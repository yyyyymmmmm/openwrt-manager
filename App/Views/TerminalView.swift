import SwiftUI
import UIKit
import OpenWrtKit
import OpenWrtSSH

/// The native terminal (phase 3, spec 0A): a real SSH session to the
/// router rendered by the kit's VT parser. Credentials come from the
/// active profile (Keychain copy when remembered, otherwise a one-time
/// prompt that is never stored by this view).
///
/// Input (round 6): the surface itself is the text input
/// (TerminalSurfaceView) — keystrokes become PTY bytes as they happen
/// and the shell's own echo is the only editing state. The previous
/// design typed into a TextField and diffed its text against the last
/// value to guess the bytes; any divergence between the field's text
/// and the shell's line (Ctrl+C, mid-line edits, execution) broke
/// input, Return included.
struct TerminalView: View {
    @Environment(RouterStore.self) private var store
    @Environment(SSHTrustStore.self) private var sshTrust
    @State private var parser = TerminalParser(columns: 80, rows: 24)
    @State private var session: SSHTerminalSession?
    @State private var phase: Phase = .idle
    @State private var password = ""
    @State private var fingerprint: String?
    /// First-use gate (package C): the presented fingerprint of a
    /// router with no trust on file. The session exists but the
    /// surface stays covered until the user confirms or disconnects.
    @State private var trustPrompt: String?
    /// Changed-key block (package C): the router presented a key
    /// that differs from the trusted one. Connection is refused
    /// until the user explicitly re-trusts from this notice.
    @State private var changedNotice: (trusted: String, presented: String)?
    @State private var receiveTask: Task<Void, Never>?
    @State private var focusToken = 0
    /// The grid the surface currently lays out at (package D): starts
    /// at the classic 80×24 and follows the surface's own reports —
    /// rotation, split view and pinch-zoom all resize the parser and
    /// the PTY together, never one without the other.
    @State private var gridColumns = 80
    @State private var gridRows = 24
    #if DEBUG
    @State private var stubbedBytes = Data()
    #endif

    private enum Phase { case idle, connecting, connected, failed(String) }

