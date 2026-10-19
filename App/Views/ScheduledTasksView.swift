import SwiftUI
import OpenWrtKit

struct ScheduledTasksView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var observed: ScheduledTasksSnapshot?
    @State private var draft = ""
    @State private var writable = false
    @State private var loading = false
    @State private var running = false
    @State private var needsRead = false
    @State private var error: String?
    @State private var permissionError: String?
    @State private var result: ScheduledTasksSaveResult?
    @State private var updatedAt: Date?
    @State private var preview: ScheduledTasksEdit?
    @State private var discard = false
    @State private var reloadPrompt = false
    @State private var requestID = UUID()
    @State private var loadedConnectionID: UUID?
    @State private var initialReadFinished = false
    @FocusState private var editorFocused: Bool
    private var changed: Bool { observed != nil && draft != (observed?.contents ?? "") }
    private var busy: Bool { loading || running || store.isMutating || store.pendingConfiguration != nil }
    private var cronReported: Bool {
        store.inventory.initServices.contains { $0.name == "cron" } || store.services.contains { $0.name == "cron" }
    }

    var body: some View {
        Form {
            Section {
                ReadStatus(updatedAt: updatedAt, error: error, retry: requestRead, loading: loading)
                Text("路由器 root 账户的计划任务，按路由器的时间执行。保存直接修改文件，不使用 UCI 超时回滚。")
                    .foregroundStyle(AppPalette.muted)
                NavigationLink("格式与执行说明") { ScheduledTasksHelpView() }
                    .accessibilityIdentifier("cron-help")
            }
            if let observed {
                Section {
                    Label(writable ? "允许编辑" : "当前仅可查看", systemImage: writable ? "pencil" : "lock")
                    if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                    if observed.contents == nil {
                        Text("目录已确认 root 任务文件不存在；保存将创建文件。").foregroundStyle(AppPalette.muted)
                    } else if observed.contents?.isEmpty == true {
                        Text("读取到的任务文件为空。").foregroundStyle(AppPalette.muted)
                    }
                    TextEditor(text: $draft)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 280)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($editorFocused)
                        .disabled(!writable || busy || needsRead)
                        .accessibilityLabel("计划任务内容").accessibilityIdentifier("cron-editor")
                } header: { Text("任务文件") } footer: {
                    Text("保留固件原有语法、注释与空行。只规范换行并补齐末尾换行；App 不推定 cron 支持哪些扩展语法。")
                }
                Section {
                    Button("预览变更", systemImage: "list.bullet.rectangle") { makePreview() }
                        .disabled(!writable || !changed || busy || needsRead)
                        .accessibilityIdentifier("cron-preview")
                    if needsRead {
                        Text("上次请求结果不确定。请先重新读取文件；本地草稿会保留供比对。").foregroundStyle(AppPalette.orange)
                    }
                    if let result {
                        ScheduledTasksResultView(result: result)
                    }
                    Button("重新加载已保存任务", systemImage: "arrow.clockwise") { Task { await reloadSaved() } }
                        .disabled(changed || busy || needsRead || observed.contents == nil)
                        .accessibilityIdentifier("cron-reload")
                    if running { ProgressView("正在核对文件并请求重载…") }
                } footer: {
                    Text("保存前比较读取时内容，保存后重读。固件不提供原子条件写入，请避免其他管理员同时编辑；重载退出码 0 也不证明任务语法或任务运行成功。")
                }
            }
            if cronReported {
                Section("系统服务") {
                    NavigationLink("cron 启动项与运行实例") { ServiceDetailView(name: "cron") }
                }
            }
            Section("核对执行结果") {
                NavigationLink("系统日志") { RouterRecordsView(kind: .logs) }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("计划任务")
            .scrollContentBackground(.hidden).background(AppPalette.canvas)
            .navigationBarBackButtonHidden(changed || busy)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { editorFocused = false }
                }
                if changed || busy {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") { if changed { discard = true } else { dismiss() } }.disabled(busy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重新读取", systemImage: "arrow.clockwise", action: requestRead).disabled(busy)
                        .accessibilityIdentifier("cron-read")
                }
            }
            .confirmationDialog("放弃未保存的计划任务？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .confirmationDialog("重新读取路由器文件", isPresented: $reloadPrompt, titleVisibility: .visible) {
                Button("保留草稿，读取最新文件") { Task { await load(keepDraft: true) } }
                Button("放弃草稿并重新读取", role: .destructive) { Task { await load(keepDraft: false) } }
                Button("取消", role: .cancel) {}
            } message: { Text("保留草稿后，请在预览中将它与最新文件比较，手动合并其他管理员的修改。") }
            .sheet(item: $preview) { edit in
                ScheduledTasksPreviewView(edit: edit) { response in
                    observed = response.snapshot; draft = response.snapshot.contents ?? ""
                    result = response; updatedAt = Date(); error = nil; needsRead = false
                } onUncertain: { message in
                    needsRead = true; error = message
                }
            }
            .task(id: store.connectionID) {
                if loadedConnectionID != store.connectionID {
                    loadedConnectionID = store.connectionID
                    observed = nil; draft = ""; result = nil; updatedAt = nil; needsRead = false
                    initialReadFinished = false
                }
                // Navigation to help or logs must not replace an unsaved draft.
                // A cancelled initial read may resume without losing edits.
                guard !initialReadFinished else { return }
                await load(keepDraft: observed != nil)
            }
    }

    private func requestRead() {
        guard !busy else { return }
        if changed || needsRead { reloadPrompt = true }
        else { Task { await load(keepDraft: false) } }
    }

    private func load(keepDraft: Bool) async {
        let generation = store.connectionID, request = UUID()
        requestID = request; loading = true; writable = false; error = nil; permissionError = nil
        defer {
            if requestID == request {
                loading = false
                if generation == store.connectionID, !Task.isCancelled { initialReadFinished = true }
            }
        }
        do {
            let value = try await store.scheduledTasks()
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            observed = value; updatedAt = Date(); needsRead = false; result = nil
            if !keepDraft { draft = value.contents ?? "" }
            do {
                let allowed = try await store.scheduledTasksWritable()
                guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
                writable = allowed
                if !allowed { permissionError = "账户没有计划任务文件的写入权限。" }
            } catch {
                guard generation == store.connectionID, requestID == request else { return }
                permissionError = "写入权限读取失败：" + FriendlyError.message(error)
            }
        } catch {
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            self.error = "未能读取任务文件，未创建或覆盖：" + FriendlyError.message(error)
        }
    }

    private func makePreview() {
        do {
            guard let observed else { return }
            preview = ScheduledTasksEdit(observed: observed, proposed: try ScheduledTasksSnapshot.prepared(draft), connectionID: store.connectionID)
            error = nil
        } catch { self.error = FriendlyError.message(error) }
    }

    private func reloadSaved() async {
        guard !busy, !changed, !needsRead, let observed else { return }
        let generation = store.connectionID
        running = true; error = nil
        defer { running = false }
        do {
            let response = try await store.reloadScheduledTasks(observed: observed)
            guard generation == store.connectionID else { return }
            result = response
        } catch {
            guard generation == store.connectionID else { return }
            self.error = FriendlyError.message(error)
        }
    }
}

