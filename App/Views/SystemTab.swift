import SwiftUI
import UniformTypeIdentifiers
import OpenWrtKit

/// System tab (spec 3.2): low-frequency maintenance pages, all read-only
/// in phase 1. The reboot page informs; it has no action button.
struct SystemTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    private var pages: [PageDescriptor] {
        store.tabs.first { $0.tab == .system }?.pages ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                if let snapshot = store.snapshot {
                    Section {
                        SummaryBanner(summary: SummaryEngine.system(
                            uptime: snapshot.system.uptime,
                            storagePercent: snapshot.system.storageUsed.flatMap {
                                HealthRating.percent(used: $0, total: snapshot.system.storageTotal ?? 0)
                            }))
                            .summaryRow()
                    }
                }
                if pages.isEmpty {
                    EmptyStateView(title: "暂无系统页面", message: "发现完成后，这里会按这台路由器实际的系统菜单生成入口。", symbol: "gearshape.slash")
                } else {
                    Section("系统") {
                        ForEach(pages) { page in
                            NavigationLink {
                                PageDestination(page: page)
                            } label: {
                                HStack {
                                    Text(page.title).font(AppTypography.rowTitle)
                                    Spacer()
                                    if page.isGenericFallback { StatusBadge(title: "通用页") }
                                }
                            }
                        }
                    }
                }
                Section {
                    NavigationLink {
                        EventLogView()
                    } label: {
                        Label("操作记录", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("系统")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Packages (back in the system tab, per spec 3.2)

/// One pending package action awaiting its confirmation sheet —
/// shared by the packages page and the online-upgrade page
/// (package J, audit F7).
private struct PendingPackageAction: Identifiable {
    let action: PackageActionKind
    let packages: [String]
    var upgradableBefore: Int? = nil
    var id: String { action.rawValue + "|" + packages.joined(separator: ",") }

    var title: String {
        switch action {
        case .update: return L10n.string("确认刷新软件源？")
        case .install: return L10n.format("确认安装「%@」？", packages.first ?? "")
        case .remove: return L10n.format("确认卸载「%@」？", packages.first ?? "")
        case .upgrade:
            return packages.isEmpty ? L10n.string("确认更新全部可更新软件包？")
                                    : L10n.format("确认更新「%@」？", packages.first ?? "")
        }
    }

    var message: String {
        switch action {
        case .update:
            return L10n.string("从软件源重新拉取可用软件包列表，不安装或卸载任何东西。")
        case .install:
            return L10n.string("经路由器自己的包管理通道安装；其依赖会一并装上。完成后回读已安装列表验证。")
        case .remove:
            return L10n.string("卸载后依赖它的功能会立即失效；若其他软件包依赖它，路由器会拒绝并说明。完成后回读验证。")
        case .upgrade:
            return L10n.string("更新期间相关服务可能短暂重启。完成后重新检查可更新列表验证。")
        }
    }
}

/// The confirmation + execution plumbing both package pages use:
/// confirm first (package actions are real writes), run through
/// RouterStore's single gate, then show the verified outcome.
private struct PackageActionRunner: ViewModifier {
    @Environment(RouterStore.self) private var store
    @Binding var pending: PendingPackageAction?
    @Binding var working: Bool
    @Binding var feedback: String?
    @Binding var feedbackFailed: Bool
    var onFinished: (() async -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pending?.title ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button(pending?.action.eventTitle ?? "确认") {
                    if let pending { Task { await run(pending) } }
                    pending = nil
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                Text(pending?.message ?? "")
            }
    }

    private func run(_ pending: PendingPackageAction) async {
        working = true
        feedback = nil
        let result = await store.performPackageAction(
            action: pending.action, packages: pending.packages,
            upgradableBefore: pending.upgradableBefore)
        working = false
        feedback = result.detail
        feedbackFailed = result.isFailure
        await onFinished?()
    }
}

struct PackagesView: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""
    @State private var installName = ""
    @State private var pending: PendingPackageAction?
    @State private var working = false
    @State private var feedback: String?
    @State private var feedbackFailed = false

    private var filtered: [InstalledPackage] {
        let packages = store.inventory.packages
        guard !query.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if store.inventory.packagesRead {
                Section {
                    SummaryBanner(summary: SummaryEngine.packages(installed: store.inventory.packages.count))
                        .summaryRow()
                }
                Section {
                    HStack {
                        TextField("输入要安装的软件包名", text: $installName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("安装") {
                            let name = installName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard PackageNameValidator.isValid(name) else {
                                feedback = "包名不合法：只能含字母、数字和 - _ . +，且须以字母或数字开头。"
                                feedbackFailed = true
                                return
                            }
                            pending = PendingPackageAction(action: .install, packages: [name])
                        }
                        .disabled(installName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                    Button {
                        pending = PendingPackageAction(action: .update, packages: [])
                    } label: {
                        Label("刷新软件源", systemImage: "arrow.clockwise")
                    }
                    .disabled(working)
                    if working {
                        HStack { ProgressView(); Text("正在执行，包管理操作可能需要一两分钟…") }
                    }
                    if let feedback {
                        Text(feedback).font(AppTypography.secondary)
                            .foregroundStyle(feedbackFailed ? AppPalette.red : AppPalette.muted)
                    }
                } footer: {
                    Text("安装与卸载走路由器自己的包管理通道（与电脑版软件包页相同），执行后回读列表验证；更新软件包在「在线升级」页逐个或全部进行。")
                }
            }
            AppSearchField(prompt: "搜索软件包", text: $query)
                .listRowInsets(EdgeInsets())
            if !store.inventory.packagesRead {
                EmptyStateView(title: "软件包列表未读取", message: "路由器未返回已安装软件包清单。", symbol: "shippingbox.slash")
            } else if filtered.isEmpty {
                EmptyStateView(title: "无匹配软件包", message: "没有名称包含「\(query)」的软件包。")
            } else {
                Section("已安装（\(filtered.count)）") {
                    ForEach(filtered) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(package.name).font(AppTypography.rowTitle)
                                if !package.description.isEmpty {
                                    Text(package.description).font(AppTypography.secondary)
                                        .foregroundStyle(AppPalette.muted).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(package.version).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("卸载", role: .destructive) {
                                pending = PendingPackageAction(action: .remove, packages: [package.name])
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("软件包")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(PackageActionRunner(pending: $pending, working: $working,
                                      feedback: $feedback, feedbackFailed: $feedbackFailed))
    }
}

// MARK: - Startup items

/// Autostart toggles with the same discipline as the service page
/// (audit U1): every swipe goes behind a confirmation, the outcome
/// is echoed on the page, and failures are shown — never swallowed.
/// Core services (audit F1) cannot have their autostart turned off
/// here either; enabling stays available as the recovery direction.
struct StartupView: View {
    @Environment(RouterStore.self) private var store
    @State private var pendingToggle: PendingToggle?
    @State private var feedback: String?
    @State private var working = false

    private struct PendingToggle: Identifiable {
        let serviceName: String
        let action: ServiceAction // .enable or .disable only
        var id: String { serviceName + "/" + action.rawValue }
    }

    private var pendingTitle: String {
        guard let pendingToggle else { return "" }
        return pendingToggle.action == .disable
            ? L10n.format("确认关闭「%@」的开机自启？", pendingToggle.serviceName)
            : L10n.format("确认启用「%@」的开机自启？", pendingToggle.serviceName)
    }

    var body: some View {
        List {
            if store.inventory.initServices.isEmpty {
                EmptyStateView(title: "无启动项数据", message: "路由器未返回 init.d 服务清单。")
            } else {
                Section {
                    SummaryBanner(summary: SummaryEngine.startup(
                        enabled: store.inventory.initServices.filter { $0.enabled == true }.count,
                        total: store.inventory.initServices.count))
                        .summaryRow()
                }
                Section("init.d 服务（\(store.inventory.initServices.count)）") {
                    ForEach(store.inventory.initServices) { service in
                        HStack {
                            Text(service.name).font(AppTypography.rowTitle)
                            if ServiceProtection.isCoreService(service.name) {
                                StatusBadge(title: "核心保护")
                            }
                            Spacer()
                            StatusBadge(title: service.enabled == true ? "自启" : service.enabled == false ? "不自启" : "未知",
                                        good: service.enabled == true)
                        }
                        .swipeActions(edge: .trailing) {
                            if service.enabled == true {
                                if !ServiceProtection.isCoreService(service.name) {
                                    Button("关闭自启") {
                                        pendingToggle = PendingToggle(serviceName: service.name, action: .disable)
                                    }
                                }
                            } else if service.enabled == false {
                                Button("启用自启") {
                                    pendingToggle = PendingToggle(serviceName: service.name, action: .enable)
                                }
                                .tint(AppPalette.accent)
                            }
                        }
                    }
                }
                if working {
                    Section { HStack { ProgressView(); Text("正在执行…") } }
                }
                if let feedback {
                    Section {
                        Text(feedback).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
            }
            Section {
                Text("滑动可开关普通服务的开机自启，操作前会再次确认。核心服务（如 rpcd、network、dnsmasq）的关闭自启已禁用：关掉它们可能让你同时失去手机与电脑的管理通道。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        .navigationTitle("启动项")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(get: { pendingToggle != nil }, set: { if !$0 { pendingToggle = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingToggle?.action.title ?? "确认") {
                if let toggle = pendingToggle { Task { await run(toggle) } }
                pendingToggle = nil
            }
            Button("取消", role: .cancel) { pendingToggle = nil }
        } message: {
            if let pendingToggle {
                Text(pendingToggle.action == .disable
                     ? L10n.string("关闭后，该服务不再随开机自动启动；当前正在运行的服务不会被停止。")
                     : L10n.string("开启后，该服务会在路由器每次开机时自动启动。"))
            }
        }
    }

    private func run(_ toggle: PendingToggle) async {
        working = true
        defer { working = false }
        do {
            try await store.performServiceAction(name: toggle.serviceName, action: toggle.action)
            feedback = L10n.format("已执行%@，状态已重新读取。", toggle.action.title)
        } catch {
            feedback = FriendlyError.message(error)
        }
    }
}

// MARK: - Crontab

struct CrontabView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<String> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取计划任务…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EmptyStateView(title: "暂无计划任务", message: "root 的 crontab 为空。", symbol: "calendar.badge.clock")
                } else {
                    let entries = CronHumanizer.entries(in: text)
                    Section {
                        SummaryBanner(summary: SummaryEngine.crontab(entries: entries.count))
                            .summaryRow()
                    }
                    if entries.isEmpty {
                        EmptyStateView(title: "没有可识别的计划任务", message: "文件里只有注释或环境设置，原文在下方原始数据中。", symbol: "calendar.badge.clock")
                    } else {
                        Section {
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(entry.schedule).font(AppTypography.rowTitle)
                                    Text(entry.command).font(AppTypography.secondary)
                                        .foregroundStyle(AppPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } header: {
                            TermLabel(text: "计划任务", term: "计划任务")
                        }
                    }
                    RawDataSection {
                        Text(text).font(AppTypography.metadata.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("计划任务")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        // A missing crontab file means "no jobs", not a read failure
        // (audit U9): distinguish by listing the directory rather
        // than trusting error codes. Every other failure — permission
        // denied, transport, a read that errors — is a real failure
        // state with a retry, never a fake empty page.
        if let entries = try? await client.fileList(path: "/etc/crontabs"),
           !entries.contains(where: { $0["name"].stringValue == "root" }) {
            state = .loaded("")
            return
        }
        do { state = .loaded(try await client.fileRead(path: "/etc/crontabs/root")) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Mounts

struct MountsView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<[JSONValue]> = .loading

    var body: some View {
        List {
            if let snapshot = store.snapshot, let total = snapshot.system.storageTotal {
                if let percent = snapshot.system.storageUsed.flatMap({ HealthRating.percent(used: $0, total: total) }) {
                    Section {
                        SummaryBanner(summary: SummaryEngine.storage(percent: percent))
                            .summaryRow()
                    }
                }
                Section("根文件系统") {
                    LabeledContent("已用", value: FormatHelpers.bytes(snapshot.system.storageUsed ?? 0))
                    LabeledContent("总计", value: FormatHelpers.bytes(total))
                    if let percent = snapshot.system.storageUsed.flatMap({ HealthRating.percent(used: $0, total: total) }) {
                        RatedRow(title: "占用", value: String(format: "%.0f%%", percent),
                                 grade: HealthRating.usageGrade(percent: percent))
                    }
                }
            }
            switch state {
            case .loading:
                ProgressView("正在读取挂载点…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let mounts):
                Section {
                    if mounts.isEmpty {
                        EmptyStateView(title: "无挂载数据", message: "路由器未返回挂载点列表。")
                    } else {
                        ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(mount["mountpoint"].stringValue ?? mount["target"].stringValue ?? "—")
                                    .font(AppTypography.rowTitle)
                                Text("\(mount["device"].stringValue ?? "") · \(mount["fstype"].stringValue ?? "")")
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                } header: {
                    TermLabel(text: "挂载点", term: "挂载点")
                }
            }
        }
        .navigationTitle("挂载点")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do { state = .loaded(try await store.records(.mounts)) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Online upgrade (read-only in phases 1-2, spec section 6)

struct OnlineUpgradeView: View {
    @Environment(RouterStore.self) private var store
    /// The check's outcome: a result from the router's package
    /// manager, or nil when the router has no usable manager at
    /// all — presented as "cannot check", never as "no updates"
    /// (audit F2).
    @State private var state: LoadState<UpgradablePackages?> = .loading
    @State private var pending: PendingPackageAction?
    @State private var working = false
    @State private var feedback: String?
    @State private var feedbackFailed = false

    var body: some View {
        List {
            Section("当前版本") {
                if let firmware = store.capability?.firmware {
                    LabeledContent("发行版", value: firmware.distribution ?? "—")
                    LabeledContent("版本", value: firmware.version ?? "—")
                    if let revision = firmware.revision { LabeledContent("修订", value: revision) }
                    if let target = firmware.target { LabeledContent("目标平台", value: target) }
                } else if let snapshot = store.snapshot {
                    LabeledContent("固件", value: snapshot.system.firmware)
                }
                TermLabel(text: "固件", term: "固件")
            }
            switch state {
            case .loading:
                ProgressView("正在检查可更新软件包…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let check):
                Section("可更新软件包") {
                    if let check {
                        LabeledContent("包管理器", value: check.manager.displayName)
                        if check.lines.isEmpty {
                            EmptyStateView(title: "暂无可更新项", message: "已向路由器查询，当前没有可更新的软件包（列表未刷新时以路由器为准）。", symbol: "checkmark.circle")
                        } else {
                            Button {
                                pending = PendingPackageAction(action: .upgrade, packages: [],
                                                               upgradableBefore: check.lines.count)
                            } label: {
                                Label("全部更新（\(check.lines.count)）", systemImage: "arrow.up.circle")
                            }
                            .disabled(working)
                            ForEach(check.lines, id: \.self) { line in
                                HStack {
                                    Text(line).font(AppTypography.secondary)
                                    Spacer()
                                    if let name = UpgradableNameExtractor.packageName(
                                        inLine: line, installed: store.inventory.packages.map(\.name)) {
                                        Button("更新") {
                                            pending = PendingPackageAction(action: .upgrade, packages: [name])
                                        }
                                        .disabled(working)
                                    }
                                }
                            }
                            if working {
                                HStack { ProgressView(); Text("正在更新，服务可能短暂重启…") }
                            }
                            if let feedback {
                                Text(feedback).font(AppTypography.secondary)
                                    .foregroundStyle(feedbackFailed ? AppPalette.red : AppPalette.muted)
                            }
                        }
                    } else {
                        EmptyStateView(title: "无法检查更新", message: "这台路由器未检测到可用的软件包管理器（opkg 或 apk），App 无法为它检查更新。", symbol: "questionmark.circle")
                    }
                }
            }
            Section {
                Text("在线升级为高风险操作：下方入口严格执行加强事务——自动备份 → 镜像哈希校验 → 镜像合法性校验 → 二次确认 → 升级 → 自动重连验证，缺一不可。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
            FirmwareUpgradeSection()
        }
        .navigationTitle("在线升级")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .modifier(PackageActionRunner(pending: $pending, working: $working,
                                      feedback: $feedback, feedbackFailed: $feedbackFailed,
                                      onFinished: { await load() }))
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        // The kit detects opkg vs apk and reports "no manager" as
        // nil; a detected manager whose query fails throws, so the
        // page shows a true failure state with retry (audit F2).
        do { state = .loaded(try await client.upgradablePackages()) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}

// MARK: - Backup & restore (package C, item 1)
//
// The artefact is OpenWrt's own sysupgrade tar.gz — created and
// restored over the ubus file plane, interchangeable with LuCI's
// flash page. Restore follows the L4 discipline: preview + diff,
// an explicit confirmation that states the overwrite, an automatic
// on-router snapshot of the current configuration before anything
// is applied, byte-verified staging, then reboot + reconnection
// verification. Every outcome lands in the operation record.

struct BackupRestoreView: View {
    @Environment(RouterStore.self) private var store
    @State private var library = BackupLibraryStore()
    @State private var isCreating = false
    @State private var showingImporter = false
    @State private var statusText: String?
    @State private var errorText: String?

    private var routerID: String? { store.activeProfile?.id.uuidString }

    var body: some View {
        List {
            Section("当前固件") {
                if let snapshot = store.snapshot {
                    LabeledContent("固件", value: snapshot.system.firmware)
                    LabeledContent("机型", value: snapshot.system.model)
                }
                LabeledContent("配置文件数", value: "\(store.inventory.configNames.count)")
            }
            Section("备份") {
                Button {
                    Task { await createBackup() }
                } label: {
                    Label("创建配置备份", systemImage: "arrow.down.doc")
                }
                .disabled(isCreating || store.activeProfile == nil)
                Button {
                    showingImporter = true
                } label: {
                    Label("导入备份文件", systemImage: "square.and.arrow.down")
                }
                Text("备份是 OpenWrt 官方 sysupgrade 格式（含全部配置），与 LuCI 的备份互通。备份文件包含路由器完整配置，只保存在本机；请像对待密码一样保管导出的文件。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                if isCreating {
                    HStack { ProgressView(); Text("正在生成并下载备份…") }
                }
                if let statusText {
                    Label(L10n.key(statusText), systemImage: "checkmark.circle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.green)
                }
                if let errorText {
                    Label(L10n.key(errorText), systemImage: "exclamationmark.triangle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
            }
            if !library.entries.isEmpty {
                Section("已保存的备份") {
                    ForEach(library.entries) { entry in
                        NavigationLink {
                            RestorePreviewView(entry: entry, library: library)
                        } label: {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(entry.fileName).font(AppTypography.rowTitle).lineLimit(1)
                                Text("\(entry.addedAt.formatted(date: .abbreviated, time: .shortened)) · \(FormatHelpers.bytes(Int64(entry.byteCount)))")
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                if let manifest = entry.manifest {
                                    Text("来自 \(manifest.routerName)：\(manifest.configs.count) 个配置、\(manifest.totalSections) 个配置节")
                                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                } else {
                                    Text("外部导入，无配置清单")
                                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                library.remove(entry)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            ShareLink(item: entry.fileURL) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("备份与更新")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.gzip, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    do {
                        try library.importBackup(from: url)
                        statusText = L10n.string("备份已导入。")
                        errorText = nil
                    } catch {
                        errorText = FriendlyError.message(error)
                    }
                }
            case .failure(let error):
                errorText = FriendlyError.message(error)
            }
        }
    }

    private func createBackup() async {
        guard let profile = store.activeProfile, let files = store.fileClient else { return }
        isCreating = true
        statusText = nil
        errorText = nil
        defer { isCreating = false }
        RouterTaskActivityController.shared.start(
            routerName: profile.name, taskTitle: L10n.string("创建配置备份"),
            phase: L10n.string("正在生成并下载备份…"))
        do {
            if store.snapshot == nil { await store.refresh() }
            let operations = BackupRestoreFlow.standardOperations(files: files)
            let created = try await BackupRestoreFlow.createBackup(operations: operations)
            var configEntries: [BackupManifest.ConfigEntry] = []
            if let client = store.readClient {
                let names = (try? await client.configurationNames()) ?? []
                for name in names {
                    let configuration = try? await store.configuration(name)
                    configEntries.append(.init(name: name, sectionCount: configuration?.sections.count ?? 0))
                }
            }
            let manifest = BackupManifest(
                createdAt: Date(), routerID: profile.id.uuidString,
                routerName: profile.name, address: profile.address,
                model: store.snapshot?.system.model,
                firmware: store.snapshot?.system.firmware,
                sha256: created.sha256, byteCount: created.data.count,
                configs: configEntries)
            let fileName = BackupFileNaming.fileName(routerName: profile.name, at: manifest.createdAt)
            try library.save(data: created.data, manifest: manifest, fileName: fileName)
            statusText = L10n.format("备份已保存：%@", fileName)
            RouterTaskActivityController.shared.finish(
                phase: L10n.string("备份已保存到本机。"), succeeded: true)
            EventLogStore.shared.append(
                category: .operation, kind: .backupRestore,
                title: L10n.string("创建配置备份"),
                detail: L10n.format("%@（%@，%lld 个配置）", fileName,
                                    FormatHelpers.bytes(Int64(created.data.count)), configEntries.count),
                routerID: routerID)
        } catch {
            errorText = FriendlyError.message(error)
            RouterTaskActivityController.shared.finish(
                phase: L10n.string("备份创建失败。"), succeeded: false)
            EventLogStore.shared.append(
                category: .operation, kind: .backupRestore,
                title: L10n.string("创建配置备份失败"),
                detail: FriendlyError.message(error), routerID: routerID)
        }
    }
}

/// Restore preview + execution for one library entry. The diff is
/// name-level (backup inventory vs the router's current configs) —
/// shown before the confirmation, never after the fact.
struct RestorePreviewView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: BackupEntry
    let library: BackupLibraryStore

    @State private var currentNames: [String]?
    @State private var confirming = false
    @State private var phase: RestorePhase = .idle
    @State private var resultText: String?

    private enum RestorePhase: Equatable {
        case idle, running(String), succeeded(String), failed(String)
    }

    private var isRunning: Bool { if case .running = phase { return true }; return false }

    private var diff: BackupDiff? {
        guard let manifest = entry.manifest, let currentNames else { return nil }
        return BackupDiff.diff(manifest: manifest, currentConfigNames: currentNames)
    }

    var body: some View {
        List {
            Section("备份信息") {
                LabeledContent("文件", value: entry.fileName)
                LabeledContent("大小", value: FormatHelpers.bytes(Int64(entry.byteCount)))
                LabeledContent("时间", value: entry.addedAt.formatted(date: .abbreviated, time: .standard))
                if let manifest = entry.manifest {
                    LabeledContent("来源路由器", value: manifest.routerName)
                    if let model = manifest.model { LabeledContent("机型", value: model) }
                    if let firmware = manifest.firmware { LabeledContent("固件", value: firmware) }
                    LabeledContent("SHA-256", value: String(manifest.sha256.prefix(16)) + "…")
                } else {
                    Text("这份备份由外部导入，没有配置清单可预览。恢复将按文件内容整体覆盖，请只恢复你信任来源的备份。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
            if let manifest = entry.manifest {
                Section("包含的配置（\(manifest.configs.count)）") {
                    ForEach(manifest.configs, id: \.name) { config in
                        HStack {
                            Text(config.name).font(AppTypography.row)
                            Spacer()
                            Text("\(config.sectionCount) 节").font(AppTypography.metadata)
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
            if let diff {
                Section("与当前配置的差异") {
                    if !diff.onlyInBackup.isEmpty {
                        LabeledContent("备份独有", value: diff.onlyInBackup.joined(separator: "、"))
                    }
                    LabeledContent("两边都有", value: "\(diff.inBoth.count) 个")
                    if !diff.onlyInCurrent.isEmpty {
                        LabeledContent("当前独有", value: diff.onlyInCurrent.joined(separator: "、"))
                    }
                    Text("恢复后，备份包含的配置以备份为准；当前独有的配置可能被移除或保留，取决于路由器恢复机制对未包含文件的处理。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            } else if entry.manifest != nil {
                Section {
                    HStack { ProgressView(); Text("正在读取当前配置清单…") }
                }
            }
            Section {
                Button("恢复这份备份", role: .destructive) { confirming = true }
                    .disabled(isRunning || store.activeProfile == nil
                              || store.isMutating || store.pendingConfiguration != nil)
                switch phase {
                case .idle:
                    EmptyView()
                case .running(let text):
                    HStack { ProgressView(); Text(L10n.key(text)) }
                case .succeeded(let text):
                    Label(L10n.key(text), systemImage: "checkmark.circle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.green)
                case .failed(let text):
                    Label(L10n.key(text), systemImage: "exclamationmark.triangle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
                if let resultText {
                    Text(L10n.key(resultText)).font(AppTypography.secondary)
                        .foregroundStyle(AppPalette.muted)
                }
            } footer: {
                Text("恢复会覆盖路由器当前配置并重启。开始前 App 会先在路由器上自动备份当前配置，万一恢复有问题，可用那份快照再恢复回来。")
                    .font(AppTypography.metadata)
            }
        }
        .navigationTitle("恢复备份")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if entry.manifest != nil, currentNames == nil {
                currentNames = (try? await store.readClient?.configurationNames()) ?? []
            }
        }
        .confirmationDialog("确定要恢复这份备份吗？", isPresented: $confirming, titleVisibility: .visible) {
            Button("恢复并重启", role: .destructive) { Task { await runRestore() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("路由器当前配置将被这份备份覆盖，全家网络会中断数分钟。恢复前会自动备份当前配置到路由器 /tmp 目录。")
        }
    }

    private func runRestore() async {
        guard let profile = store.activeProfile, let files = store.fileClient else { return }
        resultText = nil
        RouterTaskActivityController.shared.start(
            routerName: profile.name, taskTitle: L10n.string("恢复配置备份"),
            phase: L10n.string("正在备份当前配置…"))
        do {
            let data = try library.data(for: entry)
            var operations = BackupRestoreFlow.standardOperations(files: files)
            let delayBox = ProbeDelayBox()
            operations.reboot = { try await store.rebootRouter() }
            operations.probeReconnect = { await store.probeRouterReachable() }
            operations.probeDelay = {
                // First probe waits out the shutdown so a still-up
                // old session is not mistaken for recovery.
                let first = delayBox.nextIsFirst()
                try? await Task.sleep(for: .seconds(first ? 20 : 10))
            }
            let result = try await BackupRestoreFlow.restore(
                backupData: data, fileName: entry.fileName, confirmed: true,
                operations: operations,
                onStep: { step in
                    Task { @MainActor in
                        if let text = Self.stepText(step) {
                            phase = .running(text)
                            RouterTaskActivityController.shared.update(phase: text)
                        }
                    }
                })
            if result.reconnected {
                phase = .succeeded(L10n.string("恢复完成，路由器已重新连接。"))
                RouterTaskActivityController.shared.finish(
                    phase: L10n.string("恢复完成，路由器已重新连接。"), succeeded: true)
                await store.refresh()
            } else {
                phase = .failed(L10n.string("恢复已执行，但等待超时后路由器仍未恢复连接。请检查电源与网络后手动刷新。"))
                RouterTaskActivityController.shared.finish(
                    phase: L10n.string("恢复已执行，但路由器仍未恢复连接。"), succeeded: false)
            }
            resultText = L10n.format("恢复前的当前配置已备份在路由器：%@", result.preRestoreSnapshotPath)
            EventLogStore.shared.append(
                category: .operation, kind: .backupRestore,
                title: result.reconnected ? L10n.string("恢复配置备份") : L10n.string("恢复后未重新连接"),
                detail: L10n.format("%@；恢复前快照：%@", entry.fileName, result.preRestoreSnapshotPath),
                routerID: profile.id.uuidString)
        } catch {
            phase = .failed(FriendlyError.message(error))
            RouterTaskActivityController.shared.finish(
                phase: L10n.string("恢复失败。"), succeeded: false)
            EventLogStore.shared.append(
                category: .operation, kind: .backupRestore,
                title: L10n.string("恢复配置备份失败"),
                detail: FriendlyError.message(error),
                routerID: profile.id.uuidString)
        }
    }

    private static func stepText(_ step: BackupRestoreFlow.Step) -> String? {
        switch step {
        case .snapshottingCurrent: return L10n.string("正在备份当前配置…")
        case .uploading: return L10n.string("正在上传备份到路由器…")
        case .verifyingUpload: return L10n.string("正在校验上传完整性…")
        case .restoring: return L10n.string("正在执行恢复…")
        case .rebooting: return L10n.string("正在重启路由器…")
        case .reconnectVerification: return L10n.string("正在等待路由器恢复…")
        case .succeeded, .failed: return nil
        }
    }
}

/// First-probe delay bookkeeping for the restore wait: the first
/// delay is the long one (router still going down), later delays
/// are the poll cadence.
private final class ProbeDelayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func nextIsFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - Reboot (information only in phase 1)

struct RebootInfoView: View {
    @Environment(RouterStore.self) private var store
    @State private var stage = 0 // 0 idle, 1 first confirm, 2 final confirm, 3 sent
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Label("重启会中断全屋网络连接，持续数分钟。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppPalette.orange)
            }
            Section("设备") {
                if let snapshot = store.snapshot {
                    LabeledContent("机型", value: snapshot.system.model)
                    if let uptime = snapshot.system.uptime {
                        LabeledContent("已运行", value: FormatHelpers.uptime(uptime))
                    }
                }
            }
            Section {
                if stage == 3 {
                    Label("重启指令已发送，连接即将中断。", systemImage: "checkmark.circle")
                        .foregroundStyle(AppPalette.green)
                } else {
                    Button("重启路由器", role: .destructive) { stage = 1 }
                        .disabled(store.isMutating)
                }
                if let error {
                    Text(error).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
            }
        }
        .navigationTitle("重启")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定要重启这台路由器吗？", isPresented: Binding(
            get: { stage == 1 }, set: { if !$0 { stage = 0 } }), titleVisibility: .visible) {
            Button("继续", role: .destructive) { stage = 2 }
            Button("取消", role: .cancel) { stage = 0 }
        } message: {
            Text("全屋网络将中断数分钟，正在进行的连接会断开。")
        }
        .alert("最后确认：现在重启？", isPresented: Binding(
            get: { stage == 2 }, set: { if !$0 { stage = 0 } })) {
            Button("立即重启", role: .destructive) { Task { await reboot() } }
            Button("取消", role: .cancel) { stage = 0 }
        }
    }

    private func reboot() async {
        do {
            try await store.rebootRouter()
            stage = 3
        } catch {
            // A dropped connection while the router goes down is the
            // expected shape of success here; other errors are shown.
            if error is URLError {
                stage = 3
            } else {
                self.error = FriendlyError.message(error)
                stage = 0
            }
        }
    }
}


/// The strengthened upgrade flow (spec section 6), driven by
/// UpgradeFlow's two halves: prepare() runs backup/staging/hash/image
/// validation; only after the user confirms a second time does finish()
/// flash and verify reconnection. The button cannot skip steps because
/// finish() requires prepare()'s output plus the explicit flag.
private struct FirmwareUpgradeSection: View {
    @Environment(RouterStore.self) private var store
    @State private var pickerPresented = false
    @State private var imageData: Data?
    @State private var imageName: String?
    @State private var step: UpgradeFlow.Step?
    @State private var prepared: (backupPath: String, digest: String)?
    @State private var working = false
    @State private var secondConfirmation = false
    @State private var outcome: String?

    var body: some View {
        Section("固件升级（加强事务）") {
            if let imageName {
                LabeledContent("镜像", value: imageName)
                if let imageData {
                    LabeledContent("本地 SHA-256", value: SHA256Hasher.hexDigest(imageData))
                        .font(AppTypography.metadata)
                }
            }
            Button {
                pickerPresented = true
            } label: {
                Label("选择固件镜像", systemImage: "doc.badge.plus")
            }
            .disabled(working || prepared != nil)
            if let step {
                Label(stepText(step), systemImage: step == .succeeded ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(AppTypography.secondary)
                    .foregroundStyle(step == .succeeded ? AppPalette.green : AppPalette.muted)
            }
            if prepared == nil {
                Button("开始：备份并校验镜像") { Task { await prepare() } }
                    .disabled(imageData == nil || working)
            } else if !secondConfirmation {
                Text("备份与校验已完成。再次确认后将真正执行升级——升级期间全屋断网，路由器自动重启。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                Button("二次确认：执行升级", role: .destructive) {
                    secondConfirmation = true
                    Task { await finish() }
                }
                .disabled(working)
                // A way out that is not "leave the page" (audit
                // U18): cancelling undoes nothing on the router —
                // the upgrade never ran — and the auto-backup stays.
                Button("取消本次升级") {
                    prepared = nil
                    step = nil
                    outcome = L10n.string("已取消本次升级：路由器未执行任何更改，此前自动生成的备份仍保留在路由器上。")
                }
                .disabled(working)
            }
            if let outcome {
                Text(outcome).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $pickerPresented,
                      allowedContentTypes: [.data]) { result in
            if case .success(let url) = result,
               url.startAccessingSecurityScopedResource(),
               let data = try? Data(contentsOf: url) {
                imageData = data
                imageName = url.lastPathComponent
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func operations() -> UpgradeFlow.Operations? {
        guard let files = store.fileClient else { return nil }
        var operations = UpgradeFlow.standardOperations(files: files)
        operations.probeReconnect = {
            try? await Task.sleep(for: .seconds(10))
            return await store.probeRouterReachable()
        }
        return operations
    }

    private func prepare() async {
        guard let imageData, let operations = operations() else { return }
        working = true
        defer { working = false }
        do {
            let result = try await UpgradeFlow.prepare(image: imageData, operations: operations) { newStep in
                Task { @MainActor in step = newStep }
            }
            prepared = (result.backupPath, result.imageSHA256)
            outcome = "备份已保存至 \(result.backupPath)；镜像哈希与路由器端一致，镜像合法性校验通过。"
        } catch {
            step = .failed(FriendlyError.message(error))
            outcome = "已中止：\(FriendlyError.message(error))。路由器未做任何更改。"
        }
    }

    private func finish() async {
        guard let operations = operations() else { return }
        working = true
        defer { working = false }
        RouterTaskActivityController.shared.start(
            routerName: store.activeProfile?.name ?? L10n.string("路由器"),
            taskTitle: L10n.string("固件升级"),
            phase: stepText(.upgrading))
        do {
            let reconnected = try await UpgradeFlow.finish(
                secondConfirmation: secondConfirmation, operations: operations) { newStep in
                Task { @MainActor in
                    step = newStep
                    RouterTaskActivityController.shared.update(phase: stepText(newStep))
                }
            }
            outcome = reconnected
                ? "升级完成，路由器已重新连接并通过验证。"
                : "升级已执行，但自动重连验证未在预期时间内通过，请稍后手动刷新核对。"
            RouterTaskActivityController.shared.finish(
                phase: reconnected ? stepText(.succeeded) : L10n.string("升级已执行，但路由器仍未恢复连接。"),
                succeeded: reconnected)
            if reconnected { await store.refresh() }
        } catch {
            step = .failed(FriendlyError.message(error))
            outcome = FriendlyError.message(error)
            RouterTaskActivityController.shared.finish(
                phase: L10n.string("升级失败。"), succeeded: false)
        }
    }

    private func stepText(_ step: UpgradeFlow.Step) -> String {
        switch step {
        case .backup: return "正在自动备份当前配置…"
        case .staging: return "正在上传镜像到路由器…"
        case .hashVerification: return "正在校验镜像哈希…"
        case .imageValidation: return "正在校验镜像合法性…"
        case .awaitingSecondConfirmation: return "等待二次确认"
        case .upgrading: return "正在执行升级，路由器将重启…"
        case .reconnectVerification: return "正在验证重新连接…"
        case .succeeded: return "升级完成并已重连"
        case .failed(let message): return "失败：\(message)"
        }
    }
}
