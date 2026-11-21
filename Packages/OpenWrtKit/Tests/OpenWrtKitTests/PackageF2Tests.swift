import XCTest
@testable import OpenWrtKit

/// Package F2: dedicated pages for the UCI-shaped services (frpc,
/// natmap, socat, zerotier, webdav). Fixtures follow the option names
/// the services' own LuCI apps write, per the gap inventory's live
/// probes of the bypass router's configurations.
final class PackageF2Tests: XCTestCase {

    private func config(_ name: String, _ sections: [ConfigurationSection]) -> RouterConfiguration {
        RouterConfiguration(name: name, sections: sections)
    }

    // MARK: Secret recognition

    func testSecretOptionNames() {
        for name in ["password", "passwd", "token", "auth_token", "oidc_client_secret",
                     "user_password", "private_key"] {
            XCTAssertTrue(DedicatedSecret.isSecretOption(name), name)
        }
        for name in ["server_addr", "listen_port", "username", "network", "root_dir"] {
            XCTAssertFalse(DedicatedSecret.isSecretOption(name), name)
        }
    }

    func testSecretIsSet() {
        let section = ConfigurationSection(id: "common", type: "conf", values: [
            "token": .string("abc"), "empty": .string("")
        ])
        XCTAssertTrue(DedicatedSecret.isSet(section, optionNames: ["token"]))
        XCTAssertFalse(DedicatedSecret.isSet(section, optionNames: ["empty"]))
        XCTAssertFalse(DedicatedSecret.isSet(section, optionNames: ["missing"]))
    }

    // MARK: frpc

    func testFrpcParse() {
        let overview = FrpcParser.parse(config("frpc", [
            ConfigurationSection(id: "common", type: "conf", values: [
                "server_addr": .string("frp.example.com"),
                "server_port": .string("7000"),
                "token": .string("do-not-leak")
            ]),
            ConfigurationSection(id: "ssh", type: "conf", values: [
                "name": .string("SSH"),
                "type": .string("tcp"),
                "local_ip": .string("192.168.31.10"),
                "local_port": .string("22"),
                "remote_port": .string("6000"),
                "enabled": .string("1")
            ]),
            ConfigurationSection(id: "web", type: "conf", values: [
                "type": .string("http"),
                "local_port": .number(80),
                "subdomain": .string("home")
            ])
        ]))
        XCTAssertEqual(overview.server?.endpointText, "frp.example.com:7000")
        XCTAssertEqual(overview.server?.hasToken, true)
        XCTAssertEqual(overview.tunnels.map(\.sectionID), ["ssh", "web"])
        XCTAssertEqual(overview.tunnels[0].name, "SSH")
        XCTAssertEqual(overview.tunnels[0].localText, "192.168.31.10:22")
        XCTAssertEqual(overview.tunnels[0].remotePort, "6000")
        XCTAssertEqual(overview.tunnels[0].enabled, true)
        XCTAssertEqual(overview.tunnels[1].name, "web")
        XCTAssertEqual(overview.tunnels[1].localText, "80")
        XCTAssertEqual(overview.tunnels[1].domains, ["home"])
    }

    func testFrpcServerFoundByOptionsAndEmptyConfig() {
        let overview = FrpcParser.parse(config("frpc", [
            ConfigurationSection(id: "main", type: "frpc", values: [
                "server_addr": .string("10.0.0.1")
            ])
        ]))
        XCTAssertEqual(overview.server?.sectionID, "main")
        XCTAssertEqual(overview.server?.hasToken, false)
        XCTAssertTrue(overview.tunnels.isEmpty)
        let empty = FrpcParser.parse(config("frpc", []))
        XCTAssertNil(empty.server)
        XCTAssertTrue(empty.tunnels.isEmpty)
    }

    // MARK: natmap

