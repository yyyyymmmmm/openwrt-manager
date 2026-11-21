import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

/// Hotfix round 4 (2026-11-21): build #8 field failure — the main
/// router (.1) rendered Chinese titles, the bypass router (.167)
/// stayed English. Root cause, proven end-to-end against both
/// routers' REAL responses captured live over the app's own HTTP
/// chain (ubus login → uci get → LuCI login → translations fetch,
/// NAS, 2026-11-21; the fresh .167 payload is byte-identical to the
/// round-3 fixture):
///
///   - Every network step succeeds on .167 with an app session:
///     uci get luci returns code 0 (the config IS readable; ACL is
///     not the breakpoint), the LuCI cookie is issued, and the zh-cn
///     catalog parses into 4793 entries that translate titles.
///   - The negotiator was the breakpoint. It only built candidates
///     from the region code present in the preferred tag, so with
///     luci.main.lang = "auto" (.167) the tag shapes "zh-Hans" and
///     "zh-Hans-US" matched nothing and discovery degraded to
///     English — while .1's fixed lang=zh_cn masked the same miss
///     through the configured-language step for every tag shape.
///
/// These tests pin the chain with the captured payloads themselves —
/// the full JSON-RPC uci envelopes (Fixtures/uci-luci-*.json), the
/// real catalogs, the real collected snapshots — never hand-built
/// stand-ins for the device side of the chain.
final class HotfixRound4Tests: XCTestCase {

    // MARK: Fixtures

