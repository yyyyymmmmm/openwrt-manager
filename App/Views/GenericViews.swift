import SwiftUI
import OpenWrtKit

/// The generic UCI page: any configuration rendered as structured
/// sections and rows, read-only. Pages reached through the fallback carry
/// a visible 「通用页」 marker (spec 3.3) — a generic page never pretends
/// to be a dedicated one.
struct UCIConfigView: View {
    @Environment(RouterStore.self) private var store
    let title: String
    let configNames: [String]
    var sectionTypeFilter: String? = nil
    var isGenericFallback = false
    @State private var state: LoadState<[(String, RouterConfiguration)]> = .loading
    /// Set when every requested config was refused by rpcd (not granted
    /// to login sessions) or does not exist: the page then degrades to
    /// an explanatory empty state instead of an error card with a retry
    /// button that can never succeed.
    @State private var unavailableHint: String?

    var body: some View {
        List {
            if isGenericFallback {
                Section {
                    Label("通用页：此功能暂无专用页面，以下为路由器配置的结构化只读视图。", systemImage: "info.circle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
            switch state {
            case .loading:
                ProgressView("正在读取配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configurations):
                let rendered = configurations.flatMap { name, configuration in
                    (sectionTypeFilter.map { GenericPageModel.sections(from: configuration, type: $0) }
                        ?? GenericPageModel.sections(from: configuration))
                        .map { (name, $0) }
                }
                if rendered.isEmpty {
                    EmptyStateView(title: "无配置数据",
                                   message: unavailableHint ?? "路由器上没有对应的配置内容。")
                } else {
                    ForEach(rendered, id: \.1.id) { name, section in
                        Section(configurations.count > 1 ? "\(name) · \(section.title)" : section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.key, value: row.valueText)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if configNames.count == 1, let name = configNames.first {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ConfigEditorView(configName: name, title: title)
                    } label: {
                        Label("编辑", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        unavailableHint = nil
        var loaded: [(String, RouterConfiguration)] = []
        var lastError: Error?
        var accessRefusedOnly = true
        for name in configNames {
            do { loaded.append((name, try await client.configuration(name))) }
            catch let error as OpenWrtKitError {
                lastError = error
                switch error {
                case .permissionDenied, .unsupported: break
                default: accessRefusedOnly = false
                }
            } catch { lastError = error; accessRefusedOnly = false }
        }
        if loaded.isEmpty, let lastError {
            if accessRefusedOnly {
                // rpcd does not grant this config to login sessions (or
                // it does not exist): retrying cannot help, so say so
                // plainly instead of presenting a failure.
                unavailableHint = "此固件未向 App 会话开放该配置的读取（rpcd 未授权或配置不存在），本页已降级为说明展示。"
                state = .loaded(loaded)
            } else {
                state = .failed(FriendlyError.message(lastError))
            }
        } else {
            state = .loaded(loaded)
        }
    }
}

/// Generic service page: real state from the discovery snapshot plus the
/// service's UCI configuration in structured form. Enable/start controls
/// are phase-2 transaction work and deliberately absent here.
struct GenericServiceView: View {
    @Environment(RouterStore.self) private var store
    let page: PageDescriptor

    private var service: CapabilitySnapshot.CapabilityService? {
        store.capability?.services.first { $0.key == page.serviceKey }
    }

    var body: some View {
        Group {
            if let service {
                List {
                    Section {
                        Label("通用页：此服务暂无专用页面，以下为状态与配置的结构化只读视图。", systemImage: "info.circle")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    Section("状态") {
                        LabeledContent("运行状态", value: service.running.map { $0 ? "运行中" : "已停止" } ?? "未知")
                        LabeledContent("开机自启", value: service.enabled.map { $0 ? "已启用" : "未启用" } ?? "未知")
                        if !service.initNames.isEmpty {
                            LabeledContent("init.d 服务", value: service.initNames.joined(separator: "、"))
                        }
                        LabeledContent("来源", value: service.source == .initFallback ? "init.d 核心服务" : "菜单 ∩ init.d")
                    }
                    if let initName = service.initNames.first {
                        ServiceActionsSection(serviceName: initName)
                    }
                }
            } else {
                EmptyStateView(title: "服务不存在", message: "发现快照中没有此服务，可能已被移除。")
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    UCIConfigView(title: "\(page.title) 配置", configNames: page.configNames,
                                  isGenericFallback: true)
                } label: {
                    Text("配置")
                }
            }
        }
    }
}

/// Service actions for one init.d service, each behind a confirmation and
/// executed through the store's service-action transaction (snapshot ->
/// perform -> re-read -> verify).
struct ServiceActionsSection: View {
    @Environment(RouterStore.self) private var store
    let serviceName: String
    @State private var pendingAction: ServiceAction?
    @State private var result: String?
    @State private var working = false

    var body: some View {
        Section("操作") {
            ForEach(ServiceAction.allCases) { action in
                Button {
                    pendingAction = action
                } label: {
                    Label(action.title, systemImage: Self.symbol(for: action))
                }
                .disabled(working || store.isMutating)
            }
            if working { HStack { ProgressView(); Text("正在执行…") } }
            if let result {
                Text(result).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        .confirmationDialog(
            pendingAction.map { "确认\($0.title)「\(serviceName)」？" } ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingAction?.title ?? "确认") {
                if let action = pendingAction { Task { await run(action) } }
                pendingAction = nil
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        }
    }

    private static func symbol(for action: ServiceAction) -> String {
        switch action {
        case .start: return "play.circle"
        case .stop: return "stop.circle"
        case .restart: return "arrow.triangle.2.circlepath"
        case .enable: return "checkmark.circle"
        case .disable: return "xmark.circle"
        }
    }

    private func run(_ action: ServiceAction) async {
        working = true
        defer { working = false }
        do {
            try await store.performServiceAction(name: serviceName, action: action)
            result = "已执行\(action.title)，状态已重新读取。"
        } catch {
            result = FriendlyError.message(error)
        }
    }
}

/// Fallback for a discovered menu node with no dedicated or UCI page yet:
/// states plainly what was discovered instead of faking an entrance.
struct GenericMenuPageView: View {
    let page: PageDescriptor

    var body: some View {
        List {
            Section {
                Label("通用页：已发现此菜单，专用页面尚未提供。以下为发现信息。", systemImage: "info.circle")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
            Section("发现信息") {
                LabeledContent("名称", value: page.title)
                if let path = page.menuPath {
                    LabeledContent("菜单路径", value: path)
                }
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