private struct ScheduledTasksEdit: Identifiable {
    let id = UUID()
    let observed: ScheduledTasksSnapshot
    let proposed: String
    let connectionID: UUID
}

private struct ScheduledTasksPreviewView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let edit: ScheduledTasksEdit
    let onSaved: (ScheduledTasksSaveResult) -> Void
    let onUncertain: (String) -> Void
    @State private var confirming = false
    @State private var running = false
    @State private var attempted = false
    @State private var result: ScheduledTasksSaveResult?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("读取时内容") {
                    Text(edit.observed.contents.map { $0.isEmpty ? "文件为空" : $0 } ?? "文件不存在")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Section("将保存的完整内容") {
                    Text(edit.proposed.isEmpty ? "空文件：删除全部任务与注释" : edit.proposed)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Section {
                    Text("任务将以路由器 root 身份按路由器时间执行。保存立即写入整个文件；没有自动回滚。")
                    Button("保存并请求重载", role: .destructive) { confirming = true }
                        .disabled(attempted || running || store.isMutating || store.pendingConfiguration != nil || edit.connectionID != store.connectionID)
                        .accessibilityIdentifier("cron-save")
                    if running { ProgressView("正在保存并重读核对…") }
                    if let result { ScheduledTasksResultView(result: result) }
                    if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                }
            }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("计划任务变更")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(running) } }
                .confirmationDialog("保存这些计划任务？", isPresented: $confirming, titleVisibility: .visible) {
                    Button("确认保存并请求重载", role: .destructive) { Task { await save() } }
                    Button("取消", role: .cancel) {}
                } message: { Text("这会立即修改路由器任务文件。无效语法可能导致任务不执行，请仔细核对。") }
        }.interactiveDismissDisabled(running)
    }
    private func save() async {
        guard !attempted, edit.connectionID == store.connectionID else { return }
        running = true; attempted = true
        defer { running = false }
        do {
            let response = try await store.saveScheduledTasks(observed: edit.observed, text: edit.proposed)
            guard edit.connectionID == store.connectionID else { return }
            result = response; onSaved(response)
        } catch {
            guard edit.connectionID == store.connectionID else { return }
            let message = FriendlyError.message(error)
            self.error = message; onUncertain(message)
        }
    }
}

