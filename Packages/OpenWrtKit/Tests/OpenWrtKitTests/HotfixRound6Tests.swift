import XCTest
@testable import OpenWrtKit

/// Round 6: service-state reconciliation against real hauls, plus the
/// terminal committed-text encoder.
///
/// The fixtures are the routers' own responses, captured 2026-11-21
/// through the app's channels (ubus session for rc/service lists, LuCI
/// cookie for the menu) on 192.168.31.167 (OpenWrt 25.12.5) and
/// 192.168.31.1 (OpenWrt 24.10.8). The expected tables below are the
/// rc-list ground truth from the same capture — every service row the
/// app derives is asserted against it, item by item. The main router's
/// app session is denied the procd service object (measured: the call
/// errors), so its haul is modeled with services = nil, exactly what
/// discovery sees there.
final class HotfixRound6Tests: XCTestCase {

    private func fixtureJSON(_ name: String) throws -> JSONValue {
        // Same lookup chain as the other fixture suites: the bundle
        // subdirectory form on Apple platforms, the source-tree path
        // where resources land flat (Linux test runs).
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// Runs the real discovery assembly over a captured haul, the same
    /// path the app runs (rc list is the init catalogue's primary
    /// source, mirroring RouterReader.initServiceList).
    private func haulSnapshot(menu: String, rcList: String, serviceList: String?) throws -> CapabilitySnapshot {
        var inventory = RouterInventory()
        inventory.menus = try InventoryParser.menus(try fixtureJSON(menu))
        inventory.menuRead = true
        let rc = try fixtureJSON(rcList)
        inventory.initServices = try InventoryParser.initServices(rc)
        inventory.initRead = true
        var raw = RouterReader.DiscoveryRawData()
        raw.rcList = rc
        if let serviceList { raw.services = try fixtureJSON(serviceList) }
        let collected = RouterDiscovery.assemble(
            routerID: "recon", address: "http://router", role: nil, inventory: inventory, raw: raw)
        return CapabilitySnapshot(collected: collected)
    }

    private struct Expected {
        let key: String
        let initNames: [String]
        let running: Bool?
        let enabled: Bool?
        let noteIsNoState: Bool
    }

    private func assertServices(_ snapshot: CapabilitySnapshot, _ expected: [Expected],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.services.map(\.key), expected.map(\.key), "service key set/order", file: file, line: line)
        for want in expected {
            guard let got = snapshot.services.first(where: { $0.key == want.key }) else { continue }
            XCTAssertEqual(got.initNames, want.initNames, "\(want.key): init names", file: file, line: line)
            XCTAssertEqual(got.running, want.running, "\(want.key): running", file: file, line: line)
            XCTAssertEqual(got.enabled, want.enabled, "\(want.key): enabled", file: file, line: line)
            if want.noteIsNoState {
                XCTAssertEqual(got.statusNote, DiscoveryRules.ServiceStatusNote.noStateReported,
                               "\(want.key): unknown must carry the no-state-reported note", file: file, line: line)
            } else {
                XCTAssertNil(got.statusNote, "\(want.key): known state must not carry a note", file: file, line: line)
            }
        }
    }

    /// .167: 14 services-menu entries. Before this round, 12 of the 14
    /// rendered "unknown": procd lists stopped daemons as empty objects
    /// and the rc fill never landed behind them (plus wol's name miss).
    /// Ground truth (rc list, same capture): everything below is
    /// decidable except webdav and wol/etherwake, whose rc entries
    /// carry no running field at all.
    func testBypassRouterServiceReconciliation() throws {
        let snapshot = try haulSnapshot(menu: "haul-192.168.31.167-menu",
                                        rcList: "haul-192.168.31.167-rclist",
                                        serviceList: "haul-192.168.31.167-servicelist")
        let stopped = { (key: String, initNames: [String]) in
            Expected(key: key, initNames: initNames, running: false, enabled: true, noteIsNoState: false)
        }
        // Display order is the menu order (homeproxy 10, mosdns and
        // openbox 30, ddns 59, vlmcsd 60, wol 90, the rest unordered
        // and alphabetical) — the sequence the user sees in the list.
        assertServices(snapshot, [
            stopped("homeproxy", ["homeproxy"]),
            stopped("mosdns", ["mosdns"]),
            Expected(key: "openbox", initNames: ["openbox", "openbox-panel"], running: true, enabled: true, noteIsNoState: false),
            stopped("ddns", ["ddns"]),
            stopped("vlmcsd", ["vlmcsd"]),
            // wol resolves to etherwake only via the measured mapping;
            // etherwake is a one-shot script whose rc entry has no
            // running field — enabled is known, running is not.
            Expected(key: "wol", initNames: ["etherwake"], running: nil, enabled: true, noteIsNoState: true),
            stopped("airconnect", ["airconnect"]),
            stopped("airplay2", ["airplay2"]),
            Expected(key: "appfilter", initNames: ["appfilter"], running: true, enabled: true, noteIsNoState: false),
            stopped("frpc", ["frpc"]),
            stopped("natmap", ["natmap"]),
            stopped("socat", ["socat"]),
            // webdav: rc entry has enabled but no running field, and
            // procd reports no instances — genuinely undeterminable.
            Expected(key: "webdav", initNames: ["webdav"], running: nil, enabled: true, noteIsNoState: true),
            stopped("zerotier", ["zerotier"]),
        ])
    }

