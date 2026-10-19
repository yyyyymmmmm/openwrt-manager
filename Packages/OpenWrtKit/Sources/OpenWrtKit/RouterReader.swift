import Foundation
import Darwin

public struct RouterReader: Sendable {
    private let client: UbusClient
    private let session: UbusSession

    public init(client: UbusClient, session: UbusSession) {
        self.client = client; self.session = session
    }

    public func snapshot() async throws -> RouterSnapshot {
        async let boardRead = read("system", "board")
        async let infoRead = read("system", "info")
        async let interfaceRead = read("network.interface", "dump")
        let (boardResult, infoResult, interfacesResult) = await (boardRead, infoRead, interfaceRead)
        try Task.checkCancellation()
        if case .failure(let error) = boardResult, case .failure = infoResult { throw error }
        var snapshot = RouterSnapshot()
        var board: JSONValue = .null
        var info: JSONValue = .null
        switch boardResult {
        case .success(let value): board = value
        case .failure(let error): snapshot.warnings.append("硬件信息：\(error.localizedDescription)")
        }
        switch infoResult {
        case .success(let value): info = value
        case .failure(let error): snapshot.warnings.append("运行状态：\(error.localizedDescription)")
        }
        snapshot.system = SnapshotParser.system(board: board, info: info)
        switch interfacesResult {
        case .success(let value):
            do { snapshot.interfaces = try SnapshotParser.interfaces(value) }
            catch { snapshot.warnings.append("网络接口：\(error.localizedDescription)") }
        case .failure(let error): snapshot.warnings.append("网络接口：\(error.localizedDescription)")
        }
        snapshot.refreshedAt = Date()
        return snapshot
    }

    public func leases() async throws -> [DHCPLease] {
        let value = try await client.call(session: session, object: "luci-rpc", method: "getDHCPLeases")
        return try SnapshotParser.leases(value)
    }

    public func routing(interfaces: [NetworkInterfaceSnapshot]) async throws -> RouterRoutingSnapshot {
        async let ipv4Routes = ipOutput(["-4", "route", "show"])
        async let ipv6Routes = ipOutput(["-6", "route", "show"])
        async let ipv4Neighbors = ipOutput(["-4", "neigh", "show"])
        async let ipv6Neighbors = ipOutput(["-6", "neigh", "show"])
        let output = try await (ipv4Routes, ipv6Routes, ipv4Neighbors, ipv6Neighbors)
        return RouterRoutingSnapshot(
            ipv4Routes: try SnapshotParser.routes(output.0),
            ipv6Routes: try SnapshotParser.routes(output.1),
            ipv4Neighbors: try SnapshotParser.neighbors(output.2, interfaces: interfaces),
            ipv6Neighbors: try SnapshotParser.neighbors(output.3, interfaces: interfaces)
        )
    }

    public func wireless() async throws -> [WirelessRadio] {
        let value = try await client.call(session: session, object: "network.wireless", method: "status")
        return try SnapshotParser.wireless(value)
    }

    public func networkProtocols() async throws -> [String] {
        let value = try await client.call(session: session, object: "network", method: "get_proto_handlers")
        guard let handlers = value.objectValue, handlers.values.allSatisfy({ $0.objectValue != nil }) else {
            throw OpenWrtKitError.malformedResponse
        }
        return handlers.keys.sorted()
    }

    public func homeProxyCapabilities() async throws -> HomeProxyCapabilities {
        try HomeProxyCapabilities(value: await pluginCall("luci.homeproxy", "singbox_get_features"))
    }

    public func upnpMappings() async throws -> [UPnPMapping] {
        try UPnPMapping.parse(await pluginCall("luci.upnp", "get_status"))
    }

    public func zeroTierNetworks() async throws -> [ZeroTierNetwork] {
        try ZeroTierNetwork.parse(await zeroTierRead(networks: true))
    }

