import SwiftUI

struct RootView: View {
    @Environment(RouterStore.self) private var store
    @State private var showingRouterPicker = false

    var body: some View {
        Group {
            if store.hasConnection {
                RouterTabs(showingRouterPicker: $showingRouterPicker)
                    .id(store.connectionID)
            } else {
                ConnectFlowView(isModal: false)
            }
        }
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
    }
}

private struct RouterTabs: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            OverviewScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("概览", systemImage: "square.grid.2x2") }
                .tag(0)

            SystemScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("系统", systemImage: "gearshape.2") }
                .tag(1)

            ServicesScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("服务", systemImage: "puzzlepiece.extension") }
                .tag(2)

            NetworkScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("网络", systemImage: "network") }
                .tag(3)

            SettingsScreen(showingRouterPicker: $showingRouterPicker)
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .tint(AppPalette.accent)
    }
}

struct ScreenToolbar: ToolbarContent {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    var includeRefresh = true

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if includeRefresh {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .accessibilityLabel("刷新路由器状态")
            }
            Button {
                showingRouterPicker = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("切换或添加路由器")
            .disabled(store.isMutating || store.pendingConfiguration != nil)
        }
    }
}

struct DataUnavailableView: View {
    let title: String
    let message: String
    let error: String?
    var isLoading = false
    var retry: (() -> Void)?

    var body: some View {
        if isLoading {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在读取路由器信息…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        } else if let error {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !message.isEmpty {
                    Text(message)
                        .font(AppTypography.secondary)
                        .foregroundStyle(.secondary)
                }
                if let retry {
                    Button("重试", action: retry)
                }
            }
            .padding(.vertical, 6)
        } else {
            ContentUnavailableView(title, systemImage: "tray", description: Text(message))
        }
    }
}

/// Every data screen identifies the source, its last successful read and any
/// newer failure. Retained data never looks like a successful live refresh.
struct DataStatusSection: View {
    @Environment(RouterStore.self) private var store
    let updatedAt: Date?
    let error: String?

    var body: some View {
        Section {
            if let profile = store.activeProfile {
                Label(profile.name, systemImage: "wifi.router")
                    .font(.subheadline.weight(.semibold))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if updatedAt != nil {
                    Text("显示上次成功读取的数据。请重试，或从右上角重新登录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("重新读取") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
            }
            if let updatedAt {
                LabeledContent("上次成功读取") {
                    Text(updatedAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if store.isRefreshing || !store.hasLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let storageError = store.storageError {
                Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
