import Foundation
import XCTest
@testable import OpenWrtKit

final class SnapshotParserTests: XCTestCase {
    func testLuCIIPv4AndIPv6LeasesIncludingInfiniteLease() throws {
        let data = Data(#"{"dhcp_leases":[{"hostname":"phone","ipaddr":"192.168.1.2","macaddr":"02:00:00:00:00:01","expires":3600}],"dhcp6_leases":[{"hostname":"tablet","ip6addr":"fd00::2","duid":"00010001","expires":-1}]}"#.utf8)
        let leases = try SnapshotParser.leases(JSONDecoder().decode(JSONValue.self, from: data))
        XCTAssertEqual(leases.count, 2)
        XCTAssertEqual(leases.first(where: { $0.hostname == "tablet" })?.address, "fd00::2")
        XCTAssertEqual(leases.first(where: { $0.hostname == "tablet" })?.expires, -1)
        XCTAssertEqual(leases.first(where: { $0.hostname == "tablet" })?.duid, "00010001")
        XCTAssertEqual(leases.first(where: { $0.hostname == "tablet" })?.mac, "—")
    }

    func testSystemLoadUsesUbusFixedPointAndAvailableMemory() throws {
        let data = Data(#"{"uptime":86400,"load":[65536,32768,0],"memory":{"total":1024,"free":64,"available":256}}"#.utf8)
        let info = try JSONDecoder().decode(JSONValue.self, from: data)
        let system = SnapshotParser.system(board: .object([:]), info: info)
        XCTAssertEqual(system.loadAverage, [1, 0.5, 0])
        XCTAssertEqual(system.memoryUsed, 768)
        XCTAssertEqual(system.uptime, 86400)
    }

    func testMissingFieldsStayUnknownRatherThanInventingZero() {
        let system = SnapshotParser.system(board: .object([:]), info: .object([:]))
        XCTAssertNil(system.memoryUsed)
        XCTAssertNil(system.memoryTotal)
        XCTAssertNil(system.uptime)
        XCTAssertTrue(system.loadAverage.isEmpty)
    }

    func testMissingInterfaceStateDoesNotBecomeDisconnected() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"lan"},{"interface":"wan","up":false}]}"#.utf8))
        let interfaces = try SnapshotParser.interfaces(value)
        XCTAssertNil(interfaces.first(where: { $0.name == "lan" })?.up)
        XCTAssertEqual(interfaces.first(where: { $0.name == "wan" })?.up, false)
    }

    func testIPv6PrefixDelegationAndAssignmentRemainDistinctAndTyped() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"wan6","ipv6-prefix":[{"address":"2001:db8:100::","mask":56,"preferred":3600,"valid":7200,"class":"wan","assigned":{"lan":{"address":"2001:db8:100::","mask":64},"guest":{"address":"2001:db8:100:1::","mask":64}}}],"ipv6-prefix-assignment":[{"address":"2001:db8:100::","mask":64,"preferred":3500,"valid":7000,"local-address":{"address":"2001:db8:100::1","mask":64}}]}]}"#.utf8))
        let interfaces = try SnapshotParser.interfaces(value)
        let interface = try XCTUnwrap(interfaces.first)
        XCTAssertEqual(interface.delegatedIPv6Prefixes?.count, 1)
        XCTAssertEqual(interface.delegatedIPv6Prefixes?.first?.prefix.cidr, "2001:db8:100::/56")
        XCTAssertEqual(interface.delegatedIPv6Prefixes?.first?.allocations?.map(\.interfaceName), ["guest", "lan"])
        XCTAssertEqual(interface.assignedIPv6Prefixes?.first?.localAddress?.cidr, "2001:db8:100::1/64")
        XCTAssertEqual(interface.assignedIPv6Prefixes?.first?.preferredLifetime, 3500)
    }

    func testIPv6PrefixMalformedOrInvertedLifetimesFailInsteadOfBecomingEmpty() throws {
        let malformed = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"lan","ipv6-prefix":[{"address":"not-an-ip","mask":64}]}]}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.interfaces(malformed))
        let inverted = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"lan","ipv6-prefix":[{"address":"2001:db8::","mask":64,"preferred":90,"valid":30}]}]}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.interfaces(inverted))
    }

    func testIPv6PrefixMissingEmptyAndDisabledLocalAddressRemainDistinct() throws {
        let missing = try SnapshotParser.ipv6Prefixes(.object([:]), key: "ipv6-prefix")
        XCTAssertNil(missing)
        let empty = try SnapshotParser.ipv6Prefixes(.object(["ipv6-prefix": .array([])]), key: "ipv6-prefix")
        XCTAssertEqual(empty, [])
        let record: JSONValue = .object(["address": .string("::"), "mask": .number(0),
                                         "local-address": .object([:]), "assigned": .object([:])])
        let prefix = try XCTUnwrap(SnapshotParser.ipv6Prefixes(.object(["ipv6-prefix": .array([record])]), key: "ipv6-prefix")?.first)
        XCTAssertTrue(prefix.localAddressReported)
        XCTAssertNil(prefix.localAddress)
        XCTAssertEqual(prefix.allocations, [])
        XCTAssertNil(prefix.preferredLifetime)
        XCTAssertNil(prefix.validLifetime)
    }

    func testIPv6PrefixBoundariesAndMalformedNestedFields() throws {
        let base: [String: JSONValue] = ["address": .string("2001:db8::"), "mask": .number(128),
                                       "preferred": .number(0), "valid": .number(4_294_967_295)]
        func parse(_ fields: [String: JSONValue]) throws -> [InterfaceIPv6Prefix]? {
            try SnapshotParser.ipv6Prefixes(.object(["ipv6-prefix": .array([.object(fields)])]), key: "ipv6-prefix")
        }
        XCTAssertEqual(try parse(base)?.first?.validLifetime, 4_294_967_295)
        let invalid: [(String, JSONValue)] = [
            ("mask", .number(-1)), ("mask", .number(129)), ("mask", .number(64.5)),
            ("preferred", .number(-1)), ("valid", .number(4_294_967_296)), ("valid", .string("3600")),
            ("assigned", .array([])), ("assigned", .object(["lan": .object([:])])),
            ("local-address", .null), ("local-address", .object(["mask": .number(64)])),
            ("class", .number(1)), ("address", .string("192.0.2.1")),
        ]
        for (key, value) in invalid {
            var fields = base; fields[key] = value
            XCTAssertThrowsError(try parse(fields), "Accepted malformed \(key): \(value)")
        }
        XCTAssertThrowsError(try SnapshotParser.ipv6Prefixes(.object(["ipv6-prefix": .null]), key: "ipv6-prefix"))
    }

    func testMissingWirelessFieldsDoNotInventAutomaticChannel() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"radio0":{},"radio1":{"up":false,"config":{"channel":"auto"}}}"#.utf8))
        let radios = try SnapshotParser.wireless(value)
        XCTAssertNil(radios.first(where: { $0.name == "radio0" })?.up)
        XCTAssertEqual(radios.first(where: { $0.name == "radio0" })?.channel, "未报告")
        XCTAssertEqual(radios.first(where: { $0.name == "radio1" })?.up, false)
        XCTAssertEqual(radios.first(where: { $0.name == "radio1" })?.channel, "auto")
    }

    func testMissingServiceInstancesAreNotReportedAsZeroRunning() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"missing":{},"empty":{"instances":{}},"partial":{"instances":{"one":{"running":true},"two":{}}},"reported":{"instances":{"one":{"running":false}}}}"#.utf8))
        let services = try SnapshotParser.services(value)
        XCTAssertNil(services.first(where: { $0.name == "missing" })?.totalInstances)
        XCTAssertNil(services.first(where: { $0.name == "missing" })?.runningInstances)
        XCTAssertEqual(services.first(where: { $0.name == "empty" })?.runningInstances, 0)
        XCTAssertEqual(services.first(where: { $0.name == "partial" })?.totalInstances, 2)
        XCTAssertNil(services.first(where: { $0.name == "partial" })?.runningInstances)
        XCTAssertEqual(services.first(where: { $0.name == "reported" })?.runningInstances, 0)
    }

    func testMalformedInterfaceRowsAreNotSilentlyOmitted() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"lan"},{}]}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.interfaces(value))
        let badAddress = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"interface":[{"interface":"lan","ipv4-address":[{}]}]}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.interfaces(badAddress))
    }

    func testMalformedLeaseListDoesNotLookLikeNoClients() throws {
        let badRow = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"dhcp_leases":[{}]}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.leases(badRow))
        let partial = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"dhcp_leases":[],"dhcp6_leases":{}}"#.utf8))
        XCTAssertThrowsError(try SnapshotParser.leases(partial))
        XCTAssertThrowsError(try SnapshotParser.leases(.object([:])))
        XCTAssertTrue(try SnapshotParser.leases(.object(["dhcp_leases": .array([])])).isEmpty)
    }

    func testRoutingParsersReadKernelRoutesAndMapNeighborsToLogicalInterfaces() throws {
        let interfaces = [NetworkInterfaceSnapshot(name: "lan", protocolName: "static", addresses: [], up: true, device: "br-lan")]
        let routes = try SnapshotParser.routes("default via 192.168.1.1 dev br-lan proto static metric 10\n192.168.1.0/24 dev br-lan proto kernel scope link src 192.168.1.2")
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].destination, "default")
        XCTAssertEqual(routes[0].gateway, "192.168.1.1")
        XCTAssertEqual(routes[0].device, "br-lan")
        XCTAssertEqual(routes[0].metric, "10")

        let neighbors = try SnapshotParser.neighbors("192.168.1.25 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE\n192.168.1.26 dev br-lan INCOMPLETE", interfaces: interfaces)
        XCTAssertEqual(neighbors.count, 2)
        XCTAssertEqual(neighbors[0].interface, "lan")
        XCTAssertEqual(neighbors[0].mac, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(neighbors[0].state, "REACHABLE")
        XCTAssertNil(neighbors[1].mac)
        XCTAssertEqual(neighbors[1].state, "INCOMPLETE")
    }

    func testEmptyRoutingOutputIsAValidEmptyTableAndMalformedNeighborFails() throws {
        XCTAssertTrue(try SnapshotParser.routes("\n").isEmpty)
        XCTAssertTrue(try SnapshotParser.neighbors("", interfaces: []).isEmpty)
        XCTAssertThrowsError(try SnapshotParser.neighbors("192.0.2.1 lladdr aa:bb FAILED", interfaces: []))
        XCTAssertThrowsError(try SnapshotParser.routes("error: unsupported command"))
        XCTAssertThrowsError(try SnapshotParser.routes("default via"))
        XCTAssertThrowsError(try SnapshotParser.routes("123-error dev br-lan"))
        XCTAssertThrowsError(try SnapshotParser.routes("192.0.2.0/33 dev br-lan"))
        XCTAssertThrowsError(try SnapshotParser.routes("default via invalid dev br-lan"))
        XCTAssertThrowsError(try SnapshotParser.routes("default dev br-lan metric unknown"))
        XCTAssertThrowsError(try SnapshotParser.neighbors("192.0.2.1 dev br-lan lladdr FAILED", interfaces: []))
        XCTAssertThrowsError(try SnapshotParser.neighbors("invalid dev br-lan FAILED", interfaces: []))
        XCTAssertThrowsError(try SnapshotParser.neighbors("192.0.2.1 dev br-lan lladdr zz:zz:zz:zz:zz:zz STALE", interfaces: []))
        XCTAssertTrue(try SnapshotParser.routes("  \n\t").isEmpty)
        XCTAssertEqual(try SnapshotParser.routes("unreachable fd00::/64 metric 1024").first?.destination, "fd00::/64")
        XCTAssertEqual(try SnapshotParser.neighbors("fe80::1 dev br-lan lladdr 02:00:00:00:00:01 STALE router", interfaces: []).first?.state, "STALE")
    }

    func testMalformedWirelessAndServiceMapsFailRatherThanInventingEntries() {
        XCTAssertThrowsError(try SnapshotParser.wireless(.object(["radio0": .string("error")])))
        XCTAssertThrowsError(try SnapshotParser.wireless(.object(["radio0": .object(["interfaces": .object([:])])])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .bool(false)])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .object(["instances": .array([])])])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .object(["instances": .object(["one": .null])])])))
    }
}
