import SwiftUI
import OpenWrtKit

// MARK: - Shared helpers for the package-F2 dedicated pages
//
// The five F2 services are UCI-shaped: the page reads the service's
// configuration, presents it in human terms, and writes through the
// same L4 gate as every other page (draft -> ConfigurationPlan ->
// TransactionConfirmationView). None of them has a verified live
// status channel beyond the snapshot's init.d state shown by
// DedicatedServiceHeader, and the pages say so where it matters
// instead of inventing one.

/// Loads a service configuration, mapping "not granted / not there"
/// to a nil payload (the page renders its honest empty state) and
/// everything else to a real failure.
private func dedicatedConfigState(_ name: String,
                                  using readClient: ReadOnlyDataClient) async -> LoadState<RouterConfiguration?> {
    do {
        return .loaded(try await readClient.configuration(name))
    } catch let error as OpenWrtKitError where error == .permissionDenied {
        return .loaded(nil)
    } catch let error as OpenWrtKitError {
        if case .unsupported = error { return .loaded(nil) }
        return .failed(FriendlyError.message(error))
    } catch {
        return .failed(FriendlyError.message(error))
    }
}

/// The option that actually holds a boolean in this section, so a
/// toggle writes the name the daemon reads — never a guessed alias.
private func boolOptionName(in section: ConfigurationSection, candidates: [String]) -> String? {
    candidates.first { section.values[$0] != nil }
}

/// The raw layer for a UCI-shaped page: every option verbatim, with
/// secret options masked by name — a raw dump must never become the
/// leak the human layer avoided.
struct DedicatedRawConfigSection: View {
    let configuration: RouterConfiguration

    var body: some View {
        RawDataSection {
            ForEach(configuration.sections) { section in
                Text("\(section.type) · \(section.id)")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                ForEach(section.values.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: display(section.values[key] ?? .null,
                                                       secret: DedicatedSecret.isSecretOption(key)))
                }
            }
        }
    }

    private func display(_ value: JSONValue, secret: Bool) -> String {
        if secret {
            let isSet = !(value.stringValue ?? "").isEmpty || value.arrayValue?.isEmpty == false
            return isSet ? L10n.string("已设置（不显示）") : L10n.string("未设置")
        }
        return GenericPageModel.displayText(value)
    }
}

// MARK: - FRP client dedicated page (UCI frpc)

