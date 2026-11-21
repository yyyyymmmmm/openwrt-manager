import Foundation

/// The navigation registry (spec sections 0.3 and 3). Tabs and pages are
/// generated from the CapabilitySnapshot plus this dedicated-page table —
/// never hardcoded per router. A discovered node with no dedicated page
/// falls back to a generic page and is flagged as such; a node the device
/// does not have never appears.
public enum AppTabID: String, CaseIterable, Equatable, Sendable {
    case overview, network, services, system, settings

    public var title: String {
        switch self {
        case .overview: return KitL10n.text("概览")
        case .network: return KitL10n.text("网络")
        case .services: return KitL10n.text("服务")
        case .system: return KitL10n.text("系统")
        case .settings: return KitL10n.text("设置")
        }
    }
}

public enum PageKind: Equatable, Sendable {
    // Overview (router status group)
    case overviewHome, routesStatus, firewallStatus, logs, processes, realtime, wireguardStatus, channelAnalysis
    // Network
    case interfaces, staticRoutes, dhcp(merged: Bool), dns, diagnostics, speedTest, sqm, firewallConfig, upnp, bandwidthMonitor, wireless
    // Services
    case serviceDedicated(key: String), serviceGeneric(key: String)
    // System
    case packages, startup, crontab, mounts, onlineUpgrade, backupRestore, rebootInfo, adminSecurity
    // Phase 3 native long-tail (not menu-discovered; core router planes)
    case terminal, fileManager
    // Generic fallbacks
    case uci, genericMenuPage
    // App settings
    case profiles, about
}

public struct PageDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var tab: AppTabID
    public var title: String
    public var kind: PageKind
    public var menuPath: String?
    public var serviceKey: String?
    /// UCI configs the page renders (read-only in phase 1).
    public var configNames: [String]
    /// True when this page is the generic fallback for a discovered node
    /// with no dedicated page; the UI must label it as such.
    public var isGenericFallback: Bool

    public init(id: String, tab: AppTabID, title: String, kind: PageKind,
                menuPath: String? = nil, serviceKey: String? = nil,
                configNames: [String] = [], isGenericFallback: Bool = false) {
        self.id = id; self.tab = tab; self.title = title; self.kind = kind
        self.menuPath = menuPath; self.serviceKey = serviceKey
        self.configNames = configNames; self.isGenericFallback = isGenericFallback
    }
}

public struct TabDescriptor: Identifiable, Equatable, Sendable {
    public var tab: AppTabID
    public var pages: [PageDescriptor]
    public var id: String { tab.rawValue }
    public var title: String { tab.title }
    public init(tab: AppTabID, pages: [PageDescriptor]) {
        self.tab = tab; self.pages = pages
    }
}

public enum PageRegistry {
    /// Services with dedicated pages (spec 3.3 P0; package F added the
    /// four whose channels the gap inventory verified end to end,
    /// package F2 the five UCI-shaped services of its first tier —
    /// webdav's page states plainly that its running state has no
    /// source, and zerotier's covers the UCI layer only).
    public static let dedicatedServiceKeys: Set<String> = [
        "openbox", "homeproxy", "mosdns", "ddns", "appfilter", "wol", "vlmcsd",
        "frpc", "natmap", "socat", "zerotier", "webdav"
    ]

    /// Service key -> UCI config name where they differ. socat's LuCI
    /// configuration lives in luci_socat (the plain "socat" file is the
    /// daemon's example config and rpcd does not grant it); dnsmasq and
    /// odhcpd are both configured through the dhcp config on every
    /// OpenWrt — the mapping matters on init.d-fallback routers, where
    /// the service key is the init script name.
    public static let serviceConfigNames: [String: String] = [
        "wol": "etherwake",
        "socat": "luci_socat",
        "dnsmasq": "dhcp",
        "odhcpd": "dhcp"
    ]

    public static func tabs(for snapshot: CapabilitySnapshot) -> [TabDescriptor] {
        [TabDescriptor(tab: .overview, pages: overviewPages(snapshot)),
         TabDescriptor(tab: .network, pages: networkPages(snapshot)),
         TabDescriptor(tab: .services, pages: servicePages(snapshot)),
         TabDescriptor(tab: .system, pages: systemPages(snapshot)),
         TabDescriptor(tab: .settings, pages: settingsPages())]
    }

