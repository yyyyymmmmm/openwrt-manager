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
    /// The rules themselves (package I, audit U6): the status page
    /// used to stop at per-chain counts, leaving "is this forwarding
    /// rule actually there?" unanswerable. Rule bodies are device
    /// data (class ④) — presented as parsed, never translated.
    public var rules: [NftRule]
    public var id: String { name }
    public init(name: String, countedRules: Int = 0, packets: Int64 = 0, bytes: Int64 = 0,
                rules: [NftRule] = []) {
        self.name = name; self.countedRules = countedRules; self.packets = packets; self.bytes = bytes
        self.rules = rules
    }
}

/// What a rule ultimately does with a packet. The label is the
/// human word the status page shows; the raw verdict stays in the
/// rule's raw text for the detail layer.
public enum NftRuleAction: Equatable, Sendable {
    case accept
    case drop
    case reject
    case returnFromChain
    case jump(String)
    case masquerade
    case dnat
    case snat
    case redirect
    case other(String)
    case none

    public var label: String {
        switch self {
        case .accept: return KitL10n.text("放行")
        case .drop: return KitL10n.text("拦截")
        case .reject: return KitL10n.text("拒绝")
        case .returnFromChain: return KitL10n.text("返回")
        case .jump(let target): return KitL10n.format("跳转到「%@」", target)
        case .masquerade: return KitL10n.text("地址伪装")
        case .dnat: return KitL10n.text("端口转发")
        case .snat: return KitL10n.text("源地址转换")
        case .redirect: return KitL10n.text("重定向")
        case .other(let raw): return raw
        case .none: return KitL10n.text("无动作")
        }
    }

    /// Whether the rule lets traffic through — drives the status
    /// page's colour choice, nothing more.
    public var isPassing: Bool {
        switch self {
        case .accept, .masquerade, .dnat, .snat, .redirect, .jump: return true
        case .drop, .reject: return false
        case .returnFromChain, .other, .none: return false
        }
    }
}

/// One nftables rule, parsed into the parts a person reads: who
/// talks to whom, on what, and what happens — plus the raw form for
/// the detail layer.
public struct NftRule: Identifiable, Equatable, Sendable {
    public var id: String
    /// The rule's own comment (fw4 rules carry names like
    /// "Allow-DHCP-Renew"); device data, shown verbatim.
    public var comment: String?
    public var source: String?
    public var destination: String?
    /// Protocol token as the kernel names it ("tcp", "udp", "icmp"…),
    /// uppercased for display; a protocol *number* when unnamed.
    public var protocolName: String?
    public var sourcePort: String?
    public var destinationPort: String?
    public var inputInterface: String?
    public var outputInterface: String?
    public var action: NftRuleAction
    public var packets: Int64
    public var bytes: Int64
    /// One human sentence: flow, protocol/port, verdict.
    public var summary: String
    /// The rule as the router reported it — JSON for the JSON form,
    /// the line itself for the text form.
    public var rawText: String

