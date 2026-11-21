import Foundation

public struct ConfigurationSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var anonymous: Bool
    public var values: [String: JSONValue]
    public init(id: String, type: String, anonymous: Bool = false, values: [String: JSONValue] = [:]) {
        self.id = id; self.type = type; self.anonymous = anonymous; self.values = values
    }
}

public struct RouterConfiguration: Equatable, Sendable {
    public let name: String
    public var sections: [ConfigurationSection]
    public init(name: String, sections: [ConfigurationSection]) { self.name = name; self.sections = sections }

    public static func parse(name: String, value: JSONValue) throws -> RouterConfiguration {
        guard let values = value["values"].objectValue else { throw OpenWrtKitError.malformedResponse }
        let sorted = values.sorted {
            let left = $0.value[".index"].intValue ?? 0, right = $1.value[".index"].intValue ?? 0
            return left == right ? $0.key < $1.key : left < right
        }
        let sections = try sorted.map { key, value -> ConfigurationSection in
            guard let type = value[".type"].stringValue, let object = value.objectValue else {
                throw OpenWrtKitError.malformedResponse
            }
            return ConfigurationSection(id: key, type: type, anonymous: value[".anonymous"].boolValue ?? false,
                                        values: object.filter { !$0.key.hasPrefix(".") })
        }
        return RouterConfiguration(name: name, sections: sections)
    }
}

public enum ConfigurationEdit: Equatable, Sendable {
    case add(ConfigurationSection)
    case removeSection(String)
    case set(section: String, option: String, value: JSONValue)
    case removeOption(section: String, option: String)

    public var summary: String {
        switch self {
        case .add(let section): return KitL10n.format("新增 %@ 配置节", section.type)
        case .removeSection(let name): return KitL10n.format("删除配置节 %@", name)
        case .set(let section, let option, _): return KitL10n.format("设置 %@.%@", section, option)
        case .removeOption(let section, let option): return KitL10n.format("删除 %@.%@", section, option)
        }
    }
}

public struct ConfigurationPlan: Sendable {
    public let original: RouterConfiguration
    public let edited: RouterConfiguration
    public let edits: [ConfigurationEdit]

    public init(original: RouterConfiguration, edited: RouterConfiguration) throws {
        guard original.name == edited.name, InventoryParser.validIdentifier(original.name) else {
            throw ConfigurationError.invalidIdentifier
        }
        let old = Dictionary(original.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard Set(edited.sections.map(\.id)).count == edited.sections.count else { throw ConfigurationError.invalidIdentifier }
        var edits: [ConfigurationEdit] = []
        for section in original.sections where !edited.sections.contains(where: { $0.id == section.id }) {
            edits.append(.removeSection(section.id))
        }
        for section in edited.sections {
            guard InventoryParser.validIdentifier(section.id), InventoryParser.validIdentifier(section.type),
                  section.values.keys.allSatisfy(InventoryParser.validIdentifier) else { throw ConfigurationError.invalidIdentifier }
            guard let previous = old[section.id] else {
                guard section.values.values.allSatisfy(Self.validValue) else { throw ConfigurationError.invalidValue }
                edits.append(.add(section)); continue
            }
            guard previous.type == section.type, previous.anonymous == section.anonymous else { throw ConfigurationError.invalidValue }
            for option in previous.values.keys.sorted() where section.values[option] == nil {
                edits.append(.removeOption(section: section.id, option: option))
            }
            for option in section.values.keys.sorted() {
                guard let value = section.values[option], previous.values[option] != value else { continue }
                guard Self.validValue(value) else { throw ConfigurationError.invalidValue }
                edits.append(.set(section: section.id, option: option, value: value))
            }
        }
        self.original = original; self.edited = edited; self.edits = edits
    }

    private static func validValue(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): return !text.contains("\0") && text.utf8.count <= 65_536
        case .array(let list): return list.count <= 4096 && list.allSatisfy { if case .string = $0 { return validValue($0) }; return false }
        default: return false
        }
    }
}

public enum ConfigurationError: LocalizedError, Equatable {
    case invalidIdentifier, invalidValue, changedElsewhere, existingChanges, busy, noChanges, noPending
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return KitL10n.text("配置名称只能包含字母、数字、下划线和连字符，且不能重复。")
        case .invalidValue: return KitL10n.text("配置包含无法写入的值。请使用文本或文本列表。")
        case .changedElsewhere: return KitL10n.text("路由器配置已发生变化。请重新读取后再修改，避免覆盖其他操作。")
        case .existingChanges: return KitL10n.text("当前会话已有未提交修改。请先处理这些修改，再应用本次配置。")
        case .busy: return KitL10n.text("已有配置正在应用或等待确认，请先完成该操作。")
        case .noChanges: return KitL10n.text("没有需要应用的修改。")
        case .noPending: return KitL10n.text("没有等待确认的配置。请重新读取路由器状态。")
        }
    }
}

public struct PendingConfiguration: Equatable, Sendable {
    public let config: String
    public let deadline: Date
    public let acknowledged: Bool
    public init(config: String, deadline: Date, acknowledged: Bool) {
        self.config = config; self.deadline = deadline; self.acknowledged = acknowledged
    }
}

