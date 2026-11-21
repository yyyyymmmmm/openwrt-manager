import Foundation

// MARK: - Metric history (package B, item 1)
//
// The sampling store behind the history charts. Samples are taken by
// the app from its existing read channels only (the realtime poll and
// the overview refresh) — nothing new is asked of the router. The
// store is deliberately honest about absence: a stretch with no
// samples stays a gap. Chart series are built per segment so a line
// is never interpolated across an outage or across the hours the app
// was closed.

public struct MetricSample: Codable, Equatable, Sendable {
    public var at: Date
    public var rxBytesPerSecond: Double?
    public var txBytesPerSecond: Double?
    /// 1-minute load average — the load figure OpenWrt's ubus system
    /// info actually reports (there is no CPU-percent channel).
    public var load1: Double?
    public var memoryPercent: Double?
    public var connections: Int?
    public var onlineDevices: Int?
    public init(at: Date, rxBytesPerSecond: Double? = nil, txBytesPerSecond: Double? = nil,
                load1: Double? = nil, memoryPercent: Double? = nil,
                connections: Int? = nil, onlineDevices: Int? = nil) {
        self.at = at; self.rxBytesPerSecond = rxBytesPerSecond
        self.txBytesPerSecond = txBytesPerSecond; self.load1 = load1
        self.memoryPercent = memoryPercent; self.connections = connections
        self.onlineDevices = onlineDevices
    }
}

public enum MetricKey: String, CaseIterable, Sendable {
    case trafficDown, trafficUp, load, memory, connections, devices

    public func value(in sample: MetricSample) -> Double? {
        switch self {
        case .trafficDown: return sample.rxBytesPerSecond
        case .trafficUp: return sample.txBytesPerSecond
        case .load: return sample.load1
        case .memory: return sample.memoryPercent
        case .connections: return sample.connections.map(Double.init)
        case .devices: return sample.onlineDevices.map(Double.init)
        }
    }
}

public struct MetricChartPoint: Equatable, Sendable {
    public var at: Date
    public var value: Double
    public init(at: Date, value: Double) { self.at = at; self.value = value }
}

public struct MetricHistory: Codable, Equatable, Sendable {
    public private(set) var samples: [MetricSample] = []
    /// Kept history: one week. At the app's 60-second sampling cadence
    /// that is 10,080 samples; the count cap only bites if a future
    /// cadence change makes the week denser than the cap.
    public var retention: TimeInterval = 7 * 24 * 3600
    public var capacity: Int = 12_000

    public init() {}

