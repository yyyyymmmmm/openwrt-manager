#if DEBUG
import Foundation
import OpenWrtKit

/// Launch-argument seeding for the XCUITest suite (package A). This is
/// the only test seam in the app target and it exists solely in DEBUG
/// builds: Release binaries — including the shipped unsigned IPA —
/// compile this entire file and its store hook out.
///
/// Two arguments, passed by the UI tests at launch:
///   -ZiroxSeedProfiles   two saved profiles, no connection: the
///                        profile list and the connect form render
///                        exactly as they do for a returning user.
///   -ZiroxSeedConnected  additionally an active profile plus the
///                        capability snapshot below, so the five tabs
///                        render with no network at all. Nothing here
///                        can talk to a router: the store is seeded
///                        after init and no transport is ever created.
///
/// The snapshot data is derived from the verified 192.168.31.1 haul
/// kept as a kit test fixture (same menu, services, interfaces and
/// wireless state), trimmed only where volume is irrelevant to what
/// the UI tests assert (the package list).
enum UITestingSeed {
    static let profilesArgument = "-ZiroxSeedProfiles"
    static let connectedArgument = "-ZiroxSeedConnected"

    @MainActor
    static func applyIfNeeded(to store: RouterStore) {
        let arguments = ProcessInfo.processInfo.arguments
        let connected = arguments.contains(connectedArgument)
        guard connected || arguments.contains(profilesArgument) else { return }
        let profiles = seededProfiles
        store.installSeededState(
            profiles: profiles,
            activeProfile: connected ? profiles[0] : nil,
            capability: connected
                ? CapabilitySnapshot(collected: seededCollected(routerID: profiles[0].id.uuidString,
                                                                address: "192.168.31.1"))
                : nil)
    }