/// A single session owns the staging area. Never commit without rpcd rollback.
public actor RouterConfigurationClient {
    private let caller: any UbusCalling
    private var busy = false
    private var pending: PendingConfiguration?
    public init(caller: any UbusCalling) { self.caller = caller }
    public init(client: UbusClient, session: UbusSession) { self.caller = FixedSessionCaller(client: client, session: session) }

    public func read(_ name: String) async throws -> RouterConfiguration {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let value = try await caller.call(object: "uci", method: "get", parameters: ["config": .string(name)])
        return try RouterConfiguration.parse(name: name, value: value)
    }

    public func access(config: String, write: Bool) async throws -> Bool {
        let result = try await caller.call(object: "session", method: "access", parameters: [
            "scope": .string("uci"), "object": .string(config), "function": .string(write ? "write" : "read")
        ])
        guard let allowed = result["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }

    public func apply(_ plan: ConfigurationPlan) async throws -> PendingConfiguration {
        guard !busy, pending == nil else { throw ConfigurationError.busy }
        guard !plan.edits.isEmpty else { throw ConfigurationError.noChanges }
        busy = true
        defer { busy = false }
        guard try await access(config: plan.original.name, write: true) else { throw OpenWrtKitError.permissionDenied }
        for method in ["apply", "confirm", "revert", "rollback"] {
            let permission = try await caller.call(object: "session", method: "access", parameters: [
                "scope": .string("ubus"), "object": .string("uci"), "function": .string(method)
            ])
            guard permission["access"].boolValue == true else { throw OpenWrtKitError.permissionDenied }
        }
        let changes = try await caller.call(object: "uci", method: "changes")
        guard let existing = changes["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
        guard existing.isEmpty else { throw ConfigurationError.existingChanges }
        guard try await read(plan.original.name) == plan.original else { throw ConfigurationError.changedElsewhere }
        let config: [String: JSONValue] = ["config": .string(plan.original.name)]
        do {
            for edit in plan.edits {
                try Task.checkCancellation()
                var parameters = config
                let method: String
                switch edit {
                case .add(let section):
                    method = "add"; parameters["type"] = .string(section.type); parameters["values"] = .object(section.values)
                    if !section.anonymous { parameters["name"] = .string(section.id) }
                case .removeSection(let section):
                    method = "delete"; parameters["section"] = .string(section)
                case .set(let section, let option, let value):
                    method = "set"; parameters["section"] = .string(section); parameters["values"] = .object([option: value])
                case .removeOption(let section, let option):
                    method = "delete"; parameters["section"] = .string(section); parameters["option"] = .string(option)
                }
                _ = try await caller.call(object: "uci", method: method, parameters: parameters)
            }
        } catch {
            // Only this transaction's config is reverted; pre-existing changes were refused.
            do { _ = try await caller.call(object: "uci", method: "revert", parameters: config) }
            catch { throw OpenWrtKitError.unsupported(KitL10n.text("写入未完成，暂存修改也未能清理。请保持会话并重新检查配置，勿重复提交。")) }
            throw error
        }
        let deadline = Date().addingTimeInterval(90)
        do {
            _ = try await caller.call(object: "uci", method: "apply", parameters: ["rollback": .bool(true), "timeout": .number(90)])
            let value = PendingConfiguration(config: plan.original.name, deadline: deadline, acknowledged: true)
            pending = value
            return value
        } catch let error as URLError {
            // A dropped connection may mean the network change already applied.
            let value = PendingConfiguration(config: plan.original.name, deadline: deadline, acknowledged: false)
            pending = value
            _ = error
            return value
        } catch {
            _ = try? await caller.call(object: "uci", method: "revert", parameters: config)
            throw error
        }
    }

    /// The full L4 transaction (spec section 1): the plan was built from a
    /// pre-change snapshot and previewed by the user; this stages and
    /// applies it inside rpcd's rollback window, reloads the affected
    /// services, re-reads the configuration and verifies it matches the
    /// intended result, and only then confirms. Any failure before the
    /// confirm rolls the router back to the pre-change state. A failed
    /// confirm itself leaves the transaction pending (state unknown —
    /// the caller must resolve it explicitly, never silently).
    public func execute(plan: ConfigurationPlan, reloadServices: [String] = [],
                        serviceAction: @escaping @Sendable (String, ServiceAction) async throws -> Void = { _, _ in })
        async throws -> TransactionReceipt {
        let pending = try await apply(plan)
        guard pending.acknowledged else { throw TransactionError.unacknowledged }
        do {
            for service in reloadServices {
                do { try await serviceAction(service, .restart) }
                catch { throw TransactionError.reloadFailed(service) }
            }
            let reread = try await read(plan.original.name)
            guard reread == plan.edited else { throw TransactionError.verificationFailed(plan.original.name) }
        } catch {
            try? await rollback()
            throw error
        }
        try await confirm()
        return TransactionReceipt(config: plan.original.name, editCount: plan.edits.count,
                                  reloadedServices: reloadServices, verifiedAt: Date())
    }

    public func confirm() async throws {
        guard !busy else { throw ConfigurationError.busy }
        guard let pending, pending.deadline > Date() else { throw ConfigurationError.noPending }
        busy = true
        defer { busy = false }
        _ = try await caller.call(object: "system", method: "board")
        _ = try await caller.call(object: "uci", method: "confirm")
        self.pending = nil
    }

    public func rollback() async throws {
        guard !busy else { throw ConfigurationError.busy }
        guard pending != nil else { throw ConfigurationError.noPending }
        busy = true
        defer { busy = false }
        _ = try await caller.call(object: "uci", method: "rollback")
        pending = nil
    }

    public func releaseExpired() {
        if let pending, pending.deadline <= Date() { self.pending = nil }
    }
}

public enum ServiceAction: String, CaseIterable, Identifiable, Sendable {
    case start, stop, restart, enable, disable
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .start: return KitL10n.text("启动")
        case .stop: return KitL10n.text("停止")
        case .restart: return KitL10n.text("重启")
        case .enable: return KitL10n.text("启用开机启动")
        case .disable: return KitL10n.text("关闭开机启动")
        }
    }
}
