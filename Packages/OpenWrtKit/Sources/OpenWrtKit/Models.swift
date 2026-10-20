import Foundation

public struct UbusRequest: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: Int
    public let method = "call"
    public let params: [JSONValue]

    public init(id: Int = 1, session: String, object: String, method: String, parameters: [String: JSONValue]) {
        self.id = id
        self.params = [.string(session), .string(object), .string(method), .object(parameters)]
    }

    public static func login(id: Int = 1, username: String, password: String) -> UbusRequest {
        UbusRequest(id: id, session: String(repeating: "0", count: 32), object: "session", method: "login", parameters: [
            "username": .string(username), "password": .string(password), "timeout": .number(3600)
        ])
    }
}

public struct UbusResponse: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: Int?
    public let result: [JSONValue]?
    public let error: UbusError?
}

public struct UbusError: Decodable, Error, Sendable {
    public let code: Int?
    public let message: String?
}

public struct UbusSession: Sendable, Equatable {
    public let token: String
    public let expiresIn: Int
    public init(token: String, expiresIn: Int = 3600) {
        self.token = token; self.expiresIn = expiresIn
    }
}

public struct SystemSnapshot: Equatable, Sendable {
    public var hostname = "—"
    public var model = "—"
    public var firmware = "—"
    public var kernel = "—"
    public var architecture = "—"
    public var uptime: TimeInterval?
    public var memoryUsed: Int64?
    public var memoryTotal: Int64?
    public var storageUsed: Int64?
    public var storageTotal: Int64?
    public var loadAverage: [Double] = []
    public init() {}
}

public struct InterfaceDefaultRoute: Equatable, Sendable {
    public let ipv6: Bool
    public let gateway: String?
    public let metric: Int?
    public init(ipv6: Bool, gateway: String?, metric: Int?) {
        self.ipv6 = ipv6; self.gateway = gateway; self.metric = metric
    }
}

public struct NetworkInterfaceSnapshot: Identifiable, Equatable, Sendable {
    public let name: String
    public let protocolName: String
    public let addresses: [String]
    public let up: Bool?
    public let device: String?
    public let defaultRoutes: [InterfaceDefaultRoute]
    public let dnsServers: [String]
    public let errors: [String]
    /// nil means the firmware omitted the list; [] means it explicitly reported no prefixes.
    public let delegatedIPv6Prefixes: [InterfaceIPv6Prefix]?
    public let assignedIPv6Prefixes: [InterfaceIPv6Prefix]?
    public var id: String { name }
    public init(name: String, protocolName: String, addresses: [String], up: Bool?, device: String? = nil,
                defaultRoutes: [InterfaceDefaultRoute] = [], dnsServers: [String] = [], errors: [String] = [],
                delegatedIPv6Prefixes: [InterfaceIPv6Prefix]? = nil, assignedIPv6Prefixes: [InterfaceIPv6Prefix]? = nil) {
        self.name = name; self.protocolName = protocolName
        self.addresses = addresses; self.up = up; self.device = device
        self.defaultRoutes = defaultRoutes; self.dnsServers = dnsServers; self.errors = errors
        self.delegatedIPv6Prefixes = delegatedIPv6Prefixes; self.assignedIPv6Prefixes = assignedIPv6Prefixes
    }
}

public struct RouterSnapshot: Equatable, Sendable {
    public var system = SystemSnapshot()
    public var interfaces: [NetworkInterfaceSnapshot] = []
    public var warnings: [String] = []
    public var refreshedAt = Date()
    /// netifd reports actual default routes on LAN as well as WAN (including side routers).
    public var upstreamInterfaces: [NetworkInterfaceSnapshot] {
        interfaces.filter { $0.up == true && !$0.defaultRoutes.isEmpty }.sorted { left, right in
            let l4 = left.defaultRoutes.contains { !$0.ipv6 }, r4 = right.defaultRoutes.contains { !$0.ipv6 }
            if l4 != r4 { return l4 }
            let lm = left.defaultRoutes.compactMap(\.metric).min() ?? Int.max
            let rm = right.defaultRoutes.compactMap(\.metric).min() ?? Int.max
            return lm == rm ? left.name < right.name : lm < rm
        }
    }
    public init() {}
}

public struct DHCPLease: Identifiable, Equatable, Sendable {
    public let hostname: String
    public let address: String
    public let mac: String
    public let duid: String?
    public let expires: Int?
    public var id: String { mac + "|" + address }
    public init(hostname: String, address: String, mac: String, expires: Int?, duid: String? = nil) {
        self.hostname = hostname; self.address = address; self.mac = mac; self.expires = expires; self.duid = duid
    }
}

