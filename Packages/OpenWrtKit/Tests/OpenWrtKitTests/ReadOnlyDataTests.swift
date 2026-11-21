import XCTest
@testable import OpenWrtKit

final class ReadOnlyDataTests: XCTestCase {

    // MARK: Freshness

    func testFreshnessPolicyStates() {
        let policy = FreshnessPolicy(staleAfter: 25)
        let fetched = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(policy.evaluate(fetchedAt: nil, now: fetched), .missing)
        XCTAssertEqual(policy.evaluate(fetchedAt: fetched, now: fetched.addingTimeInterval(10)), .live)
        XCTAssertEqual(policy.evaluate(fetchedAt: fetched, now: fetched.addingTimeInterval(25)), .live)
        let stale = policy.evaluate(fetchedAt: fetched, now: fetched.addingTimeInterval(40))
        XCTAssertEqual(stale, .stale(age: 40))
        XCTAssertTrue(stale.isStale)
        // A clock reading earlier than the fetch never marks data stale.
        XCTAssertEqual(policy.evaluate(fetchedAt: fetched, now: fetched.addingTimeInterval(-5)), .live)
    }

    // MARK: Parsers

    func testSystemLogParser() throws {
        let json = #"{"log":[{"time":1763558400000,"msg":"daemon started","priority":6,"source":"dnsmasq"},{"time":1763558401000,"msg":"link up","priority":4,"source":"netifd"}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let entries = ReadOnlyParser.systemLog(value)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message, "daemon started")
        XCTAssertEqual(entries[0].source, "dnsmasq")
        XCTAssertEqual(entries[0].priority, 6)
        XCTAssertEqual(entries[0].timestamp, Date(timeIntervalSince1970: 1_763_558_400))
    }

    func testKernelLogParser() {
        let entries = ReadOnlyParser.kernelLog("[ 0.000000] Linux version 6.12\n[ 0.100000] pci ok\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].message.contains("Linux version"))
        XCTAssertNil(entries[0].timestamp)
    }

    func testProcessParserAcceptsStringFields() throws {
        let json = #"{"result":[{"PID":"123","PPID":"1","USER":"root","%CPU":"3.5","%MEM":"1.2","COMMAND":"/usr/sbin/uhttpd"},{"PID":"9","COMMAND":"procd"}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let processes = ReadOnlyParser.processes(value)
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, 123)
        XCTAssertEqual(processes[0].cpuPercent, 3.5)
        XCTAssertEqual(processes[0].command, "/usr/sbin/uhttpd")
        XCTAssertNil(processes[1].cpuPercent)
    }

