import SwiftUI
import OpenWrtKit

/// Disambiguation: OpenWrtKit's process model shadows Foundation's
/// `ProcessInfo` (NSProcessInfo) inside this file.
private typealias ProcessInfo = OpenWrtKit.ProcessInfo

/// Overview tab (spec 3.1): the home page is the router's status overview;
/// the remaining status pages hang below it as registry-driven entries.
struct OverviewTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    private var pages: [PageDescriptor] {
        store.tabs.first { $0.tab == .overview }?.pages ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                if let error = store.capabilityError {
                    Section {
                        ErrorStateView(message: error) { Task { await store.loadCapability() } }
                    }
                }
                homeSection
                if pages.count > 1 {
                    Section("状态") {
                        ForEach(pages.dropFirst()) { page in
                            NavigationLink {
                                PageDestination(page: page)
                            } label: {
                                Label(page.title, systemImage: Self.symbol(for: page.kind))
                            }
                        }
                    }
                }
            }
            .navigationTitle("概览")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func symbol(for kind: PageKind) -> String {
        switch kind {
        case .routesStatus: return "arrow.triangle.branch"
        case .firewallStatus: return "shield"
        case .logs: return "doc.text"
        case .processes: return "list.bullet.indent"
        case .realtime: return "waveform.path.ecg"
        case .wireguardStatus: return "lock.shield"
        case .channelAnalysis: return "wifi"
        default: return "info.circle"
        }
    }

    /// The page's opening verdict (package E, standard 1): generated
    /// by the kit's rules from the same numbers the cards below show.
    private func overviewSummary(_ system: SystemSnapshot) -> PageSummary {
        let upstreamUp = store.capability?.upstream.flatMap { upstream in
            store.capability?.interfaces.first { $0.name == upstream.interfaceName }?.up
        }
        return SummaryEngine.overview(
            upstreamUp: upstreamUp,
            memoryPercent: system.memoryUsed.flatMap { HealthRating.percent(used: $0, total: system.memoryTotal ?? 0) },
            storagePercent: system.storageUsed.flatMap { HealthRating.percent(used: $0, total: system.storageTotal ?? 0) },
            onlineDevices: store.leases.isEmpty ? nil : store.leases.count)
    }

    private func usage(of used: Int64?, total: Int64?) -> (fraction: Double?, grade: HealthGrade) {
        guard let used, let total,
              let fraction = HealthRating.fraction(used: used, total: total) else { return (nil, .unknown) }
        return (fraction, HealthRating.usageGrade(percent: fraction * 100))
    }

    @ViewBuilder
    private var homeSection: some View {
        if let snapshot = store.snapshot {
            Section {
                SummaryBanner(summary: overviewSummary(snapshot.system))
                    .summaryRow()
            }
            Section("系统") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.sm) {
                    StatusCard(title: "设备", value: snapshot.system.model,
                               detail: snapshot.system.hostname, symbol: "router")
                    StatusCard(title: "固件", value: snapshot.system.firmware,
                               detail: "内核 \(snapshot.system.kernel)", symbol: "gear")
                    RatedMetricCard(title: "内存", value: FormatHelpers.percent(used: snapshot.system.memoryUsed, total: snapshot.system.memoryTotal) ?? "—",
                                    detail: memoryDetail(snapshot.system), symbol: "memorychip",
                                    fraction: usage(of: snapshot.system.memoryUsed, total: snapshot.system.memoryTotal).fraction,
                                    grade: usage(of: snapshot.system.memoryUsed, total: snapshot.system.memoryTotal).grade)
                    RatedMetricCard(title: "存储", value: FormatHelpers.percent(used: snapshot.system.storageUsed, total: snapshot.system.storageTotal) ?? "—",
                                    detail: storageDetail(snapshot.system), symbol: "internaldrive",
                                    fraction: usage(of: snapshot.system.storageUsed, total: snapshot.system.storageTotal).fraction,
                                    grade: usage(of: snapshot.system.storageUsed, total: snapshot.system.storageTotal).grade)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                if let uptime = snapshot.system.uptime {
                    LabeledContent("运行时间", value: FormatHelpers.uptime(uptime))
                }
                if let load = snapshot.system.loadAverage.first {
                    RatedRow(title: "系统负载", value: String(format: "%.2f", load),
                             grade: HealthRating.loadGrade(load: load, cores: nil))
                }
            }
        } else if store.isRefreshing || !store.hasLoaded {
            Section { HStack { ProgressView(); Text("正在读取路由器信息…") } }
        } else if let error = store.overviewError {
            Section { ErrorStateView(message: error) { Task { await store.refresh() } } }
        }

        if let upstream = store.capability?.upstream {
            Section("上游") {
                let iface = store.capability?.interfaces.first { $0.name == upstream.interfaceName }
                LabeledContent("接口", value: upstream.interfaceName)
                if let device = upstream.l3Device ?? upstream.device {
                    LabeledContent("设备", value: device)
                }
                if let nexthop = upstream.nexthop {
                    HStack {
                        TermLabel(text: "网关", term: "网关")
                        Spacer()
                        Text(nexthop).foregroundStyle(AppPalette.muted)
                    }
                }
                if let address = iface?.ipv4.first {
                    LabeledContent("IPv4 地址", value: address)
                }
                if let state = iface?.up {
                    LabeledContent("状态", value: state ? L10n.string("已连接") : L10n.string("未连接"))
                }
            }
        }

        Section("实时") {
            if let latest = store.realtimeSamples.last {
                if let connections = latest.connections {
                    LabeledContent("活动连接", value: "\(connections)")
                }
                if let total = latest.totalRate {
                    LabeledContent("下载速率", value: FormatHelpers.rate(total.rxBytesPerSecond))
                    LabeledContent("上传速率", value: FormatHelpers.rate(total.txBytesPerSecond))
                }
                FreshnessBadge(freshness: store.freshnessPolicy.evaluate(
                    fetchedAt: store.realtimeUpdatedAt, now: Date()))
            } else {
                Text("正在采集实时数据…").foregroundStyle(AppPalette.muted)
            }
            RealtimeChartView(samples: store.realtimeSamples)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }

        Section("摘要") {
            LabeledContent("DHCP 已分配租约", value: "\(store.leases.count)")
            if store.capability?.services.contains(where: { $0.key == "ddns" }) == true {
                let ddns = store.capability?.services.first { $0.key == "ddns" }
                LabeledContent("动态 DNS", value: ddns?.running == true ? L10n.string("运行中") : L10n.string("已检出"))
            }
            if store.capability?.menuNode("admin/network/upnp") != nil {
                LabeledContent("UPnP", value: L10n.string("已检出（详情见网络页）"))
            }
        }

        QuickActionsSection()

        Section("历史") {
            HistoryChartView()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private func memoryDetail(_ system: SystemSnapshot) -> String? {
        guard let used = system.memoryUsed, let total = system.memoryTotal else { return nil }
        return "\(FormatHelpers.bytes(used)) / \(FormatHelpers.bytes(total))"
    }

    private func storageDetail(_ system: SystemSnapshot) -> String? {
        guard let used = system.storageUsed, let total = system.storageTotal else { return nil }
        return "\(FormatHelpers.bytes(used)) / \(FormatHelpers.bytes(total))"
    }
}

