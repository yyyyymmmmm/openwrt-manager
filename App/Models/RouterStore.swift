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
    private(set) var routing: RouterRoutingSnapshot?
    private(set) var radios: [WirelessRadio] = []
    private(set) var services: [RouterService] = []
    private(set) var inventory = RouterInventory()
    private(set) var inventoryUpdatedAt: Date?
    private(set) var pendingConfiguration: PendingConfiguration?
    private(set) var isMutating = false
    private(set) var activities: [RouterActivity] = []
    private(set) var overviewError: String?
    private(set) var devicesError: String?
    private(set) var routingError: String?
    private(set) var wirelessError: String?
    private(set) var servicesError: String?
    private(set) var storageError: String?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var overviewUpdatedAt: Date?
    private(set) var devicesUpdatedAt: Date?
    private(set) var routingUpdatedAt: Date?
    private(set) var wirelessUpdatedAt: Date?
    private(set) var servicesUpdatedAt: Date?

    @ObservationIgnored private var transport: RouterTransport?
    @ObservationIgnored private var reader: RouterReader?
    @ObservationIgnored private var configurationClient: RouterConfigurationClient?
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let defaults: UserDefaults
    private let profilesKey = "router-profiles.v1"

    var hasConnection: Bool { activeProfile != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        reader = RouterReader(client: client, session: session)
        configurationClient = RouterConfigurationClient(client: client, session: session)
        activeProfile = saved
        connectionID = UUID()
        clearData()
        recordActivity("已连接路由器", detail: "通过路由器账户建立管理会话。")
        profiles.removeAll { $0.id == saved.id }
        profiles.insert(saved, at: 0)
        persist()
        if let oldReader { Task { await oldReader.logout(); oldTransport?.close() } }
        else { oldTransport?.close() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let reader else { return }
        let generation = connectionID
        let previouslyFailed = overviewError != nil || devicesError != nil || routingError != nil || wirelessError != nil || servicesError != nil
        let wasLoaded = hasLoaded
        isRefreshing = true
        defer { if generation == connectionID { isRefreshing = false } }
        async let overview = capture { try await reader.snapshot() }
        async let devices = capture { try await reader.leases() }
        async let wireless = capture { try await reader.wireless() }
        async let serviceList = capture { try await reader.services() }
        async let directory = reader.inventory()
        let overviewResult = await overview
        let interfaces = (try? overviewResult.get().interfaces) ?? []
        async let routeList = capture { try await reader.routing(interfaces: interfaces) }
        let results = await (devices, wireless, serviceList, directory, routeList)
        guard generation == connectionID, !Task.isCancelled else { return }
        switch overviewResult {
        case .success(let value):
            snapshot = value
            overviewError = value.warnings.isEmpty ? nil : value.warnings.joined(separator: "\n")
            overviewUpdatedAt = Date()
        case .failure(let error): overviewError = FriendlyError.message(error)
        }
        switch results.0 {
        case .success(let value): leases = value; devicesError = nil; devicesUpdatedAt = Date()
        case .failure(let error): devicesError = FriendlyError.message(error)
        }
        switch results.1 {
        case .success(let value): radios = value; wirelessError = nil; wirelessUpdatedAt = Date()
        case .failure(let error): wirelessError = FriendlyError.message(error)
        }
        switch results.2 {
        case .success(let value): services = value; servicesError = nil; servicesUpdatedAt = Date()
        case .failure(let error): servicesError = FriendlyError.message(error)
        }
        switch results.4 {
        case .success(let value): routing = value; routingError = nil; routingUpdatedAt = Date()
        case .failure(let error): routingError = FriendlyError.message(error)
        }
        inventory = results.3
        inventoryUpdatedAt = Date()
        let errors = [overviewError, devicesError, routingError, wirelessError, servicesError].compactMap { $0 }
        if !errors.isEmpty && (!wasLoaded || !previouslyFailed) {
            recordActivity("部分信息读取失败", detail: "\(errors.count) 项数据未能更新，请在对应页面查看原因。", isWarning: true)
        } else if errors.isEmpty && previouslyFailed {
            recordActivity("状态读取已恢复", detail: "概览、路由邻居、租约、无线和服务状态已重新读取。")
        } else if !wasLoaded && errors.isEmpty {
            recordActivity("首次读取完成", detail: "概览、路由邻居、租约、无线和服务状态已读取。")
        }
        hasLoaded = true
    }

    func disconnect() {
        guard pendingConfiguration == nil, !isMutating else { return }
        let oldReader = reader
        let oldTransport = transport
        reader = nil; transport = nil; configurationClient = nil
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
        snapshot = nil; leases = []; routing = nil; radios = []; services = []
        activities = []
        inventory = RouterInventory(); inventoryUpdatedAt = nil; pendingConfiguration = nil
        overviewError = nil; devicesError = nil; routingError = nil; wirelessError = nil; servicesError = nil
        overviewUpdatedAt = nil; devicesUpdatedAt = nil; routingUpdatedAt = nil; wirelessUpdatedAt = nil; servicesUpdatedAt = nil
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

    func performServiceAction(name: String, action: ServiceAction) async throws {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await reader.serviceAction(name: name, action: action)
        recordActivity("服务操作已执行", detail: "\(name)：\(action.title)。")
        await refresh()
    }

    func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.records(kind)
    }

    func processes() async throws -> [RouterProcess] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.processes()
    }

    func processIdentity(_ process: RouterProcess) async throws -> RouterProcessIdentity {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.processIdentity(process)
    }

    func signalProcess(_ identity: RouterProcessIdentity, signal: RouterProcessSignal) async throws -> String {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let result = try await reader.signalProcess(identity, signal: signal)
        recordActivity("进程信号请求已返回", detail: "PID \(identity.process.pid)：\(signal.title)。实际结果见进程详情。", isWarning: true)
        return result
    }

    func networkProtocols() async throws -> [String] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.networkProtocols()
    }

    func homeProxyCapabilities() async throws -> HomeProxyCapabilities {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.homeProxyCapabilities()
    }

    func nativePluginRead(_ request: NativePluginRead) async throws -> String {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.nativePluginRead(request)
    }

    func upnpMappings() async throws -> [UPnPMapping] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.upnpMappings()
    }

    func zeroTierNetworks() async throws -> [ZeroTierNetwork] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.zeroTierNetworks()
    }

    func deleteUPnPMapping(_ mapping: UPnPMapping, observed: [UPnPMapping]) async throws -> [UPnPMapping] {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let mappings = try await reader.deleteUPnPMapping(mapping, observed: observed)
        recordActivity("UPnP 映射已重新核对", detail: "删除请求后未再读取到所选端点映射；客户端仍可能重新建立。")
        return mappings
    }

    func nativePluginAction(_ action: NativePluginAction) async throws -> String {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let result = try await reader.nativePluginAction(action)
        recordActivity(action.title, detail: "固件已响应请求。业务结果请查看操作页及日志。")
        await refresh()
        return result
    }

    func diagnose(tool: DiagnosticTool, host: String) async throws -> RouterCommandResult {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.diagnose(tool: tool, host: host)
    }

    func reboot() async throws {
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        try await reader.reboot()
        recordActivity("重启请求已接受", detail: "路由器已响应重启请求；重启完成后需要重新连接。", isWarning: true)
    }

    private nonisolated func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
