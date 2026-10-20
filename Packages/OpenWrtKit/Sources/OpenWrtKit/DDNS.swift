import Foundation

public struct DDNSInstanceStatus: Equatable, Identifiable, Sendable {
    public let id: String
    public let address: String?
    public let lastUpdate: String?
    public let nextUpdate: String?
    public let nextCheck: String?
    public let pid: Int?
    /// A reported null PID means stopped. An omitted PID means unknown.
    public let pidReported: Bool

    static func parse(id: String, value: JSONValue) throws -> Self {
        guard InventoryParser.validIdentifier(id), let fields = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        func text(_ key: String) throws -> String? {
            guard let value = fields[key], value != .null else { return nil }
            guard let text = value.stringValue else { throw OpenWrtKitError.malformedResponse }
            return text
        }
        var pid: Int?
        if let value = fields["pid"], value != .null {
            guard let number = value.intValue, number > 0 else { throw OpenWrtKitError.malformedResponse }
            pid = number
        }
        return try Self(id: id, address: text("ip")?.replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br />", with: "\n"),
                        lastUpdate: text("last_update"), nextUpdate: text("next_update"), nextCheck: text("next_check"),
                        pid: pid, pidReported: fields["pid"] != nil)
    }
}

public struct DDNSRuntimeSnapshot: Sendable {
    public let configuration: RouterConfiguration?
    public let instances: [DDNSInstanceStatus]?
    public let state: [String: JSONValue]?
    public let environment: [String: Bool]?
    public let issues: [String: String]
    public let readAt: Date
}

public enum DDNSInstanceAction: String, Identifiable, Sendable {
    case restart, stop
    public var id: String { rawValue }
    public var title: String { self == .restart ? "启动 / 重新检查" : "停止实例" }
}

struct DDNSClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read() async -> DDNSRuntimeSnapshot {
        async let config = capture { try RouterConfiguration.parse(name: "ddns", value: await client.call(session: session, object: "uci", method: "get", parameters: ["config": .string("ddns")])) }
        async let status = capture { try await rpc("get_services_status") }
        async let state = capture { try await rpc("get_ddns_state") }
        async let env = capture { try await rpc("get_env") }
        let results = await (config, status, state, env)
        var issues: [String: String] = [:]
        var configuration: RouterConfiguration?, instances: [DDNSInstanceStatus]?, stateFields: [String: JSONValue]?, environment: [String: Bool]?
        do { configuration = try results.0.get() } catch { issues["实例配置"] = error.localizedDescription }
        do {
            guard let fields = try results.1.get().objectValue else { throw OpenWrtKitError.malformedResponse }
            instances = try fields.keys.sorted().map { try DDNSInstanceStatus.parse(id: $0, value: fields[$0]!) }
        } catch { issues["实例状态"] = error.localizedDescription }
        do {
            guard let fields = try results.2.get().objectValue else { throw OpenWrtKitError.malformedResponse }
            for key in ["_version", "_curr_dateformat", "_services_list"] {
                if let value = fields[key], value != .null, value.stringValue == nil { throw OpenWrtKitError.malformedResponse }
            }
            if let value = fields["_enabled"], value != .null, value.boolValue == nil { throw OpenWrtKitError.malformedResponse }
            stateFields = fields
        } catch { issues["全局状态"] = error.localizedDescription }
        do {
            guard let fields = try results.3.get().objectValue else { throw OpenWrtKitError.malformedResponse }
            var flags: [String: Bool] = [:]
            for key in ["has_wget", "has_curl", "has_ssl", "has_proxy", "has_forceip", "has_bindnet", "has_bindhost", "has_dnsserver", "has_cacerts", "has_ipv6"] {
                if let value = fields[key] {
                    guard let supported = value.boolValue else { throw OpenWrtKitError.malformedResponse }
                    flags[key] = supported
                }
            }
            environment = flags
        } catch { issues["运行依赖"] = error.localizedDescription }
        return DDNSRuntimeSnapshot(configuration: configuration, instances: instances, state: stateFields, environment: environment, issues: issues, readAt: Date())
    }

    func log(instanceID: String) async throws -> String {
        guard InventoryParser.validIdentifier(instanceID) else { throw ConfigurationError.invalidIdentifier }
        let value = try await rpc("get_services_log", ["service_name": .string(instanceID)])
        guard let log = value["result"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return log
    }

    func actionAccess() async throws -> Bool {
        let method = try await access(scope: "ubus", object: "file", function: "exec")
        let executable = try await access(scope: "file", object: "/etc/init.d/ddns", function: "exec")
        return method && executable
    }

    func perform(_ action: DDNSInstanceAction, observed: ConfigurationSection, status: DDNSInstanceStatus) async throws -> RouterCommandResult {
        guard InventoryParser.validIdentifier(observed.id), observed.type == "service", observed.id == status.id else { throw ConfigurationError.invalidIdentifier }
        guard try await actionAccess() else { throw OpenWrtKitError.permissionDenied }
        let changes = try await client.call(session: session, object: "uci", method: "changes")
        guard let staged = changes["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
        guard staged.isEmpty else { throw ConfigurationError.existingChanges }
        let current = try RouterConfiguration.parse(name: "ddns", value: await client.call(session: session, object: "uci", method: "get", parameters: ["config": .string("ddns")]))
        guard current.sections.first(where: { $0.id == observed.id }) == observed else { throw ConfigurationError.changedElsewhere }
        let latest = try DDNSInstanceStatus.parse(id: observed.id, value: await rpc("get_services_status")[observed.id])
        if action == .restart {
            guard observed.values["enabled"]?.stringValue == "1" else { throw OpenWrtKitError.unsupported("请先在配置中启用该实例，并应用和确认修改。") }
        } else {
            guard status.pidReported, latest.pidReported, let pid = status.pid, latest.pid == pid else {
                throw OpenWrtKitError.unsupported("实例进程已变化、停止或未知。请重新读取状态后再操作。")
            }
        }
        try Task.checkCancellation()
        do {
            let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                "command": .string("/etc/init.d/ddns"), "params": .array([.string(action.rawValue), .string(observed.id)])
            ])
            return try RouterCommandResult(value: value)
        } catch {
            throw OpenWrtKitError.unsupported("DDNS 操作结果未确认：\(error.localizedDescription)。请求可能已经执行；请先重读实例状态与日志，不要直接重试。")
        }
    }

    private func rpc(_ method: String, _ parameters: [String: JSONValue] = [:]) async throws -> JSONValue {
        let value = try await client.call(session: session, object: "luci.ddns", method: method, parameters: parameters)
        guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
        return value
    }
    private func access(scope: String, object: String, function: String) async throws -> Bool {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: ["scope": .string(scope), "object": .string(object), "function": .string(function)])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }
    private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
