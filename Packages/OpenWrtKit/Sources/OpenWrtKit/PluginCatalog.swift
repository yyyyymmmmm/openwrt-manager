import Foundation

/// A visible procd service is evidence of a service, not proof of package
/// installation, version compatibility, writable ACLs or business health.
public struct RecognizedPluginService: Identifiable, Equatable, Sendable {
    public let service: RouterService
    public let title: String
    public let category: String
    public var id: String { service.id }
}

public enum PluginCatalog {
    public static func recognize(_ services: [RouterService]) -> [RecognizedPluginService] {
        let names: [String: (String, String)] = [
            "ddns": ("动态域名 DDNS", "网络与访问"),
            "sqm": ("SQM 智能队列", "网络与流量"),
            "pbr": ("策略路由 PBR", "网络与流量"),
            "mwan3": ("多 WAN · mwan3", "网络与流量"),
            "smartdns": ("SmartDNS", "DNS 与过滤"),
            "adblock": ("Adblock", "DNS 与过滤"),
            "dockerd": ("Docker", "存储与服务"),
            "transmission": ("Transmission", "存储与服务")
        ]
        return services.compactMap { service in
            guard let descriptor = names[service.name] else { return nil }
            return RecognizedPluginService(service: service, title: descriptor.0, category: descriptor.1)
        }.sorted { $0.id < $1.id }
    }
}

public enum RouterWebPage: String, CaseIterable, Identifiable, Sendable {
    case luci, packages, istore
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .luci: return "LuCI 管理界面"
        case .packages: return "OpenWrt 软件包"
        case .istore: return "iStore 应用商店"
        }
    }

    public func url(address: RouterAddress) -> URL {
        let path: String
        switch self {
        case .luci: path = "cgi-bin/luci/"
        case .packages: path = "cgi-bin/luci/admin/system/packages"
        case .istore: path = "cgi-bin/luci/admin/store"
        }
        return address.url.appendingPathComponent(path)
    }
}
