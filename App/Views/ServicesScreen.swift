import SwiftUI
import OpenWrtKit

struct ServicesScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var query = ""
    private var names: [String] {
        Set(store.inventory.initServices.map(\.name) + store.services.map(\.name)).sorted()
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            Section { InventoryStatus(); ReadStatus(updatedAt: store.servicesUpdatedAt, error: store.servicesError) }
            Section(store.inventory.initRead && store.servicesUpdatedAt != nil && store.servicesError == nil ? "服务与启动项 · \(names.count)" : "已读取的服务与启动项") {
                ForEach(names, id: \.self) { name in
                    NavigationLink { ServiceDetailView(name: name) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(AppTypography.rowTitle)
                            if let service = store.services.first(where: { $0.name == name }) {
                                Text(service.instanceSummary).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            } else { Text("未报告运行实例").font(AppTypography.secondary).foregroundStyle(AppPalette.muted) }
                        }
                    }
                }
            }
        }.searchable(text: $query, prompt: "搜索服务").appDetailStyle("全部系统服务")
            .refreshable { await store.refresh() }.tint(AppPalette.accent)
    }
}

struct ServiceDetailView: View {
    @Environment(RouterStore.self) private var store
    let name: String
    @State private var selectedAction: ServiceAction?
    @State private var error: String?
    @State private var result: String?
    private var startup: InitService? { store.inventory.initServices.first { $0.name == name } }
    private var service: RouterService? { store.services.first { $0.name == name } }
    var body: some View {
        Form {
            Section {
                ReadStatus(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
                LabeledContent("运行实例", value: service?.instanceSummary ?? "未报告")
                LabeledContent("开机启动", value: (startup?.enabled).map { $0 ? "启用" : "关闭" } ?? "未知")
            } header: { Text("当前状态") } footer: { Text("未报告实例不等于服务已停止；实例运行也不代表业务健康。") }
            if let error { Section { Text(error).foregroundStyle(AppPalette.red) } }
            if let result { Section { Label(result, systemImage: "checkmark.circle").foregroundStyle(AppPalette.green) } }
            Section("服务操作") {
                if store.isMutating { ProgressView("正在执行…") }
                ForEach(ServiceAction.allCases) { action in
                    Button(action.title, systemImage: symbol(action), role: action == .stop || action == .disable ? .destructive : nil) { selectedAction = action }
                }
            }.disabled(startup == nil || store.isMutating || store.pendingConfiguration != nil)
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(name)
            .confirmationDialog("\(selectedAction?.title ?? "操作") \(name)？", isPresented: Binding(get: { selectedAction != nil }, set: { if !$0 { selectedAction = nil } }), titleVisibility: .visible) {
                if let action = selectedAction {
                    Button("确认\(action.title)", role: action == .stop || action == .disable ? .destructive : nil) {
                        Task {
                            error = nil; result = nil
                            do { try await store.performServiceAction(name: name, action: action); result = "路由器已确认执行\(action.title)，请核对当前状态。" }
                            catch { self.error = FriendlyError.message(error) }
                        }
                    }
                }
                Button("取消", role: .cancel) { selectedAction = nil }
            } message: { Text("可能中断网络或管理连接。操作完成后会重新读取服务状态。") }
    }
    private func symbol(_ action: ServiceAction) -> String {
        switch action {
        case .start: return "play"
        case .stop: return "stop"
        case .restart: return "arrow.clockwise"
        case .enable: return "power"
        case .disable: return "poweroff"
        }
    }
}

private extension RouterService {
    var instanceSummary: String {
        guard let totalInstances else { return "运行实例未报告" }
        guard let runningInstances else { return "共 \(totalInstances) 个实例 · 运行数量未报告" }
        return "\(runningInstances) / \(totalInstances) 个实例运行"
    }
}
