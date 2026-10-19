import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        AppPage(title: "", subtitle: nil) { AppSettingsContent() }.appDetailStyle("App 设置")
    }
}

struct SettingsScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            AppRootPage(showingRouterPicker: $showingRouterPicker, title: "设置", subtitle: "连接、显示与 App 信息") {
                AppSection(title: "当前连接") {
                    AppGroup {
                        if let profile = store.activeProfile {
                            AppRow(title: profile.name, detail: profile.address, symbol: "wifi.router", value: profile.username)
                            AppDivider()
                        }
                        Button { showingRouterPicker = true } label: {
                            AppRow(title: "切换或添加路由器", symbol: "arrow.left.arrow.right", chevron: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-router-picker")
                        .disabled(store.isMutating || store.pendingConfiguration != nil)
                        AppDivider()
                        Button { confirmDisconnect = true } label: {
                            AppRow(title: "断开连接", symbol: "rectangle.portrait.and.arrow.right", destructive: true)
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-disconnect")
                        .disabled(store.isMutating || store.pendingConfiguration != nil)
                    }
                }
                AppSettingsContent()
            }
            .confirmationDialog("断开当前路由器连接？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) { store.disconnect() }
                Button("取消", role: .cancel) {}
            } message: { Text("清除本次会话数据，保留本机保存的地址与凭据。") }
        }
    }
}

private struct AppSettingsContent: View {
    @AppStorage("text-size.v1") private var textSize = AppTextSize.compact.rawValue
    @AppStorage("appearance.v1") private var appearance = "system"
    private var appearanceTitle: String { appearance == "dark" ? "深色" : appearance == "light" ? "浅色" : "跟随系统" }
    var body: some View {
        Group {
            AppSection(title: "显示") {
                AppGroup {
                    NavigationLink { TextSizeSelection() } label: {
                        AppRow(title: "文字大小", symbol: "textformat.size", value: (AppTextSize(rawValue: textSize) ?? .compact).title, chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("textSizePicker")
                        .accessibilityValue((AppTextSize(rawValue: textSize) ?? .compact).title)
                    AppDivider()
                    NavigationLink { AppearanceSelection() } label: {
                        AppRow(title: "外观", symbol: "circle.lefthalf.filled", value: appearanceTitle, chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("appearancePicker")
                        .accessibilityValue(appearanceTitle)
                }
            }
            AppSection(title: "支持与隐私") {
                AppGroup {
                    NavigationLink { AppHelpView() } label: { AppRow(title: "帮助与连接", symbol: "questionmark.circle", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("helpLink")
                    AppDivider()
                    NavigationLink { AppPrivacyView() } label: { AppRow(title: "隐私说明", symbol: "hand.raised", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("privacyLink")
                    AppDivider()
                    NavigationLink { AppAboutView() } label: { AppRow(title: "关于", symbol: "info.circle", chevron: true) }.buttonStyle(.plain).accessibilityIdentifier("aboutLink")
                }
            }
        }
    }
}

private struct TextSizeSelection: View {
    @AppStorage("text-size.v1") private var selected = AppTextSize.compact.rawValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "文字大小", note: "跟随系统可使用 iOS 的动态字体。系统辅助功能的大字设置始终优先。") {
                AppGroup {
                    ForEach(AppTextSize.allCases) { size in
                        Button { selected = size.rawValue; dismiss() } label: {
                            AppRow(title: size.title, symbol: selected == size.rawValue ? "checkmark" : nil)
                        }.buttonStyle(.plain).accessibilityLabel(size.title)
                        if size != AppTextSize.allCases.last { AppDivider(inset: 12) }
                    }
                }
            }
        }.appDetailStyle("文字大小")
    }
}

private struct AppearanceSelection: View {
    @AppStorage("appearance.v1") private var selected = "system"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "外观") {
                AppGroup {
                    ForEach(["system", "light", "dark"], id: \.self) { value in
                        Button { selected = value; dismiss() } label: {
                            AppRow(title: value == "system" ? "跟随系统" : value == "light" ? "浅色" : "深色",
                                   symbol: selected == value ? "checkmark" : nil)
                    }.buttonStyle(.plain)
                        if value != "dark" { AppDivider(inset: 12) }
                    }
                }
            }
        }.appDetailStyle("外观")
    }
}
