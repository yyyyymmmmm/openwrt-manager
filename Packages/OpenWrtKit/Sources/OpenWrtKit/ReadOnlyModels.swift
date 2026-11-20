import Foundation

// MARK: - Read-only data models (spec L3)

public struct LogEntry: Identifiable, Equatable, Sendable {
    public var timestamp: Date?
    public var priority: Int?
    public var source: String?
    public var message: String
    public var id: String {
        "\(timestamp?.timeIntervalSince1970 ?? 0)|\(source ?? "")|\(message)"
    }
    public init(timestamp: Date? = nil, priority: Int? = nil, source: String? = nil, message: String) {
        self.timestamp = timestamp; self.priority = priority
        self.source = source; self.message = message
    }
}

public struct ProcessInfo: Identifiable, Equatable, Sendable {
    public var pid: Int
    public var parentPID: Int?
    public var user: String?
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var command: String
    public var id: Int { pid }
    public init(pid: Int, parentPID: Int? = nil, user: String? = nil,
                cpuPercent: Double? = nil, memoryPercent: Double? = nil, command: String) {
        self.pid = pid; self.parentPID = parentPID; self.user = user
        self.cpuPercent = cpuPercent; self.memoryPercent = memoryPercent; self.command = command
    }
}

public struct NeighborEntry: Identifiable, Equatable, Sendable {
    public var address: String
    public var device: String?
    public var mac: String?
    public var state: String?
    public var isRouter: Bool
    public var id: String { "\(address)|\(device ?? "")" }
    public init(address: String, device: String? = nil, mac: String? = nil,
                state: String? = nil, isRouter: Bool = false) {
        self.address = address; self.device = device; self.mac = mac
        self.state = state; self.isRouter = isRouter
    }
}

public struct DeviceTraffic: Identifiable, Equatable, Sendable {
    public var device: String
    public var rxBytes: Int64
    public var txBytes: Int64
    public var id: String { device }
    public init(device: String, rxBytes: Int64, txBytes: Int64) {
        self.device = device; self.rxBytes = rxBytes; self.txBytes = txBytes
    }
}

public struct ConnectionCount: Equatable, Sendable {
    public var count: Int
    public var maximum: Int?
    public init(count: Int, maximum: Int? = nil) {
        self.count = count; self.maximum = maximum
    }
}

public struct NftChain: Identifiable, Equatable, Sendable {
    public var name: String
    public var countedRules: Int
    public var packets: Int64
    public var bytes: Int64
    public var id: String { name }
    public init(name: String, countedRules: Int = 0, packets: Int64 = 0, bytes: Int64 = 0) {
        self.name = name; self.countedRules = countedRules; self.packets = packets; self.bytes = bytes
    }
}

public struct NftTable: Identifiable, Equatable, Sendable {
    public var family: String
    public var name: String
    public var chains: [NftChain]
    public var id: String { "\(family)|\(name)" }
    public init(family: String, name: String, chains: [NftChain] = []) {
        self.family = family; self.name = name; self.chains = chains
    }
}

// MARK: - Parsers

/// Pure parsers for the read-only data plane. Each accepts the raw ubus
/// payload (or command output text) exactly as the router returns it.
public enum ReadOnlyParser {

    /// ubus log read: {"log": [{"time": <ms>, "msg": ..., "priority": n,
    /// "source": ...}]}. Newest first, as logread returns them.
    public static func systemLog(_ value: JSONValue) -> [LogEntry] {
        (value["log"].arrayValue ?? []).map { item in
            LogEntry(
                timestamp: item["time"].doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                priority: item["priority"].intValue,
                source: item["source"].stringValue,
                message: item["msg"].stringValue ?? "")
        }
    }

    /// dmesg plain text: one entry per line, timestamps left unset (the
    /// bracketed boot-relative offsets are not wall-clock times).
    public static func kernelLog(_ text: String) -> [LogEntry] {
        text.split(whereSeparator: \.isNewline).map { LogEntry(message: String($0)) }
    }

