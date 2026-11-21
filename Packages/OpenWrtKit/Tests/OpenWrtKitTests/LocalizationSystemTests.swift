import XCTest
@testable import OpenWrtKit

/// The localization system package (2026-11-21): every page — including
/// every sub-page — follows the system language. These tests pin the
/// four mechanisms that make that a system rather than per-page
/// patches: system-first language negotiation, the single translation
/// entry for router-source strings, the kit's own copy resolving
/// through KitL10n, and language-tagged snapshots whose cache expires
/// when the language changes.
final class LocalizationSystemTests: XCTestCase {

    override func tearDown() {
        KitL10n.appLanguage = nil
        super.tearDown()
    }

    private func luciConfig(lang: String, languages: [String]) throws -> JSONValue {
        let languagesObject = languages.map { "\"\($0)\":\"x\"" }.joined(separator: ",")
        let json = """
        {"values":{
          "main":{".type":"core","lang":"\(lang)"},
          "languages":{".type":"internal",\(languagesObject)}
        }}
        """
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: Negotiation v2 — system language first

    func testNegotiationPrefersSystemLanguageOverRouterFixedLanguage() throws {
        // Router fixed to English, system Chinese, catalog installed:
        // the system wins (this is the order the user ordered —
        // "跟随系统语言").
        let config = try luciConfig(lang: "en", languages: ["en", "zh_cn"])
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["zh-Hans-CN"]), "zh-cn")
    }

    func testNegotiationFallsBackToRouterLanguageWhenSystemCatalogMissing() throws {
        // System French has no catalog on the router; the router's own
        // fixed language is the fallback before source strings.
        let config = try luciConfig(lang: "zh_cn", languages: ["zh_cn"])
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["fr-FR"]), "zh-cn")
    }

    func testNegotiationTraditionalChineseMatchesItsCatalog() throws {
        let config = try luciConfig(lang: "auto", languages: ["zh_tw"])
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["zh-Hant-TW"]), "zh-tw")
    }

    func testNegotiationEnglishSystemMeansSourceStrings() throws {
        // LuCI source strings are English; an English system never
        // loads a catalog, whatever the router is fixed to.
        let config = try luciConfig(lang: "zh_cn", languages: ["zh_cn"])
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["en-US"]))
    }

    // MARK: The single translation entry

    func testLocalizationTranslatesHitsAndKeepsMisses() {
        let catalog = LuciTranslationCatalog(entries: [
            LuciHash.superFastHash(LuciHash.lookupKey("System")): "系统"
        ])
        let localization = LuciLocalization(language: "zh-cn", catalog: catalog)
        XCTAssertEqual(localization.translate("System"), "系统")
        XCTAssertEqual(localization.translate("No Such String"), "No Such String")
        XCTAssertEqual(LuciLocalization.source.translate("System"), "System")
        XCTAssertEqual(LuciLocalization.source.language, "source")
    }

    func testGenericPageSectionsResolveThroughLocalization() {
        let catalog = LuciTranslationCatalog(entries: [
            LuciHash.superFastHash(LuciHash.lookupKey("widget")): "小部件",
            LuciHash.superFastHash(LuciHash.lookupKey("frobnicate")): "弗罗布设置"
        ])
        let localization = LuciLocalization(language: "zh-cn", catalog: catalog)
        let config = RouterConfiguration(name: "custom", sections: [
            ConfigurationSection(id: "cfg01", type: "widget", anonymous: true,
                                 values: ["frobnicate": .string("on"), "hostname": .string("router")])
        ])
        let sections = GenericPageModel.sections(from: config, localizer: localization)
        // The section title and the unknown-field label both went
        // through the catalog entry; the device value did not.
        XCTAssertEqual(sections.first?.title, "小部件")
        XCTAssertEqual(sections.first?.rows.first?.key, "frobnicate")
        XCTAssertEqual(sections.first?.rows.first?.label, "弗罗布设置")
        XCTAssertEqual(sections.first?.rows.first?.valueText, "on")
    }

    // MARK: Kit copy follows the app language

    func testKitStringsResolveInEnglishWhenAppLanguageIsEnglish() {
        XCTAssertEqual(KitL10n.text("概览"), "概览")
        KitL10n.appLanguage = "en-US"
        XCTAssertEqual(KitL10n.text("概览"), "Overview")
        XCTAssertEqual(KitL10n.text("是"), "Yes")
        XCTAssertEqual(KitL10n.format("路由器返回 HTTP %lld，请检查管理端口和 /ubus 接口。", 404),
                       "The router returned HTTP 404. Check the management port and the /ubus endpoint.")
        // FieldCatalog labels resolve through the same table.
        let descriptor = FieldCatalog.descriptor(config: "system", sectionType: "system", option: "hostname")
        XCTAssertEqual(descriptor?.label, "Hostname")
    }

    func testEveryEnglishTableEntryDiffersOrIsAnIntentionalSameForm() {
        // Guards against placeholder copies of the source string
        // sneaking into the table (acronyms and format-only strings
        // are the legitimate same-form entries).
        let sameFormAllowed: Set<String> = ["MTU", "RA SLAAC", "HTTP %lld", "%@ → %@"]
        for (source, english) in KitL10n.englishTable {
            if source == english {
                XCTAssertTrue(sameFormAllowed.contains(source), "untranslated entry: \(source)")
            }
        }
        XCTAssertGreaterThan(KitL10n.englishTable.count, 100)
    }

    // MARK: Snapshot language tagging and cache expiry

    func testExpectedLanguageTagHeuristic() {
        XCTAssertEqual(SnapshotLanguage.expectedTag(preferredLanguages: ["zh-Hans-CN"]), "zh-cn")
        XCTAssertEqual(SnapshotLanguage.expectedTag(preferredLanguages: ["en-US"]), "source")
        XCTAssertNil(SnapshotLanguage.expectedTag(preferredLanguages: ["fr-FR"]))
    }

    func testLegacySnapshotDecodesAsVersionOneAndIsNotUsable() throws {
        // The real haul captured from the bypass router before
        // language tagging existed (build #6's cache format).
        let url = Bundle.module.url(forResource: "snapshot-192.168.31.167-2026-11-20", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/snapshot-192.168.31.167-2026-11-20.json")
        let collected = try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(collected.schemaVersion, 1)
        XCTAssertEqual(collected.language, "source")
        XCTAssertFalse(collected.isUsableCache(expectedLanguage: nil))
        XCTAssertFalse(collected.isUsableCache(expectedLanguage: "zh-cn"))
    }

    func testCurrentSnapshotCacheUsabilityFollowsLanguage() throws {
        let collected = CollectedRouterSnapshot(
            device: .init(id: "r", address: "192.168.31.1"),
            collectedAt: "2026-11-21T00:00:00.000Z",
            board: .init(),
            menuPaths: [],
            wireless: .init(present: false),
            language: "zh-cn")
        XCTAssertEqual(collected.schemaVersion, CollectedRouterSnapshot.currentSchemaVersion)
        XCTAssertTrue(collected.isUsableCache(expectedLanguage: "zh-cn"))
        XCTAssertTrue(collected.isUsableCache(expectedLanguage: nil))
        XCTAssertFalse(collected.isUsableCache(expectedLanguage: "source"))
        // The wire form carries both new keys.
        let data = try JSONEncoder().encode(collected)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schema_version"] as? Int, 4)
        XCTAssertEqual(object?["language"] as? String, "zh-cn")
        // And the capability view exposes them for the app's cache gate.
        let snapshot = CapabilitySnapshot(collected: collected)
        XCTAssertEqual(snapshot.language, "zh-cn")
        XCTAssertEqual(snapshot.schemaVersion, 4)
    }

    // MARK: The negotiated language flows through discovery

    private final class LocalizationStubCaller: UbusCalling, @unchecked Sendable {
        var localizationResult: LuciLocalization = .source
        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            .object([:])
        }
        func menu() async throws -> JSONValue {
            let json = """
            {"children":{"admin":{"children":{
              "status":{"action":{"type":"template"},"title":"Status","satisfied":true},
              "system":{"action":{"type":"template"},"title":"System","satisfied":true}
            }}}}
            """
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }
        func installedPackages() async throws -> [InstalledPackage] { [] }
        func localization() async throws -> LuciLocalization { localizationResult }
    }

    func testDiscoveryRecordsLanguageAndTranslatesMenuTitles() async throws {
        let catalog = LuciTranslationCatalog(entries: [
            LuciHash.superFastHash(LuciHash.lookupKey("System")): "系统",
            LuciHash.superFastHash(LuciHash.lookupKey("Status")): "状态"
        ])
        let caller = LocalizationStubCaller()
        caller.localizationResult = LuciLocalization(language: "zh-cn", catalog: catalog)
        let inventory = await RouterReader(caller: caller).inventory()
        XCTAssertEqual(inventory.language, "zh-cn")
        let titles = inventory.menus.flatMap { [$0] + $0.descendants }.map(\.title)
        XCTAssertTrue(titles.contains("系统"), "titles: \(titles)")
        XCTAssertTrue(titles.contains("状态"), "titles: \(titles)")
    }

    func testDiscoveryWithoutCatalogStaysSourceTagged() async throws {
        let caller = LocalizationStubCaller()
        let inventory = await RouterReader(caller: caller).inventory()
        XCTAssertEqual(inventory.language, "source")
    }

    // MARK: Live fixtures — real catalogs captured 2026-11-21

    private func fixtureText(_ name: String, ext: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).\(ext)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Coverage of the app-visible second-level menu titles when the
    /// collected snapshot's source titles are resolved through the
    /// router's own zh-cn catalog (captured live from that router).
    /// The misses are the catalog's own gaps — product names LuCI does
    /// not translate in its web UI either (WireGuard, MosDNS, DHCP…).
    private func visibleTitleCoverage(snapshotName: String, catalogName: String) throws
        -> (chinese: Int, total: Int, misses: [String]) {
        let data = try fixtureText(snapshotName, ext: "json")
        let collected = try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(data.utf8))
        let snapshot = CapabilitySnapshot(collected: collected)
        let catalog = try XCTUnwrap(LuciTranslationCatalog.parse(try fixtureText(catalogName, ext: "txt")))
        let localization = LuciLocalization(language: "zh-cn", catalog: catalog)
        var chinese = 0, total = 0
        var misses: [String] = []
        // menuTree roots are the groups; their children are the
        // visible second-level pages.
        for group in snapshot.menuTree {
            for node in group.children {
                total += 1
                let shown = localization.translate(node.title)
                if shown.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) {
                    chinese += 1
                } else {
                    misses.append(node.title)
                }
            }
        }
        return (chinese, total, misses)
    }

    func testLiveCatalogCoverageBypassRouter() throws {
        let coverage = try visibleTitleCoverage(
            snapshotName: "snapshot-192.168.31.167-2026-11-20",
            catalogName: "translations-192.168.31.167")
        print("COVERAGE-167 visible second-level: \(coverage.chinese)/\(coverage.total) misses=\(coverage.misses)")
        // Totals dropped by one with the custom-commands exclusion
        // (audit F6, package J decision).
        XCTAssertEqual(coverage.total, 48)
        XCTAssertGreaterThanOrEqual(coverage.chinese, 37)
    }

    func testLiveCatalogCoverageMainRouter() throws {
        let coverage = try visibleTitleCoverage(
            snapshotName: "snapshot-192.168.31.1-2026-11-20",
            catalogName: "translations-192.168.31.1")
        print("COVERAGE-1 visible second-level: \(coverage.chinese)/\(coverage.total) misses=\(coverage.misses)")
        XCTAssertEqual(coverage.total, 24)
        XCTAssertGreaterThanOrEqual(coverage.chinese, 22)
    }
}
