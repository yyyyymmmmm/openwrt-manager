import SwiftUI
import OpenWrtKit

struct WakeOnLANView: View {
    @Environment(RouterStore.self) private var store
    @State private var snapshot: WakeOnLANSnapshot?
    @State private var loading = false
    @State private var pageError: String?
    @State private var confirmation: WakeOnLANTarget?
    @State private var selectedTools: [String: WakeOnLANTool] = [:]
    @State private var attemptedTargets = Set<String>()
    @State private var results: [String: RouterCommandResult] = [:]
    @State private var sendErrors: [String: String] = [:]
    @State private var observedConnection: UUID?
    @State private var readRequest = UUID()

    private var configuration: RouterConfiguration? { snapshot?.configuration }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            if loading { ProgressView("正在读取目标和工具能力…") }
            if let pageError {
                AppSection(title: "读取失败") {
                    AppGroup {
                        Text(pageError).font(AppTypography.secondary).foregroundStyle(AppPalette.red).padding(12)
                        Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                }
            }

            if let snapshot {
                if snapshot.capabilities?.tools.isEmpty == true {
                    AppSection(title: "缺少唤醒工具", note: "此固件当前没有可执行的 Etherwake 或 Wakeonlan。不会发送模拟结果。") {
                        AppGroup {
                            NavigationLink { PackagesView() } label: {
                                AppRow(title: "打开原生软件包管理", detail: "搜索并安装固件可用的 etherwake 或 wakeonlan 包", symbol: "shippingbox", chevron: true)
                            }.buttonStyle(.plain).accessibilityIdentifier("wol-packages")
                        }
                    }
                }

                AppSection(title: "目标设备", note: "配置来自路由器的 luci-wol；每个目标发送前会重新核对配置、待提交 UCI 修改、工具和权限。") {
                    AppGroup {
                        if let configured = snapshot.targets {
                            if configured.isEmpty {
                                Text("路由器尚未配置唤醒目标。").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12)
                            }
                            ForEach(configured) { status in
                                targetRow(status)
                                if status.id != configured.last?.id { AppDivider() }
                            }
                        } else {
                            Text("未能读取目标配置；请查看下方实际错误。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                        }
                        NavigationLink { NativeConfigurationView(schema: .wol) } label: {
                            AppRow(title: "管理目标与默认工具", symbol: "slider.horizontal.3", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("wol-edit-configuration")
                    }
                }

                AppSection(title: "已发现主机", note: "主机提示来自路由器邻居/租约信息，不证明设备当前在线，也不会自动加入唤醒目标。") {
                    AppGroup {
                        if let hosts = snapshot.hosts {
                            if hosts.isEmpty { Text("路由器没有返回主机提示。").font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(12) }
                            ForEach(hosts) { host in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name?.isEmpty == false ? host.name! : host.mac).font(AppTypography.rowTitle)
                                    Text(([host.mac] + host.addresses).joined(separator: " · "))
                                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).textSelection(.enabled)
                                }.padding(12)
                                if host.id != hosts.last?.id { AppDivider() }
                            }
                        } else {
                            Text("主机提示不可用；请检查实际权限或固件接口错误。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12)
                        }
                    }
                }

                AppSection(title: "路由器能力与权限") {
                    AppGroup {
                        if let tools = snapshot.capabilities {
                            AppRow(title: "Etherwake", value: tools.tools.contains(.etherwake) ? "可执行" : "未安装")
                            AppDivider(inset: 12)
                            AppRow(title: "Wakeonlan", value: tools.tools.contains(.wakeonlan) ? "可执行" : "未安装")
                        } else { Text("工具探测失败；不能确认可用程序。").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).padding(12) }
                        AppDivider()
                        AppRow(title: "发送权限", value: snapshot.canSend.map { $0 ? "允许" : "拒绝" } ?? "未知")
                        if let devices = snapshot.devices {
                            AppDivider()
                            AppRow(title: "网络设备", detail: devices.map { "\($0.name)：\($0.up.map { $0 ? "启用" : "未启用" } ?? "状态未返回")" }.joined(separator: " · "))
                        }
                        if !snapshot.issues.isEmpty {
                            ForEach(snapshot.issues.keys.sorted(), id: \.self) { key in
                                AppDivider()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key).font(AppTypography.rowTitle)
                                    Text(snapshot.issues[key] ?? "").font(AppTypography.secondary).foregroundStyle(AppPalette.orange).textSelection(.enabled)
                                }.padding(12)
                            }
                        }
                        Text("读取时间：\(snapshot.readAt.formatted(date: .abbreviated, time: .standard))")
                            .font(AppTypography.metadata).foregroundStyle(AppPalette.muted).padding(12)
                    }
                }
            }
        }
        .appDetailStyle("网络唤醒")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(loading || store.isMutating || store.pendingConfiguration != nil)
                    .accessibilityIdentifier("wol-refresh")
            }
        }
        .confirmationDialog("发送唤醒包？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let target = confirmation {
                Button("向 \(target.name) 发送", systemImage: "power") { Task { await send(target) } }
                    .accessibilityIdentifier("wol-confirm-send")
            }
            Button("取消", role: .cancel) { confirmation = nil }
        } message: {
            if let target = confirmation {
                Text("目标 MAC：\(target.mac)。将通过路由器执行真实唤醒程序；命令成功不代表目标已经开机。此次目标在重新读取前只允许尝试一次。")
            }
        }
        .task(id: store.connectionID) {
            if observedConnection != store.connectionID {
                observedConnection = store.connectionID
                snapshot = nil; pageError = nil; results = [:]; sendErrors = [:]; attemptedTargets = []; selectedTools = [:]; confirmation = nil
            }
            await load()
        }
    }

    @ViewBuilder private func targetRow(_ status: WakeOnLANTargetStatus) -> some View {
        let section = status.section
        if let target = status.target {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.name).font(AppTypography.rowTitle)
                        Text(target.mac).font(.system(.caption, design: .monospaced)).foregroundStyle(AppPalette.muted).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                }
                if let available = snapshot?.capabilities?.tools, !available.isEmpty {
                    Picker("发送工具", selection: toolBinding(for: target)) {
                        Text("请选择发送工具").tag(Optional<WakeOnLANTool>.none)
                        ForEach(available) { tool in Text(tool.title).tag(Optional(tool)) }
                    }.accessibilityIdentifier("wol-tool-\(section.id)")
                    if selectedTool(for: target) == .wakeonlan && target.hasEtherwakeOptions {
                        Text("Wakeonlan 不支持此目标的发送接口、广播和 SecureOn 设置；固件会忽略这些字段。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                    }
                }
                if let result = results[section.id] {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(result.exitCode == 0 ? "唤醒程序已返回成功" : "唤醒程序返回失败", systemImage: result.exitCode == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(result.exitCode == 0 ? AppPalette.green : AppPalette.red)
                        Text("退出码 \(result.exitCode) · 设备是否开机尚未确认。")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        if !result.stdout.isEmpty { Text("输出：\(result.stdout)").font(AppTypography.secondary).textSelection(.enabled) }
                        if !result.stderr.isEmpty { Text("错误：\(result.stderr)").font(AppTypography.secondary).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                    }
                }
                if let error = sendErrors[section.id] {
                    Text(error).font(AppTypography.secondary).foregroundStyle(AppPalette.red).textSelection(.enabled)
                }
                Button("发送唤醒包", systemImage: "power") { confirmation = target }
                    .disabled(!canSend(target) || attemptedTargets.contains(section.id) || loading || store.isMutating || store.pendingConfiguration != nil)
                    .accessibilityIdentifier("wol-send-\(section.id)")
            }.padding(12)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(section.values["name"]?.stringValue ?? section.id).font(AppTypography.rowTitle)
                Text(status.error ?? "目标字段不符合唤醒格式。").font(AppTypography.secondary).foregroundStyle(AppPalette.red)
                if let mac = section.values["mac"]?.stringValue { Text("MAC：\(mac)").font(AppTypography.secondary).foregroundStyle(AppPalette.muted) }
            }.padding(12)
        }
    }

    private func selectedTool(for target: WakeOnLANTarget) -> WakeOnLANTool? {
        let available = snapshot?.capabilities?.tools ?? []
        if let selected = selectedTools[target.section.id], available.contains(selected) { return selected }
        if let configured = snapshot?.configuration?.sections.first(where: { $0.id == "defaults" })?.values["executable"]?.stringValue,
           let tool = WakeOnLANTool(rawValue: configured), available.contains(tool) { return tool }
        return nil
    }

    private func toolBinding(for target: WakeOnLANTarget) -> Binding<WakeOnLANTool?> {
        Binding(get: { selectedTool(for: target) }, set: {
            if let tool = $0 { selectedTools[target.section.id] = tool }
            else { selectedTools[target.section.id] = nil }
        })
    }

    private func canSend(_ target: WakeOnLANTarget) -> Bool {
        guard let selected = selectedTool(for: target) else { return false }
        guard pageError == nil, !loading, observedConnection == store.connectionID,
              snapshot?.canSend == true,
              snapshot?.capabilities?.tools.contains(selected) == true else { return false }
        if selected == .etherwake, let interface = target.interface {
            return snapshot?.devices?.contains(where: { $0.name == interface && $0.up == true }) == true
        }
        return true
    }

    private func load() async {
        let connection = store.connectionID, request = UUID()
        readRequest = request
        loading = true; pageError = nil; snapshot = nil; confirmation = nil
        defer { if connection == store.connectionID, readRequest == request { loading = false } }
        do {
            let value = try await store.wakeOnLAN()
            guard connection == store.connectionID, readRequest == request, !Task.isCancelled else { return }
            snapshot = value; results = [:]; sendErrors = [:]; attemptedTargets = []; confirmation = nil
            selectedTools = selectedTools.filter { id, tool in
                value.configuration?.sections.contains(where: { $0.id == id && $0.type == "target" }) == true &&
                value.capabilities?.tools.contains(tool) == true
            }
        } catch {
            guard connection == store.connectionID, readRequest == request, !Task.isCancelled else { return }
            pageError = FriendlyError.message(error)
        }
    }

    private func send(_ target: WakeOnLANTarget) async {
        guard let configuration = snapshot?.configuration,
              let tool = selectedTool(for: target),
              !attemptedTargets.contains(target.section.id),
              canSend(target), let connection = observedConnection else { return }
        attemptedTargets.insert(target.section.id)
        sendErrors[target.section.id] = nil; results[target.section.id] = nil
        do {
            let result = try await store.sendWakeOnLAN(sectionID: target.section.id, tool: tool,
                                                       observed: configuration, connection: connection)
            guard connection == store.connectionID else { return }
            results[target.section.id] = result
        } catch {
            if connection == store.connectionID { sendErrors[target.section.id] = FriendlyError.message(error) }
        }
    }
}