    func testNeighborParser() {
        let text = """
        192.168.31.5 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE
        192.168.31.1 dev br-lan lladdr 11:22:33:44:55:66 router STALE
        fe80::1 dev eth0 FAILED
        """
        let neighbors = ReadOnlyParser.neighbors(text)
        XCTAssertEqual(neighbors.count, 3)
        XCTAssertEqual(neighbors[0].mac, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(neighbors[0].state, "REACHABLE")
        XCTAssertTrue(neighbors[1].isRouter)
        XCTAssertNil(neighbors[2].mac)
        XCTAssertEqual(neighbors[2].state, "FAILED")
    }

    func testDeviceTrafficParser() throws {
        let json = #"{"eth0":{"statistics":{"rx_bytes":1000,"tx_bytes":2000}},"br-lan":{"statistics":{"rx_bytes":3000,"tx_bytes":4000}},"lo":{}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let traffic = ReadOnlyParser.deviceTraffic(value)
        XCTAssertEqual(traffic.map(\.device), ["br-lan", "eth0"])
        XCTAssertEqual(traffic[1].rxBytes, 1000)
    }

    func testConnectionCountParser() {
        XCTAssertEqual(ReadOnlyParser.connectionCount("321\n", maximumText: "65536")?.count, 321)
        XCTAssertEqual(ReadOnlyParser.connectionCount("321\n", maximumText: "65536")?.maximum, 65536)
        XCTAssertNil(ReadOnlyParser.connectionCount("not-a-number"))
    }

    func testNftablesParserSumsChainCounters() {
        let text = """
        table inet fw4 {
            chain input {
                type filter hook input priority 0; policy drop;
                iifname "lo" accept counter packets 10 bytes 800
                ct state established counter packets 90 bytes 7200
            }
            chain forward {
                type filter hook forward priority 0; policy drop;
                counter packets 5 bytes 400
            }
        }
        table ip nat {
            chain postrouting {
                counter packets 2 bytes 160
            }
        }
        """
        let tables = ReadOnlyParser.nftables(text)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].name, "fw4")
        XCTAssertEqual(tables[0].chains.count, 2)
        XCTAssertEqual(tables[0].chains[0].countedRules, 2)
        XCTAssertEqual(tables[0].chains[0].packets, 100)
        XCTAssertEqual(tables[0].chains[0].bytes, 8000)
        XCTAssertEqual(tables[0].chains[1].packets, 5)
        XCTAssertEqual(tables[1].family, "ip")
        XCTAssertEqual(tables[1].chains[0].packets, 2)
    }

    // MARK: Rate calculator

    func testRateCalculatorComputesPerSecond() {
        let previous = [DeviceTraffic(device: "eth0", rxBytes: 1_000, txBytes: 2_000)]
        let current = [DeviceTraffic(device: "eth0", rxBytes: 3_000, txBytes: 2_500)]
        let rates = RateCalculator.rates(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(rates["eth0"]?.rxBytesPerSecond, 1_000)
        XCTAssertEqual(rates["eth0"]?.txBytesPerSecond, 250)
    }

    func testRateCalculatorDropsResetCountersAndUnknownDevices() {
        let previous = [DeviceTraffic(device: "eth0", rxBytes: 5_000, txBytes: 0)]
        let current = [DeviceTraffic(device: "eth0", rxBytes: 100, txBytes: 0),
                       DeviceTraffic(device: "eth1", rxBytes: 10, txBytes: 10)]
        let rates = RateCalculator.rates(previous: previous, current: current, elapsed: 1)
        XCTAssertTrue(rates.isEmpty)
        XCTAssertTrue(RateCalculator.rates(previous: previous, current: current, elapsed: 0).isEmpty)
    }

    // MARK: Polling engine

    func testEngineBuildsSamplesWithSharedCadence() async {
        let readings: [RawRealtimeReading?] = [
            RawRealtimeReading(load: [0.5], traffic: [DeviceTraffic(device: "eth0", rxBytes: 0, txBytes: 0)], connections: 10),
            RawRealtimeReading(load: [0.7], traffic: [DeviceTraffic(device: "eth0", rxBytes: 5_000, txBytes: 1_000)], connections: 12),
            nil,
            RawRealtimeReading(load: [0.9], traffic: [DeviceTraffic(device: "eth0", rxBytes: 9_000, txBytes: 3_000)], connections: 15)
        ]
        let box = ReadingBox(readings)
        let engine = RealtimeEngine(fetch: { await box.next() }, capacity: 10)
        let start = Date(timeIntervalSince1970: 10_000)
        let first = await engine.pollOnce(now: start)
        XCTAssertEqual(first?.load1, 0.5)
        XCTAssertNil(first?.totalRate) // no previous counters yet
        let second = await engine.pollOnce(now: start.addingTimeInterval(5))
        XCTAssertEqual(second?.deviceRates["eth0"]?.rxBytesPerSecond, 1_000)
        XCTAssertEqual(second?.connections, 12)
        let failed = await engine.pollOnce(now: start.addingTimeInterval(10))
        XCTAssertNil(failed)
        let third = await engine.pollOnce(now: start.addingTimeInterval(15))
        XCTAssertEqual(third?.load1, 0.9)
        let samples = await engine.samples
        XCTAssertEqual(samples.count, 3)
        let freshness = await engine.freshness(policy: FreshnessPolicy(staleAfter: 12),
                                               now: start.addingTimeInterval(40))
        XCTAssertEqual(freshness, .stale(age: 25))
    }

    func testEngineHistoryIsBounded() async {
        let engine = RealtimeEngine(fetch: { RawRealtimeReading(load: [1]) }, capacity: 3)
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<6 {
            await engine.pollOnce(now: start.addingTimeInterval(Double(index)))
        }
        let samples = await engine.samples
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.first?.at, start.addingTimeInterval(3))
    }
}

private actor ReadingBox {
    private var readings: [RawRealtimeReading?]
    init(_ readings: [RawRealtimeReading?]) { self.readings = readings }
    func next() -> RawRealtimeReading? {
        readings.isEmpty ? nil : readings.removeFirst()
    }
}
