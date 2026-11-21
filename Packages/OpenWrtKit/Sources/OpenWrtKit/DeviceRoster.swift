import Foundation

// MARK: - Online-device roster (package C, item 2)
//
// One device list merged from every source the router offers:
// DHCP leases (hostname, address, lease expiry), the ARP/neighbor
// table (addresses a lease does not know, liveness state) and — when
// the iwinfo object is granted — wireless association (which radio a
// device hangs off, and its signal). Deduplication is by normalized
// MAC: the same device seen by two or three sources is one row, with
// every source's facts merged in. A neighbor entry without a link
// address cannot be matched to a MAC, so it stays its own row keyed
// by address and is labelled as such — never silently merged, never
// silently dropped.

public struct WirelessStation: Identifiable, Equatable, Sendable {
    public var mac: String
    /// The wireless netdev the station is associated with (wlan0…).
    public var device: String
    public var signal: Int?
    public var noise: Int?
    public var rxBytes: Int64?
    public var txBytes: Int64?
    public var id: String { "\(device)|\(mac)" }
    public init(mac: String, device: String, signal: Int? = nil, noise: Int? = nil,
                rxBytes: Int64? = nil, txBytes: Int64? = nil) {
        self.mac = mac; self.device = device; self.signal = signal; self.noise = noise
        self.rxBytes = rxBytes; self.txBytes = txBytes
    }
}

public enum StationParser {
    /// ubus iwinfo assoclist: {"results": [{"mac": "AA:BB:…",
    /// "signal": -52, "noise": -95, "inactive": 12,
    /// "rx": {"bytes": n, …}, "tx": {"bytes": n, …}}]}.
    public static func assoclist(_ value: JSONValue, device: String) -> [WirelessStation] {
        (value["results"].arrayValue ?? []).compactMap { item in
            guard let mac = item["mac"].stringValue, !mac.isEmpty else { return nil }
            return WirelessStation(
                mac: DeviceRoster.normalizeMAC(mac) ?? mac,
                device: device,
                signal: item["signal"].intValue,
                noise: item["noise"].intValue,
                rxBytes: item["rx"]["bytes"].intValue.map(Int64.init),
                txBytes: item["tx"]["bytes"].intValue.map(Int64.init))
        }
    }
}

public struct OnlineDevice: Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case lease, neighbor, station
    }
    public enum Connection: String, Codable, Sendable {
        case wireless, wired, unknown
    }

    /// Normalized MAC, or "ip:<address>" for a neighbor row that has
    /// no link address to merge by.
    public var id: String
    public var mac: String?
    public var hostname: String?
    public var addresses: [String] = []
    public var sources: Set<Source> = []
    public var connection: Connection = .unknown
    /// Wireless netdev when associated (from the station source).
    public var wirelessDevice: String?
    public var signal: Int?
    /// Seconds until the DHCP lease expires, when a lease reported it.
    public var leaseExpiresIn: Int?
    /// Neighbor-table state (REACHABLE / STALE / …) when reported.
    public var neighborState: String?
    public var isRouter: Bool = false
    public var rxBytes: Int64?
    public var txBytes: Int64?

    public init(id: String) { self.id = id }

    public var displayName: String {
        if let hostname, !hostname.isEmpty, hostname != "*" { return hostname }
        return mac ?? addresses.first ?? id
    }
}