    /// .1: no services menu at all, so the service list is the init.d
    /// catalogue itself (initFallback). 19 of 26 states are decidable
    /// from rc; the 7 without an rc running field are boot-time
    /// one-shot scripts and must stay unknown — with the note.
    func testMainRouterServiceReconciliation() throws {
        let snapshot = try haulSnapshot(menu: "haul-192.168.31.1-menu",
                                        rcList: "haul-192.168.31.1-rclist",
                                        serviceList: nil)
        func row(_ key: String, _ running: Bool?, _ enabled: Bool? = true) -> Expected {
            Expected(key: key, initNames: [key], running: running, enabled: enabled, noteIsNoState: running == nil)
        }
        assertServices(snapshot, [
            row("boot", nil), row("bootcount", nil), row("cron", false),
            row("dnsmasq", true), row("done", nil), row("dropbear", true),
            row("firewall", false), row("gpio_switch", false), row("keepalived", true),
            row("led", nil), row("log", true), row("network", true),
            row("odhcpd", true), row("packet_steering", false), row("rpcd", true),
            row("sysctl", nil), row("sysfixtime", nil), row("sysntpd", true),
            row("system", false), row("ubihealthd", true), row("ucitrack", false),
            row("uhttpd", true), row("umount", nil, false), row("urandom_seed", false),
            row("urngd", true), row("wpad", true),
        ])
        XCTAssertTrue(snapshot.services.allSatisfy { $0.source == .initFallback })
    }

    // MARK: Init-name resolution signals

    func testResolveInitNamesSignalPriority() {
        let entry = CollectedRouterSnapshot.MenuEntryInfo(configs: ["bar"], aclGroups: ["luci-app-baz"])
        // Exact leaf name beats every other signal.
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "foo", entry: entry, initNames: ["foo", "bar", "baz"]), ["foo"])
        // depends.uci config name is the second signal, family included.
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "qux", entry: entry, initNames: ["bar", "bar-helper", "baz"]), ["bar", "bar-helper"])
        // depends.acl app group is the third signal.
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "qux", entry: CollectedRouterSnapshot.MenuEntryInfo(aclGroups: ["luci-app-baz"]),
            initNames: ["baz"]), ["baz"])
        // Prefix family alone still resolves.
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "qux", entry: nil, initNames: ["qux-worker"]), ["qux-worker"])
        // The measured table is the last resort (wol measured on .167).
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "wol", entry: CollectedRouterSnapshot.MenuEntryInfo(aclGroups: ["luci-app-wol"]),
            initNames: ["etherwake"]), ["etherwake"])
        // Nothing measured, nothing matched: no invention.
        XCTAssertEqual(DiscoveryRules.resolveInitNames(
            key: "nope", entry: nil, initNames: ["other"]), [])
    }

    func testUnknownNotesDistinguishFailureFromNoMatch() throws {
        // Menu present but the whole init catalogue is missing (state
        // haul failed): the note must say the read failed, not that no
        // init service matched.
        var inventory = RouterInventory()
        inventory.menus = try InventoryParser.menus(try fixtureJSON("haul-192.168.31.167-menu"))
        inventory.menuRead = true
        let collected = RouterDiscovery.assemble(
            routerID: "recon", address: "http://router", role: nil,
            inventory: inventory, raw: RouterReader.DiscoveryRawData())
        let snapshot = CapabilitySnapshot(collected: collected)
        let mosdns = try XCTUnwrap(snapshot.services.first { $0.key == "mosdns" })
        XCTAssertNil(mosdns.running)
        XCTAssertEqual(mosdns.statusNote, DiscoveryRules.ServiceStatusNote.stateSourceFailed)
    }

    // MARK: Terminal committed-text encoding

    func testTerminalCommittedTextEncoding() {
        // Return reported as LF, CR, or CRLF all submit exactly one CR.
        XCTAssertEqual(TerminalInput.data(forCommittedText: "\n"), Data([0x0D]))
        XCTAssertEqual(TerminalInput.data(forCommittedText: "\r"), Data([0x0D]))
        XCTAssertEqual(TerminalInput.data(forCommittedText: "\r\n"), Data([0x0D]))
        XCTAssertEqual(TerminalInput.data(forCommittedText: "ls\n"), Data([0x6C, 0x73, 0x0D]))
        // DEL passes through as the backspace byte.
        XCTAssertEqual(TerminalInput.data(forCommittedText: "\u{7F}"), Data([0x7F]))
        XCTAssertEqual(TerminalInput.data(forCommittedText: "a\u{7F}b"), Data([0x61, 0x7F, 0x62]))
        // A committed IME composition goes out as its UTF-8 bytes.
        XCTAssertEqual(TerminalInput.data(forCommittedText: "你好"), Data("你好".utf8))
        // Named keys keep their established encodings.
        XCTAssertEqual(TerminalInput.data(for: .enter), Data([0x0D]))
        XCTAssertEqual(TerminalInput.data(for: .backspace), Data([0x7F]))
        XCTAssertEqual(TerminalInput.data(for: .control("C")), Data([0x03]))
        XCTAssertEqual(TerminalInput.data(for: .arrowUp), Data("\u{1B}[A".utf8))
    }
}
