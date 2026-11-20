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
        case .failure(let error): snapshot.warnings.append("硬件信息：\(error.localizedDescription)")
        }
        switch infoResult {
        case .success(let value): info = value
        case .failure(let error): snapshot.warnings.append("运行状态：\(error.localizedDescription)")
        }
        snapshot.system = SnapshotParser.system(board: board, info: info)
        switch interfacesResult {
        case .success(let value):
            do { snapshot.interfaces = try SnapshotParser.interfaces(value) }
            catch { snapshot.warnings.append("网络接口：\(error.localizedDescription)") }
        case .failure(let error): snapshot.warnings.append("网络接口：\(error.localizedDescription)")
        }
        snapshot.refreshedAt = Date()
        return snapshot
    }

    public func leases() async throws -> [DHCPLease] {
        let value = try await caller.call(object: "luci-rpc", method: "getDHCPLeases")
        return try SnapshotParser.leases(value)
    }

    public func wireless() async throws -> [WirelessRadio] {
        let value = try await caller.call(object: "network.wireless", method: "status")
        return try SnapshotParser.wireless(value)
    }

    public func services() async throws -> [RouterService] {
        let value = try await caller.call(object: "service", method: "list")
        return try SnapshotParser.services(value)
    }

    public func inventory() async -> RouterInventory {
        async let menu = capture { try InventoryParser.menus(await caller.menu()) }
        async let packages = capture { try await caller.installedPackages() }
        async let configs = capture { try InventoryParser.configNames(await caller.call(object: "file", method: "list", parameters: ["path": .string("/etc/config")])) }
        async let startup = capture { try InventoryParser.initServices(await caller.call(object: "luci", method: "getInitList")) }
        let results = await (menu, packages, configs, startup)
        var inventory = RouterInventory()
        switch results.0 {
        case .success(let value): inventory.menus = value; inventory.menuRead = true
        case .failure(let error): inventory.warnings.append("功能目录：\(error.localizedDescription)")
        }
        switch results.1 {
        case .success(let value): inventory.packages = value; inventory.packagesRead = true
        case .failure(let error): inventory.warnings.append("软件包：\(error.localizedDescription)")
        }
        switch results.2 {
        case .success(let value): inventory.configNames = value; inventory.configsRead = true
        case .failure(let error): inventory.warnings.append("配置目录：\(error.localizedDescription)")
        }
        switch results.3 {
        case .success(let value): inventory.initServices = value; inventory.initRead = true
        case .failure(let error): inventory.warnings.append("启动项：\(error.localizedDescription)")
        }
        return inventory
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
        public var warnings: [String] = []
        public init() {}
    }

    public func discoveryRawData() async -> DiscoveryRawData {
        async let board = capture { try await caller.call(object: "system", method: "board") }
        async let interfaces = capture { try await caller.call(object: "network.interface", method: "dump") }
        async let wireless = capture { try await caller.call(object: "network.wireless", method: "status") }
        async let services = capture { try await caller.call(object: "service", method: "list") }
        let results = await (board, interfaces, wireless, services)
        var data = DiscoveryRawData()
        switch results.0 {
        case .success(let value): data.board = value
        case .failure(let error): data.warnings.append("发现-硬件信息：\(error.localizedDescription)")
        }
        switch results.1 {
        case .success(let value): data.interfaces = value
        case .failure(let error): data.warnings.append("发现-接口：\(error.localizedDescription)")
        }
        switch results.2 {
        case .success(let value): data.wireless = value
        case .failure(let error): data.warnings.append("发现-无线：\(error.localizedDescription)")
        }
        switch results.3 {
        case .success(let value): data.services = value
        case .failure(let error): data.warnings.append("发现-服务状态：\(error.localizedDescription)")
        }
        return data
    }

    public func serviceAction(name: String, action: ServiceAction) async throws {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let initList = try InventoryParser.initServices(await caller.call(object: "luci", method: "getInitList"))
        guard initList.contains(where: { $0.name == name }) else { throw OpenWrtKitError.unsupported("此服务不在路由器的启动项目录中。") }
        let access = try await caller.call(object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("luci"), "function": .string("setInitAction")
        ])
        guard access["access"].boolValue == true else { throw OpenWrtKitError.permissionDenied }
        let value = try await caller.call(object: "luci", method: "setInitAction", parameters: [
            "name": .string(name), "action": .string(action.rawValue)
        ])
        guard value["result"].boolValue == true else { throw OpenWrtKitError.unsupported("路由器未确认服务操作成功，请检查日志和当前状态。") }
    }

    public func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        switch kind {
        case .logs:
            let value = try await caller.call(object: "log", method: "read", parameters: [
                "lines": .number(200), "oneshot": .bool(true), "stream": .bool(false)
            ])
            guard let records = value["log"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
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
        case .logs: return "系统日志"
        case .processes: return "运行进程"
        case .mounts: return "存储挂载"
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
            let lease = DHCPLease(hostname: item["hostname"].stringValue ?? "未命名设备", address: address,
                                  mac: item["macaddr"].stringValue ?? "—",
                                  expires: item["expires"].intValue, duid: item["duid"].stringValue)
            return seen.insert(lease.id).inserted ? lease : nil
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
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
            return WirelessRadio(name: name, up: radio["up"].boolValue, channel: radio["config"]["channel"].textValue ?? "未报告",
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
