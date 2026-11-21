import Foundation

// MARK: - Collected form
//
// The raw discovery haul, before any navigation rules are applied. This shape
// mirrors what the on-device data plane provides (ubus system board,
// network.interface dump, network.wireless status, menu.d enumeration,
// package list, rc.d + procd service state) and is the exact shape of the
// collected real-router snapshots kept as test fixtures, so live discovery
// and fixture-driven tests share one pipeline.

public struct CollectedRouterSnapshot: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public var id: String
        public var address: String
        public var role: String?
        public init(id: String, address: String, role: String? = nil) {
            self.id = id; self.address = address; self.role = role
        }
    }

    public struct Board: Codable, Equatable, Sendable {
        public struct Release: Codable, Equatable, Sendable {
            public var distribution: String?
            public var version: String?
            public var revision: String?
            public var target: String?
            public var description: String?
            public init(distribution: String? = nil, version: String? = nil, revision: String? = nil,
                        target: String? = nil, description: String? = nil) {
                self.distribution = distribution; self.version = version; self.revision = revision
                self.target = target; self.description = description
            }
        }
        public var hostname: String?
        public var model: String?
        public var boardName: String?
        public var kernel: String?
        public var system: String?
        public var rootfsType: String?
        public var release: Release?
        public init(hostname: String? = nil, model: String? = nil, boardName: String? = nil,
                    kernel: String? = nil, system: String? = nil, rootfsType: String? = nil,
                    release: Release? = nil) {
            self.hostname = hostname; self.model = model; self.boardName = boardName
            self.kernel = kernel; self.system = system; self.rootfsType = rootfsType
            self.release = release
        }
        private enum CodingKeys: String, CodingKey {
            case hostname, model, kernel, system, release
            case boardName = "board_name"
            case rootfsType = "rootfs_type"
        }
    }

    public struct MenuEntryInfo: Codable, Equatable, Sendable {
        /// Raw menu.d entries for endpoints and some apps carry no title
        /// or order at all; both stay optional rather than invented.
        public var title: String?
        public var order: Int?
        public var file: String?
        public init(title: String? = nil, order: Int? = nil, file: String? = nil) {
            self.title = title; self.order = order; self.file = file
        }
    }

    public struct InitServiceState: Codable, Equatable, Sendable {
        public var name: String
        public var enabled: Bool?
        public var running: Bool?
        public init(name: String, enabled: Bool? = nil, running: Bool? = nil) {
            self.name = name; self.enabled = enabled; self.running = running
        }
    }

    public struct Route: Codable, Equatable, Sendable {
        public var target: String
        public var mask: Int?
        public var nexthop: String?
        public var source: String?
        public init(target: String, mask: Int? = nil, nexthop: String? = nil, source: String? = nil) {
            self.target = target; self.mask = mask; self.nexthop = nexthop; self.source = source
        }
    }

    public struct InterfaceState: Codable, Equatable, Sendable {
        public var name: String
        public var up: Bool?
        public var available: Bool?
        public var pending: Bool?
        public var proto: String?
        public var device: String?
        public var l3Device: String?
        public var ipv4: [String]
        public var ipv6: [String]
        public var routes: [Route]
        public var dns: [String]
        public init(name: String, up: Bool? = nil, available: Bool? = nil, pending: Bool? = nil,
                    proto: String? = nil, device: String? = nil, l3Device: String? = nil,
                    ipv4: [String] = [], ipv6: [String] = [], routes: [Route] = [], dns: [String] = []) {
            self.name = name; self.up = up; self.available = available; self.pending = pending
            self.proto = proto; self.device = device; self.l3Device = l3Device
            self.ipv4 = ipv4; self.ipv6 = ipv6; self.routes = routes; self.dns = dns
        }
        private enum CodingKeys: String, CodingKey {
            case name, up, available, pending, proto, device, ipv4, ipv6, routes, dns
            case l3Device = "l3_device"
        }
    }

    public struct Radio: Codable, Equatable, Sendable {
        public var name: String
        public var up: Bool?
        public var disabled: Bool?
        public var band: String?
        public init(name: String, up: Bool? = nil, disabled: Bool? = nil, band: String? = nil) {
            self.name = name; self.up = up; self.disabled = disabled; self.band = band
        }
    }

    public struct WirelessState: Codable, Equatable, Sendable {
        public var present: Bool
        public var radios: [Radio]
        public var phys: [String]
        public init(present: Bool, radios: [Radio] = [], phys: [String] = []) {
            self.present = present; self.radios = radios; self.phys = phys
        }
    }

    public var device: Device
    public var collectedAt: String
    public var firmwareFields: [String: String]
    public var board: Board
    public var menuFiles: [String]
    public var menuPaths: [String]
    public var menuTree: [String: MenuEntryInfo]
    public var installedPackages: [String]
    public var installedApps: [String]
    public var services: [InitServiceState]
    public var interfaces: [InterfaceState]
    public var wireless: WirelessState

    public init(device: Device, collectedAt: String, firmwareFields: [String: String] = [:],
                board: Board, menuFiles: [String] = [], menuPaths: [String],
                menuTree: [String: MenuEntryInfo] = [:], installedPackages: [String] = [],
                installedApps: [String] = [], services: [InitServiceState] = [],
                interfaces: [InterfaceState] = [], wireless: WirelessState) {
        self.device = device; self.collectedAt = collectedAt; self.firmwareFields = firmwareFields
        self.board = board; self.menuFiles = menuFiles; self.menuPaths = menuPaths
        self.menuTree = menuTree; self.installedPackages = installedPackages
        self.installedApps = installedApps; self.services = services
        self.interfaces = interfaces; self.wireless = wireless
    }

    private enum CodingKeys: String, CodingKey {
        case device, board, services, interfaces, wireless
        case collectedAt = "collected_at"
        case firmwareFields = "firmware"
        case menuFiles = "menu_files"
        case menuPaths = "menu_paths"
        case menuTree = "menu_tree"
        case installedPackages = "luci_packages"
        case installedApps = "luci_apps"
    }
}

