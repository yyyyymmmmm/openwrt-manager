import XCTest
@testable import OpenWrtKit

final class PageRegistryTests: XCTestCase {
    private func collected(_ name: String) throws -> CollectedRouterSnapshot {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).json")
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            XCTFail("Missing collected snapshot resource \(name).json")
            throw OpenWrtKitError.malformedResponse
        }
        return try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
    }

    private func tabs(_ name: String) throws -> [TabDescriptor] {
        PageRegistry.tabs(for: CapabilitySnapshot(collected: try collected(name)))
    }

    private func pages(_ tabs: [TabDescriptor], _ tab: AppTabID) -> [PageDescriptor] {
        tabs.first { $0.tab == tab }?.pages ?? []
    }

    // MARK: Bypass router (.167)

    func testBypassTabsAndOverviewPages() throws {
        let tabs = try tabs("snapshot-192.168.31.167-2026-11-20")
        XCTAssertEqual(tabs.map(\.tab), [.overview, .network, .services, .system, .settings])
        let overview = pages(tabs, .overview)
        XCTAssertEqual(overview.first?.kind, .overviewHome)
        let kinds = overview.map(\.kind)
        XCTAssertTrue(kinds.contains(.realtime))
        XCTAssertTrue(kinds.contains(.wireguardStatus))
        XCTAssertTrue(kinds.contains(.logs))
        XCTAssertTrue(kinds.contains(.processes))
        XCTAssertTrue(kinds.contains(.firewallStatus))
        // "Release RAM" is a phase-2 action, never a phase-1 page.
        XCTAssertFalse(overview.contains { $0.menuPath == "admin/status/ramfree" })
    }

    func testBypassNetworkPagesSplitDHCPAndDNS() throws {
        let tabs = try tabs("snapshot-192.168.31.167-2026-11-20")
        let network = pages(tabs, .network)
        XCTAssertTrue(network.contains { $0.kind == .dhcp(merged: false) })
        XCTAssertTrue(network.contains { $0.kind == .dns })
        XCTAssertTrue(network.contains { $0.kind == .interfaces })
        XCTAssertTrue(network.contains { $0.kind == .firewallConfig })
        XCTAssertTrue(network.contains { $0.kind == .upnp })
        XCTAssertTrue(network.contains { $0.kind == .bandwidthMonitor })
        XCTAssertFalse(network.contains { $0.kind == .wireless })
    }

    func testBypassServicePagesDedicatedAndGeneric() throws {
        let tabs = try tabs("snapshot-192.168.31.167-2026-11-20")
        let services = pages(tabs, .services)
        XCTAssertEqual(services.count, 14)
        let dedicated = services.filter { if case .serviceDedicated = $0.kind { return true }; return false }
        XCTAssertEqual(Set(dedicated.compactMap(\.serviceKey)),
                       ["openbox", "homeproxy", "mosdns", "ddns", "appfilter", "wol", "vlmcsd",
                        "frpc", "natmap", "socat", "zerotier", "webdav"])
        let generic = services.filter(\.isGenericFallback)
        XCTAssertEqual(generic.count, 2)
        // Only the two low-increment AirPlay services stay generic.
        XCTAssertEqual(Set(generic.compactMap(\.serviceKey)), ["airconnect", "airplay2"])
        // Socat's dedicated page reads luci_socat, not the daemon file.
        XCTAssertEqual(services.first { $0.serviceKey == "socat" }?.configNames, ["luci_socat"])
        // WOL's UCI config is named etherwake, not wol.
        XCTAssertEqual(services.first { $0.serviceKey == "wol" }?.configNames, ["etherwake"])
        // No page may be keyed by a package name.
        XCTAssertTrue(services.allSatisfy { !($0.serviceKey ?? "").hasPrefix("luci-app-") })
    }

    func testBypassSystemPagesExcludeTerminalAndFiles() throws {
        let tabs = try tabs("snapshot-192.168.31.167-2026-11-20")
        let system = pages(tabs, .system)
        XCTAssertFalse(system.contains { $0.menuPath == "admin/system/ttyd" })
        XCTAssertFalse(system.contains { $0.menuPath == "admin/system/quickfile" })
        XCTAssertTrue(system.contains { $0.kind == .packages })
        XCTAssertTrue(system.contains { $0.kind == .onlineUpgrade })
        XCTAssertTrue(system.contains { $0.kind == .backupRestore })
        XCTAssertTrue(system.contains { $0.kind == .rebootInfo })
        XCTAssertTrue(system.contains { $0.menuPath == "admin/system/argon-config" })
    }

    // MARK: Main router (.1)

    func testMainNetworkPagesMergeDHCPAndDNS() throws {
        let tabs = try tabs("snapshot-192.168.31.1-2026-11-20")
        let network = pages(tabs, .network)
        let dhcp = network.first { $0.menuPath == "admin/network/dhcp" }
        XCTAssertEqual(dhcp?.kind, .dhcp(merged: true))
        XCTAssertEqual(dhcp?.title, "DHCP and DNS")
        XCTAssertFalse(network.contains { $0.kind == .dns })
        XCTAssertTrue(network.contains { $0.kind == .wireless })
    }

    func testMainServicePagesAreInitFallbackGeneric() throws {
        let snapshot = CapabilitySnapshot(collected: try collected("snapshot-192.168.31.1-2026-11-20"))
        let tabs = PageRegistry.tabs(for: snapshot)
        let services = pages(tabs, .services)
        XCTAssertEqual(services.count, snapshot.initServices.count)
        XCTAssertTrue(services.allSatisfy(\.isGenericFallback))
        XCTAssertTrue(services.contains { $0.serviceKey == "dnsmasq" })
    }

    func testMainOverviewHasChannelAnalysis() throws {
        let tabs = try tabs("snapshot-192.168.31.1-2026-11-20")
        XCTAssertTrue(pages(tabs, .overview).contains { $0.kind == .channelAnalysis })
        XCTAssertFalse(pages(tabs, .overview).contains { $0.kind == .wireguardStatus })
    }

    func testSettingsPagesAreAppLocal() throws {
        let tabs = try tabs("snapshot-192.168.31.1-2026-11-20")
        let settings = pages(tabs, .settings)
        XCTAssertEqual(settings.map(\.kind), [.profiles, .about])
        XCTAssertTrue(settings.allSatisfy { $0.menuPath == nil })
    }

    // MARK: Generic page model

    func testGenericPageModelRendersSectionsAndValues() {
        let configuration = RouterConfiguration(name: "ddns", sections: [
            ConfigurationSection(id: "myddns", type: "service", values: [
                "enabled": .bool(true), "domain": .string("example.com"),
                "retry": .number(300), "options": .array([.string("a"), .string("b")])
            ])
        ])
        let sections = GenericPageModel.sections(from: configuration)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "service · myddns")
        let rows = Dictionary(uniqueKeysWithValues: sections[0].rows.map { ($0.key, $0.valueText) })
        XCTAssertEqual(rows["enabled"], "是")
        XCTAssertEqual(rows["domain"], "example.com")
        XCTAssertEqual(rows["retry"], "300")
        XCTAssertEqual(rows["options"], "a、b")
        XCTAssertEqual(GenericPageModel.displayText(.null), "—")
    }

    // MARK: Open-Box parsers

    func testOpenBoxParsers() throws {
        let statusJSON = #"{"core":{"running":true,"enabled":true},"panel":{"running":false},"needsRestart":true}"#
        let status = OpenBoxParser.serviceStatus(try JSONDecoder().decode(JSONValue.self, from: Data(statusJSON.utf8)))
        XCTAssertEqual(status.coreRunning, true)
        XCTAssertEqual(status.panelRunning, false)
        XCTAssertEqual(status.coreEnabled, true)
        XCTAssertEqual(status.needsRestart, true)

        let proxiesJSON = #"{"proxies":{"AI":{"type":"Selector","now":"US-1","all":["US-1","JP-1"]},"DIRECT":{"type":"Direct"}}}"#
        let proxies = OpenBoxParser.proxies(try JSONDecoder().decode(JSONValue.self, from: Data(proxiesJSON.utf8)))
        XCTAssertEqual(proxies.count, 2)
        XCTAssertEqual(proxies[0].name, "AI")
        XCTAssertEqual(proxies[0].current, "US-1")
        XCTAssertEqual(proxies[0].members, ["US-1", "JP-1"])

        let versionJSON = #"{"version":"1.14.1"}"#
        XCTAssertEqual(OpenBoxParser.kernelVersion(try JSONDecoder().decode(JSONValue.self, from: Data(versionJSON.utf8))), "1.14.1")
    }
}
