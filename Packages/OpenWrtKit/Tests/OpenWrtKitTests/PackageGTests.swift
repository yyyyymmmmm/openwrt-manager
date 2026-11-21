import XCTest
@testable import OpenWrtKit

/// Package G (safety & false conclusions): the core-service
/// protection list, the upstream-nature classification behind the
/// redial copy split, and the package-manager-aware update check.
final class PackageGTests: XCTestCase {

    // MARK: F1 — core service protection

    func testCoreServiceImpacts() {
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "rpcd"), .management)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "ubusd"), .management)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "uhttpd"), .management)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "dropbear"), .management)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "network"), .network)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "dnsmasq"), .dns)
        XCTAssertEqual(ServiceProtection.impact(forServiceNamed: "firewall"), .firewall)
    }

    func testStandardServicesAreNotCore() {
        // Day-to-day services from both audited routers: stopping
        // them is recoverable, so no protection applies.
        for name in ["mosdns", "openbox", "openbox-panel", "homeproxy", "ddns",
                     "vlmcsd", "appfilter", "cron", "sysntpd", "odhcpd", "nlbwmon"] {
            XCTAssertNil(ServiceProtection.impact(forServiceNamed: name), name)
            XCTAssertFalse(ServiceProtection.isCoreService(name), name)
        }
    }

    func testBlockedActionMatrix() {
        for name in ["rpcd", "ubusd", "uhttpd", "dropbear", "network", "dnsmasq", "firewall"] {
            XCTAssertTrue(ServiceProtection.isBlocked(action: .stop, forServiceNamed: name), name)
            XCTAssertTrue(ServiceProtection.isBlocked(action: .disable, forServiceNamed: name), name)
            // Start / restart / enable stay available even for core
            // services: restart is the recovery gesture, enable only
            // restores the safe state.
            XCTAssertFalse(ServiceProtection.isBlocked(action: .start, forServiceNamed: name), name)
            XCTAssertFalse(ServiceProtection.isBlocked(action: .restart, forServiceNamed: name), name)
            XCTAssertFalse(ServiceProtection.isBlocked(action: .enable, forServiceNamed: name), name)
        }
        for action in ServiceAction.allCases {
            XCTAssertFalse(ServiceProtection.isBlocked(action: action, forServiceNamed: "mosdns"))
        }
    }

    // MARK: U7 — upstream nature

    private func upstream(name: String, device: String?, l3: String? = nil, v6: Bool = false)
        -> CapabilitySnapshot.Upstream {
        CapabilitySnapshot.Upstream(interfaceName: name, device: device, l3Device: l3,
                                    nexthop: "192.168.31.1", isIPv6: v6)
    }

    func testUpstreamNatureTrueWAN() {
        // The main router (.1 shape): default route on wan/pppoe.
        let interfaces = [CollectedRouterSnapshot.InterfaceState(
            name: "wan", up: true, proto: "pppoe", device: "eth1", l3Device: "pppoe-wan")]
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "wan", device: "eth1", l3: "pppoe-wan"),
                                          interfaces: interfaces), .wan)
        // A DHCP WAN on a plain ethernet device is still a WAN.
        let dhcp = [CollectedRouterSnapshot.InterfaceState(
            name: "wan", up: true, proto: "dhcp", device: "eth1", l3Device: "eth1")]
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "wan", device: "eth1", l3: "eth1"),
                                          interfaces: dhcp), .wan)
        // IPv6-only upstream on wan6 is a WAN too.
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "wan6", device: "eth1", v6: true),
                                          interfaces: dhcp), .wan)
    }

    func testUpstreamNatureBypassLAN() {
        // The bypass router (.167 shape, measured 2026-11-21):
        // default route belongs to lan on the br-lan bridge.
        let interfaces = [CollectedRouterSnapshot.InterfaceState(
            name: "lan", up: true, proto: "static", device: "br-lan", l3Device: "br-lan")]
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "lan", device: "br-lan", l3: "br-lan"),
                                          interfaces: interfaces), .local)
        // The bridge device alone is decisive even under another name.
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "lan0", device: "br-lan"),
                                          interfaces: []), .local)
        // And the lan name alone (device reported differently).
        XCTAssertEqual(
            DiscoveryRules.upstreamNature(of: upstream(name: "lan", device: "eth0"),
                                          interfaces: []), .local)
    }

    // MARK: F2 — package-manager-aware update check

    /// Package L rewired the check to the package-manager helper's
    /// two lists (cgi-exec): the bare opkg/apk execs it used before
    /// are granted to no login session (permission audit #10), so
    /// these tests now script the lists channel instead. The F2
    /// contract is unchanged: manager-aware, "cannot check" (nil)
    /// distinct from "nothing to update" (empty), failures throw.
    private final class PackageListsCaller: UbusCalling, @unchecked Sendable {
        var lists: PackageLists?
        var listsError: Error?

        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            .object([:])
        }

        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
        func packageLists() async throws -> PackageLists {
            if let listsError { throw listsError }
            guard let lists else { throw OpenWrtKitError.unsupported("no lists scripted") }
            return lists
        }
    }

    private func package(_ name: String, _ version: String) -> InstalledPackage {
        InstalledPackage(name: name, version: version)
    }

    func testUpgradablePackagesViaOpkg() async throws {
        let caller = PackageListsCaller()
        caller.lists = PackageLists(
            manager: .opkg,
            installed: [package("base-files", "1"), package("busybox", "1.36.1-1"), package("dnsmasq", "2.90")],
            available: [package("base-files", "2"), package("busybox", "1.36.1-2"), package("dnsmasq", "2.90")])
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .opkg)
        // Only version differences appear, in the historical
        // "name - installed - available" line shape.
        XCTAssertEqual(result?.lines, ["base-files - 1 - 2", "busybox - 1.36.1-1 - 1.36.1-2"])
    }

    func testUpgradablePackagesViaApk() async throws {
        let caller = PackageListsCaller()
        caller.lists = PackageLists(
            manager: .apk,
            installed: [package("busybox", "1.36.1-r1")],
            available: [package("busybox", "1.36.1-r2"), package("not-installed", "9")])
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .apk)
        // A package that is available but not installed is not an
        // upgrade and must not appear.
        XCTAssertEqual(result?.lines, ["busybox - 1.36.1-r1 - 1.36.1-r2"])
    }

    func testUpgradablePackagesNoManager() async throws {
        // The session cannot query package lists at all: the check
        // is impossible (nil), which the UI renders as "cannot
        // check" — never as "no updates".
        let caller = PackageListsCaller()
        caller.listsError = OpenWrtKitError.unsupported("no helper")
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertNil(result)
    }

    func testUpgradablePackagesEmptyIsARealConclusion() async throws {
        // Lists answer and nothing differs: a true "nothing to
        // update", distinct from the nil case above.
        let caller = PackageListsCaller()
        caller.lists = PackageLists(
            manager: .apk,
            installed: [package("busybox", "1.36.1-r2")],
            available: [package("busybox", "1.36.1-r2")])
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .apk)
        XCTAssertEqual(result?.lines, [])
    }

    func testUpgradablePackagesListFailureThrows() async {
        // The lists fetch fails after the channel exists: the error
        // must surface (true failure state), not collapse to empty.
        let caller = PackageListsCaller()
        caller.listsError = OpenWrtKitError.ubus(code: -1, message: "boom")
        let client = ReadOnlyDataClient(caller: caller)
        do {
            _ = try await client.upgradablePackages()
            XCTFail("expected the list failure to throw")
        } catch {
            XCTAssertTrue(error is OpenWrtKitError)
        }
    }
}
