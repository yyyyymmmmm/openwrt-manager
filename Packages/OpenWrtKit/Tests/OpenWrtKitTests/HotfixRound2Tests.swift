import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

/// Regression tests for the second real-device hotfix round
/// (2026-11-21): (1) menu titles rendered in English on a Chinese
/// LuCI — the router never translates menu titles, the web UI does it
/// client-side from the translations catalog, and the app now mirrors
/// that mechanism; (2) status pages failing with "permission
/// insufficient" because their exec command lines were not the exact
/// ones rpcd grants — nft/dmesg/ip — plus the per-router ACL gaps
/// (log read, network.device) that needed granted fallbacks.
final class HotfixRound2Tests: XCTestCase {

    // MARK: SuperFastHash — vectors verified against the live catalog
    // of the bypass router (hash -> translation pairs it serves).

    func testSuperFastHashMatchesLuciCatalogKeys() {
        XCTAssertEqual(LuciHash.superFastHash("Firewall"), "34f9da4c")
        XCTAssertEqual(LuciHash.superFastHash("Network"), "e54695b9")
        XCTAssertEqual(LuciHash.superFastHash("Processes"), "8e770194")
        XCTAssertEqual(LuciHash.superFastHash("Wireless"), "d55cef16")
    }

    // MARK: Catalog parsing and lookup

    func testCatalogParsesWindowTRWithTrailingComma() {
        // Verbatim payload shape of /admin/translations/<lang>,
        // including its trailing comma before the closing brace.
        let payload = #"window.TR={"34f9da4c":"防火墙","e54695b9":"网络",};"#
        let catalog = LuciTranslationCatalog.parse(payload)
        XCTAssertNotNil(catalog)
        XCTAssertEqual(catalog?.translate("Firewall"), "防火墙")
        XCTAssertEqual(catalog?.translate("Network"), "网络")
        XCTAssertNil(catalog?.translate("Bandwidth Monitor"))
        // Lookup keys are whitespace-normalized like cbi.js trimws().
        XCTAssertEqual(catalog?.translate("  Firewall  "), "防火墙")
    }

    // MARK: Language negotiation (dispatcher.uc semantics)

