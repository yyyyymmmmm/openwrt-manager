import SwiftUI
import OpenWrtKit

struct ServicesScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
            List {
                DataStatusSection(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
                Section {
                    if store.isRefreshing && !store.hasLoaded {
                        DataUnavailableView(title: "", message: "", error: nil, isLoading: true)
                    } else if let error = store.servicesError, store.services.isEmpty {
                        DataUnavailableView(
                            title: "无法读取服务",
                            message: "路由器可能没有 service.list 接口，或账户 ACL 不允许访问。",
                            error: error,
                            isLoading: store.isRefreshing && !store.hasLoaded,
                            retry: { Task { await store.refresh() } }
                        )
                    } else if store.services.isEmpty {
                        ContentUnavailableView(
                            "没有服务状态",
                            systemImage: "gearshape.2",
                            description: Text("请确认当前 OpenWrt 版本提供 ubus service.list。")
                        )
                    } else {
                        ForEach(store.services) { service in
                            HStack(spacing: 12) {
                                Image(systemName: service.runningInstances > 0 ? "gearshape.fill" : "gearshape")
                                    .foregroundStyle(service.runningInstances > 0 ? .green : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name)
                                        .font(AppTypography.rowTitle)
                                    Text("\(service.runningInstances) / \(service.totalInstances) 个实例运行")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(service.totalInstances == 0 ? "状态未知" : service.runningInstances > 0 ? "有运行实例" : "无运行实例")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(service.runningInstances > 0 ? .green : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("系统服务 · \(store.services.count)")
                } footer: {
                    Text("来源：procd service.list。未报告实例不等于服务已停止；运行实例也不代表业务健康。服务状态为只读。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
    }
}