    func testNatmapParse() {
        let entries = NatmapParser.parse(config("natmap", [
            ConfigurationSection(id: "main", type: "natmap", values: [
                "enable": .string("1"),
                "stun_server": .string("stun.example.com"),
                "port": .string("3456"),
                "http_server": .string("http://keep.example.com"),
                "family": .string("ipv4")
            ]),
            ConfigurationSection(id: "bare", type: "natmap", values: [:])
        ]))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].enabled, true)
        XCTAssertEqual(entries[0].stunServer, "stun.example.com")
        XCTAssertEqual(entries[0].port, "3456")
        XCTAssertEqual(entries[0].keepAliveTarget, "http://keep.example.com")
        XCTAssertEqual(entries[0].family, "ipv4")
        XCTAssertNil(entries[1].enabled)
        XCTAssertNil(entries[1].stunServer)
    }

    // MARK: socat

    func testSocatParse() {
        let rules = SocatParser.parse(config("luci_socat", [
            ConfigurationSection(id: "cfg1", type: "socat", anonymous: true, values: [
                "remarks": .string("NAS 转发"),
                "enable": .string("0"),
                "protocol": .string("tcp4"),
                "listen_port": .string("8080"),
                "dest_ip": .string("192.168.31.20"),
                "dest_port": .string("80")
            ])
        ]))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].remarks, "NAS 转发")
        XCTAssertEqual(rules[0].enabled, false)
        XCTAssertEqual(rules[0].listenPort, "8080")
        XCTAssertEqual(rules[0].destinationText, "192.168.31.20:80")
        XCTAssertTrue(SocatParser.parse(config("luci_socat", [])).isEmpty)
    }

    // MARK: zerotier

    func testZeroTierSectionForm() {
        let overview = ZeroTierParser.parse(config("zerotier", [
            ConfigurationSection(id: "default", type: "zerotier", values: [
                "enabled": .string("1"),
                "secret": .string("do-not-leak")
            ]),
            ConfigurationSection(id: "net1", type: "network", anonymous: true, values: [
                "id": .string("a1b2c3d4e5f60718"),
                "allow_managed": .string("1"),
                "allow_dns": .string("0")
            ])
        ]))
        XCTAssertEqual(overview.enabled, true)
        XCTAssertEqual(overview.switchLocation?.sectionID, "default")
        XCTAssertEqual(overview.networks.count, 1)
        XCTAssertEqual(overview.networks[0].networkID, "a1b2c3d4e5f60718")
        XCTAssertEqual(overview.networks[0].storage, .section(id: "net1"))
        XCTAssertEqual(overview.networks[0].allowManaged, true)
        XCTAssertEqual(overview.networks[0].allowDNS, false)
        XCTAssertTrue(overview.networks[0].hasAllowFlags)
        XCTAssertEqual(overview.joinTarget, .newSection)
    }

    func testZeroTierListForm() {
        let overview = ZeroTierParser.parse(config("zerotier", [
            ConfigurationSection(id: "sample", type: "zerotier", values: [
                "enabled": .string("0"),
                "network": .array([.string("1111111111111111"), .string("2222222222222222")])
            ])
        ]))
        XCTAssertEqual(overview.enabled, false)
        XCTAssertEqual(overview.networks.map(\.networkID),
                       ["1111111111111111", "2222222222222222"])
        XCTAssertEqual(overview.networks[0].storage,
                       .listValue(sectionID: "sample", option: "network"))
        XCTAssertFalse(overview.networks[0].hasAllowFlags)
        XCTAssertEqual(overview.joinTarget, .listOption(sectionID: "sample", option: "network"))
    }

    func testZeroTierNetworkIDValidation() {
        XCTAssertTrue(ZeroTierParser.isValidNetworkID("a1b2c3d4e5f60718"))
        XCTAssertTrue(ZeroTierParser.isValidNetworkID(" A1B2C3D4E5F60718 "))
        XCTAssertFalse(ZeroTierParser.isValidNetworkID("a1b2c3d4"))
        XCTAssertFalse(ZeroTierParser.isValidNetworkID("zzzzzzzzzzzzzzzz"))
        XCTAssertFalse(ZeroTierParser.isValidNetworkID(""))
    }

    // MARK: webdav

    func testWebdavParse() {
        let settings = WebdavParser.parse(config("webdav", [
            ConfigurationSection(id: "main", type: "webdav", values: [
                "enable": .string("1"),
                "listen_port": .string("8080"),
                "root_dir": .string("/mnt/data"),
                "ssl": .string("0"),
                "allow_wan": .string("0"),
                "username": .string("admin"),
                "password": .string("do-not-leak")
            ])
        ]))
        XCTAssertEqual(settings?.enabled, true)
        XCTAssertEqual(settings?.listenPort, "8080")
        XCTAssertEqual(settings?.rootDir, "/mnt/data")
        XCTAssertEqual(settings?.ssl, false)
        XCTAssertEqual(settings?.allowWAN, false)
        XCTAssertEqual(settings?.username, "admin")
        XCTAssertEqual(settings?.hasPassword, true)
        XCTAssertNil(WebdavParser.parse(config("webdav", [])))
    }
}
