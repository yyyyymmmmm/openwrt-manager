import Foundation

/// Outcome of one completed L4 configuration transaction.
public struct TransactionReceipt: Equatable, Sendable {
    public var config: String
    public var editCount: Int
    public var reloadedServices: [String]
    public var verifiedAt: Date
    public init(config: String, editCount: Int, reloadedServices: [String], verifiedAt: Date) {
        self.config = config; self.editCount = editCount
        self.reloadedServices = reloadedServices; self.verifiedAt = verifiedAt
    }
}

public enum TransactionError: LocalizedError, Equatable {
    /// The router never acknowledged the apply; the transaction stays
    /// pending for explicit resolution instead of guessing its state.
    case unacknowledged
    /// A service reload inside the transaction failed; the configuration
    /// was rolled back.
    case reloadFailed(String)
    /// The post-apply re-read did not match the intended configuration;
    /// the configuration was rolled back.
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unacknowledged: return KitL10n.text("路由器未确认应用结果，事务保持待处理状态，请核对后再决定保留或回滚。")
        case .reloadFailed(let service): return KitL10n.format("服务 %@ 重载失败，配置已回滚。", service)
        case .verificationFailed(let config): return KitL10n.format("回读验证失败：%@ 的实际内容与预期不一致，配置已回滚。", config)
        }
    }
}

/// Service actions as mini-transactions: snapshot the state, perform,
/// re-read and verify. The state reader and performer are injected so the
/// flow is testable without a router; the app wires them to the reader's
/// service list and setInitAction.
public struct ServiceActionTransaction: Sendable {
    public struct State: Equatable, Sendable {
        public var running: Bool?
        public var enabled: Bool?
        public init(running: Bool? = nil, enabled: Bool? = nil) {
            self.running = running; self.enabled = enabled
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var before: State?
        public var after: State?
        /// nil when the action has no verifiable end state (e.g. restart
        /// of a one-shot service); false means the router's reported state
        /// contradicts the action and the UI must say so.
        public var verified: Bool?
    }

    public typealias StateReader = @Sendable (String) async throws -> State?
    public typealias Performer = @Sendable (String, ServiceAction) async throws -> Void

    private let readState: StateReader
    private let perform: Performer

    public init(readState: @escaping StateReader, perform: @escaping Performer) {
        self.readState = readState
        self.perform = perform
    }

    public func execute(name: String, action: ServiceAction) async throws -> Outcome {
        let before = try await readState(name)
        try await perform(name, action)
        let after = try await readState(name)
        return Outcome(before: before, after: after, verified: Self.verify(action: action, after: after))
    }

    static func verify(action: ServiceAction, after: State?) -> Bool? {
        guard let after else { return nil }
        switch action {
        case .start, .restart:
            return after.running.map { $0 }
        case .stop:
            return after.running.map { !$0 }
        case .enable:
            return after.enabled.map { $0 }
        case .disable:
            return after.enabled.map { !$0 }
        }
    }
}

/// System-level actions that are not UCI configuration. Each is a single
/// ubus call; the strong confirmation lives in the UI, and callers treat
/// the inevitable connection drop after a reboot as expected.
public struct SystemControlClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public func reboot() async throws {
        _ = try await caller.call(object: "system", method: "reboot")
    }

    /// WAN redial (package B quick action): cycle one network
    /// interface down and back up through its own ubus object — the
    /// same call LuCI's interface "Restart" makes. The down call is
    /// allowed to fail (the interface may already be down); the up
    /// call is the verdict and its failure propagates.
    public func restartInterface(name: String) async throws {
        _ = try? await caller.call(object: "network.interface.\(name)", method: "down")
        _ = try await caller.call(object: "network.interface.\(name)", method: "up")
    }
}
