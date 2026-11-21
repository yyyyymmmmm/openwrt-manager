import SwiftUI
import OpenWrtKit

/// Network tab (spec 3.4): pages come from the registry — the DHCP/DNS
/// split, wireless presence and everything else follow the snapshot.
struct NetworkTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    private var pages: [PageDescriptor] {
        store.tabs.first { $0.tab == .network }?.pages ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                if let capability = store.capability {
                    Section {
                        SummaryBanner(summary: SummaryEngine.network(
                            upstreamUp: capability.upstream.flatMap { upstream in
                                capability.interfaces.first { $0.name == upstream.interfaceName }?.up
                            },
                            interfacesUp: capability.interfaces.filter { $0.up == true }.count,
                            interfacesTotal: capability.interfaces.count,
                            leaseCount: store.leases.count))
                            .summaryRow()
                    }
                }
                Section {
                    NavigationLink {
                        DevicesView()
                    } label: {
                        Label("设备管理", systemImage: "iphone.gen3")
                    }
                }
                if pages.isEmpty {
                    EmptyStateView(title: "暂无网络页面", message: "发现完成后，这里会按这台路由器实际的网络菜单生成入口。", symbol: "network.slash")
                } else {
                    Section("网络") {
                        ForEach(pages) { page in
                            NavigationLink {
                                PageDestination(page: page)
                            } label: {
                                HStack {
                                    Label(page.title, systemImage: Self.symbol(for: page.kind))
                                    Spacer()
                                    if page.isGenericFallback { StatusBadge(title: "通用页") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("网络")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func symbol(for kind: PageKind) -> String {
        switch kind {
        case .interfaces: return "rectangle.connected.to.line.below"
        case .staticRoutes: return "arrow.triangle.branch"
        case .dhcp, .dns: return "server.rack"
        case .diagnostics: return "stethoscope"
        case .speedTest: return "gauge.with.dots.needle.67percent"
        case .sqm: return "arrow.left.and.right"
        case .firewallConfig: return "shield"
        case .upnp: return "arrow.up.forward.app"
        case .bandwidthMonitor: return "chart.bar"
        case .wireless: return "wifi"
        default: return "network"
        }
    }
}

// MARK: - Interfaces

struct InterfacesView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<[CollectedRouterSnapshot.InterfaceState]> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取接口…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let interfaces):
                if interfaces.isEmpty {
                    EmptyStateView(title: "无接口数据", message: "路由器未报告任何接口。")
                } else {
                    Section {
                        SummaryBanner(summary: SummaryEngine.interfaces(
                            up: interfaces.filter { $0.up == true }.count, total: interfaces.count))
                            .summaryRow()
                    }
                    Section {
                        ForEach(interfaces, id: \.name) { iface in
                            InterfaceCard(iface: iface)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                Section("网络设备（配置）") {
                    NavigationLink {
                        UCIConfigView(title: "网络配置", configNames: ["network"])
                    } label: {
                        Label("网桥、端口与 VLAN 配置", systemImage: "rectangle.3.group")
                    }
                    NavigationLink {
                        ConfigEditorView(configName: "network", title: "接口配置")
                    } label: {
                        Label("编辑接口配置（协议、地址、网关、DHCP 服务器）", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .navigationTitle("接口")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do { state = .loaded(try await client.interfaces()) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

/// One interface as a phone card (package E, standard 5): name and
/// state first, addresses prominent, the rest quiet — the desktop
/// table's information, re-laid for a small screen.
private struct InterfaceCard: View {
    let iface: CollectedRouterSnapshot.InterfaceState

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Text(iface.name).font(AppTypography.rowTitle)
                Spacer()
                StatusBadge(title: iface.up == true ? L10n.string("已连接") : L10n.string("未连接"),
                            good: iface.up == true)
            }
            ForEach(iface.ipv4, id: \.self) { address in
                Text(address).font(AppTypography.reading.weight(.semibold)).monospacedDigit()
            }
            if let proto = iface.proto { detailRow("协议", proto) }
            if let device = iface.l3Device ?? iface.device { detailRow("设备", device) }
            ForEach(iface.ipv6, id: \.self) { address in
                HStack(spacing: AppSpacing.sm) {
                    TermLabel(text: "IPv6", term: "IPv6")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    Spacer(minLength: AppSpacing.sm)
                    Text(address).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        .multilineTextAlignment(.trailing)
                }
            }
            ForEach(iface.dns, id: \.self) { server in
                detailRow("DNS", server)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Text(L10n.key(label)).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            Spacer(minLength: AppSpacing.sm)
            Text(value).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Static routes

struct StaticRoutesView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        UCIConfigView(title: "静态路由", configNames: ["network"])
            .navigationTitle("静态路由")
    }
}

// MARK: - DHCP / DNS

struct DHCPView: View {
    @Environment(RouterStore.self) private var store
    let merged: Bool
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var localization: LuciLocalization = .source

    var body: some View {
        List {
            Section {
                SummaryBanner(summary: SummaryEngine.dhcp(leaseCount: store.leases.count))
                    .summaryRow()
            }
            Section {
                if store.leases.isEmpty {
                    EmptyStateView(title: "暂无租约", message: "当前没有已分配的 DHCP 租约。")
                } else {
                    ForEach(store.leases) { lease in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                                Text(lease.hostname).font(AppTypography.rowTitle)
                                Spacer(minLength: AppSpacing.sm)
                                Text(lease.address).font(AppTypography.rowTitle).monospacedDigit()
                            }
                            HStack(spacing: AppSpacing.sm) {
                                Text(lease.mac).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                Spacer()
                                // LuCI reports remaining seconds; only
                                // plausible remainders are shown, so an
                                // absolute timestamp is never misread.
                                if let expires = lease.expires, expires >= 0, expires <= 7 * 86400 {
                                    Text(L10n.format("剩余 %@", FormatHelpers.uptime(TimeInterval(expires))))
                                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                }
            } header: {
                TermLabel(text: "已分配租约", term: "DHCP 租约")
            }
            switch state {
            case .loading:
                ProgressView("正在读取 DHCP 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                if let configuration {
                    let sections = GenericPageModel.sections(from: configuration, localizer: localization)
                    let hosts = sections.filter { $0.type == "host" }
                    let pools = sections.filter { $0.type == "dhcp" }
                    if !hosts.isEmpty {
                        Section("静态租约") {
                            ForEach(hosts) { section in
                                ForEach(section.rows) { row in
                                    LabeledContent(row.displayKey, value: row.valueText)
                                }
                            }
                        }
                    }
                    if !pools.isEmpty {
                        Section("地址池") {
                            ForEach(pools) { section in
                                LabeledContent(section.title, value: L10n.format("%lld 项设置", section.rows.count))
                            }
                        }
                    }
                    if merged {
                        Section("DNS（与 DHCP 同页）") {
                            ForEach(sections.filter { $0.type == "dnsmasq" }) { section in
                                ForEach(section.rows) { row in
                                    LabeledContent(row.displayKey, value: row.valueText)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    StaticLeaseEditorView()
                } label: {
                    Label("管理静态租约", systemImage: "square.and.pencil")
                }
                NavigationLink {
                    UCIConfigView(title: "DHCP 完整配置", configNames: ["dhcp"])
                } label: {
                    Label("查看全部 DHCP 配置", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle(merged ? L10n.key("DHCP 与 DNS") : "DHCP")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        localization = await client.localization()
        do { state = .loaded(try await client.configuration("dhcp")) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

struct DNSView: View {
    var body: some View {
        UCIConfigView(title: "DNS", configNames: ["dhcp"], sectionTypeFilter: "dnsmasq")
    }
}

// MARK: - Diagnostics (query-only tools)

struct NetworkDiagnosticsView: View {
    @Environment(RouterStore.self) private var store
    @State private var target = ""
    @State private var tool = 0
    @State private var output: String?
    @State private var running = false
    @State private var error: String?

    private var isValidTarget: Bool {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 253 && trimmed.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" || $0 == "_"
        }
    }

    var body: some View {
        List {
            Section("工具") {
                Picker("工具", selection: $tool) {
                    Text("Ping").tag(0)
                    Text("路由追踪").tag(1)
                    Text("域名查询").tag(2)
                }
                .pickerStyle(.segmented)
                TextField("主机名或 IP 地址", text: $target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await run() }
                } label: {
                    if running { ProgressView() } else { Text("开始查询") }
                }
                .disabled(!isValidTarget || running)
            }
            if let error {
                ErrorStateView(message: error)
            }
            if let output {
                if tool == 0 {
                    Section {
                        SummaryBanner(summary: pingSummary(output))
                            .summaryRow()
                    }
                }
                RawDataSection(title: "原始输出") {
                    Text(output).font(AppTypography.metadata.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("网络诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A one-line verdict over the raw ping output; the output itself
    /// stays available in the raw-data section below.
    private func pingSummary(_ output: String) -> PageSummary {
        if output.contains("100% packet loss") {
            return PageSummary(headline: L10n.string("目标不可达：探测都没有回应"), tone: .bad)
        }
        if output.contains("0% packet loss") {
            return PageSummary(headline: L10n.string("目标可达：探测全部有回应"), tone: .good)
        }
        return PageSummary(headline: L10n.string("查询完成，详细结果见原始输出"), tone: .neutral)
    }

    private func run() async {
        guard let client = store.readClient, isValidTarget else { return }
        running = true
        error = nil
        output = nil
        defer { running = false }
        let host = target.trimmingCharacters(in: .whitespaces)
        do {
            switch tool {
            case 0: output = try await client.exec(command: "/bin/ping", arguments: ["-c", "4", "-W", "2", host])
            case 1: output = try await client.exec(command: "/usr/sbin/traceroute", arguments: ["-m", "15", "-w", "2", host])
            default: output = try await client.exec(command: "/usr/bin/nslookup", arguments: [host])
            }
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

// MARK: - Speed test (component check only — no execution channel yet)

/// Honest placeholder (audit F3): the app has no speed-test
/// execution channel, so this page says exactly that. Detection is
/// per-component and factual — an init.d service named for iperf
/// means the iPerf3 service, and netspeedtest is reported as its
/// own component. The previous version OR-ed the netspeedtest menu
/// into the iPerf3 verdict, reporting a component that was not
/// there; that mislabel is removed, along with the fake "results"
/// framing.
struct SpeedTestView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<Components> = .loading

    private struct Components {
        var iperf3Service: Bool
        var netspeedtestService: Bool
    }

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在检查测速组件…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let components):
                Section("路由器上的测速组件") {
                    LabeledContent("iPerf3 服务", value: components.iperf3Service ? L10n.string("已检出") : L10n.string("未检出"))
                    LabeledContent("netspeedtest 组件", value: components.netspeedtestService ? L10n.string("已检出") : L10n.string("未检出"))
                    Text("检出只说明路由器装有对应组件，不代表 App 能执行测速。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
                Section {
                    EmptyStateView(title: "App 内测速暂不可用", message: "当前版本尚未接入测速的执行通道，无法在 App 内发起测速，也没有历史结果可显示。", symbol: "gauge.with.dots.needle.67percent")
                }
            }
        }
        .navigationTitle("网速测试")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do {
            let services = try await client.serviceList()
            state = .loaded(Components(
                iperf3Service: services.contains { $0.name.contains("iperf") },
                netspeedtestService: services.contains { $0.name.contains("netspeedtest") }))
        } catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Firewall configuration (read-only)

struct FirewallConfigView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var localization: LuciLocalization = .source

    private static let groupTitles: [(type: String, title: String)] = [
        ("defaults", "常规与默认策略"), ("zone", "区域"), ("forwarding", "区域转发"),
        ("redirect", "端口转发"), ("rule", "通信规则"), ("snat", "NAT 规则"),
        ("ipset", "IP 集"), ("include", "自定义与包含")
    ]

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取防火墙配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                if let configuration {
                    let sections = GenericPageModel.sections(from: configuration, localizer: localization)
                    Section {
                        SummaryBanner(summary: SummaryEngine.genericConfig(
                            sections: sections.count,
                            rows: sections.reduce(0) { $0 + $1.rows.count }))
                            .summaryRow()
                    }
                    ForEach(Self.groupTitles, id: \.type) { group in
                        let groupSections = sections.filter { $0.type == group.type }
                        if !groupSections.isEmpty {
                            Section(group.title) {
                                ForEach(groupSections) { section in
                                    CollapsibleGroup(title: section.title, detail: "\(section.rows.count) 项") {
                                        ForEach(section.rows) { row in
                                            LabeledContent(row.displayKey, value: row.valueText)
                                        }
                                    }
                                    .listRowInsets(EdgeInsets())
                                }
                            }
                        }
                    }
                    let known = Set(Self.groupTitles.map(\.type))
                    let others = sections.filter { !known.contains($0.type) }
                    if !others.isEmpty {
                        Section("其他") {
                            ForEach(others) { section in
                                LabeledContent(section.title, value: L10n.format("%lld 项", section.rows.count))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("防火墙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ConfigEditorView(configName: "firewall", title: "防火墙")
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        localization = await client.localization()
        do { state = .loaded(try await client.configuration("firewall")) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - UPnP

struct UPnPView: View {
    var body: some View {
        UCIConfigView(title: "UPnP IGD 和 PCP", configNames: ["upnpd"])
    }
}

// MARK: - Bandwidth monitor

struct BandwidthView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<String?> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取带宽监控…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let report):
                if let report, !report.isEmpty {
                    Section {
                        SummaryBanner(summary: PageSummary(
                            headline: L10n.string("已读取流量分布报表，原始数据在下方"), tone: .neutral))
                            .summaryRow()
                    }
                    RawDataSection {
                        Text(report).font(AppTypography.metadata.monospaced()).textSelection(.enabled)
                    }
                } else {
                    EmptyStateView(title: "暂无流量数据", message: "带宽监控服务未返回数据，可能尚未积累或未启用。", symbol: "chart.bar.xaxis")
                }
            }
            Section {
                NavigationLink {
                    UCIConfigView(title: "带宽监控配置", configNames: ["nlbwmon"])
                } label: {
                    Label("查看监控配置", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("带宽监控")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        // A refused or failing nlbw call is a failure state, not
        // "no data yet" (audit U9): only a successful empty report
        // may present as empty.
        do { state = .loaded(try await client.exec(command: "/usr/sbin/nlbw", arguments: ["-c", "json"])) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Wireless (only generated when the snapshot has radios)

struct WirelessView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            if !store.radios.isEmpty {
                Section {
                    SummaryBanner(summary: SummaryEngine.wireless(
                        radiosOn: store.radios.filter { $0.up == true }.count,
                        radiosTotal: store.radios.count,
                        networkCount: store.radios.reduce(0) { $0 + $1.networks.count }))
                        .summaryRow()
                }
            }
            if let wireless = store.capability?.wireless, wireless.present {
                ForEach(wireless.radios, id: \.name) { radio in
                    Section(radio.name) {
                        LabeledContent("状态", value: radio.up == true ? L10n.string("启用") : L10n.string("未启用"))
                        if let disabled = radio.disabled {
                            LabeledContent("禁用", value: disabled ? L10n.string("是") : L10n.string("否"))
                        }
                        if let band = radio.band {
                            HStack {
                                TermLabel(text: "频段", term: "频段")
                                Spacer()
                                Text(band).foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }
            }
            if !store.radios.isEmpty {
                Section {
                    ForEach(store.radios) { radio in
                        ForEach(radio.networks, id: \.self) { ssid in
                            HStack(spacing: AppSpacing.sm) {
                                Image(systemName: "wifi").foregroundStyle(AppPalette.accent)
                                Text(ssid).font(AppTypography.rowTitle)
                                Spacer()
                                Text(radio.name).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                } header: {
                    TermLabel(text: "无线网络", term: "SSID")
                }
            }
            Section {
                NavigationLink {
                    UCIConfigView(title: "无线配置", configNames: ["wireless"])
                } label: {
                    Label("查看全部无线配置", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("无线")
        .navigationBarTitleDisplayMode(.inline)
    }
}
