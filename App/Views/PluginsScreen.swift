import SwiftUI
import OpenWrtKit

struct PluginDirectoryView: View {
    var body: some View { AppPage(title: "插件", subtitle: nil) { PluginCollection() }.appDetailStyle("插件中心") }
}
struct PluginCollection: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""
    private var plugins: [InstalledPlugin] {
        store.inventory.plugins.filter { query.isEmpty || ($0.title + $0.id).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        InventoryStatus()
        AppSearchField(prompt: "搜索已安装插件", text: $query, identifier: "pluginSearchField")
        AppSection(title: store.inventory.packagesRead ? "已安装 · \(store.inventory.plugins.count)" : "已安装插件", note: "版本、配置与服务关联来自已安装软件包。运行实例仅反映进程状态。") {
            AppGroup {
                ForEach(plugins) { plugin in
                    NavigationLink { PluginDetailView(plugin: plugin) } label: {
                        AppRow(title: plugin.title, detail: "\(plugin.id)\n\(plugin.package.version)", symbol: "puzzlepiece.extension", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("plugin-\(plugin.id)")
                    if plugin.id != plugins.last?.id { AppDivider() }
                }
            }
        }
        if plugins.isEmpty && store.inventory.packagesRead {
            ContentUnavailableView(query.isEmpty ? "未安装 LuCI 扩展包" : "没有匹配插件", systemImage: "puzzlepiece.extension")
        }
        AppSection(title: "路由器软件") {
            AppGroup {
                NavigationLink { PackagesView() } label: {
                    AppRow(title: "全部已安装软件包", symbol: "shippingbox", value: store.inventory.packagesRead ? "\(store.inventory.packages.count)" : "尚未读取", chevron: true)
                }.buttonStyle(.plain).accessibilityIdentifier("packages-directory")
            }
        }
    }
}

struct InventoryStatus: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        ReadStatus(updatedAt: store.inventoryUpdatedAt, error: nil)
        ForEach(store.inventory.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(.bottom, 8)
        }
        if (!store.inventory.packagesRead || !store.inventory.warnings.isEmpty) && !store.isRefreshing {
            Button("重新读取功能目录", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .font(AppTypography.row).padding(.bottom, 12)
        }
    }
}

struct PluginDetailView: View {
    @Environment(RouterStore.self) private var store
    let plugin: InstalledPlugin
    private var current: InstalledPlugin? { store.inventory.plugins.first { $0.id == plugin.id } }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            InventoryStatus()
            if let current {
                AppSection(title: "软件包") {
                    AppGroup { AppRow(title: current.package.name, detail: current.package.description, symbol: "shippingbox", value: current.package.version) }
                }
                if let adapter = NativeConfigurationSchema.pluginAdapter(packageName: current.package.name) {
                    AppSection(title: "专用原生管理") {
                        AppGroup {
                            NavigationLink { NativePluginManagementView(schema: adapter, title: current.title) } label: {
                                AppRow(title: adapter.title, symbol: "slider.horizontal.3", chevron: true)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                AppSection(title: store.inventory.configsRead ? "配置 · \(current.configs.count)" : "关联配置") {
                    AppGroup {
                        ForEach(current.configs, id: \.self) { name in
                            NavigationLink { ConfigurationEditorView(name: name) } label: {
                                AppRow(title: name, symbol: "slider.horizontal.3", chevron: true)
                            }.buttonStyle(.plain).accessibilityIdentifier("plugin-config-\(name)")
                            if name != current.configs.last { AppDivider() }
                        }
                        if current.configs.isEmpty {
                            AppRow(title: store.inventory.configsRead ? "未发现关联的 UCI 配置" : "配置目录尚未读取",
                                   detail: store.inventory.configsRead ? "该扩展可能使用文件或专有接口。" : "请查看读取错误并重新读取。")
                        }
                    }
                }
                if !current.serviceNames.isEmpty {
                    AppSection(title: "系统服务") {
                        AppGroup {
                            ForEach(current.serviceNames, id: \.self) { name in
                                NavigationLink { ServiceDetailView(name: name) } label: { AppRow(title: name, symbol: "gearshape", chevron: true) }
                                    .buttonStyle(.plain).accessibilityIdentifier("plugin-service-\(name)")
                                if name != current.serviceNames.last { AppDivider() }
                            }
                        }
                    }
                }
                AppSection(title: "适配范围", note: "已适配的专用表单与操作在上方单列。通用配置和服务控制不代表插件全部业务已适配。") {
                    AppGroup {
                        NavigationLink { PackageDetailView(package: current.package) } label: { AppRow(title: "依赖与安装文件", symbol: "doc.text.magnifyingglass", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("plugin-package-details")
                    }
                }
            } else {
                ContentUnavailableView(store.inventory.packagesRead ? "插件已不在当前清单中" : "软件包清单读取失败", systemImage: "puzzlepiece.extension")
            }
        }.appDetailStyle(plugin.title)
    }
}
