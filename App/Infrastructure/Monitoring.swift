import Foundation
import Observation
import UserNotifications
import BackgroundTasks
import OpenWrtKit

// MARK: - Local file locations

/// Application Support/ZiroxOpenWrt — where package B's local stores
/// live (metric history per router, the shared event log). Created on
/// first use; failures degrade to in-memory-only rather than crashing
/// a monitoring path.
enum MonitoringFiles {
    static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("ZiroxOpenWrt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Event log store (package B storage; package C builds the full UI)

@MainActor @Observable
final class EventLogStore {
    static let shared = EventLogStore()

    private(set) var log = EventLog()
    @ObservationIgnored private let fileURL: URL?

    init() {
        fileURL = MonitoringFiles.directory()?.appendingPathComponent("events.json")
        if let saved: EventLog = MonitoringFiles.load(EventLog.self, from: fileURL) {
            log = saved
        }
    }

    /// Every recorded event also lands in the diagnostic buffer
    /// (package A), so an exported diagnostics file covers operations
    /// and alerts as well as connections and transactions.
    func append(category: StoredEvent.Category, title: String, detail: String,
                routerID: String? = nil, at: Date = Date()) {
        log.append(StoredEvent(at: at, category: category, title: title,
                               detail: detail, routerID: routerID))
        MonitoringFiles.save(log, to: fileURL)
        AppDiagnostics.record(category == .alert ? .error : .app, title,
                              metadata: ["detail": detail])
    }
}

// MARK: - Metric history file store

/// Thread-safe: the foreground monitoring loop and the background
/// refresh task both append, never concurrently by design but never
/// trustingly either.
final class MetricHistoryFileStore: @unchecked Sendable {
    static let shared = MetricHistoryFileStore()

    private let lock = NSLock()
    private var cache: [String: MetricHistory] = [:]

    func history(routerID: String) -> MetricHistory {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[routerID] { return cached }
        let loaded: MetricHistory = MonitoringFiles.load(
            MetricHistory.self, from: fileURL(routerID: routerID)) ?? MetricHistory()
        cache[routerID] = loaded
        return loaded
    }

    func append(_ sample: MetricSample, routerID: String) {
        lock.lock(); defer { lock.unlock() }
        var history = cache[routerID] ?? MonitoringFiles.load(
            MetricHistory.self, from: fileURL(routerID: routerID)) ?? MetricHistory()
        history.append(sample)
        cache[routerID] = history
        MonitoringFiles.save(history, to: fileURL(routerID: routerID))
    }

    private func fileURL(routerID: String) -> URL? {
        MonitoringFiles.directory()?.appendingPathComponent("metrics-\(routerID).json")
    }
}

// MARK: - Alert centre

/// Owns the rule settings, one persisted AlertEngine per router, and
/// delivery: a transition becomes an event-log entry, a diagnostics
/// record, and — when the user granted permission — a local
/// notification. The engine (kit) decides; this class only delivers.
@MainActor @Observable
final class AlertCenter {
    var settings = AlertSettings() {
        didSet { MonitoringFiles.save(settings, to: settingsURL) }
    }
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let settingsURL: URL?
    @ObservationIgnored private var engines: [String: AlertEngine] = [:]
    private let engineKeyPrefix = "alert-engine.v1."

    init() {
        settingsURL = MonitoringFiles.directory()?.appendingPathComponent("alert-settings.json")
        if let saved: AlertSettings = MonitoringFiles.load(AlertSettings.self, from: settingsURL) {
            // Assign without re-saving through didSet during init.
            settings = saved
        }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The standard system flow: the settings page calls this the
    /// first time it appears while permission is undecided.
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func evaluate(observation: AlertObservation, routerID: String, routerName: String) {
        var engine = engines[routerID] ?? loadEngine(routerID: routerID)
        let transitions = engine.evaluate(settings: settings, observation: observation)
        engines[routerID] = engine
        if let data = try? JSONEncoder().encode(engine) {
            defaults.set(data, forKey: engineKeyPrefix + routerID)
        }
        for transition in transitions {
            deliver(transition, routerID: routerID, routerName: routerName)
        }
    }

    private func loadEngine(routerID: String) -> AlertEngine {
        guard let data = defaults.data(forKey: engineKeyPrefix + routerID),
              let engine = try? JSONDecoder().decode(AlertEngine.self, from: data) else {
            return AlertEngine()
        }
        return engine
    }

    private func deliver(_ transition: AlertTransition, routerID: String, routerName: String) {
        let text = Self.text(for: transition)
        EventLogStore.shared.append(category: .alert, title: text.title, detail: text.detail,
                                    routerID: routerID, at: transition.at)
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.detail.isEmpty ? routerName : "\(routerName)：\(text.detail)"
        content.sound = .default
        content.threadIdentifier = "router-\(routerID)"
        let request = UNNotificationRequest(
            identifier: "alert-\(transition.kind.rawValue)-\(routerID)-\(Int(transition.at.timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// User-facing wording for a transition. Device identities and
    /// router data ride as values, never as copy.
    static func text(for transition: AlertTransition) -> (title: String, detail: String) {
        switch (transition.kind, transition.phase) {
        case (.routerOffline, .fired):
            return (L10n.string("路由器离线"), L10n.string("连续两次无法读取路由器状态，可能已断电、重启或网络中断。"))
        case (.routerOffline, .resolved):
            return (L10n.string("路由器已恢复"), L10n.string("路由器重新可达。"))
        case (.wanDown, .fired):
            return (L10n.string("WAN 已断开"), L10n.string("上游接口报告未连接，外网可能不可用。"))
        case (.wanDown, .resolved):
            return (L10n.string("WAN 已恢复"), L10n.string("上游接口重新连接。"))
        case (.loadHigh, .fired):
            return (L10n.string("系统负载过高"),
                    L10n.format("1 分钟负载平均值 %.2f，持续超过阈值。", transition.value ?? 0))
        case (.loadHigh, .resolved):
            return (L10n.string("系统负载已回落"), L10n.string("负载恢复到阈值以内。"))
        case (.memoryHigh, .fired):
            return (L10n.string("内存占用过高"),
                    L10n.format("内存占用 %.0f%%，持续超过阈值。", transition.value ?? 0))
        case (.memoryHigh, .resolved):
            return (L10n.string("内存占用已回落"), L10n.string("内存恢复到阈值以内。"))
        case (.newDevice, _):
            return (L10n.string("新设备接入"),
                    L10n.format("新设备：%@", transition.newDeviceIDs.joined(separator: "、")))
        }
    }
}

// MARK: - Foreground monitoring loop

/// Samples the connected router into the metric history and feeds
/// the alert engine. It reads only what RouterStore already fetched
/// (the realtime poll and the overview refresh) — no extra router
/// traffic. Cadence: a 30-second tick, a sample at most every 45
/// seconds, so the 10-second realtime poll is not duplicated into
/// storage at full rate.
@MainActor @Observable
final class MonitoringService {
    let alerts = AlertCenter()
    private(set) var history = MetricHistory()
    private(set) var activeRouterID: String?

    @ObservationIgnored private let historyStore = MetricHistoryFileStore.shared
    @ObservationIgnored private var lastSampleAt: Date?

    /// Runs for the lifetime of one connection (RootView drives it
    /// with .task(id: connectionID)).
    func run(store: RouterStore) async {
        guard let profile = store.activeProfile else { return }
        let routerID = profile.id.uuidString
        activeRouterID = routerID
        history = historyStore.history(routerID: routerID)
        await alerts.refreshAuthorization()
        AppDiagnostics.record(.app, L10n.string("监控已启动"),
                              metadata: ["router": profile.address])
        while !Task.isCancelled, store.activeProfile?.id == profile.id {
            tick(store: store, profile: profile, routerID: routerID)
            try? await Task.sleep(for: .seconds(30))
        }
        AppDiagnostics.record(.app, L10n.string("监控已停止"),
                              metadata: ["router": profile.address])
    }

    private func tick(store: RouterStore, profile: RouterProfile, routerID: String) {
        let now = Date()
        let lastContact = max(store.overviewUpdatedAt ?? .distantPast,
                              store.realtimeUpdatedAt ?? .distantPast)
        let reachable = now.timeIntervalSince(lastContact) < 120

        let realtimeFresh = store.realtimeUpdatedAt.map { now.timeIntervalSince($0) < 120 } ?? false
        let realtime = realtimeFresh ? store.realtimeSamples.last : nil
        let system = store.snapshot?.system
        let memoryPercent: Double? = {
            guard let used = system?.memoryUsed, let total = system?.memoryTotal, total > 0 else { return nil }
            return Double(used) / Double(total) * 100
        }()
        let wanUp: Bool? = {
            guard let upstream = store.capability?.upstream else { return nil }
            return store.snapshot?.interfaces.first { $0.name == upstream.interfaceName }?.up
        }()

        if lastSampleAt.map({ now.timeIntervalSince($0) >= 45 }) ?? true {
            let sample = MetricSample(
                at: now,
                rxBytesPerSecond: realtime?.totalRate?.rxBytesPerSecond,
                txBytesPerSecond: realtime?.totalRate?.txBytesPerSecond,
                load1: realtime?.load1 ?? system?.loadAverage.first,
                memoryPercent: memoryPercent,
                connections: realtime?.connections,
                onlineDevices: store.devicesUpdatedAt == nil ? nil : store.leases.count)
            // An all-empty sample carries no information; skipping it
            // is what makes offline stretches show up as chart gaps.
            if sample.rxBytesPerSecond != nil || sample.txBytesPerSecond != nil
                || sample.load1 != nil || sample.memoryPercent != nil
                || sample.connections != nil || sample.onlineDevices != nil {
                historyStore.append(sample, routerID: routerID)
                history = historyStore.history(routerID: routerID)
                lastSampleAt = now
            }
        }

        let observation = AlertObservation(
            at: now, reachable: reachable, wanUp: wanUp,
            load1: system?.loadAverage.first, memoryPercent: memoryPercent,
            deviceIDs: store.devicesUpdatedAt == nil ? nil : Set(store.leases.map(\.mac)))
        alerts.evaluate(observation: observation, routerID: routerID, routerName: profile.name)
    }
}

// MARK: - Background sampling (best effort, system-scheduled)

/// BGAppRefreshTask handler: one lightweight sample for the default
/// router, using only a remembered Keychain password. iOS decides
/// whether and when this runs at all — the alert settings page says
/// so in plain words; nothing here pretends otherwise.
enum BackgroundSampler {
    static let taskIdentifier = "app.openwrtmanager.ios.monitoring-refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            await sampleOnce()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Mirrors RouterStore's persistence keys; the store remains the
    /// writer, this is a read-only consumer for the background pass.
    private static func sampleOnce() async {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "router-profiles.v1"),
              let profiles = try? JSONDecoder().decode([RouterProfile].self, from: data),
              let defaultID = defaults.string(forKey: "default-router-profile.v1"),
              let profile = profiles.first(where: { $0.id.uuidString == defaultID }),
              let credential = try? CredentialStore().read(id: profile.id),
              let password = credential?.password,
              let address = try? URLNormalizer.normalize(profile.address) else { return }
        let routerID = profile.id.uuidString
        let transport = RouterTransport(address: address,
                                        fingerprint: credential?.certificateFingerprint)
        defer { transport.close() }
        let client = UbusClient(address: address, session: transport.session)
        let box = StaticCredentialBox(username: profile.username, password: password)
        let manager = SessionManager(client: client, credentialProvider: box)
        let reader = ReadOnlyDataClient(caller: manager)
        let now = Date()
        do {
            let info = try await reader.systemInfo()
            let leases = try? await reader.leases()
            let memory = info["memory"].objectValue
            let total = memory?["total"]?.intValue
            // Same definition as the overview: used = total - available
            // (free is the fallback when available is not reported).
            let available = memory?["available"]?.intValue ?? memory?["free"]?.intValue
            let memoryPercent: Double? = {
                guard let total, let available, total > 0 else { return nil }
                return Double(max(0, total - available)) / Double(total) * 100
            }()
            let load = (info["load"].arrayValue ?? []).compactMap { $0.doubleValue.map { $0 / 65536 } }
            let sample = MetricSample(at: now, load1: load.first, memoryPercent: memoryPercent,
                                      onlineDevices: leases?.count)
            MetricHistoryFileStore.shared.append(sample, routerID: routerID)
            let center = await MainActor.run { AlertCenter() }
            await center.refreshAuthorization()
            await MainActor.run {
                center.evaluate(
                    observation: AlertObservation(at: now, reachable: true,
                                                  load1: load.first, memoryPercent: memoryPercent,
                                                  deviceIDs: leases.map { Set($0.map(\.mac)) }),
                    routerID: routerID, routerName: profile.name)
            }
            AppDiagnostics.record(.app, L10n.string("后台采样完成"),
                                  metadata: ["router": profile.address])
        } catch {
            let center = await MainActor.run { AlertCenter() }
            await center.refreshAuthorization()
            await MainActor.run {
                center.evaluate(
                    observation: AlertObservation(at: now, reachable: false),
                    routerID: routerID, routerName: profile.name)
            }
            AppDiagnostics.record(.error, L10n.string("后台采样失败"),
                                  metadata: ["router": profile.address,
                                             "reason": error.localizedDescription])
        }
    }
}

/// Fixed credentials for one background pass; nothing persists beyond
/// the SessionManager that holds it.
private final class StaticCredentialBox: SessionCredentialProvider, @unchecked Sendable {
    private let credentials: RouterCredentials
    init(username: String, password: String) {
        credentials = RouterCredentials(username: username, password: password)
    }
    func routerCredentials() async -> RouterCredentials? { credentials }
}
