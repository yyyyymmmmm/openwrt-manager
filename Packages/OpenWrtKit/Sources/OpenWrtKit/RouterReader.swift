import Foundation

public struct RouterReader: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public init(client: UbusClient, session: UbusSession) {
        self.caller = FixedSessionCaller(client: client, session: session)
    }

    public func snapshot() async throws -> RouterSnapshot {
        async let boardRead = read("system", "board")
        async let infoRead = read("system", "info")
        async let interfaceRead = read("network.interface", "dump")
        let (boardResult, infoResult, interfacesResult) = await (boardRead, infoRead, interfaceRead)
        try Task.checkCancellation()
        if case .failure(let error) = boardResult, case .failure = infoResult { throw error }
        var snapshot = RouterSnapshot()
        var board: JSONValue = .null
        var info: JSONValue = .null
        switch boardResult {
        case .success(let value): board = value
        case .failure(let error): snapshot.warnings.append(KitL10n.format("硬件信息：%@", KitErrorSummary.summary(for: error)))
        }
        switch infoResult {
        case .success(let value): info = value
        case .failure(let error): snapshot.warnings.append(KitL10n.format("运行状态：%@", KitErrorSummary.summary(for: error)))
        }
        snapshot.system = SnapshotParser.system(board: board, info: info)
        switch interfacesResult {
        case .success(let value):
            do { snapshot.interfaces = try SnapshotParser.interfaces(value) }
            catch { snapshot.warnings.append(KitL10n.format("网络接口：%@", KitErrorSummary.summary(for: error))) }
        case .failure(let error): snapshot.warnings.append(KitL10n.format("网络接口：%@", KitErrorSummary.summary(for: error)))
        }
        snapshot.refreshedAt = Date()
        return snapshot
    }

    public func leases() async throws -> [DHCPLease] {
        let value = try await caller.call(object: "luci-rpc", method: "getDHCPLeases")
        return try SnapshotParser.leases(value)
    }

    /// Wireless radios via luci-rpc. `network.wireless status` is granted
    /// to NO login session on stock firmware (verified in the acl.d sets
    /// of both test routers), while getWirelessDevices is granted on both
    /// and returns an empty object — not an error — when no radio exists.
    public func wireless() async throws -> [WirelessRadio] {
        let value = try await caller.call(object: "luci-rpc", method: "getWirelessDevices")
        return try SnapshotParser.wirelessDevices(value)
    }

    /// Service state: procd's service list where it is granted, with the
    /// rc list as the fallback — firmware whose acl.d grants no "service"
    /// object at all (verified on the main router) still reports every
    /// service's enabled/running state through rc.
    public func services() async throws -> [RouterService] {
        do {
            let value = try await caller.call(object: "service", method: "list")
            return try SnapshotParser.services(value)
        } catch OpenWrtKitError.permissionDenied, OpenWrtKitError.unsupported {
            let value = try await caller.call(object: "rc", method: "list")
            return try InventoryParser.rcServices(value).map { name, state in
                RouterService(name: name,
                              runningInstances: state.running.map { $0 ? 1 : 0 },
                              totalInstances: 1)
            }.sorted { $0.name < $1.name }
        }
    }

    public func inventory() async -> RouterInventory {
        async let menu = capture { try InventoryParser.menus(await caller.menu()) }
        async let packages = capture { try await caller.installedPackages() }
        async let configs = capture { try InventoryParser.configNames(await caller.call(object: "file", method: "list", parameters: ["path": .string("/etc/config")])) }
        async let startup = capture { try await initServiceList() }
        let results = await (menu, packages, configs, startup)
        var inventory = RouterInventory()
        switch results.0 {
        case .success(let value): inventory.menus = value; inventory.menuRead = true
        case .failure(let error): inventory.warnings.append(KitL10n.format("功能目录：%@", KitErrorSummary.summary(for: error)))
        }
        switch results.1 {
        case .success(let value): inventory.packages = value; inventory.packagesRead = true
        case .failure(let error): inventory.warnings.append(KitL10n.format("软件包：%@", KitErrorSummary.summary(for: error)))
        }
        switch results.2 {
        case .success(let value): inventory.configNames = value; inventory.configsRead = true
        case .failure(let error): inventory.warnings.append(KitL10n.format("配置目录：%@", KitErrorSummary.summary(for: error)))
        }
        switch results.3 {
        case .success(let value): inventory.initServices = value; inventory.initRead = true
        case .failure(let error): inventory.warnings.append(KitL10n.format("启动项：%@", KitErrorSummary.summary(for: error)))
        }
        // Menu titles arrive as LuCI source strings on every firmware —
        // the router never translates them (see LuciTranslationCatalog).
        // Localize them with the router's own catalog, the web UI's
        // mechanism; a catalog problem degrades to source-language
        // titles plus a warning, never to a failed discovery. The
        // negotiated language is recorded on the inventory so the
        // snapshot (and its cache) is tagged with the language its
        // titles are actually in.
        if inventory.menuRead {
            do {
                let localization = try await caller.localization()
                inventory.language = localization.language
                if let catalog = localization.catalog {
                    inventory.menus = inventory.menus.map { $0.applyingTranslations(catalog) }
                }
            } catch {
                inventory.warnings.append(KitL10n.format("菜单翻译：未能加载路由器语言包，标题保留原文（%@）", KitErrorSummary.summary(for: error)))
            }
        }
        return inventory
    }

    /// The session's localization context, for sub-pages that resolve
    /// router-source display strings (generic-page section/field names)
    /// after discovery. Never throws: any failure degrades to the
    /// source context, i.e. strings stay as the router served them.
    public func localization() async -> LuciLocalization {
        (try? await caller.localization()) ?? .source
    }

    /// Raw discovery inputs that the typed SnapshotParser views discard
    /// (interface routes, l3 devices, per-service instance state). Each read
    /// is captured independently; failures land in warnings, never as
    /// fabricated data.
    public struct DiscoveryRawData: Sendable {
        public var board: JSONValue?
        public var interfaces: JSONValue?
        public var wireless: JSONValue?
        public var services: JSONValue?
        public var rcList: JSONValue?
        public var warnings: [String] = []
        public init() {}
    }

    public func discoveryRawData() async -> DiscoveryRawData {
        async let board = capture { try await caller.call(object: "system", method: "board") }
        async let interfaces = capture { try await caller.call(object: "network.interface", method: "dump") }
        async let wireless = capture { try await caller.call(object: "luci-rpc", method: "getWirelessDevices") }
        async let services = capture { try await caller.call(object: "service", method: "list") }
        async let rcList = capture { try await caller.call(object: "rc", method: "list") }
        let results = await (board, interfaces, wireless, services, rcList)
        var data = DiscoveryRawData()
        switch results.0 {
        case .success(let value): data.board = value
        case .failure(let error): data.warnings.append(KitL10n.format("发现-硬件信息：%@", KitErrorSummary.summary(for: error)))
        }
        switch results.1 {
        case .success(let value): data.interfaces = value
        case .failure(let error): data.warnings.append(KitL10n.format("发现-接口：%@", KitErrorSummary.summary(for: error)))
        }
        switch results.2 {
        case .success(let value): data.wireless = value
        case .failure:
            // No warning on purpose: "no radios" and "wireless not
            // granted" must both present as simply no wireless pages.
            // getWirelessDevices returns {} for the no-radio case, so a
            // failure here only ever means the latter.
            data.wireless = nil
        }
        switch results.3 {
        case .success(let value): data.services = value
        case .failure(let error):
            // rc list (read alongside) carries the same running state on
            // firmware that grants no service object; only warn when rc
            // could not fill the gap either.
            if case .failure = results.4 {
                data.warnings.append(KitL10n.format("发现-服务状态：%@", KitErrorSummary.summary(for: error)))
            }
        }
        switch results.4 {
        case .success(let value): data.rcList = value
        case .failure: data.rcList = nil
        }
        return data
    }

    /// Init-service catalogue (name + enabled). Source of truth is the rc
    /// list — granted on both test firmwares and richer (it also carries
    /// running state); luci getInitList is only a fallback because some
    /// firmware grants it to no session at all (verified on the main
    /// router: no acl.d group authorizes it there).
    private func initServiceList() async throws -> [InitService] {
        do {
            let value = try await caller.call(object: "rc", method: "list")
            let services = try InventoryParser.initServices(value)
            // A real rc list is never empty (every firmware ships init
            // scripts); an empty answer means the object is not really
            // there, so fall through to the legacy source.
            if !services.isEmpty { return services }
        } catch OpenWrtKitError.permissionDenied, OpenWrtKitError.unsupported {
            // Fall through to the legacy source.
        }
        let value = try await caller.call(object: "luci", method: "getInitList")
        return try InventoryParser.initServices(value)
    }

    /// Drops the underlying session (discovery self-healing hook).
    public func invalidateSession() async {
        await caller.invalidateSession()
    }

    public func serviceAction(name: String, action: ServiceAction) async throws {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let initList = try await initServiceList()
        guard initList.contains(where: { $0.name == name }) else { throw OpenWrtKitError.unsupported(KitL10n.text("此服务不在路由器的启动项目录中。")) }
        // Two channels carry init actions, and firmware grants them
        // independently (permission audit #1): luci setInitAction is
        // granted on the bypass router but by NO acl group on stock
        // firmware (the main router), where every action used to die
        // as "permission denied"; the rc object's init method is
        // granted on both. Probe the session's actual grant and take
        // the channel it holds.
        if await sessionAccess(scope: "ubus", object: "luci", function: "setInitAction") {
            let value = try await caller.call(object: "luci", method: "setInitAction", parameters: [
                "name": .string(name), "action": .string(action.rawValue)
            ])
            guard value["result"].boolValue == true else { throw OpenWrtKitError.unsupported(KitL10n.text("路由器未确认服务操作成功，请检查日志和当前状态。")) }
        } else {
            _ = try await caller.call(object: "rc", method: "init", parameters: [
                "name": .string(name), "action": .string(action.rawValue)
            ])
        }
    }

    /// Whether this session is granted one (scope, object, function)
    /// triple, per rpcd's own access query. A query that fails reads
    /// as "not granted" — callers use this to pick a channel or gate
    /// an entry, where the safe direction is the closed one.
    private func sessionAccess(scope: String, object: String, function: String) async -> Bool {
        guard let value = try? await caller.call(object: "session", method: "access", parameters: [
            "scope": .string(scope), "object": .string(object), "function": .string(function)
        ]) else { return false }
        return value["access"].boolValue == true
    }

    public func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        switch kind {
        case .logs:
            do {
                let value = try await caller.call(object: "log", method: "read", parameters: [
                    "lines": .number(200), "oneshot": .bool(true), "stream": .bool(false)
                ])
                guard let records = value["log"].arrayValue else { throw OpenWrtKitError.malformedResponse }
                return records
            } catch OpenWrtKitError.permissionDenied, OpenWrtKitError.unsupported {
                // Firmware whose acl.d grants no log object at all
                // (the main router, stock 24.10): the same
                // syslog-wrapper fallback ReadOnlyDataClient.systemLog
                // uses, which IS granted there (permission audit
                // #14). The wrapper prints the whole log oldest
                // first; keep the newest 200 lines as plain records.
                let value = try await caller.call(object: "file", method: "exec", parameters: [
                    "command": .string("/usr/libexec/syslog-wrapper"), "params": .array([])
                ])
                guard value["code"].intValue == 0, let output = value["stdout"].stringValue else {
                    throw OpenWrtKitError.permissionDenied
                }
                return output.split(whereSeparator: \.isNewline).suffix(200).map { .string(String($0)) }
            }
        case .processes, .mounts:
            let method = kind == .processes ? "getProcessList" : "getMountPoints"
            let value = try await caller.call(object: "luci", method: method)
            guard let records = value["result"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
        }
    }

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    public func logout() async {
        await caller.destroySession()
    }

    private func read(_ object: String, _ method: String) async -> Result<JSONValue, Error> {
        do {
            let value = try await caller.call(object: object, method: method)
            guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            return .success(value)
        }
        catch { return .failure(error) }
    }
}

