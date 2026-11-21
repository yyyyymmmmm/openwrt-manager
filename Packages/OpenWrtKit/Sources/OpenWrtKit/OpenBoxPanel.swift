import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open-Box runs its own panel on port 3036 of the bypass router (spec
/// 3.3). The dedicated page reads it through the panel's HTTP API — still
/// fully native UI; the panel is a data source, never an embedded page.

public struct OpenBoxServiceStatus: Equatable, Sendable {
    public var coreRunning: Bool?
    public var panelRunning: Bool?
    public var coreEnabled: Bool?
    public var panelEnabled: Bool?
    public var needsRestart: Bool?
    public init(coreRunning: Bool? = nil, panelRunning: Bool? = nil,
                coreEnabled: Bool? = nil, panelEnabled: Bool? = nil, needsRestart: Bool? = nil) {
        self.coreRunning = coreRunning; self.panelRunning = panelRunning
        self.coreEnabled = coreEnabled; self.panelEnabled = panelEnabled
        self.needsRestart = needsRestart
    }
}

public struct OpenBoxProxy: Identifiable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var current: String?
    public var members: [String]
    public var id: String { name }
    public init(name: String, type: String, current: String? = nil, members: [String] = []) {
        self.name = name; self.type = type; self.current = current; self.members = members
    }
}

public enum OpenBoxParser {
    /// GET /api/openbox/service/status — the payload nests per-component
    /// state; the parser searches the known component keys rather than
    /// pinning one exact nesting, which varies between panel versions.
    public static func serviceStatus(_ value: JSONValue) -> OpenBoxServiceStatus {
        func component(_ keys: [String]) -> JSONValue {
            for key in keys where value[key] != .null { return value[key] }
            return .null
        }
        func running(_ component: JSONValue) -> Bool? {
            component["running"].boolValue ?? component["active"].boolValue
                ?? component["status"].stringValue.map { $0 == "running" }
        }
        func enabled(_ component: JSONValue) -> Bool? {
            component["enabled"].boolValue ?? component["autostart"].boolValue
        }
        let core = component(["core", "kernel", "singbox", "sing-box"])
        let panel = component(["panel", "web", "ui"])
        return OpenBoxServiceStatus(
            coreRunning: running(core) ?? running(value),
            panelRunning: running(panel),
            coreEnabled: enabled(core),
            panelEnabled: enabled(panel),
            needsRestart: value["needsRestart"].boolValue ?? value["pendingRestart"].boolValue)
    }

    /// GET /api/openbox/kernel/version — {"version": "..."} in current
    /// builds; nested forms are tolerated.
    public static func kernelVersion(_ value: JSONValue) -> String? {
        value["version"].stringValue ?? value["kernel"]["version"].stringValue
            ?? value["data"]["version"].stringValue
    }

    /// GET /api/controller/proxies — the panel's Clash-API proxy view:
    /// {"proxies": {name: {"type": ..., "now": ..., "all": [...]}}}.
    public static func proxies(_ value: JSONValue) -> [OpenBoxProxy] {
        (value["proxies"].objectValue ?? [:]).map { name, proxy in
            OpenBoxProxy(name: name,
                         type: proxy["type"].stringValue ?? "",
                         current: proxy["now"].stringValue,
                         members: (proxy["all"].arrayValue ?? []).compactMap(\.stringValue))
        }.sorted { $0.name < $1.name }
    }

    /// GET /api/openbox/groups — selector/urltest groups with selections.
    public static func groups(_ value: JSONValue) -> [OpenBoxProxy] {
        let items = value.arrayValue ?? value["groups"].arrayValue ?? value["data"].arrayValue ?? []
        return items.compactMap { item in
            guard let name = item["name"].stringValue ?? item["id"].stringValue else { return nil }
            return OpenBoxProxy(name: name,
                                type: item["type"].stringValue ?? "",
                                current: item["selected"].stringValue ?? item["now"].stringValue,
                                members: (item["proxies"].arrayValue ?? item["members"].arrayValue ?? [])
                                    .compactMap { $0.stringValue ?? $0["name"].stringValue })
        }.sorted { $0.name < $1.name }
    }