struct WOLTargetOrderView: View {
    @Binding var configuration: RouterConfiguration?
    let editable: Bool

    private var targets: [ConfigurationSection] {
        configuration?.sections.filter { $0.type == "target" } ?? []
    }

    var body: some View {
        List {
            Section {
                if targets.isEmpty { Text("当前没有可排序目标。") }
                ForEach(targets) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.values["name"]?.stringValue ?? section.id)
                        Text(section.values["mac"]?.stringValue ?? "MAC 未设置")
                            .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    .moveDisabled(!editable)
                }
                .onMove(perform: move)
            } footer: {
                Text(editable ? "拖动目标更改唤醒目标列表顺序。顺序暂存在配置草稿；返回上级预览后才会写入路由器。" : "当前账户没有确认的配置写入权限。")
            }
        }
        .environment(\.editMode, .constant(editable ? .active : .inactive))
        .tint(AppPalette.accent)
        .appDetailStyle("目标顺序")
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard editable, var configuration else { return }
        var reordered = configuration.sections.filter { $0.type == "target" }
        reordered.move(fromOffsets: source, toOffset: destination)
        var index = 0
        configuration.sections = configuration.sections.map { section in
            guard section.type == "target" else { return section }
            defer { index += 1 }
            return reordered[index]
        }
        self.configuration = configuration
    }
}
