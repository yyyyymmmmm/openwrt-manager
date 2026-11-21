import XCTest
@testable import OpenWrtKit

/// Driven by the two real-router collected snapshots (bypass router
/// 192.168.31.167 on OpenWrt 25.12.5 and main router 192.168.31.1 on
/// 24.10.8), captured 2026-11-20 and verified menu-by-menu in the phase-0
/// discovery alignment report.
final class CapabilitySnapshotTests: XCTestCase {
    private func collected(_ name: String) throws -> CollectedRouterSnapshot {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).json")
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            XCTFail("Missing collected snapshot resource \(name).json")
            throw OpenWrtKitError.malformedResponse
        }
        return try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
    }

    private func bypass() throws -> CapabilitySnapshot {
        CapabilitySnapshot(collected: try collected("snapshot-192.168.31.167-2026-11-20"))
    }

    private func main() throws -> CapabilitySnapshot {
        CapabilitySnapshot(collected: try collected("snapshot-192.168.31.1-2026-11-20"))
    }

    // MARK: Bypass router (.167)

    func testBypassSnapshotGeneratesNoWirelessNodes() throws {
        let snapshot = try bypass()
        XCTAssertFalse(snapshot.wireless.present)
        XCTAssertTrue(snapshot.wireless.radios.isEmpty)
        for gated in ["admin/network/wireless", "admin/status/channel_analysis", "admin/status/realtime/wireless"] {
            XCTAssertFalse(snapshot.visibleMenuPaths.contains(gated), "\(gated) must be gated without a wifi-device")
            XCTAssertNil(snapshot.menuNode(gated))
        }
    }

    func testBypassUpstreamIsLanBridgeNotWan() throws {
        let snapshot = try bypass()
        XCTAssertEqual(snapshot.upstream?.interfaceName, "lan")
        XCTAssertEqual(snapshot.upstream?.l3Device, "br-lan")
        XCTAssertEqual(snapshot.upstream?.nexthop, "192.168.31.1")
        XCTAssertEqual(snapshot.upstream?.isIPv6, false)
    }

    func testBypassServicesComeFromMenuAndInitNotPackageList() throws {
        let snapshot = try bypass()
        // Open-Box is the counterexample: its luci-app is absent from the
        // package manager list, yet the service exists and runs.
        XCTAssertFalse(snapshot.installedApps.contains("luci-app-openbox"))
        let openbox = snapshot.services.first { $0.key == "openbox" }
        XCTAssertNotNil(openbox)
        XCTAssertEqual(openbox?.source, .menuAndInit)
        XCTAssertEqual(openbox?.initNames, ["openbox", "openbox-panel"])
        XCTAssertEqual(openbox?.enabled, true)
        XCTAssertEqual(openbox?.running, true)
        // All 14 real service menus are present, and no entry is a package
        // name masquerading as a service.
        XCTAssertEqual(snapshot.services.count, 14)
        XCTAssertTrue(snapshot.services.allSatisfy { !$0.key.hasPrefix("luci-app-") })
        XCTAssertTrue(snapshot.services.allSatisfy { $0.menuPath != nil })
        XCTAssertEqual(Set(snapshot.services.map(\.key)),
                       ["airconnect", "airplay2", "appfilter", "ddns", "frpc", "homeproxy",
                        "mosdns", "natmap", "openbox", "socat", "vlmcsd", "webdav", "wol", "zerotier"])
    }

    func testBypassDHCPAndDNSAreSeparateNodes() throws {
        let snapshot = try bypass()
        XCTAssertNotNil(snapshot.menuNode("admin/network/dhcp"))
        XCTAssertNotNil(snapshot.menuNode("admin/network/dns"))
        XCTAssertEqual(snapshot.menuNode("admin/network/dhcp")?.title, "DHCP")
    }

    func testBypassEndpointsAndAliasesAreFiltered() throws {
        let snapshot = try bypass()
        for endpoint in ["admin/menu", "admin/uci", "admin/uci/confirm", "admin/status/routesj",
                         "admin/network/remote_addr/*", "admin/system/commands/download/*",
                         "admin/system/diskman/partition", "admin/vpn", "admin/status/iptables"] {
            XCTAssertFalse(snapshot.visibleMenuPaths.contains(endpoint), "\(endpoint) must not be generated")
        }
        XCTAssertTrue(snapshot.visibleMenuPaths.contains("admin/status/overview"))
        XCTAssertTrue(snapshot.visibleMenuPaths.contains("admin/services/openbox"))
        XCTAssertTrue(snapshot.visibleMenuPaths.contains("admin/logout"))
    }

    func testBypassIdentityAndFirmware() throws {
        let snapshot = try bypass()
        XCTAssertEqual(snapshot.routerID, "bypass-192.168.31.167")
        XCTAssertEqual(snapshot.firmware.version, "25.12.5")
        XCTAssertEqual(snapshot.board.model, "QEMU Standard PC (i440FX + PIIX, 1996)")
        XCTAssertGreaterThan(snapshot.capturedAt, Date(timeIntervalSince1970: 0))
    }

    // MARK: Main router (.1)

    func testMainSnapshotHasWirelessNodes() throws {
        let snapshot = try main()
        XCTAssertTrue(snapshot.wireless.present)
        XCTAssertEqual(snapshot.wireless.radios.count, 2)
        XCTAssertNotNil(snapshot.menuNode("admin/network/wireless"))
        XCTAssertTrue(snapshot.visibleMenuPaths.contains("admin/status/realtime/wireless"))
        XCTAssertNotNil(snapshot.menuNode("admin/status/channel_analysis"))
    }

    func testMainUpstreamIsWAN() throws {
        let snapshot = try main()
        XCTAssertEqual(snapshot.upstream?.interfaceName, "wan")
        XCTAssertEqual(snapshot.upstream?.nexthop, "192.168.1.1")
    }

    func testMainDHCPAndDNSAreOneMergedNode() throws {
        let snapshot = try main()
        // OpenWrt 24.10 ships a single "DHCP and DNS" menu; the split into
        // two pages on 25.12 must come from the snapshot, not from code.
        XCTAssertEqual(snapshot.menuNode("admin/network/dhcp")?.title, "DHCP and DNS")
        XCTAssertNil(snapshot.menuNode("admin/network/dns"))
        XCTAssertFalse(snapshot.visibleMenuPaths.contains("admin/network/dns"))
    }

    func testMainServicesFallBackToInitCoreServices() throws {
        let snapshot = try main()
        XCTAssertFalse(snapshot.services.isEmpty)
        XCTAssertTrue(snapshot.services.allSatisfy { $0.source == .initFallback })
        XCTAssertTrue(snapshot.services.allSatisfy { $0.menuPath == nil })
        for core in ["dnsmasq", "odhcpd", "dropbear", "wpad"] {
            XCTAssertTrue(snapshot.services.contains { $0.key == core }, "missing core service \(core)")
        }
        XCTAssertEqual(snapshot.services.count, snapshot.initServices.count)
    }

    func testMainIdentityAndFirmware() throws {
        let snapshot = try main()
        XCTAssertEqual(snapshot.routerID, "main-192.168.31.1")
        XCTAssertEqual(snapshot.firmware.version, "24.10.8")
        XCTAssertEqual(snapshot.board.model, "Xiaomi Mi Router AX3000T")
    }

    // MARK: Pure rules on synthetic input

    func testUpstreamNeverMatchesByInterfaceName() {
        let interfaces: [CollectedRouterSnapshot.InterfaceState] = [
            .init(name: "wan", up: true, device: "eth1", l3Device: "eth1"),
            .init(name: "lan", up: true, device: "br-lan", l3Device: "br-lan",
                  routes: [.init(target: "0.0.0.0", mask: 0, nexthop: "192.168.31.1")])
        ]
        let upstream = DiscoveryRules.resolveUpstream(interfaces: interfaces)
        XCTAssertEqual(upstream?.interfaceName, "lan")
        XCTAssertEqual(upstream?.l3Device, "br-lan")
    }

    func testUpstreamFallsBackToIPv6DefaultRoute() {
        let interfaces: [CollectedRouterSnapshot.InterfaceState] = [
            .init(name: "wan6", up: true, routes: [.init(target: "::", mask: 0, nexthop: "fe80::1")])
        ]
        let upstream = DiscoveryRules.resolveUpstream(interfaces: interfaces)
        XCTAssertEqual(upstream?.interfaceName, "wan6")
        XCTAssertEqual(upstream?.isIPv6, true)
    }

    func testWirelessGatingRule() {
        let paths = ["admin/network/wireless", "admin/status/channel_analysis",
                     "admin/status/realtime/wireless", "admin/status/overview"]
        XCTAssertEqual(DiscoveryRules.visibleMenuPaths(paths, capabilities: []), ["admin/status/overview"])
        XCTAssertEqual(DiscoveryRules.visibleMenuPaths(paths, capabilities: [.wifiDevice]).count, 4)
    }
}
