import SwiftUI
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
                Text("在线升级为高风险操作：本阶段仅只读展示。升级入口将在具备自动备份、镜像哈希校验与自动重连验证后开放。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
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
