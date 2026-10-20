import Foundation

public enum WakeOnLANTool: String, CaseIterable, Identifiable, Sendable {
    case etherwake = "/usr/bin/etherwake", wakeonlan = "/usr/bin/wakeonlan"
    public var id: String { rawValue }
    public var title: String { self == .etherwake ? "Etherwake" : "Wakeonlan" }
}

public struct WakeOnLANCapabilities: Equatable, Sendable {
    public let tools: [WakeOnLANTool]
    public init(value: JSONValue) throws {
        guard let etherwake = value["etherwake"].boolValue,
              let wakeonlan = value["wakeonlan"].boolValue else { throw OpenWrtKitError.malformedResponse }
        tools = (etherwake ? [.etherwake] : []) + (wakeonlan ? [.wakeonlan] : [])
    }
}

public struct WakeOnLANHost: Identifiable, Sendable {
    public let mac: String
    public let name: String?
    public let addresses: [String]
    public var id: String { mac }
    public var label: String { ([name].compactMap { $0 }.filter { !$0.isEmpty } + addresses).joined(separator: " · ") }

    static func parse(_ value: JSONValue) throws -> [Self] {
        guard let hosts = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try hosts.sorted { $0.key < $1.key }.map { mac, value in
            guard WakeOnLANTarget.validMAC(mac), value.objectValue != nil,
                  value["name"] == .null || value["name"].stringValue != nil else { throw OpenWrtKitError.malformedResponse }
            var addresses: [String] = []
            for key in ["ipaddrs", "ipv4", "ip6addrs", "ipv6"] where value[key] != .null {
                let items: [JSONValue]
                if let list = value[key].arrayValue { items = list }
                else if let address = value[key].stringValue { items = [.string(address)] }
                else { throw OpenWrtKitError.malformedResponse }
                for item in items {
                    guard let address = item.stringValue else { throw OpenWrtKitError.malformedResponse }
                    if !addresses.contains(address) { addresses.append(address) }
                }
            }
            return Self(mac: mac, name: value["name"].stringValue, addresses: addresses)
        }
    }
}

public struct WakeOnLANDevice: Identifiable, Equatable, Sendable {
    public let name: String
    public let up: Bool?
    public var id: String { name }
    static func parse(_ value: JSONValue) throws -> [Self] {
        guard let devices = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return try devices.sorted { $0.key < $1.key }.map { name, value in
            guard WakeOnLANTarget.validInterface(name), value.objectValue != nil else { throw OpenWrtKitError.malformedResponse }
            for flag in [value["flags"]["up"], value["up"]] where flag != .null {
                guard flag.boolValue != nil else { throw OpenWrtKitError.malformedResponse }
            }
            let flagsUp = value["flags"]["up"].boolValue, linkUp = value["up"].boolValue
            let up: Bool? = flagsUp == false || linkUp == false ? false : flagsUp ?? linkUp
            return Self(name: name, up: up)
        }
    }
}

/// Reads actual UCI target fields without inventing default values in storage.
public struct WakeOnLANTarget: Equatable, Sendable {
    public let section: ConfigurationSection
    public let name: String
    public let mac: String
    public let interface: String?
    public let broadcast: Bool
    public let password: String?
    public init(section: ConfigurationSection) throws {
        guard section.type == "target" else { throw ConfigurationError.invalidValue }
        func field(_ key: String) throws -> String? {
            guard let value = section.values[key] else { return nil }
            guard let text = value.stringValue, !text.contains("\0") else { throw ConfigurationError.invalidValue }
            return text.isEmpty ? nil : text
        }
        guard let name = try field("name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mac = try field("mac"), Self.validMAC(mac) else {
            throw OpenWrtKitError.unsupported("目标需要名称和六组十六进制 MAC 地址。")
        }
        let interface = try field("iface"), password = try field("password"), flag = try field("broadcast")
        guard interface.map(Self.validInterface) ?? true else { throw OpenWrtKitError.unsupported("接口名称无效。") }
        guard password.map(Self.validPassword) ?? true else { throw OpenWrtKitError.unsupported("唤醒密码须为六组十六进制或四组十进制字节。") }
        guard flag == nil || ["0", "1"].contains(flag!) else { throw OpenWrtKitError.unsupported("广播选项不是固件支持的 0 或 1。") }
        self.section = section; self.name = name; self.mac = mac
        self.interface = interface; self.password = password; broadcast = flag == "1"
    }

    public static func validMAC(_ value: String) -> Bool {
        let bytes = value.split(separator: ":", omittingEmptySubsequences: false)
        return bytes.count == 6 && bytes.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }
    }
    public static func validPassword(_ value: String) -> Bool {
        if validMAC(value) { return true }
        let bytes = value.split(separator: ".", omittingEmptySubsequences: false)
        return bytes.count == 4 && bytes.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil }
    }
    public static func validInterface(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 16 && value != "." && value != ".." &&
        !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" || $0 == ":" || $0 == "\0" })
    }
    public func arguments(tool: WakeOnLANTool) -> [String] {
        guard tool == .etherwake else { return [mac] }
        var args = ["-D"]
        if let interface { args += ["-i", interface] }
        if broadcast { args.append("-b") }
        if let password { args += ["-p", password] }
        args.append(mac)
        return args
    }
    public var hasEtherwakeOptions: Bool { interface != nil || broadcast || password != nil }
}

