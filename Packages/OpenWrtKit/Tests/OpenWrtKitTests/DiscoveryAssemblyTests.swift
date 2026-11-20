import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

/// Feeds RouterDiscovery the raw ubus/LuCI responses a real router would
/// return — re-synthesized from the two verified collected snapshots — over
/// a stubbed URLProtocol transport, and asserts the assembled
/// CapabilitySnapshot matches the phase-0 alignment conclusions. This is
/// the live assembly path (inventory + raw reads + assemble + rules), not
/// the collected-form shortcut the older tests use.
final class DiscoveryAssemblyTests: XCTestCase {

    // MARK: Stub transport

    private final class StubProtocol: URLProtocol {
        static var board: [String: Any] = [:]
        static var interfaces: [String: Any] = [:]
        static var wireless: [String: Any] = [:]
        static var services: [String: Any] = [:]
        static var initList: [String: Any] = [:]
        static var menu: [String: Any] = [:]
        static var packages: [[String: Any]] = []
        static var requestedCalls: [(String, String)] = []
        static let lock = NSLock()

        static func reset() {
            lock.lock()
            board = [:]; interfaces = [:]; wireless = [:]; services = [:]
            initList = [:]; menu = [:]; packages = []; requestedCalls = []
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let client else { return }
            let url = request.url?.absoluteString ?? ""
            let payload: Any
            if url.contains("admin/menu") {
                payload = Self.menu
            } else if url.contains("cgi-exec") {
                payload = Self.packages
            } else {
                let body = Self.bodyData(from: request)
                let parsed = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let id = (parsed?["id"] as? NSNumber)?.intValue ?? 1
                let params = parsed?["params"] as? [Any]
                let object = (params?.count ?? 0) > 1 ? params?[1] as? String : nil
                let method = (params?.count ?? 0) > 2 ? params?[2] as? String : nil
                let result: [Any]
                switch (object, method) {
                case ("session", "login"):
                    result = [0, ["ubus_rpc_session": String(repeating: "b", count: 32), "expires": 3600]]
                case ("system", "board"):
                    result = [0, Self.board]
                case ("network.interface", "dump"):
                    result = [0, Self.interfaces]
                case ("network.wireless", "status"):
                    result = [0, Self.wireless]
                case ("service", "list"):
                    result = [0, Self.services]
                case ("luci", "getInitList"):
                    result = [0, Self.initList]
                case ("file", "list"):
                    result = [0, ["entries": [Any]()]]
                default:
                    result = [4, [String: Any]()]
                }
                if let object, let method, object != "session" {
                    Self.lock.lock(); Self.requestedCalls.append((object, method)); Self.lock.unlock()
                }
                payload = ["jsonrpc": "2.0", "id": id, "result": result] as [String: Any]
            }
            let data = try! JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
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

    // MARK: Fixture loading and raw-response synthesis

    private func collected(_ name: String) throws -> CollectedRouterSnapshot {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
    }

    private func installPayloads(from collected: CollectedRouterSnapshot, unsatisfied: Set<String> = []) {
        StubProtocol.reset()
        // system board
        var release: [String: Any] = [:]
        if let r = collected.board.release {
            release = ["distribution": r.distribution as Any, "version": r.version as Any,
                       "revision": r.revision as Any, "target": r.target as Any,
                       "description": r.description as Any].compactMapValues { $0 }
        }
        StubProtocol.board = ["hostname": collected.board.hostname as Any,
                              "model": collected.board.model as Any,
                              "board_name": collected.board.boardName as Any,
                              "kernel": collected.board.kernel as Any,
                              "system": collected.board.system as Any,
                              "rootfs_type": collected.board.rootfsType as Any,
                              "release": release].compactMapValues { $0 }
        // network.interface dump
        StubProtocol.interfaces = ["interface": collected.interfaces.map { iface -> [String: Any] in
            var item: [String: Any] = ["interface": iface.name]
            item["up"] = iface.up as Any
            item["available"] = iface.available as Any
            item["pending"] = iface.pending as Any
            item["proto"] = iface.proto as Any
            item["device"] = iface.device as Any
            item["l3_device"] = iface.l3Device as Any
            item["ipv4-address"] = iface.ipv4.map { ["address": $0] }
            item["ipv6-address"] = iface.ipv6.map { ["address": $0] }
            item["route"] = iface.routes.map { route -> [String: Any] in
                var entry: [String: Any] = ["target": route.target]
                entry["mask"] = route.mask as Any
                entry["nexthop"] = route.nexthop as Any
                entry["source"] = route.source as Any
                return entry.compactMapValues { $0 }
            }
            item["dns-server"] = iface.dns
            return item.compactMapValues { $0 }
        }]
        // network.wireless status
        var wireless: [String: Any] = [:]
        for radio in collected.wireless.radios {
            var config: [String: Any] = [:]
            config["band"] = radio.band as Any
            config["disabled"] = radio.disabled as Any
            wireless[radio.name] = ["up": radio.up as Any, "config": config.compactMapValues { $0 }]
                .compactMapValues { $0 }
        }
        StubProtocol.wireless = wireless
        // service list (procd shape)
        var services: [String: Any] = [:]
        for service in collected.services {
            if let running = service.running {
                services[service.name] = ["instances": ["instance1": ["running": running]]]
            } else {
                services[service.name] = [String: Any]()
            }
        }
        StubProtocol.services = services
        // luci getInitList
        var initList: [String: Any] = [:]
        for service in collected.services {
            var entry: [String: Any] = [:]
            entry["enabled"] = service.enabled as Any
            initList[service.name] = entry.compactMapValues { $0 }
        }
        StubProtocol.initList = initList
        // LuCI menu tree (nested children form the parser consumes)
        StubProtocol.menu = ["children": ["admin": Self.menuNode(path: "admin", collected: collected, unsatisfied: unsatisfied)]]
        // package-manager list-installed
        StubProtocol.packages = collected.installedPackages.map { ["name": $0, "version": "1"] }
    }

    private static func menuNode(path: String, collected: CollectedRouterSnapshot, unsatisfied: Set<String>) -> [String: Any] {
        let info = collected.menuTree[path]
        var node: [String: Any] = ["title": (info?.title ?? nil) ?? path.split(separator: "/").last.map(String.init) ?? path,
                                   "order": (info?.order ?? nil) ?? 100,
                                   "satisfied": !unsatisfied.contains(path)]
        var children: [String: Any] = [:]
        for childPath in collected.menuPaths where childPath.hasPrefix(path + "/") {
            let rest = childPath.dropFirst(path.count + 1)
            guard !rest.contains("/") else { continue }
            children[String(rest)] = menuNode(path: childPath, collected: collected, unsatisfied: unsatisfied)
        }
        if !children.isEmpty { node["children"] = children }
        return node
    }

    private func discover(_ name: String, unsatisfied: Set<String> = []) async throws -> CapabilitySnapshot {
        let collected = try collected(name)
        installPayloads(from: collected, unsatisfied: unsatisfied)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let address = try URLNormalizer.normalize(collected.device.address)
        let client = UbusClient(address: address, session: URLSession(configuration: configuration))
        let manager = SessionManager(client: client, credentialProvider: StaticCredentials())
        let discovery = RouterDiscovery(reader: RouterReader(caller: manager))
        return await discovery.discover(routerID: collected.device.id,
                                        address: collected.device.address,
                                        role: collected.device.role)
    }

    private func secondLevelCount(_ snapshot: CapabilitySnapshot) -> Int {
        snapshot.visibleMenuPaths.filter { $0.split(separator: "/").count == 3 }.count
    }

    // MARK: Bypass router (.167): 47 nodes, no wireless, upstream br-lan

    func testAssembledBypassMatchesAlignmentConclusions() async throws {
        // LuCI's own menu endpoint reports switch/leds as unsatisfied on
        // this VM (their menu.d depends point at hardware it lacks), and
        // the parser drops unsatisfied nodes — that is the documented
        // depends gate for these two paths.
        let snapshot = try await discover("snapshot-192.168.31.167-2026-11-20",
                                          unsatisfied: ["admin/network/switch", "admin/system/leds"])
        XCTAssertEqual(secondLevelCount(snapshot), 47)
        XCTAssertFalse(snapshot.wireless.present)
        XCTAssertNil(snapshot.menuNode("admin/network/wireless"))
        XCTAssertEqual(snapshot.upstream?.interfaceName, "lan")
        XCTAssertEqual(snapshot.upstream?.l3Device, "br-lan")
        XCTAssertEqual(snapshot.services.count, 14)
        let openbox = snapshot.services.first { $0.key == "openbox" }
        XCTAssertEqual(openbox?.source, .menuAndInit)
        XCTAssertEqual(openbox?.running, true)
        XCTAssertNotNil(snapshot.menuNode("admin/network/dhcp"))
        XCTAssertNotNil(snapshot.menuNode("admin/network/dns"))
        // The assembly really went through the live read paths.
        let calls = StubProtocol.requestedCalls
        XCTAssertTrue(calls.contains { $0 == ("system", "board") })
        XCTAssertTrue(calls.contains { $0 == ("network.interface", "dump") })
        XCTAssertTrue(calls.contains { $0 == ("service", "list") })
    }

    // MARK: Main router (.1): 24 nodes, wireless present, upstream wan

    func testAssembledMainMatchesAlignmentConclusions() async throws {
        let snapshot = try await discover("snapshot-192.168.31.1-2026-11-20")
        XCTAssertEqual(secondLevelCount(snapshot), 24)
        XCTAssertTrue(snapshot.wireless.present)
        XCTAssertEqual(snapshot.wireless.radios.count, 2)
        XCTAssertNotNil(snapshot.menuNode("admin/network/wireless"))
        XCTAssertEqual(snapshot.upstream?.interfaceName, "wan")
        XCTAssertEqual(snapshot.menuNode("admin/network/dhcp")?.title, "DHCP and DNS")
        XCTAssertNil(snapshot.menuNode("admin/network/dns"))
        XCTAssertFalse(snapshot.services.isEmpty)
        XCTAssertTrue(snapshot.services.allSatisfy { $0.source == .initFallback })
    }

    /// The assembled snapshot and the collected-form snapshot must agree on
    /// the navigation-relevant fields (the collected form is what the app
    /// caches for offline rebuilds).
    func testAssembledAndCollectedFormsAgreeOnNavigation() async throws {
        for name in ["snapshot-192.168.31.167-2026-11-20", "snapshot-192.168.31.1-2026-11-20"] {
            let assembled = try await discover(name)
            let direct = CapabilitySnapshot(collected: try collected(name))
            XCTAssertEqual(assembled.services.map(\.key), direct.services.map(\.key), name)
            XCTAssertEqual(assembled.upstream?.interfaceName, direct.upstream?.interfaceName, name)
            XCTAssertEqual(assembled.wireless.present, direct.wireless.present, name)
            let assembledNodes = Set(assembled.visibleMenuPaths.filter { $0.split(separator: "/").count == 3 })
            let directNodes = Set(direct.visibleMenuPaths.filter { $0.split(separator: "/").count == 3 })
            // The live path additionally drops switch/leds on the bypass
            // router via LuCI's satisfied flag (see bypass test); the
            // collected form keeps them. Every other node must agree.
            XCTAssertTrue(assembledNodes.isSubset(of: directNodes), name)
            XCTAssertTrue(directNodes.subtracting(assembledNodes)
                .isSubset(of: ["admin/network/switch", "admin/system/leds"]), name)
        }
    }
}
