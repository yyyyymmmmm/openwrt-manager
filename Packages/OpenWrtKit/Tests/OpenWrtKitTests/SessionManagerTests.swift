import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenWrtKit

private struct StaticCredentials: SessionCredentialProvider {
    let credentials: RouterCredentials?
    func routerCredentials() async -> RouterCredentials? { credentials }
}

/// Minimal JSON-RPC over a stubbed URLProtocol: login requests are counted,
/// call requests follow a script (per-attempt result codes).
private final class StubURLProtocol: URLProtocol {
    static var loginCount = 0
    static var callAttempts = 0
    static var loginExpires = 3600
    static var callResultCodes: [Int] = [0]
    static var lock = NSLock()

    static func reset() {
        lock.lock()
        loginCount = 0; callAttempts = 0; loginExpires = 3600; callResultCodes = [0]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let body = Self.bodyData(from: request)
        let parsed = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let id = (parsed?["id"] as? NSNumber)?.intValue ?? 1
        let params = parsed?["params"] as? [Any]
        let method = (params?.count ?? 0) > 2 ? params?[2] as? String : nil
        Self.lock.lock()
        let payload: [String: Any]
        if method == "login" {
            Self.loginCount += 1
            let sessionObject: [String: Any] = ["ubus_rpc_session": String(repeating: "a", count: 32),
                                                "expires": Self.loginExpires]
            let result: [Any] = [0, sessionObject]
            payload = ["jsonrpc": "2.0", "id": id, "result": result]
        } else {
            let index = min(Self.callAttempts, Self.callResultCodes.count - 1)
            let code = Self.callResultCodes[index]
            Self.callAttempts += 1
            let result: [Any] = code == 0 ? [0, ["value": 1]] : [code]
            payload = ["jsonrpc": "2.0", "id": id, "result": result]
        }
        Self.lock.unlock()
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

final class SessionManagerTests: XCTestCase {
    private var manager: SessionManager!

    override func setUp() async throws {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let address = try URLNormalizer.normalize("192.168.31.250")
        let client = UbusClient(address: address, session: urlSession)
        manager = SessionManager(
            client: client,
            credentialProvider: StaticCredentials(credentials: RouterCredentials(username: "root", password: "secret")),
            refreshMargin: 60)
    }

    func testSessionIsCreatedLazilyAndReused() async throws {
        let first = try await manager.session()
        let second = try await manager.session()
        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(StubURLProtocol.loginCount, 1)
    }

    func testSessionRefreshesWhenInsideMargin() async throws {
        StubURLProtocol.loginExpires = 30
        _ = try await manager.session()
        _ = try await manager.session()
        XCTAssertEqual(StubURLProtocol.loginCount, 2)
    }

    func testCallReplaysOnceAfterPermissionDenied() async throws {
        StubURLProtocol.callResultCodes = [6, 0]
        let value = try await manager.call(object: "system", method: "board")
        XCTAssertEqual(value["value"].intValue, 1)
        XCTAssertEqual(StubURLProtocol.callAttempts, 2)
        XCTAssertEqual(StubURLProtocol.loginCount, 2)
    }

    func testCallDoesNotReplayTwice() async {
        StubURLProtocol.callResultCodes = [6, 6, 0]
        do {
            _ = try await manager.call(object: "system", method: "board")
            XCTFail("Expected permissionDenied")
        } catch let error as OpenWrtKitError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.callAttempts, 2)
        XCTAssertEqual(StubURLProtocol.loginCount, 2)
    }

    func testWritesDoNotReplayWhenDisabled() async {
        StubURLProtocol.callResultCodes = [6, 0]
        do {
            _ = try await manager.call(object: "uci", method: "set", replayAfterRelogin: false)
            XCTFail("Expected permissionDenied")
        } catch let error as OpenWrtKitError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.callAttempts, 1)
        XCTAssertEqual(StubURLProtocol.loginCount, 1)
    }

    func testMissingCredentialsThrowAuthenticationFailed() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let address = try! URLNormalizer.normalize("192.168.31.250")
        let orphan = SessionManager(
            client: UbusClient(address: address, session: URLSession(configuration: configuration)),
            credentialProvider: StaticCredentials(credentials: nil))
        do {
            _ = try await orphan.session()
            XCTFail("Expected authenticationFailed")
        } catch let error as OpenWrtKitError {
            XCTAssertEqual(error, .authenticationFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.loginCount, 0)
    }
}
