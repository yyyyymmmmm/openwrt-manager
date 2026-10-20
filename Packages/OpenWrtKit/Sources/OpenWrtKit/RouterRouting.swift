import Foundation
import Darwin

/// A failed table is not an empty table. Each family/table retains its own
/// successful timestamp; another table's refresh must never relabel stale data.
public struct RoutingRead<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    public let updatedAt: Date?
    public let error: String?
    public let command: String?
    public init(value: Value? = nil, updatedAt: Date? = nil, error: String? = nil, command: String? = nil) {
        self.value = value; self.updatedAt = updatedAt; self.error = error; self.command = command
    }
    func retaining(_ old: Self) -> Self {
        guard value == nil else { return self }
        return .init(value: old.value, updatedAt: old.updatedAt, error: error, command: command ?? old.command)
    }
}

public struct IPRuleRecord: Identifiable, Equatable, Sendable {
    public let priority: String
    public let fields: [String: JSONValue]
    public let rawValue: String
    public var id: String { rawValue }
}

struct RouterRoutingClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read(interfaces: [NetworkInterfaceSnapshot]) async throws -> RouterRoutingSnapshot {
        async let r4 = readTable("-4", "route") { try RoutingParser.routes($0, json: $1) }
        async let r6 = readTable("-6", "route") { try RoutingParser.routes($0, json: $1) }
        async let n4 = readTable("-4", "neigh") { try RoutingParser.neighbors($0, json: $1, interfaces: interfaces) }
        async let n6 = readTable("-6", "neigh") { try RoutingParser.neighbors($0, json: $1, interfaces: interfaces) }
        async let p4 = readTable("-4", "rule") { try RoutingParser.rules($0, json: $1) }
        async let p6 = readTable("-6", "rule") { try RoutingParser.rules($0, json: $1) }
        let (routes4, routes6, neighbors4, neighbors6, rules4, rules6) = await (r4, r6, n4, n6, p4, p6)
        try Task.checkCancellation()
        return RouterRoutingSnapshot(routes4: routes4, routes6: routes6, neighbors4: neighbors4,
                                     neighbors6: neighbors6, rules4: rules4, rules6: rules6)
    }

    private func readTable<T: Equatable & Sendable>(_ family: String, _ table: String,
        parse: @Sendable (String, Bool) throws -> T) async -> RoutingRead<T> {
        let tail = [table, "show"] + (table == "route" ? ["table", "all"] : [])
        var attempts: [String] = []
        for json in [true, false] {
            let arguments = [family] + (json ? ["-j"] : []) + tail
            let command = "/sbin/ip " + arguments.joined(separator: " ")
            do {
                try Task.checkCancellation()
                let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                    "command": .string("/sbin/ip"), "params": .array(arguments.map(JSONValue.string))
                ])
                let result = try RouterCommandResult(value: value)
                if result.exitCode != 0 {
                    attempts.append("\(command)：退出码 \(result.exitCode)；\(result.stderr)")
                    if json { continue } // BusyBox and older iproute2 may lack -j.
                    return .init(error: attempts.joined(separator: "\n"), command: command)
                }
                // A successful command with invalid output is an error, never []
                // and never hidden by trying a different format.
                let parsed = try parse(result.stdout, json)
                return .init(value: parsed, updatedAt: Date(), command: command)
            } catch {
                attempts.append("\(command)：\(error.localizedDescription)")
                // ACLs can grant the JSON or text command separately. Both are
                // fixed read-only queries; never request broader permissions.
                if json, (error as? OpenWrtKitError) == .permissionDenied { continue }
                return .init(error: attempts.joined(separator: "\n"), command: command)
            }
        }
        return .init(error: attempts.joined(separator: "\n"))
    }
}

public enum RoutingParser {
    public static func routes(_ text: String, json: Bool) throws -> [IPRouteRecord] {
        guard json else { return try SnapshotParser.routes(text) }
        return try records(text).map { record in
            guard let destination = record["dst"].stringValue, destination == "default" || prefix(destination) else {
                throw OpenWrtKitError.malformedResponse
            }
            if let gateway = record["gateway"].stringValue, !address(gateway) { throw OpenWrtKitError.malformedResponse }
            return IPRouteRecord(destination: destination, gateway: try scalar(record, "gateway"),
                device: try scalar(record, "dev"), protocolName: try scalar(record, "protocol"),
                metric: try scalar(record, "metric"), rawValue: try encoded(record),
                table: try scalar(record, "table"), source: try scalar(record, "prefsrc") ?? scalar(record, "src") ?? scalar(record, "from"),
                routeType: try scalar(record, "type"))
        }
    }

    public static func neighbors(_ text: String, json: Bool, interfaces: [NetworkInterfaceSnapshot]) throws -> [IPNeighborRecord] {
        guard json else { return try SnapshotParser.neighbors(text, interfaces: interfaces) }
        return try records(text).map { record in
            guard let ip = record["dst"].stringValue, address(ip),
                  let device = record["dev"].stringValue, !device.isEmpty else { throw OpenWrtKitError.malformedResponse }
            let mac = try scalar(record, "lladdr")
            if let mac {
                let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { throw OpenWrtKitError.malformedResponse }
            }
            let states: [String]
            if let list = record["state"].arrayValue {
                guard list.allSatisfy({ $0.stringValue != nil }) else { throw OpenWrtKitError.malformedResponse }
                states = list.compactMap(\.stringValue)
            } else if let state = record["state"].stringValue { states = [state] }
            else if record["state"] == .null { states = [] }
            else { throw OpenWrtKitError.malformedResponse }
            let matching = interfaces.filter { $0.device == device }.map(\.name).sorted()
            return .init(address: ip, mac: mac, device: device, interface: matching.isEmpty ? device : matching.joined(separator: " / "),
                         state: states.isEmpty ? "未报告" : states.joined(separator: " · "), rawValue: try encoded(record))
        }
    }

    public static func rules(_ text: String, json: Bool) throws -> [IPRuleRecord] {
        if json {
            return try records(text).map { record in
                guard let priority = record["priority"].intValue, priority >= 0, let fields = record.objectValue else { throw OpenWrtKitError.malformedResponse }
                return .init(priority: String(priority), fields: fields, rawValue: try encoded(record))
            }
        }
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let priority = UInt32(parts[0].trimmingCharacters(in: .whitespaces)),
                  !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { throw OpenWrtKitError.malformedResponse }
            return .init(priority: String(priority), fields: [:], rawValue: String(line))
        }
    }

    private static func records(_ text: String) throws -> [JSONValue] {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let records = value.arrayValue, records.allSatisfy({ $0.objectValue != nil }) else { throw OpenWrtKitError.malformedResponse }
        return records
    }
    private static func scalar(_ value: JSONValue, _ key: String) throws -> String? {
        if value[key] == .null { return nil }
        guard let text = value[key].textValue else { throw OpenWrtKitError.malformedResponse }
        return text
    }
    private static func encoded(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func address(_ text: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    private static func prefix(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), address(String(parts[0])) else { return false }
        return parts.count == 1 || Int(parts[1]).map { (0...(parts[0].contains(":") ? 128 : 32)).contains($0) } == true
    }
}
