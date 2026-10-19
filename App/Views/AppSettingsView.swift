import SwiftUI

enum AppTypography {
    static let title: Font = .title2.weight(.semibold)
    static let reading: Font = .callout
    static let row: Font = .subheadline
    static let rowTitle: Font = .subheadline.weight(.medium)
    static let secondary: Font = .footnote
    static let metadata: Font = .caption
}

struct AppSettingsView: View {
    @AppStorage("text-size.v1") private var textSize = AppTextSize.system.rawValue
    @AppStorage("appearance.v1") private var appearance = "system"

    var body: some View {
        Form {
            Section("显示") {
                Picker("文字大小", selection: $textSize) {
                    ForEach(AppTextSize.allCases) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("textSizePicker")
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Text("家庭网络").font(AppTypography.title)
                VStack(alignment: .leading, spacing: 5) {
                    Text("无线网络").font(AppTypography.rowTitle)
                    Text("Home-WiFi-5G").font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("已读取路由器状态").font(AppTypography.rowTitle)
                    Text("2 分钟前").font(AppTypography.metadata).foregroundStyle(.secondary)
                }
            } header: {
                Text("预览")
            } footer: {
                Text("文字大小适用于本机 App，设置会自动保存。系统辅助功能的大字优先。")
            }

            Section("支持与隐私") {
                NavigationLink {
                    AppHelpView()
                } label: {
                    Label("帮助与连接", systemImage: "questionmark.circle")
                }
                NavigationLink {
                    AppPrivacyView()
                } label: {
                    Label("隐私说明", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("privacyLink")
                NavigationLink {
                    AppAboutView()
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("App 设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
