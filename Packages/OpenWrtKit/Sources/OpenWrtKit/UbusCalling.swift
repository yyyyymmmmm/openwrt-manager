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
    /// The router's LuCI translation catalog for menu titles, when its
    /// effective language is not English. Default: no catalog (callers
    /// keep the source-language titles).
    func translationsCatalog() async throws -> LuciTranslationCatalog?
    /// The router's localization context: the negotiated catalog
    /// language plus its catalog — the single entry every router-source
    /// display string is resolved through. Default: derived from
    /// translationsCatalog(), tagged "source" because a caller that
    /// only provides a catalog cannot report the negotiated language;
    /// the app then re-discovers instead of caching a snapshot under a
    /// wrong language tag.
    func localization() async throws -> LuciLocalization
    func destroySession() async
    /// Drops the current session so the next call logs in again. Used by
    /// discovery's self-healing when a haul comes back at anonymous grade
    /// (the session was not recognized as logged in). Callers that cannot
    /// re-login (FixedSessionCaller) keep the default no-op.
    func invalidateSession() async
}

extension UbusCalling {
    public func destroySession() async {}
    public func invalidateSession() async {}
    public func translationsCatalog() async throws -> LuciTranslationCatalog? { nil }
    public func localization() async throws -> LuciLocalization {
        guard let catalog = try await translationsCatalog() else { return .source }
        return LuciLocalization(language: "source", catalog: catalog)
    }

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
    /// LuCI login cookie pair for the menu endpoint, when the fixed
    /// session was established together with a LuCI web login.
    private let luciCookie: String?

    public init(client: UbusClient, session: UbusSession, luciCookie: String? = nil) {
        self.client = client
        self.session = session
        self.luciCookie = luciCookie
    }

    public func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(session: session, object: object, method: method, parameters: parameters)
    }

    public func menu() async throws -> JSONValue {
        guard let luciCookie else {
            throw OpenWrtKitError.unsupported(KitL10n.text("固定会话没有 LuCI 登录 cookie，无法读取菜单（菜单需要 LuCI 网页登录会话）。"))
        }
        return try await client.menu(cookie: luciCookie)
    }

    public func installedPackages() async throws -> [InstalledPackage] {
        try await client.installedPackages(session: session)
    }

    public func translationsCatalog() async throws -> LuciTranslationCatalog? {
        try await localization().catalog
    }

    public func localization() async throws -> LuciLocalization {
        guard let luciCookie else { return .source }
        let config = try? await client.call(session: session, object: "uci", method: "get",
                                            parameters: ["config": .string("luci")])
        return try await client.localization(cookie: luciCookie, luciConfig: config)
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

    public func invalidateSession() async {
        await invalidate()
    }
}
