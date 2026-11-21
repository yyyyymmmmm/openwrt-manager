import Foundation

/// Accent themes (package M). A theme is one accent ramp; the
/// light/dark dimension stays with the system appearance, so every
/// theme carries a light and a dark variant of each token and the
/// two dimensions never interact. Neutral tokens (canvas, surface,
/// text, lines) and the semantic status colors (success green,
/// warning orange, error red, info blue) are NOT part of a theme —
/// they stay fixed across themes, the platform convention.
public enum AppThemeID: String, CaseIterable, Sendable {
    case tencentBlue
    case jadeGreen
    case violet
    case sunsetOrange
}

/// The three accent tokens the design system derives every tinted
/// surface from, each in its light-appearance and dark-appearance
/// form, as 0xRRGGBB values.
public struct AppThemeAccent: Equatable, Sendable {
    public let accentLight: UInt32
    public let accentDark: UInt32
    public let accentStrongLight: UInt32
    public let accentStrongDark: UInt32
    public let accentSoftLight: UInt32
    public let accentSoftDark: UInt32

    public init(accentLight: UInt32, accentDark: UInt32,
                accentStrongLight: UInt32, accentStrongDark: UInt32,
                accentSoftLight: UInt32, accentSoftDark: UInt32) {
        self.accentLight = accentLight
        self.accentDark = accentDark
        self.accentStrongLight = accentStrongLight
        self.accentStrongDark = accentStrongDark
        self.accentSoftLight = accentSoftLight
        self.accentSoftDark = accentSoftDark
    }
}

public struct AppThemeDefinition: Equatable, Sendable {
    public let id: AppThemeID
    public let accent: AppThemeAccent

    public init(id: AppThemeID, accent: AppThemeAccent) {
        self.id = id
        self.accent = accent
    }

    /// The theme's display name, resolved through KitL10n like all
    /// fixed kit copy (the app shell syncs the language at launch).
    public var displayName: String {
        switch id {
        case .tencentBlue: return KitL10n.text("腾讯蓝")
        case .jadeGreen: return KitL10n.text("青绿")
        case .violet: return KitL10n.text("紫罗兰")
        case .sunsetOrange: return KitL10n.text("落日橙")
        }
    }
}

public enum AppThemeCatalog {
    /// UserDefaults key of the stored selection. The app binds it
    /// with @AppStorage, defaulting to `defaultID.rawValue`.
    public static let storageKey = "theme.v1"

    /// The default for every install that has never stored a
    /// selection: Tencent blue, the app icon's primary color.
    /// Pre-package-M installs have nothing stored, so the default
    /// change reaches them on upgrade; the palette they shipped
    /// with stays selectable below.
    public static let defaultID: AppThemeID = .tencentBlue

    public static let all: [AppThemeDefinition] = [
        AppThemeDefinition(id: .tencentBlue, accent: AppThemeAccent(
            accentLight: 0x0052D9, accentDark: 0x6EA8FF,
            accentStrongLight: 0x0043B8, accentStrongDark: 0x9CC2FF,
            accentSoftLight: 0xE3EEFD, accentSoftDark: 0x1D2D47)),
        // The accent ramp this app shipped with through build #28,
        // preserved verbatim (AppPalette in DesignSystem.swift
        // before package M) as the selectable jade green theme.
        AppThemeDefinition(id: .jadeGreen, accent: AppThemeAccent(
            accentLight: 0x087873, accentDark: 0x74C8C0,
            accentStrongLight: 0x056661, accentStrongDark: 0x8BD4CC,
            accentSoftLight: 0xE6F4F2, accentSoftDark: 0x1C3937)),
        AppThemeDefinition(id: .violet, accent: AppThemeAccent(
            accentLight: 0x6D4BD8, accentDark: 0xB79CFF,
            accentStrongLight: 0x5736B8, accentStrongDark: 0xCDBBFF,
            accentSoftLight: 0xEFEAFB, accentSoftDark: 0x2A2145)),
        AppThemeDefinition(id: .sunsetOrange, accent: AppThemeAccent(
            accentLight: 0xC2410C, accentDark: 0xFFB37E,
            accentStrongLight: 0x9A3412, accentStrongDark: 0xFFC79C,
            accentSoftLight: 0xFDF0E3, accentSoftDark: 0x3A2716)),
    ]

    public static func definition(for id: AppThemeID) -> AppThemeDefinition {
        all.first { $0.id == id } ?? all[0]
    }

    /// Resolves a stored selection. Anything missing or unknown —
    /// a fresh install, a pre-package-M install, a value written
    /// by a different build — falls back to the default theme
    /// rather than failing or guessing.
    public static func resolve(storedValue: String?) -> AppThemeID {
        guard let storedValue, let id = AppThemeID(rawValue: storedValue) else { return defaultID }
        return id
    }
}