public enum DeviceRoster {
    /// Canonical MAC form: uppercase, colon-separated. Accepts colon,
    /// dash and bare-hex spellings; anything else returns nil.
    public static func normalizeMAC(_ raw: String) -> String? {
        let hex = raw.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }.joined(separator: ":")
    }

    public static func merge(leases: [DHCPLease],
                             neighbors: [NeighborEntry],
                             stations: [WirelessStation]) -> [OnlineDevice] {
        var byKey: [String: OnlineDevice] = [:]
        var order: [String] = []
        func device(forKey key: String, mac: String?) -> OnlineDevice {
            if let existing = byKey[key] { return existing }
            var fresh = OnlineDevice(id: key)
            fresh.mac = mac
            byKey[key] = fresh
            order.append(key)
            return fresh
        }
        func store(_ device: OnlineDevice) { byKey[device.id] = device }

        for lease in leases {
            guard let mac = normalizeMAC(lease.mac) else { continue }
            var entry = device(forKey: mac, mac: mac)
            entry.sources.insert(.lease)
            if entry.hostname == nil || entry.hostname == "*" { entry.hostname = lease.hostname }
            if !entry.addresses.contains(lease.address) { entry.addresses.append(lease.address) }
            entry.leaseExpiresIn = lease.expires
            store(entry)
        }
        for station in stations {
            guard let mac = normalizeMAC(station.mac) else { continue }
            var entry = device(forKey: mac, mac: mac)
            entry.sources.insert(.station)
            entry.connection = .wireless
            entry.wirelessDevice = station.device
            entry.signal = station.signal
            entry.rxBytes = station.rxBytes
            entry.txBytes = station.txBytes
            store(entry)
        }
        for neighbor in neighbors {
            if let rawMAC = neighbor.mac, let mac = normalizeMAC(rawMAC) {
                var entry = device(forKey: mac, mac: mac)
                entry.sources.insert(.neighbor)
                if !entry.addresses.contains(neighbor.address) { entry.addresses.append(neighbor.address) }
                entry.neighborState = neighbor.state ?? entry.neighborState
                entry.isRouter = entry.isRouter || neighbor.isRouter
                // A neighbor seen on a bridge/LAN device but not
                // associated wirelessly is wired — unless the station
                // source already claimed it.
                if entry.connection == .unknown { entry.connection = .wired }
                store(entry)
            } else {
                // No link address: cannot merge by MAC. Keep the row,
                // keyed by address, visibly unmerged.
                var entry = device(forKey: "ip:\(neighbor.address)", mac: nil)
                entry.sources.insert(.neighbor)
                if !entry.addresses.contains(neighbor.address) { entry.addresses.append(neighbor.address) }
                entry.neighborState = neighbor.state ?? entry.neighborState
                entry.isRouter = entry.isRouter || neighbor.isRouter
                store(entry)
            }
        }
        return order.map { byKey[$0]! }.sorted { lhs, rhs in
            let left = lhs.displayName.lowercased(), right = rhs.displayName.lowercased()
            return left == right ? lhs.id < rhs.id : left < right
        }
    }
}

// MARK: - Device blocking (package C, item 2)
//
// Blocking uses the router's own mechanisms, matched to how the
// device attaches:
// - Wireless: the wifi-iface MAC filter. In deny mode the MAC joins
//   each interface's deny list; in allow (whitelist) mode blocking
//   means removal from the list. Unblocking is the exact inverse.
// - Wired: a firewall rule dropping the device's forwarded traffic
//   (LAN→WAN). Same-subnet traffic never traverses the firewall, so a
//   wired block stops the device's internet, not its LAN chatter —
//   the UI copy states this scope plainly. Rules the app creates
//   carry a `zirox-block-<mac>` name so they are findable again for
//   state derivation and unblocking, and nothing else is touched.

public enum DeviceBlock {
    public static let ruleNamePrefix = "zirox-block-"

    public static func ruleName(forMAC mac: String) -> String {
        ruleNamePrefix + mac.filter { $0.isHexDigit }.lowercased()
    }

    public enum WirelessMode: Equatable, Sendable { case denyList, allowList }

    public struct WirelessInterfaceState: Equatable, Sendable {
        public var sectionID: String
        public var mode: WirelessMode
        public var listed: Bool
        public init(sectionID: String, mode: WirelessMode, listed: Bool) {
            self.sectionID = sectionID; self.mode = mode; self.listed = listed
        }
    }