public enum RouterRecordKind: String, CaseIterable, Identifiable, Sendable {
    case logs, processes, mounts
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .logs: return KitL10n.text("系统日志")
        case .processes: return KitL10n.text("运行进程")
        case .mounts: return KitL10n.text("存储挂载")
        }
    }
}

public enum SnapshotParser {
    public static func system(board: JSONValue, info: JSONValue) -> SystemSnapshot {
        var result = SystemSnapshot()
        result.hostname = board["hostname"].stringValue ?? "—"
        result.model = board["model"].stringValue ?? board["board_name"].stringValue ?? "—"
        result.kernel = board["kernel"].stringValue ?? "—"
        result.architecture = board["release"]["target"].stringValue ?? board["system"].stringValue ?? "—"
        let release = board["release"]
        let firmware = [release["distribution"].stringValue, release["version"].stringValue].compactMap { $0 }.joined(separator: " ")
        result.firmware = firmware.isEmpty ? "—" : firmware
        result.uptime = info["uptime"].doubleValue
        if let total = info["memory"]["total"].intValue, total > 0 {
            let available = info["memory"]["available"].intValue ?? info["memory"]["free"].intValue
            result.memoryTotal = Int64(total)
            if let available { result.memoryUsed = Int64(max(0, total - available)) }
        }
        if let total = info["root"]["total"].intValue, let used = info["root"]["used"].intValue, total > 0 {
            result.storageTotal = Int64(total); result.storageUsed = Int64(used)
        }
        // system.info load values are fixed point (scaled by 65536), not CPU %.
        result.loadAverage = (info["load"].arrayValue ?? []).compactMap { $0.doubleValue.map { $0 / 65536 } }
        return result
    }