    static var seededProfiles: [RouterProfile] {
        [
            RouterProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                          name: "Home Router", address: "http://192.168.31.1",
                          username: "root", rememberPassword: false),
            RouterProfile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                          name: "Side Router", address: "http://192.168.31.167",
                          username: "root", rememberPassword: false),
        ]
    }

    static func seededCollected(routerID: String, address: String) -> CollectedRouterSnapshot {
        CollectedRouterSnapshot(
            device: .init(id: routerID, address: address, role: "main"),
            collectedAt: "2026-11-20T23:00:10.207214+08:00",
            firmwareFields: ["DISTRIB_ARCH": "aarch64_cortex-a53", "DISTRIB_DESCRIPTION": "OpenWrt 24.10.8 r29233-443ec4032a", "DISTRIB_ID": "OpenWrt", "DISTRIB_RELEASE": "24.10.8", "DISTRIB_REVISION": "r29233-443ec4032a", "DISTRIB_TAINTS": "", "DISTRIB_TARGET": "mediatek/filogic"],
            board: .init(
                hostname: "OpenWrt", model: "Xiaomi Mi Router AX3000T", boardName: "xiaomi,mi-router-ax3000t",
                kernel: "6.6.144", system: "ARMv8 Processor rev 4", rootfsType: "squashfs",
                release: .init(distribution: "OpenWrt", version: "24.10.8", revision: "r29233-443ec4032a", target: "mediatek/filogic", description: "OpenWrt 24.10.8 r29233-443ec4032a")),
            menuFiles: ["luci-app-argon-config.json", "luci-app-firewall.json", "luci-app-package-manager.json", "luci-base.json", "luci-mod-network.json", "luci-mod-status.json", "luci-mod-system.json"],
            menuPaths: [
                "admin",
                "admin/logout",
                "admin/menu",
                "admin/network",
                "admin/network/dhcp",
                "admin/network/diagnostics",
                "admin/network/firewall",
                "admin/network/firewall/custom",
                "admin/network/firewall/forwards",
                "admin/network/firewall/ipsets",
                "admin/network/firewall/rules",
                "admin/network/firewall/snats",
                "admin/network/firewall/zones",
                "admin/network/network",
                "admin/network/remote_addr/*",
                "admin/network/routes",
                "admin/network/switch",
                "admin/network/wireless",
                "admin/services",
                "admin/status",
                "admin/status/channel_analysis",
                "admin/status/iptables",
                "admin/status/logs",
                "admin/status/logs/dmesg",
                "admin/status/logs/syslog",
                "admin/status/nftables",
                "admin/status/nftables/iptables",
                "admin/status/overview",
                "admin/status/processes",
                "admin/status/realtime",
                "admin/status/realtime/bandwidth",
                "admin/status/realtime/connections",
                "admin/status/realtime/load",
                "admin/status/realtime/wireless",
                "admin/status/routes",
                "admin/system",
                "admin/system/admin",
                "admin/system/admin/dropbear",
                "admin/system/admin/password",
                "admin/system/admin/repokeys",
                "admin/system/admin/sshkeys",
                "admin/system/admin/uhttpd",
                "admin/system/argon-config",
                "admin/system/crontab",
                "admin/system/flash",
                "admin/system/leds",
                "admin/system/mounts",
                "admin/system/package-manager",
                "admin/system/reboot",
                "admin/system/startup",
                "admin/system/system",
                "admin/translations/*",
                "admin/ubus/*",
                "admin/uci",
                "admin/uci/apply_rollback",
                "admin/uci/apply_unchecked",
                "admin/uci/confirm",
                "admin/uci/revert",
                "admin/vpn",
            ],
            menuTree: [
                "admin": .init(title: "Administration", order: 10, file: "luci-base.json"),
                "admin/logout": .init(title: "Log out", order: 999, file: "luci-base.json"),
                "admin/menu": .init(file: "luci-base.json"),
                "admin/network": .init(title: "Network", order: 50, file: "luci-base.json"),
                "admin/network/dhcp": .init(title: "DHCP and DNS", order: 40, file: "luci-mod-network.json"),
                "admin/network/diagnostics": .init(title: "Diagnostics", order: 50, file: "luci-mod-network.json"),
                "admin/network/firewall": .init(title: "Firewall", order: 60, file: "luci-app-firewall.json"),
                "admin/network/firewall/custom": .init(title: "Custom Rules", order: 50, file: "luci-app-firewall.json"),
                "admin/network/firewall/forwards": .init(title: "Port Forwards", order: 20, file: "luci-app-firewall.json"),
                "admin/network/firewall/ipsets": .init(title: "IP Sets", order: 45, file: "luci-app-firewall.json"),
                "admin/network/firewall/rules": .init(title: "Traffic Rules", order: 30, file: "luci-app-firewall.json"),
                "admin/network/firewall/snats": .init(title: "NAT Rules", order: 40, file: "luci-app-firewall.json"),
                "admin/network/firewall/zones": .init(title: "General Settings", order: 10, file: "luci-app-firewall.json"),
                "admin/network/network": .init(title: "Interfaces", order: 10, file: "luci-mod-network.json"),
                "admin/network/remote_addr/*": .init(file: "luci-mod-network.json"),
                "admin/network/routes": .init(title: "Routing", order: 30, file: "luci-mod-network.json"),
                "admin/network/switch": .init(title: "Switch", order: 20, file: "luci-mod-network.json"),
                "admin/network/wireless": .init(title: "Wireless", order: 15, file: "luci-mod-network.json"),
                "admin/services": .init(title: "Services", order: 40, file: "luci-base.json"),
                "admin/status": .init(title: "Status", order: 10, file: "luci-base.json"),
                "admin/status/channel_analysis": .init(title: "Channel Analysis", order: 7, file: "luci-mod-status.json"),
                "admin/status/iptables": .init(title: "Firewall", order: 3, file: "luci-mod-status.json"),
                "admin/status/logs": .init(title: "System Log", order: 4, file: "luci-mod-status.json"),
                "admin/status/logs/dmesg": .init(title: "Kernel Log", order: 2, file: "luci-mod-status.json"),
                "admin/status/logs/syslog": .init(title: "System Log", order: 1, file: "luci-mod-status.json"),
                "admin/status/nftables": .init(title: "Firewall", order: 3, file: "luci-mod-status.json"),
                "admin/status/nftables/iptables": .init(file: "luci-mod-status.json"),
                "admin/status/overview": .init(title: "Overview", order: 1, file: "luci-mod-status.json"),
                "admin/status/processes": .init(title: "Processes", order: 6, file: "luci-mod-status.json"),
                "admin/status/realtime": .init(title: "Realtime Graphs", order: 7, file: "luci-mod-status.json"),
                "admin/status/realtime/bandwidth": .init(title: "Bandwidth", order: 2, file: "luci-mod-status.json"),
                "admin/status/realtime/connections": .init(title: "Connections", order: 4, file: "luci-mod-status.json"),
                "admin/status/realtime/load": .init(title: "Load", order: 1, file: "luci-mod-status.json"),
                "admin/status/realtime/wireless": .init(title: "Wireless", order: 3, file: "luci-mod-status.json"),
                "admin/status/routes": .init(title: "Routing", order: 2, file: "luci-mod-status.json"),
                "admin/system": .init(title: "System", order: 20, file: "luci-base.json"),
                "admin/system/admin": .init(title: "Administration", order: 2, file: "luci-mod-system.json"),
                "admin/system/admin/dropbear": .init(title: "SSH Access", order: 2, file: "luci-mod-system.json"),
                "admin/system/admin/password": .init(title: "Router Password", order: 1, file: "luci-mod-system.json"),
                "admin/system/admin/repokeys": .init(title: "Repo Public Keys", order: 5, file: "luci-mod-system.json"),
                "admin/system/admin/sshkeys": .init(title: "SSH-Keys", order: 3, file: "luci-mod-system.json"),
                "admin/system/admin/uhttpd": .init(title: "HTTP(S) Access", order: 4, file: "luci-mod-system.json"),
                "admin/system/argon-config": .init(title: "Argon Config", order: 90, file: "luci-app-argon-config.json"),
                "admin/system/crontab": .init(title: "Scheduled Tasks", order: 46, file: "luci-mod-system.json"),
                "admin/system/flash": .init(title: "Backup / Flash Firmware", order: 70, file: "luci-mod-system.json"),
                "admin/system/leds": .init(title: "LED Configuration", order: 60, file: "luci-mod-system.json"),
                "admin/system/mounts": .init(title: "Mount Points", order: 50, file: "luci-mod-system.json"),
                "admin/system/package-manager": .init(title: "Software", order: 30, file: "luci-app-package-manager.json"),
                "admin/system/reboot": .init(title: "Reboot", order: 90, file: "luci-mod-system.json"),
                "admin/system/startup": .init(title: "Startup", order: 45, file: "luci-mod-system.json"),
                "admin/system/system": .init(title: "System", order: 1, file: "luci-mod-system.json"),
                "admin/translations/*": .init(file: "luci-base.json"),
                "admin/ubus/*": .init(file: "luci-base.json"),
                "admin/uci": .init(file: "luci-base.json"),
                "admin/uci/apply_rollback": .init(file: "luci-base.json"),
                "admin/uci/apply_unchecked": .init(file: "luci-base.json"),
                "admin/uci/confirm": .init(file: "luci-base.json"),
                "admin/uci/revert": .init(file: "luci-base.json"),
                "admin/vpn": .init(title: "VPN", order: 70, file: "luci-base.json"),
            ],
            installedPackages: ["luci", "luci-app-argon-config", "luci-app-firewall", "luci-app-package-manager", "luci-base", "luci-i18n-argon-config-zh-cn", "luci-i18n-base-zh-cn", "luci-i18n-firewall-zh-cn", "luci-light", "luci-mod-admin-full", "luci-mod-network", "luci-mod-status", "luci-mod-system", "luci-proto-ipv6", "luci-proto-ppp", "luci-ssl", "luci-theme-argon", "luci-theme-bootstrap"],
            installedApps: ["luci-app-argon-config", "luci-app-firewall", "luci-app-package-manager"],
            services: [
                .init(name: "boot", enabled: true),
                .init(name: "bootcount", enabled: true),
                .init(name: "cron", enabled: true),
                .init(name: "dnsmasq", enabled: true, running: true),
                .init(name: "done", enabled: true),
                .init(name: "dropbear", enabled: true, running: true),
                .init(name: "firewall", enabled: true),
                .init(name: "gpio_switch", enabled: true),
                .init(name: "keepalived", enabled: true, running: true),
                .init(name: "led", enabled: true),
                .init(name: "log", enabled: true, running: true),
                .init(name: "network", enabled: true, running: true),
                .init(name: "odhcpd", enabled: true, running: true),
                .init(name: "packet_steering", enabled: true),
                .init(name: "rpcd", enabled: true, running: true),
                .init(name: "sysctl", enabled: true),
                .init(name: "sysfixtime", enabled: true),
                .init(name: "sysntpd", enabled: true, running: true),
                .init(name: "system", enabled: true),
                .init(name: "ubihealthd", enabled: true, running: true),
                .init(name: "ubus", enabled: false, running: true),
                .init(name: "ucitrack", enabled: true),
                .init(name: "uhttpd", enabled: true, running: true),
                .init(name: "urandom_seed", enabled: true, running: false),
                .init(name: "urngd", enabled: true, running: true),
                .init(name: "wpad", enabled: true, running: true),
            ],
            interfaces: [
                .init(name: "lan", up: true, available: true, pending: false, proto: "static", device: "br-lan", l3Device: "br-lan", ipv4: ["192.168.31.1"], ipv6: [], routes: [], dns: []),
                .init(name: "loopback", up: true, available: true, pending: false, proto: "static", device: "lo", l3Device: "lo", ipv4: ["127.0.0.1"], ipv6: [], routes: [], dns: []),
                .init(name: "wan", up: true, available: true, pending: false, proto: "dhcp", device: "wan", l3Device: "wan", ipv4: ["192.168.1.2"], ipv6: [], routes: [.init(target: "0.0.0.0", mask: 0, nexthop: "192.168.1.1", source: "192.168.1.2/32")], dns: ["192.168.1.1"]),
                .init(name: "wan6", up: true, available: true, pending: false, proto: "dhcpv6", device: "wan", l3Device: "wan", ipv4: [], ipv6: ["2409:8a70:1856:2bb0::2", "2409:8a70:1856:2bb0:46f7:70ff:fe79:43a8"], routes: [.init(target: "2409:8a70:1856:2bb0::", mask: 64, nexthop: "::", source: "::/0"), .init(target: "2409:8a70:1856:2bb0::", mask: 64, nexthop: "fe80::1", source: "::/0"), .init(target: "::", mask: 0, nexthop: "fe80::1", source: "2409:8a70:1856:2bb0:46f7:70ff:fe79:43a8/64"), .init(target: "::", mask: 0, nexthop: "fe80::1", source: "2409:8a70:1856:2bb1::/64"), .init(target: "::", mask: 0, nexthop: "fe80::1", source: "2409:8a70:1856:2bb0::2/128")], dns: ["fe80::1"]),
            ],
            wireless: .init(present: true, radios: [.init(name: "radio0", up: true, disabled: false, band: "2g"), .init(name: "radio1", up: true, disabled: false, band: "5g")], phys: ["phy0", "phy1"]),
            language: "source")
    }
}
#endif
