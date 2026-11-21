import SwiftUI
import OpenWrtKit

enum AppTextSize: String, CaseIterable, Identifiable {
    case system, compact, standard, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.string("跟随系统")
        case .compact: return L10n.string("紧凑")
        case .standard: return L10n.string("标准")
        case .large: return L10n.string("加大")
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

/// The user's accent theme (package M). The selection lives in
/// the standard defaults under the kit catalog's key — the same
/// store @AppStorage binds — and AppPalette reads it from here on
/// every color resolution. Nothing stored (fresh installs, and
/// everyone upgrading from before package M) resolves to the kit
/// default, Tencent blue; the jade green this app shipped with
/// stays one tap away in App 设置.
enum AppThemeSelection {
    static var current: AppThemeID {
        AppThemeCatalog.resolve(storedValue: UserDefaults.standard.string(forKey: AppThemeCatalog.storageKey))
    }
}

struct AppPreferences: ViewModifier {
    @AppStorage("appearance.v1") private var appearance = "system"
    @AppStorage("text-size.v1") private var textSize = AppTextSize.compact.rawValue
    @AppStorage(AppThemeCatalog.storageKey) private var theme = AppThemeCatalog.defaultID.rawValue
    @Environment(\.dynamicTypeSize) private var systemTextSize

    func body(content: Content) -> some View {
        // Reading the theme here is deliberate: it subscribes this
        // modifier to the selection, so a change re-applies the
        // tint below at once. The palette colors themselves pick
        // the new theme up on their next resolution (DesignSystem).
        _ = AppThemeCatalog.resolve(storedValue: theme)
        return content
            .font(AppTypography.row)
            .tint(AppPalette.accent)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .dynamicTypeSize((AppTextSize(rawValue: textSize) ?? .system).resolved(system: systemTextSize))
    }
}
