import SwiftUI
import OpenWrtKit

private enum ConnectRoute: Hashable {
    case scan
    case login(address: String, profile: RouterProfile?)
}

struct ConnectFlowView: View {
    @Environment(RouterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let isModal: Bool
    let allowsDemo: Bool

    @State private var address = ""
    @State private var path: [ConnectRoute] = []
    @State private var addressError: String?
    @State private var removalTarget: RouterProfile?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Text("连接你的路由器")
                        .font(.title2.weight(.semibold))
                    Text("输入管理地址，或扫描当前 Wi-Fi 中开放 Web 管理端口的设备。")
                        .font(AppTypography.reading)
                        .foregroundStyle(.secondary)
                    TextField("192.168.1.1 或 https://router.example", text: $address)
                        .font(AppTypography.reading)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.continue)
                        .onSubmit(openLogin)
                        .accessibilityIdentifier("routerAddressField")

                    if let addressError {
                        Label(addressError, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button(action: openLogin) {
                        Label("继续登录", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("continueToLoginButton")
                } header: {
                    Text("手动连接")
                } footer: {
                    Text("直接登录你的路由器。选择记住密码时，密码仅保存在此设备的钥匙串中。")
                }

                Section {
                    NavigationLink(value: ConnectRoute.scan) {
                        Label("扫描局域网", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("scanLocalNetworkLink")
                } footer: {
                    Text("扫描需要允许访问本地网络。扫描结果只表示发现开放的 Web 端口，登录前请确认设备地址。")
                }

                if !store.profiles.isEmpty {
                    Section("已保存的路由器") {
                        ForEach(store.profiles) { profile in
                            Button {
                                path.append(.login(address: profile.address, profile: profile))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "wifi")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name)
                                            .font(AppTypography.rowTitle)
                                            .foregroundStyle(.primary)
                                        Text(profile.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    removalTarget = profile
                                }
                            }
                        }
                    }
                }

                if allowsDemo {
                    Section {
                        Button {
                            store.enterDemo()
                        } label: {
                            Label("试用演示数据", systemImage: "play.circle")
                        }
                        .accessibilityIdentifier("demoModeButton")
                    } footer: {
                        Text("演示模式不会连接路由器或保存登录信息。")
                    }
                }
            }
            .navigationTitle("路由器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App 设置")
                    .accessibilityIdentifier("appSettingsLink")
                }
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: ConnectRoute.self) { route in
                switch route {
                case .scan:
                    RouterScanView { selectedAddress in
                        address = selectedAddress
                        do {
                            let normalized = try URLNormalizer.normalize(selectedAddress)
                            path.append(.login(address: normalized.url.absoluteString, profile: nil))
                        } catch {
                            addressError = error.localizedDescription
                            path.removeLast()
                        }
                    }
                case .login(let address, let profile):
                    RouterLoginView(address: address, existingProfile: profile)
                }
            }
            .alert(item: $removalTarget) { profile in
                Alert(
                    title: Text("删除保存的路由器？"),
                    message: Text("“\(profile.name)”及其本机保存的凭据会从此设备移除。不会修改路由器设置。"),
                    primaryButton: .destructive(Text("删除")) {
                        do {
                            try store.remove(profile)
                        } catch {
                            addressError = error.localizedDescription
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
            .onChange(of: store.connectionID) { _, _ in
                if store.hasConnection && isModal { dismiss() }
            }
        }
        .tint(.teal)
    }

    private func openLogin() {
        addressError = nil
        do {
            let normalized = try URLNormalizer.normalize(address)
            address = normalized.url.absoluteString
            path.append(.login(address: normalized.url.absoluteString, profile: nil))
        } catch {
            addressError = error.localizedDescription
        }
    }
}
