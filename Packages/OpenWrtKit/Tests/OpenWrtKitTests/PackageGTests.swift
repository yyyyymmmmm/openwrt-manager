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

    private final class ExecScriptedCaller: UbusCalling, @unchecked Sendable {
        /// Keyed by "command arg1 arg2…"; a missing entry exits 127,
        /// like a binary that does not exist.
        var execResults: [String: (code: Int, stdout: String)] = [:]
        var requestedCommands: [String] = []

        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            guard object == "file", method == "exec" else { return .object([:]) }
            let command = parameters["command"]?.stringValue ?? ""
            let args = parameters["params"]?.arrayValue?.map { $0.stringValue ?? "" } ?? []
            let key = ([command] + args).joined(separator: " ")
            requestedCommands.append(key)
            let result = execResults[key] ?? (127, "")
            return .object(["code": .number(Double(result.code)), "stdout": .string(result.stdout)])
        }

        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
    }

    func testUpgradablePackagesViaOpkg() async throws {
        let caller = ExecScriptedCaller()
        caller.execResults["/bin/opkg --version"] = (0, "opkg version 2024.10.16")
        caller.execResults["/bin/opkg list-upgradable"] = (0, "base-files - 1 - 2\nbusybox - 1.36.1-1 - 1.36.1-2\n")
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .opkg)
        XCTAssertEqual(result?.lines, ["base-files - 1 - 2", "busybox - 1.36.1-1 - 1.36.1-2"])
        // opkg answered: apk is never probed.
        XCTAssertFalse(caller.requestedCommands.contains { $0.hasPrefix("/usr/bin/apk") })
    }

    func testUpgradablePackagesViaApk() async throws {
        // The .167 shape: no opkg at all (probe exits 127), apk answers.
        let caller = ExecScriptedCaller()
        caller.execResults["/usr/bin/apk --version"] = (0, "apk-tools 3.0.0")
        caller.execResults["/usr/bin/apk list --upgradable"] = (0, "busybox-1.36.1-r2 x86_64 {feeds} (upgradable from 1.36.1-r1)\n")
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .apk)
        XCTAssertEqual(result?.lines.count, 1)
        XCTAssertTrue(result?.lines.first?.contains("busybox") ?? false)
    }

    func testUpgradablePackagesNoManager() async throws {
        // Neither binary exists: the check is impossible (nil), which
        // the UI renders as "cannot check" — never as "no updates".
        let caller = ExecScriptedCaller()
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertNil(result)
    }

    func testUpgradablePackagesEmptyIsARealConclusion() async throws {
        // A manager that answers with an empty list is a true
        // "nothing to update", distinct from the nil case above.
        let caller = ExecScriptedCaller()
        caller.execResults["/usr/bin/apk --version"] = (0, "apk-tools 3.0.0")
        caller.execResults["/usr/bin/apk list --upgradable"] = (0, "")
        let client = ReadOnlyDataClient(caller: caller)
        let result = try await client.upgradablePackages()
        XCTAssertEqual(result?.manager, .apk)
        XCTAssertEqual(result?.lines, [])
    }

    func testUpgradablePackagesListFailureThrows() async {
        // Manager detected but the list command fails: the error
        // must surface (true failure state), not collapse to empty.
        let caller = ExecScriptedCaller()
        caller.execResults["/bin/opkg --version"] = (0, "opkg version 2024.10.16")
        caller.execResults["/bin/opkg list-upgradable"] = (1, "")
        let client = ReadOnlyDataClient(caller: caller)
        do {
            _ = try await client.upgradablePackages()
            XCTFail("expected the list failure to throw")
        } catch {
            XCTAssertTrue(error is OpenWrtKitError)
        }
    }
}