    #if DEBUG
    /// UI-test seam (DEBUG only, same rule as UITestingSeed): with
    /// -ZiroxSeedTerminal the view opens in the connected state and
    /// every byte the input surface produces lands in stubbedBytes
    /// instead of an SSH session, so the suite can assert the exact
    /// byte stream typing produces.
    private var isTerminalStubbed: Bool {
        ProcessInfo.processInfo.arguments.contains("-ZiroxSeedTerminal")
    }
    #endif

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            switch phase {
            case .idle, .failed:
                connectPanel
            case .connecting:
                HStack { ProgressView(); Text("正在建立 SSH 连接…") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .connected:
                if let trustPrompt {
                    trustGate(fingerprint: trustPrompt)
                } else {
                    terminalSurface
                }
            }
            if let changedNotice {
                changedKeyPanel(notice: changedNotice)
            }
            if case .failed(let message) = phase {
                ErrorStateView(message: message)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            if isTerminalStubbed, case .idle = phase { phase = .connected }
            #endif
        }
        .onDisappear {
            receiveTask?.cancel()
            if let session { Task { await session.close() } }
        }
    }

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label("通过 SSH 原生连接到 \(store.activeProfile?.name ?? L10n.string("路由器"))（\(store.activeProfile?.username ?? "root")）。",
                  systemImage: "terminal")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            if canUseSavedPassword {
                Text("将使用档案中保存的密码登录。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            } else {
                SecureField("SSH 密码（不保存）", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Button("连接") { Task { await connect() } }
                .buttonStyle(AppPrimaryButtonStyle())
                .disabled(!canUseSavedPassword && password.isEmpty)
            if let fingerprint, !fingerprint.isEmpty {
                Text("主机密钥指纹：\(HostKeyFingerprint.displayForm(hexDigest: fingerprint))")
                    .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    .textSelection(.enabled)
            }
        }
    }

    /// First-use confirmation: the fingerprint the router just
    /// presented, shown in the comparable OpenSSH form. Nothing of
    /// the session is visible until the user trusts it.
    private func trustGate(fingerprint presented: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label("首次连接这台路由器，请核对主机指纹", systemImage: "lock.shield")
                .font(AppTypography.rowTitle)
            Text("下面是路由器在本次连接中出示的 SSH 主机指纹。请与路由器本地显示或以往记录的指纹核对一致后再信任。信任后，下次连接将自动校验；指纹一旦变化，连接会被阻断并提醒你。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            Text(HostKeyFingerprint.displayForm(hexDigest: presented))
                .font(AppTypography.secondary.monospaced())
                .textSelection(.enabled)
            HStack(spacing: AppSpacing.sm) {
                Button("信任并继续") {
                    guard let profile = store.activeProfile,
                          let host = URL(string: profile.address)?.host else { return }
                    sshTrust.confirmTrust(host: host, port: 22, fingerprint: presented)
                    EventLogStore.shared.append(
                        category: .system, kind: .system,
                        title: L10n.string("已信任 SSH 主机指纹"),
                        detail: L10n.format("%@：%@", host, HostKeyFingerprint.displayForm(hexDigest: presented)),
                        routerID: profile.id.uuidString)
                    trustPrompt = nil
                }
                .buttonStyle(AppPrimaryButtonStyle())
                Button("断开连接", role: .destructive) { disconnectSession() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Changed-key block: shown after a verified connection was
    /// refused because the presented key differs from the trusted
    /// one. Re-trusting is only possible from this explicit action.
    private func changedKeyPanel(notice: (trusted: String, presented: String)) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("主机指纹已变化，连接已被阻断", systemImage: "exclamationmark.shield")
                .font(AppTypography.rowTitle).foregroundStyle(AppPalette.red)
            Text("这台路由器出示的 SSH 指纹与已信任的记录不一致。可能原因：路由器重装或刷机后生成了新密钥，或连接被中间人劫持。请先通过可信方式核对新指纹，确认无误后再重新信任。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            Text("已信任：\(HostKeyFingerprint.displayForm(hexDigest: notice.trusted))")
                .font(AppTypography.metadata.monospaced()).textSelection(.enabled)
            Text("本次出示：\(HostKeyFingerprint.displayForm(hexDigest: notice.presented))")
                .font(AppTypography.metadata.monospaced()).textSelection(.enabled)
            HStack(spacing: AppSpacing.sm) {
                Button("重新确认并信任新指纹", role: .destructive) {
                    guard let profile = store.activeProfile,
                          let host = URL(string: profile.address)?.host else { return }
                    sshTrust.confirmTrust(host: host, port: 22, fingerprint: notice.presented)
                    EventLogStore.shared.append(
                        category: .system, kind: .system,
                        title: L10n.string("已重新信任 SSH 主机指纹"),
                        detail: L10n.format("%@：%@", host, HostKeyFingerprint.displayForm(hexDigest: notice.presented)),
                        routerID: profile.id.uuidString)
                    changedNotice = nil
                    Task { await connect() }
                }
                .buttonStyle(.bordered)
                Button("取消") { changedNotice = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func disconnectSession() {
        receiveTask?.cancel()
        if let session { Task { await session.close() } }
        self.session = nil
        trustPrompt = nil
        phase = .idle
    }

    private var terminalSurface: some View {
        VStack(spacing: AppSpacing.sm) {
            TerminalSurfaceView(text: renderedText, focusToken: focusToken, onSend: sendToShell,
                                onResize: handleResize, onPaste: handlePaste)
                .frame(maxHeight: .infinity)
                .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .accessibilityIdentifier("terminalSurface")
            keyBar
            #if DEBUG
            if isTerminalStubbed {
                Text(stubbedBytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                    .font(AppTypography.metadata)
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("terminalByteLog")
            }
            #endif
            Button("断开连接", role: .destructive) { disconnectSession() }
        }
    }

    /// The key bar (package D): the Termius/Blink set — modifiers and
    /// navigation keys a soft keyboard cannot produce — in a
    /// horizontally scrolling strip so large Dynamic Type sizes never
    /// squeeze keys off the ends. Paste and copy ride the same strip.
    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach([("esc", TerminalInput.Key.escape), ("ctrl+c", .control("C")),
                         ("ctrl+d", .control("D")), ("ctrl+z", .control("Z")),
                         ("ctrl+l", .control("L")), ("tab", .tab), ("回车", .enter),
                         ("↑", .arrowUp), ("↓", .arrowDown),
                         ("←", .arrowLeft), ("→", .arrowRight),
                         ("home", .home), ("end", .end),
                         ("PgUp", .pageUp), ("PgDn", .pageDown), ("del", .delete)],
                        id: \.0) { label, key in
                    Button(label) {
                        sendToShell(TerminalInput.data(for: key))
                        focusToken += 1
                    }
                    .buttonStyle(.bordered)
                    .font(AppTypography.metadata)
                }
                Button("粘贴") {
                    if let text = UIPasteboard.general.string, !text.isEmpty { handlePaste(text) }
                    focusToken += 1
                }
                .buttonStyle(.bordered)
                .font(AppTypography.metadata)
                Button("复制") {
                    UIPasteboard.general.string = renderedText
                    focusToken += 1
                }
                .buttonStyle(.bordered)
                .font(AppTypography.metadata)
            }
        }
    }

    /// One resize path for every trigger (rotation, split view,
    /// pinch): parser and PTY move together or not at all.
    private func handleResize(columns: Int, rows: Int) {
        guard columns != gridColumns || rows != gridRows else { return }
        gridColumns = columns
        gridRows = rows
        var copy = parser
        copy.resize(columns: columns, rows: rows)
        parser = copy
        session?.resize(columns: columns, rows: rows)
    }

    /// Pastes take the bracketed encoding when the remote program
    /// enabled mode 2004, the plain committed-text encoding otherwise.
    private func handlePaste(_ text: String) {
        sendToShell(TerminalInput.data(forPaste: text, bracketed: parser.bracketedPasteEnabled))
    }

    private var renderedText: String {
        let scrollback = parser.screen.scrollback.map { row in
            TerminalScreen.text(forRow: row)
        }
        return (scrollback + [parser.screen.visibleText]).joined(separator: "\n")
    }

    private var storedPasswordAvailable: Bool {
        guard let profile = store.activeProfile,
              let credential = try? store.credential(for: profile) else { return false }
        return credential.password != nil
    }

    /// False once the Face ID check for the saved password was
    /// refused (package K): the panel then offers the typed-password
    /// field instead of silently spending the saved one.
    @State private var savedPasswordDeclined = false

    private var canUseSavedPassword: Bool {
        storedPasswordAvailable && !savedPasswordDeclined
    }

    /// The one byte sink for every input path — surface keystrokes,
    /// IME commits and the key bar all land here.
    private func sendToShell(_ data: Data) {
        #if DEBUG
        if isTerminalStubbed {
            stubbedBytes.append(data)
            return
        }
        #endif
        session?.send(data)
    }

    private func connect() async {
        guard let profile = store.activeProfile,
              let host = URL(string: profile.address)?.host else {
            phase = .failed("无法从档案地址解析主机。")
            return
        }
        let loginPassword: String
        if let saved = (try? store.credential(for: profile))?.password, !savedPasswordDeclined {
            // Spending the saved password is an interactive
            // credential use (package K): the Face ID gate runs
            // first, exactly like a one-tap router switch. A typed
            // password never needs the gate — the user just gave it.
            switch await CredentialGate.authorize(reason: CredentialGate.savedPasswordReason) {
            case .authorized:
                loginPassword = saved
            case .refused, .unavailable:
                savedPasswordDeclined = true
                phase = .failed("身份验证未完成，未使用保存的密码。请输入 SSH 密码后重试。")
                return
            }
        } else {
            loginPassword = password
        }
        phase = .connecting
        fingerprint = nil
        trustPrompt = nil
        // Host-key trust (package C): with a trusted fingerprint on
        // file the handshake itself must match it — a mismatch fails
        // the connection before any shell exists. Without one, the
        // first key is accepted for inspection only and the surface
        // stays gated until the user confirms it.
        let trusted = sshTrust.trustedFingerprint(host: host, port: 22)
        let policy: SSHTerminalSession.HostKeyPolicy = trusted.map { .verifySHA256($0) } ?? .acceptAny
        do {
            let established = try await SSHTerminalSession.connect(
                host: host, port: 22, username: profile.username, password: loginPassword,
                policy: policy)
            session = established
            let stream = try await established.openShell(columns: gridColumns, rows: gridRows)
            // The fingerprint exists only once the handshake has
            // completed, which openShell guarantees: read it now, not
            // right after connect (that produced the empty label).
            let presented = established.hostKeySHA256
            fingerprint = presented.isEmpty ? nil : presented
            phase = .connected
            if trusted == nil, !presented.isEmpty {
                switch sshTrust.evaluate(host: host, port: 22, presentedFingerprint: presented) {
                case .firstUse(let canonical):
                    trustPrompt = canonical
                case .match:
                    break
                case .changed(let known, let now):
                    disconnectSession()
                    changedNotice = (trusted: known, presented: now)
                    return
                }
            }
            receiveTask = Task {
                for await data in stream {
                    var copy = parser
                    copy.feed(data)
                    parser = copy
                }
            }
        } catch let error as SSHSessionError {
            if case .hostKeyMismatch(let expected, let actual) = error {
                changedNotice = (trusted: expected, presented: actual)
                EventLogStore.shared.append(
                    category: .system, kind: .system,
                    title: L10n.string("SSH 主机指纹不一致，连接被阻断"),
                    detail: L10n.format("%@ 出示的指纹与已信任记录不一致。", host),
                    routerID: profile.id.uuidString)
                phase = .idle
            } else {
                phase = .failed(FriendlyError.message(error))
            }
        } catch {
            phase = .failed(FriendlyError.message(error))
        }
    }
}
