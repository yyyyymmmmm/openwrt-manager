import SwiftUI
import UniformTypeIdentifiers
import OpenWrtKit

struct FirmwareMaintenanceView: View {
    @Environment(RouterStore.self) private var store
    @State private var capabilities: FirmwareCapabilities?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "配置备份与恢复") {
                AppGroup {
                    NavigationLink { FirmwareBackupView() } label: {
                        AppRow(title: "备份与导出", detail: "文件清单、生成备份与保存到文件", symbol: "arrow.down.doc", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("firmware-backup")
                    AppDivider()
                    NavigationLink { RouterTextFileView(file: .sysupgradeFiles) } label: {
                        AppRow(title: "备份文件设置", detail: "额外保留的文件与目录", symbol: "doc.text", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("firmware-backup-settings")
                    AppDivider()
                    NavigationLink { FirmwareImportView(kind: .backup) } label: {
                        AppRow(title: "恢复配置", detail: "选择备份、检查归档、确认恢复", symbol: "arrow.up.doc", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("firmware-restore")
                }
            }
            AppSection(title: "固件维护") {
                AppGroup {
                    NavigationLink { FirmwareImportView(kind: .firmware) } label: {
                        AppRow(title: "刷写固件", detail: "选择镜像、校验与升级选项", symbol: "internaldrive", chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("firmware-upgrade")
                    AppDivider()
                    NavigationLink { FirmwareFactoryResetView() } label: {
                        AppRow(title: "恢复出厂配置", detail: "清除可写配置并重启", symbol: "arrow.counterclockwise", chevron: true, destructive: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("firmware-reset")
                }
            }
            if store.firmwareRecord != nil || store.firmwareRecordStorageError != nil {
                AppSection(title: "最近维护") {
                    AppGroup {
                        NavigationLink { FirmwareOperationStatusView() } label: {
                            AppRow(title: "操作记录与重连核对", detail: store.maintenanceRequiresReconnect ? "结果待核对，请勿重复操作" : "查看实际返回与重连信息", symbol: "clock.arrow.circlepath", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("firmware-operation-status")
                    }
                }
            }
            AppSection(title: "当前固件能力") {
                if loading { ProgressView("正在读取平台与账户权限…") }
                if let capabilities { FirmwareCapabilityRows(value: capabilities) }
                if let error { Text(error).foregroundStyle(AppPalette.red).font(AppTypography.secondary) }
                Button("重新读取能力") { Task { await load() } }
                    .disabled(loading || store.isMutating || store.maintenanceRequiresReconnect)
            }
        }.appDetailStyle("备份、恢复与固件").tint(AppPalette.accent)
            .task(id: store.connectionID) { await load() }
    }
    private func load() async {
        guard !loading else { return }
        let generation = store.connectionID
        loading = true; error = nil; capabilities = nil
        defer { loading = false }
        do { let value = try await store.firmwareCapabilities(); if generation == store.connectionID { capabilities = value } }
        catch { if generation == store.connectionID { self.error = store.maintenanceRequiresReconnect ? "上次维护尚未核对，请进入操作记录重新连接。" : FriendlyError.message(error) } }
    }
}

private struct FirmwareCapabilityRows: View {
    let value: FirmwareCapabilities
    var body: some View {
        AppGroup {
            AppRow(title: "sysupgrade 平台", value: state(value.sysupgrade))
            AppDivider(inset: 12)
            AppRow(title: "可写配置分区", value: state(value.overlay))
            AppDivider(inset: 12)
            AppRow(title: "存储容量估计", value: value.storageSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "未能确定")
            ForEach([("backup", "下载备份"), ("upload", "上传文件"), ("validate", "镜像校验"), ("exec", "执行维护命令")], id: \.0) { item in
                AppDivider(inset: 12)
                AppRow(title: item.1 + "权限", value: value.permissions[item.0].map { $0 ? "允许" : "拒绝" } ?? "未知")
            }
        }
        Text("容量仅为固件分区信息的估计。命令、文件路径权限与镜像适配会在实际操作前再次核对。")
            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        ForEach(value.issues.keys.sorted(), id: \.self) { key in
            Text(key + "：" + (value.issues[key] ?? "")).font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
        }
    }
    private func state(_ value: Bool?) -> String { value.map { $0 ? "已确认" : "未提供" } ?? "未能确定" }
}

private struct ConfigurationBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gzip] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct FirmwareBackupView: View {
    @Environment(RouterStore.self) private var store
    @State private var listing: RouterCommandResult?
    @State private var document: ConfigurationBackupDocument?
    @State private var size: Int?
    @State private var digest: String?
    @State private var error: String?
    @State private var message: String?
    @State private var loading = false
    @State private var exporting = false
    @State private var connection: UUID?
    @State private var exportConnection: UUID?
    private var busy: Bool { loading || store.isMutating || store.maintenanceRequiresReconnect || store.pendingConfiguration != nil }
    var body: some View {
        List {
            Section {
                Text("下载路由器当前配置归档，可能包含 Wi-Fi 密码、密钥及账户设置。请保存到你信任的位置。")
                Button("生成并下载备份", systemImage: "arrow.down.doc") { Task { await download() } }
                    .disabled(busy).accessibilityIdentifier("firmware-backup-download")
                if loading { ProgressView("正在读取路由器…") }
                if let size { LabeledContent("下载大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)) }
                if let digest { FirmwareDigestView(value: digest) }
                if document != nil {
                    Button("保存到文件", systemImage: "square.and.arrow.up") { exportConnection = store.connectionID; exporting = true }
                        .disabled(loading).accessibilityIdentifier("firmware-backup-export")
                    Text("下载文件的 gzip 压缩流及校验已核对。接口没有提供来源签名；这不证明内容可信或适用于另一台路由器。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            } header: { Text("配置备份") }
            Section("将备份的文件") {
                Button("读取备份清单") { Task { await readList() } }.disabled(busy)
                    .accessibilityIdentifier("firmware-backup-list")
                if let listing {
                    NavigationLink("查看完整清单与输出") { FirmwareCommandOutputView(title: "备份清单", result: listing) }
                        .accessibilityIdentifier("firmware-backup-list-detail")
                    if listing.exitCode != 0 { Text("读取失败，退出码 \(listing.exitCode)").foregroundStyle(AppPalette.red) }
                }
                NavigationLink("额外备份文件设置") { RouterTextFileView(file: .sysupgradeFiles) }
            }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            if let message { Section { Text(message) } }
            FirmwarePendingSection()
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("备份与导出")
            .onChange(of: store.connectionID, initial: true) { _, value in
                connection = value; exporting = false; document = nil; size = nil; digest = nil; listing = nil; error = nil; message = nil
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .gzip, defaultFilename: "openwrt-backup.tar.gz") { result in
                guard exportConnection == store.connectionID else { return }
                switch result {
                case .success: message = "备份已导出到所选位置。"
                case .failure(let failure): error = FriendlyError.message(failure)
                }
            }
    }
    private func readList() async {
        guard !busy else { return }
        loading = true; error = nil
        let generation = store.connectionID
        defer { loading = false }
        do { let value = try await store.configurationBackupList(); if generation == store.connectionID { listing = value } }
        catch { if generation == store.connectionID { self.error = FriendlyError.message(error) } }
    }
    private func download() async {
        guard !busy, let connection, connection == store.connectionID else { return }
        loading = true; error = nil; message = nil; document = nil; size = nil; digest = nil
        defer { loading = false }
        do {
            let value = try await store.downloadConfigurationBackup(connection: connection)
            defer { try? FileManager.default.removeItem(at: value.fileURL) }
            guard connection == store.connectionID else { return }
            document = try ConfigurationBackupDocument(data: Data(contentsOf: value.fileURL, options: .mappedIfSafe))
            size = value.size; digest = value.sha256
        } catch { if connection == store.connectionID { self.error = FriendlyError.message(error) } }
    }
}

private struct FirmwareImportView: View {
    @Environment(RouterStore.self) private var store
    let kind: FirmwareFileKind
    @State private var picker = false
    @State private var pickerConnection: UUID?
    @State private var connection: UUID?
    @State private var capabilities: FirmwareCapabilities?
    @State private var upload: FirmwareUpload?
    @State private var inspection: BackupInspection?
    @State private var validation: FirmwareValidation?
    @State private var loading = false
    @State private var stage = ""
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var keepSettings = false
    @State private var force = false
    @State private var skipUnchanged = false
    @State private var packageList = false
    private var busy: Bool { loading || store.isMutating || store.maintenanceRequiresReconnect || store.pendingConfiguration != nil }
    private var uploadAllowed: Bool {
        capabilities?.permissions["upload"] == true && capabilities?.permissions[kind == .backup ? "backupPath" : "firmwarePath"] == true
            && (kind == .backup || capabilities?.sysupgrade == true)
    }
    private var request: FirmwareMaintenanceRequest? {
        if kind == .backup, let inspection { return .restore(inspection) }
        if kind == .firmware, let validation, !validation.needsForce || (force && validation.forceable) {
            return .upgrade(validation, .init(keepSettings: keepSettings, force: force, skipUnchanged: skipUnchanged, packageList: packageList))
        }
        return nil
    }
    var body: some View {
        Form {
            Section {
                Text(kind == .backup ? "选择由 OpenWrt 生成的 tar.gz 配置备份。恢复会覆盖配置并重启，地址及密码可能变化。" : "选择适合此设备的 sysupgrade 镜像。文件上传完成后还需校验和明确确认，才会请求刷写。")
                Button("选择" + kind.title, systemImage: "doc.badge.plus") { pickerConnection = store.connectionID; picker = true }
                    .disabled(busy || !uploadAllowed || upload != nil).accessibilityIdentifier("firmware-import-file")
                if loading { ProgressView(stage) }
                if !loading && !uploadAllowed { Text("当前尚未确认上传权限或平台能力，请查看能力信息。登录权限不足时不能继续。").foregroundStyle(AppPalette.orange) }
                if let upload {
                    LabeledContent("文件", value: upload.originalFilename)
                    LabeledContent("本机与远端大小", value: ByteCountFormatter.string(fromByteCount: Int64(upload.size), countStyle: .binary))
                    FirmwareDigestView(value: upload.sha256)
                    Text("本机与上传接口返回的 SHA-256 一致。摘要一致不等于镜像适用于此设备。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    Button("重新校验暂存文件") { Task { await inspect() } }.disabled(busy)
                        .accessibilityIdentifier("firmware-import-recheck")
                    Button("删除暂存文件并重新选择", role: .destructive) { confirmDelete = true }.disabled(busy)
                        .accessibilityIdentifier("firmware-import-discard")
                }
            } header: { Text("文件上传") } footer: {
                Text("上传会替换路由器上本操作的暂存文件，请勿与其他管理员同时操作。返回上页不会执行恢复或刷写，也不会自动删除远端暂存文件。")
            }
            if let inspection {
                Section("恢复前检查") {
                    NavigationLink("归档文件清单与原始输出") { FirmwareCommandOutputView(title: "归档检查", result: inspection.listing) }
                        .accessibilityIdentifier("firmware-archive-detail")
                    Text("固件能够列出归档，清单未发现绝对路径或上级目录。此检查不验证链接目标、归档来源或设备兼容性；仅恢复你信任的备份。恢复没有自动回滚。")
                }
            }
            if let validation { firmwareOptions(validation) }
            if let request, let connection {
                Section {
                    NavigationLink { FirmwareConfirmView(request: request, connection: connection) } label: {
                        Label("查看操作预览", systemImage: "list.bullet.clipboard")
                    }.disabled(busy).accessibilityIdentifier("firmware-operation-preview")
                }
            }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            Section("能力与权限") {
                if let capabilities { FirmwareCapabilityRows(value: capabilities) }
                Button("重新读取能力") { Task { await readCapabilities() } }.disabled(busy)
            }
            FirmwarePendingSection()
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(kind == .backup ? "恢复配置" : "刷写固件")
            .task(id: store.connectionID) {
                if connection != store.connectionID {
                    connection = store.connectionID; picker = false; upload = nil; inspection = nil; validation = nil; capabilities = nil; error = nil
                }
                await readCapabilities()
            }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                guard let selectedConnection = pickerConnection, selectedConnection == store.connectionID else {
                    error = "选择文件期间路由器连接已变化，未上传文件。请重新选择目标并导入。"
                    return
                }
                switch result {
                case .success(let urls): if let url = urls.first { Task { await send(url, connection: selectedConnection) } }
                case .failure(let failure): error = FriendlyError.message(failure)
                }
            }
            .confirmationDialog("删除本次上传的暂存文件？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除暂存文件", role: .destructive) { Task { await discard() } }
                Button("取消", role: .cancel) {}
            } message: { Text("会先核对远端文件的大小与摘要，不删除其他文件。") }
    }
    @ViewBuilder private func firmwareOptions(_ value: FirmwareValidation) -> some View {
        Section("镜像校验") {
            LabeledContent("平台格式校验", value: value.valid ? "通过" : "未通过")
            LabeledContent("sysupgrade 检查退出码", value: String(value.test.exitCode))
            LabeledContent("允许保留配置", value: value.allowBackup ? "是" : "否")
            if value.tooLarge { Text("镜像大于当前估计的存储容量。").foregroundStyle(AppPalette.red) }
            if value.storageSize == nil { Text("无法确定存储容量，不能据此确认镜像大小合适。").foregroundStyle(AppPalette.orange) }
            NavigationLink("校验详情与原始输出") { FirmwareValidationDetailsView(validation: value) }
                .accessibilityIdentifier("firmware-validation-detail")
        }
        Section("升级选项") {
            Toggle("保留当前配置", isOn: $keepSettings).disabled(!value.allowBackup || busy)
                .accessibilityIdentifier("firmware-keep-settings")
                .onChange(of: keepSettings) { _, selected in if !selected { skipUnchanged = false; packageList = false } }
            Toggle("跳过与 /rom 相同的文件", isOn: $skipUnchanged).disabled(!keepSettings || capabilities?.overlay != true || busy)
                .accessibilityIdentifier("firmware-skip-unchanged")
            Toggle("备份已安装软件包名称清单", isOn: $packageList).disabled(!keepSettings || busy)
                .accessibilityIdentifier("firmware-package-list")
            Text("软件包清单不会备份软件包本体，也不会在升级后自动安装。未保留配置时，管理地址和密码可能恢复为固件默认值。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            if value.needsForce {
                if value.forceable {
                    Toggle("明确强制升级", isOn: $force).disabled(busy).tint(AppPalette.red)
                        .accessibilityIdentifier("firmware-force")
                    Text("固件允许强制继续，但当前校验未全部通过。只有已经确认镜像适配此设备时才使用，错误镜像可能使设备无法启动。")
                        .foregroundStyle(AppPalette.red)
                } else { Text("固件不允许强制继续，不能刷写此镜像。").foregroundStyle(AppPalette.red) }
            }
        }
    }
    private func readCapabilities() async {
        guard !busy else { return }
        loading = true; stage = "正在读取能力…"
        let generation = store.connectionID
        defer { loading = false }
        do { let value = try await store.firmwareCapabilities(); if generation == store.connectionID { capabilities = value } }
        catch { if generation == store.connectionID { self.error = FriendlyError.message(error) } }
    }
    private func send(_ url: URL, connection: UUID) async {
        guard connection == store.connectionID else { error = "目标连接已变化，未上传。请重新选择文件。"; return }
        guard !busy, upload == nil else { return }
        loading = true; stage = "正在准备并上传文件，请保持 App 在前台…"; error = nil
        defer { loading = false }
        do {
            let value = try await store.uploadMaintenanceFile(url, kind: kind, connection: connection)
            guard connection == store.connectionID else { return }
            upload = value; stage = "正在核对暂存文件与固件校验…"
            try await inspectUpload(value, connection: connection)
        } catch { if connection == store.connectionID { self.error = FriendlyError.message(error) } }
    }
    private func inspect() async {
        guard !busy, let upload, let connection, connection == store.connectionID else { return }
        loading = true; stage = "正在重新校验…"; error = nil; inspection = nil; validation = nil
        defer { loading = false }
        do { try await inspectUpload(upload, connection: connection) }
        catch { if connection == store.connectionID { self.error = FriendlyError.message(error) } }
    }
    private func inspectUpload(_ value: FirmwareUpload, connection: UUID) async throws {
        if kind == .backup {
            let result = try await store.inspectConfigurationBackup(value, connection: connection)
            guard connection == store.connectionID else { return }
            inspection = result
        } else {
            let result = try await store.validateFirmware(value, connection: connection)
            guard connection == store.connectionID else { return }
            validation = result; keepSettings = result.allowBackup; force = false; skipUnchanged = false; packageList = false
        }
    }
    private func discard() async {
        guard !busy, let upload, let connection, connection == store.connectionID else { return }
        loading = true; stage = "正在核对并删除暂存文件…"; error = nil
        defer { loading = false }
        do {
            try await store.discardMaintenanceFile(upload, connection: connection)
            guard connection == store.connectionID else { return }
            self.upload = nil; inspection = nil; validation = nil
        } catch { if connection == store.connectionID { self.error = FriendlyError.message(error) } }
    }
}

private struct FirmwareFactoryResetView: View {
    @Environment(RouterStore.self) private var store
    @State private var capabilities: FirmwareCapabilities?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        List {
            Section {
                Text("将清除可写配置并重启。网络、账户密码、插件配置及可写分区中的安装内容可能丢失；固件镜像本身不会回退到旧版本。")
                NavigationLink("先备份当前配置") { FirmwareBackupView() }
                if loading { ProgressView("正在读取重置能力…") }
                if let capabilities { FirmwareCapabilityRows(value: capabilities) }
                if let error { Text(error).foregroundStyle(AppPalette.red) }
                Button("重新读取能力") { Task { await load() } }.disabled(loading || store.isMutating || store.maintenanceRequiresReconnect)
                NavigationLink { FirmwareConfirmView(request: .reset, connection: store.connectionID) } label: { Text("查看出厂重置预览").foregroundStyle(AppPalette.red) }
                    .disabled(capabilities?.overlay != true || loading || store.isMutating || store.maintenanceRequiresReconnect || store.pendingConfiguration != nil)
                    .accessibilityIdentifier("firmware-reset-preview")
            }
            FirmwarePendingSection()
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("恢复出厂配置")
            .task(id: store.connectionID) { await load() }
    }
    private func load() async {
        guard !loading else { return }
        let generation = store.connectionID
        loading = true; capabilities = nil; error = nil
        defer { loading = false }
        do { let value = try await store.firmwareCapabilities(); if generation == store.connectionID { capabilities = value } }
        catch { if generation == store.connectionID { self.error = FriendlyError.message(error) } }
    }
}

private struct FirmwareConfirmView: View {
    @Environment(RouterStore.self) private var store
    let request: FirmwareMaintenanceRequest
    let connection: UUID
    @State private var acknowledged = false
    @State private var confirming = false
    @State private var running = false
    @State private var attempted = false
    @State private var error: String?
    var body: some View {
        List {
            Section("操作目标") {
                LabeledContent("路由器", value: store.activeProfile?.name ?? "未连接")
                LabeledContent("地址", value: store.activeProfile?.address ?? "未连接")
                LabeledContent("当前固件", value: store.snapshot?.system.firmware ?? "尚未读取")
                Text(request.title).font(AppTypography.rowTitle)
                preview
            }
            Section {
                Text("操作前会复核权限、未提交配置与文件摘要。恢复、刷写和重置没有 App 自动回滚；执行期间不要断电，也不要由其他管理员同时修改。请保持 App 在前台。")
                Toggle("已核对目标、文件和备份，理解断连风险", isOn: $acknowledged)
                    .disabled(running || attempted).accessibilityIdentifier("firmware-confirm-acknowledge")
                Button("确认" + request.title, role: .destructive) { confirming = true }
                    .disabled(!acknowledged || attempted || running || store.isMutating || store.pendingConfiguration != nil || store.maintenanceRequiresReconnect || connection != store.connectionID)
                    .accessibilityIdentifier("firmware-confirm-action")
                if running { ProgressView("正在复核并发送维护请求…") }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                if attempted && !running && store.firmwareRecord == nil { Text("本次尝试已结束。若需继续，请返回文件页重新核对，不会自动再次执行。") }
            }
            if store.firmwareRecord != nil {
                Section { NavigationLink("查看请求结果与重连步骤") { FirmwareOperationStatusView() }.accessibilityIdentifier("firmware-confirm-result") }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("维护操作预览")
            .confirmationDialog(request.title + "？", isPresented: $confirming, titleVisibility: .visible) {
                Button("执行" + request.title, role: .destructive) { Task { await perform() } }
                Button("取消", role: .cancel) {}
            } message: { Text("这将对当前路由器执行真实维护命令。断线不表示失败，不能重复执行。") }
    }
    @ViewBuilder private var preview: some View {
        switch request {
        case .restore(let inspection):
            LabeledContent("备份", value: inspection.upload.originalFilename)
            FirmwareDigestView(value: inspection.upload.sha256)
            NavigationLink("归档文件清单") { FirmwareCommandOutputView(title: "归档检查", result: inspection.listing) }
        case .upgrade(let validation, let options):
            LabeledContent("镜像", value: validation.upload.originalFilename)
            FirmwareDigestView(value: validation.upload.sha256)
            LabeledContent("保留配置", value: options.keepSettings ? "是" : "否")
            LabeledContent("强制升级", value: options.force ? "是" : "否")
            LabeledContent("跳过未修改文件", value: options.skipUnchanged ? "是" : "否")
            LabeledContent("备份软件包清单", value: options.packageList ? "是" : "否")
        case .reset: Text("清除当前可写配置，随后路由器会重启。请先确认新管理地址和恢复登录方式。")
        }
    }
    private func perform() async {
        guard !attempted, acknowledged, connection == store.connectionID else { return }
        attempted = true; running = true; error = nil
        defer { running = false }
        do { try await store.performFirmwareMaintenance(request, connection: connection) }
        catch { self.error = FriendlyError.message(error) }
    }
}

struct FirmwareOperationStatusView: View {
    @Environment(RouterStore.self) private var store
    @State private var loading = false
    @State private var error: String?
    @State private var verified = false
    var body: some View {
        List {
            if let storageError = store.firmwareRecordStorageError {
                Section("本机记录读取或保存失败") {
                    Text(storageError).foregroundStyle(AppPalette.red)
                    Button("重新读取维护记录") { store.reloadFirmwareRecordStorage() }.disabled(store.isMutating)
                }
            }
            if let record = store.firmwareRecord {
                Section(record.title) {
                    Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                    Text(record.message).foregroundStyle(AppPalette.orange).textSelection(.enabled)
                    if let result = record.result { NavigationLink("命令原始输出") { FirmwareCommandOutputView(title: "维护请求", result: result) } }
                }
                Section("重新连接与核对") {
                    Text("等待设备完成维护；不要断电或重复提交。在路由器选择页重新登录原设备，再回到此页核对。若地址或密码已变化，请使用实际的新地址和密码，App 不猜测默认值。")
                    Button("读取重新连接后的设备信息") { Task { await recheck() } }
                        .disabled(loading || store.isMutating || record.connectionID == store.connectionID)
                        .accessibilityIdentifier("firmware-reconnect-check")
                    if record.connectionID == store.connectionID { Text("当前仍是执行前的会话，请先重新登录。").foregroundStyle(AppPalette.orange) }
                    if loading { ProgressView("正在读取当前设备…") }
                    if let error { Text(error).foregroundStyle(AppPalette.red) }
                    if let time = record.reconnectedAt {
                        LabeledContent("重连读取时间", value: time.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("设备型号", value: record.observedModel ?? "未提供")
                        LabeledContent("操作前版本", value: record.previousFirmware ?? "未提供")
                        LabeledContent("当前版本", value: record.observedFirmware ?? "未提供")
                        Text("新会话已读取设备信息。仍需核对配置、网络和插件业务；这不单独证明升级或恢复完整成功。")
                        if let verifiedAt = record.verifiedAt {
                            LabeledContent("用户完成核对", value: verifiedAt.formatted(date: .abbreviated, time: .standard))
                        } else {
                            Toggle("我已自行核对配置、网络及相关插件业务", isOn: $verified)
                                .accessibilityIdentifier("firmware-result-acknowledge")
                            Button("记录核对并恢复管理操作") {
                                do { try store.acknowledgeFirmwareVerification() }
                                catch { self.error = FriendlyError.message(error) }
                            }.disabled(!verified || loading || store.isMutating || record.connectionID == store.connectionID)
                                .accessibilityIdentifier("firmware-result-confirm")
                        }
                    }
                }
            } else { ContentUnavailableView("没有维护记录", systemImage: "clock.arrow.circlepath") }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("维护记录与重连")
            .onChange(of: store.connectionID) { _, _ in verified = false; error = nil }
    }
    private func recheck() async {
        guard !loading else { return }
        loading = true; error = nil
        let generation = store.connectionID
        defer { loading = false }
        do { try await store.readFirmwareAfterReconnect() }
        catch { if generation == store.connectionID { self.error = FriendlyError.message(error) } }
    }
}

private struct FirmwarePendingSection: View {
    @Environment(RouterStore.self) private var store
    var body: some View {
        if store.maintenanceRequiresReconnect {
            Section("上次维护待核对") {
                Text("暂不允许新的写入，请重新连接并核对上次维护结果。").foregroundStyle(AppPalette.orange)
                NavigationLink("操作记录与重连步骤") { FirmwareOperationStatusView() }
            }
        }
    }
}

private struct FirmwareDigestView: View {
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHA-256").font(AppTypography.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct FirmwareCommandOutputView: View {
    let title: String
    let result: RouterCommandResult
    var body: some View {
        List {
            Section { LabeledContent("退出码", value: String(result.exitCode)) }
            Section("标准输出") { Text(result.stdout.isEmpty ? "命令未返回标准输出" : result.stdout).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section("错误输出") { Text(result.stderr.isEmpty ? "命令未返回错误输出" : result.stderr).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(title)
    }
}

private struct FirmwareValidationDetailsView: View {
    let validation: FirmwareValidation
    private var raw: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(validation.details)).flatMap { String(data: $0, encoding: .utf8) } ?? "无法编码校验响应"
    }
    var body: some View {
        List {
            Section("平台校验响应") { Text(raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section { NavigationLink("sysupgrade 检查输出") { FirmwareCommandOutputView(title: "镜像检查", result: validation.test) } }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("固件校验详情")
    }
}
