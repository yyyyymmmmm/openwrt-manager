import Foundation

/// The session-bound ubus surface every read/write component consumes.
/// Two implementations exist: FixedSessionCaller (one login, used by tests
/// and single-shot flows) and SessionManager (expiry tracking with automatic
/// re-login, used by the app). Components depend only on this protocol, so
/// the session lifecycle can be swapped without touching call sites.
public protocol UbusCalling: Sendable {
    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue
    func menu() async throws -> JSONValue
    func installedPackages() async throws -> [InstalledPackage]
    func destroySession() async
}

extension UbusCalling {
    public func destroySession() async {}

    /// Parameterless convenience mirroring UbusClient.call's default.
    public func call(object: String, method: String) async throws -> JSONValue {
        try await call(object: object, method: method, parameters: [:])
    }
}

/// A caller bound to one already-established session. No renewal: when the
/// session dies, calls fail with the router's own error.
public struct FixedSessionCaller: UbusCalling {
    private let client: UbusClient
    private let session: UbusSession

    public init(client: UbusClient, session: UbusSession) {
        self.client = client
        self.session = session
    }

    public func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(session: session, object: object, method: method, parameters: parameters)
    }

    public func menu() async throws -> JSONValue {
        try await client.menu(session: session)
    }

    public func installedPackages() async throws -> [InstalledPackage] {
        try await client.installedPackages(session: session)
    }

    public func destroySession() async {
        _ = try? await client.call(session: session, object: "session", method: "destroy")
    }
}

extension SessionManager: UbusCalling {
    // The three-argument call is the protocol surface; the replay-aware
    // variant stays available on the concrete type for write paths.
    public func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        try await call(object: object, method: method, parameters: parameters, replayAfterRelogin: true)
    }

    public func destroySession() async {
        await logout()
    }
}
