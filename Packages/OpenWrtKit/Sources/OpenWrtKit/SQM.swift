import Foundation

public struct SQMRuntimeSnapshot: Sendable {
    public let configuration: RouterConfiguration?
    public let qdiscs: [String]?
    public let scripts: [String]?
    public let devices: [WakeOnLANDevice]?
    public let startup: InitService?
    public let issues: [String: String]
    public let readAt: Date
}

public struct SQMDiscipline: Identifiable, Sendable {
    public let kind: String
    public let handle: String
    public let device: String
    public let root: Bool?
    public let parent: String?
    /// Keep tc's units intact; backlog may be a string such as "12p 4096b".
    public let counters: [String: String]
    public let details: String
    public var id: String { [device, handle, parent ?? (root == true ? "root" : "unspecified"), kind].joined(separator: "/") }

    static func parse(_ value: JSONValue) throws -> [Self] {
        guard let rows = value.arrayValue else { throw OpenWrtKitError.malformedResponse }
        var identities = Set<String>()
        return try rows.map { row in
            guard row.objectValue != nil, let kind = row["kind"].stringValue, !kind.isEmpty,
                  let handle = row["handle"].stringValue, !handle.isEmpty,
                  let device = row["dev"].stringValue, WakeOnLANTarget.validInterface(device) else { throw OpenWrtKitError.malformedResponse }
            if row["root"] != .null && row["root"].boolValue == nil { throw OpenWrtKitError.malformedResponse }
            if row["parent"] != .null && row["parent"].stringValue == nil { throw OpenWrtKitError.malformedResponse }
            let identity = [device, handle, row["parent"].stringValue ?? (row["root"].boolValue == true ? "root" : "unspecified"), kind].joined(separator: "/")
            guard identities.insert(identity).inserted,
                  row["stats"] == .null || row["stats"].objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            var counters: [String: String] = [:]
            let stats = row["stats"].objectValue ?? [:]
            for key in ["bytes", "packets", "dropped", "drops", "overlimits", "requeues", "backlog", "qlen", "hw_bytes", "hw_packets", "sw_bytes", "sw_packets"] {
                let raw = stats[key] ?? row[key]
                guard raw != .null else { continue }
                if key == "backlog" {
                    if let text = raw.stringValue, !text.isEmpty { counters[key] = text }
                    else if let number = raw.intValue, number >= 0 { counters[key] = String(number) }
                    else { throw OpenWrtKitError.malformedResponse }
                } else {
                    guard let number = raw.intValue, number >= 0 else { throw OpenWrtKitError.malformedResponse }
                    counters[key] = String(number)
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let details = String(decoding: try encoder.encode(row), as: UTF8.self)
            return Self(kind: kind, handle: handle, device: device, root: row["root"].boolValue,
                        parent: row["parent"].stringValue, counters: counters, details: details)
        }
    }
}

public struct SQMKernelSnapshot: Sendable {
    /// nil means a legacy tc returned text, not an empty queue list.
    public let disciplines: [SQMDiscipline]?
    public let output: RouterCommandResult
    public let compatibilityNote: String?
    public let readAt: Date
}

public enum SQMReadRequest: Sendable {
    case scriptHelp(String)
    case startLog(String)
    case stopLog(String)
    public var title: String {
        switch self {
        case .scriptHelp(let script): return script + " · 说明"
        case .startLog(let interface): return interface + " · 启动日志"
        case .stopLog(let interface): return interface + " · 停止日志"
        }
    }
}

struct SQMClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read() async -> SQMRuntimeSnapshot {
        var config: RouterConfiguration?, qdiscs: [String]?, scripts: [String]?, devices: [WakeOnLANDevice]?, startup: InitService?
        var issues: [String: String] = [:]
        do { config = try RouterConfiguration.parse(name: "sqm", value: await call("uci", "get", ["config": .string("sqm")])) }
        catch { issues["队列配置"] = error.localizedDescription }
        do { qdiscs = try Self.names(await call("file", "list", ["path": .string("/var/run/sqm/available_qdiscs")])) }
        catch { issues["可用队列规则"] = error.localizedDescription }
        do { scripts = try Self.names(await call("file", "list", ["path": .string("/usr/lib/sqm")]), suffix: ".qos") }
        catch { issues["可用脚本"] = error.localizedDescription }
        do { devices = try WakeOnLANDevice.parse(await call("luci-rpc", "getNetworkDevices")) }
        catch { issues["网络设备"] = error.localizedDescription }
        do {
            let list = try InventoryParser.initServices(await call("luci", "getInitList"))
            startup = list.first { $0.name == "sqm" }
            if startup == nil { issues["启动项"] = "固件没有返回 sqm 启动项；不能推断服务状态。" }
        } catch { issues["启动项"] = error.localizedDescription }
        return SQMRuntimeSnapshot(configuration: config, qdiscs: qdiscs, scripts: scripts, devices: devices,
                                  startup: startup, issues: issues, readAt: Date())
    }

    func kernel() async throws -> SQMKernelSnapshot {
        // Inspect every device, including the actual IFB devices. Never invent an IFB name from UCI.
        let output = try await exec("/sbin/tc", ["-s", "-j", "qdisc", "show"])
        if output.exitCode == 0 {
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8)) }
            catch { throw OpenWrtKitError.malformedResponse }
            return try SQMKernelSnapshot(disciplines: SQMDiscipline.parse(value), output: output, compatibilityNote: nil, readAt: Date())
        }
        let message = (output.stderr + "\n" + output.stdout).lowercased()
        guard message.contains("-j"), ["unknown", "invalid", "unrecognized", "unrecognised"].contains(where: { message.contains($0) }) else {
            throw commandFailure(output)
        }
        // A read-only fallback is allowed only when tc explicitly rejects its JSON option.
        let legacy = try await exec("/sbin/tc", ["-s", "qdisc", "show"])
        guard legacy.exitCode == 0 else { throw commandFailure(legacy) }
        return SQMKernelSnapshot(disciplines: nil, output: legacy,
                                 compatibilityNote: "当前 tc 不支持 JSON；显示固件的实际文本统计，不把未解析字段显示为 0。", readAt: Date())
    }

    func text(_ request: SQMReadRequest) async throws -> String {
        let path: String
        switch request {
        case .scriptHelp(let name):
            guard Self.validName(name), name.hasSuffix(".qos") else { throw ConfigurationError.invalidIdentifier }
            let scripts = try Self.names(await call("file", "list", ["path": .string("/usr/lib/sqm")]), suffix: ".qos")
            guard scripts.contains(name) else { throw OpenWrtKitError.unsupported("此脚本已不在固件目录中，请重新读取。") }
            path = "/usr/lib/sqm/" + name + ".help"
            let value = try await call("file", "read", ["path": .string(path)])
            guard let data = value["data"].stringValue, data.utf8.count <= 256 * 1024 else { throw OpenWrtKitError.malformedResponse }
            return data
        case .startLog(let interface), .stopLog(let interface):
            guard WakeOnLANTarget.validInterface(interface) else { throw ConfigurationError.invalidIdentifier }
            let config = try RouterConfiguration.parse(name: "sqm", value: await call("uci", "get", ["config": .string("sqm")]))
            guard config.sections.contains(where: { $0.type == "queue" && $0.values["interface"]?.stringValue == interface }) else {
                throw ConfigurationError.changedElsewhere
            }
            let suffix: String
            if case .startLog = request { suffix = ".start-sqm.log" } else { suffix = ".stop-sqm.log" }
            path = "/var/run/sqm/" + interface + suffix
        }
        let result = try await exec("/usr/bin/tail", ["-n", "200", path])
        guard result.exitCode == 0 else { throw commandFailure(result) }
        return result.stdout
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    static func names(_ value: JSONValue, suffix: String? = nil) throws -> [String] {
        guard let entries = value["entries"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        var names = Set<String>()
        for entry in entries {
            guard let name = entry["name"].stringValue, let type = entry["type"].stringValue else { throw OpenWrtKitError.malformedResponse }
            guard validName(name), ["file", "link", "directory"].contains(type) else { throw OpenWrtKitError.malformedResponse }
            if type == "directory" { continue }
            if let suffix, !name.hasSuffix(suffix) { continue }
            guard names.insert(name).inserted else { throw OpenWrtKitError.malformedResponse }
        }
        return names.sorted()
    }
    private func commandFailure(_ result: RouterCommandResult) -> OpenWrtKitError {
        .unsupported("SQM 查询失败（退出码 \(result.exitCode)）：\(result.stderr)\n\(result.stdout)")
    }
    private func exec(_ command: String, _ params: [String]) async throws -> RouterCommandResult {
        try RouterCommandResult(value: await call("file", "exec", ["command": .string(command), "params": .array(params.map(JSONValue.string))]))
    }
    private func call(_ object: String, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try Task.checkCancellation()
        return try await client.call(session: session, object: object, method: method, parameters: params)
    }
}