public struct IPRouteRecord: Identifiable, Equatable, Sendable {
    public let destination: String
    public let gateway: String?
    public let device: String?
    public let protocolName: String?
    public let metric: String?
    public let rawValue: String
    public let table: String?
    public let source: String?
    public let routeType: String?
    public var id: String { rawValue }

    public init(destination: String, gateway: String?, device: String?, protocolName: String?, metric: String?, rawValue: String,
                table: String? = nil, source: String? = nil, routeType: String? = nil) {
        self.destination = destination
        self.gateway = gateway
        self.device = device
        self.protocolName = protocolName
        self.metric = metric
        self.rawValue = rawValue
        self.table = table; self.source = source; self.routeType = routeType
    }
}

public struct IPNeighborRecord: Identifiable, Equatable, Sendable {
    public let address: String
    public let mac: String?
    public let device: String
    public let interface: String
    public let state: String
    public let rawValue: String?
    public var id: String { address + "|" + device }

    public init(address: String, mac: String?, device: String, interface: String, state: String, rawValue: String? = nil) {
        self.address = address
        self.mac = mac
        self.device = device
        self.interface = interface
        self.state = state
        self.rawValue = rawValue
    }
}

public struct RouterRoutingSnapshot: Equatable, Sendable {
    public var routes4: RoutingRead<[IPRouteRecord]>
    public var routes6: RoutingRead<[IPRouteRecord]>
    public var neighbors4: RoutingRead<[IPNeighborRecord]>
    public var neighbors6: RoutingRead<[IPNeighborRecord]>
    public var rules4: RoutingRead<[IPRuleRecord]>
    public var rules6: RoutingRead<[IPRuleRecord]>
    public var ipv4Routes: [IPRouteRecord] { routes4.value ?? [] }
    public var ipv6Routes: [IPRouteRecord] { routes6.value ?? [] }
    public var ipv4Neighbors: [IPNeighborRecord] { neighbors4.value ?? [] }
    public var ipv6Neighbors: [IPNeighborRecord] { neighbors6.value ?? [] }
    public var errors: [String] {
        [routes4.error, routes6.error, neighbors4.error, neighbors6.error, rules4.error, rules6.error].compactMap { $0 }
    }
    public init(routes4: RoutingRead<[IPRouteRecord]>, routes6: RoutingRead<[IPRouteRecord]>,
                neighbors4: RoutingRead<[IPNeighborRecord]>, neighbors6: RoutingRead<[IPNeighborRecord]>,
                rules4: RoutingRead<[IPRuleRecord]>, rules6: RoutingRead<[IPRuleRecord]>) {
        self.routes4 = routes4; self.routes6 = routes6
        self.neighbors4 = neighbors4; self.neighbors6 = neighbors6
        self.rules4 = rules4; self.rules6 = rules6
    }
    public func retainingLastRead(_ old: RouterRoutingSnapshot?) -> RouterRoutingSnapshot {
        guard let old else { return self }
        return .init(routes4: routes4.retaining(old.routes4), routes6: routes6.retaining(old.routes6),
                     neighbors4: neighbors4.retaining(old.neighbors4), neighbors6: neighbors6.retaining(old.neighbors6),
                     rules4: rules4.retaining(old.rules4), rules6: rules6.retaining(old.rules6))
    }
}

public struct WirelessRadio: Identifiable, Equatable, Sendable {
    public let name: String
    public let up: Bool?
    public let channel: String
    public let networks: [String]
    public var id: String { name }
    public init(name: String, up: Bool?, channel: String, networks: [String]) {
        self.name = name; self.up = up; self.channel = channel; self.networks = networks
    }
}

public struct RouterService: Identifiable, Equatable, Sendable {
    public let name: String
    public let runningInstances: Int?
    public let totalInstances: Int?
    public var id: String { name }
    public init(name: String, runningInstances: Int?, totalInstances: Int?) {
        self.name = name; self.runningInstances = runningInstances; self.totalInstances = totalInstances
    }
}

public enum OpenWrtKitError: LocalizedError, Equatable, Sendable {
    case invalidAddress
    case transport(String)
    case http(Int)
    case authenticationFailed
    case permissionDenied
    case unsupported(String)
    case malformedResponse
    case ubus(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "地址无效，请输入 IP、主机名或 HTTP/HTTPS 网址。不要在网址中填写密码。"
        case .transport(let message): return message
        case .http(let code): return "路由器返回 HTTP \(code)，请检查管理端口和 /ubus 接口。"
        case .authenticationFailed: return "登录失败。请检查用户名、密码以及 rpcd 登录设置。"
        case .permissionDenied: return "会话已过期或账户权限不足。请重新登录，或检查 rpcd ACL。"
        case .unsupported(let message): return message
        case .malformedResponse: return "路由器响应不符合 ubus JSON-RPC 格式。"
        case .ubus(let code, let message): return "\(message)（ubus \(code)）"
        }
    }
}
