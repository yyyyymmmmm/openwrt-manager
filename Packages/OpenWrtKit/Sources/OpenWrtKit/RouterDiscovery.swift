import Foundation

/// L2 discovery service (spec section 1): upgrades RouterReader's four-way
/// inventory haul plus the raw data plane into one CapabilitySnapshot.
/// Navigation is generated from this snapshot, never hardcoded, so the same
/// build serves routers whose menus differ by firmware and hardware.
public struct RouterDiscovery: Sendable {
    private let reader: RouterReader

    public init(reader: RouterReader) {
        self.reader = reader
    }

    public func discover(routerID: String, address: String, role: String? = nil) async -> CapabilitySnapshot {
        await discoverWithCollected(routerID: routerID, address: address, role: role).snapshot
    }

    /// Same haul as discover(), but also returns the collected form so the
    /// app can cache it and rebuild the identical snapshot offline.
    public func discoverWithCollected(routerID: String, address: String, role: String? = nil)
        async -> (collected: CollectedRouterSnapshot, snapshot: CapabilitySnapshot) {
        let first = await haul(routerID: routerID, address: address, role: role)
        // Self-healing: an anonymous-grade menu means the session was not
        // recognized as logged in (LuCI decides that from rpcd session
        // data, not from the ubus ACLs). Discard the session, log in
        // again on both channels, and haul once more. If the menu is
        // still anonymous-grade, surface that loudly in the warnings —
        // and the app layer refuses to cache such a snapshot.
        guard MenuQuality.isAnonymousGrade(first.inventory.menus) else { return first.result }
        await reader.invalidateSession()
        let second = await haul(routerID: routerID, address: address, role: role)
        guard MenuQuality.isAnonymousGrade(second.inventory.menus) else { return second.result }
        let warning = KitL10n.text("发现-菜单权限：路由器返回的菜单不完整（会话未被 LuCI 认可为已登录），已重新登录重试仍未恢复；页面可能缺失，此结果不会被缓存。")
        let snapshot = CapabilitySnapshot(collected: second.result.collected,
                                          warnings: second.result.snapshot.warnings + [warning])
        return (second.result.collected, snapshot)
    }

    private func haul(routerID: String, address: String, role: String?) async
        -> (inventory: RouterInventory, result: (collected: CollectedRouterSnapshot, snapshot: CapabilitySnapshot)) {
        async let inventoryRead = reader.inventory()
        async let rawRead = reader.discoveryRawData()
        let (inventory, raw) = await (inventoryRead, rawRead)
        let collected = Self.assemble(routerID: routerID, address: address, role: role,
                                      inventory: inventory, raw: raw)
        let snapshot = CapabilitySnapshot(collected: collected, warnings: inventory.warnings + raw.warnings)
        return (inventory, (collected, snapshot))
    }

    static func assemble(routerID: String, address: String, role: String?,
                         inventory: RouterInventory, raw: RouterReader.DiscoveryRawData,
                         now: Date = Date()) -> CollectedRouterSnapshot {
        let board = parseBoard(raw.board)
        let menuPaths = inventory.allMenus.map(\.id)
        var entries: [String: CollectedRouterSnapshot.MenuEntryInfo] = [:]
        for entry in inventory.allMenus {
            entries[entry.id] = CollectedRouterSnapshot.MenuEntryInfo(title: entry.title, order: entry.order)
        }
        let procd: [RouterService] = raw.services.flatMap { try? SnapshotParser.services($0) } ?? []
        var runningByName: [String: Bool?] = Dictionary(uniqueKeysWithValues: procd.map { service in
            let running: Bool?
            if let total = service.totalInstances, total > 0 {
                running = (service.runningInstances ?? 0) > 0
            } else {
                running = nil
            }
            return (service.name, running)
        })
        // rc list is the running-state source on firmware that grants no
        // procd service object at all; where both exist, procd's instance
        // detail wins and rc only fills names procd did not report.
        let rcStates: [String: InventoryParser.RCServiceState] =
            raw.rcList.flatMap { try? InventoryParser.rcServices($0) } ?? [:]
        for (name, state) in rcStates where runningByName[name] == nil {
            runningByName[name] = state.running
        }
        var initServices = inventory.initServices.map { service in
            CollectedRouterSnapshot.InitServiceState(name: service.name, enabled: service.enabled,
                                                     running: runningByName[service.name] ?? nil)
        }
        let knownNames = Set(initServices.map(\.name))
        for name in runningByName.keys.sorted() where !knownNames.contains(name) {
            initServices.append(CollectedRouterSnapshot.InitServiceState(name: name, enabled: rcStates[name]?.enabled,
                                                                          running: runningByName[name] ?? nil))
        }
        initServices.sort { $0.name < $1.name }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CollectedRouterSnapshot(
            device: .init(id: routerID, address: address, role: role),
            collectedAt: formatter.string(from: now),
            board: board,
            menuPaths: menuPaths,
            menuTree: entries,
            installedPackages: inventory.packages.map(\.name),
            installedApps: inventory.packages.map(\.name).filter { $0.hasPrefix("luci-app-") },
            services: initServices,
            interfaces: parseInterfaces(raw.interfaces),
            wireless: parseWireless(raw.wireless),
            language: inventory.language)
    }

