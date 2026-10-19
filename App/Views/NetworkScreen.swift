import SwiftUI
import OpenWrtKit

struct NetworkScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "网络", subtitle: "连接、安全与网络协议") {
                ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
                NetworkTaskGroups()
            }
        }
    }
}

enum NetworkTask: String, CaseIterable, Identifiable {
    case wireless, wan, lan, dhcp, dns, firewall, forwards, vpn, routes, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wireless: return "无线网络"
        case .wan: return "互联网 · WAN"
        case .lan: return "局域网 · LAN"
        case .dhcp: return "DHCP 与静态租约"
        case .dns: return "DNS 与主机名"
        case .firewall: return "防火墙"
        case .forwards: return "端口转发"
        case .vpn: return "VPN 与隧道"
        case .routes: return "路由与策略"
        case .diagnostics: return "网络诊断"
        }
    }
    var detail: String {
        switch self {
        case .wireless: return "名称、频段、信道与访客网络"
        case .wan: return "接入协议与接口地址"
        case .lan: return "本地地址、网桥与接口"
        case .dhcp: return "地址分配、静态绑定与 IPv6"
        case .dns: return "上游解析、转发与本地域名"
        case .firewall: return "安全区域、流量规则与 NAT"
        case .forwards: return "外部访问与端口映射"
        case .vpn: return "WireGuard、OpenVPN 与其他隧道"
        case .routes: return "静态路由、分流与多 WAN"
        case .diagnostics: return "Ping、路由追踪与 DNS 查询"
        }
    }
    var symbol: String {
        switch self {
        case .wireless: return "wifi"
        case .wan: return "globe"
        case .lan: return "network"
        case .dhcp: return "number.square"
        case .dns: return "server.rack"
        case .firewall: return "checkmark.shield"
        case .forwards: return "arrow.triangle.branch"
        case .vpn: return "lock.shield"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

struct NetworkTaskGroups: View {
    var query = ""
    private let groups: [(String, [NetworkTask])] = [
        ("接入与连接", [.wireless, .wan, .lan]),
        ("地址与解析", [.dhcp, .dns]),
        ("安全与分流", [.firewall, .forwards, .vpn, .routes]),
        ("诊断工具", [.diagnostics])
    ]
    private func matching(_ tasks: [NetworkTask]) -> [NetworkTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { trimmed.isEmpty || ($0.title + $0.detail).localizedCaseInsensitiveContains(trimmed) }
    }
    var body: some View {
        ForEach(groups, id: \.0) { group in
            let tasks = matching(group.1)
            if !tasks.isEmpty {
                AppSection(title: group.0) {
                    AppGroup {
                        ForEach(tasks) { task in
                            NavigationLink {
                                switch task {
                                case .wireless: WirelessDetailView()
                                case .wan: InterfaceDetailView(scope: "wan")
                                case .lan: InterfaceDetailView(scope: "lan")
                                case .dhcp: DevicesContent()
                                default: NetworkManagementView(task: task)
                                }
                            } label: {
                                AppRow(title: task.title, detail: task.detail, symbol: task.symbol,
                                       badge: [.wireless, .wan, .lan, .dhcp].contains(task) ? nil : "LuCI", chevron: true)
                            }.buttonStyle(.plain).accessibilityIdentifier("network-\(task.id)")
                            if task != tasks.last { AppDivider() }
                        }
                    }
                }
            }
        }
        if !query.isEmpty && groups.allSatisfy({ matching($0.1).isEmpty }) {
            ContentUnavailableView.search(text: query).padding(.top, 24)
        }
    }
}

struct NetworkManagementView: View {
    let task: NetworkTask
    var body: some View {
        AppPage(title: task.title, subtitle: task.detail) {
            AppSection(title: "管理方式", note: "此功能的原生配置尚未接入。请通过路由器的 LuCI 页面完成操作，具体能力由固件和已安装插件决定。") {
                AppGroup {
                    NavigationLink { RouterWebEntryView(page: .luci) } label: {
                        AppRow(title: "前往 LuCI 管理", detail: "使用路由器网页配置", symbol: "safari", chevron: true)
                    }.buttonStyle(.plain)
                }
            }
        }.appDetailStyle(task.title)
    }
}

struct InterfaceDetailView: View {
    @Environment(RouterStore.self) private var store
    var scope: String? = nil
    private var interfaces: [NetworkInterfaceSnapshot] {
        (store.snapshot?.interfaces ?? []).filter { scope == nil || $0.name.lowercased().hasPrefix(scope!) }
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
            ForEach(interfaces) { interface in
                AppSection(title: interface.name) {
                    AppGroup { InterfaceRow(interface: interface, showAddresses: true).padding(12) }
                }
            }
            if interfaces.isEmpty {
                ContentUnavailableView("暂无接口信息", systemImage: "network", description: Text("路由器没有返回匹配的接口。请检查数据权限或通过 LuCI 查看。"))
            }
            AppSection(title: "配置接口") {
                AppGroup {
                    NavigationLink { RouterWebEntryView(page: .luci) } label: {
                        AppRow(title: "前往 LuCI 配置", symbol: "safari", chevron: true)
                    }.buttonStyle(.plain)
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
                        AppRow(title: radio.name, symbol: radio.up ? "wifi" : "wifi.slash", value: radio.up ? "已启用" : "未启用")
                        AppDivider()
                        AppRow(title: "信道", value: radio.channel)
                        ForEach(radio.networks, id: \.self) { ssid in
                            AppDivider()
                            AppRow(title: ssid, detail: "广播的网络名称", symbol: "dot.radiowaves.left.and.right")
                        }
                    }
                }
            }
            if store.radios.isEmpty {
                ContentUnavailableView("暂无无线电信息", systemImage: "wifi.slash", description: Text("设备可能没有无线硬件，或当前账户无读取权限。"))
            }
            AppSection(title: "无线设置", note: "当前只读取状态。修改名称、密码和访客网络请使用 LuCI。") {
                AppGroup {
                    NavigationLink { RouterWebEntryView(page: .luci) } label: {
                        AppRow(title: "前往 LuCI 配置", symbol: "safari", chevron: true)
                    }.buttonStyle(.plain)
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
                Image(systemName: interface.up ? "checkmark.circle" : "minus.circle")
                    .foregroundStyle(interface.up ? AppPalette.green : AppPalette.muted)
                Text(interface.name).font(AppTypography.rowTitle)
                Spacer()
                StatusBadge(title: interface.up ? "接口已连接" : "接口未连接", good: interface.up)
            }
            LabeledContent("协议", value: interface.protocolName)
            if let device = interface.device { LabeledContent("设备", value: device) }
            ForEach(showAddresses ? interface.addresses : Array(interface.addresses.prefix(1)), id: \.self) { address in
                LabeledContent("IP 地址", value: address).textSelection(.enabled)
            }
            if interface.addresses.isEmpty { Text("未分配 IP 地址").foregroundStyle(AppPalette.muted) }
        }.font(AppTypography.secondary).foregroundStyle(AppPalette.text)
    }
}
