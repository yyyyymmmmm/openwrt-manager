import SwiftUI
import OpenWrtKit

/// Administration security page (package J, audit F4): the two
/// actions LuCI's administration page exists for — changing the
/// router password and managing SSH authorized keys — as native
/// flows. The dropbear/uhttpd configuration that used to be this
/// page's whole content stays one tap inside.
///
/// Password change discipline: the router is changed first through
/// rpcd's luci.setPassword (its sanctioned channel), the NEW
/// password is then proven with a fresh login, and only then is it
/// adopted locally (in-memory credential box + Keychain copy when
/// the profile remembers one). The password itself never enters a
/// log, a diagnostic record, or this view's state beyond the two
/// secure fields, which are cleared on completion.
struct AdminSecurityView: View {
    @Environment(RouterStore.self) private var store
    let page: PageDescriptor

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showingPasswordConfirm = false
    @State private var passwordWorking = false
    @State private var passwordFeedback: String?
    @State private var passwordFailed = false

    @State private var keysState: LoadState<[String]> = .loading
    @State private var newKeyText = ""
    @State private var keyPendingRemoval: String?
    @State private var keysWorking = false
    @State private var keysFeedback: String?

    private static let authorizedKeysPath = "/etc/dropbear/authorized_keys"

    private var passwordReady: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword && !passwordWorking
    }

    var body: some View {
        List {
            passwordSection
            keysSection
            Section {
                NavigationLink {
                    UCIConfigView(title: page.title, configNames: page.configNames)
                } label: {
                    Label("SSH 与网页服务配置", systemImage: "gearshape.2")
                }
                Text("dropbear（SSH）与 uhttpd（网页服务）的详细配置仍在上方入口里；本页只把改密与 SSH 密钥这两件高频事做成专用流程。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadKeys() }
        .confirmationDialog(
            "确认修改路由器登录密码？",
            isPresented: $showingPasswordConfirm, titleVisibility: .visible
        ) {
            Button("修改密码", role: .destructive) { Task { await runPasswordChange() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("密码会立即在路由器上生效：其他设备与浏览器要用新密码重新登录。本机已保存的这台路由器密码会同步更新，不会把你锁在门外。当前连接不会中断。")
        }
        .confirmationDialog(
            "确认删除这把 SSH 密钥？",
            isPresented: Binding(get: { keyPendingRemoval != nil },
                                 set: { if !$0 { keyPendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除密钥", role: .destructive) {
                if let key = keyPendingRemoval { Task { await removeKey(key) } }
                keyPendingRemoval = nil
            }
            Button("取消", role: .cancel) { keyPendingRemoval = nil }
        } message: {
            Text("删除后，持有对应私钥的设备将无法再通过密钥登录这台路由器的 SSH。密码登录不受影响。")
        }
    }

    // MARK: Password

    private var passwordSection: some View {
        Section {
            SecureField("新密码", text: $newPassword)
                .textContentType(.newPassword)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("再次输入新密码", text: $confirmPassword)
                .textContentType(.newPassword)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("两次输入不一致。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            } else if !newPassword.isEmpty && newPassword.count < 8 {
                Text("密码不足 8 位，偏弱：建议用更长、只用于这台路由器的密码。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
            Button {
                showingPasswordConfirm = true
            } label: {
                Label("修改密码", systemImage: "key.horizontal")
            }
            .disabled(!passwordReady)
            if passwordWorking {
                HStack { ProgressView(); Text("正在修改并用新密码验证登录…") }
            }
            if let passwordFeedback {
                Text(passwordFeedback)
                    .font(AppTypography.secondary)
                    .foregroundStyle(passwordFailed ? AppPalette.red : AppPalette.muted)
            }
        } header: {
            Text("路由器登录密码")
        } footer: {
            Text("走路由器自己的正规改密通道（与电脑版管理页相同）。改完会先用新密码试登录一次，确认生效才更新本机保存的密码。")
        }
    }

    private func runPasswordChange() async {
        guard let client = store.adminSecurityClient, let profile = store.activeProfile else {
            passwordFeedback = "未连接路由器。"
            passwordFailed = true
            return
        }
        passwordWorking = true
        passwordFeedback = nil
        passwordFailed = false
        defer { passwordWorking = false }
        let candidate = newPassword
        do {
            try await client.setPassword(username: profile.username, password: candidate)
        } catch {
            passwordFeedback = L10n.format("路由器拒绝了改密：%@", FriendlyError.message(error))
            passwordFailed = true
            return
        }
        // Prove the new password before adopting it anywhere.
        guard await store.verifyLoginWithPassword(candidate) else {
            passwordFeedback = "路由器已接受改密请求，但用新密码试登录没有通过。本机保存的密码未更新——请断开后用新密码重新连接核对；若新密码也不行，再用旧密码试一次。"
            passwordFailed = true
            EventLogStore.shared.append(
                category: .operation, kind: .operation,
                title: "修改路由器登录密码（待核对）",
                detail: "路由器已接受改密，但新密码试登录未通过，本机凭据未更新。",
                routerID: profile.id.uuidString)
            return
        }
        do {
            try store.adoptNewPassword(candidate)
        } catch {
            passwordFeedback = "密码已在路由器上生效，但更新本机钥匙串失败：下次连接时请手动输入新密码。"
            passwordFailed = true
            return
        }
        newPassword = ""
        confirmPassword = ""
        passwordFeedback = "密码已修改，并已用新密码验证登录成功；本机凭据已同步更新。"
        EventLogStore.shared.append(
            category: .operation, kind: .operation,
            title: "修改路由器登录密码",
            detail: "已通过路由器正规通道改密，并用新密码验证登录成功；本机凭据已同步更新。密码本体不入记录。",
            routerID: profile.id.uuidString)
    }

    // MARK: SSH authorized keys

    private var keysSection: some View {
        Section {
            switch keysState {
            case .loading:
                ProgressView("正在读取 SSH 授权密钥…")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await loadKeys() } }
            case .loaded(let keys):
                if keys.isEmpty {
                    EmptyStateView(title: "暂无授权密钥", message: "还没有任何公钥被授权免密登录这台路由器的 SSH。在下方粘贴公钥即可添加。", symbol: "key.slash")
                } else {
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(AuthorizedKeys.displayName(for: key))
                                .font(AppTypography.rowTitle)
                            Text(key)
                                .font(AppTypography.metadata.monospaced())
                                .foregroundStyle(AppPalette.muted)
                                .lineLimit(2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) { keyPendingRemoval = key }
                        }
                    }
                }
                TextField("粘贴公钥（以 ssh-ed25519 / ssh-rsa 等开头）", text: $newKeyText, axis: .vertical)
                    .font(AppTypography.metadata.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                Button {
                    Task { await addKey() }
                } label: {
                    Label("添加密钥", systemImage: "plus.circle")
                }
                .disabled(newKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keysWorking)
                if keysWorking {
                    HStack { ProgressView(); Text("正在写入并回读验证…") }
                }
                if let keysFeedback {
                    Text(keysFeedback).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
        } header: {
            TermLabel(text: "SSH 授权密钥", term: "SSH 密钥")
        } footer: {
            Text("保存在路由器的 /etc/dropbear/authorized_keys，写入后回读验证；新 SSH 连接即生效，无需重启。")
        }
    }

    private func loadKeys() async {
        guard let files = store.fileClient else {
            keysState = .failed("未连接路由器。")
            return
        }
        do {
            let text = try await files.readText(path: Self.authorizedKeysPath)
            keysState = .loaded(AuthorizedKeys.parse(text))
        } catch {
            keysState = .failed(FriendlyError.message(error))
        }
    }

    private func addKey() async {
        guard case .loaded(let keys) = keysState else { return }
        let lines = newKeyText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.allSatisfy(AuthorizedKeys.isValidKeyLine) else {
            keysFeedback = "粘贴的内容不是合法的公钥行：应以 ssh-ed25519、ssh-rsa 等类型开头，后跟 Base64 密钥体。"
            return
        }
        let merged = keys + lines.filter { !keys.contains($0) }
        guard merged.count > keys.count else {
            keysFeedback = "这把密钥已经在授权列表里了。"
            return
        }
        await writeKeys(merged, success: "密钥已添加并回读验证。", eventTitle: "添加 SSH 授权密钥",
                        eventDetail: lines.map(AuthorizedKeys.displayName(for:)).joined(separator: "；"))
        newKeyText = ""
    }

    private func removeKey(_ key: String) async {
        guard case .loaded(let keys) = keysState else { return }
        await writeKeys(keys.filter { $0 != key }, success: "密钥已删除并回读验证。", eventTitle: "删除 SSH 授权密钥",
                        eventDetail: AuthorizedKeys.displayName(for: key))
    }

    private func writeKeys(_ keys: [String], success: String, eventTitle: String, eventDetail: String) async {
        guard let files = store.fileClient else { return }
        keysWorking = true
        defer { keysWorking = false }
        do {
            try await files.writeTextVerified(path: Self.authorizedKeysPath,
                                              content: AuthorizedKeys.serialize(keys))
            let reread = AuthorizedKeys.parse(try await files.readText(path: Self.authorizedKeysPath))
            guard reread == keys else {
                keysFeedback = "写入后回读不一致，请刷新页面核对路由器上的实际内容。"
                keysState = .loaded(reread)
                return
            }
            keysState = .loaded(keys)
            keysFeedback = success
            EventLogStore.shared.append(
                category: .operation, kind: .operation,
                title: eventTitle, detail: eventDetail,
                routerID: store.activeProfile?.id.uuidString)
        } catch {
            keysFeedback = L10n.format("写入失败：%@", FriendlyError.message(error))
        }
    }
}
