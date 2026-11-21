import Foundation

/// Whether a displayed value may be presented as current. Spec L3: stale
/// data must be labelled, never passed off as live.
public enum Freshness: Equatable, Sendable {
    /// Nothing has ever been fetched.
    case missing
    /// Fetched recently enough to be shown as current.
    case live
    /// A value exists but is older than the policy allows; it may only be
    /// shown with an explicit stale marker.
    case stale(age: TimeInterval)

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

public struct FreshnessPolicy: Equatable, Sendable {
    /// Age after which a value counts as stale. Callers pass a multiple of
    /// their refresh interval (the app uses 2.5x the poll cadence).
    public var staleAfter: TimeInterval

    public init(staleAfter: TimeInterval) {
        self.staleAfter = staleAfter
    }

    public func evaluate(fetchedAt: Date?, now: Date) -> Freshness {
        guard let fetchedAt else { return .missing }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return .live }
        return age <= staleAfter ? .live : .stale(age: age)
    }
}

/// A value plus the moment it was read from the router. UI layers carry
/// this (not bare values) so freshness survives hand-offs between screens.
public struct TimedValue<Value: Sendable>: Sendable {
    public var value: Value
    public var fetchedAt: Date

    public init(value: Value, fetchedAt: Date) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public func freshness(policy: FreshnessPolicy, now: Date) -> Freshness {
        policy.evaluate(fetchedAt: fetchedAt, now: now)
    }
}
