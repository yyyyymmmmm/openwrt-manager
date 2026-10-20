import SwiftUI
import OpenWrtKit

struct RouterPasswordView: View {
    @Environment(RouterStore.self) private var store
    @State private var snapshot: RouterAccountsSnapshot?
    @State private var selectedID: String?
    @State private var oldPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var message: String?
    @State private var confirmSave = false
    @State private var needsRead = false
    @State private var uncertainAccountID: String?
    @State private var loadedConnectionID: UUID?
    private var account: RouterAccount? { snapshot?.accounts.first { $0.id == selectedID } }
    private var passwordValidation: String? {
        guard let policy = snapshot?.policy, !password.isEmpty else { return nil }
        do { try policy.validate(password); return nil }
        catch { return FriendlyError.message(error) }
    }
    private var valid: Bool {
        guard let account, snapshot?.policy != nil else { return false }
        return password == confirmation && !password.isEmpty &&
            (account.kind == .unix || !oldPassword.isEmpty) &&
            passwordValidation == nil && !saving && !loading && !needsRead && uncertainAccountID != account.id &&
            !store.isMutating && store.pendingConfiguration == nil
    }

    var body: some View {
        Form {
            Section {
                if loading { ProgressView("正在读取账户与密码策略…") }
                if let snapshot {
                    if snapshot.accounts.isEmpty { Text("没有读取到可管理的账户。") }
                    Picker("账户", selection: Binding(get: { selectedID ?? snapshot.accounts.first?.id ?? "" }, set: { selectedID = $0; oldPassword = ""; password = ""; confirmation = "" })) {
                        ForEach(snapshot.accounts) { account in Text(account.username + " · " + account.kind.title).tag(account.id) }
                    }
                    if let policy = snapshot.policy {
                        Text(policyDescription(policy)).foregroundStyle(AppPalette.muted)
                    }
                    if snapshot.writable == false { Label("当前账户没有修改密码权限。", systemImage: "lock").foregroundStyle(AppPalette.orange) }
                    ForEach(snapshot.issues, id: \.self) { issue in Text(issue).foregroundStyle(AppPalette.orange) }
                    if uncertainAccountID != nil { Label("上次密码修改结果未确认。重新读取账户不能核对密码，请断开连接并用新密码登录核对。", systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.orange) }
                }
                Button("重新读取账户") { Task { await load() } }.disabled(loading || saving)
            } header: { Text("账户") }

            Section("修改密码") {
                SecureField("旧密码（rpcd 账户必填）", text: $oldPassword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("新密码", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("再次输入新密码", text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !confirmation.isEmpty && password != confirmation { Text("两次输入的新密码不一致。 ").foregroundStyle(AppPalette.orange) }
                if let passwordValidation { Text(passwordValidation).foregroundStyle(AppPalette.orange) }
                Button("预览并修改密码", role: .destructive) { confirmSave = true }
                    .disabled(!valid || snapshot?.writable != true || snapshot?.policy == nil)
            }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            if let message { Section("结果") { Text(message).foregroundStyle(AppPalette.accent).textSelection(.enabled) } }
            Section { Text("密码不会保存到草稿、活动记录或普通设置。修改当前登录账户后，App 会先清除旧凭据，再用新密码建立真实会话；如果网络中断，结果可能无法确认，请不要直接重复提交。") }
                .foregroundStyle(AppPalette.muted)
        }
        .font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("账户密码")
        .task(id: store.connectionID) {
            if loadedConnectionID != store.connectionID {
                loadedConnectionID = store.connectionID
                snapshot = nil; selectedID = nil; uncertainAccountID = nil; needsRead = false
                oldPassword = ""; password = ""; confirmation = ""
            }
            await load()
        }
        .confirmationDialog("确认修改密码？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("确认修改", role: .destructive) { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将向路由器发送账户密码修改请求。修改后必须用新密码重新登录核对，旧密码不会自动恢复。")
        }
    }

    private func policyDescription(_ policy: RouterPasswordPolicy) -> String {
        guard policy.enabled else { return "固件没有启用密码策略。" }
        var items = [String](); if let n = policy.minimumLength { items.append("至少 \(n) 个字符") }
        if policy.digits { items.append("数字") }; if policy.mixedCase { items.append("大小写") }; if policy.specialCharacters { items.append("特殊字符") }
        return "固件密码策略：" + (items.isEmpty ? "已启用" : items.joined(separator: "、"))
    }
    private func load() async {
        let generation = store.connectionID; loading = true; error = nil; message = nil
        needsRead = false
        defer { if generation == store.connectionID { loading = false } }
        do {
            let value = try await store.accounts()
            guard generation == store.connectionID, !Task.isCancelled else { return }
            snapshot = value
            if !value.accounts.contains(where: { $0.id == selectedID }) { selectedID = value.accounts.first?.id }
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            snapshot = nil; selectedID = nil; self.error = FriendlyError.message(error)
        }
    }
    private func save() async {
        guard let account, let policy = snapshot?.policy, valid else { return }
        saving = true; error = nil; message = nil
        defer { saving = false }
        do {
            message = try await store.changePassword(account: account, policy: policy, password: password, oldPassword: oldPassword)
            oldPassword = ""; password = ""; confirmation = ""; uncertainAccountID = nil; needsRead = false
            snapshot = try? await store.accounts()
        } catch let passwordError as RouterPasswordError {
            error = passwordError.localizedDescription
            if passwordError == .uncertain { needsRead = true; uncertainAccountID = account.id }
        } catch {
            error = FriendlyError.message(error)
        }
    }
}

struct SSHAuthorizedKeysView: View {
    @Environment(RouterStore.self) private var store
    @State private var observed: RouterSystemFileSnapshot?
    @State private var draft = ""
    @State private var newKey = ""
    @State private var loading = false
    @State private var writable = false
    @State private var error: String?
    @State private var permissionError: String?
    @State private var message: String?
    @State private var preview: FilePreview?
    @State private var pendingDelete: SSHAuthorizedKey?
    @State private var needsRead = false
    @State private var loadedConnectionID: UUID?
    @State private var initialReadFinished = false
    private var parsed: SSHAuthorizedKeysSnapshot? { try? SSHAuthorizedKeysSnapshot(text: draft) }

    var body: some View {
        Form {
            Section {
                if loading { ProgressView("正在读取 authorized_keys…") }
                if let observed {
                    Label(writable ? "允许编辑" : "当前仅可查看", systemImage: writable ? "pencil" : "lock")
                    if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                    if observed.contents == nil { Text("已确认 /etc/dropbear/authorized_keys 不存在；新增公钥会创建它。") }
                    if let parsed {
                        ForEach(parsed.keys) { key in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    NavigationLink { SSHKeyDetailView(key: key) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(key.comment ?? "未命名公钥").font(AppTypography.rowTitle)
                                            Text(key.algorithm + " · 第 \(key.lineNumber) 行").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                                        }
                                    }.buttonStyle(.plain)
                                    Text(key.raw).font(.system(.caption2, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                                }
                                Spacer()
                                Button("删除", role: .destructive) { pendingDelete = key }.disabled(!writable || loading || needsRead || preview != nil || store.isMutating || store.pendingConfiguration != nil)
                            }
                        }
                        ForEach(parsed.unrecognizedRows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Label("未识别内容已保留 · 第 \(row.lineNumber) 行", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(AppPalette.orange)
                                Text(row.text).font(.system(.caption2, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                            }
                        }
                        if parsed.keys.isEmpty && parsed.unrecognizedRows.isEmpty { Text("当前文件为空。") }
                    } else { Text("文件内容不是可解析的 OpenSSH 文本，已停止编辑。") }
                }
                Button("重新读取") { Task { await load() } }.disabled(loading || preview != nil || store.isMutating)
            } header: { Text("已授权公钥") } footer: { Text("保存仅限 /etc/dropbear/authorized_keys；注释、空行和未识别的旧内容会原样保留。") }

            Section("添加公钥") {
                TextField("粘贴完整 OpenSSH 公钥行", text: $newKey, axis: .vertical)
                    .font(.system(.callout, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("加入预览") { add() }.disabled(!writable || loading || needsRead || observed == nil || newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preview != nil || store.isMutating || store.pendingConfiguration != nil)
            }
            if needsRead { Text("上次保存未确认。请先重新读取文件；新公钥输入保留供比对。").foregroundStyle(AppPalette.orange) }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            if let message { Section("结果") { Text(message).foregroundStyle(AppPalette.accent).textSelection(.enabled) } }
        }
        .font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("SSH 公钥")
        .task(id: store.connectionID) {
            if loadedConnectionID != store.connectionID {
                loadedConnectionID = store.connectionID; observed = nil; draft = ""; newKey = ""; initialReadFinished = false; needsRead = false
            }
            guard !initialReadFinished else { return }
            await load()
        }
        .sheet(item: $preview) { edit in
            FilePreviewView(edit: edit, onSaved: { saved in
                observed = saved; draft = saved.contents ?? ""; message = "SSH 公钥文件已写入并重读核对。"; error = nil
                newKey = ""; needsRead = false
            }, onUncertain: { detail in
                error = detail; message = nil; needsRead = true
            })
        }
        .confirmationDialog("删除这条 SSH 公钥？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除并预览", role: .destructive) { if let key = pendingDelete { remove(key) } }
            Button("取消", role: .cancel) {}
        } message: { Text(pendingDelete?.raw ?? "") }
    }
    private func load() async {
        let generation = store.connectionID; loading = true; error = nil; message = nil; permissionError = nil
        writable = false
        defer { if generation == store.connectionID { loading = false; if !Task.isCancelled { initialReadFinished = true } } }
        do {
            let value = try await store.systemFile(.sshKeys)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            observed = value; draft = value.contents ?? ""; needsRead = false
        } catch { if generation == store.connectionID { observed = nil; error = FriendlyError.message(error) } }
        do {
            let allowed = try await store.systemFileWritable(.sshKeys)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            writable = allowed
            if !allowed { permissionError = "账户没有 /etc/dropbear/authorized_keys 的写入权限。" }
        } catch { if generation == store.connectionID { writable = false; permissionError = "无法确认写入权限：" + FriendlyError.message(error) } }
    }
    private func add() {
        guard let observed else { return }
        do { let proposed = try SSHAuthorizedKeysSnapshot(text: observed.contents ?? "").adding(newKey); preview = FilePreview(observed: observed, proposed: proposed, connectionID: store.connectionID); error = nil }
        catch { error = FriendlyError.message(error) }
    }
    private func remove(_ key: SSHAuthorizedKey) {
        guard let observed else { return }
        do { let proposed = try SSHAuthorizedKeysSnapshot(text: observed.contents ?? "").removing(key); preview = FilePreview(observed: observed, proposed: proposed, connectionID: store.connectionID); pendingDelete = nil; error = nil }
        catch { error = FriendlyError.message(error) }
    }
}

struct LocalStartupScriptView: View {
    var body: some View { RouterTextFileView(file: .localStartup) }
}

struct RouterTextFileView: View {
    let file: RouterSystemFile
    private var identifier: String { file == .localStartup ? "startup-script" : "router-file-" + file.rawValue }
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var observed: RouterSystemFileSnapshot?
    @State private var draft = ""
    @State private var writable = false
    @State private var loading = false
    @State private var needsRead = false
    @State private var initialReadFinished = false
    @State private var loadedConnectionID: UUID?
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var permissionError: String?
    @State private var message: String?
    @State private var preview: FilePreview?
    @State private var discard = false
    @State private var reloadPrompt = false
    @FocusState private var editorFocused: Bool
    private var changed: Bool { observed != nil && draft != (observed?.contents ?? "") }
    private var busy: Bool { loading || store.isMutating || store.pendingConfiguration != nil }
    var body: some View {
        Form {
            Section { Text(file.explanation) }
                .foregroundStyle(AppPalette.muted)
            Section("文件内容") {
                if loading { ProgressView("正在读取 " + file.path + "…") }
                if observed != nil {
                    Label(writable ? "允许编辑" : "当前仅可查看", systemImage: writable ? "pencil" : "lock")
                    if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                    TextEditor(text: $draft).font(.system(.callout, design: .monospaced)).frame(minHeight: 280)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($editorFocused)
                        .disabled(!writable || busy || needsRead).accessibilityIdentifier(identifier + "-editor")
                    Button("预览并保存") { makePreview() }.disabled(!writable || !changed || busy || needsRead)
                        .accessibilityIdentifier(identifier + "-preview")
                }
                Button("重新读取", action: requestRead).disabled(busy).accessibilityIdentifier(identifier + "-read")
            }
            if needsRead { Text("保存结果未确认，请先重新读取并比对草稿，勿直接重试。").foregroundStyle(AppPalette.orange) }
            if let observed, observed.contents == nil { Text("已确认文件不存在；保存会创建 " + file.path + "。").foregroundStyle(AppPalette.orange) }
            if let error { Section("请求未完成") { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) } }
            if let message { Section("结果") { Text(message).foregroundStyle(AppPalette.accent).textSelection(.enabled) } }
        }
        .font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(file.title)
        .navigationBarBackButtonHidden(changed || busy)
        .toolbar {
            if changed || busy {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回", systemImage: "chevron.left") { if changed { discard = true } else { dismiss() } }.disabled(busy)
                }
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { editorFocused = false } }
        }
        .confirmationDialog("放弃未保存的文件修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("重新读取路由器文件", isPresented: $reloadPrompt, titleVisibility: .visible) {
            Button("保留草稿，读取最新文件") { Task { await load(keepDraft: true) } }
            Button("放弃草稿并重新读取", role: .destructive) { Task { await load(keepDraft: false) } }
            Button("取消", role: .cancel) {}
        } message: { Text("保留草稿后，请在预览中比对最新文件并手动合并其他管理员的修改。") }
        .task(id: store.connectionID) {
            if loadedConnectionID != store.connectionID {
                loadedConnectionID = store.connectionID; initialReadFinished = false
                observed = nil; draft = ""; needsRead = false; message = nil
            }
            guard !initialReadFinished else { return }
            await load(keepDraft: observed != nil)
        }
        .sheet(item: $preview) { edit in
            FilePreviewView(edit: edit, onSaved: { saved in
                observed = saved; draft = saved.contents ?? ""; error = nil; needsRead = false
                message = file.savedExplanation
            }, onUncertain: { detail in needsRead = true; error = detail; message = nil })
        }
    }
    private func requestRead() {
        guard !busy else { return }
        if changed || needsRead { reloadPrompt = true }
        else { Task { await load(keepDraft: false) } }
    }
    private func load(keepDraft: Bool) async {
        let generation = store.connectionID, request = UUID()
        requestID = request; loading = true; writable = false; error = nil; permissionError = nil; message = nil
        defer {
            if requestID == request {
                loading = false
                if generation == store.connectionID, !Task.isCancelled { initialReadFinished = true }
            }
        }
        do {
            let value = try await store.systemFile(file)
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            observed = value; needsRead = false
            if !keepDraft { draft = value.contents ?? "" }
            do {
                let allowed = try await store.systemFileWritable(file)
                guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
                writable = allowed
                if !allowed { permissionError = "账户没有 " + file.path + " 的写入权限。" }
            } catch {
                guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
                permissionError = "无法确认写入权限：" + FriendlyError.message(error)
            }
        } catch {
            guard generation == store.connectionID, requestID == request, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
    private func makePreview() {
        guard let observed else { return }
        do { preview = FilePreview(observed: observed, proposed: try file.prepared(draft), connectionID: store.connectionID); error = nil }
        catch { error = FriendlyError.message(error) }
    }
}

private struct SSHKeyDetailView: View {
    let key: SSHAuthorizedKey
    var body: some View {
        List {
            Section("公钥") {
                LabeledContent("算法", value: key.algorithm)
                LabeledContent("来源行", value: String(key.lineNumber))
                LabeledContent("注释", value: key.comment ?? "未提供")
            }
            Section("完整 OpenSSH 内容") { Text(key.raw).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("公钥详情")
    }
}

private struct FilePreview: Identifiable {
    let id = UUID()
    let observed: RouterSystemFileSnapshot
    let proposed: String
    let connectionID: UUID
}
private struct FilePreviewView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let edit: FilePreview
    let onSaved: (RouterSystemFileSnapshot) -> Void
    let onUncertain: (String) -> Void
    @State private var running = false
    @State private var attempted = false
    @State private var result: String?
    @State private var error: String?
    var body: some View {
        NavigationStack { List {
            Section("读取时内容") { Text(edit.observed.contents ?? "文件不存在").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section("将保存的完整内容") { Text(edit.proposed.isEmpty ? "空文件" : edit.proposed).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Section {
                Text("保存前会重新读取并检查冲突，保存后核对文件内容。此操作没有自动回滚；请避免其他管理员同时编辑。")
                Button("确认写入", role: .destructive) { Task { await save() } }
                    .disabled(running || attempted || store.isMutating || store.pendingConfiguration != nil || edit.connectionID != store.connectionID)
                    .accessibilityIdentifier("system-file-save")
                if running { ProgressView("正在写入并重读核对…") }
                if let result { Text(result).foregroundStyle(AppPalette.accent).accessibilityIdentifier("system-file-result") }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(edit.observed.file.title)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(attempted ? "完成" : "取消") { dismiss() }.disabled(running) } }
        }.interactiveDismissDisabled(running)
    }
    private func save() async {
        guard !attempted, edit.connectionID == store.connectionID else { return }
        attempted = true; running = true
        defer { running = false }
        do {
            let saved = try await store.saveSystemFile(observed: edit.observed, text: edit.proposed)
            guard edit.connectionID == store.connectionID else { return }
            result = "文件已写入，重读内容与提交一致。"; onSaved(saved); dismiss()
        } catch {
            guard edit.connectionID == store.connectionID else { return }
            let detail = FriendlyError.message(error)
            self.error = detail; onUncertain(detail)
        }
    }
}