    private func luciConfig(lang: String, languages: [String]) throws -> JSONValue {
        // Real uci get luci shape captured from the bypass router:
        // section IDs are "main"/"languages" while their .type values
        // are "core"/"internal" — matching must use the IDs.
        let languagesObject = languages.map { "\"\($0)\":\"x\"" }.joined(separator: ",")
        let json = """
        {"values":{
          "main":{".type":"core","lang":"\(lang)"},
          "languages":{".type":"internal",\(languagesObject)}
        }}
        """
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testNegotiationFixedLanguageWins() throws {
        // Superseded by the localization package's system-first order
        // (see LocalizationSystemTests): a fixed router language no
        // longer overrides an English system preference. The fixed
        // language is now the fallback when the system language has no
        // catalog on the router.
        let config = try luciConfig(lang: "zh_cn", languages: ["zh_cn"])
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["en-US"]))
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["fr-FR"]), "zh-cn")
    }

    func testNegotiationAutoMatchesScriptFormPreference() throws {
        // iOS reports zh-Hans-CN; the router registers zh_cn. The
        // region part must win over the script part.
        let config = try luciConfig(lang: "auto", languages: ["zh_cn"])
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["zh-Hans-CN"]), "zh-cn")
        XCTAssertEqual(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["zh-CN"]), "zh-cn")
    }

    func testNegotiationEnglishAndUnknownYieldNoCatalog() throws {
        let config = try luciConfig(lang: "auto", languages: ["zh_cn"])
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["en-US"]))
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: config, preferredLanguages: ["fr-FR"]))
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: nil, preferredLanguages: ["zh-Hans-CN"]))
        let english = try luciConfig(lang: "en", languages: [])
        XCTAssertNil(LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: english, preferredLanguages: ["zh-Hans-CN"]))
    }

    // MARK: Chinese menu fixture — titles flow translated into pages

    func testChineseMenuTitlesReachGeneratedPages() throws {
        // Menu shape as the router serves it: source-language titles.
        let menuJSON = """
        {"children":{"admin":{"satisfied":true,"children":{
          "status":{"title":"Status","satisfied":true,"order":10,"children":{
            "firewall":{"title":"Firewall","satisfied":true,"order":30},
            "processes":{"title":"Processes","satisfied":true,"order":50},
            "bandwidth":{"title":"Bandwidth Monitor","satisfied":true,"order":60}
          }},
          "network":{"title":"Network","satisfied":true,"order":20,"children":{
            "wireless":{"title":"Wireless","satisfied":true,"order":40}
          }}
        }}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(menuJSON.utf8))
        let catalog = LuciTranslationCatalog(entries: [
            "34f9da4c": "防火墙", "e54695b9": "网络",
            "8e770194": "进程", "d55cef16": "无线"
        ])
        let menus = try InventoryParser.menus(value).map { $0.applyingTranslations(catalog) }
        let status = menus.first { $0.id == "admin/status" }
        XCTAssertEqual(status?.children.map(\.title), ["防火墙", "进程", "Bandwidth Monitor"])
        XCTAssertEqual(menus.first { $0.id == "admin/network" }?.title, "网络")

        // The translated titles are what page generation consumes.
        let all = menus.flatMap { [$0] + $0.descendants }
        var entries: [String: CollectedRouterSnapshot.MenuEntryInfo] = [:]
        for entry in all {
            entries[entry.id] = .init(title: entry.title, order: entry.order)
        }
        let collected = CollectedRouterSnapshot(
            device: .init(id: "test", address: "192.168.31.167"),
            collectedAt: "2026-11-21T00:00:00.000Z",
            board: .init(hostname: "bypass"),
            menuPaths: all.map(\.id), menuTree: entries,
            wireless: .init(present: false))
        let tabs = PageRegistry.tabs(for: CapabilitySnapshot(collected: collected))
        let overview = tabs.first { $0.tab == .overview }
        XCTAssertEqual(overview?.pages.first { $0.kind == .firewallStatus }?.title, "防火墙")
        XCTAssertEqual(overview?.pages.first { $0.kind == .processes }?.title, "进程")
    }

    // MARK: nftables JSON parser (real ruleset captured from .167)

    private func fixtureText(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNftablesJSONParserOnRealRuleset() throws {
        let tables = try ReadOnlyParser.nftablesJSON(try fixtureText("nftables-192.168.31.167"))
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].family, "inet")
        XCTAssertEqual(tables[0].name, "fw4")
        let input = tables[0].chains.first { $0.name == "input" }
        XCTAssertEqual(input?.countedRules, 3)
        XCTAssertEqual(input?.packets, 18)
        XCTAssertEqual(input?.bytes, 3378)
        let forward = tables[0].chains.first { $0.name == "forward" }
        XCTAssertEqual(forward?.countedRules, 3)
        XCTAssertEqual(forward?.packets, 644)
        XCTAssertEqual(forward?.bytes, 361046)
    }

    // MARK: Read paths through a scripted caller

    private final class ScriptedCaller: UbusCalling, @unchecked Sendable {
        var handler: (String, String, [String: JSONValue]) throws -> JSONValue = { _, _, _ in .object([:]) }
        var execLog: [(command: String, params: [String])] = []
        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            if object == "file", method == "exec" {
                execLog.append((parameters["command"]?.stringValue ?? "",
                                (parameters["params"]?.arrayValue ?? []).compactMap(\.stringValue)))
            }
            return try handler(object, method, parameters)
        }
        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
    }

    private func execResult(_ stdout: String) -> JSONValue {
        .object(["code": .number(0), "stdout": .string(stdout)])
    }

    func testFirewallReadUsesGrantedJSONCommandLine() async throws {
        let fixture = try fixtureText("nftables-192.168.31.167")
        let caller = ScriptedCaller()
        caller.handler = { object, method, parameters in
            guard object == "file", method == "exec" else { throw OpenWrtKitError.unsupported("n/a") }
            let params = (parameters["params"]?.arrayValue ?? []).compactMap(\.stringValue)
            if params == ["--terse", "--json", "list", "ruleset"] { return self.execResult(fixture) }
            throw OpenWrtKitError.permissionDenied
        }
        let tables = try await ReadOnlyDataClient(caller: caller).nftables()
        XCTAssertEqual(tables.first?.name, "fw4")
        XCTAssertEqual(caller.execLog.first?.params, ["--terse", "--json", "list", "ruleset"])
    }

    func testNeighborsMergeBothFamiliesViaGrantedPath() async throws {
        let caller = ScriptedCaller()
        caller.handler = { object, method, parameters in
            guard object == "file", method == "exec" else { throw OpenWrtKitError.unsupported("n/a") }
            let params = (parameters["params"]?.arrayValue ?? []).compactMap(\.stringValue)
            if parameters["command"]?.stringValue == "/sbin/ip", params == ["-4", "neigh", "show"] {
                return self.execResult("192.168.31.5 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n")
            }
            if parameters["command"]?.stringValue == "/sbin/ip", params == ["-6", "neigh", "show"] {
                return self.execResult("fe80::1 dev eth0 lladdr 11:22:33:44:55:66 STALE\n")
            }
            throw OpenWrtKitError.permissionDenied
        }
        let neighbors = try await ReadOnlyDataClient(caller: caller).neighbors()
        XCTAssertEqual(neighbors.map(\.address), ["192.168.31.5", "fe80::1"])
        XCTAssertTrue(caller.execLog.allSatisfy { $0.command == "/sbin/ip" })
    }

    func testKernelLogUsesGrantedRawForm() async throws {
        let caller = ScriptedCaller()
        caller.handler = { object, method, parameters in
            guard object == "file", method == "exec" else { throw OpenWrtKitError.unsupported("n/a") }
            let params = (parameters["params"]?.arrayValue ?? []).compactMap(\.stringValue)
            if parameters["command"]?.stringValue == "/bin/dmesg", params == ["-r"] {
                return self.execResult("<5>[    0.000000] Linux version 6.18\n<6>[    0.500000] pci ok\n")
            }
            throw OpenWrtKitError.permissionDenied
        }
        let entries = try await ReadOnlyDataClient(caller: caller).kernelLog()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].priority, 5)
        XCTAssertTrue(entries[0].message.hasPrefix("[    0.000000]"))
        XCTAssertEqual(entries[1].priority, 6)
    }

    func testSystemLogFallsBackToSyslogWrapper() async throws {
        let caller = ScriptedCaller()
        caller.handler = { object, method, parameters in
            if object == "log" { throw OpenWrtKitError.permissionDenied }
            guard object == "file", method == "exec",
                  parameters["command"]?.stringValue == "/usr/libexec/syslog-wrapper" else {
                throw OpenWrtKitError.unsupported("n/a")
            }
            return self.execResult("""
            Fri Nov 20 23:07:00 2026 daemon.info dnsmasq[1]: using only locally-known addresses
            Fri Nov 20 23:08:00 2026 user.notice netifd: Interface 'lan' is now up

            """)
        }
        let entries = try await ReadOnlyDataClient(caller: caller).systemLog()
        XCTAssertEqual(entries.count, 2)
        // Newest first, matching the ubus log read ordering.
        XCTAssertEqual(entries[0].source, "netifd")
        XCTAssertEqual(entries[0].priority, 5)
        XCTAssertEqual(entries[0].message, "Interface 'lan' is now up")
        XCTAssertEqual(entries[1].source, "dnsmasq")
        XCTAssertEqual(entries[1].priority, 6)
        XCTAssertNotNil(entries[1].timestamp)
    }

    func testDeviceTrafficFallsBackToNetworkDevices() async throws {
        let caller = ScriptedCaller()
        caller.handler = { object, _, _ in
            switch object {
            case "network.device": throw OpenWrtKitError.permissionDenied
            case "luci-rpc":
                return .object(["eth0": .object(["stats": .object([
                    "rx_bytes": .number(100), "tx_bytes": .number(200)])])])
            default: throw OpenWrtKitError.unsupported("n/a")
            }
        }
        let traffic = try await ReadOnlyDataClient(caller: caller).deviceTraffic()
        XCTAssertEqual(traffic, [DeviceTraffic(device: "eth0", rxBytes: 100, txBytes: 200)])
    }

    // MARK: Accept-Language on every LuCI HTTP request

    private final class HeaderStub: URLProtocol {
        static var acceptLanguages: [String: String] = [:]
        static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let client else { return }
            let url = request.url?.absoluteString ?? ""
            Self.lock.lock()
            Self.acceptLanguages[url] = request.value(forHTTPHeaderField: "Accept-Language")
            Self.lock.unlock()
            func respond(status: Int, headers: [String: String]?, body: Data) {
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1", headerFields: headers)!
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: body)
                client.urlProtocolDidFinishLoading(self)
            }
            if url.contains("translations") {
                respond(status: 200, headers: nil, body: Data(#"window.TR={"34f9da4c":"防火墙",};"#.utf8))
            } else if url.contains("admin/menu") {
                respond(status: 200, headers: nil, body: Data("{}".utf8))
            } else if url.contains("cgi-exec") {
                respond(status: 200, headers: nil, body: Data("[]".utf8))
            } else if url.contains("cgi-bin/luci") {
                respond(status: 302,
                        headers: ["Set-Cookie": "sysauth_http=\(String(repeating: "a", count: 32)); Path=/"],
                        body: Data())
            } else {
                respond(status: 200, headers: nil, body: Data("{}".utf8))
            }
        }
        override func stopLoading() {}
    }

    func testLuciRequestsCarryAcceptLanguage() async throws {
        HeaderStub.acceptLanguages = [:]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderStub.self]
        let address = try URLNormalizer.normalize("192.168.31.167")
        let client = UbusClient(address: address,
                                session: URLSession(configuration: configuration),
                                preferredLanguages: ["zh-Hans-CN"])
        let cookie = try await client.luciLogin(username: "root", password: "secret")
        _ = try await client.menu(cookie: cookie)
        let translations = try await client.translations(cookie: cookie, language: "zh-cn")
        XCTAssertTrue(translations.contains("防火墙"))
        let session = UbusSession(token: String(repeating: "c", count: 32), expiresIn: 3600)
        _ = try await client.installedPackages(session: session)
        XCTAssertEqual(HeaderStub.acceptLanguages.count, 4)
        for (url, header) in HeaderStub.acceptLanguages {
            XCTAssertEqual(header, "zh-Hans-CN", "missing Accept-Language on \(url)")
        }
        XCTAssertTrue(HeaderStub.acceptLanguages.keys.contains { $0.hasSuffix("/admin/translations/zh-cn") })
    }
}
