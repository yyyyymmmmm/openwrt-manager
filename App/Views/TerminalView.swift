import SwiftUI
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
    @State private var parser = TerminalParser(columns: 80, rows: 24)
    @State private var session: SSHTerminalSession?
    @State private var phase: Phase = .idle
    @State private var password = ""
    @State private var fingerprint: String?
    @State private var receiveTask: Task<Void, Never>?
    @State private var focusToken = 0
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
                terminalSurface
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
            if storedPasswordAvailable {
                Text("将使用档案中保存的密码登录。")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            } else {
                SecureField("SSH 密码（不保存）", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Button("连接") { Task { await connect() } }
                .buttonStyle(AppPrimaryButtonStyle())
                .disabled(!storedPasswordAvailable && password.isEmpty)
            if let fingerprint, !fingerprint.isEmpty {
                Text("主机密钥 SHA-256：\(fingerprint)")
                    .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    .textSelection(.enabled)
            }
        }
    }

    private var terminalSurface: some View {
        VStack(spacing: AppSpacing.sm) {
            TerminalSurfaceView(text: renderedText, focusToken: focusToken, onSend: sendToShell)
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
            Button("断开连接", role: .destructive) {
                receiveTask?.cancel()
                if let session { Task { await session.close() } }
                self.session = nil
                phase = .idle
            }
        }
    }

    private var keyBar: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach([("esc", TerminalInput.Key.escape), ("ctrl+c", .control("C")),
                     ("tab", .tab), ("回车", .enter), ("↑", .arrowUp), ("↓", .arrowDown),
                     ("←", .arrowLeft), ("→", .arrowRight)], id: \.0) { label, key in
                Button(label) {
                    sendToShell(TerminalInput.data(for: key))
                    focusToken += 1
                }
                .buttonStyle(.bordered)
                .font(AppTypography.metadata)
            }
        }
    }

    private var renderedText: String {
        let scrollback = parser.screen.scrollback.map { row in
            String(row.map(\.character)).trimmingCharacters(in: .whitespaces)
        }
        return (scrollback + [parser.screen.visibleText]).joined(separator: "\n")
    }

    private var storedPasswordAvailable: Bool {
        guard let profile = store.activeProfile,
              let credential = try? store.credential(for: profile) else { return false }
        return credential.password != nil
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
        if let credential = try? store.credential(for: profile), let saved = credential.password {
            loginPassword = saved
        } else {
            loginPassword = password
        }
        phase = .connecting
        fingerprint = nil
        do {
            let established = try await SSHTerminalSession.connect(
                host: host, port: 22, username: profile.username, password: loginPassword,
                policy: .acceptAny)
            session = established
            let stream = try await established.openShell(columns: 80, rows: 24)
            // The fingerprint exists only once the handshake has
            // completed, which openShell guarantees: read it now, not
            // right after connect (that produced the empty label).
            let presented = established.hostKeySHA256
            fingerprint = presented.isEmpty ? nil : presented
            phase = .connected
            receiveTask = Task {
                for await data in stream {
                    var copy = parser
                    copy.feed(data)
                    parser = copy
                }
            }
        } catch {
            phase = .failed(FriendlyError.message(error))
        }
    }
}
