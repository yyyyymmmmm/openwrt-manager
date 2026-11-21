import SwiftUI
import UIKit
import OpenWrtKit

/// Alert settings (package B, item 2): per-rule switches and
/// thresholds over AlertCenter's persisted settings, the notification
/// permission state handled the standard way (ask on first entry,
/// deep-link to Settings when denied), and the honest note about
/// background sampling limits.
struct AlertSettingsView: View {
    @Environment(MonitoringService.self) private var monitoring
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var alerts = monitoring.alerts
        List {
            Section {
                permissionRow(alerts: alerts)
            } header: {
                Text("通知")
            } footer: {
                Text("告警通过本地通知发出，不经过任何服务器。")
            }

            Section("规则") {
                Toggle("路由器离线 / 恢复", isOn: $alerts.settings.offlineEnabled)
                Toggle("WAN 断开 / 恢复", isOn: $alerts.settings.wanEnabled)
                Toggle("新设备接入", isOn: $alerts.settings.newDeviceEnabled)
                Toggle("系统负载过高", isOn: $alerts.settings.loadEnabled)
                if alerts.settings.loadEnabled {
                    Stepper(value: $alerts.settings.loadThreshold, in: 0.5...8, step: 0.5) {
                        LabeledContent("负载阈值（1 分钟平均）",
                                       value: String(format: "%.1f", alerts.settings.loadThreshold))
                    }
                }
                Toggle("内存占用过高", isOn: $alerts.settings.memoryEnabled)
                if alerts.settings.memoryEnabled {
                    Stepper(value: $alerts.settings.memoryThreshold, in: 50...99, step: 1) {
                        LabeledContent("内存阈值", value: L10n.format("%.0f%%", alerts.settings.memoryThreshold))
                    }
                }
            }

            Section {
                LabeledContent("持续超阈多久后告警", value: L10n.format("%lld 分钟", Int(alerts.settings.sustain / 60)))
                LabeledContent("同类告警冷却", value: L10n.format("%lld 分钟", Int(alerts.settings.cooldown / 60)))
                NavigationLink {
                    EventLogView()
                } label: {
                    Label("事件记录", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("节奏与记录")
            } footer: {
                Text("负载与内存需持续超阈才告警，避免瞬时尖峰打扰；离线与 WAN 需连续两次确认。触发与恢复成对通知，同类告警在冷却期内不重复。")
            }

            Section {
                Text("前台打开 App 时每 30 秒评估一次。App 在后台时由 iOS 决定何时唤醒采样（BGAppRefreshTask），可能间隔数小时，也可能不发生——离线告警以后台尽力而为为准，不能替代路由器自身的可用性保障。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            } header: {
                Text("后台限制")
            }
        }
        .navigationTitle("告警设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await monitoring.alerts.refreshAuthorization()
            if monitoring.alerts.authorization == .notDetermined {
                await monitoring.alerts.requestAuthorization()
            }
        }
    }

    @ViewBuilder
    private func permissionRow(alerts: AlertCenter) -> some View {
        switch alerts.authorization {
        case .authorized, .provisional, .ephemeral:
            LabeledContent("通知权限", value: L10n.string("已允许"))
        case .denied:
            HStack {
                Text("通知权限")
                Spacer()
                Button("去系统设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .foregroundStyle(AppPalette.accent)
            }
        default:
            HStack {
                Text("通知权限")
                Spacer()
                Button("允许通知") {
                    Task { await alerts.requestAuthorization() }
                }
                .foregroundStyle(AppPalette.accent)
            }
        }
    }
}

/// The event record: operations and alerts in one chronological
/// list, read from the shared EventLogStore. Package C grows this
/// into the full records surface; this list is its read-only core.
struct EventLogView: View {
    @Environment(EventLogStore.self) private var events
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            let entries = events.log.recent(routerID: store.activeProfile?.id.uuidString)
            if entries.isEmpty {
                EmptyStateView(title: "暂无事件", message: "操作与告警会记录在这里。", symbol: "list.bullet.rectangle")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack(spacing: AppSpacing.sm) {
                            Text(L10n.key(entry.title)).font(AppTypography.rowTitle)
                            Spacer()
                            StatusBadge(title: categoryTitle(entry.category),
                                        good: entry.category == .operation)
                        }
                        if !entry.detail.isEmpty {
                            Text(L10n.key(entry.detail)).font(AppTypography.secondary)
                                .foregroundStyle(AppPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(entry.at, format: .dateTime.month().day().hour().minute())
                            .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
        .navigationTitle("事件记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryTitle(_ category: StoredEvent.Category) -> String {
        switch category {
        case .operation: return L10n.string("操作")
        case .alert: return L10n.string("告警")
        case .system: return L10n.string("系统")
        }
    }
}