    private func fixtureURL(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).\(ext)")
    }

    /// The config exactly as the app receives it: the JSON-RPC
    /// envelope decoded with the kit's own types, result[1] out.
    private func realConfig(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: fixtureURL(name, "json"))
        let response = try JSONDecoder().decode(UbusResponse.self, from: data)
        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.first?.intValue, 0)
        return result[1]
    }

    private func negotiate(_ config: JSONValue, _ prefs: [String]) -> String? {
        LuciLanguageNegotiator.effectiveLanguage(luciConfig: config, preferredLanguages: prefs)
    }

    // MARK: Negotiation against the real configs

    func testRealBypassConfigMatchesEverySimplifiedChineseTagShape() throws {
        // .167 runs luci.main.lang = "auto": step 1 or nothing.
        let config = try realConfig("uci-luci-192.168.31.167")
        // The shapes iOS can hand the app for a Simplified-Chinese
        // system, depending on the region setting — the middle three
        // matched nothing before this round and left the router in
        // English.
        for prefs in [["zh-Hans-CN"], ["zh-CN"], ["zh-Hans"], ["zh-Hans-US"],
                      ["zh-Hans-HK"], ["zh-Hans-SG"], ["zh"]] {
            XCTAssertEqual(negotiate(config, prefs), "zh-cn", "prefs \(prefs)")
        }
        XCTAssertNil(negotiate(config, ["en-US"]))
        XCTAssertNil(negotiate(config, ["en"]))
    }

    func testRealMainConfigStillResolvesThroughConfiguredLanguage() throws {
        // .1 runs lang = zh_cn fixed: step 2 is the control path that
        // kept it Chinese all along — it must not move.
        let config = try realConfig("uci-luci-192.168.31.1")
        XCTAssertEqual(negotiate(config, ["zh-Hans"]), "zh-cn")
        XCTAssertEqual(negotiate(config, ["zh-Hans-US"]), "zh-cn")
        XCTAssertEqual(negotiate(config, ["fr-FR"]), "zh-cn")
        XCTAssertNil(negotiate(config, ["en-US"]))
    }

    func testScriptDefaultChoosesBetweenTwoRegisteredChineseCatalogs() throws {
        // A router shipping both Chinese catalogs: the script of the
        // preference — not registration order — picks the catalog.
        // (Composition coverage: the device-side shape is the real
        // one, only the language registry is widened.)
        let json = """
        {"values":{
          "main":{".type":"core","lang":"auto"},
          "languages":{".type":"internal","zh_cn":"x","zh_tw":"y"}
        }}
        """
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(negotiate(config, ["zh-Hant-TW"]), "zh-tw")
        XCTAssertEqual(negotiate(config, ["zh-Hant-HK"]), "zh-tw")
        XCTAssertEqual(negotiate(config, ["zh-Hans-HK"]), "zh-cn")
        XCTAssertEqual(negotiate(config, ["zh-Hans"]), "zh-cn")
        XCTAssertEqual(SnapshotLanguage.expectedTag(preferredLanguages: ["zh-Hant-TW"]), "zh-tw")
        XCTAssertEqual(SnapshotLanguage.expectedTag(preferredLanguages: ["zh-Hans-US"]), "zh-cn")
    }

    // MARK: The full chain on real payloads

    private func translatedTitles(snapshotName: String, configName: String,
                                  catalogName: String, prefs: [String])
        throws -> (language: String, titles: [String]) {
        let language = try XCTUnwrap(negotiate(try realConfig(configName), prefs))
        let payload = try String(contentsOf: fixtureURL(catalogName, "txt"), encoding: .utf8)
        let catalog = try XCTUnwrap(LuciTranslationCatalog.parse(payload))
        let localization = LuciLocalization(language: language, catalog: catalog)
        let data = try Data(contentsOf: fixtureURL(snapshotName, "json"))
        let collected = try JSONDecoder().decode(CollectedRouterSnapshot.self, from: data)
        let snapshot = CapabilitySnapshot(collected: collected)
        var titles: [String] = []
        for group in snapshot.menuTree {
            for node in group.children { titles.append(localization.translate(node.title)) }
        }
        return (language, titles)
    }

    private func chineseCount(_ titles: [String]) -> Int {
        titles.filter { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) } }.count
    }

    func testRealChainBypassRouterYieldsChineseTitles() throws {
        // The field-failing combination itself: auto-lang router,
        // region-less Simplified tag, real payloads at every step.
        let chain = try translatedTitles(
            snapshotName: "snapshot-192.168.31.167-2026-11-20",
            configName: "uci-luci-192.168.31.167",
            catalogName: "translations-192.168.31.167",
            prefs: ["zh-Hans"])
        XCTAssertEqual(chain.language, "zh-cn")
        XCTAssertEqual(chain.titles.count, 49)
        XCTAssertGreaterThanOrEqual(chineseCount(chain.titles), 38,
                                    "titles: \(chain.titles)")
        for expected in ["防火墙", "接口", "软件包", "路由"] {
            XCTAssertTrue(chain.titles.contains(expected), "missing \(expected) in \(chain.titles)")
        }
    }

    func testRealChainMainRouterYieldsChineseTitles() throws {
        let chain = try translatedTitles(
            snapshotName: "snapshot-192.168.31.1-2026-11-20",
            configName: "uci-luci-192.168.31.1",
            catalogName: "translations-192.168.31.1",
            prefs: ["zh-Hans"])
        XCTAssertEqual(chain.language, "zh-cn")
        XCTAssertEqual(chain.titles.count, 24)
        XCTAssertGreaterThanOrEqual(chineseCount(chain.titles), 22,
                                    "titles: \(chain.titles)")
        XCTAssertTrue(chain.titles.contains("防火墙"), "titles: \(chain.titles)")
        XCTAssertTrue(chain.titles.contains("接口"), "titles: \(chain.titles)")
    }

    // MARK: A degraded localization must not be cached for the session

    func testDegradedLocalizationIsNotCachedAndRetries() async throws {
        Round4Stub.reset()
        // The stub serves the REAL bypass-router config and catalog.
        let raw = try Data(contentsOf: fixtureURL("uci-luci-192.168.31.167", "json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [Any])
        Round4Stub.configObject = try XCTUnwrap(result[1] as? [String: Any])
        Round4Stub.catalogPayload = try Data(contentsOf: fixtureURL("translations-192.168.31.167", "txt"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Round4Stub.self]
        let urlSession = URLSession(configuration: configuration)
        let address = try URLNormalizer.normalize("192.168.31.250")
        let client = UbusClient(address: address, session: urlSession,
                                preferredLanguages: ["zh-Hans"])
        let manager = SessionManager(client: client, credentialProvider: Round4Credentials())

        // While uci reads fail, localization degrades to the source
        // context for this call...
        let degraded = try await manager.localization()
        XCTAssertEqual(degraded.language, "source")
        XCTAssertNil(degraded.catalog)
        let attemptsAfterDegrade = Round4Stub.uciAttempts
        XCTAssertGreaterThan(attemptsAfterDegrade, 0)

        // ...but the degradation is not cached: once uci recovers,
        // the very next call negotiates for real, with the
        // region-less Simplified tag that failed in the field.
        Round4Stub.setUciFails(false)
        let healed = try await manager.localization()
        XCTAssertEqual(healed.language, "zh-cn")
        XCTAssertEqual(healed.catalog?.translate("Firewall"), "防火墙")
        let attemptsAfterHeal = Round4Stub.uciAttempts
        XCTAssertGreaterThan(attemptsAfterHeal, attemptsAfterDegrade)

        // And the healed context IS cached: no further uci traffic.
        _ = try await manager.localization()
        XCTAssertEqual(Round4Stub.uciAttempts, attemptsAfterHeal)
    }
}

private struct Round4Credentials: SessionCredentialProvider {
    func routerCredentials() async -> RouterCredentials? {
        RouterCredentials(username: "root", password: "x")
    }
}

/// Serves the three legs of the localization chain over stubbed
/// HTTP: ubus JSON-RPC (login + a scripted uci get), the LuCI web
/// login (302 + sysauth cookie), and the translations endpoint.
private final class Round4Stub: URLProtocol {
    static var uciFails = true
    static var uciAttempts = 0
    static var configObject: [String: Any] = [:]
    static var catalogPayload = Data()
    static let lock = NSLock()

    static func reset() {
        lock.lock()
        uciFails = true; uciAttempts = 0; configObject = [:]; catalogPayload = Data()
        lock.unlock()
    }

    static func setUciFails(_ value: Bool) {
        lock.lock(); uciFails = value; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let url = request.url?.absoluteString ?? ""
        func respond(status: Int, headers: [String: String]?, body: Data) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
        if url.contains("/translations/") {
            Self.lock.lock(); let payload = Self.catalogPayload; Self.lock.unlock()
            respond(status: 200, headers: ["Content-Type": "text/javascript"], body: payload)
            return
        }
        if url.contains("cgi-bin/luci") {
            respond(status: 302,
                    headers: ["Set-Cookie": "sysauth_http=\(String(repeating: "d", count: 32)); Path=/; HttpOnly"],
                    body: Data())
            return
        }
        // JSON-RPC (ubus) endpoint.
        let body = Self.bodyData(from: request)
        let parsed = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let id = (parsed?["id"] as? NSNumber)?.intValue ?? 1
        let params = parsed?["params"] as? [Any]
        let object = (params?.count ?? 0) > 1 ? params?[1] as? String : nil
        let method = (params?.count ?? 0) > 2 ? params?[2] as? String : nil
        let result: [Any]
        switch (object, method) {
        case ("session", "login"):
            result = [0, ["ubus_rpc_session": String(repeating: "e", count: 32), "expires": 3600]]
        case ("uci", "get"):
            Self.lock.lock()
            Self.uciAttempts += 1
            let fails = Self.uciFails, config = Self.configObject
            Self.lock.unlock()
            result = fails ? [6] : [0, config]
        default:
            result = [0, [String: Any]()]
        }
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        respond(status: 200, headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: payload))
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
