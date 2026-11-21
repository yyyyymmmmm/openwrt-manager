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
        /// The node's depends.uci config names and depends.acl groups,
        /// carried since schema 4: they are discovery signals for tying
        /// a menu entry to its init.d service (see synthesizeServices).
        /// Before schema 4 the haul dropped them, which is part of why
        /// service states stayed unknown.
        public var configs: [String]
        public var aclGroups: [String]
        public init(title: String? = nil, order: Int? = nil, file: String? = nil,
                    configs: [String] = [], aclGroups: [String] = []) {
            self.title = title; self.order = order; self.file = file
            self.configs = configs; self.aclGroups = aclGroups
        }

        private enum CodingKeys: String, CodingKey {
            case title, order, file, configs
            case aclGroups = "acl_groups"
        }

        /// Tolerant decoding: pre-schema-4 hauls carry neither signal
        /// list; they decode as empty rather than failing the haul.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            order = try container.decodeIfPresent(Int.self, forKey: .order)
            file = try container.decodeIfPresent(String.self, forKey: .file)
            configs = try container.decodeIfPresent([String].self, forKey: .configs) ?? []
            aclGroups = try container.decodeIfPresent([String].self, forKey: .aclGroups) ?? []
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

    /// The cache format version of this collected form. Version 1 is
    /// the implicit format of every haul before language tagging
    /// existed (no schema_version key on the wire); version 2 records
    /// the language the haul's display strings were localized with;
    /// version 3 discards version-2 hauls whose titles were left in
    /// English by the negotiation miss on auto-lang routers (build #8
    /// field failure — the language tag honestly said "source", but a
    /// same-version cache could still outlive the fix on devices whose
    /// refresh gate had settled); version 4 discards version-3 hauls
    /// whose service states were poisoned by the rc-fill miss and the
    /// dropped menu signals (build #10 field failure — most services
    /// on the bypass router rendered "unknown" while rc reported their
    /// state all along). The app refuses to serve a cache
    /// whose version is not current — an old snapshot must be
    /// re-discovered, not rendered.
    public static let currentSchemaVersion = 4

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
    public var schemaVersion: Int
    /// Canonical tag of the catalog language this haul's router-source
    /// display strings were localized with ("zh-cn"), or "source".
    public var language: String

    public init(device: Device, collectedAt: String, firmwareFields: [String: String] = [:],
                board: Board, menuFiles: [String] = [], menuPaths: [String],
                menuTree: [String: MenuEntryInfo] = [:], installedPackages: [String] = [],
                installedApps: [String] = [], services: [InitServiceState] = [],
                interfaces: [InterfaceState] = [], wireless: WirelessState,
                schemaVersion: Int = CollectedRouterSnapshot.currentSchemaVersion,
                language: String = "source") {
        self.device = device; self.collectedAt = collectedAt; self.firmwareFields = firmwareFields
        self.board = board; self.menuFiles = menuFiles; self.menuPaths = menuPaths
        self.menuTree = menuTree; self.installedPackages = installedPackages
        self.installedApps = installedApps; self.services = services
        self.interfaces = interfaces; self.wireless = wireless
        self.schemaVersion = schemaVersion; self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case device, board, services, interfaces, wireless, language
        case collectedAt = "collected_at"
        case firmwareFields = "firmware"
        case menuFiles = "menu_files"
        case menuPaths = "menu_paths"
        case menuTree = "menu_tree"
        case installedPackages = "luci_packages"
        case installedApps = "luci_apps"
        case schemaVersion = "schema_version"
    }

    /// Whether this haul may be served from the cache: only a
    /// current-schema haul, and — when the caller knows the language a
    /// fresh discovery would produce now — only one discovered in that
    /// same language. Anything else is re-discovered instead of shown.
    public func isUsableCache(expectedLanguage: String?) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion else { return false }
        if let expectedLanguage { return language == expectedLanguage }
        return true
    }
}

