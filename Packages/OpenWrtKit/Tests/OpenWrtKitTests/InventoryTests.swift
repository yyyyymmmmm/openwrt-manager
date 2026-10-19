import XCTest
@testable import OpenWrtKit

final class InventoryTests: XCTestCase {
    func testUnknownPluginsAreIncludedEvenWithoutMenusOrRunningServices() {
        var inventory = RouterInventory()
        inventory.packages = [.init(name: "luci-app-never-seen", version: "2.0"), .init(name: "kernel", version: "6")]
        XCTAssertEqual(inventory.plugins.map(\.id), ["luci-app-never-seen"])
        XCTAssertEqual(inventory.plugins.first?.package.version, "2.0")
    }

    func testOwnershipFollowsDependenciesWithoutAttributingSharedConfig() {
        var inventory = RouterInventory()
        inventory.packages = [
            .init(name: "luci-app-example", version: "1", dependencies: ["example>=2", "luci-base"]),
            .init(name: "example", version: "2", dependencies: ["luci-app-example"], files: ["/etc/config/example", "etc/init.d/example"]),
            .init(name: "luci-base", version: "1", files: ["etc/config/system"])
        ]
        inventory.configNames = ["example", "system"]
        XCTAssertEqual(inventory.plugins.first?.configs, ["example"])
        XCTAssertEqual(inventory.plugins.first?.serviceNames, ["example"])
    }

    func testMenuFiltersUnsatisfiedAndActionRoutes() throws {
        let menu: JSONValue = .object(["children": .object(["admin": .object(["children": .object([
            "network": .object(["title": .string("Network"), "children": .object([
                "wireless": .object(["title": .string("Wi-Fi"), "satisfied": .bool(false)]),
                "interfaces": .object(["title": .string("Interfaces"), "depends": .object(["uci": .object(["network": .bool(true)])])]),
                "delete": .object(["title": .string("Delete"), "action": .object(["post": .bool(true)])])
            ])]),
            "logout": .object(["title": .string("Logout")])
        ])])])])
        let entries = try InventoryParser.menus(menu)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].children.map(\.id), ["admin/network/interfaces"])
        XCTAssertEqual(entries[0].children[0].configs, ["network"])
    }

    func testPackageManagerStructuredResponse() throws {
        let value: JSONValue = .array([.object([
            "name": .string("luci-app-test"), "version": .string("1-r2"), "depends": .array([.string("test")]),
            "contents": .array([.string("etc/config/test")])
        ])])
        let packages = try InventoryParser.packages(value)
        XCTAssertEqual(packages.first?.name, "luci-app-test")
        XCTAssertEqual(packages.first?.dependencies, ["test"])
        XCTAssertThrowsError(try InventoryParser.packages(.object([:])))
    }

    func testOpkgAndConfigurationNames() throws {
        XCTAssertEqual(try InventoryParser.opkg("one - 1.0 - Description - more\ntwo - 2.0").count, 2)
        let names = try InventoryParser.configNames(.object(["entries": .array([
            .object(["name": .string("system"), "type": .string("file")]),
            .object(["name": .string("system.bak"), "type": .string("file")]),
            .object(["name": .string("directory"), "type": .string("directory")])
        ])]))
        XCTAssertEqual(names, ["system"])
    }
}