    /// luci getProcessList: {"result": [{PID, PPID, USER, %CPU, %MEM,
    /// COMMAND}]} — field values arrive as strings on stock builds.
    public static func processes(_ value: JSONValue) -> [ProcessInfo] {
        (value["result"].arrayValue ?? []).compactMap { item in
            func field(_ keys: [String]) -> String? {
                for key in keys { if let text = item[key].textValue { return text } }
                return nil
            }
            guard let pidText = field(["PID", "pid"]), let pid = Int(pidText) else { return nil }
            return ProcessInfo(
                pid: pid,
                parentPID: field(["PPID", "ppid"]).flatMap(Int.init),
                user: field(["USER", "user"]),
                cpuPercent: field(["%CPU", "cpu"]).flatMap(Double.init),
                memoryPercent: field(["%MEM", "mem"]).flatMap(Double.init),
                command: field(["COMMAND", "command", "comm"]) ?? "")
        }
    }

    /// `ip neigh show` text lines.
    public static func neighbors(_ text: String) -> [NeighborEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(separator: " ").map(String.init)
            guard let address = tokens.first else { return nil }
            func after(_ key: String) -> String? {
                guard let index = tokens.firstIndex(of: key), index + 1 < tokens.count else { return nil }
                return tokens[index + 1]
            }
            let state = tokens.last.flatMap { token in
                ["REACHABLE", "STALE", "DELAY", "PROBE", "FAILED", "INCOMPLETE", "PERMANENT", "NOARP"].contains(token) ? token : nil
            }
            return NeighborEntry(address: address,
                                 device: after("dev"),
                                 mac: after("lladdr"),
                                 state: state,
                                 isRouter: tokens.contains("router"))
        }
    }

    /// network.device status: {device: {"statistics": {"rx_bytes": n,
    /// "tx_bytes": n}}}.
    public static func deviceTraffic(_ value: JSONValue) -> [DeviceTraffic] {
        (value.objectValue ?? [:]).compactMap { name, device in
            let stats = device["statistics"]
            guard let rx = stats["rx_bytes"].intValue, let tx = stats["tx_bytes"].intValue else { return nil }
            return DeviceTraffic(device: name, rxBytes: Int64(rx), txBytes: Int64(tx))
        }.sorted { $0.device < $1.device }
    }

    /// /proc/sys/net/netfilter/nf_conntrack_count content.
    public static func connectionCount(_ text: String, maximumText: String? = nil) -> ConnectionCount? {
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ConnectionCount(count: count,
                               maximum: maximumText.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    /// `nft list ruleset` text. Extracts tables and chains with the packet
    /// and byte totals of their counter statements — enough for a status
    /// page; rule text itself stays on the router.
    public static func nftables(_ text: String) -> [NftTable] {
        var tables: [NftTable] = []
        var currentChain: Int?
        var depth = 0
        var tableDepth = 0
        var chainDepth = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            if line.hasPrefix("table ") {
                let parts = line.split(separator: " ").map(String.init)
                if parts.count >= 3 {
                    tables.append(NftTable(family: parts[1], name: parts[2]))
                    tableDepth = depth + 1
                }
            } else if line.hasPrefix("chain "), !tables.isEmpty {
                let name = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                tables[tables.count - 1].chains.append(NftChain(name: name))
                currentChain = tables[tables.count - 1].chains.count - 1
                chainDepth = depth + 1
            } else if let chainIndex = currentChain, !tables.isEmpty, depth >= chainDepth,
                      line.contains("counter packets ") {
                let packets = counterValue(in: line, after: "counter packets ")
                let bytes = counterValue(in: line, after: " bytes ")
                var chain = tables[tables.count - 1].chains[chainIndex]
                chain.countedRules += 1
                chain.packets += packets ?? 0
                chain.bytes += bytes ?? 0
                tables[tables.count - 1].chains[chainIndex] = chain
            }
            depth += opens - closes
            if currentChain != nil, depth < chainDepth { currentChain = nil }
            if depth < tableDepth, !tables.isEmpty { currentChain = nil }
        }
        return tables
    }

    private static func counterValue(in line: String, after marker: String) -> Int64? {
        guard let range = line.range(of: marker) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int64(digits)
    }
}
