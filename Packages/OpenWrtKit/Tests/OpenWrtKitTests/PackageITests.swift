import XCTest
@testable import OpenWrtKit

/// Package I (comprehension leftovers): the bandwidth rollup, the
/// firewall rule bodies, the wireless neighbourhood scan, and the
/// two rating scales they use.
final class PackageITests: XCTestCase {

    // MARK: Bandwidth rollup (U2)

    func testBandwidthAggregatesLayer7RowsPerHost() {
        let text = """
        {"data":[
          ["IPv4","192.168.1.10","AA:BB:CC:DD:EE:01","HTTPS",10,1000,10,500,5],
          ["IPv4","192.168.1.10","AA:BB:CC:DD:EE:01","HTTP",2,300,3,100,2],
          ["IPv4","192.168.1.20","AA:BB:CC:DD:EE:02","HTTPS",1,200,2,50,1],
          ["IPv6","2001:db8::5","AA:BB:CC:DD:EE:01","HTTPS",1,700,1,70,1]
        ]}
        """
        let report = BandwidthParser.parse(text)
        XCTAssertEqual(report?.hosts.count, 2)
        let top = report?.hosts.first
        XCTAssertEqual(top?.mac, "AA:BB:CC:DD:EE:01")
        XCTAssertEqual(top?.address, "192.168.1.10")
        XCTAssertEqual(top?.downloadBytes, 2000)
        XCTAssertEqual(top?.uploadBytes, 670)
        XCTAssertEqual(top?.connections, 13)
        XCTAssertEqual(report?.totalDownload, 2200)
        XCTAssertEqual(report?.totalUpload, 720)
        if let report, let top {
            XCTAssertEqual(report.share(of: top) ?? 0, 2670.0 / 2920.0, accuracy: 0.001)
        } else {
            XCTFail("expected a parsed report with a top host")
        }
    }

    func testBandwidthPrefersIPv4DisplayAddress() {
        let text = """
        {"data":[
          ["IPv6","2001:db8::5","AA:BB:CC:DD:EE:01","HTTPS",1,700,1,70,1],
          ["IPv4","192.168.1.10","AA:BB:CC:DD:EE:01","HTTPS",1,300,1,30,1]
        ]}
        """
        XCTAssertEqual(BandwidthParser.parse(text)?.hosts.first?.address, "192.168.1.10")
    }

    func testBandwidthColumnsMappingWinsOverPositions() {
        let text = """
        {"columns":["mac","conns","rx_bytes","rx_pkts","tx_bytes","tx_pkts"],
         "data":[["AA:BB:CC:DD:EE:07",4,800,8,200,2]]}
        """
        let host = BandwidthParser.parse(text)?.hosts.first
        XCTAssertEqual(host?.mac, "AA:BB:CC:DD:EE:07")
        XCTAssertEqual(host?.downloadBytes, 800)
        XCTAssertEqual(host?.uploadBytes, 200)
        XCTAssertEqual(host?.connections, 4)
    }

    func testBandwidthObjectRows() {
        let text = """
        {"data":[{"mac":"aa:bb:cc:dd:ee:09","ip":"192.168.1.30","rx_bytes":4096,"tx_bytes":1024,"conns":3}]}
        """
        let host = BandwidthParser.parse(text)?.hosts.first
        XCTAssertEqual(host?.mac, "AA:BB:CC:DD:EE:09")
        XCTAssertEqual(host?.address, "192.168.1.30")
        XCTAssertEqual(host?.totalBytes, 5120)
    }

    func testBandwidthZeroMACFallsBackToAddressKey() {
        let text = """
        {"data":[["IPv6","2001:db8::99","00:00:00:00:00:00","HTTP",1,100,1,10,1]]}
        """
        let host = BandwidthParser.parse(text)?.hosts.first
        XCTAssertNil(host?.mac)
        XCTAssertEqual(host?.address, "2001:db8::99")
        XCTAssertEqual(host?.id, "2001:db8::99")
    }

    func testBandwidthRejectsNonReports() {
        XCTAssertNil(BandwidthParser.parse("not json"))
        XCTAssertNil(BandwidthParser.parse("{}"))
        XCTAssertNil(BandwidthParser.parse("{\"data\":[]}"))
        XCTAssertNil(BandwidthParser.parse("{\"data\":[[\"IPv4\",\"layer7 only\"]]}"))
    }

    // MARK: Firewall rule bodies (U6)

    private var rulesetJSON: String {
        """
        {"nftables":[
          {"table":{"family":"inet","name":"fw4","handle":1}},
          {"chain":{"family":"inet","table":"fw4","name":"input","handle":1}},
          {"rule":{"family":"inet","table":"fw4","chain":"input","handle":2,"comment":"Allow-DHCP-Renew",
            "expr":[
              {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"192.168.1.0","len":24}}}},
              {"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"dport"}},"right":67}},
              {"counter":{"packets":12,"bytes":1000}},
              {"accept":null}]}},
          {"rule":{"family":"inet","table":"fw4","chain":"input","handle":3,
            "expr":[
              {"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"wan"}},
              {"drop":null}]}},
          {"chain":{"family":"inet","table":"fw4","name":"dstnat","handle":4}},
          {"rule":{"family":"inet","table":"fw4","chain":"dstnat","handle":5,
            "expr":[
              {"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8080}},
              {"dnat":{"addr":"192.168.1.50","port":80}}]}}
        ]}
        """
    }

