import SwiftUI
import OpenWrtKit
import OpenWrtSSH

/// The native terminal (phase 3, spec 0A): a real SSH session to the
/// router rendered by the kit's VT parser. Credentials come from the
/// active profile (Keychain copy when remembered, otherwise a one-time
/// prompt that is never stored by this view).
struct TerminalView: View {
    @Environment(RouterStore.self) private var store
    @State private var parser = TerminalParser(columns: 80, rows: 24)
    @State private var session: SSHTerminalSession?
    @State private var phase: Phase = .idle
    @State private var password = ""
    @State private var input = ""
    @State private var fingerprint: String?
    @State private var receiveTask: Task<Void, Never>?

    private enum Phase { case idle, connecting, connected, failed(String) }

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
        .onDisappear {
            receiveTask?.cancel()
            if let session { Task { await session.close() } }
        }
    }

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label("通过 SSH 原生连接到 \(store.activeProfile?.name ?? "路由器")（\(store.activeProfile?.username ?? "root")）。",
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
            if let fingerprint {
                Text("主机密钥 SHA-256：\(fingerprint)")
                    .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    .textSelection(.enabled)
            }
        }
    }

    private var terminalSurface: some View {
        VStack(spacing: AppSpacing.sm) {
            ScrollView {
                Text(renderedText)
                    .font(AppTypography.metadata.monospaced())
                    .foregroundStyle(AppPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
            keyBar
            TextField("输入命令", text: $input)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: input) { old, new in
                    forwardInput(from: old, to: new)
                }
                .onSubmit {
                    session?.send(TerminalInput.data(for: .enter))
                }
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
                     ("tab", .tab), ("↑", .arrowUp), ("↓", .arrowDown),
                     ("←", .arrowLeft), ("→", .arrowRight)], id: \.0) { label, key in
                Button(label) { session?.send(TerminalInput.data(for: key)) }
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

    private func forwardInput(from old: String, to new: String) {
        guard let session else { return }
        if new.count > old.count {
            session.send(Data(new.dropFirst(old.count).utf8))
        } else if new.count < old.count {
            for _ in 0..<(old.count - new.count) {
                session.send(TerminalInput.data(for: .backspace))
            }
        }
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
        do {
            let established = try await SSHTerminalSession.connect(
                host: host, port: 22, username: profile.username, password: loginPassword,
                policy: .acceptAny)
            session = established
            fingerprint = established.hostKeySHA256
            let stream = try await established.openShell(columns: 80, rows: 24)
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
