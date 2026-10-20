import SwiftUI
import Observation
import OpenWrtKit

/// Runtime and persistent configuration are separate reads, joined only by the exact interface name.
@Observable @MainActor
private final class InterfaceReads {
    var runtime: [NetworkInterfaceSnapshot]?
    var configuration: RouterConfiguration?
    var runtimeDate: Date?
    var configurationDate: Date?
    var runtimeError: String?
    var configurationError: String?
    var loading = false
    private var connectionID: UUID?
    private var requestID = UUID()

    var names: [String] {
        let configured = configuration?.sections.filter { $0.type == "interface" }.map(\.id) ?? []
        return Set(configured + (runtime?.map(\.name) ?? [])).sorted()
    }

    func configured(_ name: String) -> ConfigurationSection? {
        configuration?.sections.first { $0.type == "interface" && $0.id == name }
    }

    func load(_ store: RouterStore) async {
        let generation = store.connectionID, request = UUID()
        if connectionID != generation {
            runtime = nil; configuration = nil; runtimeDate = nil; configurationDate = nil
            runtimeError = nil; configurationError = nil; connectionID = generation
        }
        requestID = request; loading = true
        async let status = readRuntime(store)
        async let config = readConfiguration(store)
        let results = await (status, config)
        guard generation == store.connectionID, requestID == request else { return }
        loading = false
        guard !Task.isCancelled else { return }
        switch results.0 {
        case .success(let value): runtime = value; runtimeDate = Date(); runtimeError = nil
        case .failure(let error): runtimeError = FriendlyError.message(error)
        }
        switch results.1 {
        case .success(let value): configuration = value; configurationDate = Date(); configurationError = nil
        case .failure(let error): configurationError = FriendlyError.message(error)
        }
    }

    private func readRuntime(_ store: RouterStore) async -> Result<[NetworkInterfaceSnapshot], Error> {
        do { return .success(try await store.networkInterfaces()) }
        catch { return .failure(error) }
    }

    private func readConfiguration(_ store: RouterStore) async -> Result<RouterConfiguration, Error> {
        do { return .success(try await store.configuration("network")) }
        catch { return .failure(error) }
    }
}

struct NetworkInterfacesView: View {
    @Environment(RouterStore.self) private var store
    @State private var reads = InterfaceReads()
    var scope: String? = nil
    private var names: [String] { reads.names.filter { scope == nil || $0 == scope } }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            InterfaceReadStatus(reads: reads)
            AppSection(title: "逻辑接口", note: "同时列出持久配置与固件运行接口。点击接口查看地址、网关、DNS，并编辑此接口。") {
                AppGroup {
                    ForEach(names, id: \.self) { name in
                        NavigationLink { NamedInterfaceView(name: name, reads: reads) } label: {
                            AppRow(title: name, detail: summary(name), symbol: "network", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("network-interface-\(name)")
                        if name != names.last { AppDivider() }
                    }
                    if names.isEmpty {
                        AppRow(title: reads.loading ? "正在读取接口…" : "未列出接口", detail: reads.runtimeError != nil || reads.configurationError != nil
                            ? "读取失败，不能判断路由器没有接口。请重新读取。" : "运行状态与持久配置中均未找到匹配接口。")
                    }
                }
            }
            AppSection(title: "网络配置") {
                AppGroup {
                    NativeConfigurationLink(schema: .interfaces, symbol: "point.3.connected.trianglepath.dotted")
                    AppDivider()
                    NativeConfigurationLink(schema: .devices, symbol: "point.3.filled.connected.trianglepath.dotted")
                }
            }
        }.appDetailStyle(scope.map { "接口 · \($0)" } ?? "接口")
            .task(id: store.connectionID) { await reads.load(store) }
            .refreshable { await reads.load(store) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await reads.load(store) } }.disabled(reads.loading)
            } }
            .onChange(of: store.pendingConfiguration) { previous, current in
                if previous != nil && current == nil { Task { await reads.load(store) } }
            }
    }

    private func summary(_ name: String) -> String {
        let runtime = reads.runtime?.first { $0.name == name }
        let config = reads.configured(name)
        let status = runtime?.up.map { $0 ? "已连接" : "未连接" } ?? (reads.runtimeError == nil ? "未报告运行状态" : "运行状态读取失败")
        let proto = runtime?.protocolName ?? config?.values["proto"]?.stringValue ?? "协议未报告"
        return [proto, status, config == nil ? (reads.configurationError == nil ? "无对应持久配置" : "配置未确认") : "已配置"].joined(separator: " · ")
    }
}