struct FrpcView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled: [String: Bool] = [:]
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "frpc")
            switch state {
            case .loading:
                ProgressView("正在读取 FRP 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let wrapped):
                if let configuration = wrapped {
                    content(FrpcParser.parse(configuration), configuration: configuration)
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 frpc 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
            }
            if let initName = store.capability?.services.first(where: { $0.key == "frpc" })?.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("FRP 客户端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }
                    .disabled(!hasChanges)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: "frpc")) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ overview: FrpcOverview, configuration: RouterConfiguration) -> some View {
        Section("服务器") {
            if let server = overview.server {
                if let endpoint = server.endpointText {
                    LabeledContent("服务器地址", value: endpoint)
                } else {
                    Text("尚未填写服务器地址，客户端连不上 FRP 服务端。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
                LabeledContent("访问令牌", value: server.hasToken ? L10n.string("已设置（不显示）") : L10n.string("未设置"))
            } else {
                Text("未找到服务器配置节。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        Section("隧道") {
            if overview.tunnels.isEmpty {
                EmptyStateView(title: "暂无隧道", message: "还没有配置任何隧道，可在编辑配置中新增。")
            } else {
                ForEach(overview.tunnels) { tunnel in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack {
                            Text(tunnel.name).font(AppTypography.rowTitle)
                            Spacer()
                            if let type = tunnel.type {
                                Text(type).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                            }
                        }
                        if let local = tunnel.localText {
                            Text(L10n.format("本地 %@", local))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if let remote = tunnel.remotePort {
                            Text(L10n.format("远端端口 %@", remote))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        ForEach(tunnel.domains, id: \.self) { domain in
                            Text(L10n.format("域名 %@", domain))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if tunnel.enabled != nil {
                            Toggle("启用此隧道", isOn: Binding(
                                get: { draftEnabled[tunnel.sectionID] ?? tunnel.enabled ?? false },
                                set: { draftEnabled[tunnel.sectionID] = $0 }))
                            .font(AppTypography.secondary)
                        }
                    }
                }
            }
            if let planError {
                Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        Section {
            NavigationLink {
                ConfigEditorView(configName: "frpc", title: "FRP 客户端")
            } label: {
                Label("编辑配置", systemImage: "square.and.pencil")
            }
        }
        DedicatedRawConfigSection(configuration: configuration)
    }

    private var hasChanges: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return false }
        let overview = FrpcParser.parse(configuration)
        return overview.tunnels.contains { tunnel in
            guard let draft = draftEnabled[tunnel.sectionID], let current = tunnel.enabled else { return false }
            return draft != current
        }
    }

    private func preparePlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return }
        var edited = configuration
        for tunnel in FrpcParser.parse(configuration).tunnels {
            guard let draft = draftEnabled[tunnel.sectionID], let current = tunnel.enabled, draft != current,
                  let index = edited.sections.firstIndex(where: { $0.id == tunnel.sectionID }),
                  let option = boolOptionName(in: edited.sections[index], candidates: ["enabled", "enable"])
            else { continue }
            edited.sections[index].values[option] = .string(draft ? "1" : "0")
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        state = await dedicatedConfigState("frpc", using: readClient)
        if case .loaded(let wrapped) = state, let configuration = wrapped {
            draftEnabled = Dictionary(uniqueKeysWithValues: FrpcParser.parse(configuration).tunnels
                .compactMap { tunnel in tunnel.enabled.map { (tunnel.sectionID, $0) } })
        }
    }
}

// MARK: - NATMap dedicated page (UCI natmap)

struct NatmapView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled: [String: Bool] = [:]
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "natmap")
            switch state {
            case .loading:
                ProgressView("正在读取 NATMap 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let wrapped):
                if let configuration = wrapped {
                    content(NatmapParser.parse(configuration), configuration: configuration)
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 natmap 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
            }
            if let initName = store.capability?.services.first(where: { $0.key == "natmap" })?.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("NATMap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }
                    .disabled(!hasChanges)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: "natmap")) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ entries: [NatmapEntry], configuration: RouterConfiguration) -> some View {
        Section {
            Text("NATMap 借助 STUN 服务器打洞，把内网端口映射到公网地址上，并周期性访问保活地址维持映射不失效。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }
        if entries.isEmpty {
            Section {
                EmptyStateView(title: "暂无映射配置", message: "路由器上还没有 NATMap 配置节，可在编辑配置中新增。")
            }
        }
        ForEach(entries) { entry in
            Section(entry.sectionID) {
                if let stun = entry.stunServer {
                    LabeledContent("STUN 服务器", value: stun)
                }
                if let port = entry.port {
                    LabeledContent("映射端口", value: port)
                }
                if let keepAlive = entry.keepAliveTarget {
                    LabeledContent("保活地址", value: keepAlive)
                }
                if let family = entry.family {
                    LabeledContent("地址族", value: family)
                }
                if entry.enabled != nil {
                    Toggle("启用映射", isOn: Binding(
                        get: { draftEnabled[entry.sectionID] ?? entry.enabled ?? false },
                        set: { draftEnabled[entry.sectionID] = $0 }))
                }
            }
        }
        if let planError {
            Section {
                Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        Section {
            NavigationLink {
                ConfigEditorView(configName: "natmap", title: "NATMap")
            } label: {
                Label("编辑配置", systemImage: "square.and.pencil")
            }
        }
        DedicatedRawConfigSection(configuration: configuration)
    }

    private var hasChanges: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return false }
        return NatmapParser.parse(configuration).contains { entry in
            guard let draft = draftEnabled[entry.sectionID], let current = entry.enabled else { return false }
            return draft != current
        }
    }

    private func preparePlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return }
        var edited = configuration
        for entry in NatmapParser.parse(configuration) {
            guard let draft = draftEnabled[entry.sectionID], let current = entry.enabled, draft != current,
                  let index = edited.sections.firstIndex(where: { $0.id == entry.sectionID }),
                  let option = boolOptionName(in: edited.sections[index], candidates: ["enable", "enabled"])
            else { continue }
            edited.sections[index].values[option] = .string(draft ? "1" : "0")
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        state = await dedicatedConfigState("natmap", using: readClient)
        if case .loaded(let wrapped) = state, let configuration = wrapped {
            draftEnabled = Dictionary(uniqueKeysWithValues: NatmapParser.parse(configuration)
                .compactMap { entry in entry.enabled.map { (entry.sectionID, $0) } })
        }
    }
}

// MARK: - Socat dedicated page (UCI luci_socat)

struct SocatView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled: [String: Bool] = [:]
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "socat")
            switch state {
            case .loading:
                ProgressView("正在读取 Socat 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let wrapped):
                if let configuration = wrapped {
                    content(SocatParser.parse(configuration), configuration: configuration)
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 luci_socat 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
            }
            if let initName = store.capability?.services.first(where: { $0.key == "socat" })?.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("Socat 端口转发")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }
                    .disabled(!hasChanges)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: "luci_socat")) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ rules: [SocatRule], configuration: RouterConfiguration) -> some View {
        Section("转发规则") {
            if rules.isEmpty {
                EmptyStateView(title: "暂无转发规则", message: "还没有配置任何端口转发规则，可在编辑配置中新增。")
            } else {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(rule.remarks ?? rule.sectionID).font(AppTypography.rowTitle)
                        if let listen = rule.listenPort {
                            Text(L10n.format("监听端口 %@", listen))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if let destination = rule.destinationText {
                            Text(L10n.format("转发到 %@", destination))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if let proto = rule.`protocol` {
                            Text(L10n.format("协议 %@", proto))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if rule.enabled != nil {
                            Toggle("启用此规则", isOn: Binding(
                                get: { draftEnabled[rule.sectionID] ?? rule.enabled ?? false },
                                set: { draftEnabled[rule.sectionID] = $0 }))
                            .font(AppTypography.secondary)
                        }
                    }
                }
            }
            if let planError {
                Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        Section {
            NavigationLink {
                ConfigEditorView(configName: "luci_socat", title: "Socat 端口转发")
            } label: {
                Label("编辑配置", systemImage: "square.and.pencil")
            }
        }
        DedicatedRawConfigSection(configuration: configuration)
    }

    private var hasChanges: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return false }
        return SocatParser.parse(configuration).contains { rule in
            guard let draft = draftEnabled[rule.sectionID], let current = rule.enabled else { return false }
            return draft != current
        }
    }

    private func preparePlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped else { return }
        var edited = configuration
        for rule in SocatParser.parse(configuration) {
            guard let draft = draftEnabled[rule.sectionID], let current = rule.enabled, draft != current,
                  let index = edited.sections.firstIndex(where: { $0.id == rule.sectionID }),
                  let option = boolOptionName(in: edited.sections[index], candidates: ["enable", "enabled"])
            else { continue }
            edited.sections[index].values[option] = .string(draft ? "1" : "0")
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        state = await dedicatedConfigState("luci_socat", using: readClient)
        if case .loaded(let wrapped) = state, let configuration = wrapped {
            draftEnabled = Dictionary(uniqueKeysWithValues: SocatParser.parse(configuration)
                .compactMap { rule in rule.enabled.map { (rule.sectionID, $0) } })
        }
    }
}

