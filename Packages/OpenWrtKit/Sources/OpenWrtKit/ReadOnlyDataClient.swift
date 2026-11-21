import Foundation

/// The package manager an OpenWrt build ships (audit F2): opkg on
/// older builds, apk on current ones. The raw value is the tool's
/// own name — device-side vocabulary, shown as-is.
public enum PackageManager: String, Equatable, Sendable {
    case opkg
    case apk

    /// The display mapping for this vocabulary — the single place a
    /// view may get the manager's name from, so no view renders the
    /// raw value directly (audit H raw-value rule). The names are the
    /// tools' own proper names and are shown verbatim in every
    /// language, like other device-side vocabulary.
    public var displayName: String { rawValue }
}

/// One update check's honest outcome: which manager answered and
/// the upgradable-package lines it reported (device data, verbatim).
/// An empty lines array means the check ran and found nothing —
/// distinct from the check being impossible, which
/// ReadOnlyDataClient.upgradablePackages reports as nil.
public struct UpgradablePackages: Equatable, Sendable {
    public var manager: PackageManager
    public var lines: [String]
    public init(manager: PackageManager, lines: [String]) {
        self.manager = manager
        self.lines = lines
    }
}

/// The router's two package lists as the package-manager helper
/// reports them (cgi-exec): what is installed and what the feeds
/// offer. The update check is a local diff of the two — the same
/// construction LuCI's software page presents.
public struct PackageLists: Equatable, Sendable {
    public var manager: PackageManager
    public var installed: [InstalledPackage]
    public var available: [InstalledPackage]
    public init(manager: PackageManager, installed: [InstalledPackage], available: [InstalledPackage]) {
        self.manager = manager
        self.installed = installed
        self.available = available
    }
}

/// The local half of the update check: which installed packages the
/// feeds offer at a different version. Lines keep the opkg
/// list-upgradable shape ("name - installed - available") the UI
/// has always rendered and name-matched against.
public enum PackageListDiff {
    public static func upgradableLines(installed: [InstalledPackage],
                                       available: [InstalledPackage]) -> [String] {
        let installedVersions = Dictionary(installed.map { ($0.name, $0.version) },
                                           uniquingKeysWith: { first, _ in first })
        return available.compactMap { candidate -> String? in
            guard let current = installedVersions[candidate.name],
                  current != candidate.version else { return nil }
            return "\(candidate.name) - \(current) - \(candidate.version)"
        }.sorted()
    }
}