// MARK: - Aggregated snapshot

/// The single discovery product the app navigates by (spec L2). Everything in
/// here is derived from one CollectedRouterSnapshot by the pure rules in
/// DiscoveryRules; nothing is matched by package name and no menu path is
/// hardcoded as present.
public struct CapabilitySnapshot: Equatable, Sendable {
    public struct Firmware: Equatable, Sendable {
        public var distribution: String?
        public var version: String?
        public var revision: String?
        public var target: String?
        public var architecture: String?
        public var description: String?
    }

    public struct Upstream: Equatable, Sendable {
        public var interfaceName: String
        public var device: String?
        public var l3Device: String?
        public var nexthop: String?
        public var isIPv6: Bool
    }

    public struct MenuNode: Identifiable, Equatable, Sendable {
        public var path: String
        public var title: String
        public var order: Int
        public var children: [MenuNode]
        public var id: String { path }
        public init(path: String, title: String, order: Int = 100, children: [MenuNode] = []) {
            self.path = path; self.title = title; self.order = order; self.children = children
        }
    }

    public struct CapabilityService: Identifiable, Equatable, Sendable {
        public enum Source: String, Equatable, Sendable {
            /// Menu entry and at least one matching init.d service.
            case menuAndInit
            /// Menu entry exists but no init.d name matched; state stays
            /// unknown rather than guessed (e.g. wol vs etherwake naming).
            case menuOnly
            /// The router exposes no service menus at all, so the service
            /// list is the init.d core services themselves (spec section 5).
            case initFallback
        }
        public var key: String
        public var title: String
        public var menuPath: String?
        public var initNames: [String]
        public var enabled: Bool?
        public var running: Bool?
        public var source: Source
        public var id: String { key }
    }

    public let routerID: String
    public let address: String
    public let role: String?
    public let capturedAt: Date
    public let firmware: Firmware
    public let board: CollectedRouterSnapshot.Board
    /// Every enumerated menu path, unfiltered.
    public let menuPaths: [String]
    /// Paths that survive endpoint removal and capability (depends) gating.
    public let visibleMenuPaths: [String]
    /// Navigation tree generated from visibleMenuPaths. "admin/logout" is
    /// kept in visibleMenuPaths but is an action, not a tree node.
    public let menuTree: [MenuNode]
    public let installedApps: [String]
    public let installedPackages: [String]
    public let initServices: [CollectedRouterSnapshot.InitServiceState]
    public let interfaces: [CollectedRouterSnapshot.InterfaceState]
    public let upstream: Upstream?
    public let wireless: CollectedRouterSnapshot.WirelessState
    public let services: [CapabilityService]
    public let warnings: [String]

