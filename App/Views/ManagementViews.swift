import SwiftUI
import OpenWrtKit

// MARK: - Device management (package C, item 2)
//
// One roster merged from DHCP leases, the neighbor table and — when
// granted — wireless association, deduplicated by MAC in the kit.
// Names are local notes (router + MAC); blocking uses the router's
// own mechanisms through the L4 gate: the wireless MAC filter for
// Wi-Fi devices, a marked firewall rule for wired forwarding.

struct DevicesView: View {
    @Environment(RouterStore.self) private var store
    @State private var devices: [OnlineDevice] = []
    @State private var wirelessConfig: RouterConfiguration?
    @State private var firewallConfig: RouterConfiguration?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var names = DeviceNameStore.shared

    private var routerID: String { store.activeProfile?.id.uuidString ?? "" }

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("正在汇总设备…") }
            } else if let loadError {
                ErrorStateView(message: loadError) { Task { await load() } }
            } else if devices.isEmpty {
                EmptyStateView(title: "暂无在线设备",
                               message: "DHCP 租约、邻居表与无线关联都没有报告设备。设备上线或续租后会出现在这里。",
                               symbol: "iphone.slash")
            } else {
                Section {
                    ForEach(devices) { device in
                        NavigationLink {
                            DeviceDetailView(device: device,
                                             wirelessConfig: wirelessConfig,
                                             firewallConfig: firewallConfig,
                                             onConfigChanged: { Task { await loadConfigs() } })
                        } label: {
                            deviceRow(device)
                        }
                    }
                } header: {
                    Text("在线设备（\(devices.count)）")
                } footer: {
                    Text("列表由 DHCP 租约、邻居表与无线关联三处数据合并，同一设备按 MAC 去重；没有 MAC 的邻居条目单独列出。")
                        .font(AppTypography.metadata)
                }
            }
        }
        .navigationTitle("设备管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func deviceRow(_ device: OnlineDevice) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: symbol(for: device))
                .foregroundStyle(AppPalette.accent)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(displayName(device)).font(AppTypography.rowTitle)
                Text(subtitle(device)).font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.muted).lineLimit(1)
            }
            Spacer()
            if isBlocked(device) {
                StatusBadge(title: "已拉黑", good: false)
            }
            if let signal = device.signal {
                Text("\(signal) dBm").font(AppTypography.metadata)
                    .foregroundStyle(AppPalette.muted).monospacedDigit()
                GradeChip(grade: HealthRating.signalGrade(dBm: Double(signal)), strength: true)
            }
        }
    }

    private func symbol(for device: OnlineDevice) -> String {
        if device.isRouter { return "network" }
        switch device.connection {
        case .wireless: return "wifi"
        case .wired: return "cable.connector"
        case .unknown: return "questionmark.circle"
        }
    }

    private func displayName(_ device: OnlineDevice) -> String {
        if let mac = device.mac, let custom = names.name(routerID: routerID, mac: mac) {
            return custom
        }
        return device.displayName
    }

    private func subtitle(_ device: OnlineDevice) -> String {
        var parts: [String] = []
        if let address = device.addresses.first { parts.append(address) }
        if let mac = device.mac { parts.append(mac) }
        switch device.connection {
        case .wireless: parts.append(L10n.string("无线"))
        case .wired: parts.append(L10n.string("有线"))
        case .unknown: parts.append(L10n.string("接入方式未知"))
        }
        return parts.joined(separator: " · ")
    }

    private func isBlocked(_ device: OnlineDevice) -> Bool {
        guard let mac = device.mac else { return false }
        let wireless = wirelessConfig.map { DeviceBlock.isWirelessBlocked(mac: mac, wireless: $0) } ?? false
        let wired = firewallConfig.map { DeviceBlock.isWiredBlocked(mac: mac, firewall: $0) } ?? false
        return wireless || wired
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        guard let client = store.readClient else {
            loadError = L10n.string("尚未连接路由器。")
            return
        }
        await store.refresh()
        let neighbors = (try? await client.neighbors()) ?? []
        let stations = await client.associatedStations()
        devices = DeviceRoster.merge(leases: store.leases, neighbors: neighbors, stations: stations)
        await loadConfigs()
    }

    private func loadConfigs() async {
        wirelessConfig = try? await store.configuration("wireless")
        firewallConfig = try? await store.configuration("firewall")
    }
}

struct DeviceDetailView: View {
    @Environment(RouterStore.self) private var store
    let device: OnlineDevice
    let wirelessConfig: RouterConfiguration?
    let firewallConfig: RouterConfiguration?
    var onConfigChanged: () -> Void = {}

