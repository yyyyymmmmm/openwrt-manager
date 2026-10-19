import Foundation

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
        case .success(let value): snapshot.interfaces = SnapshotParser.interfaces(value)
        case .failure(let error): snapshot.warnings.append("网络接口：\(error.localizedDescription)")
        }
        snapshot.refreshedAt = Date()
        return snapshot
    }

    public func leases() async throws -> [DHCPLease] {
        let value = try await client.call(session: session, object: "luci-rpc", method: "getDHCPLeases")
        guard value["dhcp_leases"].arrayValue != nil || value["dhcp6_leases"].arrayValue != nil else {
            throw OpenWrtKitError.malformedResponse
        }
        return SnapshotParser.leases(value)
    }

    public func wireless() async throws -> [WirelessRadio] {
        let value = try await client.call(session: session, object: "network.wireless", method: "status")
        guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
        return SnapshotParser.wireless(value)
    }

    public func services() async throws -> [RouterService] {
        let value = try await client.call(session: session, object: "service", method: "list")
        guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
        return SnapshotParser.services(value)
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

    public static func interfaces(_ value: JSONValue) -> [NetworkInterfaceSnapshot] {
        (value["interface"].arrayValue ?? []).compactMap { item in
            guard let name = item["interface"].stringValue else { return nil }
            let addresses = ["ipv4-address", "ipv6-address"].flatMap { key in
                (item[key].arrayValue ?? []).compactMap { address -> String? in
                    guard let ip = address["address"].stringValue else { return nil }
                    return ip + (address["mask"].intValue.map { "/\($0)" } ?? "")
                }
            }
            return NetworkInterfaceSnapshot(name: name, protocolName: item["proto"].stringValue ?? "—", addresses: addresses,
                                            up: item["up"].boolValue ?? false, device: item["l3_device"].stringValue)
        }.sorted { $0.name < $1.name }
    }

    public static func leases(_ value: JSONValue) -> [DHCPLease] {
        var seen = Set<String>()
        return ["dhcp_leases", "dhcp6_leases"].flatMap { value[$0].arrayValue ?? [] }.compactMap { item in
            let address = item["ipaddr"].stringValue
                ?? item["ip6addr"].stringValue
                ?? item["ip6addrs"].arrayValue?.first?.stringValue
            guard let address else { return nil }
            let lease = DHCPLease(hostname: item["hostname"].stringValue ?? "未命名设备", address: address,
                                  mac: item["macaddr"].stringValue ?? item["duid"].stringValue ?? "—",
                                  expires: item["expires"].intValue)
            return seen.insert(lease.id).inserted ? lease : nil
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }

    public static func wireless(_ value: JSONValue) -> [WirelessRadio] {
        (value.objectValue ?? [:]).map { name, radio in
            WirelessRadio(name: name, up: radio["up"].boolValue ?? false, channel: radio["config"]["channel"].textValue ?? "自动",
                          networks: (radio["interfaces"].arrayValue ?? []).compactMap { $0["config"]["ssid"].stringValue })
        }.sorted { $0.name < $1.name }
    }

    public static func services(_ value: JSONValue) -> [RouterService] {
        (value.objectValue ?? [:]).map { name, service in
            let instances = Array((service["instances"].objectValue ?? [:]).values)
            return RouterService(name: name, runningInstances: instances.filter { $0["running"].boolValue == true }.count,
                                 totalInstances: instances.count)
        }.sorted { $0.name < $1.name }
    }
}
