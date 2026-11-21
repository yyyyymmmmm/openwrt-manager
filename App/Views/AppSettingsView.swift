import SwiftUI
import OpenWrtKit

struct AppSettingsView: View {
    @AppStorage("text-size.v1") private var textSize = AppTextSize.compact.rawValue
    @AppStorage("appearance.v1") private var appearance = "system"
    @AppStorage(AppThemeCatalog.storageKey) private var theme = AppThemeCatalog.defaultID.rawValue
    private var appearanceTitle: String { appearance == "dark" ? "深色" : appearance == "light" ? "浅色" : "跟随系统" }
    private var themeTitle: String {
        AppThemeCatalog.definition(for: AppThemeCatalog.resolve(storedValue: theme)).displayName
    }
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "显示") {
                AppGroup {
                    NavigationLink { ThemeSelection() } label: {
                        AppRow(title: "主题", symbol: "paintpalette", value: themeTitle, chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("themePicker")
                        .accessibilityValue(themeTitle)
                    AppDivider()
                    NavigationLink { TextSizeSelection() } label: {
                        AppRow(title: "文字大小", symbol: "textformat.size", value: (AppTextSize(rawValue: textSize) ?? .compact).title, chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("textSizePicker")
                        .accessibilityValue((AppTextSize(rawValue: textSize) ?? .compact).title)
                    AppDivider()
                    NavigationLink { AppearanceSelection() } label: {
                        AppRow(title: "外观", symbol: "circle.lefthalf.filled", value: appearanceTitle, chevron: true)
                    }.buttonStyle(.plain).accessibilityIdentifier("appearancePicker")
                }
            }
            AppSection(title: "支持与隐私") {
                AppGroup {
                    NavigationLink { AppHelpView() } label: { AppRow(title: "帮助与连接", symbol: "questionmark.circle", chevron: true) }.buttonStyle(.plain)
                    AppDivider()
                    NavigationLink { AppPrivacyView() } label: { AppRow(title: "隐私说明", symbol: "hand.raised", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("privacyLink")
                    AppDivider()
                    NavigationLink { AppAboutView() } label: { AppRow(title: "关于", symbol: "info.circle", chevron: true) }.buttonStyle(.plain)
                    AppDivider()
                    NavigationLink { DiagnosticsView() } label: { AppRow(title: "诊断日志", symbol: "waveform.path.ecg", chevron: true) }
                        .buttonStyle(.plain).accessibilityIdentifier("diagnosticsLink")
                }
            }
        }.appDetailStyle("App 设置")
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

private struct ThemeSelection: View {
    @AppStorage(AppThemeCatalog.storageKey) private var selected = AppThemeCatalog.defaultID.rawValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "主题", note: "主题更换的是强调色；深浅外观仍由系统或「外观」设置决定。") {
                AppGroup {
                    ForEach(AppThemeCatalog.all, id: \.id) { theme in
                        Button { selected = theme.id.rawValue; dismiss() } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(AppPalette.swatchColor(for: theme))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(AppPalette.line, lineWidth: 0.5))
                                Text(theme.displayName)
                                    .font(AppTypography.rowTitle)
                                    .foregroundStyle(AppPalette.text)
                                Spacer(minLength: 0)
                                if selected == theme.id.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(AppPalette.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(minHeight: 45)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(theme.displayName)
                            .accessibilityAddTraits(selected == theme.id.rawValue ? .isSelected : [])
                        if theme.id != AppThemeCatalog.all.last?.id { AppDivider(inset: 50) }
                    }
                }
            }
        }.appDetailStyle("主题")
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
