import XCTest
@testable import OpenWrtKit

/// Package A: the diagnostics core. The redaction tests are the point —
/// an export that can carry a password or a session token is worse than
/// no export at all, so the rules are pinned down case by case.
final class DiagnosticsTests: XCTestCase {

    // MARK: Redaction — keys

    func testSensitiveKeysAreReplacedWholesale() {
        let redacted = DiagnosticRedactor.redact(metadata: [
            "password": "hunter2",
            "Password": "hunter2",
            "ubus_rpc_session": "0123456789abcdef0123456789abcdef",
            "api_token": "abc",
            "Set-Cookie": "sysauth_http=xyz",
            "username": "root",
        ])
        XCTAssertEqual(redacted["password"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(redacted["Password"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(redacted["ubus_rpc_session"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(redacted["api_token"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(redacted["Set-Cookie"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(redacted["username"], "root")
    }

    func testSensitiveKeyDetection() {
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("refresh-token"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("X-Auth-Token"))
        XCTAssertTrue(DiagnosticRedactor.isSensitiveKey("private_key"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("address"))
        XCTAssertFalse(DiagnosticRedactor.isSensitiveKey("hostname"))
    }

    // MARK: Redaction — value shapes

    func testLongHexRunsAreScrubbedFromMessagesAndValues() {
        let session = "0123456789abcdef0123456789abcdef"
        let message = DiagnosticRedactor.redactMessage("login ok, session \(session) issued")
        XCTAssertFalse(message.contains(session))
        XCTAssertTrue(message.contains(DiagnosticRedactor.placeholder))
        let value = DiagnosticRedactor.redactValue("id=\(session)")
        XCTAssertFalse(value.contains(session))
    }

    func testBearerCredentialsAreScrubbed() {
        let scrubbed = DiagnosticRedactor.redactValue("Authorization: Bearer abc.def.ghi")
        XCTAssertFalse(scrubbed.contains("abc.def.ghi"))
        XCTAssertTrue(scrubbed.contains("Bearer \(DiagnosticRedactor.placeholder)"))
    }

    func testShortHexAndAddressesSurvive() {
        // IPs stay by policy (self-use LAN diagnostics); short hex
        // fragments (build ids, status codes) are not credentials.
        XCTAssertEqual(DiagnosticRedactor.redactValue("192.168.31.167"), "192.168.31.167")
        XCTAssertEqual(DiagnosticRedactor.redactValue("rev 443ec4032a"), "rev 443ec4032a")
        XCTAssertEqual(DiagnosticRedactor.redactValue("OpenWrt 24.10.8"), "OpenWrt 24.10.8")
    }

    // MARK: Ring buffer

    func testRingBufferKeepsMostRecentInOrder() {
        let log = DiagnosticLog(capacity: 3)
        for index in 1...5 {
            log.record(category: .app, message: "event \(index)")
        }
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log.events.map(\.message), ["event 3", "event 4", "event 5"])
        XCTAssertEqual(log.recent(2).map(\.message), ["event 4", "event 5"])
        XCTAssertEqual(log.recent(0), [])
    }

    func testRecordRedactsBeforeStorage() {
        let log = DiagnosticLog()
        log.record(category: .connection, message: "login",
                   metadata: ["password": "hunter2", "address": "192.168.31.1"])
        let event = log.events.first
        XCTAssertEqual(event?.metadata["password"], DiagnosticRedactor.placeholder)
        XCTAssertEqual(event?.metadata["address"], "192.168.31.1")
    }

    func testClearEmptiesTheBuffer() {
        let log = DiagnosticLog()
        log.record(category: .app, message: "one")
        log.clear()
        XCTAssertEqual(log.count, 0)
    }

    // MARK: Export

    func testExportRendersHeaderEventsAndNoSecrets() {
        let log = DiagnosticLog()
        log.record(category: .connection, message: "Connected",
                   metadata: ["address": "192.168.31.1", "password": "hunter2"],
                   date: Date(timeIntervalSince1970: 1_800_000_000))
        log.record(category: .error, message: "Discovery failed",
                   date: Date(timeIntervalSince1970: 1_800_000_060))
        let header = DiagnosticExportHeader(
            appVersion: "0.3.0", appBuild: "6", deviceModel: "iPhone17,2",
            systemName: "iOS", systemVersion: "26.0",
            routerName: "Home Router", routerModel: "Xiaomi Mi Router AX3000T",
            firmwareDescription: "OpenWrt 24.10.8 r29233-443ec4032a",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_120))
        let text = DiagnosticExport.render(header: header, events: log.events)
        XCTAssertTrue(text.contains("App: 0.3.0 (6)"))
        XCTAssertTrue(text.contains("Device: iPhone17,2"))
        XCTAssertTrue(text.contains("System: iOS 26.0"))
        XCTAssertTrue(text.contains("Router model: Xiaomi Mi Router AX3000T"))
        XCTAssertTrue(text.contains("Firmware: OpenWrt 24.10.8"))
        XCTAssertTrue(text.contains("[connection] Connected"))
        XCTAssertTrue(text.contains("[error] Discovery failed"))
        XCTAssertTrue(text.contains("address=192.168.31.1"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("password=\(DiagnosticRedactor.placeholder)"))
    }

    func testExportCapsTheNumberOfEvents() {
        let log = DiagnosticLog(capacity: 10)
        for index in 1...10 {
            log.record(category: .refresh, message: "tick \(index)")
        }
        let header = DiagnosticExportHeader(
            appVersion: "0.3.0", appBuild: "6", deviceModel: "iPhone17,2",
            systemName: "iOS", systemVersion: "26.0")
        let text = DiagnosticExport.render(header: header, events: log.events, maxEvents: 3)
        XCTAssertTrue(text.contains("Events: 10 total, showing last 3"))
        XCTAssertTrue(text.contains("tick 10"))
        XCTAssertFalse(text.contains("tick 7"))
    }
}