    /// Per-interface block state for one MAC, read from the current
    /// wireless configuration.
    public static func wirelessState(mac: String, wireless: RouterConfiguration) -> [WirelessInterfaceState] {
        let target = DeviceRoster.normalizeMAC(mac) ?? mac
        return wireless.sections.filter { $0.type == "wifi-iface" }.map { section in
            let mode: WirelessMode = section.values["macfilter"]?.stringValue == "allow" ? .allowList : .denyList
            let list = macList(in: section)
            return WirelessInterfaceState(sectionID: section.id, mode: mode,
                                          listed: list.contains(target))
        }
    }

    /// The device is wireless-blocked when every interface either
    /// deny-lists it or (allow mode) does not list it.
    public static func isWirelessBlocked(mac: String, wireless: RouterConfiguration) -> Bool {
        let states = wirelessState(mac: mac, wireless: wireless)
        guard !states.isEmpty else { return false }
        return states.allSatisfy { state in
            state.mode == .denyList ? state.listed : !state.listed
        }
    }

    public static func isWiredBlocked(mac: String, firewall: RouterConfiguration) -> Bool {
        firewall.sections.contains { section in
            section.type == "rule"
                && section.values["name"]?.stringValue == ruleName(forMAC: mac)
                && section.values["enabled"]?.stringValue != "0"
        }
    }

    /// Builds the edited wireless configuration for a block
    /// (block=true) or unblock (block=false). Returns nil when the
    /// configuration already reflects the desired state.
    public static func wirelessPlan(mac: String, block: Bool,
                                    original: RouterConfiguration) -> RouterConfiguration? {
        let target = DeviceRoster.normalizeMAC(mac) ?? mac
        var edited = original
        var changed = false
        for index in edited.sections.indices where edited.sections[index].type == "wifi-iface" {
            var list = macList(in: edited.sections[index])
            let mode: WirelessMode = edited.sections[index].values["macfilter"]?.stringValue == "allow" ? .allowList : .denyList
            let listed = list.contains(target)
            // Desired list membership: deny mode blocks by listing,
            // allow mode blocks by NOT listing; unblock inverts both.
            let shouldList = (mode == .denyList) == block
            guard listed != shouldList else { continue }
            if shouldList { list.append(target) } else { list.removeAll { $0 == target } }
            if list.isEmpty {
                edited.sections[index].values.removeValue(forKey: "maclist")
            } else {
                edited.sections[index].values["maclist"] = list.count == 1 ? .string(list[0]) : .array(list.map(JSONValue.string))
            }
            if mode == .denyList, edited.sections[index].values["macfilter"] == nil {
                edited.sections[index].values["macfilter"] = .string("deny")
            }
            changed = true
        }
        return changed ? edited : nil
    }

    /// Builds the edited firewall configuration for a wired block or
    /// unblock. Returns nil when already in the desired state.
    public static func wiredPlan(mac: String, block: Bool,
                                 original: RouterConfiguration) -> RouterConfiguration? {
        let target = DeviceRoster.normalizeMAC(mac) ?? mac
        let name = ruleName(forMAC: target)
        var edited = original
        if block {
            guard !isWiredBlocked(mac: target, firewall: original) else { return nil }
            let sectionID = "ziroxblock" + target.filter { $0.isHexDigit }.lowercased()
            edited.sections.append(ConfigurationSection(
                id: sectionID, type: "rule", anonymous: true,
                values: [
                    "name": .string(name),
                    "src": .string("lan"),
                    "dest": .string("wan"),
                    "src_mac": .string(target),
                    "proto": .string("all"),
                    "target": .string("DROP"),
                    "enabled": .string("1"),
                ]))
            return edited
        }
        let before = edited.sections.count
        edited.sections.removeAll { section in
            section.type == "rule" && section.values["name"]?.stringValue == name
        }
        return edited.sections.count == before ? nil : edited
    }

    private static func macList(in section: ConfigurationSection) -> [String] {
        switch section.values["maclist"] {
        case .string(let value): return [DeviceRoster.normalizeMAC(value) ?? value]
        case .array(let values): return values.compactMap { $0.stringValue }.map { DeviceRoster.normalizeMAC($0) ?? $0 }
        default: return []
        }
    }
}
