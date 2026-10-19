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

    func testMalformedWirelessAndServiceMapsFailRatherThanInventingEntries() {
        XCTAssertThrowsError(try SnapshotParser.wireless(.object(["radio0": .string("error")])))
        XCTAssertThrowsError(try SnapshotParser.wireless(.object(["radio0": .object(["interfaces": .object([:])])])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .bool(false)])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .object(["instances": .array([])])])))
        XCTAssertThrowsError(try SnapshotParser.services(.object(["service": .object(["instances": .object(["one": .null])])])))
    }
}