    @State private var nameDraft = ""
    @State private var pendingPlan: ConfigurationPlan?
    @State private var pendingReload: [String] = []
    @State private var showingConfirm = false
    @State private var note: String?
    @State private var names = DeviceNameStore.shared

    private var routerID: String { store.activeProfile?.id.uuidString ?? "" }
    private var mac: String? { device.mac }

    private var wirelessBlocked: Bool {
        guard let mac, let wirelessConfig else { return false }
        return DeviceBlock.isWirelessBlocked(mac: mac, wireless: wirelessConfig)
    }
    private var wiredBlocked: Bool {
        guard let mac, let firewallConfig else { return false }
        return DeviceBlock.isWiredBlocked(mac: mac, firewall: firewallConfig)
    }
    private var hasWirelessInterfaces: Bool {
        wirelessConfig?.sections.contains { $0.type == "wifi-iface" } ?? false
    }

    var body: some View {
        List {
            Section("设备") {
                LabeledContent("显示名称", value: currentName)
                if let hostname = device.hostname, !hostname.isEmpty, hostname != "*" {
                    LabeledContent("主机名", value: hostname)
                }
                if let mac = device.mac {
                    LabeledContent("MAC 地址", value: mac)
                }
                ForEach(device.addresses, id: \.self) { address in
                    LabeledContent("IP 地址", value: address)
                }
                LabeledContent("接入方式", value: connectionText)
                if let wirelessDevice = device.wirelessDevice {
                    LabeledContent("无线设备", value: wirelessDevice)
                }
                if let signal = device.signal {
                    RatedRow(title: "信号", value: "\(signal) dBm",
                             grade: HealthRating.signalGrade(dBm: Double(signal)), strength: true)
                    MeterBar(fraction: HealthRating.signalFraction(dBm: Double(signal)),
                             grade: HealthRating.signalGrade(dBm: Double(signal)))
                }
                if let expires = device.leaseExpiresIn {
                    LabeledContent("租约剩余", value: FormatHelpers.uptime(TimeInterval(expires)))
                }
                if let state = device.neighborState {
                    LabeledContent("邻居状态", value: RoutesStatusView.neighborStateLabel(state))
                }
                if let rx = device.rxBytes, let tx = device.txBytes {
                    LabeledContent("流量（本次关联）", value: "↓ \(FormatHelpers.bytes(rx)) · ↑ \(FormatHelpers.bytes(tx))")
                }
                LabeledContent("数据来源", value: sourcesText)
                if device.mac == nil {
                    Text("这条记录来自邻居表且没有 MAC 地址，无法与租约或无线关联合并，也无法命名或拉黑。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }

            if device.mac != nil {
                Section("备注名") {
                    TextField("给这台设备起个名字", text: $nameDraft)
                    Button("保存备注名") {
                        names.setName(nameDraft, routerID: routerID, mac: mac ?? "")
                        note = L10n.string("备注名已保存（只保存在本机，不写路由器）。")
                    }
                    if let note {
                        Text(L10n.key(note)).font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                Section("拉黑") {
                    if hasWirelessInterfaces {
                        HStack {
                            Text("无线接入")
                            Spacer()
                            Text(wirelessBlocked ? "已拉黑" : "未拉黑")
                                .foregroundStyle(wirelessBlocked ? AppPalette.red : AppPalette.muted)
                        }
                        Button(wirelessBlocked ? "解除无线拉黑" : "拉黑无线接入",
                               role: wirelessBlocked ? nil : .destructive) {
                            prepareWireless(block: !wirelessBlocked)
                        }
                        Text("通过各无线接口的 MAC 过滤名单生效：拉黑后该设备无法再连入这台路由器的 Wi-Fi。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    HStack {
                        Text("有线转发")
                        Spacer()
                        Text(wiredBlocked ? "已拉黑" : "未拉黑")
                            .foregroundStyle(wiredBlocked ? AppPalette.red : AppPalette.muted)
                    }
                    Button(wiredBlocked ? "解除有线拉黑" : "拉黑有线转发",
                           role: wiredBlocked ? nil : .destructive) {
                        prepareWired(block: !wiredBlocked)
                    }
                    Text("通过防火墙规则拦截该设备的上网转发。同网段设备之间的互访不经过防火墙，不在此拦截范围内。")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    if let note {
                        Text(L10n.key(note)).font(AppTypography.secondary)
                            .foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
        .navigationTitle(currentName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let mac { nameDraft = names.name(routerID: routerID, mac: mac) ?? "" }
        }
        .sheet(isPresented: $showingConfirm) {
            if let pendingPlan {
                TransactionConfirmationView(plan: pendingPlan, reloadServices: pendingReload) {
                    onConfigChanged()
                }
            }
        }
    }

    private var currentName: String {
        if let mac, let custom = names.name(routerID: routerID, mac: mac) { return custom }
        return device.displayName
    }

    private var connectionText: String {
        switch device.connection {
        case .wireless: return L10n.string("无线")
        case .wired: return L10n.string("有线")
        case .unknown: return L10n.string("接入方式未知")
        }
    }

    private var sourcesText: String {
        var parts: [String] = []
        if device.sources.contains(.lease) { parts.append(L10n.string("DHCP 租约")) }
        if device.sources.contains(.neighbor) { parts.append(L10n.string("邻居表")) }
        if device.sources.contains(.station) { parts.append(L10n.string("无线关联")) }
        return parts.joined(separator: "、")
    }

    private func prepareWireless(block: Bool) {
        guard let mac, let wirelessConfig,
              let edited = DeviceBlock.wirelessPlan(mac: mac, block: block, original: wirelessConfig),
              let plan = try? ConfigurationPlan(original: wirelessConfig, edited: edited) else {
            note = L10n.string("已是该状态，无需变更。")
            return
        }
        pendingPlan = plan
        pendingReload = ConfigReloadMap.services(for: "wireless")
        showingConfirm = true
    }

    private func prepareWired(block: Bool) {
        guard let mac, let firewallConfig,
              let edited = DeviceBlock.wiredPlan(mac: mac, block: block, original: firewallConfig),
              let plan = try? ConfigurationPlan(original: firewallConfig, edited: edited) else {
            note = L10n.string("已是该状态，无需变更。")
            return
        }
        pendingPlan = plan
        pendingReload = ConfigReloadMap.services(for: "firewall")
        showingConfirm = true
    }
}

// MARK: - App lock (package C, item 4)

struct AppLockToggleRow: View {
    @Environment(AppLockController.self) private var lock

    var body: some View {
        Toggle(isOn: Binding(
            get: { lock.enabled },
            set: { newValue in
                if newValue {
                    Task { _ = await lock.enableWithAuthentication() }
                } else {
                    Task { _ = await lock.disableWithAuthentication() }
                }
            })) {
            Label("使用 Face ID 解锁 App", systemImage: "faceid")
        }
        Text("开启后，冷启动或离开超过 30 秒再返回时，需要用 Face ID、触控 ID 或设备密码解锁；锁定期间不显示任何路由器内容。切换路由器时调用保存密码前的 Face ID 验证始终生效，不受此开关影响。")
            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
    }
}

/// The locked face of the app: brand + one action, nothing else.
/// No router names, no lists, no values — the root content is not
/// rendered at all while this is up.
struct LockScreenView: View {
    @Environment(AppLockController.self) private var lock

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(AppPalette.accent)
            Text("已锁定")
                .font(AppTypography.title)
            Text("解锁后才能查看路由器管理内容。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            Button {
                Task { await lock.authenticate() }
            } label: {
                Label(lock.isAuthenticating ? "正在验证…" : "解锁", systemImage: "faceid")
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .disabled(lock.isAuthenticating)
            .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task { await lock.authenticate() }
    }
}

// MARK: - SSH trust management (package C, item 5)

struct SSHTrustSettingsView: View {
    @State private var trustStore = SSHTrustStore.shared

    var body: some View {
        List {
            if trustStore.trust.records.isEmpty {
                EmptyStateView(title: "暂无已信任指纹",
                               message: "首次在终端连接一台路由器并确认指纹后，记录会出现在这里。",
                               symbol: "fingerprint")
            } else {
                Section {
                    ForEach(trustStore.trust.records) { record in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(record.endpoint).font(AppTypography.rowTitle)
                            Text(record.displayFingerprint)
                                .font(AppTypography.metadata.monospaced())
                                .foregroundStyle(AppPalette.muted)
                                .textSelection(.enabled)
                            Text("信任于 \(record.trustedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                trustStore.revoke(record)
                            } label: {
                                Label("撤销信任", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("撤销后，下次终端连接这台路由器时会重新要求核对指纹。")
                        .font(AppTypography.metadata)
                }
            }
        }
        .navigationTitle("SSH 主机指纹")
        .navigationBarTitleDisplayMode(.inline)
    }
}
