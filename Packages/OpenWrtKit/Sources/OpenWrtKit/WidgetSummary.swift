import Foundation

/// The status summary the home-screen widget renders (package D).
/// One Codable shape shared by the writer (the app, after each
/// refresh) and the reader (the widget extension, from the App Group
/// store): the widget never opens its own router connection — it
/// renders the last summary the app produced and says how old it is.
public struct RouterStatusSummary: Codable, Equatable, Sendable {
    public var routerName: String
    public var model: String
    public var firmware: String
    public var uptimeSeconds: Double?
    /// 1-minute load average, already normalized per the ubus scale.
    public var loadOneMinute: Double?
    public var memoryUsedFraction: Double?
    public var storageUsedFraction: Double?
    public var connectedDevices: Int
    public var runningServices: Int
    public var totalServices: Int
    public var updatedAt: Date

    public init(routerName: String, model: String, firmware: String,
                uptimeSeconds: Double? = nil, loadOneMinute: Double? = nil,
                memoryUsedFraction: Double? = nil, storageUsedFraction: Double? = nil,
                connectedDevices: Int = 0, runningServices: Int = 0, totalServices: Int = 0,
                updatedAt: Date) {
        self.routerName = routerName
        self.model = model
        self.firmware = firmware
        self.uptimeSeconds = uptimeSeconds
        self.loadOneMinute = loadOneMinute
        self.memoryUsedFraction = memoryUsedFraction
        self.storageUsedFraction = storageUsedFraction
        self.connectedDevices = connectedDevices
        self.runningServices = runningServices
        self.totalServices = totalServices
        self.updatedAt = updatedAt
    }

    /// Builds the summary from the store's already-fetched data —
    /// no new router traffic of any kind.
    public static func build(routerName: String, snapshot: RouterSnapshot,
                             leases: [DHCPLease], services: [RouterService],
                             at date: Date = Date()) -> RouterStatusSummary {
        let system = snapshot.system
        func fraction(_ used: Int64?, _ total: Int64?) -> Double? {
            guard let used, let total, total > 0 else { return nil }
            return min(max(Double(used) / Double(total), 0), 1)
        }
        let running = services.filter { service in
            guard let total = service.totalInstances, total > 0 else { return false }
            return (service.runningInstances ?? 0) > 0
        }.count
        return RouterStatusSummary(
            routerName: routerName,
            model: system.model,
            firmware: system.firmware,
            uptimeSeconds: system.uptime,
            loadOneMinute: system.loadAverage.first,
            memoryUsedFraction: fraction(system.memoryUsed, system.memoryTotal),
            storageUsedFraction: fraction(system.storageUsed, system.storageTotal),
            connectedDevices: leases.count,
            runningServices: running,
            totalServices: services.count,
            updatedAt: date)
    }

    /// The placeholder the widget shows before the app has ever
    /// written a summary (first install, or a different router).
    public static func placeholder(at date: Date = Date()) -> RouterStatusSummary {
        RouterStatusSummary(routerName: "Zirox-openwrt", model: "—", firmware: "—", updatedAt: date)
    }
}

/// The App Group store both processes agree on. The app saves after
/// each refresh; the widget loads when building its timeline. The
/// store is deliberately dumb — freshness judgement ("how old is
/// this summary") belongs to the rendering side, which can see the
/// summary's own timestamp.
public enum RouterStatusSummaryStore {
    public static let appGroupIdentifier = "group.app.openwrtmanager.ios"
    public static let defaultsKey = "router-status-summary.v1"

    public static func save(_ summary: RouterStatusSummary, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func load(from defaults: UserDefaults) -> RouterStatusSummary? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(RouterStatusSummary.self, from: data)
    }
}