    /// All five tabs with only the app-local settings pages populated —
    /// used before discovery completes or when it failed without a cache.
    public static func settingsOnlyTabs() -> [TabDescriptor] {
        AppTabID.allCases.map { tab in
            TabDescriptor(tab: tab, pages: tab == .settings ? settingsPages() : [])
        }
    }

    public static func page(id: String, in tabs: [TabDescriptor]) -> PageDescriptor? {
        tabs.flatMap(\.pages).first { $0.id == id }
    }

    // MARK: Overview — the router's status group

    private static func overviewPages(_ snapshot: CapabilitySnapshot) -> [PageDescriptor] {
        var pages = [PageDescriptor(id: "app/overview-home", tab: .overview, title: KitL10n.text("概况"), kind: .overviewHome)]
        guard let group = snapshot.menuNode("admin/status") else { return pages }
        for child in group.children {
            switch child.path {
            case "admin/status/overview":
                continue // the home page covers it
            case "admin/status/ramfree":
                continue // an action, phase 2 — never a phase-1 page
            case "admin/status/routes":
                pages.append(descriptor(child, tab: .overview, kind: .routesStatus))
            case "admin/status/firewall", "admin/status/nftables":
                pages.append(descriptor(child, tab: .overview, kind: .firewallStatus))
            case "admin/status/logs":
                pages.append(descriptor(child, tab: .overview, kind: .logs))
            case "admin/status/processes":
                pages.append(descriptor(child, tab: .overview, kind: .processes))
            case "admin/status/realtime":
                pages.append(descriptor(child, tab: .overview, kind: .realtime))
            case "admin/status/wireguard":
                pages.append(descriptor(child, tab: .overview, kind: .wireguardStatus))
            case "admin/status/channel_analysis":
                pages.append(descriptor(child, tab: .overview, kind: .channelAnalysis))
            default:
                pages.append(descriptor(child, tab: .overview, kind: .genericMenuPage, generic: true))
            }
        }
        return pages
    }

    // MARK: Network — the router's network group

    private static func networkPages(_ snapshot: CapabilitySnapshot) -> [PageDescriptor] {
        guard let group = snapshot.menuNode("admin/network") else { return [] }
        let hasDNSPage = snapshot.menuNode("admin/network/dns") != nil
        var pages: [PageDescriptor] = []
        for child in group.children {
            switch child.path {
            case "admin/network/network":
                pages.append(descriptor(child, tab: .network, kind: .interfaces, configs: ["network"]))
            case "admin/network/routes":
                pages.append(descriptor(child, tab: .network, kind: .staticRoutes, configs: ["network"]))
            case "admin/network/dhcp":
                pages.append(descriptor(child, tab: .network, kind: .dhcp(merged: !hasDNSPage), configs: ["dhcp"]))
            case "admin/network/dns":
                pages.append(descriptor(child, tab: .network, kind: .dns, configs: ["dhcp"]))
            case "admin/network/diagnostics":
                pages.append(descriptor(child, tab: .network, kind: .diagnostics))
            case "admin/network/netspeedtest":
                pages.append(descriptor(child, tab: .network, kind: .speedTest))
            case "admin/network/sqm":
                pages.append(descriptor(child, tab: .network, kind: .sqm, configs: ["sqm"]))
            case "admin/network/firewall":
                pages.append(descriptor(child, tab: .network, kind: .firewallConfig, configs: ["firewall"]))
            case "admin/network/upnp":
                pages.append(descriptor(child, tab: .network, kind: .upnp, configs: ["upnpd"]))
            case "admin/network/nlbw":
                pages.append(descriptor(child, tab: .network, kind: .bandwidthMonitor, configs: ["nlbwmon"]))
            case "admin/network/wireless":
                pages.append(descriptor(child, tab: .network, kind: .wireless, configs: ["wireless"]))
            case "admin/network/switch":
                pages.append(descriptor(child, tab: .network, kind: .uci, configs: ["network"]))
            default:
                let fallback = child.path.split(separator: "/").last.map(String.init) ?? ""
                pages.append(descriptor(child, tab: .network, kind: .uci, configs: [fallback], generic: true))
            }
        }
        return pages
    }

    // MARK: Services — snapshot services, never the package list

