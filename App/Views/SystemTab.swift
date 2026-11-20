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
                        ActivityListView()
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

struct PackagesView: View {
    @Environment(RouterStore.self) private var store
    @State private var query = ""

    private var filtered: [InstalledPackage] {
        let packages = store.inventory.packages
        guard !query.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
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
                    }
                }
            }
        }
        .navigationTitle("软件包")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Startup items (read-only)

struct StartupView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            if store.inventory.initServices.isEmpty {
                EmptyStateView(title: "无启动项数据", message: "路由器未返回 init.d 服务清单。")
            } else {
                Section("init.d 服务（\(store.inventory.initServices.count)）") {
                    ForEach(store.inventory.initServices) { service in
                        HStack {
                            Text(service.name).font(AppTypography.rowTitle)
                            Spacer()
                            StatusBadge(title: service.enabled == true ? "自启" : service.enabled == false ? "不自启" : "未知",
                                        good: service.enabled == true)
                        }
                        .swipeActions(edge: .trailing) {
                            if service.enabled == true {
                                Button("关闭自启") {
                                    Task { try? await store.performServiceAction(name: service.name, action: .disable) }
                                }
                            } else if service.enabled == false {
                                Button("启用自启") {
                                    Task { try? await store.performServiceAction(name: service.name, action: .enable) }
                                }
                                .tint(AppPalette.accent)
                            }
                        }
                    }
                }
            }
            Section {
                Text("启停与脚本编辑将在写操作阶段提供，本页为只读视图。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        .navigationTitle("启动项")
        .navigationBarTitleDisplayMode(.inline)
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
                    Section("/etc/crontabs/root") {
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
        do { state = .loaded(try await client.fileRead(path: "/etc/crontabs/root")) }
        catch { state = .loaded("") }
    }
}

// MARK: - Mounts

struct MountsView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<[JSONValue]> = .loading

    var body: some View {
        List {
            if let snapshot = store.snapshot, let total = snapshot.system.storageTotal {
                Section("根文件系统") {
                    LabeledContent("已用", value: FormatHelpers.bytes(snapshot.system.storageUsed ?? 0))
                    LabeledContent("总计", value: FormatHelpers.bytes(total))
                }
            }
            switch state {
            case .loading:
                ProgressView("正在读取挂载点…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let mounts):
                Section("挂载点") {
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
    @State private var state: LoadState<[String]> = .loading

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
            }
            switch state {
            case .loading:
                ProgressView("正在检查可更新软件包…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let upgradable):
                Section("可更新软件包") {
                    if upgradable.isEmpty {
                        EmptyStateView(title: "暂无可更新项", message: "按路由器现有的软件包列表，没有可更新的软件包（列表未刷新时以路由器为准）。", symbol: "checkmark.circle")
                    } else {
                        ForEach(upgradable, id: \.self) { line in
                            Text(line).font(AppTypography.secondary)
                        }
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
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        do {
            let output = try await client.exec(command: "/bin/opkg", arguments: ["list-upgradable"])
            state = .loaded(output.split(whereSeparator: \.isNewline).map(String.init))
        } catch {
            // apk-based builds have no opkg; treat as "no data" not an error.
            state = .loaded([])
        }
    }
}

// MARK: - Backup & flash (read-only)

struct BackupRestoreView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            Section("当前固件") {
                if let snapshot = store.snapshot {
                    LabeledContent("固件", value: snapshot.system.firmware)
                    LabeledContent("机型", value: snapshot.system.model)
                }
                LabeledContent("配置文件数", value: "\(store.inventory.configNames.count)")
            }
            Section {
                Text("备份生成与恢复属于高风险写操作，仍不在本页提供；配置类修改请在各配置页经事务通道完成。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        .navigationTitle("备份与更新")
        .navigationBarTitleDisplayMode(.inline)
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
        do {
            let reconnected = try await UpgradeFlow.finish(
                secondConfirmation: secondConfirmation, operations: operations) { newStep in
                Task { @MainActor in step = newStep }
            }
            outcome = reconnected
                ? "升级完成，路由器已重新连接并通过验证。"
                : "升级已执行，但自动重连验证未在预期时间内通过，请稍后手动刷新核对。"
            if reconnected { await store.refresh() }
        } catch {
            step = .failed(FriendlyError.message(error))
            outcome = FriendlyError.message(error)
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