    private func zeroTierRead(networks: Bool) async throws -> JSONValue {
        let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string("/usr/bin/zerotier-cli"),
            "params": .array([.string("-j"), .string(networks ? "listnetworks" : "info")])
        ])
        let result = try RouterCommandResult(value: value)
        guard result.exitCode == 0 else {
            throw OpenWrtKitError.unsupported("ZeroTier 查询失败（\(result.exitCode)）：\(result.stderr)\n\(result.stdout)")
        }
        guard let data = result.stdout.data(using: .utf8) else { throw OpenWrtKitError.malformedResponse }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw OpenWrtKitError.malformedResponse }
    }

    public func deleteUPnPMapping(_ mapping: UPnPMapping, observed: [UPnPMapping]) async throws -> [UPnPMapping] {
        try await pluginAccess("luci.upnp", "delete_rule")
        let current = try await upnpMappings()
        // The firmware addresses rules by a volatile row token, not a stable ID.
        guard observed.contains(where: { $0.isSameRule(as: mapping) }), current.count == observed.count,
              zip(current, observed).allSatisfy({ $0.0.isSameRule(as: $0.1) }) else {
            throw OpenWrtKitError.unsupported("映射列表已变化，未发送删除请求。请重新读取后选择。")
        }
        // luci.upnp deletes a lease-file line by row number. Firewall rule order
        // need not match lease order, so verify the addressed line as well.
        let configuration = try await client.call(session: session, object: "uci", method: "get", parameters: [
            "config": .string("upnpd"), "section": .string("config"), "option": .string("upnp_lease_file")
        ])
        guard let path = configuration["value"].stringValue, path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\n"), path.utf8.count <= 4096 else {
            throw OpenWrtKitError.unsupported("未确认固件的 UPnP 租约文件，未发送删除请求。")
        }
        let leaseFile = try await client.call(session: session, object: "file", method: "read", parameters: ["path": .string(path)])
        guard let content = leaseFile["data"].stringValue, let index = Int(mapping.token), index > 0 else {
            throw OpenWrtKitError.malformedResponse
        }
        let lines = content.components(separatedBy: "\n")
        guard index <= lines.count else {
            throw OpenWrtKitError.unsupported("映射序号与租约文件不一致，未发送删除请求。")
        }
        let lease = lines[index - 1].split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard lease.count == 6, lease[0].uppercased() == mapping.transport,
              Int(lease[1]) == mapping.externalPort, String(lease[2]) == mapping.internalAddress,
              Int(lease[3]) == mapping.internalPort,
              lease[5].trimmingCharacters(in: .whitespacesAndNewlines) == mapping.description else {
            throw OpenWrtKitError.unsupported("固件映射序号未指向所选租约，未发送删除请求。请重新读取。")
        }
        let result = try await pluginCall("luci.upnp", "delete_rule", ["token": .string(mapping.token)])
        guard result["result"].stringValue == "OK" else {
            throw OpenWrtKitError.unsupported("固件未接受映射删除请求。")
        }
        let refreshed = try await upnpMappings()
        guard !refreshed.contains(where: { $0.hasSameEndpoint(as: mapping) }) else {
            throw OpenWrtKitError.unsupported("删除请求已接受，但映射仍存在或已被客户端重新建立；尚未确认删除成功，请重新读取。")
        }
        return refreshed
    }

    /// Fixed plugin methods only; callers cannot supply objects, executables or paths.
    public func nativePluginRead(_ request: NativePluginRead) async throws -> String {
        switch request {
        case .homeProxyFeatures:
            let capabilities = try await homeProxyCapabilities()
            let flags = capabilities.features.keys.sorted().map { key in
                "\(key)：\(capabilities.features[key] == true ? "支持" : "不支持")"
            }
            return (["sing-box：" + capabilities.version] + flags).joined(separator: "\n")
        case .homeProxyResource(let resource):
            let value = try await pluginCall("luci.homeproxy", "resources_get_version", ["type": .string(resource.rawValue)])
            guard let version = value["version"].stringValue else { throw OpenWrtKitError.malformedResponse }
            return version.isEmpty ? "资源版本为空，请核对资源是否安装。" : version
        case .homeProxyConnection(let google):
            let value = try await pluginCall("luci.homeproxy", "connection_check", ["site": .string(google ? "google" : "baidu")])
            guard let result = value["result"].boolValue else { throw OpenWrtKitError.malformedResponse }
            return result ? "路由器访问该站点成功。此结果仅代表本次站点检查。" : "路由器访问该站点失败。请检查 DNS、上联及代理配置。"
        case .homeProxyLog(let log):
            // A fixed, bounded tail avoids loading an unbounded router log into memory.
            let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                "command": .string("/usr/bin/tail"),
                "params": .array([.string("-n"), .string("200"), .string("/var/run/homeproxy/" + log.rawValue + ".log")])
            ])
            let result = try RouterCommandResult(value: value)
            guard result.exitCode == 0 else { throw OpenWrtKitError.unsupported("日志读取失败（\(result.exitCode)）：\(result.stderr)") }
            return result.stdout
        case .mosDNSVersion:
            let value = try await pluginCall("luci.mosdns", "get_version")
            guard let version = value["version"].stringValue, !version.isEmpty else { throw OpenWrtKitError.malformedResponse }
            return version
        case .mosDNSLog, .mosDNSUpdateLog:
            let method = if case .mosDNSLog = request { "print_log" } else { "get_update_log" }
            let value = try await pluginCall("luci.mosdns", method)
            guard let log = value["log"].stringValue else { throw OpenWrtKitError.malformedResponse }
            return log.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        case .zeroTierInfo:
            let value = try await zeroTierRead(networks: false)
            guard let address = value["address"].stringValue, !address.isEmpty,
                  let version = value["version"].stringValue, let online = value["online"].boolValue else { throw OpenWrtKitError.malformedResponse }
            return "节点：\(address)\n版本：\(version)\nZeroTier 客户端：\(online ? "ONLINE" : "OFFLINE")\n此状态不代表某个虚拟网络已授权或已连通。"
        }
    }

    public func nativePluginAction(_ action: NativePluginAction) async throws -> String {
        switch action {
        case .homeProxyResource(let resource):
            try await pluginAccess("luci.homeproxy", "resources_update")
            let value = try await pluginCall("luci.homeproxy", "resources_update", ["type": .string(resource.rawValue)])
            guard let status = value["status"].intValue else { throw OpenWrtKitError.malformedResponse }
            switch status {
            case 0: return "资源更新程序返回成功。请重新读取资源版本。"
            case 2: return "固件报告已有更新正在进行；本次没有启动新的更新。请稍后重新读取版本。"
            case 3: return "固件报告当前资源已是最新版本。"
            default: throw OpenWrtKitError.unsupported("资源更新失败，固件状态码：\(status)。")
            }
        case .homeProxySubscriptions:
            try await pluginAccess("file", "exec")
            let changes = try await client.call(session: session, object: "uci", method: "changes")
            guard let existing = changes["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
            guard existing.isEmpty else { throw ConfigurationError.existingChanges }
            let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                "command": .string("/etc/homeproxy/scripts/update_subscriptions.uc"), "params": .array([])
            ])
            let result = try RouterCommandResult(value: value)
            guard result.exitCode == 0 else { throw OpenWrtKitError.unsupported("订阅更新程序失败（\(result.exitCode)）：\(result.stderr)\n\(result.stdout)") }
            return "订阅更新程序返回退出码 0；请重新读取节点配置及日志核对各订阅结果。\n" + result.stdout + result.stderr
        case .mosDNSFlushCache, .mosDNSUpdate:
            let method = if case .mosDNSFlushCache = action { "flush_cache" } else { "start_update" }
            try await pluginAccess("luci.mosdns", method)
            let value = try await pluginCall("luci.mosdns", method)
            guard let success = value["success"].boolValue else { throw OpenWrtKitError.malformedResponse }
            guard success else { throw OpenWrtKitError.unsupported("MosDNS 未确认操作成功。") }
            if case .mosDNSUpdate = action { return "固件已接受后台更新请求。尚未确认更新完成，请读取规则更新日志。" }
            return "MosDNS 已确认清空缓存。"
        }
    }

    private func pluginCall(_ object: String, _ method: String, _ parameters: [String: JSONValue] = [:]) async throws -> JSONValue {
        let value = try await client.call(session: session, object: object, method: method, parameters: parameters)
        guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
        if value["error"] != .null {
            guard let message = value["error"].stringValue else { throw OpenWrtKitError.malformedResponse }
            if !message.isEmpty { throw OpenWrtKitError.unsupported(message) }
        }
        return value
    }

    private func pluginAccess(_ object: String, _ method: String) async throws {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string(object), "function": .string(method)
        ])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        guard allowed else { throw OpenWrtKitError.permissionDenied }
    }

    public func diagnose(tool: DiagnosticTool, host: String) async throws -> RouterCommandResult {
        let arguments = try tool.arguments(host: host)
        let result = try await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string(tool.executable), "params": .array(arguments.map(JSONValue.string))
        ])
        return try RouterCommandResult(value: result)
    }

    public func reboot() async throws {
        let access = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("system"), "function": .string("reboot")
        ])
        guard let allowed = access["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        guard allowed else { throw OpenWrtKitError.permissionDenied }
        _ = try await client.call(session: session, object: "system", method: "reboot")
    }

    public func services() async throws -> [RouterService] {
        let value = try await client.call(session: session, object: "service", method: "list")
        return try SnapshotParser.services(value)
    }

    public func inventory() async -> RouterInventory {
        async let menu = capture { try InventoryParser.menus(await client.menu(session: session)) }
        async let packages = capture { try await client.installedPackages(session: session) }
        async let configs = capture { try InventoryParser.configNames(await client.call(session: session, object: "file", method: "list", parameters: ["path": .string("/etc/config")])) }
        async let startup = capture { try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList")) }
        let results = await (menu, packages, configs, startup)
        var inventory = RouterInventory()
        switch results.0 {
        case .success(let value): inventory.menus = value; inventory.menuRead = true
        case .failure(let error): inventory.warnings.append("功能目录：\(error.localizedDescription)")
        }
        switch results.1 {
        case .success(let value): inventory.packages = value; inventory.packagesRead = true
        case .failure(let error): inventory.warnings.append("软件包：\(error.localizedDescription)")
        }
        switch results.2 {
        case .success(let value): inventory.configNames = value; inventory.configsRead = true
        case .failure(let error): inventory.warnings.append("配置目录：\(error.localizedDescription)")
        }
        switch results.3 {
        case .success(let value): inventory.initServices = value; inventory.initRead = true
        case .failure(let error): inventory.warnings.append("启动项：\(error.localizedDescription)")
        }
        return inventory
    }

    public func serviceAction(name: String, action: ServiceAction) async throws {
        guard InventoryParser.validIdentifier(name) else { throw ConfigurationError.invalidIdentifier }
        let initList = try InventoryParser.initServices(await client.call(session: session, object: "luci", method: "getInitList"))
        guard initList.contains(where: { $0.name == name }) else { throw OpenWrtKitError.unsupported("此服务不在路由器的启动项目录中。") }
        let access = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("luci"), "function": .string("setInitAction")
        ])
        guard access["access"].boolValue == true else { throw OpenWrtKitError.permissionDenied }
        let value = try await client.call(session: session, object: "luci", method: "setInitAction", parameters: [
            "name": .string(name), "action": .string(action.rawValue)
        ])
        guard value["result"].boolValue == true else { throw OpenWrtKitError.unsupported("路由器未确认服务操作成功，请检查日志和当前状态。") }
    }

    public func records(_ kind: RouterRecordKind) async throws -> [JSONValue] {
        switch kind {
        case .logs:
            let value = try await client.call(session: session, object: "log", method: "read", parameters: [
                "lines": .number(200), "oneshot": .bool(true), "stream": .bool(false)
            ])
            guard let records = value["log"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
        case .kernelLogs:
            let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                "command": .string("/bin/dmesg"), "params": .array([.string("-r")])
            ])
            let result = try RouterCommandResult(value: value)
            guard result.exitCode == 0 else {
                throw OpenWrtKitError.unsupported("内核日志读取失败（\(result.exitCode)）：\(result.stderr)")
            }
            return result.stdout.split(separator: "\n").map { .string(String($0)) }
        case .processes, .mounts:
            let method = kind == .processes ? "getProcessList" : "getMountPoints"
            let value = try await client.call(session: session, object: "luci", method: method)
            guard let records = value["result"].arrayValue else { throw OpenWrtKitError.malformedResponse }
            return records
        }
    }

    public func processes() async throws -> [RouterProcess] {
        try RouterProcess.parse(await records(.processes))
    }

    public func scheduledTasks() async throws -> ScheduledTasksSnapshot {
        try await ScheduledTasksClient(client: client, session: session).read()
    }

    public func scheduledTasksWritable() async throws -> Bool {
        try await ScheduledTasksClient(client: client, session: session).writable()
    }

    public func saveScheduledTasks(observed: ScheduledTasksSnapshot, text: String) async throws -> ScheduledTasksSaveResult {
        try await ScheduledTasksClient(client: client, session: session).save(observed: observed, text: text)
    }

    public func reloadScheduledTasks(observed: ScheduledTasksSnapshot) async -> ScheduledTasksSaveResult {
        await ScheduledTasksClient(client: client, session: session).reload(observed)
    }

    public func processIdentity(_ observed: RouterProcess) async throws -> RouterProcessIdentity {
        let before = try await processStartTime(observed.pid)
        guard let current = try await processes().first(where: { $0.pid == observed.pid }), current.matches(observed),
              try await processStartTime(observed.pid) == before else {
            throw OpenWrtKitError.unsupported("进程已变化或退出。请返回列表重新读取。")
        }
        return RouterProcessIdentity(process: current, startTime: before)
    }

    private func processStartTime(_ pid: Int) async throws -> String {
        guard pid > 0 else { throw OpenWrtKitError.malformedResponse }
        let value = try await client.call(session: session, object: "file", method: "read", parameters: [
            "path": .string("/proc/\(pid)/stat")
        ])
        guard let text = value["data"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return try RouterProcessIdentity.startTime(text, pid: pid)
    }

    public func signalProcess(_ identity: RouterProcessIdentity, signal: RouterProcessSignal) async throws -> String {
        guard identity.process.pid > 1 else {
            throw OpenWrtKitError.unsupported("不能向 PID 1 发送进程信号。路由器维护请使用明确的系统重启流程。")
        }
        try await pluginAccess("file", "exec")
        let current = try await processIdentity(identity.process)
        guard current.startTime == identity.startTime else {
            throw OpenWrtKitError.unsupported("原进程已退出且 PID 已被重新使用，未发送信号。请重新读取。")
        }
        let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string("/bin/kill"),
            "params": .array([.string("-\(signal.rawValue)"), .string(String(identity.process.pid))])
        ])
        let result = try RouterCommandResult(value: value)
        guard result.exitCode == 0 else {
            throw OpenWrtKitError.unsupported("信号程序失败（\(result.exitCode)）：\(result.stderr)\n\(result.stdout)")
        }
        // Sending a signal does not prove application-level completion. A process
        // may ignore TERM, reload after HUP, or be immediately restarted by procd.
        do {
            let refreshed = try await processes()
            guard let remaining = refreshed.first(where: { $0.pid == identity.process.pid }) else {
                return "信号程序返回 0；重新读取进程列表时已无此 PID。服务仍可能重新启动，请返回列表刷新。"
            }
            let start = try await processStartTime(remaining.pid)
            if start == identity.startTime {
                return "信号程序返回 0；原进程仍存在。不能据此确认配置重新加载或进程退出。"
            }
            return "信号程序返回 0；同一 PID 已对应另一进程。请返回列表重新读取。"
        } catch {
            return "信号程序返回 0，但操作后读取失败：\(error.localizedDescription)。业务结果尚未确认，请重新读取。"
        }
    }

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    public func logout() async {
        _ = try? await client.call(session: session, object: "session", method: "destroy")
    }

    private func read(_ object: String, _ method: String) async -> Result<JSONValue, Error> {
        do {
            let value = try await client.call(session: session, object: object, method: method)
            guard value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            return .success(value)
        }
        catch { return .failure(error) }
    }

    private func ipOutput(_ arguments: [String]) async throws -> String {
        let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string("/sbin/ip"), "params": .array(arguments.map(JSONValue.string))
        ])
        guard value["code"].intValue == 0, let output = value["stdout"].stringValue else {
            if let error = value["stderr"].stringValue, !error.isEmpty {
                throw OpenWrtKitError.unsupported("读取路由器路由/邻居表失败：\(error)")
            }
            throw OpenWrtKitError.malformedResponse
        }
        return output
    }
}