    public init(id: String, comment: String? = nil, source: String? = nil,
                destination: String? = nil, protocolName: String? = nil,
                sourcePort: String? = nil, destinationPort: String? = nil,
                inputInterface: String? = nil, outputInterface: String? = nil,
                action: NftRuleAction = .none, packets: Int64 = 0, bytes: Int64 = 0,
                summary: String, rawText: String) {
        self.id = id; self.comment = comment; self.source = source
        self.destination = destination; self.protocolName = protocolName
        self.sourcePort = sourcePort; self.destinationPort = destinationPort
        self.inputInterface = inputInterface; self.outputInterface = outputInterface
        self.action = action; self.packets = packets; self.bytes = bytes
        self.summary = summary; self.rawText = rawText
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

    /// dmesg text: one entry per line, timestamps left unset (the
    /// bracketed boot-relative offsets are not wall-clock times). The
    /// granted "-r" form prefixes each line with <priority>; the prefix
    /// is stripped into the entry's priority field. Lines without the
    /// prefix (plain dmesg) pass through unchanged.
    public static func kernelLog(_ text: String) -> [LogEntry] {
        text.split(whereSeparator: \.isNewline).map { raw in
            var line = String(raw)
            var priority: Int?
            if line.hasPrefix("<"), let close = line.firstIndex(of: ">"),
               let value = Int(line[line.index(after: line.startIndex)..<close]) {
                priority = value
                line = String(line[line.index(after: close)...])
            }
            return LogEntry(priority: priority, message: line)
        }
    }

    /// logread plain text (the syslog-wrapper fallback): lines of the
    /// form "Fri Nov 20 23:07:00 2026 daemon.info dnsmasq[1]: message",
    /// oldest first. Returned newest-first to match the ubus log read
    /// ordering. Unparseable lines are kept as plain messages rather
    /// than dropped.
    public static func systemLogText(_ text: String) -> [LogEntry] {
        let priorities = ["emerg": 0, "alert": 1, "crit": 2, "err": 3,
                          "warning": 4, "notice": 5, "info": 6, "debug": 7]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return text.split(whereSeparator: \.isNewline).reversed().map { raw in
            let line = String(raw)
            // Tokens 0-4 are the date; token 5 is the remainder of the
            // line: "facility.priority source[pid]: message".
            let tokens = line.split(separator: " ", maxSplits: 5).map(String.init)
            guard tokens.count == 6 else { return LogEntry(message: line) }
            let timestamp = formatter.date(from: tokens[0..<5].joined(separator: " "))
            let bodyParts = tokens[5].split(separator: " ", maxSplits: 1).map(String.init)
            guard bodyParts.count == 2 else {
                return LogEntry(timestamp: timestamp, message: line)
            }
            let facPri = bodyParts[0].split(separator: ".", maxSplits: 1).map(String.init)
            let priority = facPri.count == 2 ? priorities[facPri[1]] : nil
            var message = bodyParts[1]
            var source: String?
            if let colon = message.range(of: ": ") {
                let candidate = String(message[message.startIndex..<colon.lowerBound])
                if !candidate.contains(" "), candidate.count <= 64 {
                    source = candidate.replacingOccurrences(of: #"\[\d+\]$"#,
                                                            with: "", options: .regularExpression)
                    message = String(message[colon.upperBound...])
                }
            }
            return LogEntry(timestamp: timestamp, priority: priority, source: source, message: message)
        }
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

    /// luci-rpc getNetworkDevices: {device: {"stats": {"rx_bytes": n,
    /// "tx_bytes": n}}} — the same counters under a shorter key, from
    /// the call LuCI's realtime graphs poll.
    public static func networkDeviceTraffic(_ value: JSONValue) -> [DeviceTraffic] {
        (value.objectValue ?? [:]).compactMap { name, device in
            let stats = device["stats"]
            guard let rx = stats["rx_bytes"].intValue, let tx = stats["tx_bytes"].intValue else { return nil }
            return DeviceTraffic(device: name, rxBytes: Int64(rx), txBytes: Int64(tx))
        }.sorted { $0.device < $1.device }
    }

    /// `nft --terse --json list ruleset` output — the form LuCI's
    /// firewall status page reads and the only nft command line rpcd
    /// grants. Produces the same table/chain model as the text parser:
    /// per chain, the count of rules carrying a counter statement and
    /// their packet/byte totals.
    public static func nftablesJSON(_ text: String) throws -> [NftTable] {
        guard let data = text.data(using: .utf8) else { throw OpenWrtKitError.malformedResponse }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let items = value["nftables"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        var tables: [NftTable] = []
        func tableIndex(family: String, name: String) -> Int? {
            tables.firstIndex { $0.family == family && $0.name == name }
        }
        for item in items {
            let table = item["table"]
            let chain = item["chain"]
            let rule = item["rule"]
            if table.objectValue != nil,
               let family = table["family"].stringValue, let name = table["name"].stringValue,
               tableIndex(family: family, name: name) == nil {
                tables.append(NftTable(family: family, name: name))
            } else if chain.objectValue != nil,
                      let family = chain["family"].stringValue,
                      let tableName = chain["table"].stringValue,
                      let name = chain["name"].stringValue {
                guard let index = tableIndex(family: family, name: tableName) else { continue }
                if !tables[index].chains.contains(where: { $0.name == name }) {
                    tables[index].chains.append(NftChain(name: name))
                }
            } else if rule.objectValue != nil,
                      let family = rule["family"].stringValue,
                      let tableName = rule["table"].stringValue,
                      let chainName = rule["chain"].stringValue {
                guard let index = tableIndex(family: family, name: tableName),
                      let chainIndex = tables[index].chains.firstIndex(where: { $0.name == chainName })
                else { continue }
                let parsed = nftRule(from: rule,
                                     id: "\(chainName)|\(tables[index].chains[chainIndex].rules.count)")
                tables[index].chains[chainIndex].rules.append(parsed.rule)
                tables[index].chains[chainIndex].countedRules += parsed.counterExpressions
                tables[index].chains[chainIndex].packets += parsed.rule.packets
                tables[index].chains[chainIndex].bytes += parsed.rule.bytes
            }
        }
        return tables
    }

    /// One rule object of the JSON ruleset → the human model. The
    /// expression list is a small language of its own: matches carry
    /// the flow (addresses, ports, interfaces, protocol), statements
    /// carry the verdict. Anything unrecognized is not dropped — it
    /// stays in the raw text and, when it is the only statement,
    /// surfaces as an "other" action with its raw name.
    private static func nftRule(from rule: JSONValue, id: String)
        -> (rule: NftRule, counterExpressions: Int) {
        var source: String?
        var destination: String?
        var protocolName: String?
        var sourcePort: String?
        var destinationPort: String?
        var inputInterface: String?
        var outputInterface: String?
        var action: NftRuleAction = .none
        var packets: Int64 = 0
        var bytes: Int64 = 0
        var counterExpressions = 0

        for expression in rule["expr"].arrayValue ?? [] {
            guard let object = expression.objectValue else { continue }
            for (key, value) in object {
                switch key {
                case "counter":
                    counterExpressions += 1
                    packets += Int64(value["packets"].intValue ?? 0)
                    bytes += Int64(value["bytes"].intValue ?? 0)
                case "match":
                    applyMatch(value, source: &source, destination: &destination,
                               protocolName: &protocolName, sourcePort: &sourcePort,
                               destinationPort: &destinationPort,
                               inputInterface: &inputInterface, outputInterface: &outputInterface)
                case "accept": action = .accept
                case "drop": action = .drop
                case "reject": action = .reject
                case "return": action = .returnFromChain
                case "jump", "goto":
                    action = .jump(value["target"].stringValue ?? "")
                case "masquerade": action = .masquerade
                case "dnat": action = .dnat
                case "snat": action = .snat
                case "redirect": action = .redirect
                case "log", "ct", "limit", "quota", "queue", "vmap", "map", "set", "dynset":
                    // Bookkeeping statements: they shape the rule but
                    // are not its verdict; the raw text keeps them.
                    break
                default:
                    if action == .none { action = .other(key) }
                }
            }
        }

        let rawText = (try? JSONEncoder().encode(rule)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let parsed = NftRule(
            id: id, comment: rule["comment"].stringValue,
            source: source, destination: destination, protocolName: protocolName,
            sourcePort: sourcePort, destinationPort: destinationPort,
            inputInterface: inputInterface, outputInterface: outputInterface,
            action: action, packets: packets, bytes: bytes,
            summary: nftRuleSummary(source: source, destination: destination,
                                    protocolName: protocolName, destinationPort: destinationPort,
                                    action: action),
            rawText: rawText)
        return (parsed, counterExpressions)
    }

    private static func applyMatch(_ match: JSONValue,
                                   source: inout String?, destination: inout String?,
                                   protocolName: inout String?, sourcePort: inout String?,
                                   destinationPort: inout String?,
                                   inputInterface: inout String?, outputInterface: inout String?) {
        let left = match["left"]
        let rendered = nftValueText(match["right"])
        guard let rendered else { return }
        if let meta = left["meta"].objectValue, let key = meta["key"]?.stringValue {
            switch key {
            case "iifname": inputInterface = rendered
            case "oifname": outputInterface = rendered
            case "l4proto": protocolName = protocolName ?? nftProtocolName(rendered)
            default: break
            }
            return
        }
        if let payload = left["payload"].objectValue,
           let field = payload["field"]?.stringValue {
            let proto = payload["protocol"]?.stringValue
            switch field {
            case "saddr": source = rendered
            case "daddr": destination = rendered
            case "sport":
                sourcePort = rendered
                if let proto { protocolName = protocolName ?? nftProtocolName(proto) }
            case "dport":
                destinationPort = rendered
                if let proto { protocolName = protocolName ?? nftProtocolName(proto) }
            case "protocol":
                protocolName = protocolName ?? nftProtocolName(rendered)
            default: break
            }
        }
    }

    /// A match's right-hand side as display text: a plain value, a
    /// CIDR prefix, a set joined by commas, or a range with a dash.
    private static func nftValueText(_ value: JSONValue) -> String? {
        if let string = value.stringValue { return string }
        if let number = value.intValue { return String(number) }
        if let prefix = value["prefix"].objectValue,
           let address = prefix["addr"]?.stringValue, let length = prefix["len"]?.intValue {
            return "\(address)/\(length)"
        }
        if let set = value["set"].arrayValue {
            let parts = set.compactMap { nftValueText($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let range = value["range"].arrayValue, range.count == 2,
           let low = nftValueText(range[0]), let high = nftValueText(range[1]) {
            return "\(low)-\(high)"
        }
        if let concat = value["concat"].arrayValue {
            let parts = concat.compactMap { nftValueText($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }

    /// Protocol tokens and numbers → the display token. Names are
    /// protocol vocabulary (device data class), uppercased as the
    /// kernel prints them; unknown numbers stay numbers.
    private static func nftProtocolName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "6", "tcp": return "TCP"
        case "17", "udp": return "UDP"
        case "1", "icmp": return "ICMP"
        case "58", "ipv6-icmp", "icmpv6": return "ICMPv6"
        case "47", "gre": return "GRE"
        case "50", "esp": return "ESP"
        case "51", "ah": return "AH"
        default: return raw.uppercased()
        }
    }

    /// The one-sentence reading of a rule: flow first, then the
    /// protocol/port it applies to, then what happens.
    private static func nftRuleSummary(source: String?, destination: String?,
                                       protocolName: String?, destinationPort: String?,
                                       action: NftRuleAction) -> String {
        let flow: String
        switch (source, destination) {
        case let (source?, destination?):
            flow = KitL10n.format("%@ → %@", source, destination)
        case let (nil, destination?):
            flow = KitL10n.format("发往 %@", destination)
        case let (source?, nil):
            flow = KitL10n.format("来自 %@", source)
        case (nil, nil):
            flow = KitL10n.text("任意地址")
        }
        var parts = [flow]
        if let protocolName { parts.append(protocolName) }
        if let destinationPort { parts.append(KitL10n.format("端口 %@", destinationPort)) }
        parts.append(action.label)
        return parts.joined(separator: " · ")
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
                chain.rules.append(NftRule(
                    id: "\(chain.name)|\(chain.rules.count)",
                    action: nftTextAction(line),
                    packets: packets ?? 0, bytes: bytes ?? 0,
                    summary: line, rawText: line))
                tables[tables.count - 1].chains[chainIndex] = chain
            } else if let chainIndex = currentChain, !tables.isEmpty, depth >= chainDepth,
                      !line.isEmpty, line != "}", !line.hasPrefix("type ") {
                // A rule without a counter: the JSON form is the
                // primary path, but the text fallback keeps rule
                // bodies too — the line is already the readable form.
                var chain = tables[tables.count - 1].chains[chainIndex]
                chain.rules.append(NftRule(
                    id: "\(chain.name)|\(chain.rules.count)",
                    action: nftTextAction(line),
                    summary: line, rawText: line))
                tables[tables.count - 1].chains[chainIndex] = chain
            }
            depth += opens - closes
            if currentChain != nil, depth < chainDepth { currentChain = nil }
            if depth < tableDepth, !tables.isEmpty { currentChain = nil }
        }
        return tables
    }

    /// The verdict of a text-form rule line, by its trailing
    /// statement keyword. Text rules keep the line as their summary;
    /// this only drives the status colour and the detail label.
    private static func nftTextAction(_ line: String) -> NftRuleAction {
        let padded = " \(line) "
        if padded.contains(" accept") { return .accept }
        if padded.contains(" drop") { return .drop }
        if padded.contains(" reject") { return .reject }
        if padded.contains(" masquerade") { return .masquerade }
        if padded.contains(" dnat ") || padded.contains(" dnat to") { return .dnat }
        if padded.contains(" snat ") || padded.contains(" snat to") { return .snat }
        if padded.contains(" redirect") { return .redirect }
        if let range = padded.range(of: " jump ") {
            let target = padded[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            return .jump(target)
        }
        if let range = padded.range(of: " goto ") {
            let target = padded[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            return .jump(target)
        }
        if padded.contains(" return") { return .returnFromChain }
        return .none
    }

    private static func counterValue(in line: String, after marker: String) -> Int64? {
        guard let range = line.range(of: marker) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int64(digits)
    }
}
