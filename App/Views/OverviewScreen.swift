import SwiftUI
import OpenWrtKit

struct OverviewScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    private var wan: NetworkInterfaceSnapshot? {
        store.snapshot?.interfaces.first { $0.name.lowercased() == "wan" }
    }
    private var loadAverage: String {
        guard let values = store.snapshot?.system.loadAverage, !values.isEmpty else { return "尚未读取" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "概览",
                        subtitle: store.isDemo ? "家庭网络 · 当前显示演示数据" : "家庭网络 · 路由器状态与管理") {
                ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
                health
                HStack(spacing: 8) {
                    NavigationLink { WirelessDetailView() } label: {
                        overviewTile("Wi-Fi 状态", store.wirelessUpdatedAt == nil ? "尚未读取" : "\(store.radios.count) 个无线电", "wifi")
                    }
                    NavigationLink { DevicesContent() } label: {
                        overviewTile("设备状态", store.devicesUpdatedAt == nil ? "尚未读取" : "\(store.leases.count) 条 DHCP 租约", "desktopcomputer")
                    }
                }.buttonStyle(.plain).padding(.top, 9)
                AppSection(title: "常用管理") {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            NavigationLink { WirelessDetailView() } label: { quickItem("无线网络", "名称、信道与广播", "wifi") }
                            NavigationLink { NetworkManagementView(task: .firewall) } label: { quickItem("防火墙", "区域与端口规则", "checkmark.shield") }
                        }
                        AppDivider(inset: 12)
                        HStack(spacing: 0) {
                            NavigationLink { PluginDirectoryView() } label: { quickItem("插件中心", "服务、软件包、iStore", "puzzlepiece.extension") }
                            NavigationLink { SystemManagementView(kind: .backup) } label: { quickItem("配置备份", "导出与恢复", "arrow.down.to.line") }
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
        NavigationLink { InterfaceDetailView(scope: "wan") } label: {
            VStack(spacing: 11) {
                HStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 22))
                        .foregroundStyle(wan?.up == true ? AppPalette.green : AppPalette.muted)
                        .frame(width: 40, height: 40)
                        .background(wan?.up == true ? AppPalette.greenSoft : AppPalette.canvas, in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(wan.map { $0.up ? "WAN 接口已连接" : "WAN 接口未连接" } ?? "WAN 状态尚未读取").font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                        Text("互联网可达性尚未检测").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                }
                AppDivider(inset: 0)
                HStack {
                    speedSlot("下载")
                    Rectangle().fill(AppPalette.line).frame(width: 0.5, height: 31)
                    speedSlot("上传")
                    Text("速率未接入").font(AppTypography.chrome).foregroundStyle(AppPalette.muted)
                }.padding(.top, 1)
            }.padding(15).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func speedSlot(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("—").font(AppTypography.title).foregroundStyle(AppPalette.text)
                Text("Mb/s").font(AppTypography.chrome).foregroundStyle(AppPalette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