// MARK: - Status detail pages

struct RoutesStatusView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<([CollectedRouterSnapshot.InterfaceState], [NeighborEntry])> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取路由…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let (interfaces, neighbors)):
                Section {
                    SummaryBanner(summary: SummaryEngine.interfaces(
                        up: interfaces.filter { $0.up == true }.count, total: interfaces.count))
                        .summaryRow()
                }
                Section("活跃路由") {
                    let routes = interfaces.flatMap { iface in iface.routes.map { (iface.name, $0) } }
                    if routes.isEmpty {
                        EmptyStateView(title: "无路由数据", message: "路由器未报告任何路由条目。")
                    } else {
                        ForEach(Array(routes.enumerated()), id: \.offset) { _, pair in
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text("\(pair.1.target)/\(pair.1.mask ?? 0)")
                                    .font(AppTypography.rowTitle)
                                Text("经 \(pair.0)\(pair.1.nexthop.map { L10n.format(" · 网关 %@", $0) } ?? "")")
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }
                Section("邻居") {
                    if neighbors.isEmpty {
                        EmptyStateView(title: "无邻居数据", message: "路由器未报告邻居表。")
                    } else {
                        ForEach(neighbors) { neighbor in
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(neighbor.address).font(AppTypography.rowTitle)
                                    Text(neighbor.mac ?? "无 MAC").font(AppTypography.secondary)
                                        .foregroundStyle(AppPalette.muted)
                                }
                                Spacer()
                                if let state = neighbor.state { StatusBadge(title: Self.neighborStateLabel(state)) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("路由")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do {
            async let interfaces = client.interfaces()
            async let neighbors = client.neighbors()
            state = .loaded((try await interfaces, try await neighbors))
        } catch { state = .failed(FriendlyError.message(error)) }
    }

    /// Neighbor states are protocol enums from the router; like every
    /// status vocabulary they get an app-side human mapping, with the
    /// raw value kept for anything unrecognized.
    static func neighborStateLabel(_ state: String) -> String {
        switch state {
        case "REACHABLE": return L10n.string("可达")
        case "STALE": return L10n.string("可能过期")
        case "FAILED": return L10n.string("不可达")
        case "INCOMPLETE": return L10n.string("解析中")
        case "DELAY", "PROBE": return L10n.string("探测中")
        case "PERMANENT": return L10n.string("固定")
        case "NOARP": return L10n.string("免 ARP")
        default: return state
        }
    }
}

struct FirewallStatusView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<[NftTable]> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取防火墙…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let tables):
                if tables.isEmpty {
                    EmptyStateView(title: "无 nftables 数据", message: "路由器未返回规则集，可能未使用 nftables。", symbol: "shield.slash")
                } else {
                    Section {
                        SummaryBanner(summary: SummaryEngine.firewall(
                            tables: tables.count,
                            chains: tables.reduce(0) { $0 + $1.chains.count }))
                            .summaryRow()
                    }
                    ForEach(tables) { table in
                        Section("\(table.family) · \(table.name)") {
                            ForEach(table.chains) { chain in
                                HStack {
                                    Text(chain.name).font(AppTypography.rowTitle)
                                    Spacer()
                                    Text("\(chain.countedRules) 条计数规则 · \(chain.packets) 包")
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                    Section {
                        TermLabel(text: "nftables", term: "nftables")
                    }
                }
            }
        }
        .navigationTitle("防火墙状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do { state = .loaded(try await client.nftables()) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

struct LogsView: View {
    @Environment(RouterStore.self) private var store
    @State private var source = 0
    @State private var state: LoadState<[LogEntry]> = .loading

    var body: some View {
        List {
            Picker("日志来源", selection: $source) {
                Text("系统日志").tag(0)
                Text("内核日志").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets())
            switch state {
            case .loading:
                ProgressView("正在读取日志…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let entries):
                if entries.isEmpty {
                    EmptyStateView(title: "暂无日志", message: "路由器未返回日志记录。", symbol: "doc.text.magnifyingglass")
                } else {
                    Section {
                        SummaryBanner(summary: SummaryEngine.logs(
                            total: entries.count,
                            errors: entries.filter { ($0.priority ?? 99) <= 3 }.count))
                            .summaryRow()
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(entry.message).font(AppTypography.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: AppSpacing.sm) {
                                if let source = entry.source { StatusBadge(title: source) }
                                if let timestamp = entry.timestamp {
                                    Text(timestamp, format: .dateTime.hour().minute().second())
                                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do {
            state = .loaded(source == 0 ? try await client.systemLog() : try await client.kernelLog())
        } catch { state = .failed(FriendlyError.message(error)) }
    }
}

struct ProcessesView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<[ProcessInfo]> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取进程…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let processes):
                if processes.isEmpty {
                    EmptyStateView(title: "无进程数据", message: "路由器未返回进程列表。")
                } else {
                    let sorted = processes.sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
                    Section {
                        SummaryBanner(summary: SummaryEngine.processes(
                            total: sorted.count,
                            topName: sorted.first?.command,
                            topCPU: sorted.first?.cpuPercent))
                            .summaryRow()
                    }
                    ForEach(sorted) { process in
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(process.command).font(AppTypography.rowTitle).lineLimit(1)
                                Text("PID \(process.pid)\(process.user.map { L10n.format(" · %@", $0) } ?? "")")
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                            Spacer()
                            if let cpu = process.cpuPercent {
                                Text(String(format: "%.1f%% CPU", cpu))
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("进程")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do { state = .loaded(try await client.processes()) }
        catch { state = LoadState<[ProcessInfo]>.failed(FriendlyError.message(error)) }
    }
}

struct RealtimeView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            if let latest = store.realtimeSamples.last, let total = latest.totalRate {
                Section {
                    SummaryBanner(summary: PageSummary(
                        headline: L10n.format("当前下载 %@ · 上传 %@",
                                              FormatHelpers.rate(total.rxBytesPerSecond),
                                              FormatHelpers.rate(total.txBytesPerSecond)),
                        tone: .neutral))
                        .summaryRow()
                }
            }
            Section {
                RealtimeChartView(samples: store.realtimeSamples)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("各设备速率") {
                if let latest = store.realtimeSamples.last, !latest.deviceRates.isEmpty {
                    ForEach(latest.deviceRates.sorted(by: { $0.key < $1.key }), id: \.key) { device, rate in
                        HStack {
                            Text(device).font(AppTypography.rowTitle)
                            Spacer()
                            Text("↓ \(FormatHelpers.rate(rate.rxBytesPerSecond)) · ↑ \(FormatHelpers.rate(rate.txBytesPerSecond))")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                } else {
                    EmptyStateView(title: "暂无速率数据", message: "至少需要两次轮询才能计算速率。")
                }
            }
            Section {
                FreshnessBadge(freshness: store.freshnessPolicy.evaluate(
                    fetchedAt: store.realtimeUpdatedAt, now: Date()))
            }
            Section("历史流量") {
                HistoryChartView(fixedMetric: .traffic)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("实时信息")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WireGuardStatusView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var localization: LuciLocalization = .source

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取 WireGuard…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                let wgInterfaces = store.capability?.interfaces.filter {
                    $0.proto == "wireguard" || $0.name.hasPrefix("wg")
                } ?? []
                Section {
                    SummaryBanner(summary: SummaryEngine.wireguard(
                        up: wgInterfaces.filter { $0.up == true }.count, total: wgInterfaces.count))
                        .summaryRow()
                }
                Section("接口") {
                    if wgInterfaces.isEmpty {
                        EmptyStateView(title: "无 WireGuard 接口", message: "接口列表中未发现 WireGuard 接口。", symbol: "lock.shield")
                    } else {
                        ForEach(wgInterfaces, id: \.name) { iface in
                            LabeledContent(iface.name, value: iface.up == true ? L10n.string("已连接") : L10n.string("未连接"))
                        }
                    }
                }
                if let configuration {
                    Section("配置摘要") {
                        LabeledContent("配置节", value: "\(configuration.sections.count)")
                        ForEach(GenericPageModel.sections(from: configuration, localizer: localization)) { section in
                            LabeledContent(section.title, value: L10n.format("%lld 项", section.rows.count))
                        }
                    }
                }
                Section {
                    TermLabel(text: "WireGuard", term: "WireGuard")
                }
            }
        }
        .navigationTitle("WireGuard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        localization = await client.localization()
        do { state = .loaded(try await client.configuration("wireguard")) }
        catch { state = .loaded(nil) }
    }
}

struct ChannelAnalysisView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            if store.radios.isEmpty {
                EmptyStateView(title: "无无线数据", message: "路由器未报告无线电信息。", symbol: "wifi.slash")
            } else {
                Section {
                    SummaryBanner(summary: SummaryEngine.wireless(
                        radiosOn: store.radios.filter { $0.up == true }.count,
                        radiosTotal: store.radios.count,
                        networkCount: store.radios.reduce(0) { $0 + $1.networks.count }))
                        .summaryRow()
                }
                ForEach(store.radios) { radio in
                    Section(radio.name) {
                        LabeledContent("状态", value: radio.up == true ? L10n.string("启用") : L10n.string("未启用"))
                        HStack {
                            TermLabel(text: "信道", term: "信道")
                            Spacer()
                            Text(radio.channel).foregroundStyle(AppPalette.muted)
                        }
                        ForEach(radio.networks, id: \.self) { ssid in
                            LabeledContent("网络", value: ssid)
                        }
                    }
                }
            }
        }
        .navigationTitle("信道分析")
        .navigationBarTitleDisplayMode(.inline)
    }
}
