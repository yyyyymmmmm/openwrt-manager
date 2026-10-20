import SwiftUI
import OpenWrtKit

struct NetworkScreen: View {
    @Binding var showingRouterPicker: Bool
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "网络", subtitle: "接口、地址与安全配置") {
                NetworkTaskGroups()
            }
        }
    }
}

struct NetworkTaskGroups: View {
    @Environment(RouterStore.self) private var store
    var query = ""
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    var body: some View {
        InventoryStatus()
        AppSection(title: "网络") {
            AppGroup {
                if matches("接口 设备 网桥 VLAN 全局网络 WAN LAN IPv6") {
                    NavigationLink { NetworkInterfacesView() } label: { AppRow(title: "接口", detail: "逻辑接口、设备、网桥与 VLAN", symbol: "network", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("network-interfaces")
                }
                if matches("无线网络 Wi-Fi SSID 访客") {
                    NavigationLink { WirelessDetailView() } label: { AppRow(title: "无线网络", detail: "无线电、SSID 与安全", symbol: "wifi", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("network-wireless")
                }
                if matches("静态 策略 路由 IPv4 IPv6") { NativeConfigurationLink(schema: .routes, symbol: "arrow.triangle.branch") }
                if matches("DHCP 租约 静态绑定 分配 IPv6 RA") {
                    NavigationLink { DHCPManagementView() } label: { AppRow(title: "DHCP", detail: "地址分配、静态租约与 IPv6 RA", symbol: "rectangle.connected.to.line.below", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("network-dhcp-leases")
                }
                if matches("DNS 缓存 记录 DNSSEC 转发") { NativeConfigurationLink(schema: .dns, symbol: "server.rack") }
                if matches("防火墙 区域 端口转发 通信规则 NAT IP集合") { NativeConfigurationLink(schema: .firewall, symbol: "checkmark.shield") }
                if matches("网络诊断 Ping Traceroute DNS查询") {
                    NavigationLink { RouterDiagnosticsView() } label: { AppRow(title: "网络诊断", symbol: "stethoscope", chevron: true) }.buttonStyle(.plain)
                }
            }
        }
        FirmwareMenuSection(group: "network", excluding: ["network", "wireless", "routes", "dhcp", "dns", "firewall", "diagnostics"], query: query)
        AppSection(title: "高级配置", note: "通用 UCI 编辑保留给固件扩展字段，不代表专用功能已经适配。") {
            AppGroup {
                NavigationLink { ConfigurationDirectoryView() } label: { AppRow(title: "全部配置文件", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("network-configurations")
            }
        }
    }
}

struct InterfaceDetailView: View {
    var scope: String? = nil
    var body: some View {
        NetworkInterfacesView(scope: scope)
    }
}

struct WirelessDetailView: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.wirelessUpdatedAt, error: store.wirelessError)
            ForEach(store.radios) { radio in
                AppSection(title: radio.name) {
                    AppGroup {
                        AppRow(title: radio.name, symbol: radio.up == nil ? "questionmark.circle" : radio.up == true ? "wifi" : "wifi.slash",
                               value: radio.up.map { $0 ? "已启用" : "未启用" } ?? "状态未报告")
                        AppDivider()
                        AppRow(title: "信道", value: radio.channel)
                        ForEach(radio.networks, id: \.self) { ssid in AppDivider(); AppRow(title: ssid, symbol: "dot.radiowaves.left.and.right") }
                    }
                }
            }
            if store.radios.isEmpty {
                ContentUnavailableView("没有读取到无线电", systemImage: "wifi.slash", description: Text(store.wirelessError == nil ? "当前未返回无线硬件。" : "读取失败不能据此判断设备没有无线硬件。"))
            }
            AppSection(title: "无线配置") {
                AppGroup {
                    NavigationLink { NativeConfigurationView(schema: .wireless) } label: { AppRow(title: "编辑无线配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain)
                }
            }
        }.appDetailStyle("无线网络").refreshable { await store.refresh() }
    }
}

private enum AddressFamily: String, CaseIterable, Identifiable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
    var id: String { rawValue }
}

struct RoutingTablesView: View {
    @Environment(RouterStore.self) private var store
    @State private var family: AddressFamily = .ipv4
    @State private var table: RoutingTable = .neighbors
    @State private var query = ""

    private enum RoutingTable: String, CaseIterable, Identifiable {
        case neighbors = "邻居", routes = "路由", rules = "策略规则"
        var id: String { rawValue }
    }
    private var routeRead: RoutingRead<[IPRouteRecord]>? { family == .ipv4 ? store.routing?.routes4 : store.routing?.routes6 }
    private var neighborRead: RoutingRead<[IPNeighborRecord]>? { family == .ipv4 ? store.routing?.neighbors4 : store.routing?.neighbors6 }
    private var ruleRead: RoutingRead<[IPRuleRecord]>? { family == .ipv4 ? store.routing?.rules4 : store.routing?.rules6 }
    private var routes: [IPRouteRecord] {
        let values = routeRead?.value ?? []
        return query.isEmpty ? values : values.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
    }
    private var neighbors: [IPNeighborRecord] {
        let values = neighborRead?.value ?? []
        guard !query.isEmpty else { return values }
        return values.filter { [$0.address, $0.mac ?? "", $0.interface, $0.device, $0.state].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private var rules: [IPRuleRecord] {
        let values = ruleRead?.value ?? []
        guard !query.isEmpty else { return values }
        return values.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
    }
    private var activeRead: AnyRoutingRead {
        switch table {
        case .neighbors: return AnyRoutingRead(valueIsAvailable: neighborRead?.value != nil, updatedAt: neighborRead?.updatedAt, error: neighborRead?.error)
        case .routes: return AnyRoutingRead(valueIsAvailable: routeRead?.value != nil, updatedAt: routeRead?.updatedAt, error: routeRead?.error)
        case .rules: return AnyRoutingRead(valueIsAvailable: ruleRead?.value != nil, updatedAt: ruleRead?.updatedAt, error: ruleRead?.error)
        }
    }
    private var activeCount: String {
        guard activeRead.valueIsAvailable else { return "未知" }
        let count = switch table { case .neighbors: neighbors.count; case .routes: routes.count; case .rules: rules.count }
        return activeRead.error == nil ? String(count) : "\(count)（上次读取）"
    }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: activeRead.updatedAt, error: activeRead.error ?? (store.routing == nil ? store.routingError : nil),
                       retry: { Task { await store.refresh() } }, loading: store.isRefreshing)
            Picker("地址族", selection: $family) {
                ForEach(AddressFamily.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("routingFamilyPicker")
            .padding(.top, 10)

            Picker("路由数据", selection: $table) {
                ForEach(RoutingTable.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("routingTablePicker")

            if let updatedAt = activeRead.updatedAt {
                Text("本表读取于 \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            }

            AppSection(title: "\(table.rawValue) · \(activeCount)", note: table == .neighbors
                       ? "来源：路由器内核 ARP/NDP 邻居表。DHCP 租约单独显示，不代表设备在线。"
                       : table == .routes ? "来源：路由器全部内核路由表，包含策略路由表。" : "来源：路由器 IPv4/IPv6 策略规则。") {
                AppGroup {
                    if let error = activeRead.error, !activeRead.valueIsAvailable {
                        DataUnavailableView(title: "无法读取\(table.rawValue)", message: "应用请求固定的只读 /sbin/ip 命令；错误会按地址族和数据表分别显示。", error: error) {
                            Task { await store.refresh() }
                        }
                    } else if activeRead.updatedAt == nil {
                        DataUnavailableView(title: "正在读取\(table.rawValue)", message: "", error: nil, isLoading: store.isRefreshing)
                    } else {
                        if let error = activeRead.error {
                            Label("本次读取失败；以下为上次成功读取的数据。", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(AppPalette.orange).textSelection(.enabled)
                            Text(error).font(.caption).foregroundStyle(AppPalette.muted).textSelection(.enabled)
                        }
                        switch table {
                        case .neighbors:
                            if neighbors.isEmpty {
                                ContentUnavailableView(query.isEmpty ? "暂无邻居记录" : "没有匹配邻居", systemImage: "network.slash",
                                    description: Text(query.isEmpty ? "路由器当前没有返回此地址族的邻居项。静态配置但近期未通信的设备不会出现在内核邻居表中。" : "请更换 IP、MAC、接口或状态关键词。"))
                            } else {
                                ForEach(neighbors) { neighbor in
                                    NavigationLink { NeighborRecordDetailView(neighbor: neighbor, family: family) } label: {
                                        AppRow(title: neighbor.address, detail: "\(neighbor.mac ?? "未报告 MAC") · \(neighbor.interface)",
                                               symbol: "desktopcomputer", value: neighbor.state, chevron: true)
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("neighbor-\(family.rawValue)-\(neighbor.id)")
                                    if neighbor.id != neighbors.last?.id { AppDivider(inset: 48) }
                                }
                            }
                        case .routes:
                            if routes.isEmpty { ContentUnavailableView(query.isEmpty ? "暂无路由记录" : "没有匹配路由", systemImage: "point.3.connected.trianglepath.dotted") }
                            else {
                                ForEach(routes) { route in
                                    NavigationLink { RouteRecordDetailView(route: route, family: family) } label: {
                                        AppRow(title: route.destination,
                                            detail: [route.table.map { "表 \($0)" }, route.gateway.map { "网关 \($0)" }, route.device.map { "设备 \($0)" }].compactMap { $0 }.joined(separator: " · "),
                                            symbol: "arrow.triangle.branch", value: route.metric.map { "Metric \($0)" }, chevron: true)
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("route-\(family.rawValue)-\(route.destination)-\(route.table ?? "unreported")-\(route.device ?? "none")")
                                    if route.id != routes.last?.id { AppDivider(inset: 48) }
                                }
                            }
                        case .rules:
                            if rules.isEmpty { ContentUnavailableView(query.isEmpty ? "暂无策略规则" : "没有匹配规则", systemImage: "line.3.horizontal.decrease.circle") }
                            else {
                                ForEach(rules) { rule in
                                    NavigationLink { RoutingRuleDetailView(rule: rule, family: family) } label: {
                                        AppRow(title: "优先级 \(rule.priority)", detail: ruleSummary(rule), symbol: "line.3.horizontal.decrease.circle", chevron: true)
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("rule-\(family.rawValue)-\(rule.priority)")
                                }
                            }
                        }
                    }
                }
            }
        }
        .appDetailStyle("路由与设备")
        .searchable(text: $query, prompt: "搜索 IP、MAC、接口或状态")
        .refreshable { await store.refresh() }
    }
}

private struct AnyRoutingRead {
    let valueIsAvailable: Bool
    let updatedAt: Date?
    let error: String?
}

private struct NeighborRecordDetailView: View {
    let neighbor: IPNeighborRecord
    let family: AddressFamily
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "路由器邻居记录") {
                AppGroup {
                    AppRow(title: "地址族", value: family.rawValue)
                    AppDivider(inset: 12)
                    AppRow(title: "IP 地址", value: neighbor.address)
                    AppDivider(inset: 12)
                    AppRow(title: "MAC 地址", value: neighbor.mac ?? "未报告")
                    AppDivider(inset: 12)
                    AppRow(title: "逻辑接口", value: neighbor.interface)
                    AppDivider(inset: 12)
                    AppRow(title: "内核设备", value: neighbor.device)
                    AppDivider(inset: 12)
                    AppRow(title: "邻居状态", value: neighbor.state)
                }
            }
            Text("邻居状态来自路由器内核的 ARP/NDP 表，不等同于 DHCP 租约或持续在线检测。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.horizontal, 6).padding(.top, 8)
            if let raw = neighbor.rawValue {
                AppSection(title: "路由器原始记录") {
                    Text(raw).font(AppTypography.secondary.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .appDetailStyle("设备详情")
        .textSelection(.enabled)
    }
}

private struct RouteRecordDetailView: View {
    let route: IPRouteRecord
    let family: AddressFamily
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "生效路由") {
                AppGroup {
                    AppRow(title: "地址族", value: family.rawValue)
                    AppDivider(inset: 12)
                    AppRow(title: "目标网络", value: route.destination)
                    if let gateway = route.gateway { AppDivider(inset: 12); AppRow(title: "网关", value: gateway) }
                    if let device = route.device { AppDivider(inset: 12); AppRow(title: "内核设备", value: device) }
                    if let protocolName = route.protocolName { AppDivider(inset: 12); AppRow(title: "路由来源", value: protocolName) }
                    if let metric = route.metric { AppDivider(inset: 12); AppRow(title: "Metric", value: metric) }
                    if let table = route.table { AppDivider(inset: 12); AppRow(title: "路由表", value: table) }
                    if let source = route.source { AppDivider(inset: 12); AppRow(title: "源地址", value: source) }
                    if let type = route.routeType { AppDivider(inset: 12); AppRow(title: "路由类型", value: type) }
                }
            }
            AppSection(title: "路由器原始记录") {
                Text(route.rawValue).font(AppTypography.secondary.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .appDetailStyle("路由详情")
    }
}

private struct RoutingRuleDetailView: View {
    let rule: IPRuleRecord
    let family: AddressFamily
    private var values: [(String, String)] {
        let labels = ["iif": "入口设备", "oif": "出口设备", "from": "源地址", "to": "目标地址", "priority": "优先级",
                      "table": "路由表", "action": "动作", "fwmark": "防火墙标记", "ipproto": "IP 协议", "sport": "源端口", "dport": "目标端口", "uidrange": "用户 ID 范围"]
        return rule.fields.keys.sorted().compactMap { key in
            guard let value = rule.fields[key] else { return nil }
            // iproute2 emits presence-only flags such as `not` and `nop` as null.
            if value == .null { return (labels[key] ?? key, "存在") }
            return (labels[key] ?? key, display(value))
        }
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "\(family.rawValue) 策略规则") {
                AppGroup {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, pair in
                        if index > 0 { AppDivider(inset: 12) }
                        AppRow(title: pair.0, value: pair.1)
                    }
                    if values.isEmpty { Text(rule.rawValue).font(AppTypography.secondary.monospaced()).textSelection(.enabled).padding(12) }
                }
            }
            AppSection(title: "路由器原始记录") {
                Text(rule.rawValue).font(AppTypography.secondary.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }.appDetailStyle("策略规则详情")
    }
    private func display(_ value: JSONValue) -> String {
        if let text = value.textValue { return text }
        if let list = value.arrayValue { return list.map(display).joined(separator: " · ") }
        if let object = value.objectValue { return object.keys.sorted().compactMap { key in object[key].map { "\(key)=\(display($0))" } }.joined(separator: ", ") }
        return value == .bool(true) ? "是" : value == .bool(false) ? "否" : "—"
    }
}

private func ruleSummary(_ rule: IPRuleRecord) -> String {
    let parts = ["iif", "src", "dst", "from", "to", "table", "action"].compactMap { key -> String? in
        guard let value = rule.fields[key]?.textValue else { return nil }
        return "\(key)=\(value)"
    }
    return parts.isEmpty ? "查看路由器返回的完整规则" : parts.joined(separator: " · ")
}

struct InterfaceRow: View {
    let interface: NetworkInterfaceSnapshot
    var showAddresses = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: interface.up == nil ? "questionmark.circle" : interface.up == true ? "checkmark.circle" : "minus.circle")
                    .foregroundStyle(interface.up == true ? AppPalette.green : AppPalette.muted)
                Text(interface.name).font(AppTypography.rowTitle)
                Spacer()
                StatusBadge(title: interface.up.map { $0 ? "接口已连接" : "接口未连接" } ?? "状态未报告", good: interface.up == true)
            }
            LabeledContent("协议", value: interface.protocolName)
            if let device = interface.device { LabeledContent("设备", value: device) }
            ForEach(showAddresses ? interface.addresses : Array(interface.addresses.prefix(1)), id: \.self) { address in LabeledContent("IP 地址", value: address).textSelection(.enabled) }
            if interface.addresses.isEmpty { Text("未报告 IP 地址").foregroundStyle(AppPalette.muted) }
        }.font(AppTypography.secondary).foregroundStyle(AppPalette.text)
    }
}
