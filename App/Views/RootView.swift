import SwiftUI
import OpenWrtKit

struct RootView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingRouterPicker = false
    @State private var monitoring = MonitoringService()
    @State private var appLock = AppLockController()
    @State private var sshTrust = SSHTrustStore.shared
    /// App Intents requests (package D): shortcuts record their ask
    /// on this bridge and open the app; the app executes through its
    /// own channels — refresh directly, reboot only after the
    /// in-app confirmation below.
    @ObservedObject private var intentBridge = RouterIntentBridge.shared
    @State private var showingIntentRebootConfirm = false
    @State private var intentActionError: String?

    var body: some View {
        ZStack {
            Group {
                if store.hasConnection {
                    RouterTabs(showingRouterPicker: $showingRouterPicker)
                        .id(store.connectionID)
                } else {
                    ConnectFlowView(isModal: false)
                }
            }
            // App lock (package C): while locked the management
            // content is replaced outright — nothing of any router
            // renders behind the lock face.
            if appLock.isLocked {
                LockScreenView()
            }
        }
        .environment(monitoring)
        .environment(EventLogStore.shared)
        .environment(appLock)
        .environment(sshTrust)
        .sheet(isPresented: $showingRouterPicker) {
            ConnectFlowView(isModal: true)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(get: { store.pendingConfiguration != nil }, set: { _ in })) {
            PendingConfigurationView().interactiveDismissDisabled()
        }
        .onChange(of: intentBridge.refreshRequested) { _, requested in
            guard requested else { return }
            intentBridge.refreshRequested = false
            Task { await store.refresh() }
        }
        .onChange(of: intentBridge.rebootRequested) { _, requested in
            guard requested else { return }
            intentBridge.rebootRequested = false
            if store.hasConnection {
                showingIntentRebootConfirm = true
            } else {
                intentActionError = L10n.string("尚未连接路由器，无法执行重启。请先在 App 中连接路由器。")
            }
        }
        .alert("快捷指令请求重启路由器", isPresented: $showingIntentRebootConfirm) {
            Button("立即重启", role: .destructive) {
                Task {
                    do { try await store.rebootRouter() }
                    catch { intentActionError = FriendlyError.message(error) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请求来自快捷指令。重启期间全屋网络将中断数分钟，正在进行的连接会断开。")
        }
        .alert("快捷指令执行失败", isPresented: Binding(
            get: { intentActionError != nil }, set: { if !$0 { intentActionError = nil } })) {
            Button("好", role: .cancel) { intentActionError = nil }
        } message: {
            Text(intentActionError ?? "")
        }
        .task(id: store.connectionID) {
            guard store.hasConnection else { return }
            await store.refresh()
        }
        // Package B monitoring: samples history + evaluates alerts
        // for the lifetime of this connection, reading only what the
        // store already fetched.
        .task(id: store.connectionID) {
            await monitoring.run(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundSampler.schedule() }
            switch phase {
            case .active: appLock.handleScenePhase(.active)
            case .inactive: appLock.handleScenePhase(.inactive)
            case .background: appLock.handleScenePhase(.background)
            @unknown default: break
            }
            if appLock.isLocked { showingRouterPicker = false }
        }
        // Language changes (system or per-app) re-run the refresh,
        // whose language gate re-discovers when the snapshot's
        // language no longer matches — no manual refresh needed for
        // pages to follow the new language.
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            L10n.syncKitLanguage()
            Task { await store.refresh() }
        }
    }
}

/// The five tabs of the structure spec: overview / network / services /
/// system / settings. Their contents are generated from the discovery
/// snapshot by PageRegistry; this view only fixes the tab shell.
private struct RouterTabs: View {
    @Binding var showingRouterPicker: Bool
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            OverviewTabScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("概览", systemImage: "square.grid.2x2") }
                .tag(0)

            NetworkTabScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("网络", systemImage: "network") }
                .tag(1)

            ServicesTabScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("服务", systemImage: "server.rack") }
                .tag(2)

            SystemTabScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("系统", systemImage: "cpu") }
                .tag(3)

            SettingsTabScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        // iPad form (package D): sidebarAdaptable is the platform's
        // own answer — a sidebar on regular-width iPad (portrait and
        // landscape), the familiar tab bar on iPhone — instead of a
        // hand-rolled split view duplicating the tab shell.
        .tabViewStyle(.sidebarAdaptable)
        .tint(AppPalette.accent)
    }
}