public enum RouterRecordKind: String, CaseIterable, Identifiable, Sendable {
    case logs, kernelLogs, processes, mounts
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .logs: return "系统日志"
        case .kernelLogs: return "内核日志"
        case .processes: return "运行进程"
        case .mounts: return "存储挂载"
        }
    }
}

public enum SnapshotParser {
    public static func system(board: JSONValue, info: JSONValue) -> SystemSnapshot {
        var result = SystemSnapshot()
        result.hostname = board["hostname"].stringValue ?? "—"
        result.model = board["model"].stringValue ?? board["board_name"].stringValue ?? "—"
        result.kernel = board["kernel"].stringValue ?? "—"
        result.architecture = board["release"]["target"].stringValue ?? board["system"].stringValue ?? "—"
        let release = board["release"]
        let firmware = [release["distribution"].stringValue, release["version"].stringValue].compactMap { $0 }.joined(separator: " ")
        result.firmware = firmware.isEmpty ? "—" : firmware
        result.uptime = info["uptime"].doubleValue
        if let total = info["memory"]["total"].intValue, total > 0 {
            let available = info["memory"]["available"].intValue ?? info["memory"]["free"].intValue
            result.memoryTotal = Int64(total)
            if let available { result.memoryUsed = Int64(max(0, total - available)) }
        }
        if let total = info["root"]["total"].intValue, let used = info["root"]["used"].intValue, total > 0 {
            result.storageTotal = Int64(total); result.storageUsed = Int64(used)
        }
        // system.info load values are fixed point (scaled by 65536), not CPU %.
        result.loadAverage = (info["load"].arrayValue ?? []).compactMap { $0.doubleValue.map { $0 / 65536 } }
        return result
    }