    /// GET /api/controller/connections — {"connections": [...]}.
    public static func connectionCount(_ value: JSONValue) -> Int? {
        value["connections"].arrayValue?.count
    }

    /// GET /api/auth/status — the panel's login state probe (the one
    /// panel endpoint verified reachable without authentication). The
    /// flag has travelled under several key names across builds.
    public static func authenticated(_ value: JSONValue) -> Bool? {
        for key in ["authenticated", "loggedIn", "logged_in", "isAuthenticated", "login"] {
            if let flag = value[key].boolValue { return flag }
        }
        if let status = value["status"].stringValue {
            return status == "authenticated" || status == "logged_in"
        }
        return nil
    }
}

/// Thin read-only HTTP client for the panel. Authentication uses the
/// panel's own login (POST /api/auth/login) and its session cookie; the
/// password comes from the app's credential store, never from the router
/// account.
public struct OpenBoxPanelClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(host: String, port: Int = 3036, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.session = session
    }

    public func login(password: String) async throws {
        _ = try await loginReturningState(password: password)
    }

    /// POST /api/auth/login — the frontend's own login call: JSON
    /// {password}, cookie session (credentials: same-origin). A wrong
    /// password is answered with code ACCESS_PASSWORD_INVALID, which
    /// the caller must be able to tell apart from an unreachable
    /// panel; success returns the panel's auth-state JSON.
    public func loginReturningState(password: String) async throws -> OpenBoxAuthState {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["password": password])
        let (data, response) = try await session.data(for: request)
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        if let code = value.flatMap({ OpenBoxParser.accessCode($0) }) {
            if code == "ACCESS_PASSWORD_INVALID" { throw OpenBoxPanelError.invalidPassword }
            if code == "ACCESS_PASSWORD_REQUIRED" { throw OpenWrtKitError.permissionDenied }
        }
        try check(response)
        return OpenBoxParser.authState(value ?? .null)
    }

    public func get(_ path: String) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Switches a selector group to another node (Clash-API PUT through
    /// the panel proxy). This is a write: callers must confirm with the
    /// user first and re-read the group afterwards to verify.
    public func selectProxy(group: String, node: String) async throws {
        let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        var request = URLRequest(url: baseURL.appendingPathComponent("api/controller/proxies/\(encoded)"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": node])
        let (_, response) = try await session.data(for: request)
        try check(response)
    }

    public func serviceStatus() async throws -> OpenBoxServiceStatus {
        OpenBoxParser.serviceStatus(try await get("api/openbox/service/status"))
    }

    public func kernelVersion() async throws -> String? {
        OpenBoxParser.kernelVersion(try await get("api/openbox/kernel/version"))
    }

    public func proxies() async throws -> [OpenBoxProxy] {
        OpenBoxParser.proxies(try await get("api/controller/proxies"))
    }

    public func groups() async throws -> [OpenBoxProxy] {
        OpenBoxParser.groups(try await get("api/openbox/groups"))
    }

    /// Live connection count through the panel's Clash-API proxy.
    public func connectionCount() async throws -> Int? {
        OpenBoxParser.connectionCount(try await get("api/controller/connections"))
    }

    /// Whether the panel currently considers this session logged in.
    /// Reachable without credentials; used to label the page's panel
    /// state honestly instead of guessing from read failures.
    public func authenticated() async throws -> Bool? {
        OpenBoxParser.authenticated(try await get("api/auth/status"))
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenWrtKitError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw OpenWrtKitError.permissionDenied }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
    }
}

// MARK: - Authenticated data plane (package F+)

extension OpenBoxPanelClient {
    private func url(_ path: String) -> URL {
        URL(string: "\(baseURL.absoluteString)/\(path)")!
    }

    private func queryValue(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// encodeURIComponent-equivalent for one path segment.
    private func segment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// One authenticated request. The panel answers a dead session
    /// with code ACCESS_PASSWORD_REQUIRED (not always with a 401), so
    /// the code is checked on every response, whatever the status.
    private func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        if let code = value.flatMap({ OpenBoxParser.accessCode($0) }),
           code == "ACCESS_PASSWORD_REQUIRED" {
            throw OpenWrtKitError.permissionDenied
        }
        try check(response)
        return value ?? .null
    }

    /// GET /api/auth/status in its full shape.
    public func authState() async throws -> OpenBoxAuthState {
        OpenBoxParser.authState(try await get("api/auth/status"))
    }

    public func subscriptions() async throws -> [OpenBoxSubscription] {
        OpenBoxParser.subscriptions(try await send("GET", "api/openbox/subscriptions"))
    }

    /// POST /api/openbox/subscriptions with the form's JSON object.
    public func createSubscription(name: String, url: String) async throws {
        _ = try await send("POST", "api/openbox/subscriptions",
                           body: .object(["name": .string(name), "url": .string(url)]))
    }

    /// PATCH /api/openbox/subscriptions/<id> with the changed fields.
    public func updateSubscription(id: String, name: String, url: String, enabled: Bool) async throws {
        _ = try await send("PATCH", "api/openbox/subscriptions/\(segment(id))",
                           body: .object(["name": .string(name), "url": .string(url),
                                          "enabled": .bool(enabled)]))
    }

    public func deleteSubscription(id: String) async throws {
        _ = try await send("DELETE", "api/openbox/subscriptions/\(segment(id))")
    }

    public func refreshSubscription(id: String) async throws -> OpenBoxRefreshOutcome {
        OpenBoxParser.refreshOutcome(
            try await send("POST", "api/openbox/subscriptions/\(segment(id))/refresh",
                           body: .object([:])))
    }

    /// GET /api/openbox/traffic/day?day=yyyy-MM-dd&limit=n
    public func trafficDay(day: String, limit: Int = 50) async throws -> OpenBoxTrafficSummary {
        OpenBoxParser.trafficSummary(
            try await send("GET", "api/openbox/traffic/day?day=\(queryValue(day))&limit=\(limit)"))
    }

    /// GET /api/openbox/traffic/month?month=yyyy-MM
    public func trafficMonth(month: String) async throws -> OpenBoxTrafficSummary {
        OpenBoxParser.trafficSummary(
            try await send("GET", "api/openbox/traffic/month?month=\(queryValue(month))"))
    }

    /// GET /api/openbox/traffic/usage — overall totals.
    public func trafficUsage() async throws -> OpenBoxTrafficSummary {
        OpenBoxParser.trafficSummary(try await send("GET", "api/openbox/traffic/usage"))
    }

    /// GET /api/openbox/policies/entries — the routing policy list.
    public func policyEntries() async throws -> [JSONValue] {
        OpenBoxParser.entries(try await send("GET", "api/openbox/policies/entries"))
    }

    /// GET /api/openbox/rulesets/entries?tag=<tag>&offset=0&limit=n —
    /// the panel refuses a request without a tag, so a tag is a
    /// required parameter here, exactly as in the frontend.
    public func rulesetEntries(tag: String, limit: Int = 50) async throws -> [JSONValue] {
        OpenBoxParser.entries(try await send(
            "GET", "api/openbox/rulesets/entries?tag=\(queryValue(tag))&offset=0&limit=\(limit)"))
    }

    /// GET /api/openbox/node-quality — per-node quality as the panel
    /// reports it; unrecognised fields stay in each entry's raw form.
    public func nodeQuality() async throws -> [OpenBoxNodeQuality] {
        OpenBoxParser.nodeQuality(try await send("GET", "api/openbox/node-quality"))
    }

    /// POST /api/openbox/nodes/latency — asks the panel to measure
    /// node latency; results land in node-quality afterwards.
    public func triggerNodeLatency() async throws {
        _ = try await send("POST", "api/openbox/nodes/latency", body: .object([:]))
    }

    // MARK: Session cookie custody
    //
    // The panel session is a cookie in the shared cookie storage.
    // The app persists the cookie pairs in the Keychain (never in
    // files or logs) and hands them back here on the next launch.

    public func sessionCookies() -> [(name: String, value: String)] {
        (HTTPCookieStorage.shared.cookies(for: baseURL) ?? []).map { ($0.name, $0.value) }
    }

    public func restoreSessionCookies(_ cookies: [(name: String, value: String)]) {
        guard let host = baseURL.host else { return }
        for pair in cookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .path: "/", .name: pair.name, .value: pair.value,
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    public func clearSessionCookies() {
        for cookie in HTTPCookieStorage.shared.cookies(for: baseURL) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
