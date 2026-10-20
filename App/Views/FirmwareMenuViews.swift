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
        NativeConfigurationSchema.pluginAdapter(menuID: entry.id)
    }
    var body: some View {
        if adapter?.id == "wol" {
            NavigationLink { NativePluginManagementView(schema: .wol, title: entry.title) } label: {
                AppRow(title: entry.title, detail: "目标、工具与原生唤醒", symbol: "power", chevron: true)
            }.buttonStyle(.plain).accessibilityIdentifier("native-menu-\(entry.id)")
        } else if let adapter {
            NavigationLink { NativePluginManagementView(schema: adapter, title: entry.title) } label: {
                AppRow(title: entry.title, detail: "配置与系统服务", symbol: "slider.horizontal.3", chevron: true)
            }.buttonStyle(.plain).accessibilityIdentifier("native-menu-\(entry.id)")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                AppRow(title: entry.title, detail: "暂不支持原生管理", symbol: "puzzlepiece.extension")
                ForEach(entry.children) { child in FirmwareMenuDescription(entry: child).padding(.horizontal, 14) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct FirmwareMenuDescription: View {
    let entry: RouterMenuEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title + " · 未适配原生操作").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            ForEach(entry.children) { child in
                FirmwareMenuDescription(entry: child).padding(.leading, 12)
            }
        }.padding(.bottom, 8)
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
            if ["homeproxy", "mosdns", "zerotier"].contains(schema.id) {
                AppSection(title: "运行管理") {
                    AppGroup {
                        NavigationLink { NativePluginOperationsView(pluginID: schema.id) } label: {
                            AppRow(title: "状态与操作", detail: "读取实际响应与任务结果", symbol: "waveform.path.ecg", chevron: true)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if schema.id == "upnp" {
                AppSection(title: "运行管理") {
                    AppGroup {
                        NavigationLink { UPnPMappingsView() } label: {
                            AppRow(title: "活动端口映射", detail: "实际映射、详情与删除", symbol: "arrow.left.arrow.right", chevron: true)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if schema.id == "ddns" {
                AppSection(title: "运行管理") {
                    AppGroup {
                        NavigationLink { DDNSInstancesView() } label: {
                            AppRow(title: "实例状态与日志", detail: "注册 IP、更新时间与单实例启停", symbol: "network", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("ddns-instances")
                    }
                }
            }
            if schema.id == "sqm" {
                AppSection(title: "专用运行管理") {
                    AppGroup {
                        NavigationLink { SQMManagementView() } label: {
                            AppRow(title: "实例、脚本与内核队列", detail: "读取实际 tc 队列、统计和启动日志", symbol: "waveform.path.ecg", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("sqm-runtime")
                    }
                }
            }
            if schema.id == "wol" {
                AppSection(title: "运行管理") {
                    AppGroup {
                        NavigationLink { WakeOnLANView() } label: {
                            AppRow(title: "唤醒目标与发送", detail: "工具、接口、权限与真实退出结果", symbol: "power", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("wol-targets")
                    }
                }
            }
            if schema.id == "mosdns" {
                AppSection(title: "规则与自定义配置") {
                    AppGroup {
                        NavigationLink { MosDNSFilesView() } label: {
                            AppRow(title: "规则文件", detail: "八类规则、预览和保存", symbol: "line.3.horizontal.decrease", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("mosdns-rules")
                        AppDivider()
                        NavigationLink { RouterTextFileView(file: .mosDNSCustom) } label: {
                            AppRow(title: "自定义 YAML", symbol: "doc.text", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("mosdns-custom-file")
                    }
                }
            }
            if schema.id != "wol" {
            AppSection(title: "系统服务", note: "启动项与进程状态只代表系统服务，不证明插件业务成功。") {
                AppGroup {
                    if serviceReported {
                        NavigationLink { ServiceDetailView(name: serviceName) } label: { AppRow(title: serviceName, symbol: "gearshape", chevron: true) }.buttonStyle(.plain)
                    } else { AppRow(title: "尚未读取到对应启动项", detail: "请刷新并查看服务读取权限与错误。") }
                }
            }
            }
            Text(schema.note).font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.top, 14)
        }.appDetailStyle(title)
    }
}

struct MosDNSFilesView: View {
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "默认配置规则", note: "自定义 YAML 只有明确引用这些文件时才会使用它们。保存文件后需重启 MosDNS 并核对日志及解析结果。") {
                AppGroup {
                    ForEach(RouterSystemFile.mosDNSRules, id: \.self) { file in
                        NavigationLink { RouterTextFileView(file: file) } label: {
                            AppRow(title: file.title, detail: file.explanation, symbol: "doc.text", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("mosdns-file-" + file.rawValue)
                        if file != RouterSystemFile.mosDNSRules.last { AppDivider() }
                    }
                }
            }
        }.appDetailStyle("MosDNS 规则文件")
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
                AppGroup {
                    NavigationLink { RouterPasswordView() } label: {
                        AppRow(title: "账户密码", detail: "系统与 rpcd 账户、固件密码策略", symbol: "key", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("admin-password")
                    AppDivider()
                    NativeConfigurationLink(schema: .ssh, symbol: "terminal")
                    AppDivider()
                    NavigationLink { SSHAuthorizedKeysView() } label: {
                        AppRow(title: "SSH 公钥", detail: "公钥详情、添加与删除", symbol: "key.horizontal", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("admin-ssh-keys")
                }
            }
            AppSection(title: "尚待适配") {
                AppGroup { AppRow(title: "软件源公钥", detail: "APK / opkg 公钥管理尚未接入") }
            }
        }.appDetailStyle("管理权")
    }
}
