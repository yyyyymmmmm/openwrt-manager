import SwiftUI

struct SystemScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "系统", subtitle: "系统设置、管理权限与维护") {
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
                InventoryStatus()
                AppSection(title: "系统") {
                    AppGroup {
                        NativeConfigurationLink(schema: .system, symbol: "gearshape")
                        AppDivider()
                        NavigationLink { RouterAdministrationView() } label: { AppRow(title: "管理权", detail: "SSH 访问设置", symbol: "lock.shield", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { PackagesView() } label: { AppRow(title: "软件包", detail: "已安装软件与依赖", symbol: "shippingbox", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        NavigationLink { ServiceDirectoryView() } label: { AppRow(title: "启动项", detail: "运行实例、启停与开机启动", symbol: "gearshape.2", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("services-directory")
                        AppDivider()
                        NavigationLink { RouterRecordsView(kind: .mounts) } label: { AppRow(title: "挂载记录", detail: "只读存储挂载信息", symbol: "externaldrive", chevron: true) }.buttonStyle(.plain)
                    }
                }
                FirmwareMenuSection(group: "system", excluding: ["system", "admin", "package-manager", "startup"])

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
