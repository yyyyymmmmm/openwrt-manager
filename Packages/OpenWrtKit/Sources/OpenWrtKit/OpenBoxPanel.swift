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
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["password": password])
        let (_, response) = try await session.data(for: request)
        try check(response)
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

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OpenWrtKitError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw OpenWrtKitError.permissionDenied }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
    }
}
