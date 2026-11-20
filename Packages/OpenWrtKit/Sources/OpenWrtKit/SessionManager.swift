import Foundation

public struct RouterCredentials: Sendable, Equatable {
    public let username: String
    public let password: String
    public init(username: String, password: String) {
        self.username = username; self.password = password
    }
}

/// Supplies router credentials on demand. The app implements this over its
/// Keychain store; the kit never persists credentials itself.
public protocol SessionCredentialProvider: Sendable {
    func routerCredentials() async -> RouterCredentials?
}

/// Owns the ubus session lifecycle that the raw UbusClient deliberately does
/// not: expiry tracking with a refresh margin, and one automatic re-login
/// with replay when the router rejects a call as expired/unauthorized
/// (spec L1: an expired session must recover silently, not surface an error
/// asking the user to log in again).
public actor SessionManager {
    private let client: UbusClient
    private let credentialProvider: any SessionCredentialProvider
    private let refreshMargin: TimeInterval
    private var current: UbusSession?

    public init(client: UbusClient, credentialProvider: any SessionCredentialProvider,
                refreshMargin: TimeInterval = 60) {
        self.client = client
        self.credentialProvider = credentialProvider
        self.refreshMargin = refreshMargin
    }

    /// A session that is valid now and stays valid for at least the refresh
    /// margin; logs in (or re-logs in) when there is none.
    public func session() async throws -> UbusSession {
        if let current, current.isUsable(margin: refreshMargin) { return current }
        return try await login()
    }

    /// Performs a ubus call on a fresh-enough session. On a permission
    /// rejection the session is discarded, a new login is made, and the call
    /// is replayed exactly once. Callers handling writes should pass
    /// `replayAfterRelogin: false` unless the write is known idempotent;
    /// transaction-level writes keep their own confirm/rollback flow.
    public func call(object: String, method: String, parameters: [String: JSONValue] = [:],
                     replayAfterRelogin: Bool = true) async throws -> JSONValue {
        let session = try await session()
        do {
            return try await client.call(session: session, object: object, method: method, parameters: parameters)
        } catch OpenWrtKitError.permissionDenied {
            guard replayAfterRelogin else { throw OpenWrtKitError.permissionDenied }
            invalidate(ifMatching: session)
            let renewed = try await login()
            return try await client.call(session: renewed, object: object, method: method, parameters: parameters)
        }
    }

    /// The sysauth cookie value for endpoints that authenticate with the
    /// session token as a cookie (e.g. the LuCI menu endpoint).
    public func menu() async throws -> JSONValue {
        let session = try await session()
        do {
            return try await client.menu(session: session)
        } catch OpenWrtKitError.permissionDenied {
            invalidate(ifMatching: session)
            let renewed = try await login()
            return try await client.menu(session: renewed)
        }
    }

    public func installedPackages() async throws -> [InstalledPackage] {
        let session = try await session()
        do {
            return try await client.installedPackages(session: session)
        } catch OpenWrtKitError.permissionDenied {
            invalidate(ifMatching: session)
            let renewed = try await login()
            return try await client.installedPackages(session: renewed)
        }
    }

    public func invalidate() { current = nil }

    private func invalidate(ifMatching session: UbusSession) {
        if current?.token == session.token { current = nil }
    }

    public func logout() async {
        guard let current else { return }
        self.current = nil
        _ = try? await client.call(session: current, object: "session", method: "destroy")
    }

    private func login() async throws -> UbusSession {
        guard let credentials = await credentialProvider.routerCredentials() else {
            throw OpenWrtKitError.authenticationFailed
        }
        let session = try await client.login(username: credentials.username, password: credentials.password)
        current = session
        return session
    }
}
