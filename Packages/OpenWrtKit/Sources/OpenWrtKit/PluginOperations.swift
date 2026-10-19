import Foundation

public struct HomeProxyCapabilities: Sendable {
    public let version: String
    public let features: [String: Bool]
    public init(value: JSONValue) throws {
        guard let object = value.objectValue, let version = object["version"]?.stringValue, !version.isEmpty else {
            throw OpenWrtKitError.unsupported("HomeProxy 未返回 sing-box 版本，无法确认内核能力。")
        }
        var features: [String: Bool] = [:]
        for (key, value) in object where key != "version" {
            guard let enabled = value.boolValue else { throw OpenWrtKitError.malformedResponse }
            features[key] = enabled
        }
        self.version = version; self.features = features
    }
    public var nodeTypes: [String] {
        var types = ["direct", "anytls", "http", "shadowsocks", "shadowtls", "socks", "ssh", "trojan", "vless", "vmess"]
        if features["with_quic"] == true { types += ["hysteria", "hysteria2", "tuic"] }
        if features["with_wireguard"] == true && features["with_gvisor"] == true { types += ["wireguard"] }
        return types
    }
    public var proxyModes: [String] {
        var modes = ["redirect"]
        if features["hp_has_tproxy"] == true { modes += ["redirect_tproxy"] }
        if features["hp_has_tun"] == true && features["hp_has_ip_full"] == true { modes += ["redirect_tun", "tun"] }
        return modes
    }
}

public enum HomeProxyResource: String, CaseIterable, Identifiable, Sendable {
    case chinaIP4 = "china_ip4", chinaIP6 = "china_ip6", chinaList = "china_list", gfwList = "gfw_list"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chinaIP4: return "中国 IPv4 网段"
        case .chinaIP6: return "中国 IPv6 网段"
        case .chinaList: return "中国域名列表"
        case .gfwList: return "GFW 域名列表"
        }
    }
}

public enum HomeProxyLog: String, CaseIterable, Identifiable, Sendable {
    case homeproxy, client = "sing-box-c", server = "sing-box-s"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .homeproxy: return "HomeProxy 日志"
        case .client: return "客户端内核日志"
        case .server: return "服务端内核日志"
        }
    }
}

public enum NativePluginRead: Sendable {
    case homeProxyFeatures
    case homeProxyResource(HomeProxyResource)
    case homeProxyConnection(google: Bool)
    case homeProxyLog(HomeProxyLog)
    case mosDNSVersion, mosDNSLog, mosDNSUpdateLog
    case zeroTierInfo

    public var title: String {
        switch self {
        case .homeProxyFeatures: return "sing-box 与内核能力"
        case .homeProxyResource(let resource): return resource.title
        case .homeProxyConnection(let google): return google ? "Google 连通性" : "百度连通性"
        case .homeProxyLog(let log): return log.title
        case .mosDNSVersion: return "MosDNS 版本"
        case .mosDNSLog: return "MosDNS 日志"
        case .mosDNSUpdateLog: return "规则更新日志"
        case .zeroTierInfo: return "ZeroTier 客户端状态"
        }
    }
}

public enum NativePluginAction: Identifiable, Sendable {
    case homeProxyResource(HomeProxyResource)
    case homeProxySubscriptions
    case mosDNSFlushCache, mosDNSUpdate

    public var id: String { title }
    public var title: String {
        switch self {
        case .homeProxyResource(let resource): return "更新" + resource.title
        case .homeProxySubscriptions: return "更新节点订阅"
        case .mosDNSFlushCache: return "清空 DNS 缓存"
        case .mosDNSUpdate: return "更新 MosDNS 规则"
        }
    }
    public var explanation: String {
        switch self {
        case .homeProxySubscriptions: return "使用路由器已应用的订阅设置更新节点，可能修改节点配置并重启服务。更新不使用尚未应用的本机草稿。"
        case .homeProxyResource: return "使用固件的 HomeProxy 更新程序下载对应资源，可能影响分流。"
        case .mosDNSFlushCache: return "清空当前 MosDNS 实例的 lazy_cache。此操作无法撤销。"
        case .mosDNSUpdate: return "请求固件在后台更新规则。请求接受后仍需读取更新日志核对结果。"
        }
    }
}
