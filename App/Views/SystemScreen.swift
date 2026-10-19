import SwiftUI

struct SystemScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "系统", subtitle: "固件信息、运行状态与系统记录") {
                ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
                NavigationLink { SystemInformationView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.router").font(.system(size: 26)).foregroundStyle(AppPalette.accent)
                            .frame(width: 48, height: 48).background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.snapshot?.system.model ?? "路由器信息尚未读取").font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                            Text(store.snapshot?.system.firmware ?? "固件版本尚未读取").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                    }.padding(14).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain)
                AppSection(title: "运行与诊断") {
                    AppGroup {
                        NavigationLink { SystemInformationView() } label: { AppRow(title: "系统状态", detail: "负载、内存、存储与运行时间", symbol: "chart.bar", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { RouterRecordsView(kind: .logs) } label: { AppRow(title: "系统日志", symbol: "doc.text", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { RouterRecordsView(kind: .processes) } label: { AppRow(title: "运行进程", symbol: "cpu", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { RouterRecordsView(kind: .mounts) } label: { AppRow(title: "存储挂载", symbol: "externaldrive", chevron: true) }.buttonStyle(.plain)
                    }
                }
                AppSection(title: "系统配置") {
                    AppGroup {
                        ForEach(store.inventory.configNames.filter { ["system", "dropbear", "uhttpd", "rpcd", "fstab", "luci"].contains($0) }, id: \.self) { name in
                            NavigationLink { ConfigurationEditorView(name: name) } label: { AppRow(title: name, symbol: "slider.horizontal.3", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("system-config-\(name)")
                            if name != store.inventory.configNames.filter({ ["system", "dropbear", "uhttpd", "rpcd", "fstab", "luci"].contains($0) }).last { AppDivider() }
                        }
                        if store.inventory.configNames.filter({ ["system", "dropbear", "uhttpd", "rpcd", "fstab", "luci"].contains($0) }).isEmpty {
                            Text(store.inventory.configsRead ? "路由器未报告系统配置文件" : "配置目录尚未读取")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12)
                        }
                    }
                }
            }
        }
    }
}

struct SystemInformationView: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
            AppSection(title: "设备信息") {
                AppGroup {
                    AppRow(title: "主机名", value: store.snapshot?.system.hostname ?? "—")
                    AppDivider(inset: 12)
                    AppRow(title: "设备型号", value: store.snapshot?.system.model ?? "—")
                    AppDivider(inset: 12)
                    AppRow(title: "固件版本", value: store.snapshot?.system.firmware ?? "—")
                    AppDivider(inset: 12)
                    AppRow(title: "内核", value: store.snapshot?.system.kernel ?? "—")
                    AppDivider(inset: 12)
                    AppRow(title: "架构", value: store.snapshot?.system.architecture ?? "—")
                }
            }
            AppSection(title: "运行状态") {
                AppGroup {
                    AppRow(title: "运行时间", symbol: "clock", value: store.snapshot?.system.uptime.map(Self.duration) ?? "—")
                    AppDivider()
                    ResourceRow(title: "内存", symbol: "memorychip", used: store.snapshot?.system.memoryUsed, total: store.snapshot?.system.memoryTotal)
                    AppDivider()
                    ResourceRow(title: "存储", symbol: "externaldrive", used: store.snapshot?.system.storageUsed, total: store.snapshot?.system.storageTotal)
                }
            }
            if let profile = store.activeProfile {
                AppSection(title: "连接信息") {
                    AppGroup {
                        AppRow(title: "路由器", value: profile.name)
                        AppDivider(inset: 12)
                        AppRow(title: "管理地址", value: profile.address)
                        AppDivider(inset: 12)
                        AppRow(title: "登录用户", value: profile.username)
                    }
                }
            }
        }.appDetailStyle("系统状态").textSelection(.enabled)
    }
    private static func duration(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        return "\(hours) 小时 \(minutes) 分钟"
    }
}
