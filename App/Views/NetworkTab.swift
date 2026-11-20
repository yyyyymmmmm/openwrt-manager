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
                    ForEach(interfaces, id: \.name) { iface in
                        Section(iface.name) {
                            LabeledContent("状态", value: iface.up == true ? "已连接" : "未连接")
                            if let proto = iface.proto { LabeledContent("协议", value: proto) }
                            if let device = iface.l3Device ?? iface.device { LabeledContent("设备", value: device) }
                            ForEach(iface.ipv4, id: \.self) { address in
                                LabeledContent("IPv4", value: address)
                            }
                            ForEach(iface.ipv6, id: \.self) { address in
                                LabeledContent("IPv6", value: address)
                            }
                            ForEach(iface.dns, id: \.self) { server in
                                LabeledContent("DNS", value: server)
                            }
                        }
                    }
                }
                Section("网络设备（配置）") {
                    NavigationLink {
                        UCIConfigView(title: "网络配置", configNames: ["network"])
                    } label: {
                        Label("网桥、端口与 VLAN 配置", systemImage: "rectangle.3.group")
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

    var body: some View {
        List {
            Section("已分配租约") {
                if store.leases.isEmpty {
                    EmptyStateView(title: "暂无租约", message: "当前没有已分配的 DHCP 租约。")
                } else {
                    ForEach(store.leases) { lease in
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(lease.hostname).font(AppTypography.rowTitle)
                                Text(lease.mac).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                            Spacer()
                            Text(lease.address).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
            switch state {
            case .loading:
                ProgressView("正在读取 DHCP 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                if let configuration {
                    let sections = GenericPageModel.sections(from: configuration)
                    let hosts = sections.filter { $0.type == "host" }
                    let pools = sections.filter { $0.type == "dhcp" }
                    if !hosts.isEmpty {
                        Section("静态租约") {
                            ForEach(hosts) { section in
                                ForEach(section.rows) { row in
                                    LabeledContent(row.key, value: row.valueText)
                                }
                            }
                        }
                    }
                    if !pools.isEmpty {
                        Section("地址池") {
                            ForEach(pools) { section in
                                LabeledContent(section.title, value: "\(section.rows.count) 项设置")
                            }
                        }
                    }
                    if merged {
                        Section("DNS（与 DHCP 同页）") {
                            ForEach(sections.filter { $0.type == "dnsmasq" }) { section in
                                ForEach(section.rows) { row in
                                    LabeledContent(row.key, value: row.valueText)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    UCIConfigView(title: "DHCP 完整配置", configNames: ["dhcp"])
                } label: {
                    Label("查看全部 DHCP 配置", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle(merged ? "DHCP and DNS" : "DHCP")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
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

struct DiagnosticsView: View {
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
                Section("结果") {
                    Text(output).font(AppTypography.metadata.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("网络诊断")
        .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Speed test (read-only results area)

struct SpeedTestView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<Bool> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在检查测速服务…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let iperfPresent):
                Section("iPerf3") {
                    LabeledContent("服务检出", value: iperfPresent ? "已检出" : "未检出")
                }
                Section("测速结果") {
                    EmptyStateView(title: "暂无测速结果", message: "本期为只读展示：测速执行将在后续版本提供，历史结果会显示在这里。", symbol: "gauge.with.dots.needle.67percent")
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
            state = .loaded(services.contains { $0.name.contains("iperf") }
                            || (store.capability?.menuNode("admin/network/netspeedtest") != nil))
        } catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Firewall configuration (read-only)

struct FirewallConfigView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading

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
                    let sections = GenericPageModel.sections(from: configuration)
                    ForEach(Self.groupTitles, id: \.type) { group in
                        let groupSections = sections.filter { $0.type == group.type }
                        if !groupSections.isEmpty {
                            Section(group.title) {
                                ForEach(groupSections) { section in
                                    CollapsibleGroup(title: section.title, detail: "\(section.rows.count) 项") {
                                        ForEach(section.rows) { row in
                                            LabeledContent(row.key, value: row.valueText)
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
                                LabeledContent(section.title, value: "\(section.rows.count) 项")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("防火墙")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
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
                    Section("流量分布") {
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
        do { state = .loaded(try await client.exec(command: "/usr/sbin/nlbw", arguments: ["-c", "json"])) }
        catch { state = .loaded(nil) }
    }
}

// MARK: - Wireless (only generated when the snapshot has radios)

struct WirelessView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            if let wireless = store.capability?.wireless, wireless.present {
                ForEach(wireless.radios, id: \.name) { radio in
                    Section(radio.name) {
                        LabeledContent("状态", value: radio.up == true ? "启用" : "未启用")
                        if let disabled = radio.disabled {
                            LabeledContent("禁用", value: disabled ? "是" : "否")
                        }
                        if let band = radio.band { LabeledContent("频段", value: band) }
                    }
                }
            }
            if !store.radios.isEmpty {
                Section("网络") {
                    ForEach(store.radios) { radio in
                        ForEach(radio.networks, id: \.self) { ssid in
                            LabeledContent(radio.name, value: ssid)
                        }
                    }
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
