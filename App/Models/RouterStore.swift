import Foundation
import Observation
import OpenWrtKit

@MainActor @Observable
final class RouterStore {
    private(set) var profiles: [RouterProfile] = []
    private(set) var activeProfile: RouterProfile?
    private(set) var connectionID = UUID()
    private(set) var snapshot: RouterSnapshot?
    private(set) var leases: [DHCPLease] = []
    private(set) var radios: [WirelessRadio] = []
    private(set) var services: [RouterService] = []
    private(set) var inventory = RouterInventory()
    private(set) var inventoryUpdatedAt: Date?
    private(set) var pendingConfiguration: PendingConfiguration?
    private(set) var isMutating = false
    private(set) var activities: [RouterActivity] = []
    private(set) var overviewError: String?
    private(set) var devicesError: String?
    private(set) var wirelessError: String?
    private(set) var servicesError: String?
    private(set) var storageError: String?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var overviewUpdatedAt: Date?
    private(set) var devicesUpdatedAt: Date?
    private(set) var wirelessUpdatedAt: Date?
    private(set) var servicesUpdatedAt: Date?

    private(set) var capability: CapabilitySnapshot?
    private(set) var capabilityUpdatedAt: Date?
    private(set) var capabilityError: String?
    private(set) var capabilityIsFromCache = false
    /// The snapshot-language prediction in effect when the last live
    /// discovery ran; the baseline for the refresh-time language gate.
    private var lastDiscoveryPrediction: String?
    private(set) var realtimeSamples: [RealtimeSample] = []
    private(set) var realtimeUpdatedAt: Date?
    private(set) var defaultProfileID: UUID?

    @ObservationIgnored private var transport: RouterTransport?
    @ObservationIgnored private var reader: RouterReader?
    @ObservationIgnored private var sessionManager: SessionManager?
    @ObservationIgnored private(set) var readClient: ReadOnlyDataClient?
    @ObservationIgnored private var configurationClient: RouterConfigurationClient?
    @ObservationIgnored private var realtimeEngine: RealtimeEngine?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var liveCredentials: LiveCredentialBox?
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let defaults: UserDefaults
    private let profilesKey = "router-profiles.v1"

    var hasConnection: Bool { activeProfile != nil }

