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

// MARK: - Open-Box dedicated page (panel API, read-only)

struct OpenBoxView: View {
    @Environment(RouterStore.self) private var store
    @State private var state: LoadState<(OpenBoxServiceStatus, String?, [OpenBoxProxy])> = .loading
    @State private var panelPassword = ""
    @State private var needsLogin = false
    @State private var switchTarget: (group: String, node: String)?
    @State private var switchResult: String?

    var body: some View {
        List {
            switch state {
            case .loading:
                ProgressView("正在读取 Open-Box…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                if needsLogin {
                    Section("面板登录") {
                        SecureField("Open-Box 面板密码", text: $panelPassword)
                        Button("登录面板并重试") { Task { await loginAndLoad() } }
                            .disabled(panelPassword.isEmpty)
                        Text("面板密码与路由器登录密码不同，仅用于本次会话读取面板数据。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }
            case .loaded(let (status, version, proxies)):
                Section("内核与面板") {
                    LabeledContent("内核", value: status.coreRunning.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    LabeledContent("面板", value: status.panelRunning.map { $0 ? L10n.string("运行中") : L10n.string("已停止") } ?? L10n.string("未知"))
                    if let version { LabeledContent("内核版本", value: version) }
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
            if let service = store.capability?.services.first(where: { $0.key == "openbox" }) {
                Section("路由器侧状态") {
                    LabeledContent("init.d", value: service.initNames.joined(separator: L10n.string("、")))
                    LabeledContent("开机自启", value: service.enabled.map { $0 ? L10n.string("已启用") : L10n.string("未启用") } ?? L10n.string("未知"))
                }
            }
        }
        .navigationTitle("Open-Box")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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
    }

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

    private func loginAndLoad() async {
        guard let client = panelClient() else { return }
        do {
            try await client.login(password: panelPassword)
            panelPassword = ""
            needsLogin = false
            await load()
        } catch {
            state = .failed("面板登录失败：\(FriendlyError.message(error))")
        }
    }

    private func load() async {
        guard let client = panelClient() else { state = .failed("无法确定路由器地址。"); return }
        state = .loading
        do {
            async let status = client.serviceStatus()
            async let version = client.kernelVersion()
            async let proxies = client.proxies()
            state = .loaded((try await status, try await version, try await proxies))
        } catch let error as OpenWrtKitError where error == .permissionDenied {
            needsLogin = true
            state = .failed("面板需要登录后才能读取数据。")
        } catch {
            state = .failed(FriendlyError.message(error))
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