public struct WakeOnLANTargetStatus: Identifiable, Sendable {
    public let section: ConfigurationSection
    public let target: WakeOnLANTarget?
    public let error: String?
    public var id: String { section.id }
    init(section: ConfigurationSection) {
        self.section = section
        do { target = try WakeOnLANTarget(section: section); error = nil }
        catch { target = nil; self.error = error.localizedDescription }
    }
}

public struct WakeOnLANSnapshot: Sendable {
    public let configuration: RouterConfiguration?
    public let capabilities: WakeOnLANCapabilities?
    public let hosts: [WakeOnLANHost]?
    public let devices: [WakeOnLANDevice]?
    public let canSend: Bool?
    public let issues: [String: String]
    public let readAt: Date
    public var targets: [WakeOnLANTargetStatus]? {
        configuration.map { $0.sections.filter { $0.type == "target" }.map { WakeOnLANTargetStatus(section: $0) } }
    }
}

public enum WakeOnLANError: LocalizedError, Sendable {
    case uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .uncertain(let detail): return "发送结果未确认：\(detail)。可能已经发出唤醒包；不会自动重试，请先检查目标设备。"
        }
    }
}

struct WakeOnLANClient: Sendable {
    let client: UbusClient
    let session: UbusSession
    func read() async -> WakeOnLANSnapshot {
        var configuration: RouterConfiguration?, capabilities: WakeOnLANCapabilities?
        var hosts: [WakeOnLANHost]?, devices: [WakeOnLANDevice]?, canSend: Bool?
        var issues: [String: String] = [:]
        do { configuration = try await config() } catch { issues["目标配置"] = error.localizedDescription }
        do { capabilities = try await tools() } catch { issues["唤醒工具"] = error.localizedDescription }
        do { hosts = try WakeOnLANHost.parse(await call("luci-rpc", "getHostHints")) } catch { issues["主机提示"] = error.localizedDescription }
        do { devices = try WakeOnLANDevice.parse(await call("luci-rpc", "getNetworkDevices")) } catch { issues["网络设备"] = error.localizedDescription }
        do { canSend = try await access() } catch { issues["发送权限"] = error.localizedDescription }
        return WakeOnLANSnapshot(configuration: configuration, capabilities: capabilities, hosts: hosts,
                                 devices: devices, canSend: canSend, issues: issues, readAt: Date())
    }

    func send(sectionID: String, tool: WakeOnLANTool, observed: RouterConfiguration) async throws -> RouterCommandResult {
        guard try await access() else { throw OpenWrtKitError.permissionDenied }
        let changes = try await call("uci", "changes")
        guard let pending = changes["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
        guard pending.isEmpty else { throw ConfigurationError.existingChanges }
        let current = try await config()
        guard current == observed else { throw ConfigurationError.changedElsewhere }
        guard let section = current.sections.first(where: { $0.id == sectionID }) else { throw ConfigurationError.changedElsewhere }
        let target = try WakeOnLANTarget(section: section)
        guard try await tools().tools.contains(tool) else { throw OpenWrtKitError.unsupported("所选唤醒工具已不可用，请重新读取后选择。") }
        if tool == .etherwake, let interface = target.interface {
            let devices = try WakeOnLANDevice.parse(await call("luci-rpc", "getNetworkDevices"))
            guard let device = devices.first(where: { $0.name == interface }), device.up == true else {
                throw OpenWrtKitError.unsupported("所选网络设备不存在、未启用或无法确认状态，未发送唤醒包。")
            }
        }
        try Task.checkCancellation()
        do {
            let value = try await call("luci.wol", "exec", ["name": .string(tool.rawValue), "args": .array(target.arguments(tool: tool).map(JSONValue.string))])
            return try RouterCommandResult(value: value)
        } catch { throw WakeOnLANError.uncertain(error.localizedDescription) }
    }
    private func config() async throws -> RouterConfiguration {
        try RouterConfiguration.parse(name: "luci-wol", value: await call("uci", "get", ["config": .string("luci-wol")]))
    }
    private func tools() async throws -> WakeOnLANCapabilities {
        try WakeOnLANCapabilities(value: await call("luci.wol", "stat"))
    }
    private func access() async throws -> Bool {
        let value = try await call("session", "access", ["scope": .string("ubus"), "object": .string("luci.wol"), "function": .string("exec")])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }
    private func call(_ object: String, _ method: String, _ parameters: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await client.call(session: session, object: object, method: method, parameters: parameters)
    }
}
