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
    private var hasWireless: Bool { !store.radios.isEmpty || store.inventory.menu("admin/network/wireless") != nil }
    private var configs: [String] {
        let discovered = store.inventory.allMenus.filter { $0.group == "network" }.flatMap(\.configs)
        let existing = Set(store.inventory.configNames)
        return Set(discovered + ["network", "dhcp", "firewall"] + (hasWireless ? ["wireless"] : []))
            .intersection(existing).sorted().filter { query.isEmpty || ($0 + title($0)).localizedCaseInsensitiveContains(query) }
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    var body: some View {
        InventoryStatus()
        AppSection(title: "连接状态") {
            AppGroup {
                if hasWireless && matches("无线网络 Wi-Fi") {
                    NavigationLink { WirelessDetailView() } label: { AppRow(title: "无线网络", symbol: "wifi", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("network-wireless")
                }
                if store.snapshot?.interfaces.contains(where: { $0.name.hasPrefix("wan") }) == true && matches("互联网 WAN") {
                    NavigationLink { InterfaceDetailView(scope: "wan") } label: { AppRow(title: "互联网 · WAN", symbol: "globe", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("network-wan")
                }
                if store.snapshot?.interfaces.contains(where: { $0.name.hasPrefix("lan") }) == true && matches("局域网 LAN") {
                    NavigationLink { InterfaceDetailView(scope: "lan") } label: { AppRow(title: "局域网 · LAN", symbol: "network", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("network-lan")
                }
                if matches("全部网络接口") {
                    NavigationLink { InterfaceDetailView() } label: { AppRow(title: "全部网络接口", symbol: "point.3.connected.trianglepath.dotted", chevron: true) }.buttonStyle(.plain)
                }
                if matches("DHCP 设备租约") {
                    NavigationLink { DevicesContent() } label: { AppRow(title: "DHCP 租约", symbol: "desktopcomputer", chevron: true) }.buttonStyle(.plain)
                }
            }
        }
        AppSection(title: "网络配置") {
            AppGroup {
                ForEach(configs, id: \.self) { config in
                    NavigationLink { ConfigurationEditorView(name: config) } label: {
                        AppRow(title: title(config), detail: config, symbol: "slider.horizontal.3", chevron: true)
                    }.buttonStyle(.plain)
                    if config != configs.last { AppDivider() }
                }
            }
        }
        AppSection(title: "扩展配置") {
            AppGroup {
                NavigationLink { PluginDirectoryView() } label: { AppRow(title: "已安装插件", symbol: "puzzlepiece.extension", chevron: true) }.buttonStyle(.plain)
                AppDivider()
                NavigationLink { ConfigurationDirectoryView() } label: { AppRow(title: "全部路由器配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain)
            }
        }
    }
    private func title(_ config: String) -> String {
        switch config {
        case "network": return "接口、设备与路由"
        case "wireless": return "无线配置"
        case "dhcp": return "DHCP、DNS 与静态租约"
        case "firewall": return "防火墙、NAT 与端口转发"
        default: return config
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
                AppSection(title: interface.name) { AppGroup { InterfaceRow(interface: interface, showAddresses: true).padding(12) } }
            }
            if interfaces.isEmpty { ContentUnavailableView("暂无接口信息", systemImage: "network", description: Text("路由器没有返回匹配接口。请核对读取权限与错误信息。")) }
            if store.inventory.configNames.contains("network") {
                AppSection(title: "接口配置") {
                    AppGroup {
                        NavigationLink { ConfigurationEditorView(name: "network") } label: { AppRow(title: "编辑网络配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain)
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
            if store.inventory.configNames.contains("wireless") && (!store.radios.isEmpty || store.inventory.menu("admin/network/wireless") != nil) {
                AppSection(title: "无线配置") {
                    AppGroup {
                        NavigationLink { ConfigurationEditorView(name: "wireless") } label: { AppRow(title: "编辑无线配置", symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain)
                    }
                }
            }
        }.appDetailStyle("无线网络").refreshable { await store.refresh() }
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
