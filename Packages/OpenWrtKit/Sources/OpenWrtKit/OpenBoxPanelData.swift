import Foundation

/// The panel-authenticated data plane (package F+). Every endpoint,
/// method and body shape here was read out of the panel's own shipped
/// frontend code (the assets under /opt/open-box/panel/dist, fetched
/// read-only over HTTP from the running panel on 2026-11-21) — the
/// alignment table lives in briefs/openbox-native-spec.md. Fields the
/// frontend evidence does not pin down are parsed tolerantly and stay
/// optional; nothing is invented.

public struct OpenBoxAuthState: Equatable, Sendable {
    /// Whether the panel has an access password configured at all.
    public var enabled: Bool?
    /// Whether the current session is logged in.
    public var authenticated: Bool?
    public var passwordSet: Bool?
    public init(enabled: Bool? = nil, authenticated: Bool? = nil, passwordSet: Bool? = nil) {
        self.enabled = enabled; self.authenticated = authenticated; self.passwordSet = passwordSet
    }
}

public enum OpenBoxPanelError: Error, Equatable, Sendable {
    /// POST /api/auth/login answered ACCESS_PASSWORD_INVALID.
    case invalidPassword
}

public struct OpenBoxSubscription: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: String?
    public var enabled: Bool?
    public var nodeCount: Int?
    public var updatedAt: String?
    /// The full item as the panel returned it, for the raw-data layer.
    public var raw: JSONValue
    public init(id: String, name: String, url: String? = nil, enabled: Bool? = nil,
                nodeCount: Int? = nil, updatedAt: String? = nil, raw: JSONValue = .null) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled
        self.nodeCount = nodeCount; self.updatedAt = updatedAt; self.raw = raw
    }
}

public struct OpenBoxSkippedNode: Equatable, Sendable {
    public var name: String
    public var reason: String
    public var detail: String?
    public init(name: String, reason: String, detail: String? = nil) {
        self.name = name; self.reason = reason; self.detail = detail
    }
}

/// POST /api/openbox/subscriptions/<id>/refresh — the frontend reads
/// `changed` and a `skipped` list of {name, reason, detail} entries
/// (nodes the refresh dropped as invalid).
public struct OpenBoxRefreshOutcome: Equatable, Sendable {
    public var changed: Bool?
    public var skipped: [OpenBoxSkippedNode]
    public init(changed: Bool? = nil, skipped: [OpenBoxSkippedNode] = []) {
        self.changed = changed; self.skipped = skipped
    }
}

/// One traffic row. The frontend's traffic merge code reads exactly
/// `key`, `up`, `down`, `conns` and sorts by up+down.
public struct OpenBoxTrafficRow: Equatable, Sendable {
    public var key: String
    public var up: Int64
    public var down: Int64
    public var conns: Int?
    public init(key: String, up: Int64, down: Int64, conns: Int? = nil) {
        self.key = key; self.up = up; self.down = down; self.conns = conns
    }
}

public struct OpenBoxTrafficSummary: Equatable, Sendable {
    public var rows: [OpenBoxTrafficRow]
    /// Panel-reported totals when present; nil means "sum the rows".
    public var totalUp: Int64?
    public var totalDown: Int64?
    public var raw: JSONValue
    public init(rows: [OpenBoxTrafficRow] = [], totalUp: Int64? = nil,
                totalDown: Int64? = nil, raw: JSONValue = .null) {
        self.rows = rows; self.totalUp = totalUp; self.totalDown = totalDown; self.raw = raw
    }
    public var displayUp: Int64 { totalUp ?? rows.reduce(0) { $0 + $1.up } }
    public var displayDown: Int64 { totalDown ?? rows.reduce(0) { $0 + $1.down } }
}

/// One node-quality entry. The panel's exact field set varies by
/// build, so only the name is required; score/latency stay optional.
public struct OpenBoxNodeQuality: Equatable, Sendable {
    public var name: String
    public var score: Double?
    public var latencyMilliseconds: Double?
    public var raw: JSONValue
    public init(name: String, score: Double? = nil, latencyMilliseconds: Double? = nil,
                raw: JSONValue = .null) {
        self.name = name; self.score = score
        self.latencyMilliseconds = latencyMilliseconds; self.raw = raw
    }
}

extension OpenBoxParser {
    /// The panel's machine-readable error code, present on auth
    /// failures: ACCESS_PASSWORD_REQUIRED (no session) and
    /// ACCESS_PASSWORD_INVALID (wrong password at login).
    public static func accessCode(_ value: JSONValue) -> String? {
        value["code"].stringValue
    }

    /// GET /api/auth/status — {enabled, authenticated, passwordSet}.
    public static func authState(_ value: JSONValue) -> OpenBoxAuthState {
        OpenBoxAuthState(enabled: value["enabled"].boolValue,
                         authenticated: authenticated(value),
                         passwordSet: value["passwordSet"].boolValue ?? value["password_set"].boolValue)
    }