// MARK: - ZeroTier dedicated page (UCI layer only)

struct ZeroTierView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled: Bool?
    @State private var newNetworkID = ""
    @State private var formError: String?
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "zerotier")
            switch state {
            case .loading:
                ProgressView("正在读取 ZeroTier 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let wrapped):
                if let configuration = wrapped {
                    content(ZeroTierParser.parse(configuration), configuration: configuration)
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 zerotier 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
            }
            if let initName = store.capability?.services.first(where: { $0.key == "zerotier" })?.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("ZeroTier")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { prepareSwitchPlan() }
                    .disabled(!hasSwitchChange)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: "zerotier")) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ overview: ZeroTierOverview, configuration: RouterConfiguration) -> some View {
        Section("服务开关") {
            if let location = overview.switchLocation {
                Toggle("启用 ZeroTier", isOn: Binding(
                    get: { draftEnabled ?? location.current },
                    set: { draftEnabled = $0 }))
                Text("保存后写入路由器配置并重启 ZeroTier 服务生效。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            } else {
                Text("未在配置中识别到启用开关的位置，开关为只读。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
            if let planError {
                Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        Section("已加入的网络") {
            if overview.networks.isEmpty {
                EmptyStateView(title: "尚未加入网络", message: "在下方输入网络 ID 即可加入一个 ZeroTier 网络。")
            } else {
                ForEach(overview.networks) { network in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(network.networkID)
                            .font(AppTypography.rowTitle.monospaced())
                        if network.hasAllowFlags {
                            if let managed = network.allowManaged {
                                LabeledContent("托管地址", value: managed ? L10n.string("允许") : L10n.string("不允许"))
                            }
                            if let global = network.allowGlobal {
                                LabeledContent("全局路由", value: global ? L10n.string("允许") : L10n.string("不允许"))
                            }
                            if let def = network.allowDefault {
                                LabeledContent("默认路由", value: def ? L10n.string("允许") : L10n.string("不允许"))
                            }
                            if let dns = network.allowDNS {
                                LabeledContent("DNS", value: dns ? L10n.string("允许") : L10n.string("不允许"))
                            }
                        }
                    }
                }
                .onDelete { offsets in leaveNetworks(at: offsets, overview: overview, configuration: configuration) }
            }
            Text("向左滑动可离开网络（经确认后写入配置）。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }
        Section("加入网络") {
            TextField("网络 ID（16 位十六进制）", text: $newNetworkID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                joinNetwork(overview: overview, configuration: configuration)
            } label: {
                Label("加入网络", systemImage: "plus.circle")
            }
            .disabled(newNetworkID.trimmingCharacters(in: .whitespaces).isEmpty)
            if let formError {
                Text(formError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
        }
        Section {
            Text("这里只显示路由器配置中加入的网络。节点的实时在线状态要靠路由器上的 ZeroTier 工具输出，路由器没有向 App 开放这条通道，所以这里不显示在线状态。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }
        DedicatedRawConfigSection(configuration: configuration)
    }

    private var hasSwitchChange: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let location = ZeroTierParser.parse(configuration).switchLocation,
              let draftEnabled else { return false }
        return draftEnabled != location.current
    }

    private func prepareSwitchPlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let location = ZeroTierParser.parse(configuration).switchLocation,
              let draftEnabled, draftEnabled != location.current,
              let index = configuration.sections.firstIndex(where: { $0.id == location.sectionID })
        else { return }
        var edited = configuration
        edited.sections[index].values[location.option] = .string(draftEnabled ? "1" : "0")
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func joinNetwork(overview: ZeroTierOverview, configuration: RouterConfiguration) {
        let candidate = newNetworkID.trimmingCharacters(in: .whitespaces).lowercased()
        guard ZeroTierParser.isValidNetworkID(candidate) else {
            formError = "网络 ID 应为 16 位十六进制字符。"
            return
        }
        guard !overview.networks.contains(where: { $0.networkID == candidate }) else {
            formError = "已经加入了这个网络。"
            return
        }
        var edited = configuration
        switch overview.joinTarget {
        case .newSection:
            var number = edited.sections.count + 1
            var id = "cfg\(number)"
            while edited.sections.contains(where: { $0.id == id }) { number += 1; id = "cfg\(number)" }
            edited.sections.append(ConfigurationSection(
                id: id, type: "network", anonymous: true, values: ["id": .string(candidate)]))
        case .listOption(let sectionID, let option):
            guard let index = edited.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            var values = edited.sections[index].values[option]?.arrayValue ?? []
            values.append(.string(candidate))
            edited.sections[index].values[option] = .array(values)
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            formError = nil
            newNetworkID = ""
        } catch {
            formError = FriendlyError.message(error)
        }
    }

    private func leaveNetworks(at offsets: IndexSet, overview: ZeroTierOverview,
                               configuration: RouterConfiguration) {
        var edited = configuration
        for offset in offsets {
            let network = overview.networks[offset]
            switch network.storage {
            case .section(let id):
                edited.sections.removeAll { $0.id == id }
            case .listValue(let sectionID, let option):
                guard let index = edited.sections.firstIndex(where: { $0.id == sectionID }) else { continue }
                let values = (edited.sections[index].values[option]?.arrayValue ?? [])
                    .filter { $0.stringValue != network.networkID }
                edited.sections[index].values[option] = .array(values)
            }
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
        } catch {
            formError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        state = await dedicatedConfigState("zerotier", using: readClient)
        if case .loaded(let wrapped) = state, let configuration = wrapped {
            draftEnabled = ZeroTierParser.parse(configuration).switchLocation?.current
        }
    }
}

// MARK: - WebDAV dedicated page (configuration layer)

struct WebdavView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled: Bool?
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "webdav")
            switch state {
            case .loading:
                ProgressView("正在读取 WebDAV 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let wrapped):
                if let configuration = wrapped {
                    content(WebdavParser.parse(configuration), configuration: configuration)
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 webdav 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
            }
            if let initName = store.capability?.services.first(where: { $0.key == "webdav" })?.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("WebDAV 文件服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { preparePlan() }
                    .disabled(!hasChanges)
            }
        }
        .task { await load() }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan,
                                        reloadServices: ConfigReloadMap.services(for: "webdav")) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ settings: WebdavSettings?, configuration: RouterConfiguration) -> some View {
        Section {
            Label("运行状态无法判定", systemImage: "questionmark.circle")
                .font(AppTypography.rowTitle)
            Text("WebDAV 服务不向路由器汇报运行状态（没有状态通道），这里只能确认下面的配置；服务是否真在运行，可到概览的进程页核对。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }
        if let settings {
            Section("共享设置") {
                if settings.enabled != nil {
                    Toggle("启用 WebDAV", isOn: Binding(
                        get: { draftEnabled ?? settings.enabled ?? false },
                        set: { draftEnabled = $0 }))
                }
                if let port = settings.listenPort {
                    LabeledContent("监听端口", value: port)
                }
                if let root = settings.rootDir {
                    LabeledContent("共享目录", value: root)
                }
                if let ssl = settings.ssl {
                    LabeledContent("HTTPS", value: ssl ? L10n.string("已开启") : L10n.string("已关闭"))
                }
                if let wan = settings.allowWAN {
                    LabeledContent("允许外网访问", value: wan ? L10n.string("允许") : L10n.string("不允许"))
                }
                if let user = settings.username {
                    LabeledContent("账号", value: user)
                }
                LabeledContent("密码", value: settings.hasPassword ? L10n.string("已设置（不显示）") : L10n.string("未设置"))
                if let planError {
                    Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
            }
        } else {
            Section {
                EmptyStateView(title: "无配置数据", message: "配置里没有找到 WebDAV 的设置节。")
            }
        }
        Section {
            NavigationLink {
                ConfigEditorView(configName: "webdav", title: "WebDAV 文件服务")
            } label: {
                Label("编辑配置", systemImage: "square.and.pencil")
            }
        }
        DedicatedRawConfigSection(configuration: configuration)
    }

    private var hasChanges: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let settings = WebdavParser.parse(configuration),
              let draftEnabled, let current = settings.enabled else { return false }
        return draftEnabled != current
    }

    private func preparePlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let settings = WebdavParser.parse(configuration),
              let draftEnabled, let current = settings.enabled, draftEnabled != current,
              let index = configuration.sections.firstIndex(where: { $0.id == settings.sectionID }),
              let option = boolOptionName(in: configuration.sections[index], candidates: ["enable", "enabled"])
        else { return }
        var edited = configuration
        edited.sections[index].values[option] = .string(draftEnabled ? "1" : "0")
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        state = await dedicatedConfigState("webdav", using: readClient)
        if case .loaded(let wrapped) = state, let configuration = wrapped {
            draftEnabled = WebdavParser.parse(configuration)?.enabled
        }
    }
}
