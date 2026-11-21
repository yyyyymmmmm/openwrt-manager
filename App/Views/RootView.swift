import SwiftUI
import OpenWrtKit

struct RootView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingRouterPicker = false
    @State private var monitoring = MonitoringService()

    var body: some View {
        Group {
            if store.hasConnection {
                RouterTabs(showingRouterPicker: $showingRouterPicker)
                    .id(store.connectionID)
            } else {
                ConnectFlowView(isModal: false)
            }
        }
        .environment(monitoring)
        .environment(EventLogStore.shared)
        .sheet(isPresented: $showingRouterPicker) {
            ConnectFlowView(isModal: true)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(get: { store.pendingConfiguration != nil }, set: { _ in })) {
            PendingConfigurationView().interactiveDismissDisabled()
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
        .tint(AppPalette.accent)
    }
}
