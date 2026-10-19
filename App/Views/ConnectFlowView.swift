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
    @State private var showingWelcome = true

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if allowsDemo && !isModal && store.profiles.isEmpty && showingWelcome {
                    welcome
                } else {
                    addressPage
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AppSettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("App 设置").accessibilityIdentifier("appSettingsLink")
                }
                if isModal {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
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
                Alert(title: Text("删除保存的路由器？"),
                      message: Text("“\(profile.name)”及其本机凭据会从此设备移除。不会修改路由器设置。"),
                      primaryButton: .destructive(Text("删除")) {
                          do { try store.remove(profile) } catch { addressError = error.localizedDescription }
                      }, secondaryButton: .cancel())
            }
            .onChange(of: store.connectionID) { _, _ in
                if store.hasConnection && isModal { dismiss() }
            }
        }
        .tint(AppPalette.accent)
    }

    private var addressPage: some View {
        AppPage(title: "连接你的路由器", subtitle: "输入管理网址，或查找当前网络中的路由器。", setup: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("管理地址").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(AppPalette.muted)
                    TextField("管理地址", text: $address,
                              prompt: Text(verbatim: "192.168.1.1 或 https://router.example").foregroundStyle(AppPalette.muted))
                        .font(AppTypography.reading)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.continue)
                        .onSubmit(openLogin)
                        .accessibilityIdentifier("routerAddressField")
                }.padding(.horizontal, 14).frame(minHeight: 58)
                    .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    if let addressError {
                        Label(addressError, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.red)
                    }

                    Button(action: openLogin) {
                        Label("继续登录", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(AppPrimaryButtonStyle()).padding(.top, 12)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("continueToLoginButton")
            }
            AppSection(title: "或在附近查找", note: "扫描需要本地网络权限。发现地址后仍需确认设备并登录。") {
                AppGroup {
                    NavigationLink(value: ConnectRoute.scan) {
                        AppRow(title: "扫描局域网", detail: "查找当前 Wi-Fi 中的管理地址", symbol: "dot.radiowaves.left.and.right", chevron: true)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("scanLocalNetworkLink")
                }
            }
                if !store.profiles.isEmpty {
                    AppSection(title: "已保存的路由器") {
                        AppGroup {
                        ForEach(store.profiles) { profile in
                            Button {
                                path.append(.login(address: profile.address, profile: profile))
                            } label: {
                                AppRow(title: profile.name, detail: profile.address, symbol: "wifi.router", chevron: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    removalTarget = profile
                                }
                            }
                        }
                        }
                    }
                }

                if allowsDemo {
                    AppSection(title: "") {
                        Button {
                            store.enterDemo()
                        } label: {
                            Label("试用演示数据", systemImage: "play.circle")
                        }
                        .buttonStyle(AppSecondaryButtonStyle()).accessibilityIdentifier("demoModeButton")
                    }
                }
            privacyLinks.padding(.top, 28)
        }
    }

    private var welcome: some View {
        AppPage(title: "", setup: true) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.router").foregroundStyle(AppPalette.accent)
                Text("OpenWrt Manager").font(AppTypography.navigation)
            }.padding(.top, 12)
            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "wifi.router").font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("你的 OpenWrt").font(AppTypography.rowTitle)
                        Text("家庭网络").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                    Spacer()
                    Circle().fill(AppPalette.green).frame(width: 6, height: 6)
                }.padding(18).background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 0) {
                    endpoint("iphone", "手机")
                    endpoint("laptopcomputer", "电脑")
                    endpoint("square.stack.3d.up", "更多设备")
                }
            }.padding(.top, 52).padding(.bottom, 42)
            Text("你的网络，\n尽在掌握。").font(AppTypography.display).lineSpacing(4)
            Text("连接 OpenWrt，随时查看设备、管理网络与插件。")
                .font(AppTypography.reading).foregroundStyle(AppPalette.muted).lineSpacing(5).padding(.top, 12)
            Button { showingWelcome = false } label: { Text("连接路由器") }
                .buttonStyle(AppPrimaryButtonStyle()).padding(.top, 32).accessibilityIdentifier("startConnectionButton")
            Button { store.enterDemo() } label: { Text("先试用演示") }
                .buttonStyle(AppSecondaryButtonStyle()).padding(.top, 10).accessibilityIdentifier("demoModeButton")
            privacyLinks.padding(.top, 28)
        }
    }

    private func endpoint(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(AppPalette.accent)
            Text(name).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }.frame(maxWidth: .infinity)
    }

    private var privacyLinks: some View {
        HStack(spacing: 24) {
            NavigationLink("隐私说明") { AppPrivacyView() }
            NavigationLink("连接帮助") { AppHelpView() }
        }.font(AppTypography.secondary).frame(maxWidth: .infinity, minHeight: 44)
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
