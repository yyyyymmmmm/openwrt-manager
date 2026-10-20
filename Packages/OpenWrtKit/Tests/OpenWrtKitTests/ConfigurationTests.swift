import XCTest
@testable import OpenWrtKit

final class ConfigurationTests: XCTestCase {
    private let original = RouterConfiguration(name: "system", sections: [.init(id: "main", type: "system", values: ["hostname": .string("OpenWrt")])])

    func testPlanChangesOnlyEditedFieldsAndNeverLeaksSecretInSummary() throws {
        var draft = original
        draft.sections[0].values["password"] = .string("do-not-log-this")
        let plan = try ConfigurationPlan(original: original, edited: draft)
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertFalse(plan.edits[0].summary.contains("do-not-log-this"))
        XCTAssertEqual(try ConfigurationPlan(original: original, edited: original).edits, [])
    }

    func testListsAndDeletionsRemainTyped() throws {
        var draft = original
        draft.sections[0].values["hostname"] = nil
        draft.sections[0].values["server"] = .array([.string("one"), .string("two")])
        let edits = try ConfigurationPlan(original: original, edited: draft).edits
        XCTAssertEqual(edits, [.removeOption(section: "main", option: "hostname"), .set(section: "main", option: "server", value: .array([.string("one"), .string("two")]))])
    }

    func testConfigurationPlanIncludesExplicitSectionOrderOnlyWhenNeeded() throws {
        let sections = [
            ConfigurationSection(id: "first", type: "queue", anonymous: true),
            ConfigurationSection(id: "second", type: "queue", anonymous: true)
        ]
        let original = RouterConfiguration(name: "sqm", sections: sections)
        let reordered = RouterConfiguration(name: "sqm", sections: Array(sections.reversed()))
        XCTAssertEqual(try ConfigurationPlan(original: original, edited: reordered).edits, [.order(["second", "first"])])
        XCTAssertEqual(try ConfigurationPlan(original: original, edited: original).edits, [])
    }

    func testConfigurationPlanOrdersNewAnonymousSectionsUsingDraftIdentifiers() throws {
        let original = RouterConfiguration(name: "sqm", sections: [
            ConfigurationSection(id: "existing", type: "queue", anonymous: true)
        ])
        let draft = RouterConfiguration(name: "sqm", sections: [
            ConfigurationSection(id: "new-local-id", type: "queue", anonymous: true),
            original.sections[0]
        ])
        XCTAssertEqual(try ConfigurationPlan(original: original, edited: draft).edits, [
            .add(ConfigurationSection(id: "new-local-id", type: "queue", anonymous: true)),
            .order(["new-local-id", "existing"])
        ])
    }

    func testConfigurationPlanOrdersRetainedSectionsAfterDeletion() throws {
        let original = RouterConfiguration(name: "sqm", sections: [
            ConfigurationSection(id: "first", type: "queue", anonymous: true),
            ConfigurationSection(id: "middle", type: "queue", anonymous: true),
            ConfigurationSection(id: "last", type: "queue", anonymous: true)
        ])
        let draft = RouterConfiguration(name: "sqm", sections: [original.sections[2], original.sections[0]])
        XCTAssertEqual(try ConfigurationPlan(original: original, edited: draft).edits, [
            .removeSection("middle"), .order(["last", "first"])
        ])
    }

    func testInvalidNamesAndUnsupportedValuesRefused() {
        var draft = original
        draft.sections[0].values["bad/field"] = .string("x")
        XCTAssertThrowsError(try ConfigurationPlan(original: original, edited: draft))
        draft = original; draft.sections[0].values["hostname"] = .number(1)
        XCTAssertThrowsError(try ConfigurationPlan(original: original, edited: draft))
        draft = original; draft.sections.append(draft.sections[0])
        XCTAssertThrowsError(try ConfigurationPlan(original: original, edited: draft))
    }

    func testDeniedAccessPerformsNoWrites() async throws {
        let fixture = RouterFixture(); fixture.denied = true
        let (configuration, _) = try fixture.clients()
        do { _ = try await configuration.apply(plan()); XCTFail("Expected ACL rejection") }
        catch { XCTAssertEqual(error as? OpenWrtKitError, .permissionDenied) }
        XCTAssertFalse(fixture.calls.contains { ["set", "add", "delete", "apply"].contains($0.method) })
    }