    public static func interfaces(_ value: JSONValue) throws -> [NetworkInterfaceSnapshot] {
        guard let items = value["interface"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        return try items.map { item in
            guard let name = item["interface"].stringValue, !name.isEmpty else { throw OpenWrtKitError.malformedResponse }
            let addresses = try ["ipv4-address", "ipv6-address"].flatMap { key -> [String] in
                guard item[key] != .null else { return [] }
                guard let reported = item[key].arrayValue else { throw OpenWrtKitError.malformedResponse }
                return try reported.map { address in
                    guard let ip = address["address"].stringValue, !ip.isEmpty else { throw OpenWrtKitError.malformedResponse }
                    return ip + (address["mask"].intValue.map { "/\($0)" } ?? "")
                }
            }
            let routes: [JSONValue]
            if item["route"] == .null { routes = [] }
            else if let reported = item["route"].arrayValue { routes = reported }
            else { throw OpenWrtKitError.malformedResponse }
            let defaults = try routes.compactMap { route -> InterfaceDefaultRoute? in
                guard let target = route["target"].stringValue, let mask = route["mask"].intValue else {
                    throw OpenWrtKitError.malformedResponse
                }
                guard mask == 0, ["0.0.0.0", "::"].contains(target) else { return nil }
                let gateway = route["nexthop"].stringValue
                if let gateway, !validIPAddress(gateway) { throw OpenWrtKitError.malformedResponse }
                return InterfaceDefaultRoute(ipv6: target == "::", gateway: gateway, metric: route["metric"].intValue)
            }
            let dns: [String]
            if item["dns-server"] == .null { dns = [] }
            else {
                guard let list = item["dns-server"].arrayValue,
                      list.allSatisfy({ $0.stringValue.map(validIPAddress) == true }) else { throw OpenWrtKitError.malformedResponse }
                dns = list.compactMap(\.stringValue)
            }
            let errors: [String]
            if item["errors"] == .null { errors = [] }
            else {
                guard let list = item["errors"].arrayValue else { throw OpenWrtKitError.malformedResponse }
                errors = try list.map { error in
                    guard let code = error["code"].stringValue else { throw OpenWrtKitError.malformedResponse }
                    return [error["subsystem"].stringValue, code].compactMap { $0 }.joined(separator: ": ")
                }
            }
            return NetworkInterfaceSnapshot(name: name, protocolName: item["proto"].stringValue ?? "—", addresses: addresses,
                                            up: item["up"].boolValue, device: item["l3_device"].stringValue,
                                            defaultRoutes: defaults, dnsServers: dns, errors: errors)
        }.sorted { $0.name < $1.name }
    }

    public static func leases(_ value: JSONValue) throws -> [DHCPLease] {
        var reported: [JSONValue] = []
        var hasList = false
        for key in ["dhcp_leases", "dhcp6_leases"] where value[key] != .null {
            guard let leases = value[key].arrayValue else { throw OpenWrtKitError.malformedResponse }
            hasList = true
            reported.append(contentsOf: leases)
        }
        guard hasList else { throw OpenWrtKitError.malformedResponse }
        var seen = Set<String>()
        return try reported.compactMap { item -> DHCPLease? in
            let address = item["ipaddr"].stringValue
                ?? item["ip6addr"].stringValue
                ?? item["ip6addrs"].arrayValue?.first?.stringValue
            guard let address, !address.isEmpty else { throw OpenWrtKitError.malformedResponse }
            let lease = DHCPLease(hostname: item["hostname"].stringValue ?? "未命名设备", address: address,
                                  mac: item["macaddr"].stringValue ?? "—",
                                  expires: item["expires"].intValue, duid: item["duid"].stringValue)
            return seen.insert(lease.id).inserted ? lease : nil
        }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }

    public static func routes(_ text: String) throws -> [IPRouteRecord] {
        try text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { raw in
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            let types: Set<String> = ["unicast", "local", "broadcast", "multicast", "throw", "unreachable", "prohibit", "blackhole", "nat", "anycast"]
            let destinationIndex = fields.first.map { types.contains($0) } == true ? 1 : 0
            guard fields.indices.contains(destinationIndex) else { throw OpenWrtKitError.malformedResponse }
            let destination = fields[destinationIndex]
            guard destination == "default" || validIPPrefix(destination),
                  ["via", "dev", "proto", "metric"].allSatisfy({ key in
                      fields.firstIndex(of: key).map { fields.indices.contains($0 + 1) } ?? true
                  }) else { throw OpenWrtKitError.malformedResponse }
            func value(after key: String) -> String? {
                guard let index = fields.firstIndex(of: key), fields.indices.contains(index + 1) else { return nil }
                return fields[index + 1]
            }
            if let gateway = value(after: "via"), !validIPAddress(gateway) { throw OpenWrtKitError.malformedResponse }
            if let metric = value(after: "metric"), UInt32(metric) == nil { throw OpenWrtKitError.malformedResponse }
            return IPRouteRecord(destination: destination, gateway: value(after: "via"), device: value(after: "dev"),
                                 protocolName: value(after: "proto"), metric: value(after: "metric"), rawValue: raw)
        }
    }

    public static func neighbors(_ text: String, interfaces: [NetworkInterfaceSnapshot]) throws -> [IPNeighborRecord] {
        let states: Set<String> = ["INCOMPLETE", "REACHABLE", "STALE", "DELAY", "PROBE", "FAILED", "NOARP", "PERMANENT"]
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let address = fields.first, validIPAddress(address),
                  let deviceIndex = fields.firstIndex(of: "dev"), fields.indices.contains(deviceIndex + 1),
                  let state = fields.first(where: { states.contains($0.uppercased()) }) else {
                throw OpenWrtKitError.malformedResponse
            }
            let device = fields[deviceIndex + 1]
            let mac: String?
            if let macIndex = fields.firstIndex(of: "lladdr") {
                guard fields.indices.contains(macIndex + 1) else { throw OpenWrtKitError.malformedResponse }
                let octets = fields[macIndex + 1].split(separator: ":", omittingEmptySubsequences: false)
                guard octets.count == 6, octets.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { throw OpenWrtKitError.malformedResponse }
                mac = fields[macIndex + 1]
            } else {
                mac = nil
            }
            let interface = interfaces.first(where: { $0.device == device })?.name ?? device
            return IPNeighborRecord(address: address, mac: mac, device: device, interface: interface, state: state.uppercased())
        }
    }

