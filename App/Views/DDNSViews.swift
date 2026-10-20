import SwiftUI
import OpenWrtKit

struct DDNSInstancesView: View {
    @Environment(RouterStore.self) private var store
    @State private var runtime: DDNSRuntimeSnapshot?
    @State private var access: Bool?
    @State private var loading = false
    @State private var error: String?
    @State private var accessError: String?
    @State private var loadedConnectionID: UUID?

    var body: some View {
        Form {
            Section("DDNS 运行状态") {
                if loading { ProgressView("正在读取 DDNS 配置和实例状态…") }
                if let runtime {
                    if let version = runtime.state?["_version"]?.stringValue { LabeledContent("DDNS 版本", value: version) }
                    if let enabled = runtime.state?["_enabled"]?.boolValue { LabeledContent("全局服务", value: enabled ? "已启用" : "已禁用") }
                    if let date = runtime.state?["_curr_dateformat"]?.stringValue { LabeledContent("路由器时间", value: date) }
                    if let schedule = runtime.state?["_services_list"]?.stringValue, schedule != "NO_LIST" { LabeledContent("下次计划", value: schedule) }
                    ForEach(runtime.issues.keys.sorted(), id: \.self) { key in
                        Label("\(key)：\(runtime.issues[key] ?? "读取失败")", systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.orange)
                    }
                    if let environment = runtime.environment {
                        let supported = environment.filter(\.value).map(\.key).sorted()
                        let unknown = ["has_wget", "has_curl", "has_ssl", "has_proxy", "has_forceip", "has_bindnet", "has_bindhost", "has_dnsserver", "has_cacerts", "has_ipv6"].filter { environment[$0] == nil }
                        LabeledContent("运行依赖", value: "\(supported.count) 项可用，\(unknown.count) 项未知")
                        ForEach(environment.keys.sorted(), id: \.self) { key in
                            LabeledContent(environmentTitle(key), value: environment[key] == true ? "可用" : "不可用")
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                Button("重新读取") { Task { await load() } }.disabled(loading || store.isMutating)
            }
            Section("服务实例") {
                if let configuration = runtime?.configuration {
                    if configuration.sections.filter({ $0.type == "service" }).isEmpty {
                        Text("固件返回的 DDNS 配置中没有 service 实例。可通过下方原生配置添加。")
                    }
                    ForEach(configuration.sections.filter { $0.type == "service" }) { section in
                        NavigationLink { DDNSInstanceDetailView(instanceID: section.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.id).font(AppTypography.rowTitle)
                                Text(instanceSummary(section)).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                if let status = runtime?.instances?.first(where: { $0.id == section.id }) {
                                    Text(status.address?.isEmpty == false ? "注册 IP：\(status.address!)" : "注册 IP：固件未报告")
                                        .font(AppTypography.secondary).foregroundStyle(status.address?.isEmpty == false ? AppPalette.accent : AppPalette.muted)
                                } else if let issue = runtime?.issues["实例状态"] {
                                    Text("状态读取失败：\(issue)").font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                                } else { Text("实例运行状态未知").font(AppTypography.secondary).foregroundStyle(AppPalette.muted) }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("ddns-instance-\(section.id)")
                    }
                } else if runtime?.issues["实例配置"] != nil {
                    Text(runtime?.issues["实例配置"] ?? "配置读取失败；不能推定没有实例。").foregroundStyle(AppPalette.orange)
                }
                NavigationLink { NativeConfigurationView(schema: .ddns) } label: {
                    AppRow(title: "DDNS 原生配置", detail: "全局设置与服务商实例字段", symbol: "slider.horizontal.3", chevron: true)
                }.accessibilityIdentifier("ddns-configuration")
            }
            if let accessError { Section("权限读取") { Text(accessError).foregroundStyle(AppPalette.orange).textSelection(.enabled) } }
            Section { Text("单实例操作调用 OpenWrt 的 ddns 启动脚本。退出码不等于 DNS 更新成功；需核对注册 IP、更新时间和实例日志。超时或断连后先重新读取，不要直接重试。") }
                .foregroundStyle(AppPalette.muted)
        }
        .font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("DDNS 实例")
        .task(id: store.connectionID) {
            if loadedConnectionID != store.connectionID { loadedConnectionID = store.connectionID; runtime = nil; access = nil }
            await load()
        }
    }

    private func environmentTitle(_ key: String) -> String {
        ["has_wget":"wget", "has_curl":"cURL", "has_ssl":"SSL", "has_proxy":"代理", "has_forceip":"强制 IP", "has_bindnet":"绑定网络", "has_bindhost":"绑定主机", "has_dnsserver":"指定 DNS", "has_cacerts":"CA 证书", "has_ipv6":"IPv6"][key] ?? key
    }
    private func instanceSummary(_ section: ConfigurationSection) -> String {
        let provider = section.values["service_name"]?.stringValue ?? "未设置服务商"
        let domain = section.values["domain"]?.stringValue ?? "未设置域名"
        let enabled = section.values["enabled"]?.stringValue == "1" ? "启用" : section.values["enabled"]?.stringValue == "0" ? "禁用" : "启用状态未知"
        return "\(provider) · \(domain) · \(enabled)"
    }
    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil; accessError = nil
        defer { if generation == store.connectionID { loading = false } }
        do {
            let value = try await store.ddnsRuntime()
            guard generation == store.connectionID, !Task.isCancelled else { return }
            runtime = value
            do {
                let allowed = try await store.ddnsActionAccess()
                guard generation == store.connectionID, !Task.isCancelled else { return }; access = allowed
            } catch {
                guard generation == store.connectionID, !Task.isCancelled else { return }
                access = false; accessError = "无法读取 DDNS 操作权限：" + FriendlyError.message(error)
            }
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
 }

private struct DDNSInstanceDetailView: View {
    @Environment(RouterStore.self) private var store
    let instanceID: String
    @State private var runtime: DDNSRuntimeSnapshot?
    @State private var access = false
    @State private var loading = false
    @State private var action: DDNSInstanceAction?
    @State private var needsRead = true
    @State private var error: String?
    @State private var permissionError: String?
    @State private var output: String?
    @State private var log: String?
    @State private var logError: String?
    @State private var loadingLog = false
    @State private var loadedConnectionID: UUID?
    private var section: ConfigurationSection? { runtime?.configuration?.sections.first { $0.id == instanceID && $0.type == "service" } }
    private var status: DDNSInstanceStatus? { runtime?.instances?.first { $0.id == instanceID } }
    private var busy: Bool { loading || store.isMutating || store.pendingConfiguration != nil }
    private var actionable: Bool { access && !needsRead && !busy && section != nil && status != nil }

    var body: some View {
        Form {
            Section("实例身份") {
                LabeledContent("配置节", value: instanceID)
                if let section {
                    LabeledContent("服务商", value: section.values["service_name"]?.stringValue ?? "未设置")
                    LabeledContent("域名", value: section.values["domain"]?.stringValue ?? "未设置")
                    LabeledContent("启用", value: section.values["enabled"]?.stringValue == "1" ? "是" : section.values["enabled"]?.stringValue == "0" ? "否" : "未知")
                } else if runtime?.configuration != nil { Text("此实例已不在当前 DDNS 配置中。") }
                NavigationLink { NativeConfigurationView(schema: .ddns) } label: { Label("编辑 DDNS 配置", systemImage: "slider.horizontal.3") }
            }
            Section("固件运行状态") {
                if loading { ProgressView("正在读取实例…") }
                if let runtime { Text("读取时间：" + runtime.readAt.formatted()).font(AppTypography.secondary).foregroundStyle(AppPalette.muted) }
                if let status {
                    LabeledContent("注册 IP", value: status.address?.isEmpty == false ? status.address! : "固件未报告")
                    LabeledContent("上次更新", value: status.lastUpdate ?? "固件未报告")
                    LabeledContent("下次操作", value: status.nextUpdate ?? "固件未报告")
                    LabeledContent("下次检查", value: status.nextCheck ?? "固件未报告")
                    LabeledContent("进程", value: status.pidReported ? (status.pid.map(String.init) ?? "未运行") : "未知")
                } else { Text("没有可用的实例运行状态。") }
                if let runtime {
                    ForEach(runtime.issues.keys.sorted(), id: \.self) { key in Text(key + "：" + (runtime.issues[key] ?? "读取失败")).foregroundStyle(AppPalette.orange) }
                }
                if needsRead { Text("当前数据不可用于操作；请重新读取。上次数据仅供对照。").foregroundStyle(AppPalette.orange) }
                if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                Button("重读实例状态") { Task { await load() } }.disabled(busy)
                    .accessibilityIdentifier("ddns-instance-read")
                Button("启动 / 重新检查") { action = .restart }
                    .disabled(!actionable || section?.values["enabled"]?.stringValue != "1")
                    .accessibilityIdentifier("ddns-instance-restart")
                Button("停止实例", role: .destructive) { action = .stop }
                    .disabled(!actionable || status?.pidReported != true || status?.pid == nil)
                    .accessibilityIdentifier("ddns-instance-stop")
            }
            if let output { Section("命令实际返回") { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            Section("实例日志") {
                if loadingLog { ProgressView("正在读取固件日志…") }
                if let log {
                    if log == "File not found or empty" { Text("固件报告日志文件不存在或为空。") }
                    else { Text(log.isEmpty ? "固件返回空日志。" : log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                if let logError { Text(logError).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                Button("读取实例日志") { Task { await readLog() } }.disabled(loadingLog || busy)
                    .accessibilityIdentifier("ddns-instance-log")
            }
            Section { Text("命令退出码 0 不代表 DDNS 更新成功。请核对注册 IP、更新时间和日志。操作前会再次比对配置及进程身份；固件没有原子条件启停接口，仍需避免多端同时操作。") }.foregroundStyle(AppPalette.muted)
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(instanceID)
        .task(id: store.connectionID) {
            if loadedConnectionID != store.connectionID {
                loadedConnectionID = store.connectionID; runtime = nil; log = nil; error = nil; output = nil; needsRead = true
            }
            await load()
        }
        .confirmationDialog("确认 DDNS 实例操作？", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            if let action { Button(action.title, role: .destructive) { Task { await run(action) } } }
            Button("取消", role: .cancel) { action = nil }
        } message: { Text("目标实例：" + instanceID + "。请求可能触发 DNS 服务商更新。") }
    }
    private func load() async {
        let generation = store.connectionID
        loading = true; access = false; permissionError = nil; needsRead = true
        defer { if generation == store.connectionID { loading = false } }
        do {
            let value = try await store.ddnsRuntime()
            guard generation == store.connectionID, !Task.isCancelled else { return }
            runtime = value
            needsRead = value.issues["实例配置"] != nil || value.issues["实例状态"] != nil || section == nil || status == nil
            do {
                let allowed = try await store.ddnsActionAccess()
                guard generation == store.connectionID, !Task.isCancelled else { return }
                access = allowed
                if !allowed { permissionError = "当前账户没有 DDNS 启动脚本的执行权限。" }
            } catch {
                guard generation == store.connectionID, !Task.isCancelled else { return }
                permissionError = FriendlyError.message(error)
            }
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
    private func run(_ action: DDNSInstanceAction) async {
        self.action = nil
        guard actionable, let section, let status else { return }
        let generation = store.connectionID
        needsRead = true; error = nil; output = nil
        do {
            let result = try await store.ddnsAction(action, observed: section, status: status)
            guard generation == store.connectionID else { return }
            output = "退出码：\(result.exitCode)\n标准输出：\n\(result.stdout)\n标准错误：\n\(result.stderr)"
            if result.exitCode != 0 { error = "DDNS 脚本返回失败，请检查输出和日志。" }
        } catch {
            guard generation == store.connectionID else { return }
            self.error = FriendlyError.message(error)
        }
        guard generation == store.connectionID else { return }
        await load(); await readLog()
    }
    private func readLog() async {
        let generation = store.connectionID
        loadingLog = true; logError = nil
        defer { if generation == store.connectionID { loadingLog = false } }
        do {
            let value = try await store.ddnsLog(instanceID: instanceID)
            guard generation == store.connectionID, !Task.isCancelled else { return }; log = value
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            logError = "最新日志读取失败（旧内容仅供对照）：" + FriendlyError.message(error)
        }
    }
}
