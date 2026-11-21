import SwiftUI
import OpenWrtKit

/// Services tab (spec 3.3): the list is the snapshot's services — menu
/// entries intersected with init.d state, each with its real status dot.
/// Package names never appear here.
struct ServicesTabScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    private var pages: [PageDescriptor] {
        store.tabs.first { $0.tab == .services }?.pages ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouterChromeHeader(showingRouterPicker: $showingRouterPicker)
                }
                if let services = store.capability?.services, !services.isEmpty {
                    Section {
                        SummaryBanner(summary: SummaryEngine.services(
                            running: services.filter { $0.running == true }.count,
                            stopped: services.filter { $0.running == false }.count,
                            unknown: services.filter { $0.running == nil }.count))
                            .summaryRow()
                    }
                }
                if let openbox = pages.first(where: { $0.serviceKey == "openbox" }),
                   let service = store.capability?.services.first(where: { $0.key == "openbox" }) {
                    Section("Open-Box") {
                        NavigationLink {
                            PageDestination(page: openbox)
                        } label: {
                            HStack {
                                StatusDot(running: service.running)
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text("Open-Box").font(AppTypography.rowTitle)
                                    Text(service.running == true ? "内核运行中" : "查看内核与节点状态")
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                }
                Section("服务") {
                    if pages.isEmpty {
                        EmptyStateView(title: "暂无服务", message: "发现完成后，这里会列出这台路由器实际检出的服务。", symbol: "square.stack.3d.up.slash")
                    } else {
                        ForEach(pages) { page in
                            let service = store.capability?.services.first { $0.key == page.serviceKey }
                            NavigationLink {
                                PageDestination(page: page)
                            } label: {
                                HStack(spacing: AppSpacing.sm) {
                                    StatusDot(running: service?.running)
                                    Text(page.title).font(AppTypography.rowTitle)
                                    Spacer()
                                    if page.isGenericFallback { StatusBadge(title: "通用页") }
                                    Text(service?.running == true ? "运行中" : service?.running == false ? "已停止" : "未知")
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("服务")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct StatusDot: View {
    let running: Bool?

    var body: some View {
        Circle()
            .fill(running == true ? AppPalette.green : running == false ? AppPalette.red : AppPalette.muted)
            .frame(width: 9, height: 9)
            .accessibilityLabel(running == true ? "运行中" : running == false ? "已停止" : "状态未知")
    }
}

// MARK: - Open-Box dedicated page (panel API; F+ adds the panel login)

/// Panel data that only exists behind the panel's own login
/// (package F+). The password is entered here, in the app's own
/// native form — never in an embedded panel page — and the password
/// plus session cookies are kept in the Keychain only.
private struct PanelTraffic {
    var today: OpenBoxTrafficSummary
    var month: OpenBoxTrafficSummary
}

private struct PanelRules {
    var policies: [JSONValue]
    var rulesets: [(tag: String, entries: [JSONValue])]
}

struct OpenBoxView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<(OpenBoxServiceStatus, String?, [OpenBoxProxy], Int?, Bool?)> = .loading
    @State private var switchTarget: (group: String, node: String)?
    @State private var switchResult: String?

    // Panel session (F+)
    @State private var authState: OpenBoxAuthState?
    @State private var passwordInput = ""
    @State private var hasSavedPassword = false
    @State private var isLoggingIn = false
    @State private var loginError: String?
    @State private var sessionExpiredNotice = false
    @State private var sessionDead = false

    // Panel-authenticated sections (F+)
    @State private var subscriptionsState: LoadState<[OpenBoxSubscription]> = .loading
    @State private var trafficState: LoadState<PanelTraffic> = .loading
    @State private var rulesState: LoadState<PanelRules> = .loading
    @State private var qualityState: LoadState<[OpenBoxNodeQuality]> = .loading
    @State private var pendingAction: PanelAction?
    @State private var actionMessage: String?
    @State private var newSubName = ""
    @State private var newSubURL = ""
    @State private var editDraft: OpenBoxSubscription?

    private var isLoggedIn: Bool { authState?.authenticated == true }

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取 Open-Box…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let (status, version, proxies, connections, authenticated)):
                Section {
                    SummaryBanner(summary: SummaryEngine.openBox(
                        coreRunning: status.coreRunning, groups: proxies.count))
                        .summaryRow()
                }
                Section("内核与面板") {
                    LabeledContent("内核", value: status.coreRunning.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    LabeledContent("面板", value: status.panelRunning.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    if let version { LabeledContent("内核版本", value: version) }
                    if let connections {
                        LabeledContent("当前连接数", value: String(connections))
                    }
                    LabeledContent("面板登录", value: authenticated.map { $0 ? L10n.string("已登录") : L10n.string("未登录") } ?? L10n.string("未知"))
                    if status.needsRestart == true {
                        Label("有待重启生效的变更", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.orange)
                    }
                }
                Section("代理组与节点") {
                    if proxies.isEmpty {
                        EmptyStateView(title: "无代理数据", message: "面板未返回代理组信息。")
                    } else {
                        ForEach(proxies) { proxy in
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(proxy.name).font(AppTypography.rowTitle)
                                    Text(proxy.type).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                }
                                Spacer()
                                Text(proxy.current ?? "—").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                if proxy.members.count > 1, proxy.current != nil {
                                    Menu {
                                        ForEach(proxy.members, id: \.self) { member in
                                            Button(member) {
                                                switchTarget = (group: proxy.name, node: member)
                                            }
                                            .disabled(member == proxy.current)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.left.arrow.right.circle")
                                    }
                                    .accessibilityLabel("切换 \(proxy.name) 的节点")
                                }
                            }
                        }
                        if let switchResult {
                            Text(switchResult).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
            panelSessionSection
            if isLoggedIn {
                subscriptionsSection
                trafficSection
                rulesSection
                qualitySection
            }
            if let service = store.capability?.services.first(where: { $0.key == "openbox" }) {
                Section("路由器侧状态") {
                    LabeledContent("init.d", value: service.initNames.joined(separator: L10n.string("、")))
                    LabeledContent("开机自启", value: service.enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
                }
                Section("路由器侧配置") {
                    NavigationLink {
                        UCIConfigView(title: "Open-Box 配置", configNames: ["openbox"])
                    } label: {
                        Label("路由器侧配置（openbox）", systemImage: "list.bullet.rectangle")
                    }
                }
                if let core = service.initNames.first(where: { $0 == "openbox" }) ?? service.initNames.first {
                    ServiceActionsSection(serviceName: core)
                }
            }
        }
        .navigationTitle("Open-Box")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editDraft) { subscription in
            OpenBoxSubscriptionEditor(subscription: subscription) { name, url, enabled in
                await saveEdit(subscription, name: name, url: url, enabled: enabled)
            }
        }
        .confirmationDialog(
            switchTarget.map { "将「\($0.group)」切换到节点「\($0.node)」？" } ?? "",
            isPresented: Binding(get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("确认切换") {
                if let target = switchTarget { Task { await performSwitch(target) } }
                switchTarget = nil
            }
            Button("取消", role: .cancel) { switchTarget = nil }
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                    pendingAction = nil
                    Task { await perform(action) }
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        }
    }

    // MARK: Panel session

    @ViewBuilder
    private var panelSessionSection: some View {
        Section("面板登录") {
            if isLoggedIn {
                LabeledContent("面板登录", value: L10n.string("已登录"))
                Text("订阅、流量、规则与节点质量已在下方显示。面板密码与会话只保存在这台设备的钥匙串里。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                Button("退出登录") { logout() }
            } else {
                if sessionExpiredNotice {
                    Label("面板会话已失效，请重新登录。", systemImage: "exclamationmark.triangle")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                }
                SecureField("Open-Box 面板密码", text: $passwordInput)
                Button {
                    Task { await performLogin(password: passwordInput) }
                } label: {
                    if isLoggingIn { ProgressView() } else { Text("登录面板") }
                }
                .disabled(passwordInput.isEmpty || isLoggingIn)
                if hasSavedPassword {
                    Button("使用已保存的密码登录") { Task { await loginWithSavedPassword() } }
                        .disabled(isLoggingIn)
                    Button("清除已保存的面板密码", role: .destructive) { forgetSavedPassword() }
                }
                if let loginError {
                    Text(loginError).font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
                Text("面板密码与路由器登录密码不同。在这里输入后，密码保存在钥匙串中，下次打开自动恢复面板会话；不会写进日志或诊断导出。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
    }

    // MARK: Subscriptions

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section("订阅") {
            switch subscriptionsState {
            case .loading:
                ProgressView("正在读取订阅…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await reloadSubscriptions() } }
            case .loaded(let subscriptions):
                if subscriptions.isEmpty {
                    EmptyStateView(title: "暂无订阅", message: "在下方添加第一个订阅。")
                }
                ForEach(subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack {
                            Text(subscription.name).font(AppTypography.rowTitle)
                            Spacer()
                            if let enabled = subscription.enabled {
                                Text(enabled ? "已启用" : "已停用")
                                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                            }
                        }
                        HStack(spacing: AppSpacing.sm) {
                            if let nodeCount = subscription.nodeCount {
                                Text(L10n.format("%lld 个节点", nodeCount))
                            }
                            if let updatedAt = subscription.updatedAt {
                                Text(updatedAt)
                            }
                        }
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        HStack(spacing: AppSpacing.lg) {
                            Button("刷新") { pendingAction = .refresh(subscription) }
                            Button("编辑") { editDraft = subscription }
                            Button("删除", role: .destructive) { pendingAction = .delete(subscription) }
                        }
                        .font(AppTypography.secondary)
                    }
                }
                if subscriptions.count > 1 {
                    Button("全部刷新") { pendingAction = .refreshAll }
                }
                if let actionMessage {
                    Text(actionMessage).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
        }
        Section("添加订阅") {
            TextField("订阅名称", text: $newSubName)
            TextField("订阅链接", text: $newSubURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加订阅") {
                pendingAction = .create(name: newSubName, url: newSubURL)
            }
            .disabled(newSubName.trimmingCharacters(in: .whitespaces).isEmpty
                      || newSubURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Traffic

    @ViewBuilder
    private var trafficSection: some View {
        Section("流量统计") {
            switch trafficState {
            case .loading:
                ProgressView("正在读取流量…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await loadPanelData() } }
            case .loaded(let traffic):
                LabeledContent("今日上传", value: bytesText(traffic.today.displayUp))
                LabeledContent("今日下载", value: bytesText(traffic.today.displayDown))
                LabeledContent("本月上传", value: bytesText(traffic.month.displayUp))
                LabeledContent("本月下载", value: bytesText(traffic.month.displayDown))
                if !traffic.today.rows.isEmpty {
                    Text("今日流量最高")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    ForEach(traffic.today.rows.prefix(5), id: \.key) { row in
                        HStack {
                            Text(row.key).font(AppTypography.secondary).lineLimit(1)
                            Spacer()
                            Text("↑ \(bytesText(row.up)) · ↓ \(bytesText(row.down))")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
        }
        if case .loaded(let traffic) = trafficState {
            RawDataSection(title: "流量原始数据") {
                Text(rawText(traffic.today.raw))
                    .font(.caption.monospaced()).foregroundStyle(AppPalette.muted)
            }
        }
    }

    // MARK: Rules & policies

    @ViewBuilder
    private var rulesSection: some View {
        Section("规则与策略") {
            switch rulesState {
            case .loading:
                ProgressView("正在读取规则…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await loadPanelData() } }
            case .loaded(let rules):
                if rules.policies.isEmpty && rules.rulesets.isEmpty {
                    EmptyStateView(title: "暂无规则数据", message: "面板未返回策略条目。")
                }
                if !rules.policies.isEmpty {
                    Text("策略条目")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    ForEach(Array(rules.policies.enumerated()), id: \.offset) { _, entry in
                        entryRow(entry)
                    }
                }
                ForEach(rules.rulesets, id: \.tag) { group in
                    Text(L10n.format("规则集 %@", group.tag))
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    ForEach(Array(group.entries.prefix(30).enumerated()), id: \.offset) { _, entry in
                        entryRow(entry)
                    }
                }
                if rules.rulesets.isEmpty && !rules.policies.isEmpty {
                    Text("面板没有给出规则集索引，本页只展示策略条目。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(OpenBoxParser.entryTitle(entry) ?? L10n.string("条目"))
                .font(AppTypography.secondary).lineLimit(2)
            let hints = [entry["type"].stringValue, entry["action"].stringValue,
                         entry["proxy"].stringValue, entry["outbound"].stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !hints.isEmpty {
                Text(hints.joined(separator: " · "))
                    .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            }
        }
    }

    // MARK: Node quality

    @ViewBuilder
    private var qualitySection: some View {
        Section("节点质量") {
            switch qualityState {
            case .loading:
                ProgressView("正在读取节点质量…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await loadPanelData() } }
            case .loaded(let nodes):
                if nodes.isEmpty {
                    EmptyStateView(title: "暂无质量数据", message: "面板尚未给出节点质量结果，可以触发一次测速。")
                }
                ForEach(nodes, id: \.name) { node in
                    HStack {
                        Text(node.name).font(AppTypography.secondary).lineLimit(1)
                        Spacer()
                        if let latency = node.latencyMilliseconds {
                            Text(L10n.format("%lld ms", Int64(latency.rounded())))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                        if let score = node.score {
                            Text(L10n.format("评分 %lld", Int64(score.rounded())))
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
                Button("重新测速") { pendingAction = .latency }
            }
        }
    }

    // MARK: Panel actions

    private enum PanelAction: Identifiable {
        case refresh(OpenBoxSubscription)
        case delete(OpenBoxSubscription)
        case create(name: String, url: String)
        case refreshAll
        case latency

        var id: String {
            switch self {
            case .refresh(let sub): return "refresh-\(sub.id)"
            case .delete(let sub): return "delete-\(sub.id)"
            case .create: return "create"
            case .refreshAll: return "refresh-all"
            case .latency: return "latency"
            }
        }

        var isDestructive: Bool {
            if case .delete = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .refresh(let sub): return L10n.format("刷新订阅「%@」？", sub.name)
            case .delete(let sub): return L10n.format("删除订阅「%@」？", sub.name)
            case .create(let name, _): return L10n.format("添加订阅「%@」？", name)
            case .refreshAll: return L10n.string("刷新全部订阅？")
            case .latency: return L10n.string("重新测量全部节点延迟？")
            }
        }

        var confirmLabel: String {
            switch self {
            case .refresh: return L10n.string("确认刷新")
            case .delete: return L10n.string("确认删除")
            case .create: return L10n.string("确认添加")
            case .refreshAll: return L10n.string("确认刷新")
            case .latency: return L10n.string("开始测速")
            }
        }
    }

    private func perform(_ action: PanelAction) async {
        guard let client = panelClient() else { return }
        actionMessage = nil
        do {
            switch action {
            case .refresh(let subscription):
                let outcome = try await client.refreshSubscription(id: subscription.id)
                var message = outcome.changed == true
                    ? L10n.format("订阅「%@」已刷新，节点有变化。", subscription.name)
                    : L10n.format("订阅「%@」已刷新，节点无变化。", subscription.name)
                if !outcome.skipped.isEmpty {
                    message += L10n.format("跳过 %lld 个无效节点。", outcome.skipped.count)
                }
                actionMessage = message
                recordOperation("刷新订阅", detail: message)
                await reloadSubscriptions()
            case .delete(let subscription):
                try await client.deleteSubscription(id: subscription.id)
                actionMessage = L10n.format("订阅「%@」已删除。", subscription.name)
                recordOperation("删除订阅", detail: actionMessage ?? "")
                await reloadSubscriptions()
            case .create(let name, let url):
                try await client.createSubscription(name: name, url: url)
                actionMessage = L10n.format("订阅「%@」已添加。", name)
                recordOperation("添加订阅", detail: actionMessage ?? "")
                newSubName = ""; newSubURL = ""
                await reloadSubscriptions()
            case .refreshAll:
                guard case .loaded(let subscriptions) = subscriptionsState else { return }
                var changedCount = 0
                for subscription in subscriptions {
                    if try await client.refreshSubscription(id: subscription.id).changed == true {
                        changedCount += 1
                    }
                }
                actionMessage = L10n.format("全部订阅已刷新，%lld 个有变化。", changedCount)
                recordOperation("刷新全部订阅", detail: actionMessage ?? "")
                await reloadSubscriptions()
            case .latency:
                try await client.triggerNodeLatency()
                recordOperation("节点测速", detail: L10n.string("已请面板重新测量节点延迟。"))
                try? await Task.sleep(for: .seconds(3))
                await reloadQuality()
            }
        } catch {
            if isSessionFailure(error) {
                expireSession()
            } else {
                actionMessage = FriendlyError.message(error)
            }
        }
    }

    private func saveEdit(_ subscription: OpenBoxSubscription, name: String, url: String,
                          enabled: Bool) async -> Bool {
        guard let client = panelClient() else { return false }
        do {
            try await client.updateSubscription(id: subscription.id, name: name, url: url, enabled: enabled)
            recordOperation("编辑订阅", detail: L10n.format("订阅「%@」已更新。", name))
            await reloadSubscriptions()
            return true
        } catch {
            if isSessionFailure(error) { expireSession() }
            actionMessage = FriendlyError.message(error)
            return false
        }
    }

    /// Operation-log entries carry the subscription NAME only — a
    /// subscription URL is a credential in practice and never lands
    /// in the log (which is mirrored into diagnostics exports).
    private func recordOperation(_ title: String, detail: String) {
        EventLogStore.shared.append(category: .operation, kind: .operation,
                                    title: L10n.string(title), detail: detail,
                                    routerID: store.activeProfile?.id.uuidString)
    }

    // MARK: Loading

    private func performSwitch(_ target: (group: String, node: String)) async {
        guard let client = panelClient() else { return }
        do {
            try await client.selectProxy(group: target.group, node: target.node)
            // Verify by re-reading the group state before claiming success.
            let proxies = try await client.proxies()
            if proxies.first(where: { $0.name == target.group })?.current == target.node {
                switchResult = "已切换：\(target.group) → \(target.node)（回读确认）。"
            } else {
                switchResult = "已下发切换，但回读的当前节点与目标不一致，请核对。"
            }
            await load()
        } catch {
            switchResult = FriendlyError.message(error)
        }
    }

    private func panelClient() -> OpenBoxPanelClient? {
        guard let host = store.activeProfile.flatMap({ URL(string: $0.address)?.host }) else { return nil }
        return OpenBoxPanelClient(host: host)
    }

    private func savedPanelCredential() -> PanelCredential? {
        guard let id = store.activeProfile?.id else { return nil }
        return try? PanelCredentialStore().read(id: id)
    }

    private func load() async {
        guard let client = panelClient() else { state = .failed("无法确定路由器地址。"); return }
        state = .loading
        // Restore the Keychain-kept panel session before any call.
        if let saved = savedPanelCredential() {
            hasSavedPassword = saved.password != nil
            if !saved.cookies.isEmpty {
                client.restoreSessionCookies(saved.cookies.map { (name: $0.name, value: $0.value) })
            }
        }
        do {
            async let status = client.serviceStatus()
            async let version = client.kernelVersion()
            async let proxies = client.proxies()
            let loaded = (try await status, try await version, try await proxies)
            // Best-effort extras: a missing connections or auth-status
            // answer never fails the page.
            let connections = try? await client.connectionCount()
            if let panelAuth = try? await client.authState() {
                authState = panelAuth
            }
            state = .loaded((loaded.0, loaded.1, loaded.2, connections ?? nil, authState?.authenticated))
        } catch let error as OpenWrtKitError where error == .permissionDenied {
            state = .failed("面板需要登录后才能读取数据。")
        } catch {
            state = .failed(FriendlyError.message(error))
        }
        if isLoggedIn { await loadPanelData() }
    }

    private func loadPanelData() async {
        guard let client = panelClient(), isLoggedIn, !sessionDead else { return }
        subscriptionsState = .loading
        trafficState = .loading
        rulesState = .loading
        qualityState = .loading
        async let subs = client.subscriptions()
        async let day = client.trafficDay(day: panelDay(Date()))
        async let month = client.trafficMonth(month: panelMonth(Date()))
        async let pols = client.policyEntries()
        async let qual = client.nodeQuality()
        do { subscriptionsState = .loaded(try await subs) }
        catch { subscriptionsState = .failed(panelFailure(error)) }
        do {
            trafficState = .loaded(PanelTraffic(today: try await day, month: try await month))
        } catch { trafficState = .failed(panelFailure(error)) }
        do {
            let policies = try await pols
            var groups: [(tag: String, entries: [JSONValue])] = []
            for tag in harvestRulesetTags(policies).prefix(3) {
                if let entries = try? await client.rulesetEntries(tag: tag) {
                    groups.append((tag: tag, entries: entries))
                }
            }
            rulesState = .loaded(PanelRules(policies: policies, rulesets: groups))
        } catch { rulesState = .failed(panelFailure(error)) }
        do { qualityState = .loaded(try await qual) }
        catch { qualityState = .failed(panelFailure(error)) }
    }

    private func reloadSubscriptions() async {
        guard let client = panelClient(), isLoggedIn, !sessionDead else { return }
        do { subscriptionsState = .loaded(try await client.subscriptions()) }
        catch { subscriptionsState = .failed(panelFailure(error)) }
    }

    private func reloadQuality() async {
        guard let client = panelClient(), isLoggedIn, !sessionDead else { return }
        do { qualityState = .loaded(try await client.nodeQuality()) }
        catch { qualityState = .failed(panelFailure(error)) }
    }

    /// Ruleset entries need a tag; the panel exposes no ruleset index
    /// endpoint, so tags are harvested from the policy entries
    /// themselves. No tags, no ruleset section — stated on the page.
    private func harvestRulesetTags(_ policies: [JSONValue]) -> [String] {
        var tags: [String] = []
        for entry in policies {
            for key in ["tag", "ruleset", "ruleSet", "rule_set"] {
                if let tag = entry[key].stringValue, !tag.isEmpty, !tags.contains(tag) {
                    tags.append(tag)
                }
            }
        }
        return tags
    }

    // MARK: Session lifecycle

    private func isSessionFailure(_ error: Error) -> Bool {
        (error as? OpenWrtKitError) == .permissionDenied
    }

    private func panelFailure(_ error: Error) -> String {
        if isSessionFailure(error) {
            expireSession()
            return L10n.string("面板会话已失效，请重新登录。")
        }
        return FriendlyError.message(error)
    }

    /// A dead panel session drops the page back to the login form
    /// exactly once — the saved token is forgotten, the saved
    /// password stays for a one-tap re-login, and nothing retries.
    private func expireSession() {
        guard !sessionDead else { return }
        sessionDead = true
        panelClient()?.clearSessionCookies()
        if let id = store.activeProfile?.id, var saved = savedPanelCredential() {
            saved.cookies = []
            try? PanelCredentialStore().save(saved, id: id)
        }
        authState = OpenBoxAuthState(enabled: authState?.enabled, authenticated: false,
                                     passwordSet: authState?.passwordSet)
        sessionExpiredNotice = true
        AppDiagnostics.record(.session, "Open-Box 面板会话已失效")
    }

    private func performLogin(password: String) async {
        guard let client = panelClient(), !password.isEmpty else { return }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            let result = try await client.loginReturningState(password: password)
            if let id = store.activeProfile?.id {
                let credential = PanelCredential(
                    password: password,
                    cookies: client.sessionCookies().map { PanelCookie(name: $0.name, value: $0.value) })
                try? PanelCredentialStore().save(credential, id: id)
            }
            hasSavedPassword = true
            passwordInput = ""
            sessionDead = false
            sessionExpiredNotice = false
            authState = OpenBoxAuthState(enabled: result.enabled,
                                         authenticated: result.authenticated ?? true,
                                         passwordSet: result.passwordSet ?? true)
            AppDiagnostics.record(.session, "Open-Box 面板已登录")
            await loadPanelData()
        } catch OpenBoxPanelError.invalidPassword {
            loginError = L10n.string("面板密码不正确，请重新输入。")
        } catch let error as OpenWrtKitError where error == .permissionDenied {
            loginError = L10n.string("面板密码不正确，请重新输入。")
        } catch {
            loginError = L10n.format("连不上 Open-Box 面板：%@", FriendlyError.message(error))
        }
    }

    private func loginWithSavedPassword() async {
        guard let password = savedPanelCredential()?.password else { return }
        await performLogin(password: password)
    }

    private func logout() {
        panelClient()?.clearSessionCookies()
        if let id = store.activeProfile?.id, var saved = savedPanelCredential() {
            saved.cookies = []
            try? PanelCredentialStore().save(saved, id: id)
        }
        authState = OpenBoxAuthState(enabled: authState?.enabled, authenticated: false,
                                     passwordSet: authState?.passwordSet)
        AppDiagnostics.record(.session, "Open-Box 面板已退出登录")
    }

    private func forgetSavedPassword() {
        if let id = store.activeProfile?.id {
            try? PanelCredentialStore().delete(id: id)
        }
        panelClient()?.clearSessionCookies()
        hasSavedPassword = false
        authState = OpenBoxAuthState(enabled: authState?.enabled, authenticated: false,
                                     passwordSet: authState?.passwordSet)
    }

    // MARK: Formatting

    private func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func panelDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func panelMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private func rawText(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "—" }
        return text
    }
}

/// Subscription editor: the save is a two-step confirm inside the
/// sheet, so a PATCH never leaves without the user seeing it twice.
struct OpenBoxSubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: OpenBoxSubscription
    let onSave: (String, String, Bool) async -> Bool

    @State private var name: String
    @State private var url: String
    @State private var enabled: Bool
    @State private var confirming = false
    @State private var saving = false
    @State private var failed = false

    init(subscription: OpenBoxSubscription,
         onSave: @escaping (String, String, Bool) async -> Bool) {
        self.subscription = subscription
        self.onSave = onSave
        _name = State(initialValue: subscription.name)
        _url = State(initialValue: subscription.url ?? "")
        _enabled = State(initialValue: subscription.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅") {
                    TextField("订阅名称", text: $name)
                    TextField("订阅链接", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("已启用", isOn: $enabled)
                }
                if failed {
                    Text("保存失败，请回到页面查看原因。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                }
                Section {
                    if confirming {
                        Button("确认保存") {
                            saving = true
                            Task {
                                if await onSave(name, url, enabled) {
                                    dismiss()
                                } else {
                                    failed = true
                                }
                                saving = false
                                confirming = false
                            }
                        }
                        .disabled(saving)
                        Button("再想想", role: .cancel) { confirming = false }
                    } else {
                        Button("保存") { confirming = true }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                      || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - HomeProxy dedicated page (UCI, read-only)

struct HomeProxyView: View {
    @Environment(RouterStore.self) private var store

    private var service: CapabilitySnapshot.CapabilityService? {
        store.capability?.services.first { $0.key == "homeproxy" }
    }

    var body: some View {
        List {
            if let service {
                Section {
                    SummaryBanner(summary: SummaryEngine.serviceState(running: service.running))
                        .summaryRow()
                }
                Section("服务状态") {
                    LabeledContent("运行状态", value: service.running.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    if service.running == nil, let note = service.statusNote {
                        Text(note)
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    LabeledContent("开机自启", value: service.enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
                }
            }
            Section("配置分组") {
                ForEach([("客户端", "config"), ("节点", "node"), ("服务器", "server")], id: \.1) { title, _ in
                    NavigationLink {
                        UCIConfigView(title: "HomeProxy · \(title)", configNames: ["homeproxy"])
                    } label: {
                        Label(title, systemImage: "list.bullet.rectangle")
                    }
                }
                NavigationLink {
                    ConfigEditorView(configName: "homeproxy", title: "HomeProxy")
                } label: {
                    Label("编辑配置（含节点选择）", systemImage: "square.and.pencil")
                }
            }
            if let service, let initName = service.initNames.first {
                ServiceActionsSection(serviceName: initName)
            }
        }
        .navigationTitle("HomeProxy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - MosDNS dedicated page (UCI, read-only)

struct MosDNSView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<RouterConfiguration?> = .loading
    @State private var localization: LuciLocalization = .source

    private var service: CapabilitySnapshot.CapabilityService? {
        store.capability?.services.first { $0.key == "mosdns" }
    }

    var body: some View {
        List {
            if let service {
                Section {
                    SummaryBanner(summary: SummaryEngine.serviceState(running: service.running))
                        .summaryRow()
                }
                Section("服务状态") {
                    LabeledContent("运行状态", value: service.running.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    if service.running == nil, let note = service.statusNote {
                        Text(note)
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    LabeledContent("开机自启", value: service.enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
                }
            }
            switch state {
            case .loading:
                ProgressView("正在读取 MosDNS 配置…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let configuration):
                if let configuration {
                    ForEach(GenericPageModel.sections(from: configuration, localizer: localization)) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.displayKey, value: row.valueText)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("MosDNS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ConfigEditorView(configName: "mosdns", title: "MosDNS")
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = store.readClient else { state = .failed("未连接路由器。"); return }
        state = .loading
        localization = await client.localization()
        do { state = .loaded(try await client.configuration("mosdns")) }
        catch { state = .failed(FriendlyError.message(error)) }
    }
}