    func testExistingChangesAreNeverOverwritten() async throws {
        let fixture = RouterFixture(); fixture.existingChanges = true
        let (configuration, _) = try fixture.clients()
        do { _ = try await configuration.apply(plan()); XCTFail("Expected staged change rejection") }
        catch { XCTAssertEqual(error as? ConfigurationError, .existingChanges) }
        XCTAssertFalse(fixture.calls.contains { $0.method == "set" || $0.method == "revert" })
    }

    func testConcurrentModificationIsRefused() async throws {
        let fixture = RouterFixture(); fixture.hostname = "ChangedElsewhere"
        let (configuration, _) = try fixture.clients()
        do { _ = try await configuration.apply(plan()); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? ConfigurationError, .changedElsewhere) }
        XCTAssertFalse(fixture.calls.contains { $0.method == "set" })
    }

    func testApplyUsesRollbackAndExplicitConfirmation() async throws {
        let fixture = RouterFixture()
        let (configuration, _) = try fixture.clients()
        let pending = try await configuration.apply(plan())
        XCTAssertTrue(pending.acknowledged)
        let apply = try XCTUnwrap(fixture.calls.first { $0.method == "apply" })
        XCTAssertEqual(apply.parameters["rollback"], .bool(true))
        XCTAssertEqual(apply.parameters["timeout"], .number(90))
        XCTAssertFalse(fixture.calls.contains { $0.method == "confirm" })
        try await configuration.confirm()
        XCTAssertEqual(fixture.calls.suffix(2).map(\.method), ["board", "confirm"])
    }

    func testStagingFailureRevertsOnlyThisConfiguration() async throws {
        let fixture = RouterFixture(); fixture.failSet = true
        let (configuration, _) = try fixture.clients()
        do { _ = try await configuration.apply(plan()); XCTFail("Expected stage failure") } catch {}
        XCTAssertEqual(fixture.calls.last?.method, "revert")
        XCTAssertEqual(fixture.calls.last?.parameters["config"], .string("system"))
        XCTAssertFalse(fixture.calls.contains { $0.method == "apply" })
    }

    func testLostApplyResponseStaysPendingAndBlocksAnotherWrite() async throws {
        let fixture = RouterFixture(); fixture.loseApplyResponse = true
        let (configuration, _) = try fixture.clients()
        let pending = try await configuration.apply(plan())
        XCTAssertFalse(pending.acknowledged)
        do { _ = try await configuration.apply(plan()); XCTFail("Expected pending guard") }
        catch { XCTAssertEqual(error as? ConfigurationError, .busy) }
        try await configuration.rollback()
        XCTAssertEqual(fixture.calls.last?.method, "rollback")
    }

    func testFailedConfirmationDoesNotDiscardPendingTransaction() async throws {
        let fixture = RouterFixture(); fixture.failConfirm = true
        let (configuration, _) = try fixture.clients()
        _ = try await configuration.apply(plan())
        do { try await configuration.confirm(); XCTFail("Expected confirmation failure") } catch {}
        do { _ = try await configuration.apply(plan()); XCTFail("Expected pending guard") }
        catch { XCTAssertEqual(error as? ConfigurationError, .busy) }
        try await configuration.rollback()
    }

    func testServiceActionChecksMembershipAndPermissions() async throws {
        let fixture = RouterFixture()
        let (_, reader) = try fixture.clients()
        try await reader.serviceAction(name: "example", action: .restart)
        XCTAssertEqual(fixture.calls.last?.parameters["action"], .string("restart"))
        let count = fixture.calls.filter { $0.method == "setInitAction" }.count
        do { try await reader.serviceAction(name: "missing", action: .stop); XCTFail("Expected unknown service rejection") } catch {}
        XCTAssertEqual(fixture.calls.filter { $0.method == "setInitAction" }.count, count)
    }

    func testRecordResponsesUseActualResultKeys() async throws {
        let fixture = RouterFixture()
        let (_, reader) = try fixture.clients()
        let processes = try await reader.records(.processes)
        let logs = try await reader.records(.logs)
        XCTAssertEqual(processes.count, 1); XCTAssertEqual(logs.count, 1)
    }

    func testRoutingUsesSixFixedJSONCommandsAndAllRouteTables() async throws {
        let fixture = RouterFixture()
        let (_, reader) = try fixture.clients()
        let routing = try await reader.routing(interfaces: [.init(name: "lan", protocolName: "static", addresses: [], up: true, device: "br-lan")])
        XCTAssertEqual(routing.ipv4Routes.first?.destination, "default")
        XCTAssertEqual(routing.ipv6Routes.first?.destination, "fd00::/64")
        XCTAssertEqual(routing.ipv4Neighbors.first?.interface, "lan")
        XCTAssertEqual(routing.ipv6Neighbors.first?.state, "STALE")
        XCTAssertEqual(routing.rules4.value?.first?.priority, "100")
        XCTAssertEqual(routing.rules6.value?.first?.priority, "32766")
        XCTAssertTrue(routing.errors.isEmpty)
        XCTAssertEqual(fixture.calls.count, 6)
        XCTAssertTrue(fixture.calls.allSatisfy { $0.object == "file" && $0.method == "exec" && $0.parameters["command"] == .string("/sbin/ip") })
        let queries = Set(try fixture.calls.map { call in
            try XCTUnwrap(call.parameters["params"]?.arrayValue).compactMap(\.stringValue).joined(separator: " ")
        })
        XCTAssertEqual(queries, Set(["-4 -j route show table all", "-6 -j route show table all", "-4 -j neigh show", "-6 -j neigh show", "-4 -j rule show", "-6 -j rule show"]))
    }

    func testRoutingACLFailureDoesNotBecomeAnEmptyTable() async throws {
        let fixture = RouterFixture(); fixture.denyRoutes = true
        let (_, reader) = try fixture.clients()
        let routing = try await reader.routing(interfaces: [])
        XCTAssertEqual(routing.errors.count, 6)
        XCTAssertNil(routing.neighbors4.value)
        XCTAssertNil(routing.neighbors4.updatedAt)
        XCTAssertTrue(routing.errors.allSatisfy { $0.contains("权限不足") })
    }

    func testRoutingCommandAndMalformedFailuresArePropagated() async throws {
        let responses: [JSONValue] = [
            .object(["code": .number(1), "stdout": .string(""), "stderr": .string("ip failed")]),
            .object(["stdout": .string("")]),
            .object(["code": .number(0), "stdout": .string("invalid record")])
        ]
        for response in responses {
            let fixture = RouterFixture(); fixture.routeResponse = response
            let (_, reader) = try fixture.clients()
            let routing = try await reader.routing(interfaces: [])
            XCTAssertEqual(routing.errors.count, 6)
            XCTAssertNil(routing.routes4.value)
            XCTAssertNil(routing.neighbors6.updatedAt)
        }
    }

    func testRoutingTextFallbackDoesNotDropPolicyTables() async throws {
        let fixture = RouterFixture(); fixture.rejectJSON = true
        let (_, reader) = try fixture.clients()
        let routing = try await reader.routing(interfaces: [])
        XCTAssertTrue(routing.errors.isEmpty)
        XCTAssertEqual(routing.routes4.value?.first?.table, "100")
        XCTAssertEqual(routing.rules4.value?.first?.priority, "100")
        XCTAssertEqual(fixture.calls.count, 12)
    }

    func testOneFailedRoutingTableRetainsOnlyItsPreviousTimestamp() async throws {
        let fixture = RouterFixture()
        let (_, reader) = try fixture.clients()
        let old = try await reader.routing(interfaces: [])
        fixture.failedQuery = "-6 -j neigh show"
        let fresh = try await reader.routing(interfaces: [])
        XCTAssertEqual(fresh.errors.count, 1)
        XCTAssertNotNil(fresh.routes4.value)
        XCTAssertNil(fresh.neighbors6.value)
        let retained = fresh.retainingLastRead(old)
        XCTAssertEqual(retained.neighbors6.value, old.neighbors6.value)
        XCTAssertEqual(retained.neighbors6.updatedAt, old.neighbors6.updatedAt)
        XCTAssertNotNil(retained.neighbors6.error)
        XCTAssertEqual(retained.routes4.updatedAt, fresh.routes4.updatedAt)
    }

    private func plan() throws -> ConfigurationPlan {
        var edited = original; edited.sections[0].values["hostname"] = .string("NewName")
        return try ConfigurationPlan(original: original, edited: edited)
    }
}

