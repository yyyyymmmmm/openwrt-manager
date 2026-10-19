import SwiftUI

enum AppTextSize: String, CaseIterable, Identifiable {
    case system, compact, standard, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .large: return "加大"
        }
    }

    func resolved(system: DynamicTypeSize) -> DynamicTypeSize {
        guard !system.isAccessibilitySize else { return system }
        switch self {
        case .system: return system
        case .compact: return .medium
        case .standard: return .large
        case .large: return .xLarge
        }
    }
}

struct AppPreferences: ViewModifier {
    @AppStorage("appearance.v1") private var appearance = "system"
    @AppStorage("text-size.v1") private var textSize = AppTextSize.compact.rawValue
    @Environment(\.dynamicTypeSize) private var systemTextSize

    func body(content: Content) -> some View {
        content
            .font(AppTypography.row)
            .tint(AppPalette.accent)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .dynamicTypeSize((AppTextSize(rawValue: textSize) ?? .system).resolved(system: systemTextSize))
    }
}
