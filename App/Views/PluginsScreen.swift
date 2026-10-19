import SwiftUI
import SafariServices
import OpenWrtKit

struct PluginsScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    private var recognized: [RecognizedPluginService] { PluginCatalog.recognize(store.services) }

    var body: some View {
        NavigationStack {
            List {
                DataStatusSection(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
                Section {
                    if store.isRefreshing && !store.hasLoaded {
                        ProgressView("正在读取服务…")
                    } else if let error = store.servicesError, store.services.isEmpty {
                        DataUnavailableView(title: "无法识别插件服务", message: "", error: error,
                                            retry: { Task { await store.refresh() } })
                    } else if recognized.isEmpty {
                        ContentUnavailableView("暂无已识别服务", systemImage: "puzzlepiece.extension",
                                               description: Text("未匹配到服务不等于未安装插件。可在 LuCI 中查看完整功能。"))
                    } else {
                        ForEach(recognized) { plugin in
                            NavigationLink {
                                PluginServiceDetail(plugin: plugin)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(plugin.title).font(AppTypography.rowTitle)
                                    Text("\(plugin.category) · \(plugin.service.runningInstances) / \(plugin.service.totalInstances) 个实例运行")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } header: {
                    Text("已识别的插件服务")
                } footer: {
                    Text("来源：procd service.list。仅表示服务可见，不证明插件版本、配置生效或业务健康。")
                }
                Section("管理入口") {
                    ForEach(RouterWebPage.allCases) { page in
                        NavigationLink(page.title) { RouterWebEntryView(page: page) }
                    }
                    NavigationLink("全部系统服务") {
                        ServicesScreen(showingRouterPicker: $showingRouterPicker)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
        }
    }
}

private struct PluginServiceDetail: View {
    @Environment(RouterStore.self) private var store
    let plugin: RecognizedPluginService

    var body: some View {
        List {
            DataStatusSection(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
            Section("服务证据") {
                LabeledContent("服务名称", value: plugin.id)
                if let current = store.services.first(where: { $0.id == plugin.id }) {
                    LabeledContent("运行实例", value: "\(current.runningInstances) / \(current.totalInstances)")
                } else {
                    Text("最新服务列表中未找到此服务").foregroundStyle(.secondary)
                }
                LabeledContent("插件版本", value: "尚未读取")
                LabeledContent("原生配置适配", value: "尚未接入")
            }
            Section {
                NavigationLink("前往 LuCI 管理") { RouterWebEntryView(page: .luci) }
            } footer: {
                Text("不同插件和固件的配置接口不同；原生配置入口通过版本和权限验证后才会开放。")
            }
        }
        .navigationTitle(plugin.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RouterWebEntryView: View {
    @Environment(RouterStore.self) private var store
    let page: RouterWebPage
    @State private var showingBrowser = false

    private var url: URL? {
        guard let profile = store.activeProfile,
              let address = try? URLNormalizer.normalize(profile.address) else { return nil }
        return page.url(address: address)
    }

    var body: some View {
        List {
            Section {
                Label(page.title, systemImage: "safari")
                    .font(.headline)
                if let url {
                    Text(url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if page == .istore {
                    Text("需要路由器已安装兼容的 iStore。支持情况取决于固件、架构、软件源和 iStore 版本。")
                } else if page == .packages {
                    Text("软件包页面取决于固件的 LuCI 版本及 opkg / apk 支持。")
                }
                Button("打开管理网页", systemImage: "arrow.up.right.square") {
                    showingBrowser = true
                }
                .disabled(url == nil)
                .accessibilityIdentifier("openRouterWebButton")
            } footer: {
                Text(store.isDemo ? "演示模式没有真实路由器，无法打开管理页面。" : "网页使用独立登录，不自动传入 App 的密码或会话。系统浏览器独立验证 HTTPS 证书。页面不存在时可返回 LuCI 首页。")
            }
            if page != .luci {
                Section {
                    NavigationLink("LuCI 首页") { RouterWebEntryView(page: .luci) }
                }
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBrowser) {
            if let url { RouterBrowser(url: url).ignoresSafeArea() }
        }
    }
}

private struct RouterBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
