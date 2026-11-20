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
        recordActivity("已连接路由器", detail: "通过路由器账户建立管理会话。")
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
        if snapshot.menuTree.isEmpty, snapshot.board.hostname == nil {
            capabilityError = "实时发现失败：路由器未返回菜单与设备信息。"
            if let cached = cachedCapability(for: profile) {
                capability = cached
                capabilityIsFromCache = true
                capabilityUpdatedAt = nil
                recordActivity("显示离线缓存", detail: "实时发现失败，导航来自上次成功发现的缓存快照。", isWarning: true)
            }
            return
        }
        capability = snapshot
        capabilityIsFromCache = false
        capabilityUpdatedAt = Date()
        capabilityError = result.snapshot.warnings.isEmpty ? nil : result.snapshot.warnings.joined(separator: "\n")
        if let data = try? JSONEncoder().encode(result.collected) {
            defaults.set(data, forKey: capabilityCachePrefix + profile.id.uuidString)
        }
    }

    private func cachedCapability(for profile: RouterProfile) -> CapabilitySnapshot? {
        guard let data = defaults.data(forKey: capabilityCachePrefix + profile.id.uuidString),
              let collected = try? JSONDecoder().decode(CollectedRouterSnapshot.self, from: data) else { return nil }
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
        if capability == nil || capabilityIsFromCache { await loadCapability() }
        let errors = [overviewError, devicesError, wirelessError, servicesError].compactMap { $0 }
        if !errors.isEmpty && (!wasLoaded || !previouslyFailed) {
            recordActivity("部分信息读取失败", detail: "\(errors.count) 项数据未能更新，请在对应页面查看原因。", isWarning: true)
        } else if errors.isEmpty && previouslyFailed {
            recordActivity("状态读取已恢复", detail: "概览、租约、无线和服务状态已重新读取。")
        } else if !wasLoaded && errors.isEmpty {
            recordActivity("首次读取完成", detail: "概览、租约、无线和服务状态已读取。")
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

    private func recordActivity(_ title: String, detail: String, isWarning: Bool = false) {
        activities.insert(RouterActivity(title, detail: detail, isWarning: isWarning), at: 0)
        activities = Array(activities.prefix(50))
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
            recordActivity("配置等待确认", detail: "\(plan.original.name) 的应用请求已获路由器确认，等待连接验证。")
        } else {
            recordActivity("配置应用结果待确认", detail: "\(plan.original.name) 的应用请求未收到响应，请验证连接并核对配置。", isWarning: true)
        }
    }

    func confirmConfiguration() async throws {
        guard !isMutating, let configurationClient else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await configurationClient.confirm()
        pendingConfiguration = nil
        recordActivity("配置已确认", detail: "路由器连接验证通过，修改已保留。")
        await refresh()
    }

    func rollbackConfiguration() async throws {
        guard !isMutating, let configurationClient else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await configurationClient.rollback()
        pendingConfiguration = nil
        recordActivity("配置已回滚", detail: "路由器已接受回滚请求，请核对重新读取的配置。")
        await refresh()
    }

    func releaseExpiredConfiguration() async {
        guard let pendingConfiguration, pendingConfiguration.deadline <= Date(), !isMutating else { return }
        await configurationClient?.releaseExpired()
        self.pendingConfiguration = nil
        recordActivity("配置确认已超时", detail: "已超过回滚期限。请重新读取配置，核对路由器实际状态。", isWarning: true)
        await refresh()
    }

    /// Service actions run as mini-transactions (phase 2): snapshot the
    /// state, perform through the reader, re-read and verify the end
    /// state; a contradiction is reported, never hidden.
    func performServiceAction(name: String, action: ServiceAction) async throws {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
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
            recordActivity("服务操作后状态未达预期", detail: "\(name)：\(action.title) 已下发，但路由器报告的状态与预期不一致，请核对。", isWarning: true)
        } else {
            recordActivity("服务操作已执行", detail: "\(name)：\(action.title)。")
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
            recordActivity("配置已更新", detail: "\(plan.original.name)：\(plan.edits.count) 项修改已下发、回读验证并确认。")
            await refresh()
            return receipt
        } catch let error as TransactionError {
            if error == .unacknowledged {
                // The client still holds the pending transaction; surface
                // it for explicit resolution instead of guessing.
                pendingConfiguration = PendingConfiguration(config: plan.original.name,
                                                            deadline: Date().addingTimeInterval(90),
                                                            acknowledged: false)
                recordActivity("配置应用结果待确认", detail: "\(plan.original.name) 的应用请求未收到确认，请验证连接后决定保留或回滚。", isWarning: true)
            } else {
                recordActivity("配置事务失败", detail: error.localizedDescription, isWarning: true)
            }
            throw error
        }
    }

    /// Device reboot: a single ubus call behind the UI's strong
    /// confirmation. The connection drops afterwards by design.
    func rebootRouter() async throws {
        guard !isMutating, pendingConfiguration == nil, let sessionManager else { throw ConfigurationError.busy }
        try await SystemControlClient(caller: sessionManager).reboot()
        recordActivity("已发送重启指令", detail: "路由器正在重启，连接将中断数分钟。", isWarning: true)
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
