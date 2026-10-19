import Foundation
import Darwin

public struct RouterReader: Sendable {
    private let client: UbusClient
    private let session: UbusSession

    public init(client: UbusClient, session: UbusSession) {
        self.client = client; self.session = session
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
        let value = try await client.call(session: session, object: "luci-rpc", method: "getDHCPLeases")
        return try SnapshotParser.leases(value)
    }

    public func routing(interfaces: [NetworkInterfaceSnapshot]) async throws -> RouterRoutingSnapshot {
        async let ipv4Routes = ipOutput(["-4", "route", "show"])
        async let ipv6Routes = ipOutput(["-6", "route", "show"])
        async let ipv4Neighbors = ipOutput(["-4", "neigh", "show"])
        async let ipv6Neighbors = ipOutput(["-6", "neigh", "show"])
        let output = try await (ipv4Routes, ipv6Routes, ipv4Neighbors, ipv6Neighbors)
        return RouterRoutingSnapshot(
            ipv4Routes: try SnapshotParser.routes(output.0),
            ipv6Routes: try SnapshotParser.routes(output.1),
            ipv4Neighbors: try SnapshotParser.neighbors(output.2, interfaces: interfaces),
            ipv6Neighbors: try SnapshotParser.neighbors(output.3, interfaces: interfaces)
        )
    }

    public func wireless() async throws -> [WirelessRadio] {
        let value = try await client.call(session: session, object: "network.wireless", method: "status")
        return try SnapshotParser.wireless(value)
    }

    public func services() async throws -> [RouterService] {
        let value = try await client.call(session: session, object: "service", method: "list")
        return try SnapshotParser.services(value)
    }

    public func inventory() async -> RouterInventory {
        async let menu = capture { try InventoryParser.menus(await client.menu(session: session)) }
        async let packages = capture { try await client.installedPackages(session: session) }
        async let configs = capture { try InventoryParser.configNames(await client.call(session: session, object: "file", method: "list", parameters: ["path": .string("/etc/config")])) }
        async let startup = capture { try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList")) }
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

    public func serviceAction(name: String, action: ServiceAction) async throws {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let initList = try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList"))
        guard initList.contains(where: { $0.name == name }) else { throw OpenWrtKitError.unsupported("此服务不在路由器的启动项目录中。") }
        let access = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("luci"), "function": .string("setInitAction")
        ])
        guard access["access"].boolValue == true else { throw OpenWrtKitError.permissionDenied }
        let value = try await client.call(session: session, object: "luci", method: "setInitAction", parameters: [
            "name": .string(name), "action": .string(action.rawValue)
        ])
        guard value["result"].boolValue == true else { throw OpenWrtKitError.unsupported("路由器未确认服务操作成功，请检查日志和当前状态。") }
    }

    public func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        switch kind {
        case .logs:
            let value = try await client.call(session: session, object: "log", method: "read", parameters: [
                "lines": .number(200), "oneshot": .bool(true), "stream": .bool(false)
            ])
            guard let records = value["log"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
        case .processes, .mounts:
            let method = kind == .processes ? "getProcessList" : "getMountPoints"
            let value = try await client.call(session: session, object: "luci", method: method)
            guard let records = value["result"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
        }
    }

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    public func logout() async {
        _ = try? await client.call(session: session, object: "session", method: "destroy")
    }

    private func read(_ object: String, _ method: String) async -> Result<JSONValue, Error> {
        do {
            let value = try await client.call(session: session, object: object, method: method)
            guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            return .success(value)
        }
        catch { return .failure(error) }
    }

    private func ipOutput(_ arguments: [String]) async throws -> String {
        let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string("/sbin/ip"), "params": .array(arguments.map(JSONValue.string))
        ])
        guard value["code"].intValue == 0, let output = value["stdout"].stringValue else {
            if let error = value["stderr"].stringValue, !error.isEmpty {
                throw OpenWrtKitError.unsupported("读取路由器路由/邻居表失败：\(error)")
            }
            throw OpenWrtKitError.malformedResponse
        }
        return output
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

    public static func routes(_ text: String) throws -> [IPRouteRecord] {
        try text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { raw in
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            let types: Set<String> = ["unicast", "local", "broadcast", "multicast", "throw", "unreachable", "prohibit", "blackhole", "nat", "anycast"]
            let destinationIndex = fields.first.map { types.contains($0) } == true ? 1 : 0
            guard fields.indices.contains(destinationIndex) else { throw OpenWrtKitError.malformedResponse }
            let destination = fields[destinationIndex]
            guard destination == "default" || validIPPrefix(destination),
                  ["via", "dev", "proto", "metric"].allSatisfy({ key in
                      fields.firstIndex(of: key).map { fields.indices.contains($0 + 1) } ?? true
                  }) else { throw OpenWrtKitError.malformedResponse }
            func value(after key: String) -> String? {
                guard let index = fields.firstIndex(of: key), fields.indices.contains(index + 1) else { return nil }
                return fields[index + 1]
            }
            if let gateway = value(after: "via"), !validIPAddress(gateway) { throw OpenWrtKitError.malformedResponse }
            if let metric = value(after: "metric"), UInt32(metric) == nil { throw OpenWrtKitError.malformedResponse }
            return IPRouteRecord(destination: destination, gateway: value(after: "via"), device: value(after: "dev"),
                                 protocolName: value(after: "proto"), metric: value(after: "metric"), rawValue: raw)
        }
    }

    public static func neighbors(_ text: String, interfaces: [NetworkInterfaceSnapshot]) throws -> [IPNeighborRecord] {
        let states: Set<String> = ["INCOMPLETE", "REACHABLE", "STALE", "DELAY", "PROBE", "FAILED", "NOARP", "PERMANENT"]
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let address = fields.first, validIPAddress(address),
                  let deviceIndex = fields.firstIndex(of: "dev"), fields.indices.contains(deviceIndex + 1),
                  let state = fields.first(where: { states.contains($0.uppercased()) }) else {
                throw OpenWrtKitError.malformedResponse
            }
            let device = fields[deviceIndex + 1]
            let mac: String?
            if let macIndex = fields.firstIndex(of: "lladdr") {
                guard fields.indices.contains(macIndex + 1) else { throw OpenWrtKitError.malformedResponse }
                let octets = fields[macIndex + 1].split(separator: ":", omittingEmptySubsequences: false)
                guard octets.count == 6, octets.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { throw OpenWrtKitError.malformedResponse }
                mac = fields[macIndex + 1]
            } else {
                mac = nil
            }
            let interface = interfaces.first(where: { $0.device == device })?.name ?? device
            return IPNeighborRecord(address: address, mac: mac, device: device, interface: interface, state: state.uppercased())
        }
    }

    private static func validIPAddress(_ text: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    private static func validIPPrefix(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), validIPAddress(String(parts[0])) else { return false }
        guard parts.count == 2 else { return true }
        guard let bits = Int(parts[1]) else { return false }
        return (0...(parts[0].contains(":") ? 128 : 32)).contains(bits)
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
