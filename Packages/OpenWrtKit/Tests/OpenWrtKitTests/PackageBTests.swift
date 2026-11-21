import XCTest
@testable import OpenWrtKit

/// Package B: metric history honesty (gaps stay gaps), the alert
/// rule engine (sustained thresholds, two-strike offline, cooldown,
/// fired/resolved pairing), the event log, OpenWrt fingerprinting
/// and the restrained discovery candidate list.
final class PackageBTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(at offset: TimeInterval, rx: Double? = nil, load: Double? = nil,
                        memory: Double? = nil) -> MetricSample {
        MetricSample(at: t0.addingTimeInterval(offset), rxBytesPerSecond: rx,
                     load1: load, memoryPercent: memory)
    }

    // MARK: History

    func testHistoryPrunesBeyondRetentionAndCap() {
        var history = MetricHistory()
        history.retention = 3600
        history.append(sample(at: 0))
        history.append(sample(at: 1800))
        history.append(sample(at: 3700))
        XCTAssertEqual(history.samples.map { $0.at }, [t0.addingTimeInterval(1800), t0.addingTimeInterval(3700)])

        var capped = MetricHistory()
        capped.capacity = 3
        for index in 0..<5 { capped.append(sample(at: TimeInterval(index * 60))) }
        XCTAssertEqual(capped.samples.count, 3)
        XCTAssertEqual(capped.samples.first?.at, t0.addingTimeInterval(120))
    }

    func testChartSegmentsBreakAtGapsAndNeverBridgeThem() {
        var history = MetricHistory()
        // Two dense clusters with a 30-minute silence between them.
        for offset in stride(from: 0.0, through: 300.0, by: 60.0) {
            history.append(sample(at: offset, rx: 100))
        }
        for offset in stride(from: 2100.0, through: 2400.0, by: 60.0) {
            history.append(sample(at: offset, rx: 200))
        }
        let range = t0...t0.addingTimeInterval(3600)
        let segments = history.chartSegments(metric: .trafficDown, in: range)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].map(\.value), Array(repeating: 100.0, count: 6))
        XCTAssertEqual(segments[1].map(\.value), Array(repeating: 200.0, count: 6))
        XCTAssertTrue(history.hasGap(metric: .trafficDown, in: range))
        // No fabricated point exists inside the silent stretch.
        let allPoints = segments.flatMap { $0 }
        XCTAssertFalse(allPoints.contains { $0.at > t0.addingTimeInterval(300) && $0.at < t0.addingTimeInterval(2100) })
    }

    func testChartSegmentsSkipMissingMetricAndBucketWithinSegments() {
        var history = MetricHistory()
        history.append(sample(at: 0, rx: nil, load: 1))
        history.append(sample(at: 60, rx: 10, load: 1))
        history.append(sample(at: 120, rx: 30, load: 1))
        let range = t0...t0.addingTimeInterval(600)
        let raw = history.chartSegments(metric: .trafficDown, in: range)
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0].count, 2, "samples without the metric are absent, not zero")
        // t0 sits 200 s into its 300 s bucket, so the two points fall
        // into neighbouring buckets and stay separate averages.
        let bucketed = history.chartSegments(metric: .trafficDown, in: range, bucketSeconds: 300)
        XCTAssertEqual(bucketed[0].map(\.value), [10, 30])
    }

    // MARK: Alert engine

    private func observation(at offset: TimeInterval, reachable: Bool = true,
                               wanUp: Bool? = nil, load: Double? = nil,
                               memory: Double? = nil, devices: Set<String>? = nil) -> AlertObservation {
        AlertObservation(at: t0.addingTimeInterval(offset), reachable: reachable,
                         wanUp: wanUp, load1: load, memoryPercent: memory, deviceIDs: devices)
    }

    func testOfflineNeedsTwoStrikesAndResolvesAsPair() {
        var engine = AlertEngine()
        let settings = AlertSettings()
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 0, reachable: false)).isEmpty)
        let fired = engine.evaluate(settings: settings, observation: observation(at: 30, reachable: false))
        XCTAssertEqual(fired.map { "\($0.kind)/\($0.phase)" }, ["routerOffline/fired"])
        // Still offline: no repeat.
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 60, reachable: false)).isEmpty)
        let resolved = engine.evaluate(settings: settings, observation: observation(at: 90, reachable: true))
        XCTAssertEqual(resolved.map { "\($0.kind)/\($0.phase)" }, ["routerOffline/resolved"])
    }

    func testOfflineCooldownSuppressesImmediateRefire() {
        var engine = AlertEngine()
        var settings = AlertSettings()
        settings.cooldown = 1800
        _ = engine.evaluate(settings: settings, observation: observation(at: 0, reachable: false))
        _ = engine.evaluate(settings: settings, observation: observation(at: 30, reachable: false))
        _ = engine.evaluate(settings: settings, observation: observation(at: 60, reachable: true))
        _ = engine.evaluate(settings: settings, observation: observation(at: 90, reachable: false))
        let refired = engine.evaluate(settings: settings, observation: observation(at: 120, reachable: false))
        XCTAssertTrue(refired.isEmpty, "second outage inside the cooldown stays quiet")
        // Its recovery is not reported either — the user never saw the alert.
        let resolved = engine.evaluate(settings: settings, observation: observation(at: 150, reachable: true))
        XCTAssertTrue(resolved.isEmpty)
    }

    func testThresholdMustBeSustainedBeforeFiring() {
        var engine = AlertEngine()
        var settings = AlertSettings()
        settings.sustain = 300
        settings.memoryThreshold = 90
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 0, memory: 95)).isEmpty)
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 120, memory: 96)).isEmpty)
        let fired = engine.evaluate(settings: settings, observation: observation(at: 300, memory: 97))
        XCTAssertEqual(fired.map { "\($0.kind)/\($0.phase)" }, ["memoryHigh/fired"])
        XCTAssertEqual(fired.first?.value, 97)
        let resolved = engine.evaluate(settings: settings, observation: observation(at: 360, memory: 40))
        XCTAssertEqual(resolved.map { "\($0.kind)/\($0.phase)" }, ["memoryHigh/resolved"])
    }

    func testThresholdBlipResetsTheSustainClock() {
        var engine = AlertEngine()
        var settings = AlertSettings()
        settings.sustain = 300
        _ = engine.evaluate(settings: settings, observation: observation(at: 0, load: 3))
        _ = engine.evaluate(settings: settings, observation: observation(at: 200, load: 0.5))
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 400, load: 3)).isEmpty)
        let fired = engine.evaluate(settings: settings, observation: observation(at: 700, load: 3))
        XCTAssertEqual(fired.map(\.kind), [.loadHigh])
    }

    func testWANRuleIgnoresUnknownAndDisabledRulesStaySilent() {
        var engine = AlertEngine()
        let settings = AlertSettings()
        XCTAssertTrue(engine.evaluate(settings: settings, observation: observation(at: 0, wanUp: nil)).isEmpty)
        _ = engine.evaluate(settings: settings, observation: observation(at: 30, wanUp: false))
        let fired = engine.evaluate(settings: settings, observation: observation(at: 60, wanUp: false))
        XCTAssertEqual(fired.map(\.kind), [.wanDown])

        var disabled = AlertSettings()
        disabled.wanEnabled = false
        var quiet = AlertEngine()
        _ = quiet.evaluate(settings: disabled, observation: observation(at: 0, wanUp: false))
        XCTAssertTrue(quiet.evaluate(settings: disabled, observation: observation(at: 30, wanUp: false)).isEmpty)
    }

    func testNewDeviceBaselineIsSilentThenFiresOncePerCooldown() {
        var engine = AlertEngine()
        var settings = AlertSettings()
        settings.cooldown = 1800
        let baseline = engine.evaluate(settings: settings, observation: observation(at: 0, devices: ["aa", "bb"]))
        XCTAssertTrue(baseline.isEmpty, "first sight is the baseline, not an alert")
        let fired = engine.evaluate(settings: settings, observation: observation(at: 60, devices: ["aa", "bb", "cc"]))
        XCTAssertEqual(fired.map(\.kind), [.newDevice])
        XCTAssertEqual(fired.first?.newDeviceIDs, ["cc"])
        let again = engine.evaluate(settings: settings, observation: observation(at: 120, devices: ["aa", "bb", "cc", "dd"]))
        XCTAssertTrue(again.isEmpty, "cooldown suppresses the second arrival")
    }

    // MARK: Event log

    func testEventLogCapsAndScopes() {
        var log = EventLog()
        log.capacity = 3
        for index in 0..<5 {
            log.append(StoredEvent(at: t0.addingTimeInterval(TimeInterval(index)), category: .operation,
                                   title: "事件 \(index)", detail: "", routerID: index.isMultiple(of: 2) ? "r1" : nil))
        }
        XCTAssertEqual(log.events.count, 3)
        XCTAssertEqual(log.recent().first?.title, "事件 4")
        XCTAssertEqual(log.recent(routerID: "r1").map(\.title), ["事件 4", "事件 3", "事件 2"], "router scope includes global (routerless) events")
    }

    // MARK: Fingerprint

    func testLuCIFingerprint() {
        XCTAssertTrue(OpenWrtFingerprint.looksLikeLuCI(html: "<form action=\"/cgi-bin/luci/\">"))
        XCTAssertTrue(OpenWrtFingerprint.looksLikeLuCI(html: "<link href=\"/luci-static/bootstrap/cascade.css\">"))
        XCTAssertTrue(OpenWrtFingerprint.looksLikeLuCI(html: "<title>OpenWrt - LuCI</title>"))
        XCTAssertFalse(OpenWrtFingerprint.looksLikeLuCI(html: "<title>Router Login</title><p>Welcome</p>"))
        XCTAssertFalse(OpenWrtFingerprint.looksLikeLuCI(html: ""))
    }

    func testBoardInfoParsing() throws {
        let payload = #"{"jsonrpc":"2.0","id":1,"result":[0,{"hostname":"OpenWrt","model":"Xiaomi AX3000T","release":{"distribution":"OpenWrt","version":"24.10.8","description":"OpenWrt 24.10.8 r28959"}}]}"#
        let info = try XCTUnwrap(OpenWrtFingerprint.boardInfo(from: Data(payload.utf8)))
        XCTAssertEqual(info.model, "Xiaomi AX3000T")
        XCTAssertEqual(info.firmware, "OpenWrt 24.10.8 r28959")
        XCTAssertEqual(info.hostname, "OpenWrt")
        XCTAssertNil(OpenWrtFingerprint.boardInfo(from: Data(#"{"error":{"code":-32000}}"#.utf8)))
        XCTAssertNil(OpenWrtFingerprint.boardInfo(from: Data("not json".utf8)))
    }

    // MARK: Discovery candidates

    func testDiscoveryCandidatesAreGatewayFirstAndRestrained() {
        let hosts = DiscoveryCandidates.hosts(phoneIP: "192.168.31.150", netmask: "255.255.255.0")
        XCTAssertEqual(hosts.first, "192.168.31.1")
        XCTAssertTrue(hosts.contains("192.168.31.254"))
        XCTAssertFalse(hosts.contains("192.168.31.150"), "the phone itself is never a candidate")
        XCTAssertLessThanOrEqual(hosts.count, 4)
        XCTAssertEqual(DiscoveryCandidates.hosts(phoneIP: "not-an-ip", netmask: "255.255.255.0"), [])
    }
}
