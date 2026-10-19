import SwiftUI
import SafariServices
import OpenWrtKit

struct PluginsScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "插件", subtitle: "服务、扩展与软件包") {
                PluginCollection()
            }
        }
    }
}

struct PluginDirectoryView: View {
    var body: some View {
        AppPage(title: "插件", subtitle: "服务、扩展与软件包") { PluginCollection() }.appDetailStyle("插件中心")
    }
}

private struct PluginCollection: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""
    @State private var onlyRunning = false
    private var recognized: [RecognizedPluginService] { PluginCatalog.recognize(store.services) }
    private var filtered: [RecognizedPluginService] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return recognized.filter {
            (!onlyRunning || $0.service.runningInstances > 0) &&
            (trimmed.isEmpty || ($0.title + $0.id + $0.category).localizedCaseInsensitiveContains(trimmed))
        }
    }
    private var categories: [String] { Array(Set(filtered.map(\.category))).sorted() }
    var body: some View {
        ReadStatus(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 24))
                .foregroundStyle(AppPalette.accent).frame(width: 46, height: 46)
                .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.servicesUpdatedAt == nil ? "服务尚未读取" : "已识别 \(recognized.count) 项插件服务").font(AppTypography.rowTitle)
                Text("其他插件可通过 LuCI 或 iStore 管理").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }.padding(.vertical, 4).padding(.bottom, 18)
        AppSearchField(prompt: "搜索插件名称或服务", text: $query, identifier: "pluginSearchField")
        HStack(spacing: 6) {
            FilterButton(title: "全部服务", selected: !onlyRunning) { onlyRunning = false }
            FilterButton(title: "运行中", selected: onlyRunning) { onlyRunning = true }
        }.padding(.top, 12)
        ForEach(categories, id: \.self) { category in
            AppSection(title: category) {
                AppGroup {
                    ForEach(filtered.filter { $0.category == category }) { plugin in
                        NavigationLink { PluginServiceDetail(plugin: plugin) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: plugin.id == "smartdns" ? "server.rack" : "checkmark.shield")
                                    .font(.system(size: 21)).foregroundStyle(AppPalette.accent)
                                    .frame(width: 40, height: 40).background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plugin.title).font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                                    Text("procd · \(plugin.id)").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                    Text("服务可见 · 版本尚未读取").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                StatusBadge(title: plugin.service.totalInstances == 0 ? "未知" : plugin.service.runningInstances > 0 ? "运行中" : "未运行", good: plugin.service.runningInstances > 0)
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppPalette.muted)
                            }.padding(12)
                        }.buttonStyle(.plain)
                        if plugin.id != filtered.filter({ $0.category == category }).last?.id { AppDivider(inset: 63) }
                    }
                }
            }
        }
        if filtered.isEmpty && store.servicesUpdatedAt != nil {
            ContentUnavailableView(query.isEmpty ? "暂无匹配服务" : "未找到相关插件", systemImage: "puzzlepiece.extension",
                                   description: Text("未匹配到服务不等于未安装插件。可通过下面的管理入口查看。"))
        }
        AppSection(title: "管理入口", note: "插件运行实例不代表配置生效或业务健康。") {
            AppGroup {
                ForEach(RouterWebPage.allCases) { page in
                    NavigationLink { RouterWebEntryView(page: page) } label: {
                        AppRow(title: page.title, symbol: page == .istore ? "bag" : page == .packages ? "shippingbox" : "safari", chevron: true)
                    }.buttonStyle(.plain)
                    AppDivider()
                }
                NavigationLink { ServicesScreen(showingRouterPicker: .constant(false)) } label: {
                    AppRow(title: "全部系统服务", symbol: "gearshape.2", chevron: true)
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct PluginServiceDetail: View {
    @Environment(RouterStore.self) private var store
    let plugin: RecognizedPluginService

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            ReadStatus(updatedAt: store.servicesUpdatedAt, error: store.servicesError)
            AppSection(title: "服务证据") {
                AppGroup {
                AppRow(title: "服务名称", value: plugin.id)
                AppDivider(inset: 12)
                if let current = store.services.first(where: { $0.id == plugin.id }) {
                    AppRow(title: "运行实例", value: "\(current.runningInstances) / \(current.totalInstances)")
                } else {
                    AppRow(title: "最新列表中未找到此服务")
                }
                AppDivider(inset: 12)
                AppRow(title: "插件版本", value: "尚未读取")
                AppDivider(inset: 12)
                AppRow(title: "原生配置适配", value: "尚未接入")
                }
            }
            AppSection(title: "管理", note: "不同插件和固件的配置接口不同；原生配置入口通过版本和权限验证后才会开放。") {
                AppGroup {
                    NavigationLink { RouterWebEntryView(page: .luci) } label: {
                        AppRow(title: "前往 LuCI 管理", symbol: "safari", chevron: true)
                    }.buttonStyle(.plain)
                }
            }
        }
        .appDetailStyle(plugin.title)
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
        AppPage(title: page.title, subtitle: "访问路由器提供的管理页面") {
            AppGroup {
                AppRow(title: page.title, symbol: page == .istore ? "bag" : page == .packages ? "shippingbox" : "safari")
                if let url {
                    Text(url.absoluteString)
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if page == .istore {
                    Text("需要路由器已安装兼容的 iStore。支持情况取决于固件、架构、软件源和 iStore 版本。")
                } else if page == .packages {
                    Text("软件包页面取决于固件的 LuCI 版本及 opkg / apk 支持。")
                }
                Text(store.isDemo ? "演示模式没有真实路由器，无法打开管理页面。" : "网页使用独立登录，不自动传入 App 的密码或会话。系统浏览器独立验证 HTTPS 证书。页面不存在时可返回 LuCI 首页。")
            }.font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.top, 18)
                Button("打开管理网页", systemImage: "arrow.up.right.square") {
                    showingBrowser = true
                }
                .buttonStyle(AppPrimaryButtonStyle()).padding(.top, 24).disabled(url == nil)
                .accessibilityIdentifier("openRouterWebButton")
            if page != .luci {
                AppSection(title: "其他入口") {
                    AppGroup {
                        NavigationLink { RouterWebEntryView(page: .luci) } label: {
                            AppRow(title: "LuCI 首页", symbol: "safari", chevron: true)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .appDetailStyle(page.title)
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