    static func parseBoard(_ value: JSONValue?) -> CollectedRouterSnapshot.Board {
        guard let board = value else { return CollectedRouterSnapshot.Board() }
        let release = board["release"]
        return CollectedRouterSnapshot.Board(
            hostname: board["hostname"].stringValue,
            model: board["model"].stringValue,
            boardName: board["board_name"].stringValue,
            kernel: board["kernel"].stringValue,
            system: board["system"].stringValue,
            rootfsType: board["rootfs_type"].stringValue,
            release: .init(distribution: release["distribution"].stringValue,
                           version: release["version"].stringValue,
                           revision: release["revision"].stringValue,
                           target: release["target"].stringValue,
                           description: release["description"].stringValue))
    }

    static func parseInterfaces(_ value: JSONValue?) -> [CollectedRouterSnapshot.InterfaceState] {
        guard let items = value?["interface"].arrayValue else { return [] }
        return items.compactMap { item in
            guard let name = item["interface"].stringValue, !name.isEmpty else { return nil }
            func addresses(_ key: String) -> [String] {
                (item[key].arrayValue ?? []).compactMap { $0["address"].stringValue }
            }
            let routes = (item["route"].arrayValue ?? []).compactMap { route -> CollectedRouterSnapshot.Route? in
                guard let target = route["target"].stringValue else { return nil }
                return CollectedRouterSnapshot.Route(target: target, mask: route["mask"].intValue,
                                                     nexthop: route["nexthop"].stringValue,
                                                     source: route["source"].stringValue)
            }
            return CollectedRouterSnapshot.InterfaceState(
                name: name, up: item["up"].boolValue, available: item["available"].boolValue,
                pending: item["pending"].boolValue, proto: item["proto"].stringValue,
                device: item["device"].stringValue, l3Device: item["l3_device"].stringValue,
                ipv4: addresses("ipv4-address"), ipv6: addresses("ipv6-address"),
                routes: routes, dns: (item["dns-server"].arrayValue ?? []).compactMap(\.stringValue))
        }.sorted { $0.name < $1.name }
    }

    /// Parses luci-rpc getWirelessDevices (the wireless source granted to
    /// login sessions; network.wireless status is granted to none). The
    /// nesting varies across rpcd builds, so fields are read defensively;
    /// an empty object means no radios — present stays false.
    static func parseWireless(_ value: JSONValue?) -> CollectedRouterSnapshot.WirelessState {
        guard let radios = value?.objectValue, !radios.isEmpty else {
            return CollectedRouterSnapshot.WirelessState(present: false)
        }
        let parsed = radios.map { name, radio in
            let interfaces = radio["interfaces"].arrayValue ?? []
            let band = radio["config"]["band"].stringValue
                ?? radio["config"]["hwmode"].stringValue.map(hwmodeBand)
            return CollectedRouterSnapshot.Radio(
                name: name,
                up: radio["up"].boolValue
                    ?? (interfaces.contains { $0["iwinfo"].objectValue != nil } ? true : nil),
                disabled: radio["disabled"].boolValue ?? radio["config"]["disabled"].boolValue,
                band: band)
        }.sorted { $0.name < $1.name }
        return CollectedRouterSnapshot.WirelessState(present: true, radios: parsed)
    }

    private static func hwmodeBand(_ hwmode: String) -> String {
        switch hwmode {
        case "11a", "11ac": return "5g"
        case "11b", "11g", "11ng": return "2g"
        case "11ax": return "ax"
        default: return hwmode
        }
    }
}
