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
                    EmptyStateView(title: "无配置数据", message: "路由器上没有对应的配置内容。")
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
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        var loaded: [(String, RouterConfiguration)] = []
        var lastError: Error?
        for name in configNames {
            do { loaded.append((name, try await client.configuration(name))) }
            catch { lastError = error }
        }
        if loaded.isEmpty, let lastError {
            state = .failed(FriendlyError.message(lastError))
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
