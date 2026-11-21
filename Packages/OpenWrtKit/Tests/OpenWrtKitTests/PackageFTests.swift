import XCTest
@testable import OpenWrtKit

/// Package F: dedicated service pages (ddns / appfilter / wol /
/// vlmcsd) and the Open-Box panel deepening. Fixtures follow the
/// shapes the services' own LuCI views consume (ddns overview.js,
/// wol.js), captured in the gap inventory's live probes.
final class PackageFTests: XCTestCase {

    // MARK: ddns parsers

    func testDDNSGlobalState() {
        let state = DDNSParser.globalState(.object([
            "_enabled": .bool(true),
            "_version": .string("2.8.2-r5"),
            "_services_list": .string("2026-11-20 03:00")
        ]))
        XCTAssertEqual(state.autostartEnabled, true)
        XCTAssertEqual(state.version, "2.8.2-r5")
        XCTAssertEqual(state.servicesListUpdated, "2026-11-20 03:00")
        XCTAssertNil(DDNSParser.globalState(.object([:])).autostartEnabled)
    }

    func testDDNSServicesStatus() {
        let runtimes = DDNSParser.servicesStatus(.object([
            "home": .object([
                "ip": .string("203.0.113.7"),
                "last_update": .string("2026-11-21 10:00"),
                "next_update": .string("Verify"),
                "next_check": .string("2026-11-21 10:05"),
                "pid": .number(4321)
            ]),
            "office": .object(["pid": .string("0")])
        ]))
        XCTAssertEqual(runtimes.map(\.section), ["home", "office"])
        XCTAssertEqual(runtimes[0].ip, "203.0.113.7")
        XCTAssertEqual(runtimes[0].nextUpdate, "Verify")
        XCTAssertTrue(runtimes[0].running)
        XCTAssertFalse(runtimes[1].running)
    }

    func testDDNSServiceLogForms() {
        XCTAssertEqual(DDNSParser.serviceLog(.array([.string("a"), .string("b")])), ["a", "b"])
        XCTAssertEqual(DDNSParser.serviceLog(.object(["log": .array([.string("x")])])), ["x"])
        XCTAssertEqual(DDNSParser.serviceLog(.string("l1\nl2")), ["l1", "l2"])
        XCTAssertEqual(DDNSParser.serviceLog(.object([:])), [])
    }

    // MARK: appfilter parsers

    func testAppFilterStatus() {
        XCTAssertEqual(AppFilterParser.status(.object(["enable": .number(1)])).enabled, true)
        XCTAssertEqual(AppFilterParser.status(.object(["enabled": .bool(false)])).enabled, false)
        XCTAssertNil(AppFilterParser.status(.object([:])).enabled)
    }

    func testAppFilterClasses() {
        let classes = AppFilterParser.classes(.object([
            "class_list": .array([
                .object(["id": .number(3), "name": .string("视频"),
                         "apps": .array([.object(["name": .string("抖音")]), .string("快手")])]),
                .object(["class": .string("游戏"), "app_list": .array([.string("王者荣耀")])])
            ])
        ]))
        XCTAssertEqual(classes.count, 2)
        XCTAssertEqual(classes.first { $0.name == "视频" }?.identifier, "3")
        XCTAssertEqual(classes.first { $0.name == "视频" }?.apps, ["抖音", "快手"])
        XCTAssertEqual(classes.first { $0.name == "游戏" }?.apps, ["王者荣耀"])
    }

    func testAppFilterSelectionForms() {
        XCTAssertEqual(AppFilterParser.selection(.array([.string("3"), .string("7")])), ["3", "7"])
        XCTAssertEqual(AppFilterParser.selection(.object([
            "appfilter": .array([.object(["class": .string("5")])])
        ])), ["5"])
        XCTAssertEqual(AppFilterParser.selection(.object([
            "3": .bool(true), "7": .bool(false)
        ])), ["3"])
        XCTAssertEqual(AppFilterParser.selection(.object([:])), [])
    }