private final class RouterFixture: @unchecked Sendable {
    struct Call { let object: String; let method: String; let parameters: [String: JSONValue] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    var denied = false
    var existingChanges = false
    var failSet = false
    var loseApplyResponse = false
    var failConfirm = false
    var hostname = "OpenWrt"
    var denyRoutes = false
    var routeResponse: JSONValue?
    var rejectJSON = false
    var failedQuery: String?

    func clients() throws -> (RouterConfigurationClient, RouterReader) {
        let host = UUID().uuidString.lowercased() + ".test"
        RouterProtocol.register(self, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterProtocol.self]
        let client = UbusClient(address: try URLNormalizer.normalize("http://" + host), session: URLSession(configuration: configuration))
        let session = UbusSession(token: String(repeating: "a", count: 32))
        return (RouterConfigurationClient(client: client, session: session), RouterReader(client: client, session: session))
    }

    func response(_ request: URLRequest) throws -> Data {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            data = result
        } else { throw URLError(.cannotDecodeContentData) }
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        let params = body["params"].arrayValue!
        let call = Call(object: params[1].stringValue!, method: params[2].stringValue!, parameters: params[3].objectValue!)
        lock.lock(); recorded.append(call); lock.unlock()
        if call.method == "apply" && loseApplyResponse { throw URLError(.networkConnectionLost) }
        var code = 0
        let result: JSONValue
        switch call.method {
        case "access": result = .object(["access": .bool(!denied)])
        case "changes": result = .object(["changes": .object(existingChanges ? ["network": .array([.string("staged")])] : [:])])
        case "get": result = .object(["values": .object(["main": .object([".type": .string("system"), ".index": .number(0), "hostname": .string(hostname)])])])
        case "set": code = failSet ? 8 : 0; result = .object([:])
        case "confirm": code = failConfirm ? 8 : 0; result = .object([:])
        case "getInitList": result = .object(["example": .object(["enabled": .bool(true)])])
        case "setInitAction": result = .object(["result": .bool(true)])
        case "getProcessList", "getMountPoints": result = .object(["result": .array([.object(["PID": .number(1)])])])
        case "read": result = .object(["log": .array([.object(["msg": .string("event")])])])
        case "exec":
            code = denyRoutes ? 6 : 0
            let query = call.parameters["params"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? ""
            let outputs = [
                "-4 -j route show table all": #"[{"dst":"default","gateway":"192.0.2.254","dev":"br-lan","table":100,"metric":10}]"#,
                "-6 -j route show table all": #"[{"dst":"fd00::/64","dev":"br-lan","metric":256}]"#,
                "-4 -j neigh show": #"[{"dst":"192.0.2.10","dev":"br-lan","lladdr":"02:00:00:00:00:01","state":["REACHABLE"]}]"#,
                "-6 -j neigh show": #"[{"dst":"fd00::10","dev":"br-lan","lladdr":"02:00:00:00:00:01","state":["STALE"]}]"#,
                "-4 -j rule show": #"[{"priority":100,"src":"all","table":100}]"#,
                "-6 -j rule show": #"[{"priority":32766,"src":"all","table":"main"}]"#,
                "-4 route show table all": "default via 192.0.2.254 dev br-lan table 100 proto static metric 10",
                "-6 route show table all": "fd00::/64 dev br-lan proto kernel metric 256",
                "-4 neigh show": "192.0.2.10 dev br-lan lladdr 02:00:00:00:00:01 REACHABLE",
                "-6 neigh show": "fd00::10 dev br-lan lladdr 02:00:00:00:00:01 STALE router",
                "-4 rule show": "100: from all lookup 100",
                "-6 rule show": "32766: from all lookup main"
            ]
            if query == failedQuery { result = .object(["code": .number(0), "stdout": .string("invalid JSON")]) }
            else if rejectJSON && query.contains("-j") { result = .object(["code": .number(1), "stderr": .string("invalid option -j")]) }
            else { result = routeResponse ?? .object(["code": .number(0), "stdout": .string(outputs[query] ?? "unexpected command"), "stderr": .string("")]) }
        default: result = .object([:])
        }
        return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"], "result": .array([.number(Double(code)), result])]))
    }
}

private final class RouterProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: RouterFixture] = [:]
    static func register(_ fixture: RouterFixture, host: String) { lock.lock(); defer { lock.unlock() }; fixtures[host] = fixture }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixtures[request.url!.host!]; Self.lock.unlock()
        do {
            let data = try fixture!.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