    public mutating func append(_ sample: MetricSample) {
        samples.append(sample)
        samples.sort { $0.at < $1.at }
        let cutoff = sample.at.addingTimeInterval(-retention)
        samples.removeAll { $0.at < cutoff }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public func samples(in range: ClosedRange<Date>) -> [MetricSample] {
        samples.filter { range.contains($0.at) }
    }

    /// Chart series for one metric over a range, as separate segments:
    /// wherever the distance between neighbouring samples exceeds
    /// `gapThreshold` the series breaks, so the chart renders a blank
    /// instead of a fabricated bridge. Within a segment, samples are
    /// averaged into time buckets of `bucketSeconds` (<= 0 keeps raw
    /// points); bucketing never crosses a segment boundary.
    public func chartSegments(metric: MetricKey, in range: ClosedRange<Date>,
                              gapThreshold: TimeInterval = 240,
                              bucketSeconds: TimeInterval = 0) -> [[MetricChartPoint]] {
        let points = samples(in: range).compactMap { sample -> MetricChartPoint? in
            metric.value(in: sample).map { MetricChartPoint(at: sample.at, value: $0) }
        }
        var segments: [[MetricChartPoint]] = []
        var current: [MetricChartPoint] = []
        for point in points {
            if let last = current.last, point.at.timeIntervalSince(last.at) > gapThreshold {
                segments.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }
        guard bucketSeconds > 0 else { return segments }
        return segments.map { segment in
            var buckets: [Int: (sum: Double, count: Int, at: Date)] = [:]
            for point in segment {
                let key = Int(point.at.timeIntervalSince1970 / bucketSeconds)
                var bucket = buckets[key] ?? (0, 0, point.at)
                bucket.sum += point.value; bucket.count += 1
                buckets[key] = bucket
            }
            return buckets.keys.sorted().map { key in
                let bucket = buckets[key]!
                return MetricChartPoint(at: bucket.at, value: bucket.sum / Double(bucket.count))
            }
        }
    }

    /// True when the range contains at least one internal gap — the UI
    /// captions the chart so the blanks are explained, not mysterious.
    public func hasGap(metric: MetricKey, in range: ClosedRange<Date>,
                       gapThreshold: TimeInterval = 240) -> Bool {
        chartSegments(metric: metric, in: range, gapThreshold: gapThreshold).count > 1
    }
}

// MARK: - Alerting (package B, item 2)
//
// A deterministic rule engine: observations in, transitions out. All
// timing is injected through the observations, so the behaviour —
// sustained thresholds, two-strike offline detection, per-rule
// cooldown, fired/resolved pairing — is unit-testable without a
// clock. The app owns delivery (local notifications, event log,
// diagnostics); the engine owns judgement.

public struct AlertSettings: Codable, Equatable, Sendable {
    public var offlineEnabled = true
    public var wanEnabled = true
    public var loadEnabled = true
    public var memoryEnabled = true
    public var newDeviceEnabled = true
    /// 1-minute load average above which the load rule arms.
    public var loadThreshold: Double = 2.0
    /// Memory usage percent above which the memory rule arms.
    public var memoryThreshold: Double = 90
    /// How long a threshold must be exceeded before it fires.
    public var sustain: TimeInterval = 300
    /// Minimum quiet period before the same rule may fire again.
    public var cooldown: TimeInterval = 1800
    public init() {}
}

public struct AlertObservation: Equatable, Sendable {
    public var at: Date
    public var reachable: Bool
    public var wanUp: Bool?
    public var load1: Double?
    public var memoryPercent: Double?
    /// Stable device identities (lease MACs) currently seen, when the
    /// caller could read them; nil means "unknown", never "none".
    public var deviceIDs: Set<String>?
    public init(at: Date, reachable: Bool, wanUp: Bool? = nil, load1: Double? = nil,
                memoryPercent: Double? = nil, deviceIDs: Set<String>? = nil) {
        self.at = at; self.reachable = reachable; self.wanUp = wanUp
        self.load1 = load1; self.memoryPercent = memoryPercent; self.deviceIDs = deviceIDs
    }
}

public enum AlertKind: String, Codable, CaseIterable, Sendable {
    case routerOffline, wanDown, loadHigh, memoryHigh, newDevice
}

public struct AlertTransition: Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case fired, resolved }
    public var kind: AlertKind
    public var phase: Phase
    public var at: Date
    /// The measured value for threshold rules (load average / percent).
    public var value: Double?
    /// Identities first seen, for the new-device rule.
    public var newDeviceIDs: [String]
    public init(kind: AlertKind, phase: Phase, at: Date,
                value: Double? = nil, newDeviceIDs: [String] = []) {
        self.kind = kind; self.phase = phase; self.at = at
        self.value = value; self.newDeviceIDs = newDeviceIDs
    }
}

public struct AlertEngine: Codable, Equatable, Sendable {
    private struct RuleState: Codable, Equatable, Sendable {
        var active = false
        /// Whether the firing was actually delivered; a firing eaten
        /// by the cooldown still marks the rule active so the later
        /// recovery is not reported as a pair for an alert the user
        /// never saw — the recovery is only emitted when notified.
        var notified = false
        var lastFiredAt: Date?
        var strikes = 0
        var exceededSince: Date?
    }

    private var offline = RuleState()
    private var wan = RuleState()
    private var load = RuleState()
    private var memory = RuleState()
    private var newDevice = RuleState()
    private var knownDevices: Set<String>?

    public init() {}

    public mutating func evaluate(settings: AlertSettings,
                                  observation: AlertObservation) -> [AlertTransition] {
        var transitions: [AlertTransition] = []
        evaluateOffline(settings: settings, observation: observation, into: &transitions)
        evaluateWAN(settings: settings, observation: observation, into: &transitions)
        Self.evaluateThreshold(settings: settings, observation: observation,
                          kind: .loadHigh, enabled: settings.loadEnabled,
                          value: observation.load1, threshold: settings.loadThreshold,
                          state: &load, into: &transitions)
        Self.evaluateThreshold(settings: settings, observation: observation,
                          kind: .memoryHigh, enabled: settings.memoryEnabled,
                          value: observation.memoryPercent, threshold: settings.memoryThreshold,
                          state: &memory, into: &transitions)
        evaluateNewDevices(settings: settings, observation: observation, into: &transitions)
        return transitions
    }

    private static func cooldownPassed(_ state: RuleState, at: Date, settings: AlertSettings) -> Bool {
        guard let last = state.lastFiredAt else { return true }
        return at.timeIntervalSince(last) >= settings.cooldown
    }