private struct InterfaceReadStatus: View {
    @Environment(RouterStore.self) private var store
    let reads: InterfaceReads
    var body: some View {
        AppSection(title: "读取状态") {
            AppGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("运行状态").font(AppTypography.rowTitle)
                    if let date = reads.runtimeDate { Text(date, format: .dateTime.hour().minute().second()).font(AppTypography.metadata) }
                    ReadStatus(updatedAt: reads.runtimeDate, error: reads.runtimeError,
                               retry: { Task { await reads.load(store) } }, loading: reads.loading)
                    Text("持久配置").font(AppTypography.rowTitle)
                    if let date = reads.configurationDate { Text(date, format: .dateTime.hour().minute().second()).font(AppTypography.metadata) }
                    ReadStatus(updatedAt: reads.configurationDate, error: reads.configurationError,
                               retry: { Task { await reads.load(store) } }, loading: reads.loading)
                    if reads.loading { ProgressView("正在重新读取…") }
                    if reads.runtimeError != nil || reads.configurationError != nil {
                        Text("读取失败时保留上次数据，请按更新时间判断；不能据此认定当前连接正常或配置已生效。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                    }
                }.padding(12)
            }
        }
    }
}

private struct NamedInterfaceView: View {
    @Environment(RouterStore.self) private var store
    let name: String
    let reads: InterfaceReads
    private var runtime: NetworkInterfaceSnapshot? { reads.runtime?.first { $0.name == name } }
    private var configured: ConfigurationSection? { reads.configured(name) }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            InterfaceReadStatus(reads: reads)
            AppSection(title: "运行状态") {
                AppGroup {
                    if let runtime {
                        InterfaceRow(interface: runtime).padding(12)
                        ForEach(runtime.errors, id: \.self) { error in
                            AppDivider(); AppRow(title: "固件错误", detail: error, symbol: "exclamationmark.triangle")
                        }
                    } else {
                        AppRow(title: "未取得此接口的运行状态", detail: reads.runtimeError == nil
                            ? "固件未返回此接口；持久配置存在不代表接口已启动。" : "请先解决运行状态读取错误。")
                    }
                }
            }
            addressSection(ipv6: false)
            addressSection(ipv6: true)
            AppSection(title: "DNS") {
                AppGroup {
                    let servers = runtime?.dnsServers ?? []
                    AppRow(title: "运行 DNS", value: servers.isEmpty ? "未报告" : servers.joined(separator: " · "))
                    AppDivider()
                    AppRow(title: "配置 DNS", value: configuredValue("dns"))
                }
            }
            AppSection(title: "持久配置", note: "应用后会重新读取配置和运行状态；事务确认仅表示保留修改，仍需核对连接、地址与固件错误。") {
                AppGroup {
                    if let configured {
                        AppRow(title: "协议", value: configured.values["proto"]?.stringValue ?? "未设置")
                        AppDivider()
                        AppRow(title: "设备", value: configured.values["device"]?.stringValue ?? "未设置")
                        AppDivider()
                        NavigationLink { NativeConfigurationView(schema: .interfaces, sectionID: name) } label: {
                            AppRow(title: "编辑此接口", detail: "常规设置、高级设置与 IPv6", symbol: "slider.horizontal.3", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("interface-edit-\(name)")
                    } else {
                        AppRow(title: reads.configurationError == nil ? "没有对应的持久配置" : "持久配置未确认", detail:
                            reads.configurationError == nil ? "此接口可能由协议动态生成。请返回全部接口配置查看其上级接口；不会按名称猜测或创建配置。" : "请先解决配置读取错误。")
                    }
                }
            }
        }.appDetailStyle(name)
            .task(id: store.connectionID) { await reads.load(store) }
            .refreshable { await reads.load(store) }
            .onChange(of: store.pendingConfiguration) { previous, current in
                if previous != nil && current == nil { Task { await reads.load(store) } }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await reads.load(store) } }.disabled(reads.loading)
            } }
    }

    private func addressSection(ipv6: Bool) -> some View {
        let family = ipv6 ? "IPv6" : "IPv4"
        let addresses = runtime?.addresses.filter { $0.contains(":") == ipv6 } ?? []
        let routes = runtime?.defaultRoutes.filter { $0.ipv6 == ipv6 } ?? []
        return AppSection(title: family) {
            AppGroup {
                AppRow(title: "运行地址", value: addresses.isEmpty ? "未报告" : addresses.joined(separator: " · "))
                ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                    AppDivider()
                    AppRow(title: "默认网关", detail: route.metric.map { "跃点 \($0)" }, value: route.gateway ?? "无下一跳（链路路由）")
                }
                AppDivider()
                AppRow(title: "配置地址", value: configuredValue(ipv6 ? "ip6addr" : "ipaddr"))
                if !ipv6 {
                    AppDivider()
                    AppRow(title: "配置子网掩码", value: configuredValue("netmask"))
                }
                AppDivider()
                AppRow(title: "配置网关", value: configuredValue(ipv6 ? "ip6gw" : "gateway"))
            }
        }
    }

    private func configuredValue(_ key: String) -> String {
        guard let configured else { return "配置未取得" }
        guard let value = configured.values[key] else { return "未设置" }
        if let list = value.arrayValue { return list.compactMap(\.stringValue).joined(separator: " · ") }
        return value.stringValue ?? "字段格式未适配"
    }
}