    private static func servicePages(_ snapshot: CapabilitySnapshot) -> [PageDescriptor] {
        snapshot.services.map { service in
            let config = serviceConfigNames[service.key] ?? service.key
            if dedicatedServiceKeys.contains(service.key) {
                return PageDescriptor(id: "service/\(service.key)", tab: .services, title: service.title,
                                      kind: .serviceDedicated(key: service.key),
                                      menuPath: service.menuPath, serviceKey: service.key,
                                      configNames: [config])
            }
            return PageDescriptor(id: "service/\(service.key)", tab: .services, title: service.title,
                                  kind: .serviceGeneric(key: service.key),
                                  menuPath: service.menuPath, serviceKey: service.key,
                                  configNames: [config], isGenericFallback: true)
        }
    }

    // MARK: System — the router's system group

    /// Nodes that must never become pages in phase 1: the terminal and the
    /// file manager are phase-3 native work (spec 0A) and get no web or
    /// placeholder entry before then.
    public static let excludedSystemPaths: Set<String> = ["admin/system/ttyd", "admin/system/quickfile"]

    private static func systemPages(_ snapshot: CapabilitySnapshot) -> [PageDescriptor] {
        guard let group = snapshot.menuNode("admin/system") else { return [] }
        var pages: [PageDescriptor] = []
        for child in group.children where !excludedSystemPaths.contains(child.path) {
            switch child.path {
            case "admin/system/system":
                pages.append(descriptor(child, tab: .system, kind: .uci, configs: ["system"]))
            case "admin/system/admin":
                // The administration page (audit F4): password change
                // and SSH authorized keys get their dedicated native
                // page; the dropbear/uhttpd configuration stays one
                // tap inside it, so the configs ride along.
                pages.append(descriptor(child, tab: .system, kind: .adminSecurity, configs: ["dropbear", "uhttpd"]))
            case "admin/system/package-manager":
                pages.append(descriptor(child, tab: .system, kind: .packages))
            case "admin/system/startup":
                pages.append(descriptor(child, tab: .system, kind: .startup))
            case "admin/system/crontab":
                pages.append(descriptor(child, tab: .system, kind: .crontab))
            case "admin/system/mounts", "admin/system/diskman":
                pages.append(descriptor(child, tab: .system, kind: .mounts))
            case "admin/system/leds":
                pages.append(descriptor(child, tab: .system, kind: .uci, configs: ["system"]))
            case "admin/system/ota":
                pages.append(descriptor(child, tab: .system, kind: .onlineUpgrade))
            case "admin/system/flash":
                pages.append(descriptor(child, tab: .system, kind: .backupRestore))
            case "admin/system/argon-config":
                pages.append(descriptor(child, tab: .system, kind: .uci, configs: ["argon"]))
            case "admin/system/autoreboot":
                pages.append(descriptor(child, tab: .system, kind: .uci, configs: ["autoreboot"]))
            case "admin/system/reboot":
                pages.append(descriptor(child, tab: .system, kind: .rebootInfo))
            default:
                pages.append(descriptor(child, tab: .system, kind: .genericMenuPage, generic: true))
            }
        }
        // Phase 3: the native terminal (SSH) and file manager (ubus file)
        // join the system tab as app-provided pages. Their LuCI menu
        // counterparts stay excluded above — these are the native
        // implementations, present on every OpenWrt.
        pages.append(PageDescriptor(id: "app/file-manager", tab: .system, title: KitL10n.text("文件管理"), kind: .fileManager))
        pages.append(PageDescriptor(id: "app/terminal", tab: .system, title: KitL10n.text("终端"), kind: .terminal))
        return pages
    }

    // MARK: Settings — the app itself

    private static func settingsPages() -> [PageDescriptor] {
        [PageDescriptor(id: "app/profiles", tab: .settings, title: KitL10n.text("路由器档案"), kind: .profiles),
         PageDescriptor(id: "app/about", tab: .settings, title: KitL10n.text("关于"), kind: .about)]
    }

    private static func descriptor(_ node: CapabilitySnapshot.MenuNode, tab: AppTabID,
                                   kind: PageKind, configs: [String] = [],
                                   generic: Bool = false) -> PageDescriptor {
        PageDescriptor(id: node.path, tab: tab, title: node.title, kind: kind,
                       menuPath: node.path, configNames: configs, isGenericFallback: generic)
    }
}