    private static func validIPAddress(_ text: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return text.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    private static func validIPPrefix(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), validIPAddress(String(parts[0])) else { return false }
        guard parts.count == 2 else { return true }
        guard let bits = Int(parts[1]) else { return false }
        return (0...(parts[0].contains(":") ? 128 : 32)).contains(bits)
    }

    public static func wireless(_ value: JSONValue) throws -> [WirelessRadio] {
        guard let radios = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try radios.map { name, radio in
            guard radio.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            let interfaces: [JSONValue]
            if radio["interfaces"] == .null { interfaces = [] }
            else {
                guard let reported = radio["interfaces"].arrayValue else { throw OpenWrtKitError.malformedResponse }
                interfaces = reported
            }
            guard interfaces.allSatisfy({ $0.objectValue != nil }) else { throw OpenWrtKitError.malformedResponse }
            return WirelessRadio(name: name, up: radio["up"].boolValue, channel: radio["config"]["channel"].textValue ?? "未报告",
                                 networks: interfaces.compactMap { $0["config"]["ssid"].stringValue })
        }.sorted { $0.name < $1.name }
    }

    public static func services(_ value: JSONValue) throws -> [RouterService] {
        guard let services = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try services.map { name, service in
            guard service.objectValue != nil,
                  service["instances"] == .null || service["instances"].objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            let instances = service["instances"].objectValue.map { Array($0.values) }
            guard instances?.allSatisfy({ $0.objectValue != nil }) != false else { throw OpenWrtKitError.malformedResponse }
            let running = instances.flatMap { values -> Int? in
                guard values.allSatisfy({ $0["running"].boolValue != nil }) else { return nil }
                return values.filter { $0["running"].boolValue == true }.count
            }
            return RouterService(name: name, runningInstances: running, totalInstances: instances?.count)
        }.sorted { $0.name < $1.name }
    }
}
