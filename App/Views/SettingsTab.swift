import SwiftUI
import OpenWrtKit

/// Settings tab (spec 3.5): app-local only — router profiles and about.
/// Router settings never live here. Phase 1 ships profiles + about; the
/// remaining items (appearance cadence etc.) already live in App 设置 and
/// stay reachable from here without moving router concerns in.
struct SettingsTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var removeError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                Section("路由器档案") {
                    ForEach(store.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(profile.name).font(AppTypography.rowTitle)
                                Text(profile.address).font(AppTypography.secondary)
                                    .foregroundStyle(AppPalette.muted).lineLimit(1)
                            }
                            Spacer()
                            if store.defaultProfileID == profile.id {
                                StatusBadge(title: "默认", good: true)
                            }
                            if store.activeProfile?.id == profile.id {
                                StatusBadge(title: "当前连接", good: true)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                do { try store.remove(profile) }
                                catch { removeError = FriendlyError.message(error) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                store.setDefaultProfile(profile)
                            } label: {
                                Label("设为默认", systemImage: "star")
                            }
                            .tint(AppPalette.accent)
                        }
                    }
                    Button {
                        showingRouterPicker = true
                    } label: {
                        Label("添加或切换路由器", systemImage: "plus.circle")
                    }
                    if let removeError {
                        Text(removeError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                    }
                }
                Section("监控与告警") {
                    NavigationLink {
                        AlertSettingsView()
                    } label: {
                        Label("告警设置", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        EventLogView()
                    } label: {
                        Label("操作记录", systemImage: "list.bullet.rectangle")
                    }
                }
                Section("安全") {
                    AppLockToggleRow()
                    NavigationLink {
                        SSHTrustSettingsView()
                    } label: {
                        Label("SSH 主机指纹", systemImage: "fingerprint")
                    }
                }
                Section("应用") {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("App 设置（外观与文字）", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        AppAboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("诊断日志", systemImage: "waveform.path.ecg")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