    /// GET /api/openbox/subscriptions — the frontend unwraps the
    /// `subscriptions` array from the response envelope.
    public static func subscriptions(_ value: JSONValue) -> [OpenBoxSubscription] {
        let items = value["subscriptions"].arrayValue ?? value["data"].arrayValue
            ?? value.arrayValue ?? []
        return items.compactMap { item in
            guard let id = item["id"].textValue else { return nil }
            let url = item["url"].stringValue
            let name = item["name"].stringValue ?? url ?? id
            let nodeCount = item["nodeCount"].intValue ?? item["nodesCount"].intValue
                ?? item["nodes"].arrayValue?.count ?? item["proxies"].arrayValue?.count
            let updatedAt = item["updatedAt"].textValue ?? item["lastUpdated"].textValue
                ?? item["syncedAt"].textValue ?? item["updateTime"].textValue
                ?? item["lastUpdate"].textValue
            return OpenBoxSubscription(
                id: id, name: name, url: url,
                enabled: item["enabled"].boolValue ?? item["enable"].boolValue,
                nodeCount: nodeCount, updatedAt: updatedAt, raw: item)
        }
    }

    public static func refreshOutcome(_ value: JSONValue) -> OpenBoxRefreshOutcome {
        let skipped = (value["skipped"].arrayValue ?? [JSONValue]()).compactMap { entry -> OpenBoxSkippedNode? in
            guard let name = entry["name"].stringValue else { return nil }
            return OpenBoxSkippedNode(name: name,
                                      reason: entry["reason"].stringValue ?? "",
                                      detail: entry["detail"].stringValue)
        }
        return OpenBoxRefreshOutcome(changed: value["changed"].boolValue, skipped: skipped)
    }

    /// GET /api/openbox/traffic/day|month|usage — rows of
    /// {key, up, down, conns}; totals ride along on some builds.
    public static func trafficSummary(_ value: JSONValue) -> OpenBoxTrafficSummary {
        let rawRows = value["rows"].arrayValue ?? value["items"].arrayValue
            ?? value["data"].arrayValue ?? value.arrayValue ?? []
        let rows = rawRows.compactMap { row -> OpenBoxTrafficRow? in
            guard let key = row["key"].textValue ?? row["name"].textValue
                    ?? row["host"].textValue ?? row["client"].textValue else { return nil }
            return OpenBoxTrafficRow(
                key: key,
                up: row["up"].intValue.map(Int64.init) ?? Int64(row["upload"].intValue ?? 0),
                down: row["down"].intValue.map(Int64.init) ?? Int64(row["download"].intValue ?? 0),
                conns: row["conns"].intValue ?? row["connections"].intValue)
        }.sorted { $0.up + $0.down > $1.up + $1.down }
        let total = value["total"]
        return OpenBoxTrafficSummary(
            rows: rows,
            totalUp: total["up"].intValue.map(Int64.init) ?? value["totalUp"].intValue.map(Int64.init),
            totalDown: total["down"].intValue.map(Int64.init) ?? value["totalDown"].intValue.map(Int64.init),
            raw: value)
    }

    /// Shared shape for /api/openbox/policies/entries and
    /// /api/openbox/rulesets/entries: an entry list under one of the
    /// known envelope keys, or a bare array.
    public static func entries(_ value: JSONValue) -> [JSONValue] {
        for key in ["entries", "policies", "rules", "items", "data"] {
            if let list = value[key].arrayValue { return list }
        }
        return value.arrayValue ?? []
    }

    /// GET /api/openbox/node-quality — per-node quality entries.
    public static func nodeQuality(_ value: JSONValue) -> [OpenBoxNodeQuality] {
        let items = value["nodes"].arrayValue ?? value["items"].arrayValue
            ?? value["data"].arrayValue ?? value.arrayValue ?? []
        return items.compactMap { item in
            guard let name = item["name"].textValue ?? item["node"].textValue
                    ?? item["tag"].textValue else { return nil }
            return OpenBoxNodeQuality(
                name: name,
                score: item["score"].doubleValue ?? item["quality"].doubleValue,
                latencyMilliseconds: item["latency"].doubleValue ?? item["delay"].doubleValue
                    ?? item["latencyMs"].doubleValue,
                raw: item)
        }
    }

    /// A human title for a policy/ruleset entry: the first string the
    /// entry carries under a well-known key. Display-only; the raw
    /// entry stays available underneath.
    public static func entryTitle(_ entry: JSONValue) -> String? {
        for key in ["name", "payload", "domain", "ip", "value", "key", "match", "type"] {
            if let text = entry[key].stringValue, !text.isEmpty { return text }
        }
        return entry.stringValue
    }
}
