import SwiftUI
import OpenWrtKit

struct RouterDiagnosticsView: View {
    @Environment(RouterStore.self) private var store
    @State private var tool: DiagnosticTool = .ping
    @State private var host = ""
    @State private var result: RouterCommandResult?
    @State private var error: String?
    @State private var running = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            Section("诊断任务") {
                Picker("工具", selection: $tool) { ForEach(DiagnosticTool.allCases) { Text($0.title).tag($0) } }
                TextField("IP 或域名", text: $host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("diagnostic-host")
                Button(running ? "正在执行…" : "开始诊断", systemImage: "play") { run() }
                    .disabled(running || host.isEmpty).accessibilityIdentifier("diagnostic-run")
            }.disabled(running)
            if running {
                Section {
                    ProgressView("等待路由器返回…")
                    Button("取消等待", role: .cancel) { task?.cancel(); task = nil; running = false }
                } footer: { Text("取消会结束手机等待，已启动的路由器命令可能继续运行直至退出。") }
            }
            if let error { Section("未能完成请求") { Text(error).foregroundStyle(AppPalette.red) } }
            if let result {
                Section("执行结果") {
                    LabeledContent("退出码", value: String(result.exitCode))
                    if result.stdout.isEmpty && result.stderr.isEmpty { Text("命令没有返回文本输出。") }
                    if !result.stdout.isEmpty { Text(result.stdout).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                    if !result.stderr.isEmpty { Text(result.stderr).font(.system(.footnote, design: .monospaced)).foregroundStyle(AppPalette.orange).textSelection(.enabled) }
                }
            }
            Section {
                Text("从路由器执行固定诊断命令。Ping 最多 3 次、8 秒；Traceroute 最多 8 跳。工具未安装、账户无权执行、目标不响应或请求超时都会显示实际结果。")
                    .foregroundStyle(AppPalette.muted)
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("网络诊断")
            .onDisappear { task?.cancel(); task = nil; running = false }
    }
    private func run() {
        let generation = store.connectionID
        let selectedTool = tool, target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result = nil; error = nil; running = true
        task = Task {
            defer { if !Task.isCancelled && generation == store.connectionID { running = false } }
            do {
                let response = try await store.diagnose(tool: selectedTool, host: target)
                guard !Task.isCancelled, generation == store.connectionID else { return }
                result = response
            } catch {
                guard !Task.isCancelled, generation == store.connectionID else { return }
                self.error = FriendlyError.message(error)
            }
        }
    }
}

struct RouterRebootView: View {
    @Environment(RouterStore.self) private var store
    @State private var confirming = false
    @State private var requested = false
    @State private var submitting = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("路由器", value: store.activeProfile?.name ?? "—")
                Text("重启会中断全部网络与管理连接。请先处理未应用的草稿及其他正在运行的任务。")
            }
            Section {
                if submitting { ProgressView("正在发送重启请求…") }
                if !requested {
                    Button("重启路由器", systemImage: "restart", role: .destructive) { confirming = true }
                        .disabled(store.isMutating || store.pendingConfiguration != nil || submitting)
                }
                if let message { Text(message).foregroundStyle(AppPalette.muted) }
                if requested {
                    Button("断开并重新连接") { store.disconnect() }
                }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("重启")
            .confirmationDialog("确认重启当前路由器？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认重启", role: .destructive) {
                    Task {
                        submitting = true; message = nil
                        defer { submitting = false }
                        do {
                            try await store.reboot(); requested = true
                            message = "路由器已接受重启请求。等待设备恢复后请重新连接；收到请求不代表重启已经完成。"
                        } catch {
                            message = "重启请求未能确认：" + FriendlyError.message(error) + " 请先核对设备状态，避免重复发送。"
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            }
    }
}