    private static func fire(kind: AlertKind, state: inout RuleState,
                               observation: AlertObservation, settings: AlertSettings,
                               value: Double? = nil, newDeviceIDs: [String] = [],
                               into transitions: inout [AlertTransition]) {
        state.active = true
        if Self.cooldownPassed(state, at: observation.at, settings: settings) {
            state.notified = true
            state.lastFiredAt = observation.at
            transitions.append(AlertTransition(kind: kind, phase: .fired, at: observation.at,
                                               value: value, newDeviceIDs: newDeviceIDs))
        }
    }

    private static func resolve(kind: AlertKind, state: inout RuleState,
                                  observation: AlertObservation,
                                  into transitions: inout [AlertTransition]) {
        if state.active && state.notified {
            transitions.append(AlertTransition(kind: kind, phase: .resolved, at: observation.at))
        }
        state.active = false
        state.notified = false
        state.strikes = 0
        state.exceededSince = nil
    }

    private mutating func evaluateOffline(settings: AlertSettings,
                                          observation: AlertObservation,
                                          into transitions: inout [AlertTransition]) {
        guard settings.offlineEnabled else { offline = RuleState(); return }
        if observation.reachable {
            if offline.active { Self.resolve(kind: .routerOffline, state: &offline, observation: observation, into: &transitions) }
            offline.strikes = 0
        } else {
            offline.strikes += 1
            // Two consecutive unreachable observations: a single failed
            // poll (a busy router, a Wi-Fi roam) must not cry wolf.
            if offline.strikes >= 2 && !offline.active {
                Self.fire(kind: .routerOffline, state: &offline, observation: observation,
                     settings: settings, into: &transitions)
            }
        }
    }

    private mutating func evaluateWAN(settings: AlertSettings,
                                      observation: AlertObservation,
                                      into transitions: inout [AlertTransition]) {
        guard settings.wanEnabled else { wan = RuleState(); return }
        guard let wanUp = observation.wanUp else { return }
        if wanUp {
            if wan.active { Self.resolve(kind: .wanDown, state: &wan, observation: observation, into: &transitions) }
            wan.strikes = 0
        } else {
            wan.strikes += 1
            if wan.strikes >= 2 && !wan.active {
                Self.fire(kind: .wanDown, state: &wan, observation: observation,
                     settings: settings, into: &transitions)
            }
        }
    }

    private static func evaluateThreshold(settings: AlertSettings,
                                            observation: AlertObservation,
                                            kind: AlertKind, enabled: Bool,
                                            value: Double?, threshold: Double,
                                            state: inout RuleState,
                                            into transitions: inout [AlertTransition]) {
        guard enabled else { state = RuleState(); return }
        guard let value else { return }
        if value > threshold {
            if state.exceededSince == nil { state.exceededSince = observation.at }
            if !state.active,
               let since = state.exceededSince,
               observation.at.timeIntervalSince(since) >= settings.sustain {
                Self.fire(kind: kind, state: &state, observation: observation,
                     settings: settings, value: value, into: &transitions)
            }
        } else {
            if state.active { Self.resolve(kind: kind, state: &state, observation: observation, into: &transitions) }
            state.exceededSince = nil
        }
    }

    private mutating func evaluateNewDevices(settings: AlertSettings,
                                             observation: AlertObservation,
                                             into transitions: inout [AlertTransition]) {
        guard let deviceIDs = observation.deviceIDs else { return }
        guard let known = knownDevices else {
            // First sight establishes the baseline silently — the
            // devices already on the network when monitoring starts
            // are not "new".
            knownDevices = deviceIDs
            return
        }
        let fresh = deviceIDs.subtracting(known)
        knownDevices = deviceIDs
        guard settings.newDeviceEnabled, !fresh.isEmpty else { return }
        if Self.cooldownPassed(newDevice, at: observation.at, settings: settings) {
            newDevice.lastFiredAt = observation.at
            transitions.append(AlertTransition(kind: .newDevice, phase: .fired, at: observation.at,
                                               newDeviceIDs: fresh.sorted()))
        }
    }
}

// MARK: - Event log (package B storage, package C surface)
//
// One local record for everything the user may later want to review:
// operations performed in the app and alerts that fired or resolved.
// Package C builds the full records UI on this model; package B only
// guarantees the store exists and is written.

