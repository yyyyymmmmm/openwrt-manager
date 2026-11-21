import SwiftUI
import OpenWrtKit

// MARK: - Shared header for the dedicated service pages (package F)
//
// The same opening every dedicated page gives: the package-E verdict
// banner, then the snapshot's real service state. The state comes
// from the discovery snapshot (init.d truth), never from a page-local
// guess.

struct DedicatedServiceHeader: View {
    @Environment(RouterStore.self) private var store
    let serviceKey: String

    private var service: CapabilitySnapshot.CapabilityService? {
        store.capability?.services.first { $0.key == serviceKey }
    }

    var body: some View {
        if let service {
            Section {
                SummaryBanner(summary: SummaryEngine.serviceState(running: service.running))
                    .summaryRow()
            }
            Section("服务状态") {
                LabeledContent("运行状态", value: service.running.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                if service.running == nil, let note = service.statusNote {
                    Text(note)
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
                LabeledContent("开机自启", value: service.enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
                if !service.initNames.isEmpty {
                    LabeledContent("init.d 服务", value: service.initNames.joined(separator: L10n.string("、")))
                }
            }
        }
    }
}

// MARK: - Dynamic DNS dedicated page (luci.ddns + UCI ddns)

struct DDNSView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<DDNSData> = .loading
    @State private var confirmingForceUpdate = false
    @State private var actionResult: String?
    @State private var working = false

    struct DDNSData {
        var global: DDNSGlobalState?
        var runtime: [String: DDNSServiceRuntime]
        var configuration: RouterConfiguration
        var logs: [String: [String]]
    }

    private var serviceSections: [ConfigurationSection] {
        guard case .loaded(let data) = state else { return [] }
        return data.configuration.sections.filter { $0.type == "ddns" && $0.id != "global" }
    }

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "ddns")
            switch state {
            case .loading:
                ProgressView("正在读取动态 DNS…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let data):
                if let global = data.global {
                    Section("全局状态") {
                        if let enabled = global.autostartEnabled {
                            LabeledContent("开机自启", value: enabled ? L10n.string("已启用") : L10n.string("未启用"))
                        }
                        if let version = global.version {
                            LabeledContent("版本", value: version)
                        }
                        if let updated = global.servicesListUpdated {
                            LabeledContent("服务列表更新于", value: updated)
                        }
                    }
                }
                if serviceSections.isEmpty {
                    Section {
                        EmptyStateView(title: "暂无 DDNS 条目", message: "路由器上还没有配置动态 DNS 服务条目，可在编辑配置中新增。")
                    }
                }
                ForEach(serviceSections) { section in
                    serviceSection(section, runtime: data.runtime[section.id], log: data.logs[section.id] ?? [])
                }
                Section("操作") {
                    Button {
                        confirmingForceUpdate = true
                    } label: {
                        Label("强制更新（重启服务）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(working || store.isMutating)
                    NavigationLink {
                        ConfigEditorView(configName: "ddns", title: "动态 DNS")
                    } label: {
                        Label("编辑配置", systemImage: "square.and.pencil")
                    }
                    if working { HStack { ProgressView(); Text("正在执行…") } }
                    if let actionResult {
                        Text(actionResult).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
        .navigationTitle("动态 DNS")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("强制更新将重启 DDNS 服务，所有条目立即重新上报当前 IP。",
                            isPresented: $confirmingForceUpdate, titleVisibility: .visible) {
            Button("重启并更新") { Task { await forceUpdate() } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func serviceSection(_ section: ConfigurationSection, runtime: DDNSServiceRuntime?, log: [String]) -> some View {
        let host = section.values["lookup_host"]?.stringValue ?? section.values["domain"]?.stringValue ?? section.id
        Section(host) {
            if let provider = section.values["service_name"]?.stringValue {
                LabeledContent("服务商", value: provider)
            }
            if let domain = section.values["domain"]?.stringValue {
                LabeledContent("域名", value: domain)
            }
            if let interface = section.values["interface"]?.stringValue {
                LabeledContent("接口", value: interface)
            }
            let enabled = DedicatedValue.truthy(section.values["enabled"])
            LabeledContent("条目启用", value: enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
            if section.values["password"] != nil {
                LabeledContent("密码", value: L10n.string("已设置（不显示）"))
            }
            if let runtime {
                LabeledContent("当前 IP", value: runtime.ip ?? L10n.string("暂无数据"))
                LabeledContent("运行进程", value: runtime.running ? L10n.format("运行中（PID %lld）", runtime.pid ?? 0) : L10n.string("未运行"))
                if let last = runtime.lastUpdate {
                    LabeledContent("上次更新", value: last)
                }
                if let next = runtime.nextUpdate {
                    LabeledContent("下次更新", value: Self.nextUpdateText(next))
                }
                if let check = runtime.nextCheck {
                    LabeledContent("下次检查", value: check)
                }
            } else {
                LabeledContent("当前 IP", value: L10n.string("暂无数据"))
            }
        }
        if !log.isEmpty {
            RawDataSection(title: "更新日志") {
                ForEach(Array(log.suffix(60).enumerated()), id: \.offset) { _, line in
                    Text(line).font(AppTypography.metadata.monospaced())
                        .foregroundStyle(AppPalette.muted)
                }
            }
        }
    }

    /// The daemon's next-update state words, mapped the way LuCI's own
    /// view maps them; anything else is a formatted time and passes
    /// through untouched.
    private static func nextUpdateText(_ raw: String) -> String {
        switch raw {
        case "Verify": return L10n.string("正在验证")
        case "Run once": return L10n.string("运行一次")
        case "Disabled": return L10n.string("已禁用")
        case "Stopped": return L10n.string("已停止")
        default: return raw
        }
    }

    private func forceUpdate() async {
        working = true
        defer { working = false }
        do {
            try await store.performServiceAction(name: "ddns", action: .restart)
            actionResult = "已重启 DDNS 服务，状态已重新读取。"
            await load()
        } catch {
            actionResult = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let client = store.dedicatedClient, let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        do {
            let configuration = try await readClient.configuration("ddns")
            let global = try? await client.ddnsGlobalState()
            let runtimes = (try? await client.ddnsServicesStatus()) ?? []
            var logs: [String: [String]] = [:]
            for section in configuration.sections where section.type == "ddns" && section.id != "global" {
                if let lines = try? await client.ddnsServiceLog(service: section.id), !lines.isEmpty {
                    logs[section.id] = lines
                }
            }
            state = .loaded(DDNSData(global: global,
                                     runtime: Dictionary(uniqueKeysWithValues: runtimes.map { ($0.section, $0) }),
                                     configuration: configuration, logs: logs))
        } catch {
            state = .failed(FriendlyError.message(error))
        }
    }
}

// MARK: - App filter dedicated page (appfilter ubus + UCI appfilter)

struct AppFilterView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<AppFilterData> = .loading
    @State private var draftEnabled: Bool?
    @State private var draftSelection: Set<String> = []
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    struct AppFilterData {
        var status: AppFilterStatus?
        var classes: [AppFilterClass]
        var selection: Set<String>
        var classVisits: [AppFilterClassVisit]
        var deviceVisits: [AppFilterDeviceVisit]
        var configuration: RouterConfiguration?
        var switchLocation: DedicatedConfigDiscovery.SwitchLocation?
        var listLocation: DedicatedConfigDiscovery.ListLocation?
    }

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "appfilter")
            switch state {
            case .loading:
                ProgressView("正在读取应用过滤…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let data):
                Section("过滤设置") {
                    if let location = data.switchLocation {
                        Toggle("启用应用过滤", isOn: Binding(
                            get: { draftEnabled ?? location.current },
                            set: { draftEnabled = $0 }))
                        Text("总开关写入路由器配置，保存后重启应用过滤服务生效。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    } else if data.status?.enabled != nil {
                        LabeledContent("过滤状态", value: data.status?.enabled == true ? L10n.string("已开启") : L10n.string("已关闭"))
                        Text("未在配置中识别到总开关的位置，开关为只读。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    } else {
                        Text("未能读取过滤状态。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
                Section("分类规则") {
                    if data.classes.isEmpty {
                        EmptyStateView(title: "暂无分类数据", message: "路由器未返回应用分类目录。")
                    } else {
                        ForEach(data.classes) { category in
                            Toggle(isOn: Binding(
                                get: { isSelected(category, in: data) },
                                set: { setSelected(category, $0) })) {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(category.name).font(AppTypography.row)
                                    if !category.apps.isEmpty {
                                        Text(category.apps.prefix(6).joined(separator: L10n.string("、")))
                                            .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .disabled(data.listLocation == nil)
                        }
                        if data.listLocation == nil {
                            Text("未识别到分类规则的配置存储位置，规则为只读（上方开关状态来自路由器实时规则）。")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                    if let planError {
                        Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                    }
                }
                if !data.classVisits.isEmpty || !data.deviceVisits.isEmpty {
                    Section("访问统计") {
                        ForEach(data.classVisits.prefix(12)) { visit in
                            LabeledContent(visit.name, value: L10n.format("%lld 次", visit.value))
                        }
                        ForEach(data.deviceVisits.prefix(12)) { visit in
                            HStack {
                                Text(visit.device).font(AppTypography.row)
                                Spacer()
                                Text(deviceVisitText(visit)).font(AppTypography.secondary)
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                } else {
                    Section("访问统计") {
                        Text("暂无统计（过滤关闭或尚无命中时为空）。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
                ServiceActionsSection(serviceName: "appfilter")
            }
        }
        .navigationTitle("应用过滤")
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
                                        reloadServices: ConfigReloadMap.services(for: "appfilter")) {
                Task { await load() }
            }
        }
    }

    private var hasChanges: Bool {
        guard case .loaded(let data) = state else { return false }
        if let location = data.switchLocation, let draftEnabled, draftEnabled != location.current { return true }
        if data.listLocation != nil, draftSelection != data.selection { return true }
        return false
    }

    private func isSelected(_ category: AppFilterClass, in data: AppFilterData) -> Bool {
        draftSelection.contains(category.identifier) || draftSelection.contains(category.name)
    }

    private func setSelected(_ category: AppFilterClass, _ selected: Bool) {
        if selected {
            draftSelection.insert(category.identifier)
        } else {
            draftSelection.remove(category.identifier)
            draftSelection.remove(category.name)
        }
    }

    private func deviceVisitText(_ visit: AppFilterDeviceVisit) -> String {
        var parts: [String] = []
        if let visits = visit.visits { parts.append(L10n.format("%lld 次", visits)) }
        if let seconds = visit.durationSeconds { parts.append(L10n.format("%lld 秒", seconds)) }
        return parts.isEmpty ? "—" : parts.joined(separator: L10n.string(" · "))
    }

    private func preparePlan() {
        guard case .loaded(let data) = state, let configuration = data.configuration else { return }
        var edited = configuration
        if let location = data.switchLocation, let draftEnabled, draftEnabled != location.current,
           let index = edited.sections.firstIndex(where: { $0.id == location.sectionID }) {
            edited.sections[index].values[location.option] = .string(draftEnabled ? "1" : "0")
        }
        if let location = data.listLocation,
           let index = edited.sections.firstIndex(where: { $0.id == location.sectionID }) {
            // Preserve any stored values that are not known categories,
            // and write the selection in catalogue order. The daemon's
            // live selection may key categories by name rather than id,
            // so both forms count as "selected" here.
            let known = Set(data.classes.map(\.identifier) + data.classes.map(\.name))
            let preserved = location.values.filter { !known.contains($0) }
            let chosen = data.classes
                .filter { draftSelection.contains($0.identifier) || draftSelection.contains($0.name) }
                .map(\.identifier)
            edited.sections[index].values[location.option] = .array((preserved + chosen).map(JSONValue.string))
        }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            planError = nil
        } catch {
            planError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let client = store.dedicatedClient, let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        let status = try? await client.appfilterStatus()
        let classes = (try? await client.appfilterClasses()) ?? []
        let selection = (try? await client.appfilterSelection()) ?? []
        let classVisits = (try? await client.appfilterClassVisits()) ?? []
        let deviceVisits = (try? await client.appfilterDeviceVisits()) ?? []
        let configuration = try? await readClient.configuration("appfilter")
        if status == nil, classes.isEmpty, configuration == nil {
            state = .failed(L10n.string("未能读取应用过滤数据，请稍后重试。"))
            return
        }
        let switchLocation = configuration.flatMap {
            DedicatedConfigDiscovery.booleanSwitch(in: $0, options: ["enable", "enabled"])
        }
        let knownIDs = Set(classes.map(\.identifier) + classes.map(\.name))
        let listLocation = configuration.flatMap {
            DedicatedConfigDiscovery.classListStorage(in: $0, knownIdentifiers: knownIDs.union(selection))
        }
        draftEnabled = switchLocation?.current
        draftSelection = selection
        state = .loaded(AppFilterData(status: status, classes: classes, selection: selection,
                                      classVisits: classVisits, deviceVisits: deviceVisits,
                                      configuration: configuration,
                                      switchLocation: switchLocation, listLocation: listLocation))
    }
}

// MARK: - Wake-on-LAN dedicated page (luci.wol + UCI luci-wol)

struct WolView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<WolData> = .loading
    @State private var wakeTarget: ConfigurationSection?
    @State private var wakeResult: String?
    @State private var working = false
    @State private var adhocMAC = ""
    @State private var newName = ""
    @State private var newMAC = ""
    @State private var newInterface = ""
    @State private var newBroadcast = false
    @State private var newPassword = ""
    @State private var formError: String?
    @State private var plan: PlanPresentation?

    struct WolData {
        var programs: WolPrograms
        var configuration: RouterConfiguration?
        var executable: String?
        var targets: [ConfigurationSection]
    }

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "wol")
            switch state {
            case .loading:
                ProgressView("正在读取网络唤醒…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let data):
                Section("可用程序") {
                    LabeledContent("etherwake", value: data.programs.etherwake ? L10n.string("已安装") : L10n.string("未安装"))
                    LabeledContent("wakeonlan", value: data.programs.wakeonlan ? L10n.string("已安装") : L10n.string("未安装"))
                    if let executable = data.executable {
                        LabeledContent("默认程序", value: executable)
                    }
                    if !data.programs.anyAvailable {
                        Label("路由器上未安装 etherwake 或 wakeonlan，无法发送魔术包。", systemImage: "exclamationmark.triangle")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                    }
                }
                Section("唤醒目标") {
                    if data.targets.isEmpty {
                        EmptyStateView(title: "暂无唤醒目标", message: "在下方添加常唤醒的设备，或直接输入 MAC 地址唤醒任意设备。")
                    } else {
                        ForEach(data.targets) { target in
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(target.values["name"]?.stringValue ?? target.id).font(AppTypography.rowTitle)
                                    Text(target.values["mac"]?.stringValue ?? "")
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                    if let iface = target.values["iface"]?.stringValue, !iface.isEmpty {
                                        Text(iface).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                    }
                                }
                                Spacer()
                                Button("唤醒") { wakeTarget = target }
                                    .disabled(working || !data.programs.anyAvailable)
                            }
                        }
                        .onDelete { offsets in deleteTargets(at: offsets, in: data) }
                    }
                    if working { HStack { ProgressView(); Text("正在发送…") } }
                    if let wakeResult {
                        Text(wakeResult).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
                Section("唤醒任意设备") {
                    TextField("MAC 地址", text: $adhocMAC)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("发送魔术包") { Task { await wakeAdhoc(data) } }
                        .disabled(working || !data.programs.anyAvailable || adhocMAC.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if data.configuration != nil {
                    Section("添加目标") {
                        TextField("名称", text: $newName)
                        TextField("MAC 地址", text: $newMAC)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("接口（可选，如 br-lan）", text: $newInterface)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("广播发送", isOn: $newBroadcast)
                        SecureField("唤醒密码（可选）", text: $newPassword)
                        Button {
                            addTarget(in: data)
                        } label: {
                            Label("添加目标", systemImage: "plus.circle")
                        }
                        if let formError {
                            Text(formError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                        }
                    }
                    Section {
                        NavigationLink {
                            ConfigEditorView(configName: "luci-wol", title: "网络唤醒")
                        } label: {
                            Label("高级编辑（含默认程序）", systemImage: "square.and.pencil")
                        }
                    }
                }
                if let service = store.capability?.services.first(where: { $0.key == "wol" }),
                   let initName = service.initNames.first {
                    ServiceActionsSection(serviceName: initName)
                }
            }
        }
        .navigationTitle("网络唤醒")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            wakeTarget.map { L10n.format("向「%@」发送魔术包？", $0.values["name"]?.stringValue ?? $0.id) } ?? "",
            isPresented: Binding(get: { wakeTarget != nil }, set: { if !$0 { wakeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("发送") {
                if let target = wakeTarget, case .loaded(let data) = state {
                    Task { await wake(target: target, in: data) }
                }
                wakeTarget = nil
            }
            Button("取消", role: .cancel) { wakeTarget = nil }
        }
        .sheet(item: $plan) { presentation in
            TransactionConfirmationView(plan: presentation.plan, reloadServices: []) {
                Task { await load() }
            }
        }
    }

    private func wake(target: ConfigurationSection, in data: WolData) async {
        guard let mac = target.values["mac"]?.stringValue else { return }
        await sendWake(mac: mac,
                       interface: target.values["iface"]?.stringValue,
                       broadcast: DedicatedValue.truthy(target.values["broadcast"]) ?? false,
                       password: target.values["password"]?.stringValue,
                       in: data)
    }

    private func wakeAdhoc(_ data: WolData) async {
        await sendWake(mac: adhocMAC.trimmingCharacters(in: .whitespaces),
                       interface: nil, broadcast: false, password: nil, in: data)
    }

    private func sendWake(mac: String, interface: String?, broadcast: Bool,
                          password: String?, in data: WolData) async {
        guard let client = store.dedicatedClient else { return }
        guard let request = WolWakeBuilder.request(executable: data.executable, programs: data.programs,
                                                   mac: mac, interface: interface,
                                                   broadcast: broadcast, password: password) else {
            wakeResult = "没有可用的唤醒程序。"
            return
        }
        working = true
        defer { working = false }
        do {
            let result = try await client.wolExec(name: request.name, args: request.args)
            if result.succeeded {
                wakeResult = L10n.format("魔术包已发送（%@）。", mac)
            } else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                wakeResult = detail.isEmpty
                    ? L10n.format("唤醒命令失败（代码 %lld）。", result.code ?? -1)
                    : L10n.format("唤醒命令失败：%@", detail)
            }
        } catch {
            wakeResult = FriendlyError.message(error)
        }
    }

    private func addTarget(in data: WolData) {
        guard let configuration = data.configuration else { return }
        let mac = newMAC.trimmingCharacters(in: .whitespaces)
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, mac.count == 17, mac.contains(":") else {
            formError = "请填写名称与完整的 MAC 地址（如 00:11:22:33:44:55）。"
            return
        }
        var values: [String: JSONValue] = [
            "name": .string(newName.trimmingCharacters(in: .whitespaces)),
            "mac": .string(mac)
        ]
        let iface = newInterface.trimmingCharacters(in: .whitespaces)
        if !iface.isEmpty { values["iface"] = .string(iface) }
        if newBroadcast { values["broadcast"] = .string("1") }
        if !newPassword.isEmpty { values["password"] = .string(newPassword) }
        var number = data.targets.count + 1
        var id = "cfg\(number)"
        while configuration.sections.contains(where: { $0.id == id }) { number += 1; id = "cfg\(number)" }
        var edited = configuration
        edited.sections.append(ConfigurationSection(id: id, type: "target", anonymous: true, values: values))
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
            formError = nil
            newName = ""; newMAC = ""; newInterface = ""; newBroadcast = false; newPassword = ""
        } catch {
            formError = FriendlyError.message(error)
        }
    }

    private func deleteTargets(at offsets: IndexSet, in data: WolData) {
        guard let configuration = data.configuration else { return }
        let removed = Set(offsets.map { data.targets[$0].id })
        var edited = configuration
        edited.sections.removeAll { removed.contains($0.id) }
        do {
            plan = try PlanPresentation(plan: ConfigurationPlan(original: configuration, edited: edited))
        } catch {
            formError = FriendlyError.message(error)
        }
    }

    private func load() async {
        guard let client = store.dedicatedClient, let readClient = store.readClient else {
            state = .failed(L10n.string("未连接路由器。")); return
        }
        state = .loading
        do {
            let programs = try await client.wolPrograms()
            let configuration = try? await readClient.configuration("luci-wol")
            let executable = configuration?.sections.first { $0.id == "defaults" }?.values["executable"]?.stringValue
            let targets = configuration?.sections.filter { $0.type == "target" } ?? []
            state = .loaded(WolData(programs: programs, configuration: configuration,
                                    executable: executable, targets: targets))
        } catch {
            state = .failed(FriendlyError.message(error))
        }
    }
}

// MARK: - KMS (vlmcsd) light dedicated page

struct VLMCSDView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var draftEnabled = false
    @State private var draftAutoactivate = false
    @State private var plan: PlanPresentation?
    @State private var planError: String?

    /// The settings section: the one carrying the known options when
    /// present, otherwise the configuration's first section.
    private func settingsSection(in configuration: RouterConfiguration) -> ConfigurationSection? {
        configuration.sections.first {
            $0.values["enabled"] != nil || $0.values["autoactivate"] != nil
        } ?? configuration.sections.first
    }

    var body: some View {
        List {
            DedicatedServiceHeader(serviceKey: "vlmcsd")
            switch state {
            case .loading:
                ProgressView("正在读取 KMS 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                if let configuration, let section = settingsSection(in: configuration) {
                    Section("激活设置") {
                        Toggle("启用 KMS 服务", isOn: $draftEnabled)
                        Toggle("自动激活", isOn: $draftAutoactivate)
                        Text("保存后写入路由器配置并重启 vlmcsd 服务生效。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        if let planError {
                            Text(planError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                        }
                    }
                } else {
                    Section {
                        EmptyStateView(title: "无配置数据", message: "此固件未向 App 会话开放 vlmcsd 配置的读取（rpcd 未授权或配置不存在）。")
                    }
                }
                ServiceActionsSection(serviceName: "vlmcsd")
            }
        }
        .navigationTitle("KMS 服务器")
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
                                        reloadServices: ConfigReloadMap.services(for: "vlmcsd")) {
                Task { await load() }
            }
        }
    }

    private var hasChanges: Bool {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let section = settingsSection(in: configuration) else { return false }
        return draftEnabled != (DedicatedValue.truthy(section.values["enabled"]) ?? false)
            || draftAutoactivate != (DedicatedValue.truthy(section.values["autoactivate"]) ?? false)
    }

    private func preparePlan() {
        guard case .loaded(let wrapped) = state, let configuration = wrapped,
              let section = settingsSection(in: configuration) else { return }
        var edited = configuration
        guard let index = edited.sections.firstIndex(where: { $0.id == section.id }) else { return }
        edited.sections[index].values["enabled"] = .string(draftEnabled ? "1" : "0")
        edited.sections[index].values["autoactivate"] = .string(draftAutoactivate ? "1" : "0")
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
        do {
            let configuration = try await readClient.configuration("vlmcsd")
            state = .loaded(configuration)
            if let section = settingsSection(in: configuration) {
                draftEnabled = DedicatedValue.truthy(section.values["enabled"]) ?? false
                draftAutoactivate = DedicatedValue.truthy(section.values["autoactivate"]) ?? false
            }
        } catch let error as OpenWrtKitError where error == .permissionDenied || error == .unsupported {
            state = .loaded(nil)
        } catch {
            state = .failed(FriendlyError.message(error))
        }
    }
}