    func testNftRulesParsedWithHumanSummary() throws {
        let tables = try ReadOnlyParser.nftablesJSON(rulesetJSON)
        let input = tables[0].chains.first { $0.name == "input" }
        XCTAssertEqual(input?.rules.count, 2)
        // Chain counters keep their old semantics: only rules with a
        // counter statement count.
        XCTAssertEqual(input?.countedRules, 1)
        XCTAssertEqual(input?.packets, 12)

        let dhcp = input?.rules[0]
        XCTAssertEqual(dhcp?.comment, "Allow-DHCP-Renew")
        XCTAssertEqual(dhcp?.source, "192.168.1.0/24")
        XCTAssertEqual(dhcp?.destinationPort, "67")
        XCTAssertEqual(dhcp?.protocolName, "UDP")
        XCTAssertEqual(dhcp?.action, .accept)
        XCTAssertEqual(dhcp?.summary, "来自 192.168.1.0/24 · UDP · 端口 67 · 放行")
        XCTAssertTrue(dhcp?.rawText.contains("\"accept\"") ?? false)

        let wan = input?.rules[1]
        XCTAssertEqual(wan?.inputInterface, "wan")
        XCTAssertEqual(wan?.action, .drop)
        XCTAssertEqual(wan?.summary, "任意地址 · 拦截")

        let dstnat = tables[0].chains.first { $0.name == "dstnat" }
        XCTAssertEqual(dstnat?.rules.first?.action, .dnat)
        XCTAssertEqual(dstnat?.rules.first?.action.label, "端口转发")
        XCTAssertEqual(dstnat?.rules.first?.protocolName, "TCP")
    }

    func testNftRulesFromRealRulesetFixture() throws {
        let url = Bundle.module.url(forResource: "nftables-192.168.31.167", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/nftables-192.168.31.167.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        let tables = try ReadOnlyParser.nftablesJSON(text)
        let input = tables[0].chains.first { $0.name == "input" }
        XCTAssertEqual(input?.rules.count, 3)
        XCTAssertEqual(input?.rules.first?.action, .accept)
        XCTAssertEqual(input?.rules.first?.inputInterface, "openbox-tun")
        XCTAssertEqual(input?.rules.first?.comment, "!sing-box: Accept traffic from tun")
    }

    func testNftTextParserKeepsRuleLines() {
        let text = """
        table inet fw4 {
            chain input {
                type filter hook input priority 0; policy drop;
                iifname "lo" accept
                counter packets 5 bytes 400 drop
            }
        }
        """
        let tables = ReadOnlyParser.nftables(text)
        let input = tables[0].chains[0]
        XCTAssertEqual(input.rules.count, 2)
        XCTAssertEqual(input.rules[0].action, .accept)
        XCTAssertEqual(input.rules[1].action, .drop)
        XCTAssertEqual(input.rules[1].packets, 5)
        XCTAssertEqual(input.countedRules, 1)
    }

    // MARK: Wireless scan (U4)

    func testWirelessScanParser() {
        let value: JSONValue = .object(["results": .array([
            .object(["ssid": .string("HomeWiFi"), "bssid": .string("aa:bb:cc:dd:ee:01"),
                     "channel": .number(6), "signal": .number(-55),
                     "encryption": .object(["enabled": .bool(true)])]),
            .object(["ssid": .string(""), "bssid": .string("AA:BB:CC:DD:EE:02"),
                     "channel": .number(6), "signal": .number(-80),
                     "encryption": .object(["enabled": .bool(false)])]),
            .object(["channel": .number(1)])
        ])])
        let entries = WirelessScanParser.results(value, device: "wlan0")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].ssid, "HomeWiFi")
        XCTAssertEqual(entries[0].bssid, "AA:BB:CC:DD:EE:01")
        XCTAssertEqual(entries[0].encrypted, true)
        XCTAssertNil(entries[1].ssid)
        XCTAssertEqual(entries[1].encrypted, false)
        XCTAssertEqual(WirelessScanParser.channelCounts(entries), [6: 2])
    }

    // MARK: Rating scales

    func testChannelGradeBoundaries() {
        XCTAssertEqual(HealthRating.channelGrade(coChannelCount: 0), .excellent)
        XCTAssertEqual(HealthRating.channelGrade(coChannelCount: 2), .good)
        XCTAssertEqual(HealthRating.channelGrade(coChannelCount: 4), .fair)
        XCTAssertEqual(HealthRating.channelGrade(coChannelCount: 7), .poor)
        XCTAssertEqual(HealthRating.channelGrade(coChannelCount: 8), .critical)
    }

    func testSignalFractionScale() {
        XCTAssertEqual(HealthRating.signalFraction(dBm: -30), 1.0, accuracy: 0.001)
        XCTAssertEqual(HealthRating.signalFraction(dBm: -60), 0.5, accuracy: 0.001)
        XCTAssertEqual(HealthRating.signalFraction(dBm: -90), 0.0, accuracy: 0.001)
        XCTAssertEqual(HealthRating.signalFraction(dBm: -120), 0.0, accuracy: 0.001)
    }
}
