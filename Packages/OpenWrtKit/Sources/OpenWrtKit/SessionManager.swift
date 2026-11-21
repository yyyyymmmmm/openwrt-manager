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
    /// The LuCI web-login cookie pair ("sysauth_http=…"), issued alongside
    /// the ubus session and discarded with it. LuCI's dispatcher does not
    /// recognize a bare ubus session (see UbusClient.luciLogin), so the
    /// menu endpoint is authenticated with this cookie instead.
    private var luciCookie: String?
    /// The negotiated localization context, fetched once per session:
    /// the translations catalog is the router's full dictionary
    /// (thousands of entries), and every sub-page resolves its
    /// router-source strings through it, so it must not be re-fetched
    /// per page. Discarded with the session.
    private var cachedLocalization: LuciLocalization?

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

    /// The LuCI menu tree, authenticated with the LuCI login cookie (not
    /// the ubus token — LuCI would treat that as anonymous and return a
    /// stripped menu). A permission rejection discards both sessions,
    /// re-logs in on both channels, and retries exactly once.
    public func menu() async throws -> JSONValue {
        let session = try await session()
        do {
            return try await client.menu(cookie: luciSessionCookie())
        } catch OpenWrtKitError.permissionDenied {
            invalidate(ifMatching: session)
            _ = try await login()
            return try await client.menu(cookie: luciSessionCookie())
        }
    }

    /// The cached LuCI cookie, logging in via LuCI's web flow when there
    /// is none. A failed LuCI login throws here — loudly, at the one call
    /// site that needs it — instead of degrading the menu silently.
    private func luciSessionCookie() async throws -> String {
        if let luciCookie { return luciCookie }
        guard let credentials = await credentialProvider.routerCredentials() else {
            throw OpenWrtKitError.authenticationFailed
        }
        let cookie = try await client.luciLogin(username: credentials.username, password: credentials.password)
        luciCookie = cookie
        return cookie
    }

    /// The LuCI translation catalog for menu titles, negotiated from
    /// the router's own luci config. A failed luci-config read simply
    /// yields no catalog; a failed catalog fetch throws so discovery
    /// can note it — titles then stay in the source language, they are
    /// never fabricated.
    public func translationsCatalog() async throws -> LuciTranslationCatalog? {
        try await localization().catalog
    }

    /// The localization context behind translationsCatalog(): same
    /// negotiation and fetch, but the negotiated language travels with
    /// the catalog so discovery can tag its snapshot with it.
    public func localization() async throws -> LuciLocalization {
        if let cachedLocalization { return cachedLocalization }
        _ = try await session()
        let config = try? await call(object: "uci", method: "get", parameters: ["config": .string("luci")])
        let localization = try await client.localization(cookie: luciSessionCookie(), luciConfig: config)
        cachedLocalization = localization
        return localization
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

    public func invalidate() {
        current = nil
        luciCookie = nil
        cachedLocalization = nil
    }

    private func invalidate(ifMatching session: UbusSession) {
        if current?.token == session.token {
            current = nil
            luciCookie = nil
            cachedLocalization = nil
        }
    }

    public func logout() async {
        guard let current else { return }
        self.current = nil
        luciCookie = nil
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