extension CollectedRouterSnapshot {
    /// Tolerant decoding: hauls written before language tagging (the
    /// on-disk caches of earlier builds, the collected test fixtures)
    /// carry no schema_version/language keys and decode as version 1 /
    /// "source". Encoding stays synthesized — only decoding is custom
    /// (it lives in this extension for exactly that reason), so the
    /// wire format gains exactly the two new keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(Device.self, forKey: .device)
        collectedAt = try container.decodeIfPresent(String.self, forKey: .collectedAt) ?? ""
        firmwareFields = try container.decodeIfPresent([String: String].self, forKey: .firmwareFields) ?? [:]
        board = try container.decodeIfPresent(Board.self, forKey: .board) ?? Board()
        menuFiles = try container.decodeIfPresent([String].self, forKey: .menuFiles) ?? []
        menuPaths = try container.decodeIfPresent([String].self, forKey: .menuPaths) ?? []
        menuTree = try container.decodeIfPresent([String: MenuEntryInfo].self, forKey: .menuTree) ?? [:]
        installedPackages = try container.decodeIfPresent([String].self, forKey: .installedPackages) ?? []
        installedApps = try container.decodeIfPresent([String].self, forKey: .installedApps) ?? []
        services = try container.decodeIfPresent([InitServiceState].self, forKey: .services) ?? []
        interfaces = try container.decodeIfPresent([InterfaceState].self, forKey: .interfaces) ?? []
        wireless = try container.decodeIfPresent(WirelessState.self, forKey: .wireless) ?? WirelessState(present: false)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "source"
    }
}

// MARK: - Aggregated snapshot

