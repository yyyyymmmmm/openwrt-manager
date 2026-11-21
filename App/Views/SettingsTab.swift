import SwiftUI
import OpenWrtKit

/// Settings tab (spec 3.5): app-local only — router profiles and about.
/// Router settings never live here. Phase 1 ships profiles + about; the
/// remaining items (appearance cadence etc.) already live in App 设置 and
/// stay reachable from here without moving router concerns in.
///
/// Package K: a profile row's tap IS the switch — Face ID gate, saved
/// credential, connected — the way Termius and 1Password treat a saved
/// host. Editing (name / account / password) lives behind the swipe
/// and long-press actions, not on the tap.
struct SettingsTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var removeError: String?
    @State private var removalTarget: RouterProfile?
    @State private var quickConnect = QuickConnectModel()
    @State private var loginRoute: LoginRoute?

    /// The two ways the login form opens from here: editing a
    /// profile (gate passed, saved password may prefill) and manual
    /// entry (gate refused/unavailable or no saved password — the
    /// form never prefills in this mode).
    private enum LoginRoute: Identifiable, Hashable {
        case edit(RouterProfile)
        case manual(RouterProfile)

        var id: String {
            switch self {
            case .edit(let profile): return "edit-\(profile.id.uuidString)"
            case .manual(let profile): return "manual-\(profile.id.uuidString)"
            }
        }
        var profile: RouterProfile {
            switch self {
            case .edit(let profile), .manual(let profile): return profile
            }
        }
        var isManual: Bool {
            if case .manual = self { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                Section("路由器档案") {
                    ForEach(store.profiles) { profile in
                        profileRow(profile)
                    }
                    Button {
                        showingRouterPicker = true
                    } label: {
                        Label("添加路由器", systemImage: "plus.circle")
                    }
                    Text("点按档案即可切换连接；使用保存的密码前，会先以 Face ID 验证身份。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
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
                    BiometricStatusRow()
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
            .navigationDestination(item: $loginRoute) { route in
                RouterLoginView(address: route.profile.address, existingProfile: route.profile,
                                manualPasswordEntry: route.isManual)
            }
            .onChange(of: quickConnect.manualEntryProfile) { _, profile in
                if let profile {
                    loginRoute = .manual(profile)
                    quickConnect.manualEntryProfile = nil
                }
            }
            .quickConnectCertificateAlert(model: quickConnect, store: store)
            // Same confirmation as the connection page's long-press
            // delete (audit U19): one removal, one wording — the
            // swipe no longer deletes silently.
            .alert(item: $removalTarget) { profile in
                Alert(title: Text("删除保存的路由器？"),
                      message: Text("“\(profile.name)”及其本机凭据会从此设备移除。不会修改路由器设置。"),
                      primaryButton: .destructive(Text("删除")) {
                          do { try store.remove(profile) }
                          catch { removeError = FriendlyError.message(error) }
                      }, secondaryButton: .cancel())
            }
        }
    }

    /// One profile row: the whole row is the switch button, with
    /// the connection state rendered in place — connecting spinner
    /// while the switch runs, the failure reason (in human words)
    /// under the row when it fails, and a plain tap to retry.
    @ViewBuilder
    private func profileRow(_ profile: RouterProfile) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button {
                Task { await quickConnect.tap(profile, store: store) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(profile.name).font(AppTypography.rowTitle)
                        Text(profile.address).font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.muted).lineLimit(1)
                    }
                    Spacer()
                    if quickConnect.isConnecting(profile) {
                        ProgressView()
                        Text("正在连接…").font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.muted)
                    } else {
                        if store.defaultProfileID == profile.id {
                            StatusBadge(title: "默认", good: true)
                        }
                        if store.activeProfile?.id == profile.id {
                            StatusBadge(title: "当前连接", good: true)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let failure = quickConnect.failure(for: profile) {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                removalTarget = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                beginEdit(profile)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(AppPalette.accent)
        }
        .swipeActions(edge: .leading) {
            Button {
                store.setDefaultProfile(profile)
            } label: {
                Label("设为默认", systemImage: "star")
            }
            .tint(AppPalette.accent)
        }
        .contextMenu {
            if store.activeProfile?.id != profile.id {
                Button {
                    Task { await quickConnect.tap(profile, store: store) }
                } label: {
                    Label("切换到此路由器", systemImage: "arrow.triangle.swap")
                }
            }
            Button {
                beginEdit(profile)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                store.setDefaultProfile(profile)
            } label: {
                Label("设为默认", systemImage: "star")
            }
            Button(role: .destructive) {
                removalTarget = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// Editing shows the saved password (masked) and can replace
    /// the account credentials, so it passes the same gate as a
    /// switch; a refused or unavailable check degrades to the
    /// manual form instead of locking the user out of editing.
    private func beginEdit(_ profile: RouterProfile) {
        Task {
            switch await CredentialGate.authorize(reason: CredentialGate.savedPasswordReason) {
            case .authorized:
                loginRoute = .edit(profile)
            case .refused, .unavailable:
                loginRoute = .manual(profile)
            }
        }
    }
}
