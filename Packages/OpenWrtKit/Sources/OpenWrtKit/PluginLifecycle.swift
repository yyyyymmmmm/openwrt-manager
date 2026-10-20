import Foundation

/// These adapters have an actual runtime read path. This is not a registry of
/// every installed plugin and must never be used to filter discovery.
public enum PluginServiceTarget: String, Sendable {
    case sqm, zerotier
    public var title: String { self == .sqm ? "SQM" : "ZeroTier" }
}

public struct PluginServiceSnapshot: Sendable {
    public let target: PluginServiceTarget
    public let configuration: RouterConfiguration?
    public let startup: InitService?
    public let service: RouterService?
    public let actionAllowed: Bool?
    public let networks: [ZeroTierNetwork]?
    public let kernel: SQMKernelSnapshot?
    public let issues: [String: String]
    public let readAt: Date
}

public enum PluginServiceError: LocalizedError, Sendable {
    case rejected, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .rejected:
            return "启动脚本报告操作失败。可能已有部分改变，请核对实际状态和日志；不会自动重试。"
        case .uncertain(let message):
            return "服务操作结果未确认：\(message)。可能已经执行，请先重读实际状态和日志，再决定下一步，不会自动重试。"
        }
    }
}

struct PluginLifecycleClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read(_ target: PluginServiceTarget) async -> PluginServiceSnapshot {
        var configuration: RouterConfiguration?, startup: InitService?
        var service: RouterService?, actionAllowed: Bool?
        var networks: [ZeroTierNetwork]?, kernel: SQMKernelSnapshot?
        var issues: [String: String] = [:]
        do { configuration = try await config(target) }
        catch { issues["持久配置"] = error.localizedDescription }
        do {
            let list = try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList"))
            startup = list.first { $0.name == target.rawValue }
            if startup == nil { issues["启动项"] = "固件没有返回对应启动项；不能确认可用的服务操作。" }
        } catch { issues["启动项"] = error.localizedDescription }
        do { actionAllowed = try await actionAccess() }
        catch { issues["操作权限"] = error.localizedDescription }
        do {
            service = try await RouterReader(client: client, session: session).services().first { $0.name == target.rawValue }
        } catch { issues["运行实例"] = error.localizedDescription }
        switch target {
        case .sqm:
            do { kernel = try await SQMClient(client: client, session: session).kernel() }
            catch { issues["内核队列"] = error.localizedDescription }
        case .zerotier:
            do { networks = try await RouterReader(client: client, session: session).zeroTierNetworks() }
            catch { issues["客户端网络"] = error.localizedDescription }
        }
        return PluginServiceSnapshot(target: target, configuration: configuration, startup: startup,
                                     service: service, actionAllowed: actionAllowed,
                                     networks: networks, kernel: kernel, issues: issues, readAt: Date())
    }

    func action(_ target: PluginServiceTarget, _ action: ServiceAction, observed: RouterConfiguration) async throws {
        guard observed.name == target.rawValue else { throw ConfigurationError.invalidIdentifier }
        // A service reload can consume pending UCI changes or persist state.
        // Never trigger it while the current session has unconfirmed changes.
        try await noChanges()
        guard try await config(target) == observed else { throw ConfigurationError.changedElsewhere }
        let list = try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList"))
        guard list.contains(where: { $0.name == target.rawValue }) else {
            throw OpenWrtKitError.unsupported("此插件不在当前启动项目录中，未发送服务操作。")
        }
        guard try await actionAccess() else { throw OpenWrtKitError.permissionDenied }
        try await noChanges()
        guard try await config(target) == observed else { throw ConfigurationError.changedElsewhere }
        try Task.checkCancellation()
        // Only the mutation itself enters the uncertain window. A read/ACL
        // preflight failure must never imply that the action was dispatched.
        let response: JSONValue
        do {
            response = try await client.call(session: session, object: "luci", method: "setInitAction", parameters: [
                "name": .string(target.rawValue), "action": .string(action.rawValue)
            ])
        } catch OpenWrtKitError.permissionDenied {
            throw OpenWrtKitError.permissionDenied
        } catch { throw PluginServiceError.uncertain(error.localizedDescription) }
        guard let accepted = response["result"].boolValue else {
            throw PluginServiceError.uncertain("固件未返回可识别的操作结果")
        }
        guard accepted else { throw PluginServiceError.rejected }
    }

    private func actionAccess() async throws -> Bool {
        let access = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("luci"), "function": .string("setInitAction")
        ])
        guard let allowed = access["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }

    private func config(_ target: PluginServiceTarget) async throws -> RouterConfiguration {
        try RouterConfiguration.parse(name: target.rawValue, value: await client.call(session: session, object: "uci", method: "get", parameters: [
            "config": .string(target.rawValue)
        ]))
    }

    private func noChanges() async throws {
        let value = try await client.call(session: session, object: "uci", method: "changes")
        guard let changes = value["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
        guard changes.isEmpty else { throw ConfigurationError.existingChanges }
    }
}