private struct ScheduledTasksResultView: View {
    let result: ScheduledTasksSaveResult
    var body: some View {
        if result.savedAndVerified {
            Text("任务文件已保存，重读内容与提交内容一致。")
        }
        if let reload = result.reload {
            LabeledContent("cron 重载退出码", value: String(reload.exitCode))
            Text(reload.exitCode == 0 ? "重载程序返回 0；不代表任务语法正确或任务已执行。" : "重载程序返回失败。请核对系统日志、权限与 cron 启动项。")
                .foregroundStyle(reload.exitCode == 0 ? AppPalette.muted : AppPalette.orange)
            if !reload.stdout.isEmpty { Text(reload.stdout).textSelection(.enabled) }
            if !reload.stderr.isEmpty { Text(reload.stderr).foregroundStyle(AppPalette.orange).textSelection(.enabled) }
        }
        if let error = result.reloadError {
            Text("cron 重载未确认：" + error)
                .foregroundStyle(AppPalette.orange).textSelection(.enabled)
        }
    }
}

private struct ScheduledTasksHelpView: View {
    var body: some View {
        List {
            Section("每行一个任务") {
                Text("分钟 小时 日期 月份 星期 命令").font(.system(.callout, design: .monospaced))
                Text("这是 root 用户任务文件，时间字段后直接填写命令，不额外填写用户名。以 # 开头的行是注释。")
                Text("通配、范围、列表、步长与扩展时间格式取决于路由器安装的 cron 实现。App 保留已有语法，不承诺固件支持全部扩展。")
            }
            Section("时间与执行") {
                Text("执行使用路由器的时钟与时区。请在系统设置核对时间同步；App 不会用手机时区换算文件内容。")
                Text("保存不是立即运行任务。cron 重载返回 0 也不证明各行有效；请在到期后核对系统日志和任务实际输出。")
            }
            Section("保存与恢复") {
                Text("预览显示原文件和将保存的完整内容。保存前重读检查冲突；保存后逐字核对。内容冲突或读写错误会阻止直接重试。")
                Text("此文件不属于 UCI 事务，没有超时回滚。需要恢复时，重新读取最新文件、编辑为所需内容，再预览提交。")
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("计划任务说明")
    }
}
