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
    /// When the router issued this session. Expiry tracking lives here so
    /// every holder of a session can judge freshness without a side table.
    public let issuedAt: Date
    public init(token: String, expiresIn: Int = 3600, issuedAt: Date = Date()) {
        self.token = token; self.expiresIn = expiresIn; self.issuedAt = issuedAt
    }
    public var expiresAt: Date { issuedAt.addingTimeInterval(TimeInterval(expiresIn)) }
    /// True while the session is valid and stays valid for at least `margin`.
    public func isUsable(now: Date = Date(), margin: TimeInterval = 0) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
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

public struct NetworkInterfaceSnapshot: Identifiable, Equatable, Sendable {
    public let name: String
    public let protocolName: String
    public let addresses: [String]
    public let up: Bool?
    public let device: String?
    public var id: String { name }
    public init(name: String, protocolName: String, addresses: [String], up: Bool?, device: String? = nil) {
        self.name = name; self.protocolName = protocolName
        self.addresses = addresses; self.up = up; self.device = device
    }
}

public struct RouterSnapshot: Equatable, Sendable {
    public var system = SystemSnapshot()
    public var interfaces: [NetworkInterfaceSnapshot] = []
    public var warnings: [String] = []
    public var refreshedAt = Date()
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
        case .invalidAddress: return KitL10n.text("地址无效，请输入 IP、主机名或 HTTP/HTTPS 网址。不要在网址中填写密码。")
        case .transport(let message): return message
        case .http(let code): return KitL10n.format("路由器返回 HTTP %lld，请检查管理端口和 /ubus 接口。", code)
        case .authenticationFailed: return KitL10n.text("登录失败。请检查用户名、密码以及 rpcd 登录设置。")
        case .permissionDenied: return KitL10n.text("路由器未授权此功能：这台固件没有向 App 登录会话开放这项操作，重新登录也不会改变。")
        case .unsupported(let message): return message
        case .malformedResponse: return KitL10n.text("路由器响应不符合 ubus JSON-RPC 格式。")
        case .ubus(let code, let message):
            // Well-known status codes get the localized semantic label;
            // rpcd's raw message for them is terse English ("Access
            // denied", "Not found") and must not reach the user as-is.
            // Unknown codes keep the raw message plus the code — the
            // message may be the only clue, and the code keeps it
            // reportable (audit L5).
            if let label = Self.ubusStatusLabel(code: code) {
                return KitL10n.format("%@（ubus %lld）", label, code)
            }
            return KitL10n.format("%@（ubus %lld）", message, code)
        }
    }

    /// Short human label for the well-known ubus status codes (the C
    /// library's UBUS_STATUS_* set); nil for codes outside that set.
    public static func ubusStatusLabel(code: Int) -> String? {
        switch code {
        case 1: return KitL10n.text("无效命令")
        case 2: return KitL10n.text("参数无效")
        case 3: return KitL10n.text("路由器不支持此功能")
        case 4: return KitL10n.text("未找到")
        case 5: return KitL10n.text("暂无数据")
        case 6: return KitL10n.text("权限不足")
        case 7: return KitL10n.text("请求超时")
        case 8: return KitL10n.text("路由器不支持")
        case 10: return KitL10n.text("连接失败")
        default: return nil
        }
    }
}
