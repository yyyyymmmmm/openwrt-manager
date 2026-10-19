import SwiftUI

struct SystemScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var showDisconnectConfirmation = false
    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "系统", subtitle: "设备、日志、备份与维护") {
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
                        NavigationLink { ServicesScreen(showingRouterPicker: $showingRouterPicker) } label: { AppRow(title: "系统服务", detail: "查看服务与实例状态", symbol: "gearshape.2", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        managementLink(.logs)
                        AppDivider()
                        managementLink(.startup)
                    }
                }
                AppSection(title: "备份与设备维护") {
                    AppGroup {
                        managementLink(.backup)
                        AppDivider()
                        managementLink(.upgrade)
                        AppDivider()
                        managementLink(.reboot)
                    }
                }
                AppSection(title: "本机 App 设置") {
                    AppGroup {
                        NavigationLink { AppSettingsView() } label: { AppRow(title: "App 设置", detail: "外观、文字大小与隐私", symbol: "slider.horizontal.3", chevron: true) }
                            .buttonStyle(.plain).accessibilityIdentifier("appSettingsLink")
                        AppDivider()
                        Button { showingRouterPicker = true } label: { AppRow(title: "切换或添加路由器", symbol: "arrow.left.arrow.right", chevron: true) }.buttonStyle(.plain)
                        AppDivider()
                        Button { showDisconnectConfirmation = true } label: { AppRow(title: "断开连接", symbol: "wifi.slash", destructive: true) }
                            .buttonStyle(.plain).accessibilityIdentifier("disconnectRouterButton")
                    }
                }
            }
            .confirmationDialog("断开与 \(store.activeProfile?.name ?? "路由器") 的连接？", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) { store.disconnect() }
                Button("取消", role: .cancel) {}
            } message: { Text("这不会删除保存的地址或修改路由器设置。") }
        }
    }
    private func managementLink(_ kind: SystemManagementKind) -> some View {
        NavigationLink { SystemManagementView(kind: kind) } label: {
            AppRow(title: kind.title, detail: kind.detail, symbol: kind.symbol, badge: "LuCI", chevron: true)
        }.buttonStyle(.plain)
    }
}

enum SystemManagementKind {
    case logs, startup, backup, upgrade, reboot
    var title: String {
        switch self {
        case .logs: return "系统日志"
        case .startup: return "启动项与计划任务"
        case .backup: return "配置备份与恢复"
        case .upgrade: return "固件升级"
        case .reboot: return "重启路由器"
        }
    }
    var detail: String {
        switch self {
        case .logs: return "系统事件、内核日志与排障"
        case .startup: return "开机服务与定时执行"
        case .backup: return "导出配置、恢复备份与重置"
        case .upgrade: return "镜像校验与版本更新"
        case .reboot: return "结束运行并重新启动设备"
        }
    }
    var symbol: String {
        switch self {
        case .logs: return "doc.text"
        case .startup: return "clock"
        case .backup: return "arrow.down.to.line"
        case .upgrade: return "arrow.up.circle"
        case .reboot: return "power"
        }
    }
}

struct SystemManagementView: View {
    let kind: SystemManagementKind
    var body: some View {
        AppPage(title: kind.title, subtitle: kind.detail) {
            AppSection(title: "管理方式", note: "当前通过路由器的 LuCI 页面完成此操作。原生操作将在权限、任务状态和失败恢复机制接入后开放。") {
                AppGroup {
                    NavigationLink { RouterWebEntryView(page: .luci) } label: {
                        AppRow(title: "前往 LuCI 管理", symbol: "safari", chevron: true)
                    }.buttonStyle(.plain)
                }
            }
        }.appDetailStyle(kind.title)
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
