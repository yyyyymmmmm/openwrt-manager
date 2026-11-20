import Foundation

/// One raw reading from the router before rate computation.
public struct RawRealtimeReading: Equatable, Sendable {
    public var load: [Double]
    public var traffic: [DeviceTraffic]
    public var connections: Int?
    public init(load: [Double] = [], traffic: [DeviceTraffic] = [], connections: Int? = nil) {
        self.load = load; self.traffic = traffic; self.connections = connections
    }
}

public struct DeviceRate: Equatable, Sendable {
    public var rxBytesPerSecond: Double
    public var txBytesPerSecond: Double
    public init(rxBytesPerSecond: Double, txBytesPerSecond: Double) {
        self.rxBytesPerSecond = rxBytesPerSecond; self.txBytesPerSecond = txBytesPerSecond
    }
}

/// One plotted point: load, connection count and per-device byte rates,
/// all derived from a single poll so the three realtime charts share one
/// cadence and one freshness clock (spec L3).
public struct RealtimeSample: Equatable, Sendable {
    public var at: Date
    public var load1: Double?
    public var connections: Int?
    public var deviceRates: [String: DeviceRate]
    public var totalRate: DeviceRate? {
        guard !deviceRates.isEmpty else { return nil }
        return DeviceRate(
            rxBytesPerSecond: deviceRates.values.reduce(0) { $0 + $1.rxBytesPerSecond },
            txBytesPerSecond: deviceRates.values.reduce(0) { $0 + $1.txBytesPerSecond })
    }
    public init(at: Date, load1: Double? = nil, connections: Int? = nil, deviceRates: [String: DeviceRate] = [:]) {
        self.at = at; self.load1 = load1; self.connections = connections; self.deviceRates = deviceRates
    }
}

public enum RateCalculator {
    /// Byte rates between two counter snapshots. A counter that went
    /// backwards (interface reset, counter wrap) yields no rate for that
    /// device instead of a negative spike.
    public static func rates(previous: [DeviceTraffic], current: [DeviceTraffic], elapsed: TimeInterval) -> [String: DeviceRate] {
        guard elapsed > 0 else { return [:] }
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.device, $0) })
        var result: [String: DeviceRate] = [:]
        for item in current {
            guard let old = before[item.device] else { continue }
            let rxDelta = item.rxBytes - old.rxBytes
            let txDelta = item.txBytes - old.txBytes
            guard rxDelta >= 0, txDelta >= 0 else { continue }
            result[item.device] = DeviceRate(rxBytesPerSecond: Double(rxDelta) / elapsed,
                                             txBytesPerSecond: Double(txDelta) / elapsed)
        }
        return result
    }
}

/// The single polling engine for the whole app. The fetch closure is
/// supplied by the owner (wired to ReadOnlyDataClient); the engine owns
/// cadence bookkeeping, rate derivation and the bounded sample history.
public actor RealtimeEngine {
    public typealias Fetch = @Sendable () async -> RawRealtimeReading?

    private let fetch: Fetch
    private let capacity: Int
    public private(set) var samples: [RealtimeSample] = []
    private var lastReading: RawRealtimeReading?
    private var lastReadingAt: Date?

    public init(fetch: @escaping Fetch, capacity: Int = 120) {
        self.fetch = fetch
        self.capacity = max(1, capacity)
    }

    public var latest: RealtimeSample? { samples.last }

    /// One poll. A failed fetch (nil) leaves history untouched and reports
    /// nil, so freshness ages honestly instead of freezing on fake data.
    @discardableResult
    public func pollOnce(now: Date = Date()) async -> RealtimeSample? {
        guard let reading = await fetch() else { return nil }
        var rates: [String: DeviceRate] = [:]
        if let previous = lastReading, let previousAt = lastReadingAt {
            rates = RateCalculator.rates(previous: previous.traffic, current: reading.traffic,
                                         elapsed: now.timeIntervalSince(previousAt))
        }
        let sample = RealtimeSample(at: now, load1: reading.load.first,
                                    connections: reading.connections, deviceRates: rates)
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lastReading = reading
        lastReadingAt = now
        return sample
    }

    public func freshness(policy: FreshnessPolicy, now: Date) -> Freshness {
        policy.evaluate(fetchedAt: samples.last?.at, now: now)
    }

    public func reset() {
        samples = []
        lastReading = nil
        lastReadingAt = nil
    }
}
