import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

/// Rollback drills for the phase-2 transaction layer, run against a
/// stateful fake router: its UCI store actually mutates on set/delete,
/// restores on rollback/revert, and can be told to corrupt the applied
/// result or fail mid-staging.
final class TransactionTests: XCTestCase {
    private let original = RouterConfiguration(name: "system", sections: [
        .init(id: "main", type: "system", values: ["hostname": .string("OpenWrt")])
    ])

    private func plan() throws -> ConfigurationPlan {
        var edited = original
        edited.sections[0].values["hostname"] = .string("NewName")
        return try ConfigurationPlan(original: original, edited: edited)
    }

    func testExecuteHappyPathStagesReloadsVerifiesAndConfirms() async throws {
        let fixture = StatefulRouter()
        let client = try fixture.client()
        var reloaded: [String] = []
        let receipt = try await client.execute(plan: try plan(), reloadServices: ["dnsmasq"]) { name, action in
            reloaded.append("\(name):\(action.rawValue)")
        }
        XCTAssertEqual(receipt.editCount, 1)
        XCTAssertEqual(receipt.reloadedServices, ["dnsmasq"])
        XCTAssertEqual(reloaded, ["dnsmasq:restart"])
        let methods = fixture.calls.map(\.method)
        // Order is the transaction: access checks, changes check, read,
        // set, apply (rollback window), reload, verify read, board, confirm.
        XCTAssertLessThan(methods.firstIndex(of: "set")!, methods.firstIndex(of: "apply")!)
        XCTAssertLessThan(methods.firstIndex(of: "apply")!, methods.lastIndex(of: "get")!)
        XCTAssertEqual(methods.last, "confirm")
        XCTAssertFalse(methods.contains("rollback"))
        XCTAssertEqual(fixture.hostname, "NewName")
    }

    func testExecuteVerificationFailureRollsBack() async throws {
        let fixture = StatefulRouter()
        fixture.corruptAfterApply = true
        let client = try fixture.client()
        do {
            _ = try await client.execute(plan: try plan())
            XCTFail("Expected verification failure")
        } catch let error as TransactionError {
            XCTAssertEqual(error, .verificationFailed("system"))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.calls.contains { $0.method == "rollback" })
        XCTAssertFalse(fixture.calls.contains { $0.method == "confirm" })
        XCTAssertEqual(fixture.hostname, "OpenWrt")
    }

    func testExecuteReloadFailureRollsBack() async throws {
        let fixture = StatefulRouter()
        let client = try fixture.client()
        do {
            _ = try await client.execute(plan: try plan(), reloadServices: ["dnsmasq"]) { _, _ in
                throw OpenWrtKitError.unsupported("reload failed")
            }
            XCTFail("Expected reload failure")
        } catch let error as TransactionError {
            XCTAssertEqual(error, .reloadFailed("dnsmasq"))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.calls.contains { $0.method == "rollback" })
        XCTAssertEqual(fixture.hostname, "OpenWrt")
    }

    func testExecuteStagingFailureRevertsAndNeverApplies() async throws {
        let fixture = StatefulRouter()
        fixture.failSet = true
        let client = try fixture.client()
        do {
            _ = try await client.execute(plan: try plan())
            XCTFail("Expected staging failure")
        } catch { /* the staging error itself propagates */ }
        XCTAssertEqual(fixture.calls.last?.method, "revert")
        XCTAssertFalse(fixture.calls.contains { $0.method == "apply" })
        XCTAssertFalse(fixture.calls.contains { $0.method == "rollback" })
        XCTAssertEqual(fixture.hostname, "OpenWrt")
    }

    func testServiceActionTransactionVerifiesEndState() async throws {
        let box = ServiceStateBox(running: false, enabled: true)
        let transaction = ServiceActionTransaction(
            readState: { _ in await box.state },
            perform: { _, action in if action == .start { await box.set(running: true) } })
        let outcome = try await transaction.execute(name: "dnsmasq", action: .start)
        XCTAssertEqual(outcome.before?.running, false)
        XCTAssertEqual(outcome.after?.running, true)
        XCTAssertEqual(outcome.verified, true)
    }

    func testServiceActionTransactionReportsContradiction() async throws {
        let box = ServiceStateBox(running: true, enabled: true)
        let transaction = ServiceActionTransaction(
            readState: { _ in await box.state },
            perform: { _, _ in /* router silently keeps running */ })
        let outcome = try await transaction.execute(name: "dnsmasq", action: .stop)
        XCTAssertEqual(outcome.verified, false)
    }

    func testSystemControlRebootIssuesSingleCall() async throws {
        let caller = RecordingCaller()
        let control = SystemControlClient(caller: caller)
        try await control.reboot()
        XCTAssertEqual(caller.calls.map { "\($0.0)/\($0.1)" }, ["system/reboot"])
    }
}

private actor ServiceStateBox {
    var state: ServiceActionTransaction.State
    init(running: Bool?, enabled: Bool?) { state = .init(running: running, enabled: enabled) }
    func set(running: Bool) { state.running = running }
}

private final class RecordingCaller: UbusCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String)] = []
    var calls: [(String, String)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        lock.lock(); recorded.append((object, method)); lock.unlock()
        return .object([:])
    }
    func menu() async throws -> JSONValue { .object([:]) }
    func installedPackages() async throws -> [InstalledPackage] { [] }
}

/// A fake router whose single system config actually mutates.
private final class StatefulRouter: @unchecked Sendable {
    struct Call { let object: String; let method: String; let parameters: [String: JSONValue] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    var hostname = "OpenWrt"
    var failSet = false
    var corruptAfterApply = false
    private var applied = false

    func client() throws -> RouterConfigurationClient {
        let host = UUID().uuidString.lowercased() + ".test"
        StatefulProtocol.register(self, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatefulProtocol.self]
        let client = UbusClient(address: try URLNormalizer.normalize("http://" + host),
                                session: URLSession(configuration: configuration))
        return RouterConfigurationClient(client: client, session: UbusSession(token: String(repeating: "a", count: 32)))
    }

    func response(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        let params = body["params"].arrayValue!
        let call = Call(object: params[1].stringValue!, method: params[2].stringValue!,
                        parameters: params[3].objectValue!)
        lock.lock(); recorded.append(call); lock.unlock()
        var code = 0
        let result: JSONValue
        switch call.method {
        case "access":
            result = .object(["access": .bool(true)])
        case "changes":
            result = .object(["changes": .object([:])])
        case "get":
            let shown = (applied && corruptAfterApply) ? "Corrupted" : hostname
            result = .object(["values": .object(["main": .object([
                ".type": .string("system"), ".index": .number(0), "hostname": .string(shown)])])])
        case "set":
            if failSet { code = 8; result = .object([:]) }
            else {
                if let value = call.parameters["values"]?["hostname"].stringValue { hostname = value }
                result = .object([:])
            }
        case "apply":
            applied = true
            result = .object([:])
        case "rollback", "revert":
            hostname = "OpenWrt"
            applied = false
            result = .object([:])
        default:
            result = .object([:])
        }
        return try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": body["id"],
            "result": .array([.number(Double(code)), result])]))
    }
}

private final class StatefulProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: StatefulRouter] = [:]
    static func register(_ fixture: StatefulRouter, host: String) {
        lock.lock(); defer { lock.unlock() }; fixtures[host] = fixture
    }
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
