import SwiftUI
import UIKit

// These tokens are copied from the approved HTML prototype, including dark mode.
enum AppPalette {
    static let accent = color(0x087873, 0x74C8C0)
    static let accentStrong = color(0x056661, 0x8BD4CC)
    static let accentSoft = color(0xE6F4F2, 0x1C3937)
    static let canvas = color(0xF3F4F5, 0x111719)
    static let surface = color(0xFFFFFF, 0x1C2426)
    static let text = color(0x191E20, 0xEFF3F3)
    static let muted = color(0x5E696C, 0xADB9BA)
    static let line = color(0xE4E8E9, 0x303B3D)
    static let green = color(0x25734B, 0x91D1A9)
    static let greenSoft = color(0xEAF5ED, 0x1C3627)
    static let orange = color(0x855A12, 0xEDC77F)
    static let orangeSoft = color(0xFAF0DC, 0x382D1B)
    static let red = color(0xB52F35, 0xF19A9C)
    static let blue = color(0x32699C, 0xA5C7EB)
    static let blueSoft = color(0xEAF1F8, 0x222F3A)

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

enum AppTypography {
    static let display: Font = .system(.title, weight: .semibold)
    static let title: Font = .system(.title2, weight: .semibold)
    static let navigation: Font = .system(.body, weight: .semibold)
    static let reading: Font = .callout
    static let row: Font = .subheadline
    static let rowTitle: Font = .system(.subheadline, weight: .medium)
    static let secondary: Font = .footnote
    static let metadata: Font = .caption
    static let chrome: Font = .caption2
}

struct AppPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var setup = false
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !title.isEmpty {
                    VStack(alignment: .leading, spacing: setup ? 12 : 6) {
                        Text(title).font(AppTypography.title).accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .font(setup ? AppTypography.reading : AppTypography.secondary)
                                .foregroundStyle(AppPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(setup ? 4 : 1)
                        }
                    }
                    .padding(.top, setup ? 18 : 5)
                    .padding(.bottom, setup ? 28 : 18)
                }
                content
            }
            .padding(.horizontal, setup ? 24 : 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .foregroundStyle(AppPalette.text)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct AppSection<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(AppTypography.secondary.weight(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.horizontal, 10)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let note {
                Text(note).font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
            }
        }
        .padding(.top, 23)
    }
}

struct AppGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 15))
    }
}

struct AppDivider: View {
    var inset: CGFloat = 48
    var body: some View {
        Rectangle().fill(AppPalette.line).frame(height: 0.5).padding(.leading, inset)
    }
}

struct AppRow: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var value: String? = nil
    var badge: String? = nil
    var chevron = false
    var destructive = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 19))
                    .foregroundStyle(destructive ? AppPalette.red : AppPalette.muted)
                    .frame(width: 26, height: 30).accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { copy; trailing }
                VStack(alignment: .leading, spacing: 6) { copy; trailing }
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppPalette.muted).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 45)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(AppTypography.rowTitle)
                .foregroundStyle(destructive ? AppPalette.red : AppPalette.text)
            if let detail {
                Text(detail).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var trailing: some View {
        if let value {
            Text(value).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
        }
        if let badge { StatusBadge(title: badge) }
    }
}

struct StatusBadge: View {
    let title: String
    var good = false
    var body: some View {
        Text(title).font(AppTypography.metadata.weight(.medium))
            .foregroundStyle(good ? AppPalette.green : AppPalette.muted)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(good ? AppPalette.greenSoft : AppPalette.canvas,
                        in: RoundedRectangle(cornerRadius: 7))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.reading.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(colorScheme == .dark ? AppPalette.canvas : .white)
            .background(AppPalette.accent.opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.45),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(AppTypography.reading.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(AppPalette.accentStrong)
            .background(AppPalette.surface.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppPalette.line, lineWidth: 0.5))
    }
}

struct AppSearchField: View {
    let prompt: String
    @Binding var text: String
    var identifier = "searchField"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppPalette.muted)
            TextField(prompt, text: $text,
                      prompt: Text(verbatim: prompt).foregroundStyle(AppPalette.muted))
                .font(AppTypography.reading)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(AppPalette.muted).frame(width: 44, height: 44)
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11).frame(minHeight: 44)
        .background(AppPalette.line.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct FilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(AppTypography.secondary.weight(selected ? .semibold : .medium))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(selected ? AppPalette.accentStrong : AppPalette.muted)
                .background(selected ? AppPalette.accentSoft : AppPalette.line.opacity(0.45),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ReadStatus: View {
    @Environment(RouterStore.self) private var store
    let updatedAt: Date?
    let error: String?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                if let updatedAt {
                    Text("显示上次读取的数据 · \(updatedAt.formatted(date: .omitted, time: .shortened))")
                }
                Button("重新读取") { Task { await store.refresh() } }.disabled(store.isRefreshing)
            }
            .font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.orangeSoft, in: RoundedRectangle(cornerRadius: 13))
            .padding(.bottom, 12)
        } else if store.isRefreshing && updatedAt == nil {
            HStack(spacing: 8) { ProgressView(); Text("正在读取路由器信息…") }
                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                .padding(.bottom, 12)
        }
        if let storageError = store.storageError {
            Text(storageError).font(AppTypography.secondary).foregroundStyle(AppPalette.orange)
                .padding(.bottom, 12)
        }
    }
}

struct RootPageHeader: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var showingSearch = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showingRouterPicker = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "wifi.router").font(.system(size: 20))
                        .foregroundStyle(AppPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(AppPalette.accentSoft, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeProfile?.name ?? "家庭主路由器")
                            .font(AppTypography.secondary.weight(.semibold)).foregroundStyle(AppPalette.text)
                        Text(store.isDemo ? "OpenWrt · 演示路由器" : store.activeProfile?.address ?? "OpenWrt")
                            .font(AppTypography.metadata).foregroundStyle(AppPalette.muted).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(AppPalette.muted)
                }
                .frame(minHeight: 48)
            }
            .buttonStyle(.plain).accessibilityLabel("切换或添加路由器")
            Spacer(minLength: 0)
            Button { Task { await store.refresh() } } label: {
                Group {
                    if store.isRefreshing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 19)) }
                }.frame(width: 44, height: 44)
            }
            .disabled(store.isRefreshing).accessibilityLabel("刷新路由器状态")
            Button { showingSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("搜索管理功能")
        }
        .padding(.horizontal, 18).frame(minHeight: 61)
        .foregroundStyle(AppPalette.accent).background(AppPalette.canvas)
        .sheet(isPresented: $showingSearch) { ManagementSearchView().presentationDragIndicator(.visible) }
    }
}

struct ManagementSearchView: View {
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            AppPage(title: "搜索", subtitle: "查找网络功能与管理入口") {
                AppSearchField(prompt: "无线、接口、防火墙…", text: $query)
                NetworkTaskGroups(query: query)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

extension View {
    func appDetailStyle(_ title: String) -> some View {
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(AppPalette.canvas, for: .navigationBar)
    }
}

struct AppRootPage<Content: View>: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            RootPageHeader(showingRouterPicker: $showingRouterPicker)
            AppPage(title: title, subtitle: subtitle) { content }
                .refreshable { await store.refresh() }
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }
}
