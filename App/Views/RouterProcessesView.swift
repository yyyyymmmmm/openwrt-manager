import SwiftUI
import OpenWrtKit

struct RouterProcessesView: View {
    @Environment(RouterStore.self) private var store
    @State private var processes: [RouterProcess] = []
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var requestID = UUID()
    private var filtered: [RouterProcess] {
        processes.filter { query.isEmpty || "\($0.pid) \($0.user) \($0.command)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            Section {
                ReadStatus(updatedAt: updatedAt, error: error, retry: { Task { await load() } }, loading: loading)
                Text("进程存在不代表服务业务正常。操作前会重新核对进程身份及权限。")
                    .foregroundStyle(AppPalette.muted)
            }
            Section("进程（\(filtered.count)）") {
                if updatedAt != nil && filtered.isEmpty {
                    Text(error == nil ? "没有匹配的进程。" : "当前状态读取失败，上次列表没有匹配项。").foregroundStyle(AppPalette.muted)
                }
                ForEach(filtered) { process in
                    NavigationLink {
                        RouterProcessDetail(process: process, connectionID: store.connectionID)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(process.command).lineLimit(3)
                            Text("PID \(process.pid) · \(process.user) · CPU \(process.cpu ?? "未返回") · 内存 \(process.memory ?? "未返回")")
                                .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                        }
                    }.disabled(error != nil || loading).accessibilityIdentifier("router-process-\(process.pid)")
                }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("进程")
            .searchable(text: $query, prompt: "PID、用户或命令")
            .task(id: store.connectionID) { processes = []; updatedAt = nil; await load() }
            .refreshable { await load() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            } }
    }
    private func load() async {
        let generation = store.connectionID, request = UUID()
        requestID = request; loading = true; error = nil
        defer { if requestID == request { loading = false } }
        do {
            let result = try await store.processes()
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            processes = result; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
}

private struct RouterProcessDetail: View {
    @Environment(RouterStore.self) private var store
    let process: RouterProcess
    let connectionID: UUID
    @State private var identity: RouterProcessIdentity?
    @State private var selected: RouterProcessSignal?
    @State private var confirming = false
    @State private var loading = false
    @State private var running = false
    @State private var error: String?
    @State private var result: String?
    var body: some View {
        List {
            Section("读取时进程信息") {
                LabeledContent("PID", value: String(process.pid))
                LabeledContent("用户", value: process.user)
                LabeledContent("CPU", value: process.cpu ?? "固件未返回")
                LabeledContent("内存", value: process.memory ?? "固件未返回")
                Text(process.command).textSelection(.enabled)
            }
            Section {
                if loading { ProgressView("正在核对进程身份…") }
                if running { ProgressView("正在发送信号并核对…") }
                ForEach(RouterProcessSignal.allCases) { signal in
                    Button(signal.title, role: .destructive) { selected = signal; confirming = true }
                        .disabled(identity == nil || process.pid == 1 || loading || running || result != nil || error != nil || store.isMutating || store.pendingConfiguration != nil || connectionID != store.connectionID)
                }
                if process.pid == 1 { Text("PID 1 不提供进程信号操作。").foregroundStyle(AppPalette.muted) }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                if let result { Text(result).textSelection(.enabled) }
            } header: { Text("进程控制") } footer: {
                Text("信号可能中断网络和管理会话；procd 可能自动重启服务。核对与发送之间仍有进程变化风险。操作后返回列表重新读取，再决定下一步。")
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("进程详情")
            .task { await identify() }
            .confirmationDialog(selected?.title ?? "进程操作", isPresented: $confirming, titleVisibility: .visible) {
                if let selected {
                    Button("确认\(selected.title)", role: .destructive) { Task { await send(selected) } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("PID \(process.pid)：\(process.command)\n" + (selected?.explanation ?? ""))
            }
    }
    private func identify() async {
        guard connectionID == store.connectionID else { error = "连接已变化，请返回进程列表重新读取。"; return }
        loading = true
        defer { loading = false }
        do {
            let value = try await store.processIdentity(process)
            guard connectionID == store.connectionID, !Task.isCancelled else { return }
            identity = value
        } catch {
            guard connectionID == store.connectionID, !Task.isCancelled else { return }
            self.error = "无法核对进程身份，未开放信号操作：" + FriendlyError.message(error)
        }
    }
    private func send(_ signal: RouterProcessSignal) async {
        guard connectionID == store.connectionID, let identity else { return }
        running = true
        defer { running = false }
        do {
            let response = try await store.signalProcess(identity, signal: signal)
            guard connectionID == store.connectionID else { return }
            result = response
        } catch {
            guard connectionID == store.connectionID else { return }
            self.error = FriendlyError.message(error) + "\n请求未确认不代表信号已取消。请返回列表重新读取。"
        }
    }
}
