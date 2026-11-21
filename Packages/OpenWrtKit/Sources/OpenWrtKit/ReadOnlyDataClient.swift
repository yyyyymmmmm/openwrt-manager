import Foundation

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
        case .failure(let error): snapshot.warnings.append(KitL10n.format("硬件信息：%@", error.localizedDescription))
        }
        switch infoResult {
        case .success(let value): infoValue = value
        case .failure(let error): snapshot.warnings.append(KitL10n.format("运行状态：%@", error.localizedDescription))
        }
        snapshot.system = SnapshotParser.system(board: boardValue, info: infoValue)
        switch dumpResult {
        case .success(let value):
            do { snapshot.interfaces = try SnapshotParser.interfaces(value) }
            catch { snapshot.warnings.append(KitL10n.format("网络接口：%@", error.localizedDescription)) }
        case .failure(let error): snapshot.warnings.append(KitL10n.format("网络接口：%@", error.localizedDescription))
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

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
