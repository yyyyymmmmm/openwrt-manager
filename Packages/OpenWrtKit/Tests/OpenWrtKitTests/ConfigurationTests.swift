import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
