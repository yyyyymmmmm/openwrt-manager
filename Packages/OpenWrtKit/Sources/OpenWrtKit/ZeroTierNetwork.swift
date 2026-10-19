import Foundation

public struct ZeroTierNetwork: Identifiable, Sendable {
    public struct Route: Sendable {
        public let target: String
        public let via: String?
        public let metric: Int?
    }
    public let id: String
    public let name: String?
    public let status: String
    public let device: String?
    public let mac: String?
    public let type: String?
    public let addresses: [String]?
    public let routes: [Route]?
    public let allowManaged: Bool?
    public let allowGlobal: Bool?
    public let allowDefault: Bool?
    public let allowDNS: Bool?
    public let mtu: Int?
    public let portError: Int?

    public var statusExplanation: String {
        switch status {
        case "OK": return "控制器已返回网络配置；仍需单独核对实际连通性。"
        case "ACCESS_DENIED": return "控制器拒绝加入；请在该网络控制器核对成员授权。"
        case "REQUESTING_CONFIGURATION": return "正在向控制器请求网络配置。"
        case "NOT_FOUND": return "控制器未找到该网络。"
        case "PORT_ERROR": return "虚拟接口创建失败，请检查驱动与运行错误。"
        case "CLIENT_TOO_OLD": return "控制器要求更新 ZeroTier 客户端。"
        case "AUTHENTICATION_REQUIRED": return "网络要求身份认证，请向网络管理员核对。"
        default: return "保留客户端返回的状态，未推断为已连接。"
        }
    }

    public static func parse(_ value: JSONValue) throws -> [Self] {
        guard let list = value.arrayValue else { throw OpenWrtKitError.malformedResponse }
        var identifiers = Set<String>()
        return try list.map { item in
            guard item.objectValue != nil, let id = item["nwid"].stringValue ?? item["id"].stringValue,
                  id.count == 16, id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  identifiers.insert(id.lowercased()).inserted,
                  let status = item["status"].stringValue, !status.isEmpty else { throw OpenWrtKitError.malformedResponse }
            for key in ["name", "portDeviceName", "mac", "type"] where item[key] != .null {
                guard item[key].stringValue != nil else { throw OpenWrtKitError.malformedResponse }
            }
            for key in ["allowManaged", "allowGlobal", "allowDefault", "allowDNS"] where item[key] != .null {
                guard item[key].boolValue != nil else { throw OpenWrtKitError.malformedResponse }
            }
            for key in ["mtu", "portError"] where item[key] != .null {
                guard item[key].intValue != nil else { throw OpenWrtKitError.malformedResponse }
            }
            var addresses: [String]?
            if item["assignedAddresses"] != .null {
                guard let values = item["assignedAddresses"].arrayValue, values.allSatisfy({ $0.stringValue != nil }) else { throw OpenWrtKitError.malformedResponse }
                addresses = values.compactMap(\.stringValue)
            }
            var routes: [Route]?
            if item["routes"] != .null {
                guard let values = item["routes"].arrayValue else { throw OpenWrtKitError.malformedResponse }
                routes = try values.map { route in
                    guard let target = route["target"].stringValue, !target.isEmpty,
                          route["via"] == .null || route["via"].stringValue != nil,
                          route["metric"] == .null || route["metric"].intValue != nil else { throw OpenWrtKitError.malformedResponse }
                    return Route(target: target, via: route["via"].stringValue, metric: route["metric"].intValue)
                }
            }
            return Self(id: id, name: item["name"].stringValue, status: status, device: item["portDeviceName"].stringValue,
                        mac: item["mac"].stringValue, type: item["type"].stringValue, addresses: addresses, routes: routes,
                        allowManaged: item["allowManaged"].boolValue, allowGlobal: item["allowGlobal"].boolValue,
                        allowDefault: item["allowDefault"].boolValue, allowDNS: item["allowDNS"].boolValue,
                        mtu: item["mtu"].intValue, portError: item["portError"].intValue)
        }
    }
}