    public static func interfaces(_ value: JSONValue) throws -> [NetworkInterfaceSnapshot] {
        guard let items = value["interface"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        return try items.map { item in
            guard let name = item["interface"].stringValue, !name.isEmpty else { throw OpenWrtKitError.malformedResponse }
            let addresses = try ["ipv4-address", "ipv6-address"].flatMap { key -> [String] in
                guard item[key] != .null else { return [] }
                guard let reported = item[key].arrayValue else { throw OpenWrtKitError.malformedResponse }
                return try reported.map { address in
                    guard let ip = address["address"].stringValue, !ip.isEmpty else { throw OpenWrtKitError.malformedResponse }
                    return ip + (address["mask"].intValue.map { "/\($0)" } ?? "")
                }
            }
            return NetworkInterfaceSnapshot(name: name, protocolName: item["proto"].stringValue ?? "—", addresses: addresses,
                                            up: item["up"].boolValue, device: item["l3_device"].stringValue)
        }.sorted { $0.name < $1.name }
    }

    public static func leases(_ value: JSONValue) throws -> [DHCPLease] {
        var reported: [JSONValue] = []
        var hasList = false
        for key in ["dhcp_leases", "dhcp6_leases"] where value[key] != .null {
            guard let leases = value[key].arrayValue else { throw OpenWrtKitError.malformedResponse }
            hasList = true
            reported.append(contentsOf: leases)
        }
        guard hasList else { throw OpenWrtKitError.malformedResponse }
        var seen = Set<String>()
        return try reported.compactMap { item -> DHCPLease? in
            let address = item["ipaddr"].stringValue
                ?? item["ip6addr"].stringValue
                ?? item["ip6addrs"].arrayValue?.first?.stringValue
            guard let address, !address.isEmpty else { throw OpenWrtKitError.malformedResponse }
            let lease = DHCPLease(hostname: item["hostname"].stringValue ?? KitL10n.text("未命名设备"), address: address,
                                  mac: item["macaddr"].stringValue ?? "—",
                                  expires: item["expires"].intValue, duid: item["duid"].stringValue)
            return seen.insert(lease.id).inserted ? lease : nil
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }

    /// luci-rpc getWirelessDevices, parsed defensively: the exact nesting
    /// (config under the radio vs under each interface, iwinfo placement)
    /// varies across rpcd builds, so every field is looked up in each of
    /// its plausible homes. An empty object — a router with no radios —
    /// parses to an empty list, never an error.
    public static func wirelessDevices(_ value: JSONValue) throws -> [WirelessRadio] {
        guard let radios = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return radios.map { name, radio in
            let interfaces = radio["interfaces"].arrayValue ?? []
            let channel = radio["config"]["channel"].textValue
                ?? radio["iwinfo"]["channel"].textValue
                ?? interfaces.first?["iwinfo"]["channel"].textValue
            var networks = interfaces.compactMap { $0["config"]["ssid"].stringValue ?? $0["iwinfo"]["ssid"].stringValue }
            if networks.isEmpty, let ssid = radio["config"]["ssid"].stringValue { networks = [ssid] }
            let up = radio["up"].boolValue
                ?? (interfaces.contains { $0["iwinfo"].objectValue != nil } ? true : nil)
            return WirelessRadio(name: name, up: up, channel: channel ?? KitL10n.text("未报告"), networks: networks)
        }.sorted { $0.name < $1.name }
    }

    public static func wireless(_ value: JSONValue) throws -> [WirelessRadio] {
        guard let radios = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try radios.map { name, radio in
            guard radio.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            let interfaces: [JSONValue]
            if radio["interfaces"] == .null { interfaces = [] }
            else {
                guard let reported = radio["interfaces"].arrayValue else { throw OpenWrtKitError.malformedResponse }
                interfaces = reported
            }
            guard interfaces.allSatisfy({ $0.objectValue != nil }) else { throw OpenWrtKitError.malformedResponse }
            return WirelessRadio(name: name, up: radio["up"].boolValue, channel: radio["config"]["channel"].textValue ?? KitL10n.text("未报告"),
                                 networks: interfaces.compactMap { $0["config"]["ssid"].stringValue })
        }.sorted { $0.name < $1.name }
    }

    public static func services(_ value: JSONValue) throws -> [RouterService] {
        guard let services = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try services.map { name, service in
            guard service.objectValue != nil,
                  service["instances"] == .null || service["instances"].objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            let instances = service["instances"].objectValue.map { Array($0.values) }
            guard instances?.allSatisfy({ $0.objectValue != nil }) != false else { throw OpenWrtKitError.malformedResponse }
            let running = instances.flatMap { values -> Int? in
                guard values.allSatisfy({ $0["running"].boolValue != nil }) else { return nil }
                return values.filter { $0["running"].boolValue == true }.count
            }
            return RouterService(name: name, runningInstances: running, totalInstances: instances?.count)
        }.sorted { $0.name < $1.name }
    }
}