public struct StoredEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Category: String, Codable, Sendable { case operation, alert, system }
    /// The filter dimension of the records surface (package C):
    /// what sort of thing happened, independent of the coarser
    /// category. Events written before kinds existed decode with a
    /// kind derived from their category, so old logs stay filterable.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case configuration, quickAction, operation, alert, backupRestore, login, system
    }
    public var id: String
    public var at: Date
    public var category: Category
    public var kind: Kind
    public var title: String
    public var detail: String
    public var routerID: String?
    public init(id: String = UUID().uuidString, at: Date, category: Category,
                kind: Kind? = nil, title: String, detail: String, routerID: String? = nil) {
        self.id = id; self.at = at; self.category = category
        self.kind = kind ?? Self.derivedKind(for: category)
        self.title = title; self.detail = detail; self.routerID = routerID
    }

    public static func derivedKind(for category: Category) -> Kind {
        switch category {
        case .alert: return .alert
        case .operation: return .operation
        case .system: return .system
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, category, kind, title, detail, routerID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Date.self, forKey: .at)
        category = try container.decode(Category.self, forKey: .category)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? Self.derivedKind(for: category)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        routerID = try container.decodeIfPresent(String.self, forKey: .routerID)
    }
}

public struct EventLog: Codable, Equatable, Sendable {
    public private(set) var events: [StoredEvent] = []
    public var capacity: Int = 1000
    public init() {}

    public mutating func append(_ event: StoredEvent) {
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    /// Newest first, optionally scoped to one router (plus global
    /// events, which carry no router id) and/or to one kind.
    public func recent(limit: Int = 200, routerID: String? = nil, kind: StoredEvent.Kind? = nil) -> [StoredEvent] {
        var scoped = events
        if routerID != nil { scoped = scoped.filter { $0.routerID == nil || $0.routerID == routerID } }
        if let kind { scoped = scoped.filter { $0.kind == kind } }
        return Array(scoped.suffix(limit).reversed())
    }
}

// MARK: - OpenWrt fingerprinting (package B, item 4)
//
// Discovery must answer "is this OpenWrt?" before an address is
// offered as a router candidate. Two unauthenticated signals, in
// order of strength: the LuCI login page (its markup references the
// luci application paths) and the anonymous ubus `system board` call
// some builds answer. Model/firmware are reported only when the
// board call actually returned them — never guessed.

public enum OpenWrtFingerprint {
    public struct BoardInfo: Equatable, Sendable {
        public var model: String?
        public var firmware: String?
        public var hostname: String?
        public init(model: String? = nil, firmware: String? = nil, hostname: String? = nil) {
            self.model = model; self.firmware = firmware; self.hostname = hostname
        }
    }

    public static func looksLikeLuCI(html: String) -> Bool {
        let text = html.lowercased()
        if text.contains("cgi-bin/luci") || text.contains("luci-static") { return true }
        return text.contains("luci") && text.contains("openwrt")
    }

    /// Parses a ubus JSON-RPC response to `system board`:
    /// {"result": [0, {model: ..., release: {description: ...}}]}.
    /// A bare board object (no envelope) is accepted too.
    public static func boardInfo(from data: Data) -> BoardInfo? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return boardInfo(from: value)
    }

    public static func boardInfo(from value: JSONValue) -> BoardInfo? {
        var board = value
        if let result = value["result"].arrayValue {
            guard result.count >= 2 else { return nil }
            board = result[1]
        }
        guard board.objectValue != nil else { return nil }
        let release = board["release"]
        let firmware = release["description"].stringValue
            ?? release["version"].stringValue.map { "OpenWrt \($0)" }
        let info = BoardInfo(model: board["model"].stringValue,
                             firmware: firmware,
                             hostname: board["hostname"].stringValue)
        return (info.model != nil || info.firmware != nil || info.hostname != nil) ? info : nil
    }
}

/// The restrained candidate list for LAN discovery: the addresses a
/// home router actually sits at inside the phone's own /24 — gateway
/// first (.1, then .254), then the next couple of low addresses.
/// Deliberately NOT a subnet sweep.
public enum DiscoveryCandidates {
    public static func hosts(phoneIP: String, netmask: String) -> [String] {
        guard let ip = ipv4(phoneIP), let mask = ipv4(netmask) else { return [] }
        // Bound the search to the phone's /24 whatever the real mask
        // says — the same restraint the port scanner already used.
        let boundedMask = mask | 0xFFFFFF00
        let network = ip & boundedMask
        let broadcast = network | ~boundedMask
        guard broadcast > network + 1 else { return [] }
        var seen = Set<UInt32>()
        var hosts: [String] = []
        for candidate in [network + 1, broadcast - 1, network + 2, network + 3] {
            guard candidate > network, candidate < broadcast,
                  candidate != ip, seen.insert(candidate).inserted else { continue }
            hosts.append(dotted(candidate))
        }
        return hosts
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return parts.reduce(0) { ($0 << 8) | $1 }
    }

    private static func dotted(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }
}
