import XCTest
@testable import OpenWrtKit

/// Package M (theme system): the kit owns the theme catalog — the
/// accent ramps, the default, and the stored-value resolution the
/// app shell binds to UserDefaults. The jade green ramp is pinned
/// to the exact values the app shipped with before themes existed,
/// so "keep the green" cannot silently drift.
final class PackageMTests: XCTestCase {

    func testDefaultIsTencentBlue() {
        XCTAssertEqual(AppThemeCatalog.defaultID, .tencentBlue)
        XCTAssertEqual(AppThemeCatalog.all.first?.id, .tencentBlue)
        XCTAssertEqual(AppThemeCatalog.storageKey, "theme.v1")
    }

    func testTencentBlueUsesTheIconPrimary() {
        let accent = AppThemeCatalog.definition(for: .tencentBlue).accent
        XCTAssertEqual(accent.accentLight, 0x0052D9)
    }

    func testJadeGreenPreservesTheShippedPaletteVerbatim() {
        // AppPalette in DesignSystem.swift before package M:
        // accent 0x087873/0x74C8C0, accentStrong 0x056661/0x8BD4CC,
        // accentSoft 0xE6F4F2/0x1C3937.
        let accent = AppThemeCatalog.definition(for: .jadeGreen).accent
        XCTAssertEqual(accent.accentLight, 0x087873)
        XCTAssertEqual(accent.accentDark, 0x74C8C0)
        XCTAssertEqual(accent.accentStrongLight, 0x056661)
        XCTAssertEqual(accent.accentStrongDark, 0x8BD4CC)
        XCTAssertEqual(accent.accentSoftLight, 0xE6F4F2)
        XCTAssertEqual(accent.accentSoftDark, 0x1C3937)
    }

    func testCatalogHasFourUniqueCompleteThemes() {
        XCTAssertEqual(AppThemeCatalog.all.count, 4)
        XCTAssertEqual(Set(AppThemeCatalog.all.map(\.id)).count, 4)
        XCTAssertEqual(Set(AppThemeID.allCases), Set(AppThemeCatalog.all.map(\.id)))
        for theme in AppThemeCatalog.all {
            XCTAssertFalse(theme.displayName.isEmpty, "\(theme.id) has no display name")
            // Every ramp slot carries a real light/dark pair.
            XCTAssertNotEqual(theme.accent.accentLight, theme.accent.accentDark, "\(theme.id)")
            XCTAssertNotEqual(theme.accent.accentStrongLight, theme.accent.accentStrongDark, "\(theme.id)")
            XCTAssertNotEqual(theme.accent.accentSoftLight, theme.accent.accentSoftDark, "\(theme.id)")
        }
    }

    func testResolveFallsBackToDefaultForMissingOrUnknownValues() {
        XCTAssertEqual(AppThemeCatalog.resolve(storedValue: nil), .tencentBlue)
        XCTAssertEqual(AppThemeCatalog.resolve(storedValue: ""), .tencentBlue)
        XCTAssertEqual(AppThemeCatalog.resolve(storedValue: "no-such-theme"), .tencentBlue)
    }

    func testResolveRoundTripsEveryTheme() {
        for id in AppThemeID.allCases {
            XCTAssertEqual(AppThemeCatalog.resolve(storedValue: id.rawValue), id)
            XCTAssertEqual(AppThemeCatalog.definition(for: id).id, id)
        }
    }

    func testDisplayNamesResolveInSourceLanguageByDefault() {
        // No app shell in tests: KitL10n stays in the source
        // language, so names come back as the Chinese source.
        XCTAssertEqual(AppThemeCatalog.definition(for: .tencentBlue).displayName, "腾讯蓝")
        XCTAssertEqual(AppThemeCatalog.definition(for: .jadeGreen).displayName, "青绿")
        XCTAssertEqual(AppThemeCatalog.definition(for: .violet).displayName, "紫罗兰")
        XCTAssertEqual(AppThemeCatalog.definition(for: .sunsetOrange).displayName, "落日橙")
    }
}
