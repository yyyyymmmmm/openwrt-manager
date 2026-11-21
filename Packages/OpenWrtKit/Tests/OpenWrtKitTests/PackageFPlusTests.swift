import XCTest
@testable import OpenWrtKit

/// Package F+: the panel-authenticated Open-Box data plane. Fixtures
/// follow the shapes read out of the panel's own frontend code
/// (briefs/openbox-native-spec.md): the subscriptions envelope, the
/// refresh outcome's changed/skipped pair, traffic rows of
/// key/up/down/conns, and the ACCESS_PASSWORD_* error codes.
final class PackageFPlusTests: XCTestCase {

    func testAuthStateParser() {
        let state = OpenBoxParser.authState(.object([
            "enabled": .bool(true), "authenticated": .bool(false), "passwordSet": .bool(true),
        ]))
        XCTAssertEqual(state.enabled, true)
        XCTAssertEqual(state.authenticated, false)
        XCTAssertEqual(state.passwordSet, true)
        XCTAssertNil(OpenBoxParser.authState(.object([:])).authenticated)
    }

    func testAccessCodeParser() {
        XCTAssertEqual(OpenBoxParser.accessCode(.object(["code": .string("ACCESS_PASSWORD_INVALID")])),
                       "ACCESS_PASSWORD_INVALID")
        XCTAssertEqual(OpenBoxParser.accessCode(.object(["code": .string("ACCESS_PASSWORD_REQUIRED")])),
                       "ACCESS_PASSWORD_REQUIRED")
        XCTAssertNil(OpenBoxParser.accessCode(.object([:])))
    }

    func testSubscriptionsUnwrapEnvelope() {
        let subs = OpenBoxParser.subscriptions(.object([
            "subscriptions": .array([
                .object(["id": .string("a1"), "name": .string("机场 A"),
                         "url": .string("https://example.com/sub"),
                         "enabled": .bool(true),
                         "nodes": .array([.object([:]), .object([:]), .object([:])])]),
                .object(["id": .number(7), "url": .string("https://example.net/x")]),
            ]),
        ]))
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].name, "机场 A")
        XCTAssertEqual(subs[0].nodeCount, 3)
        XCTAssertEqual(subs[0].enabled, true)
        // A numeric id coerces to text; a missing name falls back to the URL.
        XCTAssertEqual(subs[1].id, "7")
        XCTAssertEqual(subs[1].name, "https://example.net/x")
        XCTAssertNil(subs[1].nodeCount)
    }

    func testRefreshOutcomeParser() {
        let outcome = OpenBoxParser.refreshOutcome(.object([
            "changed": .bool(true),
            "skipped": .array([
                .object(["name": .string("坏节点"), "reason": .string("invalid"),
                         "detail": .string("bad uri")]),
                .object(["reason": .string("invalid")]),
            ]),
        ]))
        XCTAssertEqual(outcome.changed, true)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].name, "坏节点")
        XCTAssertEqual(outcome.skipped[0].reason, "invalid")
        XCTAssertEqual(outcome.skipped[0].detail, "bad uri")
    }

    func testTrafficSummaryRowsAndTotals() {
        let summary = OpenBoxParser.trafficSummary(.object([
            "rows": .array([
                .object(["key": .string("192.168.31.50"), "up": .number(100),
                         "down": .number(900), "conns": .number(4)]),
                .object(["key": .string("example.com"), "up": .number(5000),
                         "down": .number(6000)]),
            ]),
        ]))
        XCTAssertEqual(summary.rows.count, 2)
        // Heaviest row first, as the frontend sorts by up+down.
        XCTAssertEqual(summary.rows[0].key, "example.com")
        XCTAssertEqual(summary.rows[0].conns, nil)
        XCTAssertEqual(summary.displayUp, 5100)
        XCTAssertEqual(summary.displayDown, 6900)
    }

    func testTrafficSummaryPanelTotalsWin() {
        let summary = OpenBoxParser.trafficSummary(.object([
            "total": .object(["up": .number(10), "down": .number(20)]),
            "rows": .array([.object(["key": .string("a"), "up": .number(1), "down": .number(2)])]),
        ]))
        XCTAssertEqual(summary.displayUp, 10)
        XCTAssertEqual(summary.displayDown, 20)
    }

    func testEntriesEnvelopeVariants() {
        XCTAssertEqual(OpenBoxParser.entries(.object(["entries": .array([.string("x")])])).count, 1)
        XCTAssertEqual(OpenBoxParser.entries(.array([.object([:]), .object([:])])).count, 2)
        XCTAssertEqual(OpenBoxParser.entries(.object([:])).count, 0)
    }

    func testEntryTitlePicksFirstKnownField() {
        XCTAssertEqual(OpenBoxParser.entryTitle(.object(["payload": .string("*.example.com"),
                                                         "type": .string("domain-suffix")])),
                       "*.example.com")
        XCTAssertEqual(OpenBoxParser.entryTitle(.string("plain-entry")), "plain-entry")
        XCTAssertNil(OpenBoxParser.entryTitle(.object(["other": .number(1)])))
    }

    func testNodeQualityParser() {
        let nodes = OpenBoxParser.nodeQuality(.object([
            "nodes": .array([
                .object(["name": .string("香港 01"), "score": .number(92.5),
                         "latency": .number(38)]),
                .object(["tag": .string("node-b")]),
            ]),
        ]))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].score, 92.5)
        XCTAssertEqual(nodes[0].latencyMilliseconds, 38)
        XCTAssertEqual(nodes[1].name, "node-b")
        XCTAssertNil(nodes[1].score)
    }

    /// The panel password and session cookie the F+ login flow handles
    /// must be covered by the diagnostic redactor under every key name
    /// the new code could record them with — values under those keys
    /// are replaced wholesale before anything can leave the device.
    func testPanelSecretsAreRedactedByKey() {
        for key in ["panelPassword", "panel_cookie", "panelToken", "openboxSession", "cookie"] {
            XCTAssertTrue(DiagnosticRedactor.isSensitiveKey(key), key)
            XCTAssertEqual(DiagnosticRedactor.redact(metadata: [key: "s3cr3t-value"])[key],
                           DiagnosticRedactor.placeholder, key)
        }
    }
}
