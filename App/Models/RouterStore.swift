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
    private(set) var systemRuntime: SystemRuntimeSnapshot?
    private(set) var systemRuntimeError: String?
    private(set) var packageInstalled: PackageListSnapshot?
    private(set) var packageAvailable: PackageListSnapshot?
    private(set) var packageInstalledError: String?
    private(set) var packageAvailableError: String?
    private(set) var isReadingPackages = false
    private(set) var packageTasks: [PackageTaskRecord] = []
    private(set) var packageRecheckRequired = false
    private(set) var firmwareRecords: [UUID: FirmwareTaskRecord] = [:]
    private(set) var firmwareRecordStorageError: String?
    var firmwareRecord: FirmwareTaskRecord? { activeProfile.flatMap { firmwareRecords[$0.id] } }
    var maintenanceRequiresReconnect: Bool {
        firmwareRecordStorageError != nil || firmwareRecord?.requiresReconnect == true
    }

    @ObservationIgnored private var transport: RouterTransport?
    @ObservationIgnored private var reader: RouterReader?
    @ObservationIgnored private var configurationClient: RouterConfigurationClient?
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let defaults: UserDefaults
    private let profilesKey = "router-profiles.v1"
    private let firmwareRecordsKey = "firmware-maintenance-records.v1"

    var hasConnection: Bool { activeProfile != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reloadFirmwareRecordStorage()
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
        case .success(let value):
            routing = value.retainingLastRead(routing)
            routingError = value.errors.isEmpty ? nil : value.errors.joined(separator: "\n")
            routingUpdatedAt = [routing?.routes4.updatedAt, routing?.routes6.updatedAt, routing?.neighbors4.updatedAt,
                                routing?.neighbors6.updatedAt, routing?.rules4.updatedAt, routing?.rules6.updatedAt].compactMap { $0 }.max()
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
        systemRuntime = nil; systemRuntimeError = nil
        packageInstalled = nil; packageAvailable = nil
        packageInstalledError = nil; packageAvailableError = nil
        isReadingPackages = false; packageTasks = []; packageRecheckRequired = false
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
        try requireMaintenanceSettled()
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
        try requireMaintenanceSettled()
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

    func refreshPackageLists() async {
        guard !isReadingPackages, !isMutating, let reader else { return }
        await readPackageLists(reader: reader, generation: connectionID)
    }

    private func readPackageLists(reader: RouterReader, generation: UUID) async {
        isReadingPackages = true
        defer { if generation == connectionID { isReadingPackages = false } }
        async let installed = capture { try await reader.packageList(installed: true) }
        async let available = capture { try await reader.packageList(installed: false) }
        let results = await (installed, available)
        guard generation == connectionID, !Task.isCancelled else { return }
        switch results.0 {
        case .success(let value): packageInstalled = value; packageInstalledError = nil
        case .failure(let error): packageInstalledError = FriendlyError.message(error)
        }
        switch results.1 {
        case .success(let value): packageAvailable = value; packageAvailableError = nil
        case .failure(let error): packageAvailableError = FriendlyError.message(error)
        }
        if packageInstalledError == nil && packageAvailableError == nil { packageRecheckRequired = false }
    }

    func packageOperationAccess(_ operation: PackageOperation) async throws -> Bool {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.packageOperationAccess(operation)
    }

    func performPackageOperation(_ operation: PackageOperation, installedVersion: String?, availableVersion: String?) async throws -> UUID {
        try requireMaintenanceSettled()
        guard !isMutating, !isReadingPackages, pendingConfiguration == nil, !packageRecheckRequired, let reader else { throw ConfigurationError.busy }
        let generation = connectionID
        isMutating = true
        defer { if generation == connectionID { isMutating = false } }
        let task = PackageTaskRecord(operation: operation, startedAt: Date())
        packageTasks.insert(task, at: 0)
        packageTasks = Array(packageTasks.prefix(10))
        do {
            let result = try await reader.packageOperation(operation, installedVersion: installedVersion, availableVersion: availableVersion)
            guard generation == connectionID else { throw CancellationError() }
            packageTasks[0].result = result
        } catch {
            guard generation == connectionID else { throw CancellationError() }
            packageTasks[0].error = FriendlyError.message(error)
            if let packageError = error as? PackageOperationError,
               case .uncertain = packageError {
                packageTasks[0].uncertain = true
                packageRecheckRequired = true
            }
        }
        await readPackageLists(reader: reader, generation: generation)
        guard generation == connectionID else { throw CancellationError() }
        packageTasks[0].completedAt = Date()
        if packageInstalledError == nil, let snapshot = packageInstalled, let name = operation.name {
            let current = snapshot.packages.first { $0.name == name }
            if operation.removesPackage {
                packageTasks[0].verification = current.map { "重读仍发现 \($0.name) \($0.version)；不能认定卸载完成。" } ?? "重读已安装清单未再发现此包；相关服务和依赖仍需核对。"
            } else {
                packageTasks[0].verification = current.map { "重读当前版本：\($0.version)。" + ($0.version == availableVersion ? "与确认时的软件源版本一致；运行状态仍需核对。" : "与确认时的软件源版本不同，请检查任务输出。") } ?? "重读未发现此软件包；不能认定安装完成。"
            }
        } else if operation.name == nil {
            packageTasks[0].verification = packageAvailableError == nil ? "已重新读取软件源清单；请同时检查命令退出码和错误输出。" : "软件源清单重读失败，请查看读取错误。"
        } else {
            packageTasks[0].verification = "已安装清单重读失败，最终状态仍未确认。"
        }
        recordActivity("软件包任务已返回", detail: operation.title + (operation.name.map { "：" + $0 } ?? "") + "。退出码、输出和清单核对见软件包任务。", isWarning: packageTasks[0].result?.output.exitCode != 0)
        // Re-discover menus, services and plugin configuration after a package
        // change; a successful process exit does not imply plugin health.
        await refresh()
        return task.id
    }

    func processes() async throws -> [RouterProcess] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.processes()
    }

    func scheduledTasks() async throws -> ScheduledTasksSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.scheduledTasks()
    }

    func systemFile(_ file: RouterSystemFile) async throws -> RouterSystemFileSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.systemFile(file)
    }

    func firmwareCapabilities() async throws -> FirmwareCapabilities {
        guard !isMutating, !maintenanceRequiresReconnect, let reader else { throw ConfigurationError.busy }
        let generation = connectionID
        let value = await reader.firmwareCapabilities()
        guard generation == connectionID else { throw CancellationError() }
        return value
    }

    func configurationBackupList() async throws -> RouterCommandResult {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = try await reader.configurationBackupList()
        guard generation == connectionID else { throw CancellationError() }
        return value
    }

    func downloadConfigurationBackup(connection: UUID) async throws -> FirmwareBackupDownload {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect,
              pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let value = try await reader.downloadConfigurationBackup()
        guard connection == connectionID else {
            try? FileManager.default.removeItem(at: value.fileURL)
            throw CancellationError()
        }
        recordActivity("配置备份已下载", detail: "请在备份页导出文件。下载和摘要不等同于已验证可恢复。")
        return value
    }

    func uploadMaintenanceFile(_ url: URL, kind: FirmwareFileKind, connection: UUID) async throws -> FirmwareUpload {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect,
              pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let value = try await reader.uploadMaintenanceFile(url, kind: kind)
        guard connection == connectionID else { throw CancellationError() }
        recordActivity(kind.title + "已上传", detail: "大小及 SHA-256 与本机一致；尚未执行恢复或刷写。")
        return value
    }

    func inspectConfigurationBackup(_ upload: FirmwareUpload, connection: UUID) async throws -> BackupInspection {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        let value = try await reader.inspectConfigurationBackup(upload)
        guard connection == connectionID else { throw CancellationError() }
        return value
    }

    func validateFirmware(_ upload: FirmwareUpload, connection: UUID) async throws -> FirmwareValidation {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        let value = try await reader.validateFirmware(upload)
        guard connection == connectionID else { throw CancellationError() }
        return value
    }

    func discardMaintenanceFile(_ upload: FirmwareUpload, connection: UUID) async throws {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect,
              pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        try await reader.discardMaintenanceFile(upload)
        guard connection == connectionID else { throw CancellationError() }
        recordActivity("已删除暂存文件", detail: upload.kind.title + "的暂存文件经摘要复核后删除，父目录已重读确认路径不存在。")
    }

    func performFirmwareMaintenance(_ request: FirmwareMaintenanceRequest, connection: UUID) async throws {
        guard connection == connectionID, !isMutating, !maintenanceRequiresReconnect,
              pendingConfiguration == nil, let reader, let profile = activeProfile else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        let startedAt = Date(), previous = snapshot?.system.firmware
        let previousRecord = firmwareRecords[profile.id]
        firmwareRecords[profile.id] = FirmwareTaskRecord(title: request.title, startedAt: startedAt, connectionID: connection,
            previousFirmware: previous, result: nil, message: "已开始维护前复核；请求是否已发出及执行结果尚未确认。中断后请先重新连接核对，不要重试。")
        do { try persistFirmwareRecords() }
        catch { firmwareRecords[profile.id] = previousRecord; throw error }
        var commandReturned = false
        do {
            let result: RouterCommandResult
            switch request {
            case .restore(let inspection): result = try await reader.restoreConfigurationBackup(inspection)
            case .upgrade(let validation, let options): result = try await reader.upgradeFirmware(validation, options: options)
            case .reset: result = try await reader.factoryReset()
            }
            commandReturned = true
            guard connection == connectionID else { throw FirmwareMaintenanceError.uncertain("命令已返回，但当前连接已变化") }
            let message = result.exitCode == 0
                ? "命令返回退出码 0，重启与最终状态尚未确认。请勿断电，等待路由器恢复后重新连接。"
                : "命令返回非零退出码 \(result.exitCode)，不能推定配置未变化。请查看原始输出并重新连接核对，未自动重试。"
            firmwareRecords[profile.id] = FirmwareTaskRecord(title: request.title, startedAt: startedAt, connectionID: connection,
                previousFirmware: previous, result: result, message: message)
            try persistFirmwareRecords()
            recordActivity(request.title + "请求已返回", detail: message, isWarning: true)
        } catch {
            if let failure = error as? FirmwareMaintenanceError, case .uncertain = failure {
                firmwareRecords[profile.id] = FirmwareTaskRecord(title: request.title, startedAt: startedAt, connectionID: connection,
                    previousFirmware: previous, result: nil, message: failure.localizedDescription)
                try persistFirmwareRecords()
                recordActivity(request.title + "结果未确认", detail: failure.localizedDescription, isWarning: true)
                return
            }
            // A local persistence error after the RPC returned must not erase
            // the durable preflight marker or imply that nothing happened.
            if commandReturned { throw error }
            firmwareRecords[profile.id] = previousRecord
            try persistFirmwareRecords()
            throw error
        }
    }

    func readFirmwareAfterReconnect() async throws {
        guard let reader, let profile = activeProfile, var record = firmwareRecords[profile.id],
              record.connectionID != connectionID, !isMutating else {
            throw FirmwareMaintenanceError.failed("请先从路由器选择页重新登录，再核对当前设备信息。不会重复执行维护命令。")
        }
        let generation = connectionID
        let value = try await reader.snapshot()
        guard generation == connectionID else { throw CancellationError() }
        let model = value.system.model, firmware = value.system.firmware
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model != "—",
              !firmware.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, firmware != "—" else {
            throw FirmwareMaintenanceError.failed("设备型号或固件版本尚未成功读取，不能确认重新连接后的状态。")
        }
        record.reconnectedAt = Date(); record.observedModel = model; record.observedFirmware = firmware
        firmwareRecords[profile.id] = record
        try persistFirmwareRecords()
        recordActivity("维护后设备信息已重读", detail: "已建立新会话并读取当前型号与版本；请继续核对配置、网络和业务，不能据此断言恢复或刷写完整成功。", isWarning: true)
    }

    func acknowledgeFirmwareVerification() throws {
        guard let profile = activeProfile, var record = firmwareRecords[profile.id],
              record.reconnectedAt != nil, record.connectionID != connectionID,
              !isMutating else { throw FirmwareMaintenanceError.failed("请先用新的路由器会话读取型号与固件版本，再完成操作后核对。") }
        record.verifiedAt = Date()
        firmwareRecords[profile.id] = record
        try persistFirmwareRecords()
        recordActivity("用户确认维护后核对", detail: "用户确认已自行检查路由器配置、网络及相关业务；App 仅记录此确认，不声称自动验证全部功能。", isWarning: true)
    }

    func systemFileWritable(_ file: RouterSystemFile) async throws -> Bool {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.systemFileWritable(file)
    }

    func saveSystemFile(observed: RouterSystemFileSnapshot, text: String) async throws -> RouterSystemFileSnapshot {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        let result = try await reader.saveSystemFile(observed: observed, text: text)
        recordActivity(observed.file.title + "已重读核对", detail: observed.file.savedExplanation)
        return result
    }

    func accounts() async throws -> RouterAccountsSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return await reader.accounts()
    }

    func changePassword(account: RouterAccount, policy: RouterPasswordPolicy, password: String, oldPassword: String) async throws -> String {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader, let profile = activeProfile, let transport else { throw ConfigurationError.busy }
        try policy.validate(password)
        isMutating = true; defer { isMutating = false }
        let changingLogin = account.username == profile.username
        let saved = try credentials.read(id: profile.id)
        if changingLogin {
            // Invalidate the stale saved password before a request whose outcome
            // might be unknowable after a network interruption. Keep TLS trust.
            try credentials.save(StoredCredential(password: nil, certificateFingerprint: saved?.certificateFingerprint), id: profile.id)
        }
        try await reader.changePassword(account: account, policy: policy, password: password, oldPassword: oldPassword)
        guard changingLogin else {
            recordActivity("账户密码请求已确认", detail: "固件报告修改成功；未替其他账户建立登录会话。")
            return "固件报告密码修改成功。该账户的新密码登录尚未核对。"
        }
        let client = UbusClient(address: try URLNormalizer.normalize(profile.address), session: transport.session)
        let newSession: UbusSession
        do { newSession = try await client.login(username: profile.username, password: password) }
        catch { throw RouterPasswordError.uncertain }
        self.reader = RouterReader(client: client, session: newSession)
        configurationClient = RouterConfigurationClient(client: client, session: newSession)
        connectionID = UUID()
        clearData()
        await reader.logout()
        var persistenceIssue: String?
        do { try credentials.save(StoredCredential(password: profile.rememberPassword ? password : nil, certificateFingerprint: saved?.certificateFingerprint), id: profile.id) }
        catch { persistenceIssue = "新会话已建立，但钥匙串保存失败；下次连接请手动输入新密码。" }
        recordActivity("新密码登录已核对", detail: "已建立新的路由器管理会话；密码没有写入活动记录。")
        await refresh()
        return persistenceIssue ?? "固件报告修改成功，已使用新密码重新登录。"
    }

    func scheduledTasksWritable() async throws -> Bool {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.scheduledTasksWritable()
    }

    func saveScheduledTasks(observed: ScheduledTasksSnapshot, text: String) async throws -> ScheduledTasksSaveResult {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let result = try await reader.saveScheduledTasks(observed: observed, text: text)
        recordActivity("计划任务文件已重读核对", detail: "cron 重载和任务执行情况请查看计划任务页与系统日志。", isWarning: true)
        return result
    }

    func reloadScheduledTasks(observed: ScheduledTasksSnapshot) async throws -> ScheduledTasksSaveResult {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let result = await reader.reloadScheduledTasks(observed: observed)
        recordActivity("计划任务重载请求已返回", detail: "实际退出码和错误见计划任务页，任务执行结果仍需核对。", isWarning: true)
        return result
    }

    func processIdentity(_ process: RouterProcess) async throws -> RouterProcessIdentity {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.processIdentity(process)
    }

    func signalProcess(_ identity: RouterProcessIdentity, signal: RouterProcessSignal) async throws -> String {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let result = try await reader.signalProcess(identity, signal: signal)
        recordActivity("进程信号请求已返回", detail: "PID \(identity.process.pid)：\(signal.title)。实际结果见进程详情。", isWarning: true)
        return result
    }

    func networkInterfaces() async throws -> [NetworkInterfaceSnapshot] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = try await reader.networkInterfaces()
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func networkProtocols() async throws -> [String] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.networkProtocols()
    }

    func readSystemRuntime() async throws -> SystemRuntimeSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        do {
            let value = try await reader.systemRuntime()
            guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
            systemRuntime = value; systemRuntimeError = nil
            return value
        } catch {
            guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
            systemRuntimeError = FriendlyError.message(error); throw error
        }
    }

    func systemActionAccess(_ function: String) async throws -> Bool {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.systemActionAccess(function)
    }

    func setRouterClock() async throws {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        try await reader.setLocaltime()
        recordActivity("时间设置请求已返回", detail: "luci.setLocaltime 已返回；实际时间需要重新读取核对。")
    }

    func syncRouterNTP() async throws {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true; defer { isMutating = false }
        try await reader.syncNTP()
        recordActivity("NTP 同步已请求", detail: "已请求 sysntpd 重启；运行中不等于已经与上游时间服务器同步。")
    }

    func homeProxyCapabilities() async throws -> HomeProxyCapabilities {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.homeProxyCapabilities()
    }

    func ddnsRuntime() async throws -> DDNSRuntimeSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return await reader.ddnsRuntime()
    }

    func ddnsLog(instanceID: String) async throws -> String {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.ddnsLog(instanceID: instanceID)
    }

    func ddnsActionAccess() async throws -> Bool {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.ddnsActionAccess()
    }

    func ddnsAction(_ action: DDNSInstanceAction, observed: ConfigurationSection, status: DDNSInstanceStatus) async throws -> RouterCommandResult {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        let generation = connectionID
        isMutating = true; defer { isMutating = false }
        let result = try await reader.ddnsAction(action, observed: observed, status: status)
        guard generation == connectionID else { throw CancellationError() }
        recordActivity("DDNS 实例操作已返回", detail: observed.id + "：" + action.title + "。注册 IP、更新结果和日志仍需重读核对。", isWarning: result.exitCode != 0)
        return result
    }

    func nativePluginRead(_ request: NativePluginRead) async throws -> String {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.nativePluginRead(request)
    }

    func wakeOnLAN() async throws -> WakeOnLANSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = await reader.wakeOnLAN()
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func sqmRuntime() async throws -> SQMRuntimeSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = await reader.sqmRuntime()
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func sqmKernel() async throws -> SQMKernelSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = try await reader.sqmKernel()
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func sqmText(_ request: SQMReadRequest) async throws -> String {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let value = try await reader.sqmText(request)
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func sendWakeOnLAN(sectionID: String, tool: WakeOnLANTool, observed: RouterConfiguration, connection: UUID) async throws -> RouterCommandResult {
        try requireMaintenanceSettled()
        guard connection == connectionID else { throw ConfigurationError.changedElsewhere }
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { if connection == connectionID { isMutating = false } }
        let result = try await reader.sendWakeOnLAN(sectionID: sectionID, tool: tool, observed: observed)
        guard connection == connectionID else { throw WakeOnLANError.uncertain("连接已变化") }
        recordActivity("WOL 发送程序已返回", detail: "退出码 \(result.exitCode)。目标设备是否开机仍需另行核对。", isWarning: result.exitCode != 0)
        return result
    }

    func upnpMappings() async throws -> [UPnPMapping] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        return try await reader.upnpMappings()
    }

    func zeroTierNetworks() async throws -> [ZeroTierNetwork] {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let result = try await reader.zeroTierNetworks()
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    func pluginServiceSnapshot(_ target: PluginServiceTarget) async throws -> PluginServiceSnapshot {
        guard let reader else { throw OpenWrtKitError.authenticationFailed }
        let generation = connectionID
        let result = await reader.pluginServiceSnapshot(target)
        guard generation == connectionID, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    func pluginServiceAction(_ target: PluginServiceTarget, action: ServiceAction, observed: RouterConfiguration, connection: UUID) async throws {
        try requireMaintenanceSettled()
        guard connection == connectionID else { throw ConfigurationError.changedElsewhere }
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { if connection == connectionID { isMutating = false } }
        try await reader.pluginServiceAction(target, action: action, observed: observed)
        guard connection == connectionID else { throw PluginServiceError.uncertain("操作后目标连接已变化") }
        recordActivity(target.title + " 服务接口已响应", detail: action.title + "；实际队列、网络授权与路由仍需分别重读核对。")
    }

    func deleteUPnPMapping(_ mapping: UPnPMapping, observed: [UPnPMapping]) async throws -> [UPnPMapping] {
        try requireMaintenanceSettled()
        guard !isMutating, pendingConfiguration == nil, let reader else { throw ConfigurationError.busy }
        isMutating = true
        defer { isMutating = false }
        let mappings = try await reader.deleteUPnPMapping(mapping, observed: observed)
        recordActivity("UPnP 映射已重新核对", detail: "删除请求后未再读取到所选端点映射；客户端仍可能重新建立。")
        return mappings
    }

    func nativePluginAction(_ action: NativePluginAction) async throws -> String {
        try requireMaintenanceSettled()
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
        try requireMaintenanceSettled()
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

    func reloadFirmwareRecordStorage() {
        guard !isMutating else { return }
        do {
            guard let data = defaults.data(forKey: firmwareRecordsKey) else {
                if firmwareRecordStorageError != nil { return } // Do not erase an unresolved in-memory failure.
                return
            }
            let decoded = try JSONDecoder().decode([String: FirmwareTaskRecord].self, from: data)
            var records: [UUID: FirmwareTaskRecord] = [:]
            for (key, value) in decoded {
                guard let id = UUID(uuidString: key) else { throw CocoaError(.fileReadCorruptFile) }
                records[id] = value
            }
            firmwareRecords = records; firmwareRecordStorageError = nil
        } catch {
            firmwareRecordStorageError = "本机维护记录无法读取，原始数据仍保留。无法确定上次请求是否完成，新的写入已暂停；请重新读取记录，勿清空数据后重复执行。"
        }
    }

    private func persistFirmwareRecords() throws {
        do {
            let values = Dictionary(uniqueKeysWithValues: firmwareRecords.map { ($0.key.uuidString, $0.value) })
            let data = try JSONEncoder().encode(values)
            defaults.set(data, forKey: firmwareRecordsKey)
            guard defaults.data(forKey: firmwareRecordsKey) == data else { throw CocoaError(.fileWriteUnknown) }
            firmwareRecordStorageError = nil
        } catch {
            firmwareRecordStorageError = "本机维护记录保存失败，新的写入已暂停。请保留当前 App 数据并核对路由器状态。"
            throw FirmwareMaintenanceError.failed(firmwareRecordStorageError!)
        }
    }

    private func requireMaintenanceSettled() throws {
        if let firmwareRecordStorageError { throw FirmwareMaintenanceError.failed(firmwareRecordStorageError) }
        if maintenanceRequiresReconnect {
            throw FirmwareMaintenanceError.failed("上次固件维护结果尚未核对，暂不发送新的写入或控制命令。请先重新登录，再到系统 → 备份、恢复与固件 → 操作记录与重连核对读取设备信息。")
        }
    }
}
