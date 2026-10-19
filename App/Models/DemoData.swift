import Foundation
import OpenWrtKit

/// Explicitly synthetic data. Used only by the opt-in demo and UI tests.
enum DemoData {
    static var snapshot: RouterSnapshot {
        var value = RouterSnapshot()
        value.system.hostname = "OpenWrt · 演示"
        value.system.model = "示例路由器"
        value.system.firmware = "OpenWrt 24.10 · 示例"
        value.system.kernel = "6.6 · 示例"
        value.system.architecture = "aarch64 · 示例"
        value.system.uptime = 309_612
        value.system.memoryTotal = 512 * 1024 * 1024
        value.system.memoryUsed = 185 * 1024 * 1024
        value.system.loadAverage = [0.12, 0.08, 0.04]
        value.interfaces = [
            .init(name: "lan", protocolName: "static", addresses: ["192.168.1.1/24", "fd00::1/64"], up: true, device: "br-lan"),
            .init(name: "wan", protocolName: "dhcp", addresses: ["192.0.2.24/24"], up: true, device: "eth1"),
            .init(name: "guest", protocolName: "static", addresses: ["192.168.3.1/24"], up: false, device: "br-guest")
        ]
        return value
    }

    static let leases: [DHCPLease] = [
        .init(hostname: "我的 iPhone", address: "192.168.1.102", mac: "02:00:00:00:00:01", expires: 39_620),
        .init(hostname: "书房电脑", address: "192.168.1.108", mac: "02:00:00:00:00:02", expires: 24_600),
        .init(hostname: "客厅音箱", address: "192.168.1.115", mac: "02:00:00:00:00:03", expires: -1)
    ]
    static let radios: [WirelessRadio] = [
        .init(name: "radio0", up: true, channel: "6", networks: ["Home · 2.4 GHz"]),
        .init(name: "radio1", up: true, channel: "149", networks: ["Home · 5 GHz", "Guest"])
    ]
    static let services: [RouterService] = [
        .init(name: "dnsmasq", runningInstances: 1, totalInstances: 1),
        .init(name: "dropbear", runningInstances: 1, totalInstances: 1),
        .init(name: "uhttpd", runningInstances: 1, totalInstances: 1)
    ]
}