    private let defaultProfileKey = "default-router-profile.v1"
    private let capabilityCachePrefix = "capability-cache.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: defaultProfileKey) { defaultProfileID = UUID(uuidString: raw) }
        if let data = defaults.data(forKey: profilesKey) {
            do { profiles = try JSONDecoder().decode([RouterProfile].self, from: data) }
            catch { storageError = "保存的路由器列表无法读取。原始记录仍保留在设备上。" }
        }
        #if DEBUG
        UITestingSeed.applyIfNeeded(to: self)
        #endif
    }

    func credential(for profile: RouterProfile) throws -> StoredCredential? {
        try credentials.read(id: profile.id)
    }

    /// Return a certificate notice through the error so the UI can ask once,
    /// then retry with that exact fingerprint. Nothing is persisted on failure.
    func connect(profile: RouterProfile, password: String, fingerprint: String?) async throws {
        guard pendingConfiguration == nil, !isMutating else { throw ConfigurationError.busy }
        let address = try URLNormalizer.normalize(profile.address)
        let candidateTransport = RouterTransport(address: address, fingerprint: fingerprint)
        let client = UbusClient(address: address, session: candidateTransport.session)
        let session: UbusSession
        do {
            session = try await client.login(username: profile.username, password: password)
            try Task.checkCancellation()
        } catch {
            AppDiagnostics.record(.error, L10n.string("连接失败"),
                                  metadata: ["address": profile.address, "reason": error.localizedDescription])
            let notice = candidateTransport.delegate.certificateNotice
            candidateTransport.close()
            if let notice { throw AppFailure.certificate(notice) }
            throw error
        }
        guard pendingConfiguration == nil, !isMutating else {
            candidateTransport.close()
            throw ConfigurationError.busy
        }
        var saved = profile
        saved.address = address.url.absoluteString
        saved.lastConnected = Date()
        if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saved.name = address.host }
        do {
            try credentials.save(StoredCredential(password: saved.rememberPassword ? password : nil,
                                                 certificateFingerprint: fingerprint), id: saved.id)
        } catch {
            candidateTransport.close()
            throw error
        }
        let oldReader = reader
        let oldTransport = transport
        transport = candidateTransport
        // All data flow goes through the SessionManager from here on: when
        // the router session expires it re-logs in silently (spec L1)
        // instead of surfacing an error. The password stays in memory for
        // this connection only; the Keychain copy (when the user chose to
        // remember it) is the fallback.
        let credentialBox = LiveCredentialBox(username: saved.username, password: password)
        liveCredentials = credentialBox
        let manager = SessionManager(client: client, credentialProvider: credentialBox)
        sessionManager = manager
        let newReader = RouterReader(caller: manager)
        reader = newReader
        configurationClient = RouterConfigurationClient(caller: manager)
        readClient = ReadOnlyDataClient(caller: manager)
        activeProfile = saved
        connectionID = UUID()
        clearData()
        recordActivity(L10n.string("已连接路由器"), detail: L10n.string("通过路由器账户建立管理会话。"), category: .connection)
        EventLogStore.shared.append(category: .operation, kind: .login,
                                    title: L10n.string("登录路由器"),
                                    detail: L10n.format("已连接到 %@（%@）。", saved.name, saved.address),
                                    routerID: saved.id.uuidString)
        profiles.removeAll { $0.id == saved.id }
        profiles.insert(saved, at: 0)
        persist()
        if defaultProfileID == nil { setDefaultProfile(saved) }
        if let oldReader { Task { await oldReader.logout(); oldTransport?.close() } }
        else { oldTransport?.close() }
        await loadCapability()
        startPolling()
    }

    /// L2 discovery: build the CapabilitySnapshot the whole navigation is
    /// generated from, cache its collected form, and fall back to that
    /// cache (clearly marked) when the live haul fails.
    func loadCapability() async {
        guard let reader, let profile = activeProfile else { return }
        let discovery = RouterDiscovery(reader: reader)
        let result = await discovery.discoverWithCollected(
            routerID: profile.id.uuidString, address: profile.address, role: nil)
        let snapshot = result.snapshot
        // A haul that is not substantive — empty, or an anonymous-grade
        // menu the discovery self-healing could not repair — is a failed
        // discovery: never cache it, never let it replace a good
        // snapshot. (The old check required BOTH an empty tree and a
        // missing hostname, so stripped menus were cached as success.)
        if !snapshot.hasSubstantiveMenu {
            AppDiagnostics.record(.discovery, L10n.string("实时发现失败"),
                                  metadata: ["address": profile.address])
            capabilityError = L10n.string("实时发现失败：路由器返回的菜单不完整（会话未被认可为已登录），已保留上次结果，未写入缓存。")
            if capability == nil, let cached = cachedCapability(for: profile) {
                capability = cached
                capabilityIsFromCache = true
                capabilityUpdatedAt = nil
                recordActivity(L10n.string("显示离线缓存"), detail: L10n.string("实时发现不完整，导航来自上次成功发现的缓存快照。"), isWarning: true, category: .discovery)
            }
            return
        }
        capability = snapshot
        capabilityIsFromCache = false
        capabilityUpdatedAt = Date()
        lastDiscoveryPrediction = L10n.expectedSnapshotLanguage
        capabilityError = result.snapshot.warnings.isEmpty ? nil : result.snapshot.warnings.joined(separator: "\n")
        if let data = try? JSONEncoder().encode(result.collected) {
            defaults.set(data, forKey: capabilityCachePrefix + profile.id.uuidString)
        }
    }

    private func cachedCapability(for profile: RouterProfile) -> CapabilitySnapshot? {
        guard let data = defaults.data(forKey: capabilityCachePrefix + profile.id.uuidString),
              let collected = try? JSONDecoder().decode(CollectedRouterSnapshot.self, from: data) else { return nil }
        // Language gate (localization package, spec D): a cache written
        // by an older schema — including every pre-tagging haul — is
        // discarded outright, and a haul whose display strings were
        // localized for a different language than a fresh discovery
        // would produce now is not rendered either; the caller falls
        // back to live re-discovery instead of showing stale-language
        // pages until the user happens to refresh.
        guard collected.isUsableCache(expectedLanguage: L10n.expectedSnapshotLanguage) else { return nil }
        return CapabilitySnapshot(collected: collected)
    }

    var tabs: [TabDescriptor] {
        capability.map(PageRegistry.tabs(for:)) ?? PageRegistry.settingsOnlyTabs()
    }

    var freshnessPolicy: FreshnessPolicy {
        FreshnessPolicy(staleAfter: pollInterval * 2.5)
    }

    private var pollInterval: TimeInterval {
        let stored = defaults.double(forKey: "refresh-interval.v1")
        return stored >= 5 ? min(stored, 120) : 10
    }

    /// One realtime engine for the whole app (spec L3): load, bandwidth
    /// and connection count share this cadence and freshness clock.
    private func startPolling() {
        pollTask?.cancel()
        guard let readClient else { return }
        let engine = RealtimeEngine(fetch: {
            async let info = try? readClient.systemInfo()
            async let traffic = try? readClient.deviceTraffic()
            async let connections = try? readClient.connectionCount()
            let (infoValue, trafficValue, connectionValue) = await (info, traffic, connections)
            guard infoValue != nil || trafficValue != nil else { return nil }
            let load = (infoValue?["load"].arrayValue ?? []).compactMap { $0.doubleValue.map { $0 / 65536 } }
            return RawRealtimeReading(load: load, traffic: trafficValue ?? [],
                                      connections: connectionValue?.count)
        })
        realtimeEngine = engine
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let sample = await engine.pollOnce() {
                    let samples = await engine.samples
                    await MainActor.run { [weak self] in
                        self?.realtimeSamples = samples
                        self?.realtimeUpdatedAt = sample.at
                    }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func setDefaultProfile(_ profile: RouterProfile?) {
        defaultProfileID = profile?.id
        if let profile { defaults.set(profile.id.uuidString, forKey: defaultProfileKey) }
        else { defaults.removeObject(forKey: defaultProfileKey) }
    }

    var defaultProfile: RouterProfile? {
        profiles.first { $0.id == defaultProfileID }
    }

    func uciConfiguration(_ name: String) async throws -> RouterConfiguration {
        guard let readClient else { throw OpenWrtKitError.authenticationFailed }
        return try await readClient.configuration(name)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let reader else { return }
        let generation = connectionID
        let previouslyFailed = overviewError != nil || devicesError != nil || wirelessError != nil || servicesError != nil
        let wasLoaded = hasLoaded
        isRefreshing = true
        defer { if generation == connectionID { isRefreshing = false } }
        async let overview = capture { try await reader.snapshot() }
        async let devices = capture { try await reader.leases() }
        async let wireless = capture { try await reader.wireless() }
        async let serviceList = capture { try await reader.services() }
        async let directory = reader.inventory()
        let results = await (overview, devices, wireless, serviceList, directory)
        guard generation == connectionID, !Task.isCancelled else { return }
        switch results.0 {
        case .success(let value):
            snapshot = value
            overviewError = value.warnings.isEmpty ? nil : value.warnings.joined(separator: "\n")
            overviewUpdatedAt = Date()
        case .failure(let error): overviewError = FriendlyError.message(error)
        }
        switch results.1 {
        case .success(let value): leases = value; devicesError = nil; devicesUpdatedAt = Date()
        case .failure(let error): devicesError = FriendlyError.message(error)
        }
        switch results.2 {
        case .success(let value): radios = value; wirelessError = nil; wirelessUpdatedAt = Date()
        case .failure(let error): wirelessError = FriendlyError.message(error)
        }
        switch results.3 {
        case .success(let value): services = value; servicesError = nil; servicesUpdatedAt = Date()
        case .failure(let error): servicesError = FriendlyError.message(error)
        }
        inventory = results.4
        inventoryUpdatedAt = Date()
        // If the system language changed since the snapshot was
        // discovered (per-app language in Settings, or a cache admitted
        // while the language was unpredictable), re-discover so every
        // page — titles included — follows the current language. The
        // prediction recorded at the last live discovery is the
        // baseline: a router without a catalog for the system language
        // settles on a different tag once, and that settled result must
        // not trigger a re-discovery on every refresh.
        L10n.syncKitLanguage()
        let expectedLanguage = L10n.expectedSnapshotLanguage
        let languageStale = capability != nil && expectedLanguage != nil
            && expectedLanguage != capability?.language
            && expectedLanguage != lastDiscoveryPrediction
        if capability == nil || capabilityIsFromCache || languageStale { await loadCapability() }
        let errors = [overviewError, devicesError, wirelessError, servicesError].compactMap { $0 }
        if !errors.isEmpty && (!wasLoaded || !previouslyFailed) {
            recordActivity(L10n.string("部分信息读取失败"), detail: L10n.format("%lld 项数据未能更新，请在对应页面查看原因。", errors.count), isWarning: true, category: .error)
        } else if errors.isEmpty && previouslyFailed {
            recordActivity(L10n.string("状态读取已恢复"), detail: L10n.string("概览、租约、无线和服务状态已重新读取。"), category: .refresh)
        } else if !wasLoaded && errors.isEmpty {
            recordActivity(L10n.string("首次读取完成"), detail: L10n.string("概览、租约、无线和服务状态已读取。"), category: .refresh)
        }
        hasLoaded = true
    }

    func disconnect() {
        guard pendingConfiguration == nil, !isMutating else { return }
        pollTask?.cancel(); pollTask = nil
        realtimeEngine = nil
        let oldReader = reader
        let oldTransport = transport
        reader = nil; transport = nil; configurationClient = nil
        sessionManager = nil; readClient = nil; liveCredentials = nil
        activeProfile = nil; connectionID = UUID()
        clearData()
        if let oldReader { Task { await oldReader.logout(); oldTransport?.close() } }
        else { oldTransport?.close() }
    }

    func remove(_ profile: RouterProfile) throws {
        guard activeProfile?.id != profile.id || (pendingConfiguration == nil && !isMutating) else { throw ConfigurationError.busy }
        try credentials.delete(id: profile.id)
        profiles.removeAll { $0.id == profile.id }
        persist()
        if activeProfile?.id == profile.id { disconnect() }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: profilesKey)
            storageError = nil
        } catch { storageError = "路由器列表未能保存，下次打开可能需要重新添加。" }
    }

    private func clearData() {
        snapshot = nil; leases = []; radios = []; services = []
        capability = nil; capabilityUpdatedAt = nil; capabilityError = nil; capabilityIsFromCache = false
        realtimeSamples = []; realtimeUpdatedAt = nil
        activities = []
        inventory = RouterInventory(); inventoryUpdatedAt = nil; pendingConfiguration = nil
        overviewError = nil; devicesError = nil; wirelessError = nil; servicesError = nil
        overviewUpdatedAt = nil; devicesUpdatedAt = nil; wirelessUpdatedAt = nil; servicesUpdatedAt = nil
        hasLoaded = false; isRefreshing = false
    }

    /// Every activity also lands in the diagnostic event buffer
    /// (package A) under the caller's category, so the exportable log
    /// covers the same ground as the on-screen activity list. The
    /// buffer redacts on record; the detail rides as metadata.
    private func recordActivity(_ title: String, detail: String, isWarning: Bool = false,
                                category: DiagnosticCategory = .app) {
        activities.insert(RouterActivity(title, detail: detail, isWarning: isWarning), at: 0)
        activities = Array(activities.prefix(50))
        AppDiagnostics.record(category, title, metadata: ["detail": detail])
    }

    func configuration(_ name: String) async throws -> RouterConfiguration {
        guard let configurationClient else { throw ConfigurationError.noPending }
        return try await configurationClient.read(name)
    }

    func canWriteConfiguration(_ name: String) async throws -> Bool {
        guard let configurationClient else { return false }
        return try await configurationClient.access(config: name, write: true)
    }

    func applyConfiguration(_ plan: ConfigurationPlan) async throws {
        guard !isMutating, pendingConfiguration == nil, let configurationClient else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let pending = try await configurationClient.apply(plan)
        pendingConfiguration = pending
        if pending.acknowledged {
            recordActivity(L10n.string("配置等待确认"), detail: L10n.format("%@ 的应用请求已获路由器确认，等待连接验证。", plan.original.name), category: .transaction)
        } else {
            recordActivity(L10n.string("配置应用结果待确认"), detail: L10n.format("%@ 的应用请求未收到响应，请验证连接并核对配置。", plan.original.name), isWarning: true, category: .transaction)
        }
    }

    func confirmConfiguration() async throws {
        guard !isMutating, let configurationClient else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await configurationClient.confirm()
        pendingConfiguration = nil
        recordActivity(L10n.string("配置已确认"), detail: L10n.string("路由器连接验证通过，修改已保留。"), category: .transaction)
        await refresh()
    }

    func rollbackConfiguration() async throws {
        guard !isMutating, let configurationClient else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await configurationClient.rollback()
        pendingConfiguration = nil
        recordActivity(L10n.string("配置已回滚"), detail: L10n.string("路由器已接受回滚请求，请核对重新读取的配置。"), category: .transaction)
        await refresh()
    }

    func releaseExpiredConfiguration() async {
        guard let pendingConfiguration, pendingConfiguration.deadline <= Date(), !isMutating else { return }
        await configurationClient?.releaseExpired()
        self.pendingConfiguration = nil
        recordActivity(L10n.string("配置确认已超时"), detail: L10n.string("已超过回滚期限。请重新读取配置，核对路由器实际状态。"), isWarning: true, category: .transaction)
        await refresh()
    }

    /// Service actions run as mini-transactions (phase 2): snapshot the
    /// state, perform through the reader, re-read and verify the end
    /// state; a contradiction is reported, never hidden.
    func performServiceAction(name: String, action: ServiceAction) async throws {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        // Core-service protection (audit F1), enforced at this
        // single door as well as in the UI: no surface may stop a
        // core service or turn off its autostart — the action would
        // travel over the very channel it destroys.
        if ServiceProtection.isBlocked(action: action, forServiceNamed: name) {
            throw AppFailure.storage(L10n.format("「%@」是核心服务，不提供「%@」操作：执行后可能同时失去手机与电脑的管理通道，只能到路由器跟前恢复。", name, action.title))
        }
        isMutating = true
        defer { isMutating = false }
        let transaction = ServiceActionTransaction(
            readState: { serviceName in
                async let services = try? reader.services()
                async let inventory = reader.inventory()
                let (serviceList, directory) = await (services, inventory)
                let running = serviceList?.first { $0.name == serviceName }.flatMap { service -> Bool? in
                    guard let total = service.totalInstances, total > 0 else { return nil }
                    return (service.runningInstances ?? 0) > 0
                }
                let enabled = directory.initServices.first { $0.name == serviceName }?.enabled
                return ServiceActionTransaction.State(running: running, enabled: enabled)
            },
            perform: { serviceName, serviceAction in
                try await reader.serviceAction(name: serviceName, action: serviceAction)
            })
        let outcome = try await transaction.execute(name: name, action: action)
        if outcome.verified == false {
            recordActivity(L10n.string("服务操作后状态未达预期"), detail: L10n.format("%@：%@ 已下发，但路由器报告的状态与预期不一致，请核对。", name, action.title), isWarning: true, category: .session)
        } else {
            recordActivity(L10n.string("服务操作已执行"), detail: L10n.format("%@：%@。", name, action.title), category: .session)
        }
        await refresh()
    }

    /// The one door for configuration writes (spec L4): every editing
    /// page builds a ConfigurationPlan and comes through here. The client
    /// stages, applies inside the rollback window, reloads services,
    /// verifies by re-reading, and confirms — or rolls back.
    func executeConfiguration(plan: ConfigurationPlan, reloadServices: [String] = []) async throws -> TransactionReceipt {
        guard !isMutating, pendingConfiguration == nil, let configurationClient, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        do {
            let receipt = try await configurationClient.execute(plan: plan, reloadServices: reloadServices) { name, action in
                try await reader.serviceAction(name: name, action: action)
            }
            recordActivity(L10n.string("配置已更新"), detail: L10n.format("%@：%lld 项修改已下发、回读验证并确认。", plan.original.name, plan.edits.count), category: .transaction)
            await refresh()
            return receipt
        } catch let error as TransactionError {
            if error == .unacknowledged {
                // The client still holds the pending transaction; surface
                // it for explicit resolution instead of guessing.
                pendingConfiguration = PendingConfiguration(config: plan.original.name,
                                                            deadline: Date().addingTimeInterval(90),
                                                            acknowledged: false)
                recordActivity(L10n.string("配置应用结果待确认"), detail: L10n.format("%@ 的应用请求未收到确认，请验证连接后决定保留或回滚。", plan.original.name), isWarning: true, category: .transaction)
            } else {
                recordActivity(L10n.string("配置事务失败"), detail: error.localizedDescription, isWarning: true, category: .transaction)
            }
            throw error
        }
    }

    /// Device reboot: a single ubus call behind the UI's strong
    /// confirmation. The connection drops afterwards by design.
    func rebootRouter() async throws {
        guard !isMutating, pendingConfiguration == nil, let sessionManager else { throw ConfigurationError.busy }
        try await SystemControlClient(caller: sessionManager).reboot()
        recordActivity(L10n.string("已发送重启指令"), detail: L10n.string("路由器正在重启，连接将中断数分钟。"), isWarning: true, category: .session)
    }

    /// WAN redial (package B quick action): cycle the discovered
    /// upstream interface down/up through the same session channel as
    /// every other action. Callers verify recovery by refreshing and
    /// watching the interface state; the call itself only dials.
    /// The activity record follows the upstream's nature (audit
    /// U7): on a bypass router the cycled interface is the LAN
    /// interface itself, and the record must not call it a WAN dial.
    func redialWAN() async throws {
        guard !isMutating, pendingConfiguration == nil, let sessionManager else { throw ConfigurationError.busy }
        guard let upstream = capability?.upstream else {
            throw AppFailure.storage(L10n.string("未发现上游接口，无法重拨。"))
        }
        try await SystemControlClient(caller: sessionManager).restartInterface(name: upstream.interfaceName)
        let isLocalUpstream = capability.map {
            DiscoveryRules.upstreamNature(of: upstream, interfaces: $0.interfaces) == .local
        } ?? false
        if isLocalUpstream {
            recordActivity(L10n.string("已重启上游接口"), detail: L10n.format("接口 %@ 已重启，等待恢复连接。", upstream.interfaceName), isWarning: true, category: .session)
        } else {
            recordActivity(L10n.string("已重拨 WAN"), detail: L10n.format("接口 %@ 已重新拨号，等待恢复连接。", upstream.interfaceName), isWarning: true, category: .session)
        }
    }

    func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.records(kind)
    }

    private nonisolated func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}