/// The L3 read-only data plane (spec section 1). Every read the phase-1
/// pages need goes through here on top of UbusCalling, so session renewal
/// and transport stay single-sourced. Nothing in this type writes.
public struct ReadOnlyDataClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public init(client: UbusClient, session: UbusSession) {
        self.caller = FixedSessionCaller(client: client, session: session)
    }

    /// The session's localization context, for pages that resolve
    /// router-source display strings (generic-page section/field
    /// names) through the discovery's translation entry. Never
    /// throws: failures degrade to the source context.
    public func localization() async -> LuciLocalization {
        (try? await caller.localization()) ?? .source
    }

    // MARK: System and interfaces

    public func systemBoard() async throws -> JSONValue {
        try await caller.call(object: "system", method: "board")
    }

    public func systemInfo() async throws -> JSONValue {
        try await caller.call(object: "system", method: "info")
    }

    /// Board + info + interface dump combined through the shared parser,
    /// exactly like the overview's existing snapshot.
    public func systemSnapshot() async throws -> RouterSnapshot {
        async let board = capture { try await systemBoard() }
        async let info = capture { try await systemInfo() }
        async let dump = capture { try await interfaceDump() }
        let (boardResult, infoResult, dumpResult) = await (board, info, dump)
        var snapshot = RouterSnapshot()
        var boardValue: JSONValue = .null
        var infoValue: JSONValue = .null
        switch boardResult {
        case .success(let value): boardValue = value
        case .failure(let error): snapshot.warnings.append(KitL10n.format("硬件信息：%@", KitErrorSummary.summary(for: error)))
        }
        switch infoResult {
        case .success(let value): infoValue = value
        case .failure(let error): snapshot.warnings.append(KitL10n.format("运行状态：%@", KitErrorSummary.summary(for: error)))
        }
        snapshot.system = SnapshotParser.system(board: boardValue, info: infoValue)
        switch dumpResult {
        case .success(let value):
            do { snapshot.interfaces = try SnapshotParser.interfaces(value) }
            catch { snapshot.warnings.append(KitL10n.format("网络接口：%@", KitErrorSummary.summary(for: error))) }
        case .failure(let error): snapshot.warnings.append(KitL10n.format("网络接口：%@", KitErrorSummary.summary(for: error)))
        }
        snapshot.refreshedAt = Date()
        return snapshot
    }

    public func interfaceDump() async throws -> JSONValue {
        try await caller.call(object: "network.interface", method: "dump")
    }

    /// Rich interface states (routes, l3 devices) via the discovery parser.
    public func interfaces() async throws -> [CollectedRouterSnapshot.InterfaceState] {
        RouterDiscovery.parseInterfaces(try await interfaceDump())
    }

    public func deviceTraffic() async throws -> [DeviceTraffic] {
        do {
            let value = try await caller.call(object: "network.device", method: "status")
            return ReadOnlyParser.deviceTraffic(value)
        } catch OpenWrtKitError.permissionDenied {
            // Firmware whose acl.d grants no network.device object (the
            // main router): luci-rpc getNetworkDevices is granted on
            // both test routers and carries the same byte counters —
            // it is the source LuCI's own realtime graphs poll.
            let value = try await caller.call(object: "luci-rpc", method: "getNetworkDevices")
            return ReadOnlyParser.networkDeviceTraffic(value)
        }
    }

    public func neighbors() async throws -> [NeighborEntry] {
        // The only neigh command lines rpcd grants are the /sbin/ip
        // per-family forms (acl.d luci-mod-status-routes, both test
        // routers); /bin/ip is not even present on stock firmware.
        var entries: [NeighborEntry] = []
        var succeeded = false
        var lastError: Error?
        for family in ["-4", "-6"] {
            do {
                entries += ReadOnlyParser.neighbors(
                    try await exec(command: "/sbin/ip", arguments: [family, "neigh", "show"]))
                succeeded = true
            } catch { lastError = error }
        }
        if !succeeded, let lastError { throw lastError }
        return entries
    }

    // MARK: Services, leases, wireless

    public func serviceList() async throws -> [RouterService] {
        do {
            let value = try await caller.call(object: "service", method: "list")
            return try SnapshotParser.services(value)
        } catch OpenWrtKitError.permissionDenied, OpenWrtKitError.unsupported {
            // Firmware whose acl.d grants no "service" object (verified on
            // the main router): rc list carries the same running state.
            let value = try await caller.call(object: "rc", method: "list")
            return try InventoryParser.rcServices(value).map { name, state in
                RouterService(name: name,
                              runningInstances: state.running.map { $0 ? 1 : 0 },
                              totalInstances: 1)
            }.sorted { $0.name < $1.name }
        }
    }

    public func leases() async throws -> [DHCPLease] {
        let value = try await caller.call(object: "luci-rpc", method: "getDHCPLeases")
        return try SnapshotParser.leases(value)
    }

    public func wirelessRadios() async throws -> [WirelessRadio] {
        // luci-rpc getWirelessDevices is the wireless read granted to
        // login sessions; network.wireless status is granted to none
        // (verified in both test routers' acl.d). No radios → empty list.
        let value = try await caller.call(object: "luci-rpc", method: "getWirelessDevices")
        return try SnapshotParser.wirelessDevices(value)
    }

    /// Associated wireless stations (package C device roster
    /// enrichment), best effort by design: the iwinfo ubus object is
    /// not granted to login sessions on every build, and a radio may
    /// have no stations. Candidate netdevs come from the network
    /// device status (wlan*/ath*/phy* names); each assoclist call
    /// that fails is skipped, and a wholesale denial simply yields
    /// an empty list — the roster then stands on leases + neighbors.
    public func associatedStations() async -> [WirelessStation] {
        guard let value = try? await caller.call(object: "network.device", method: "status") else {
            return []
        }
        let names = (value.objectValue ?? [:]).keys.filter { name in
            name.hasPrefix("wlan") || name.hasPrefix("ath") || name.hasPrefix("phy")
        }.sorted()
        var stations: [WirelessStation] = []
        for name in names {
            if let result = try? await caller.call(object: "iwinfo", method: "assoclist",
                                                   parameters: ["device": .string(name)]) {
                stations += StationParser.assoclist(result, device: name)
            }
        }
        return stations
    }

    /// Neighbourhood scan (package I, audit U4), best effort like
    /// the association list: iwinfo scan is slow, a busy radio may
    /// refuse it, and the object is not granted everywhere. Each
    /// radio is tried in turn; failures simply contribute nothing,
    /// and the channel page presents an empty result as "scan
    /// unavailable", never as "no networks around".
    public func wirelessScan() async -> [WirelessScanEntry] {
        guard let value = try? await caller.call(object: "network.device", method: "status") else {
            return []
        }
        let names = (value.objectValue ?? [:]).keys.filter { name in
            name.hasPrefix("wlan") || name.hasPrefix("ath") || name.hasPrefix("phy")
        }.sorted()
        var entries: [WirelessScanEntry] = []
        for name in names {
            if let result = try? await caller.call(object: "iwinfo", method: "scan",
                                                   parameters: ["device": .string(name)]) {
                entries += WirelessScanParser.results(result, device: name)
            }
        }
        return entries
    }

    public func connectionCount() async throws -> ConnectionCount {
        let countText = try await fileRead(path: "/proc/sys/net/netfilter/nf_conntrack_count")
        let maximumText = try? await fileRead(path: "/proc/sys/net/netfilter/nf_conntrack_max")
        guard let parsed = ReadOnlyParser.connectionCount(countText, maximumText: maximumText) else {
            throw OpenWrtKitError.malformedResponse
        }
        return parsed
    }

    // MARK: Logs, processes, firewall status

    public func systemLog(lines: Int = 200) async throws -> [LogEntry] {
        do {
            let value = try await caller.call(object: "log", method: "read", parameters: [
                "lines": .number(Double(lines)), "oneshot": .bool(true), "stream": .bool(false)
            ])
            return ReadOnlyParser.systemLog(value)
        } catch OpenWrtKitError.permissionDenied {
            // Firmware whose acl.d grants no log object at all (the
            // main router, stock 24.10): LuCI's own log view falls back
            // to the syslog-wrapper exec, which IS granted there. It
            // prints the whole log oldest-first; keep the newest `lines`.
            let output = try await exec(command: "/usr/libexec/syslog-wrapper", arguments: [])
            return Array(ReadOnlyParser.systemLogText(output).prefix(lines))
        }
    }

    public func kernelLog() async throws -> [LogEntry] {
        // Only the "-r" form is granted (acl.d luci-mod-status-logs,
        // both test routers); it prefixes each line with <priority>,
        // which the parser strips into the entry's priority field.
        ReadOnlyParser.kernelLog(try await exec(command: "/bin/dmesg", arguments: ["-r"]))
    }

    public func processes() async throws -> [ProcessInfo] {
        let value = try await caller.call(object: "luci", method: "getProcessList")
        return ReadOnlyParser.processes(value)
    }

    public func nftables() async throws -> [NftTable] {
        // The one nft command line rpcd grants to login sessions is
        // the JSON form LuCI's firewall status page itself uses
        // (acl.d luci-mod-status-firewall, verified on both test
        // routers): the plain "list ruleset" form is denied, which was
        // the firewall page's "permission insufficient" failure.
        do {
            let output = try await exec(command: "/usr/sbin/nft",
                                        arguments: ["--terse", "--json", "list", "ruleset"])
            return try ReadOnlyParser.nftablesJSON(output)
        } catch OpenWrtKitError.permissionDenied {
            // Older acl.d sets may grant only the text form; try it
            // before surfacing the denial.
            let output = try await exec(command: "/usr/sbin/nft", arguments: ["list", "ruleset"])
            return ReadOnlyParser.nftables(output)
        }
    }

    // MARK: UCI configuration (read-only here; writes live in phase 2's
    // transaction layer)

    public func configuration(_ name: String) async throws -> RouterConfiguration {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let value = try await caller.call(object: "uci", method: "get", parameters: ["config": .string(name)])
        return try RouterConfiguration.parse(name: name, value: value)
    }

    public func configurationNames() async throws -> [String] {
        let value = try await caller.call(object: "file", method: "list", parameters: ["path": .string("/etc/config")])
        return try InventoryParser.configNames(value)
    }

    // MARK: File plane primitives (read side)

    public func fileRead(path: String) async throws -> String {
        let value = try await caller.call(object: "file", method: "read", parameters: ["path": .string(path)])
        guard let text = value["data"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return text
    }

    public func fileList(path: String) async throws -> [JSONValue] {
        let value = try await caller.call(object: "file", method: "list", parameters: ["path": .string(path)])
        guard let entries = value["entries"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        return entries
    }

    /// Runs a fixed read-only command through rpcd's file exec and returns
    /// stdout. Callers pass complete argument vectors; no shell is involved.
    public func exec(command: String, arguments: [String]) async throws -> String {
        let value = try await caller.call(object: "file", method: "exec", parameters: [
            "command": .string(command), "params": .array(arguments.map(JSONValue.string))
        ])
        guard value["code"].intValue == 0, let output = value["stdout"].stringValue else {
            throw OpenWrtKitError.unsupported(KitL10n.format("路由器未返回 %@ 的输出。", command))
        }
        return output
    }

    // MARK: Session access precheck (batch-2 gating)

    /// Asks rpcd whether THIS session may use one (scope, object,
    /// function) triple — the same question rpcd answers before
    /// every call, asked up front so an entry can be greyed out with
    /// an explanation instead of failing after the fact. Never
    /// throws: a check that cannot be answered reads as "not
    /// granted", which is the safe direction for a gate.
    public func sessionAccess(scope: String, object: String, function: String) async -> Bool {
        guard let value = try? await caller.call(object: "session", method: "access", parameters: [
            "scope": .string(scope), "object": .string(object), "function": .string(function)
        ]) else { return false }
        return value["access"].boolValue == true
    }

    // MARK: Bandwidth data (nlbwmon)

    /// The nlbwmon accounting dump through the action helper LuCI's
    /// bandwidth page uses (`nlbwmon-action download`, granted to
    /// login sessions; the bare `/usr/sbin/nlbw` exec is NOT granted
    /// anywhere, verified 2026-11-21). Default output is the same
    /// JSON dump BandwidthParser already reads. Returns nil when the
    /// helper is refused or absent — the component is not installed
    /// or not exposed to this session — so the page can say exactly
    /// that instead of a generic permission failure.
    public func bandwidthDownload() async throws -> String? {
        let value: JSONValue
        do {
            value = try await caller.call(object: "file", method: "exec", parameters: [
                "command": .string("/usr/libexec/nlbwmon-action"),
                "params": .array([.string("download"), .string("-f"), .string("json")])
            ])
        } catch OpenWrtKitError.permissionDenied {
            return nil
        }
        guard value["code"].intValue == 0, let output = value["stdout"].stringValue else {
            return nil
        }
        return output
    }

    // MARK: Package update check (online upgrade page)

    /// Lists upgradable packages (audit F2) by diffing the router's
    /// installed and available lists, both fetched through the
    /// package-manager helper (cgi-exec) — the channel LuCI's
    /// software page uses. The previous construction probed and ran
    /// the bare opkg/apk binaries over file exec; rpcd grants no
    /// exec key for either binary on any measured firmware, so the
    /// check could only ever report "cannot check" (permission
    /// audit #10). Returns nil when the session cannot query package
    /// lists at all, which the UI presents as "cannot check", never
    /// as "no updates"; a list fetch that fails after the channel
    /// answered throws — a failed check is a failure state, not an
    /// empty conclusion.
    public func upgradablePackages() async throws -> UpgradablePackages? {
        let lists: PackageLists
        do {
            lists = try await caller.packageLists()
        } catch OpenWrtKitError.unsupported {
            return nil
        }
        return UpgradablePackages(
            manager: lists.manager,
            lines: PackageListDiff.upgradableLines(installed: lists.installed,
                                                   available: lists.available))
    }

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