/// The single discovery product the app navigates by (spec L2). Everything in
/// here is derived from one CollectedRouterSnapshot by the pure rules in
/// DiscoveryRules; nothing is matched by package name and no menu path is
/// hardcoded as present.
/// The nature of a resolved upstream interface (audit U7): a real
/// WAN port, or — on bypass routers — the LAN interface itself
/// carrying the default route. Presentation classification only;
/// see DiscoveryRules.upstreamNature.
public enum UpstreamNature: String, Equatable, Sendable {
    case wan
    case local
}

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
        /// Why the running state is unknown, in user language; nil when
        /// the state is known. The list column shows only the state
        /// itself — this note is what the detail page shows next to an
        /// "unknown" so the user never has to guess which kind of
        /// unknown it is (round-6: no init match, no state reported by
        /// the router, or the state haul itself failed).
        public var statusNote: String?
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
    /// The collected haul's cache-format version (see
    /// CollectedRouterSnapshot.currentSchemaVersion).
    public let schemaVersion: Int
    /// The language this snapshot's router-source display strings were
    /// localized with ("zh-cn"), or "source". Compared against the
    /// language a fresh discovery would use now to decide whether the
    /// snapshot must be re-discovered rather than rendered.
    public let language: String

    public init(collected: CollectedRouterSnapshot, warnings: [String] = []) {
        schemaVersion = collected.schemaVersion
        language = collected.language
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
                               // Custom commands (audit F6, decided in
                               // package J): the whole subtree is not
                               // generated as pages. The feature is a
                               // second arbitrary-command surface fully
                               // duplicated by the native terminal
                               // (which has host-key trust and an
                               // operation record); the menu node
                               // itself only ever produced an empty
                               // dead-end page. Prefix matching covers
                               // the node and its run/download actions.
                               "admin/system/commands"]
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

    /// What kind of thing the resolved upstream is, for presentation
    /// only (audit U7): cycling a true WAN interface briefly drops
    /// the internet and leaves the LAN alone, while on a bypass
    /// router the "upstream" IS the LAN interface — cycling it drops
    /// the LAN side too, and the copy must say so. This classifies
    /// the already-resolved upstream; it never takes part in
    /// resolving it (the no-name-matching rule above stands). The
    /// LAN verdict rests on measured shapes: the upstream rides the
    /// br-lan bridge (the bypass router at 192.168.31.167, measured
    /// 2026-11-21), or the interface is the lan interface itself.
    public static func upstreamNature(of upstream: CapabilitySnapshot.Upstream,
                                      interfaces: [CollectedRouterSnapshot.InterfaceState]) -> UpstreamNature {
        let match = interfaces.first { $0.name == upstream.interfaceName }
        let devices = [upstream.device, upstream.l3Device, match?.device, match?.l3Device].compactMap { $0 }
        if devices.contains(where: { $0 == "br-lan" || $0.hasPrefix("br-lan.") }) { return .local }
        if upstream.interfaceName == "lan" { return .local }
        return .wan
    }

    /// Menu leaf -> init.d names for the entries no discovery signal
    /// can tie together. This table is a last resort and grows only
    /// from measured routers, never from naming folklore: every entry
    /// records the router and date that proved the signals empty.
    /// - wol -> etherwake: 192.168.31.167 (OpenWrt 25.12.5), measured
    ///   2026-11-21. The wol menu node carries no depends.uci, its acl
    ///   group names only the app (luci-app-wol) and its action path is
    ///   "wol"; the init script is /etc/init.d/etherwake.
    public static let measuredServiceInitNames: [String: [String]] = [
        "wol": ["etherwake"]
    ]

    /// Why a service's running state is unknown, in user language. The
    /// three cases are kept apart because they ask different things of
    /// the user: nothing (one-shot scripts have no state to know),
    /// nothing yet (discovery limitation), or a retry (the haul failed).
    public enum ServiceStatusNote {
        public static var noInitMatch: String {
            KitL10n.text("未找到对应的 init.d 服务，无法读取运行状态。")
        }
        public static var noStateReported: String {
            KitL10n.text("路由器未报告此服务的运行状态（这类服务多为一次性脚本，没有常驻进程），无法判定。")
        }
        public static var stateSourceFailed: String {
            KitL10n.text("服务状态读取失败，请重新发现或下拉刷新后重试。")
        }
    }

    /// Resolves one services-menu entry to its init.d service names by
    /// trying the discovery signals in a fixed priority — the leaf name
    /// itself, the node's depends.uci config names, its depends.acl
    /// app groups, the leaf's prefix family, and only then the measured
    /// mapping table. The first signal that names at least one real
    /// init service wins, and a hit always carries its prefix family
    /// (openbox -> openbox + openbox-panel are one service to the user).
    public static func resolveInitNames(key: String, entry: CollectedRouterSnapshot.MenuEntryInfo?,
                                        initNames: Set<String>) -> [String] {
        func family(of base: String) -> [String] {
            initNames.filter { $0 == base || $0.hasPrefix(base + "-") || $0.hasPrefix(base + "_") }.sorted()
        }
        if initNames.contains(key) { return family(of: key) }
        for config in entry?.configs ?? [] where initNames.contains(config) {
            return family(of: config)
        }
        for group in entry?.aclGroups ?? [] {
            let candidate = group.hasPrefix("luci-app-") ? String(group.dropFirst("luci-app-".count)) : group
            if initNames.contains(candidate) { return family(of: candidate) }
        }
        let prefixed = family(of: key)
        if !prefixed.isEmpty { return prefixed }
        return (measuredServiceInitNames[key] ?? []).filter { initNames.contains($0) }.sorted()
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
                    running: service.running, source: .initFallback,
                    statusNote: service.running == nil ? ServiceStatusNote.noStateReported : nil)
            }.sorted { $0.key < $1.key }
        }
        let initNameSet = Set(collected.services.map(\.name))
        let byName = Dictionary(uniqueKeysWithValues: collected.services.map { ($0.name, $0) })
        return menuChildren.map { path in
            let key = String(path.split(separator: "/").last ?? "")
            let resolved = resolveInitNames(key: key, entry: collected.menuTree[path], initNames: initNameSet)
            let matched = resolved.compactMap { byName[$0] }
            let enabledValues = matched.compactMap(\.enabled)
            let runningValues = matched.compactMap(\.running)
            let running: Bool? = runningValues.contains(true) ? true : (runningValues.isEmpty ? nil : false)
            let note: String?
            if running != nil {
                note = nil
            } else if matched.isEmpty {
                note = collected.services.isEmpty
                    ? ServiceStatusNote.stateSourceFailed
                    : ServiceStatusNote.noInitMatch
            } else {
                note = ServiceStatusNote.noStateReported
            }
            return CapabilitySnapshot.CapabilityService(
                key: key,
                title: (collected.menuTree[path]?.title ?? nil) ?? key,
                menuPath: path,
                initNames: resolved,
                enabled: enabledValues.isEmpty ? nil : enabledValues.contains(true),
                running: running,
                source: matched.isEmpty ? .menuOnly : .menuAndInit,
                statusNote: note)
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
