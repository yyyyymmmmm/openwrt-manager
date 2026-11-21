import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

/// Regression tests for the 2026-11-21 real-device discovery failure: the
/// app held a valid ubus session, yet LuCI treated it as anonymous (a bare
/// ubus login never writes the session token LuCI's dispatcher checks), so
/// the menu came back stripped — services 1/14, status 0/11, network 1/13 —
/// and the stripped snapshot was cached as a successful discovery.
///
/// The two menu fixtures are real responses captured from the bypass
/// router (192.168.31.167): the anonymous-grade menu a full-ACL ubus
/// session received, and the complete menu after a proper LuCI login
/// (7/58 vs 52/58 second-level nodes satisfied).
final class MenuSessionHotfixTests: XCTestCase {

    // MARK: Fixture helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private func fixtureMenus(_ name: String) throws -> [RouterMenuEntry] {
        let value = try JSONDecoder().decode(JSONValue.self, from: fixtureData(name))
        return try InventoryParser.menus(value)
    }

    private func groupChildren(_ menus: [RouterMenuEntry], _ group: String) -> [RouterMenuEntry] {
        menus.first { $0.id == "admin/\(group)" }?.children ?? []
    }

    // MARK: The two captured menus

    func testFullMenuParsesToCompleteGroups() throws {
        let menus = try fixtureMenus("menu-192.168.31.167-full")
        XCTAssertEqual(groupChildren(menus, "services").count, 14)
        XCTAssertEqual(groupChildren(menus, "network").count, 10)
        XCTAssertEqual(groupChildren(menus, "system").count, 15)
        // 8 at parser level: the routesj alias is among them and is only
        // dropped later by DiscoveryRules (snapshot level: 7, asserted in
        // testFullMenuYieldsCompletePages via the visible-path count).
        XCTAssertEqual(groupChildren(menus, "status").count, 8)
        XCTAssertFalse(MenuQuality.isAnonymousGrade(menus))
    }

    func testAnonymousMenuIsRecognizedAsAnonymousGrade() throws {
        let menus = try fixtureMenus("menu-192.168.31.167-anonymous")
        // The fingerprint the user screenshotted: one service left,
        // an empty status group.
        XCTAssertEqual(groupChildren(menus, "services").count, 1)
        XCTAssertEqual(groupChildren(menus, "status").count, 0)
        XCTAssertTrue(MenuQuality.isAnonymousGrade(menus))
    }

    // MARK: Full pipeline: snapshot and generated pages

    private func collected(from menus: [RouterMenuEntry]) -> CollectedRouterSnapshot {
        let all = menus.flatMap { [$0] + $0.descendants }
        var entries: [String: CollectedRouterSnapshot.MenuEntryInfo] = [:]
        for entry in all {
            entries[entry.id] = CollectedRouterSnapshot.MenuEntryInfo(title: entry.title, order: entry.order)
        }
        return CollectedRouterSnapshot(
            device: .init(id: "test", address: "192.168.31.167"),
            collectedAt: "2026-11-21T00:00:00.000Z",
            board: .init(hostname: "bypass"),
            menuPaths: all.map(\.id),
            menuTree: entries,
            wireless: .init(present: false))
    }

    func testFullMenuYieldsCompletePages() throws {
        let snapshot = CapabilitySnapshot(collected: collected(from: try fixtureMenus("menu-192.168.31.167-full")))
        XCTAssertTrue(snapshot.hasSubstantiveMenu)
        XCTAssertEqual(snapshot.visibleMenuPaths.filter { $0.split(separator: "/").count == 3 }.count, 46)
        XCTAssertEqual(snapshot.services.count, 14)
        let tabs = PageRegistry.tabs(for: snapshot)
        func pages(_ tab: AppTabID) -> Int { tabs.first { $0.tab == tab }?.pages.count ?? -1 }
        XCTAssertEqual(pages(.services), 14)
        XCTAssertEqual(pages(.network), 10)
        // 13 menu-driven system pages plus the app's native terminal and
        // file manager (their LuCI counterparts stay excluded).
        XCTAssertEqual(pages(.system), 15)
        XCTAssertEqual(pages(.overview), 6)
    }

    func testAnonymousMenuSnapshotIsNotSubstantive() throws {
        let snapshot = CapabilitySnapshot(collected: collected(from: try fixtureMenus("menu-192.168.31.167-anonymous")))
        XCTAssertFalse(snapshot.hasSubstantiveMenu)
    }

    // MARK: opkg stanza packages (main router's real output shape)

    func testOpkgStanzaParsing() throws {
        // Verbatim shape captured from the main router's
        // package-manager-call (opkg firmware answers stanza text, not
        // the JSON array apk firmware returns).
        let text = """
        Package: iwinfo
        Version: 2024.10.20~b94f066e-r1
        Depends: libc, libiwinfo20230701
        Status: install ok installed
        Architecture: aarch64_cortex-a53

        Package: libopenssl3
        ABIVersion: 3
        Version: 3.0.22-r1
        Depends: libc
        Provides: libopenssl
        Status: install ok installed

        """
        let packages = try InventoryParser.opkgStanzas(text)
        XCTAssertEqual(packages.map(\.name), ["iwinfo", "libopenssl3"])
        XCTAssertEqual(packages.first?.version, "2024.10.20~b94f066e-r1")
        XCTAssertEqual(packages.first?.dependencies, ["libc", "libiwinfo20230701"])
    }

    // MARK: LuCI login cookie flow + discovery self-healing

    private final class HotfixStub: URLProtocol {
        static var anonymousMenu: Data = Data()
        static var fullMenu: Data = Data()
        static var alwaysAnonymous = false
        static var luciLoginCount = 0
        static var ubusLoginCount = 0
        static var lastMenuCookie: String?
        static let lock = NSLock()

        static func reset() {
            lock.lock()
            luciLoginCount = 0; ubusLoginCount = 0; lastMenuCookie = nil; alwaysAnonymous = false
            lock.unlock()
        }

        static var firstCookie: String { String(repeating: "a", count: 32) }
        static var secondCookie: String { String(repeating: "b", count: 32) }

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
            if url.contains("admin/menu") {
                Self.lock.lock()
                Self.lastMenuCookie = request.value(forHTTPHeaderField: "Cookie")
                let cookie = Self.lastMenuCookie ?? ""
                let count = Self.luciLoginCount
                Self.lock.unlock()
                let full = !Self.alwaysAnonymous && count >= 2 && cookie.contains(Self.secondCookie)
                respond(status: 200, headers: ["Content-Type": "application/json"],
                        body: full ? Self.fullMenu : Self.anonymousMenu)
                return
            }
            if url.contains("cgi-bin/luci") {
                Self.lock.lock(); Self.luciLoginCount += 1; let count = Self.luciLoginCount; Self.lock.unlock()
                let cookie = count >= 2 ? Self.secondCookie : Self.firstCookie
                respond(status: 302,
                        headers: ["Set-Cookie": "sysauth_http=\(cookie); Path=/; HttpOnly"],
                        body: Data())
                return
            }
            if url.contains("cgi-exec") {
                respond(status: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8))
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
                Self.lock.lock(); Self.ubusLoginCount += 1; Self.lock.unlock()
                result = [0, ["ubus_rpc_session": String(repeating: "c", count: 32), "expires": 3600]]
            case ("system", "board"):
                result = [0, ["hostname": "bypass", "model": "VM"]]
            case ("network.interface", "dump"):
                result = [0, ["interface": [Any]()]]
            case ("luci-rpc", "getWirelessDevices"):
                result = [0, [String: Any]()]
            case ("service", "list"):
                result = [0, [String: Any]()]
            case ("rc", "list"):
                result = [0, ["cron": ["start": 50, "enabled": true, "running": true]]]
            case ("file", "list"):
                result = [0, ["entries": [Any]()]]
            default:
                result = [0, [String: Any]()]
            }
            let payload = ["jsonrpc": "2.0", "id": id, "result": result] as [String: Any]
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

    private struct StaticCredentials: SessionCredentialProvider {
        func routerCredentials() async -> RouterCredentials? {
            RouterCredentials(username: "root", password: "secret")
        }
    }

    private func makeDiscovery() throws -> RouterDiscovery {
        HotfixStub.reset()
        HotfixStub.anonymousMenu = try fixtureData("menu-192.168.31.167-anonymous")
        HotfixStub.fullMenu = try fixtureData("menu-192.168.31.167-full")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HotfixStub.self]
        let address = try URLNormalizer.normalize("192.168.31.167")
        let client = UbusClient(address: address, session: URLSession(configuration: configuration))
        let manager = SessionManager(client: client, credentialProvider: StaticCredentials())
        return RouterDiscovery(reader: RouterReader(caller: manager))
    }

    func testMenuUsesLuciLoginCookieNotUbusToken() async throws {
        let discovery = try makeDiscovery()
        _ = await discovery.discover(routerID: "r", address: "192.168.31.167")
        // The menu request must carry the cookie issued by LuCI's own
        // login — never the ubus session token.
        XCTAssertEqual(HotfixStub.lastMenuCookie, "sysauth_http=\(HotfixStub.secondCookie)")
    }

    func testDiscoverySelfHealsAnonymousMenu() async throws {
        let discovery = try makeDiscovery()
        let snapshot = await discovery.discover(routerID: "r", address: "192.168.31.167")
        XCTAssertEqual(HotfixStub.luciLoginCount, 2, "anonymous menu must trigger one re-login and re-haul")
        XCTAssertTrue(snapshot.hasSubstantiveMenu)
        XCTAssertEqual(snapshot.services.count, 14)
        let tabs = PageRegistry.tabs(for: snapshot)
        XCTAssertEqual(tabs.first { $0.tab == .services }?.pages.count, 14)
    }

    func testDiscoveryReportsFailureWhenMenuStaysAnonymous() async throws {
        let discovery = try makeDiscovery()
        HotfixStub.alwaysAnonymous = true
        let result = await discovery.discoverWithCollected(routerID: "r", address: "192.168.31.167")
        XCTAssertFalse(result.snapshot.hasSubstantiveMenu)
        XCTAssertTrue(result.snapshot.warnings.contains { $0.contains("菜单权限") },
                      "a still-anonymous menu must surface as a loud warning, got: \(result.snapshot.warnings)")
    }
}
