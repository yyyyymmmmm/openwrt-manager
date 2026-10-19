import SwiftUI
import OpenWrtKit

/// Preserve the firmware's category and hierarchy, including unknown extensions.
/// No action is offered for an adapter that has not been implemented.
struct FirmwareMenuSection: View {
    @Environment(RouterStore.self) private var store
    let group: String
    var excluding: Set<String> = []
    var query = ""
    private var entries: [RouterMenuEntry] {
        store.inventory.allMenus.filter {
            $0.group == group && $0.path.count == 3 && !excluding.contains($0.path.last ?? "") &&
            (query.isEmpty || ($0.title + $0.id).localizedCaseInsensitiveContains(query))
        }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }
    var body: some View {
        if !entries.isEmpty {
            AppSection(title: "固件扩展", note: "按当前固件的菜单分类显示。未支持的原生操作会明确标注。") {
                AppGroup {
                    ForEach(entries) { entry in
                        FirmwareMenuRow(entry: entry)
                        if entry.id != entries.last?.id { AppDivider() }
                    }
                }
            }
        }
    }
}

private struct FirmwareMenuRow: View {
    let entry: RouterMenuEntry
    private var adapter: NativeConfigurationSchema? {
        switch entry.id {
        case "admin/services/ddns": return .ddns
        case "admin/network/sqm": return .sqm
        case "admin/network/upnp": return .upnp
        default: return nil
        }
    }
    var body: some View {
        if let adapter {
            NavigationLink { NativePluginManagementView(schema: adapter, title: entry.title) } label: {
                AppRow(title: entry.title, detail: "配置与系统服务", symbol: "slider.horizontal.3", chevron: true)
            }.buttonStyle(.plain).accessibilityIdentifier("native-menu-\(entry.id)")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                AppRow(title: entry.title, detail: "暂不支持原生管理", symbol: "puzzlepiece.extension")
                if !entry.children.isEmpty {
                    Text(entry.children.map(\.title).joined(separator: " · "))
                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct NativePluginManagementView: View {
    @Environment(RouterStore.self) private var store
    let schema: NativeConfigurationSchema
    let title: String
    private var serviceName: String { schema.id == "upnp" ? "miniupnpd" : schema.id }
    private var serviceReported: Bool {
        store.inventory.initServices.contains { $0.name == serviceName } || store.services.contains { $0.name == serviceName }
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: title) {
                AppGroup { NativeConfigurationLink(schema: schema) }
            }
            AppSection(title: "系统服务", note: "启动项与进程状态只代表系统服务，不证明插件业务成功。") {
                AppGroup {
                    if serviceReported {
                        NavigationLink { ServiceDetailView(name: serviceName) } label: { AppRow(title: serviceName, symbol: "gearshape", chevron: true) }.buttonStyle(.plain)
                    } else { AppRow(title: "尚未读取到对应启动项", detail: "请刷新并查看服务读取权限与错误。") }
                }
            }
            Text(schema.note).font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.top, 14)
        }.appDetailStyle(title)
    }
}

struct NetworkInterfacesView: View {
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "接口") {
                AppGroup {
                    NavigationLink { InterfaceDetailView() } label: { AppRow(title: "运行状态", detail: "地址、上联网关、DNS 与错误", symbol: "network", chevron: true) }.buttonStyle(.plain)
                    AppDivider()
                    NativeConfigurationLink(schema: .interfaces, symbol: "point.3.connected.trianglepath.dotted")
                    AppDivider()
                    NativeConfigurationLink(schema: .devices, symbol: "point.3.filled.connected.trianglepath.dotted")
                }
            }
        }.appDetailStyle("接口")
    }
}

struct NativeConfigurationLink: View {
    let schema: NativeConfigurationSchema
    var symbol = "slider.horizontal.3"
    var body: some View {
        NavigationLink { NativeConfigurationView(schema: schema) } label: {
            AppRow(title: schema.title, symbol: symbol, chevron: true)
        }.buttonStyle(.plain).accessibilityIdentifier("native-config-\(schema.id)")
    }
}

struct DHCPManagementView: View {
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "DHCP") {
                AppGroup {
                    NavigationLink { DevicesContent() } label: { AppRow(title: "DHCP 租约", symbol: "rectangle.connected.to.line.below", chevron: true) }.buttonStyle(.plain)
                    AppDivider()
                    NativeConfigurationLink(schema: .dhcp)
                }
            }
        }.appDetailStyle("DHCP")
    }
}

struct RouterAdministrationView: View {
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "管理权") {
                AppGroup { NativeConfigurationLink(schema: .ssh, symbol: "terminal") }
            }
            AppSection(title: "其他管理选项", note: "账户密码、SSH 公钥与软件源公钥的原生管理尚未接入。") {
                EmptyView()
            }
        }.appDetailStyle("管理权")
    }
}