    public init(collected: CollectedRouterSnapshot, warnings: [String] = []) {
        routerID = collected.device.id
        address = collected.device.address
        role = collected.device.role
        capturedAt = DiscoveryRules.parseCollectedDate(collected.collectedAt)
        let fields = collected.firmwareFields
        let release = collected.board.release
        firmware = Firmware(
            distribution: fields["DISTRIB_ID"] ?? release?.distribution,
            version: fields["DISTRIB_RELEASE"] ?? release?.version,
            revision: fields["DISTRIB_REVISION"] ?? release?.revision,
            target: fields["DISTRIB_TARGET"] ?? release?.target,
            architecture: fields["DISTRIB_ARCH"],
            description: fields["DISTRIB_DESCRIPTION"] ?? release?.description)
        board = collected.board
        menuPaths = collected.menuPaths
        let capabilities = DiscoveryRules.capabilities(of: collected)
        visibleMenuPaths = DiscoveryRules.visibleMenuPaths(collected.menuPaths, capabilities: capabilities)
        menuTree = DiscoveryRules.menuTree(visiblePaths: visibleMenuPaths, entries: collected.menuTree)
        installedApps = collected.installedApps
        installedPackages = collected.installedPackages
        initServices = collected.services
        interfaces = collected.interfaces
        upstream = DiscoveryRules.resolveUpstream(interfaces: collected.interfaces)
        wireless = collected.wireless
        services = DiscoveryRules.synthesizeServices(collected: collected, visiblePaths: visibleMenuPaths)
        self.warnings = warnings
    }

    /// True when the menu carries a plausible logged-in haul. An
    /// anonymous-grade menu (session not recognized by LuCI) collapses to
    /// a handful of visible pages; such a snapshot must never be cached
    /// or presented as a successful discovery.
    public var hasSubstantiveMenu: Bool {
        visibleMenuPaths.filter { $0.split(separator: "/").count == 3 }.count
            >= MenuQuality.minimumLoggedInSecondLevel
    }

