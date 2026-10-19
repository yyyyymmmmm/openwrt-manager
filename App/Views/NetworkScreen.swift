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
    @Environment(RouterStore.self) private var store
    var scope: String? = nil
    private var interfaces: [NetworkInterfaceSnapshot] {
        (store.snapshot?.interfaces ?? []).filter { interface in scope.map { interface.name.lowercased().hasPrefix($0) } ?? true }
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
            ForEach(interfaces) { interface in
                AppSection(title: interface.name) { AppGroup {
                    InterfaceRow(interface: interface, showAddresses: true).padding(12)
                    if let device = interface.device { AppDivider(); AppRow(title: "网络设备", value: device) }
                    ForEach(Array(interface.defaultRoutes.enumerated()), id: \.offset) { _, route in
                        AppDivider()
                        AppRow(title: route.ipv6 ? "IPv6 默认网关" : "IPv4 默认网关", detail: route.metric.map { "跃点 \($0)" }, value: route.gateway ?? "无下一跳（链路路由）")
                    }
                    if !interface.dnsServers.isEmpty { AppDivider(); AppRow(title: "DNS", value: interface.dnsServers.joined(separator: " · ")) }
                    ForEach(interface.errors, id: \.self) { error in AppDivider(); AppRow(title: "固件错误", detail: error, symbol: "exclamationmark.triangle") }
                } }
            }
            if interfaces.isEmpty { ContentUnavailableView("暂无接口信息", systemImage: "network", description: Text("路由器没有返回匹配接口。请核对读取权限与错误信息。")) }
            if store.inventory.configNames.contains("network") {
                AppSection(title: "接口配置") {
                    AppGroup {
                        NavigationLink { NativeConfigurationView(schema: .interfaces) } label: { AppRow(title: "编辑网络配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("interface-edit-config")
                    }
                }
            }
        }.appDetailStyle(scope == "wan" ? "互联网 · WAN" : scope == "lan" ? "局域网 · LAN" : "网络接口")
            .refreshable { await store.refresh() }
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
    @State private var query = ""

    private var routes: [IPRouteRecord] {
        family == .ipv4 ? (store.routing?.ipv4Routes ?? []) : (store.routing?.ipv6Routes ?? [])
    }
    private var neighbors: [IPNeighborRecord] {
        let values = family == .ipv4 ? (store.routing?.ipv4Neighbors ?? []) : (store.routing?.ipv6Neighbors ?? [])
        guard !query.isEmpty else { return values }
        return values.filter { [$0.address, $0.mac ?? "", $0.interface, $0.device, $0.state].contains { $0.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.routingUpdatedAt, error: store.routingError,
                       retry: { Task { await store.refresh() } }, loading: store.isRefreshing && store.routingUpdatedAt == nil)
            Picker("地址族", selection: $family) {
                ForEach(AddressFamily.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("routingFamilyPicker")
            .padding(.top, 10)

            AppSection(title: "邻居设备 · \(neighbors.count)", note: "来源：路由器内核 ARP/NDP 邻居表。DHCP 租约单独显示，不代表在线状态。") {
                AppGroup {
                    if let error = store.routingError, store.routing == nil {
                        DataUnavailableView(title: "无法读取邻居表", message: "检查 file.exec 权限；应用仅请求固定的 /sbin/ip 查询命令。", error: error) {
                            Task { await store.refresh() }
                        }
                    } else if store.routingUpdatedAt == nil {
                        DataUnavailableView(title: "正在读取邻居表", message: "", error: nil, isLoading: store.isRefreshing)
                    } else if neighbors.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "暂无邻居记录" : "没有匹配邻居", systemImage: "network.slash",
                                               description: Text(query.isEmpty ? "路由器当前没有返回此地址族的邻居项。静态配置但近期未通信的设备不会出现在内核邻居表中。" : "请更换 IP、MAC、接口或状态关键词。"))
                    } else {
                        ForEach(neighbors) { neighbor in
                            NavigationLink {
                                NeighborRecordDetailView(neighbor: neighbor, family: family)
                            } label: {
                                AppRow(title: neighbor.address,
                                       detail: "\(neighbor.mac ?? "未报告 MAC") · \(neighbor.interface)",
                                       symbol: "desktopcomputer", value: neighbor.state, chevron: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("neighbor-\(family.rawValue)-\(neighbor.id)")
                            if neighbor.id != neighbors.last?.id { AppDivider(inset: 48) }
                        }
                    }
                }
            }

            AppSection(title: "路由表 · \(routes.count)", note: "来源：路由器内核路由表；这里只读显示当前生效路由。") {
                AppGroup {
                    if store.routingUpdatedAt == nil {
                        Text("路由数据尚未读取").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12)
                    } else if routes.isEmpty && store.routingError == nil {
                        ContentUnavailableView("暂无路由记录", systemImage: "point.3.connected.trianglepath.dotted")
                    } else {
                        ForEach(routes) { route in
                            NavigationLink { RouteRecordDetailView(route: route, family: family) } label: {
                                AppRow(title: route.destination,
                                       detail: [route.gateway.map { "网关 \($0)" }, route.device.map { "设备 \($0)" }].compactMap { $0 }.joined(separator: " · "),
                                       symbol: "arrow.triangle.branch", value: route.metric.map { "Metric \($0)" }, chevron: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("route-\(family.rawValue)-\(route.id)")
                            if route.id != routes.last?.id { AppDivider(inset: 48) }
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
