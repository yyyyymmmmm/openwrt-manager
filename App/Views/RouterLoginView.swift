import SwiftUI
import OpenWrtKit

private enum LoginAlert: Identifiable {
    case insecureHTTP
    case certificate(CertificateNotice)

    var id: String {
        switch self {
        case .insecureHTTP: return "http"
        case .certificate(let notice): return "certificate-\(notice.fingerprint)"
        }
    }
}

struct RouterLoginView: View {
    @Environment(RouterStore.self) private var store

    let address: String
    let existingProfile: RouterProfile?
    /// Manual-entry mode (package K): reached when a one-tap switch
    /// could not spend the saved password — the Face ID check was
    /// refused or unavailable, so the user types the password here.
    /// The saved password is then deliberately NOT prefilled: the
    /// gate would be theatre if cancelling it landed on a form that
    /// had the password already filled in.
    let manualPasswordEntry: Bool

    @State private var routerName: String
    @State private var username: String
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var knownFingerprint: String?
    @State private var alert: LoginAlert?
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var passwordLoaded = false
    @State private var revealPassword = false
    @State private var connectionTask: Task<Void, Never>?
    @FocusState private var focusedField: LoginField?

    private enum LoginField {
        case name, username, password
    }

    init(address: String, existingProfile: RouterProfile?, manualPasswordEntry: Bool = false) {
        self.address = address
        self.existingProfile = existingProfile
        self.manualPasswordEntry = manualPasswordEntry
        let host = URLComponents(string: address)?.host ?? address
        _routerName = State(initialValue: existingProfile?.name ?? host)
        _username = State(initialValue: existingProfile?.username ?? "root")
        _rememberPassword = State(initialValue: existingProfile?.rememberPassword ?? false)
    }

    var body: some View {
        AppPage(title: "登录路由器", subtitle: "使用路由器的管理员账户建立连接。", setup: true) {
            AppGroup {
                AppRow(title: existingProfile?.name ?? "OpenWrt 路由器", detail: address, symbol: "wifi.router")
            }
            Label(address.lowercased().hasPrefix("https:") ? "HTTPS · 加密连接" : "HTTP · 当前连接未加密",
                  systemImage: address.lowercased().hasPrefix("https:") ? "lock" : "lock.open")
                .font(AppTypography.secondary)
                .foregroundStyle(address.lowercased().hasPrefix("https:") ? AppPalette.muted : AppPalette.orange)
                .padding(.top, 12).padding(.bottom, 24)
            if manualPasswordEntry {
                Label("身份验证未完成，请手动输入密码。", systemImage: "faceid")
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.orange)
                    .padding(.bottom, 16)
            }
            AppGroup {
                VStack(alignment: .leading, spacing: 5) {
                    Text("用户名").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    TextField("用户名", text: $username,
                              prompt: Text("用户名").foregroundStyle(AppPalette.muted))
                        .font(AppTypography.reading)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("routerUsernameField")
                }
                .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 64)
                AppDivider(inset: 14)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("密码").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                        Group {
                            if revealPassword {
                                TextField("路由器密码", text: $password,
                                          prompt: Text("路由器密码").foregroundStyle(AppPalette.muted))
                            } else {
                                SecureField("路由器密码", text: $password,
                                            prompt: Text("路由器密码").foregroundStyle(AppPalette.muted))
                            }
                        }.font(AppTypography.reading).textContentType(.password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .password)
                            .accessibilityIdentifier("routerPasswordField")
                    }
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye").frame(width: 44, height: 44)
                    }.accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码").foregroundStyle(AppPalette.muted)
                }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 64)
            }
            Toggle("在此设备记住密码", isOn: $rememberPassword)
                .font(AppTypography.row).tint(AppPalette.accent).padding(.top, 18)
            Text("密码仅在你选择记住时保存到 iOS 钥匙串。")
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.top, 6)
            AppSection(title: "路由器名称") {
                TextField("名称", text: $routerName,
                          prompt: Text("名称").foregroundStyle(AppPalette.muted))
                    .font(AppTypography.reading)
                    .textContentType(.nickname)
                    .focused($focusedField, equals: .name)
                    .padding(.horizontal, 14).frame(minHeight: 54)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            }

            if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppPalette.red)
                        .textSelection(.enabled)
                        .padding(.top, 14)
            }

                Button(action: beginConnection) {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("正在连接…")
                        } else {
                            Text("登录并连接")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(AppPrimaryButtonStyle()).padding(.top, 24)
                .disabled(isConnecting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .accessibilityIdentifier("loginButton")
                Label("使用路由器账户的实际权限。缺少权限或模块时会单独提示；配置与服务修改需另行确认。", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(AppPalette.muted).padding(.top, 18)
        }
        .appDetailStyle("")
        .task {
            loadSavedCredential()
        }
        .onDisappear {
            connectionTask?.cancel()
        }
        .alert(item: $alert) { item in
            switch item {
            case .insecureHTTP:
                Alert(
                    title: Text("此连接未加密"),
                    message: Text("HTTP 会在当前网络中以明文传输用户名、密码和会话信息。仅在可信的本地网络中继续；如果路由器支持 HTTPS，建议改用 HTTPS 地址。"),
                    primaryButton: .destructive(Text("继续使用 HTTP")) {
                        startConnection(using: knownFingerprint)
                    },
                    secondaryButton: .cancel()
                )
            case .certificate(let notice):
                Alert(
                    title: Text(notice.changed ? "路由器证书已更改" : "路由器证书未获系统信任"),
                    message: Text("\(notice.host)\n\(notice.subject)\nSHA-256\n\(notice.fingerprint)\n\n请通过可信方式核对指纹。信任后只对这个路由器地址生效。"),
                    primaryButton: .default(Text("核对后信任并继续")) {
                        startConnection(using: notice.fingerprint)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func loadSavedCredential() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        guard let existingProfile else { return }
        do {
            let credential = try store.credential(for: existingProfile)
            knownFingerprint = credential?.certificateFingerprint
            // Manual-entry mode (package K) loads the fingerprint
            // only: the password stays in the Keychain until the
            // user types it, which is the whole point of the
            // fallback.
            if !manualPasswordEntry, let savedPassword = credential?.password {
                password = savedPassword
                rememberPassword = true
            }
        } catch {
            errorMessage = FriendlyError.message(error)
        }
    }

    private func beginConnection() {
        errorMessage = nil
        do {
            let normalized = try URLNormalizer.normalize(address)
            if !normalized.isSecure {
                alert = .insecureHTTP
                return
            }
            startConnection(using: knownFingerprint)
        } catch {
            errorMessage = FriendlyError.message(error)
        }
    }

    private func startConnection(using fingerprint: String?) {
        focusedField = nil
        connectionTask = Task { await connect(using: fingerprint) }
    }

    private func connect(using fingerprint: String?) async {
        guard !isConnecting else { return }
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }

        let host = URLComponents(string: address)?.host ?? address
        let profile = RouterProfile(
            id: existingProfile?.id ?? UUID(),
            name: routerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : routerName,
            address: address,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            rememberPassword: rememberPassword
        )
        do {
            try await store.connect(profile: profile, password: password, fingerprint: fingerprint)
        } catch let failure as AppFailure {
            guard !Task.isCancelled else { return }
            if case .certificate(let notice) = failure {
                alert = .certificate(notice)
                return
            }
            errorMessage = FriendlyError.message(failure)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = FriendlyError.message(error)
        }
    }
}