    public func menuNode(_ path: String) -> MenuNode? {
        func search(_ nodes: [MenuNode]) -> MenuNode? {
            for node in nodes {
                if node.path == path { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(menuTree)
    }
}

// MARK: - Pure discovery rules

public enum DiscoveryCapability: String, Hashable, Sendable {
    /// A wifi-device exists in the wireless configuration.
    case wifiDevice
    /// nftables is the live firewall backend.
    case nftables
}

public enum DiscoveryRules {
    /// Menu paths whose LuCI definitions depend on a wifi-device
    /// (menu.d depends on uci wireless @wifi-device). Without one they are
    /// hidden by LuCI itself and must not be generated here either.
    static let wifiGatedPaths = ["admin/network/wireless", "admin/status/channel_analysis", "admin/status/realtime/wireless"]

    public static func capabilities(of collected: CollectedRouterSnapshot) -> Set<DiscoveryCapability> {
        var result: Set<DiscoveryCapability> = []
        if collected.wireless.present { result.insert(.wifiDevice) }
        if collected.menuPaths.contains("admin/status/nftables")
            || collected.menuPaths.contains("admin/status/firewall/nftables") {
            result.insert(.nftables)
        }
        return result
    }

    /// Non-display endpoints and action routes that appear in raw menu
    /// enumeration but are never menu items (LuCI internals, wildcard
    /// handlers, POST actions, and the routes/routesj duplicate alias).
    public static func isDisplayablePath(_ path: String) -> Bool {
        guard path == "admin" || path.hasPrefix("admin/") else { return false }
        guard !path.contains("*") else { return false }
        let blockedPrefixes = ["admin/ubus", "admin/translations", "admin/uci",
                               "admin/network/remote_addr",
                               "admin/system/commands/download", "admin/system/commands/run"]
        if blockedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        if path == "admin/menu" { return false }
        if path == "admin/system/diskman/partition" { return false }
        if path == "admin/status/routesj" { return false }
        return true
    }

    public static func visibleMenuPaths(_ paths: [String], capabilities: Set<DiscoveryCapability>) -> [String] {
        var visible = paths.filter { path in
            guard isDisplayablePath(path) else { return false }
            if wifiGatedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
               !capabilities.contains(.wifiDevice) { return false }
            // The legacy iptables status page is hidden whenever nftables
            // is present (its menu.d depends declares nft "absent").
            if path == "admin/status/iptables", capabilities.contains(.nftables) { return false }
            return true
        }
        // Drop group roots that ended up with no visible descendants, except
        // the four core groups the navigation is built from.
        let coreGroups: Set<String> = ["admin/status", "admin/system", "admin/services", "admin/network"]
        visible = visible.filter { path in
            let depth = path.split(separator: "/").count
            guard depth == 2, !coreGroups.contains(path), path != "admin/logout" else { return true }
            return visible.contains { $0.hasPrefix(path + "/") }
        }
        return visible.sorted()
    }

    /// Upstream is whichever interface owns the default route. Matching an
    /// interface literally named "wan" is forbidden: on the bypass router
    /// the default route belongs to lan/br-lan and wan is an empty shell.
    public static func resolveUpstream(interfaces: [CollectedRouterSnapshot.InterfaceState]) -> CapabilitySnapshot.Upstream? {
        func find(target: String, isIPv6: Bool) -> CapabilitySnapshot.Upstream? {
            let candidates = interfaces.filter { iface in
                iface.routes.contains { $0.target == target && ($0.mask ?? 0) == 0 }
            }
            guard let chosen = candidates.first(where: { $0.up == true }) ?? candidates.first,
                  let route = chosen.routes.first(where: { $0.target == target && ($0.mask ?? 0) == 0 }) else { return nil }
            return CapabilitySnapshot.Upstream(interfaceName: chosen.name, device: chosen.device,
                                               l3Device: chosen.l3Device, nexthop: route.nexthop, isIPv6: isIPv6)
        }
        return find(target: "0.0.0.0", isIPv6: false) ?? find(target: "::", isIPv6: true)
    }

    /// Services are menu entries intersected with init.d state. Package
    /// lists are never consulted: luci-app-openbox is not in the package
    /// manager's list on the bypass router, yet its menu and its init.d
    /// services exist and run.
    public static func synthesizeServices(collected: CollectedRouterSnapshot, visiblePaths: [String]) -> [CapabilitySnapshot.CapabilityService] {
        let menuChildren = visiblePaths.filter { path in
            path.hasPrefix("admin/services/") && path.split(separator: "/").count == 3
        }
        guard !menuChildren.isEmpty else {
            return collected.services.map { service in
                CapabilitySnapshot.CapabilityService(
                    key: service.name, title: service.name, menuPath: nil,
                    initNames: [service.name], enabled: service.enabled,
                    running: service.running, source: .initFallback)
            }.sorted { $0.key < $1.key }
        }
        return menuChildren.map { path in
            let key = String(path.split(separator: "/").last ?? "")
            let matched = collected.services.filter { service in
                service.name == key || service.name.hasPrefix(key + "-") || service.name.hasPrefix(key + "_")
            }
            let enabledValues = matched.compactMap(\.enabled)
            let runningValues = matched.compactMap(\.running)
            return CapabilitySnapshot.CapabilityService(
                key: key,
                title: (collected.menuTree[path]?.title ?? nil) ?? key,
                menuPath: path,
                initNames: matched.map(\.name).sorted(),
                enabled: enabledValues.isEmpty ? nil : enabledValues.contains(true),
                running: runningValues.contains(true) ? true : (runningValues.isEmpty ? nil : false),
                source: matched.isEmpty ? .menuOnly : .menuAndInit)
        }.sorted { lhs, rhs in
            let leftOrder = (collected.menuTree[lhs.menuPath ?? ""]?.order ?? nil) ?? 100
            let rightOrder = (collected.menuTree[rhs.menuPath ?? ""]?.order ?? nil) ?? 100
            return leftOrder == rightOrder ? lhs.key < rhs.key : leftOrder < rightOrder
        }
    }

    public static func menuTree(visiblePaths: [String], entries: [String: CollectedRouterSnapshot.MenuEntryInfo]) -> [CapabilitySnapshot.MenuNode] {
        let paths = visiblePaths.filter { $0 != "admin" && $0 != "admin/logout" }
        let pathSet = Set(paths)
        func children(of parent: String) -> [CapabilitySnapshot.MenuNode] {
            paths.filter { path in
                path.hasPrefix(parent + "/") && !path.dropFirst(parent.count + 1).contains("/")
            }.map { path in
                CapabilitySnapshot.MenuNode(path: path, title: (entries[path]?.title ?? nil) ?? String(path.split(separator: "/").last ?? ""),
                                            order: (entries[path]?.order ?? nil) ?? 100, children: children(of: path))
            }.sorted { $0.order == $1.order ? $0.path < $1.path : $0.order < $1.order }
        }
        return paths.filter { $0.split(separator: "/").count == 2 && pathSet.contains($0) }
            .map { path in
                CapabilitySnapshot.MenuNode(path: path, title: (entries[path]?.title ?? nil) ?? String(path.split(separator: "/").last ?? ""),
                                            order: (entries[path]?.order ?? nil) ?? 100, children: children(of: path))
            }.sorted { $0.order == $1.order ? $0.path < $1.path : $0.order < $1.order }
    }

    static func parseCollectedDate(_ raw: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw) ?? Date(timeIntervalSince1970: 0)
    }
}
