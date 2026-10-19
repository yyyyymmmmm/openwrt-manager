import SwiftUI
import OpenWrtKit

struct OverviewScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    private var upstream: NetworkInterfaceSnapshot? { store.snapshot?.upstreamInterfaces.first }
    private var loadAverage: String {
        guard let values = store.snapshot?.system.loadAverage, !values.isEmpty else { return "尚未读取" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "概览",
                        subtitle: "路由器状态与管理") {
                ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
                health
                HStack(spacing: 8) {
                    NavigationLink { WirelessDetailView() } label: {
                        overviewTile("Wi-Fi 状态", store.wirelessError != nil ? "读取失败" : store.wirelessUpdatedAt == nil ? "尚未读取" : "\(store.radios.count) 个无线电", "wifi")
                    }.accessibilityIdentifier("overview-wireless")
                    NavigationLink { DevicesContent() } label: {
                        overviewTile("设备状态", store.devicesUpdatedAt == nil ? "尚未读取" : "\(store.leases.count) 条 DHCP 租约", "desktopcomputer")
                    }.accessibilityIdentifier("overview-leases")
                }.buttonStyle(.plain).padding(.top, 9)
                AppSection(title: "常用管理") {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            NavigationLink { InterfaceDetailView() } label: { quickItem("网络接口", "地址与连接状态", "network") }.accessibilityIdentifier("overview-interfaces")
                            if store.inventory.configNames.contains("firewall") {
                                NavigationLink { NativeConfigurationView(schema: .firewall) } label: { quickItem("防火墙", "区域与端口规则", "checkmark.shield") }.accessibilityIdentifier("overview-firewall")
                            }
                        }
                        AppDivider(inset: 12)
                        HStack(spacing: 0) {
                            NavigationLink { PluginDirectoryView() } label: { quickItem("插件中心", "配置、服务与软件包", "puzzlepiece.extension") }.accessibilityIdentifier("overview-plugins")
                            NavigationLink { ConfigurationDirectoryView() } label: { quickItem("全部配置", "读取与编辑", "slider.horizontal.3") }.accessibilityIdentifier("overview-configurations")
                        }
                    }.buttonStyle(.plain).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                }
                AppSection(title: "设备运行状态") {
                    AppGroup {
                        AppRow(title: "处理器负载", detail: "1 分钟 · 5 分钟 · 15 分钟", symbol: "bolt",
                               value: loadAverage)
                        AppDivider()
                        ResourceRow(title: "内存占用", symbol: "memorychip", used: store.snapshot?.system.memoryUsed, total: store.snapshot?.system.memoryTotal)
                        AppDivider()
                        ResourceRow(title: "根文件系统", symbol: "externaldrive", used: store.snapshot?.system.storageUsed, total: store.snapshot?.system.storageTotal)
                    }
                }
                AppSection(title: "状态") {
                    AppGroup {
                        NavigationLink { RoutingTablesView() } label: { AppRow(title: "路由与邻居", detail: "IPv4 / IPv6 生效路由与 ARP/NDP", symbol: "arrow.triangle.branch", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("network-routing")
                        AppDivider()
                        NavigationLink { RouterLogDirectoryView() } label: { AppRow(title: "系统日志", detail: "系统 / 内核日志与筛选", symbol: "doc.text", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { RouterProcessesView() } label: { AppRow(title: "进程", detail: "详情与进程信号", symbol: "cpu", chevron: true) }.buttonStyle(.plain)
                    }
                }
                FirmwareMenuSection(group: "status", excluding: ["overview", "routesj", "routes", "logs", "processes"])
                AppSection(title: "最近活动", note: "本次会话记录，不代表路由器完整日志。") {
                    AppGroup {
                        if store.activities.isEmpty { AppRow(title: "暂无管理记录", symbol: "clock") }
                        else {
                            ForEach(store.activities.prefix(2)) { activity in
                                ActivityRow(activity: activity)
                                AppDivider(inset: 31)
                            }
                            NavigationLink { ActivityListView() } label: { AppRow(title: "查看全部活动", symbol: "clock", chevron: true) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    private var health: some View {
        NavigationLink { InterfaceDetailView() } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe").font(.system(size: 22))
                    .foregroundStyle(upstream == nil ? AppPalette.muted : AppPalette.green)
                    .frame(width: 40, height: 40)
                    .background(upstream == nil ? AppPalette.canvas : AppPalette.greenSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(upstream.map { "上联接口 · \($0.name)" } ?? "未报告可用默认路由").font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                    Text(upstream.map { $0.addresses.joined(separator: " · ") } ?? "查看接口状态、固件错误与读取权限").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    Text("默认路由存在不代表互联网可达").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppPalette.muted)
            }.padding(15).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityIdentifier("overview-wan")
    }
    private func overviewTile(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(AppPalette.accent).frame(width: 29)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                Text(detail).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 13))
    }
    private func quickItem(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(AppPalette.accent).frame(width: 21)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                Text(detail).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}

struct ResourceRow: View {
    let title: String
    let symbol: String
    let used: Int64?
    let total: Int64?
    var body: some View {
        if let used, let total, total > 0 {
            AppRow(title: title, detail: "已使用 \(Self.bytes(used)) · 总计 \(Self.bytes(total))", symbol: symbol, value: "\(Int(Double(used) / Double(total) * 100))%")
        } else { AppRow(title: title, detail: "路由器尚未提供数据", symbol: symbol, value: "—") }
    }
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }
}