/// In-memory credentials for the SessionManager's automatic re-login.
/// The password lives only for the duration of the connection; nothing is
/// written anywhere by this type.
private final class LiveCredentialBox: SessionCredentialProvider, @unchecked Sendable {
    private let credentials: RouterCredentials
    init(username: String, password: String) {
        credentials = RouterCredentials(username: username, password: password)
    }
    func routerCredentials() async -> RouterCredentials? { credentials }
}


extension RouterStore {
    /// ubus file plane for the native file manager (phase 3).
    var fileClient: FileClient? {
        sessionManager.map { FileClient(caller: $0) }
    }

    /// Dedicated-service data plane (package F): ddns, appfilter and
    /// Wake-on-LAN reads/actions on the live session.
    var dedicatedClient: DedicatedServiceClient? {
        sessionManager.map { DedicatedServiceClient(caller: $0) }
    }

    /// One fresh login attempt against the active router — the
    /// reconnection probe for the upgrade flow. Builds a throwaway
    /// transport so the (presumed dead) live session is untouched.
    func probeRouterReachable() async -> Bool {
        guard let profile = activeProfile, let liveCredentials,
              let credentials = await liveCredentials.routerCredentials(),
              let address = try? URLNormalizer.normalize(profile.address) else { return false }
        let transport = RouterTransport(address: address, fingerprint: nil)
        defer { transport.close() }
        let client = UbusClient(address: address, session: transport.session)
        do {
            _ = try await client.login(username: credentials.username, password: credentials.password)
            return true
        } catch {
            return false
        }
    }
}

#if DEBUG
extension RouterStore {
    /// DEBUG-only installer for the XCUITest seed (see UITestingSeed).
    /// In-memory state only — nothing is persisted, no transport is
    /// created — and Release builds compile this out entirely.
    func installSeededState(profiles seeded: [RouterProfile], activeProfile seededActive: RouterProfile?,
                            capability seededCapability: CapabilitySnapshot?) {
        profiles = seeded
        activeProfile = seededActive
        if let seededActive { defaultProfileID = seededActive.id }
        capability = seededCapability
        capabilityUpdatedAt = seededCapability == nil ? nil : Date()
        hasLoaded = seededActive != nil
    }
}
#endif