    func testAppFilterVisits() {
        let byClass = AppFilterParser.classVisits(.object(["视频": .number(42), "游戏": .number(7)]))
        XCTAssertEqual(byClass.map(\.name), ["视频", "游戏"])
        XCTAssertEqual(byClass.first?.value, 42)
        let devices = AppFilterParser.deviceVisits(.object([
            "list": .array([.object(["mac": .string("AA:BB:CC:DD:EE:FF"),
                                     "count": .number(9), "time": .number(120)])])
        ]))
        XCTAssertEqual(devices.first?.device, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(devices.first?.visits, 9)
        XCTAssertEqual(devices.first?.durationSeconds, 120)
    }

    // MARK: UCI write discovery

    private func configuration(_ sections: [ConfigurationSection]) -> RouterConfiguration {
        RouterConfiguration(name: "appfilter", sections: sections)
    }

    func testBooleanSwitchDiscovery() {
        let config = configuration([
            ConfigurationSection(id: "global", type: "global", values: ["enable": .string("1")]),
            ConfigurationSection(id: "other", type: "other", values: ["enabled": .string("0")])
        ])
        let found = DedicatedConfigDiscovery.booleanSwitch(in: config, options: ["enable", "enabled"])
        XCTAssertEqual(found?.sectionID, "global")
        XCTAssertEqual(found?.current, true)
        let missing = DedicatedConfigDiscovery.booleanSwitch(
            in: configuration([ConfigurationSection(id: "x", type: "x", values: [:])]),
            options: ["enable"])
        XCTAssertNil(missing)
    }

    func testClassListStorageDiscovery() {
        let config = configuration([
            ConfigurationSection(id: "global", type: "global", values: [
                "enable": .string("1"),
                "class": .array([.string("3"), .string("7")]),
                "unrelated": .array([.string("zzz")])
            ])
        ])
        let found = DedicatedConfigDiscovery.classListStorage(in: config, knownIdentifiers: ["3", "5"])
        XCTAssertEqual(found?.sectionID, "global")
        XCTAssertEqual(found?.option, "class")
        XCTAssertEqual(found?.values, ["3", "7"])
        XCTAssertNil(DedicatedConfigDiscovery.classListStorage(in: config, knownIdentifiers: []))
        XCTAssertNil(DedicatedConfigDiscovery.classListStorage(
            in: configuration([ConfigurationSection(id: "g", type: "global",
                                                    values: ["x": .array([.string("nope")])])]),
            knownIdentifiers: ["3"]))
    }

    // MARK: Wake-on-LAN

    func testWolPrograms() {
        let programs = WolParser.programs(.object(["etherwake": .bool(true), "wakeonlan": .bool(false)]))
        XCTAssertTrue(programs.etherwake)
        XCTAssertFalse(programs.wakeonlan)
        XCTAssertTrue(programs.anyAvailable)
    }

    func testWolWakeBuilderEtherwakeFull() {
        let request = WolWakeBuilder.request(
            executable: nil, programs: WolPrograms(etherwake: true, wakeonlan: true),
            mac: "AA:BB:CC:DD:EE:FF", interface: "br-lan", broadcast: true, password: "00:11:22:33:44:55")
        XCTAssertEqual(request?.name, "/usr/bin/etherwake")
        XCTAssertEqual(request?.args, ["-D", "-i", "br-lan", "-b", "-p", "00:11:22:33:44:55", "AA:BB:CC:DD:EE:FF"])
    }

    func testWolWakeBuilderMinimalAndWakeonlan() {
        let minimal = WolWakeBuilder.request(
            executable: nil, programs: WolPrograms(etherwake: true, wakeonlan: false),
            mac: "AA:BB:CC:DD:EE:FF", interface: nil, broadcast: false, password: nil)
        XCTAssertEqual(minimal?.args, ["-D", "AA:BB:CC:DD:EE:FF"])
        let wol = WolWakeBuilder.request(
            executable: "/usr/bin/wakeonlan", programs: WolPrograms(etherwake: true, wakeonlan: true),
            mac: "AA:BB:CC:DD:EE:FF", interface: "br-lan", broadcast: true, password: "x")
        XCTAssertEqual(wol?.name, "/usr/bin/wakeonlan")
        XCTAssertEqual(wol?.args, ["AA:BB:CC:DD:EE:FF"])
    }

    func testWolWakeBuilderFallbacks() {
        // Configured default is etherwake but only wakeonlan exists.
        let fallback = WolWakeBuilder.request(
            executable: "/usr/bin/etherwake", programs: WolPrograms(etherwake: false, wakeonlan: true),
            mac: "AA:BB:CC:DD:EE:FF", interface: "br-lan", broadcast: true, password: nil)
        XCTAssertEqual(fallback?.name, "/usr/bin/wakeonlan")
        XCTAssertNil(WolWakeBuilder.request(
            executable: nil, programs: WolPrograms(), mac: "AA:BB:CC:DD:EE:FF",
            interface: nil, broadcast: false, password: nil))
    }

    func testWolExecResult() {
        let ok = WolParser.execResult(.object(["stdout": .string("sent"), "stderr": .string(""), "code": .number(0)]))
        XCTAssertTrue(ok.succeeded)
        let bad = WolParser.execResult(.object(["stderr": .string("boom"), "code": .number(1)]))
        XCTAssertFalse(bad.succeeded)
        XCTAssertEqual(bad.stderr, "boom")
    }

    // MARK: Open-Box panel additions

    func testOpenBoxAuthenticatedParser() {
        XCTAssertEqual(OpenBoxParser.authenticated(.object(["authenticated": .bool(true)])), true)
        XCTAssertEqual(OpenBoxParser.authenticated(.object(["status": .string("logged_in")])), true)
        XCTAssertNil(OpenBoxParser.authenticated(.object([:])))
    }

    func testDedicatedValueTruthy() {
        XCTAssertEqual(DedicatedValue.truthy(.string("1")), true)
        XCTAssertEqual(DedicatedValue.truthy(.string("off")), false)
        XCTAssertEqual(DedicatedValue.truthy(.number(2)), true)
        XCTAssertEqual(DedicatedValue.truthy(.bool(false)), false)
        XCTAssertNil(DedicatedValue.truthy(.string("maybe")))
        XCTAssertNil(DedicatedValue.truthy(nil))
    }

    // MARK: Client parameter passing

    private final class RecordingCaller: UbusCalling, @unchecked Sendable {
        var calls: [(object: String, method: String, parameters: [String: JSONValue])] = []
        var responses: [String: JSONValue] = [:]
        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            calls.append((object, method, parameters))
            return responses["\(object).\(method)"] ?? .object([:])
        }
        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
    }

    func testClientPassesParameters() async throws {
        let caller = RecordingCaller()
        caller.responses["luci.ddns.get_services_log"] = .array([.string("line")])
        caller.responses["luci.wol.exec"] = .object(["code": .number(0)])
        let client = DedicatedServiceClient(caller: caller)
        let log = try await client.ddnsServiceLog(service: "home")
        XCTAssertEqual(log, ["line"])
        XCTAssertEqual(caller.calls.first?.parameters["service_name"], .string("home"))
        let result = try await client.wolExec(name: "/usr/bin/etherwake", args: ["-D", "AA"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(caller.calls.last?.parameters["name"], .string("/usr/bin/etherwake"))
        XCTAssertEqual(caller.calls.last?.parameters["args"], .array([.string("-D"), .string("AA")]))
    }
}
