import SwiftUI
import OpenWrtKit

struct ServicesScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
            AppSection(title: "系统服务 · \(store.services.count)", note: "来源：procd service.list。未报告实例不等于服务已停止；运行实例也不代表业务健康。服务状态为只读。") {
                AppGroup {
                    if store.isRefreshing && !store.hasLoaded {
                        DataUnavailableView(title: "", message: "", error: nil, isLoading: true).padding(12)
                    } else if store.services.isEmpty {
                        ContentUnavailableView("没有服务状态", systemImage: "gearshape.2",
                                               description: Text("请确认当前版本提供 service.list，且账户允许访问。"))
                    } else {
                        ForEach(store.services) { service in
                            HStack(spacing: 10) {
                                Image(systemName: "gearshape")
                                    .foregroundStyle(service.runningInstances > 0 ? AppPalette.green : AppPalette.muted)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name).font(AppTypography.rowTitle)
                                    Text("\(service.runningInstances) / \(service.totalInstances) 个实例运行")
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                StatusBadge(title: service.totalInstances == 0 ? "状态未知" : service.runningInstances > 0 ? "有运行实例" : "无运行实例", good: service.runningInstances > 0)
                            }.padding(12)
                            if service.id != store.services.last?.id { AppDivider() }
                        }
                    }
                }
            }
        }.appDetailStyle("全部系统服务")
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
    }
}
