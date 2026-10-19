import Foundation

public struct RouterAddress: Equatable, Sendable {
    public let url: URL
    public let rpcURL: URL
    public var scheme: String { url.scheme ?? "http" }
    public var host: String { (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
    public var port: Int { url.port ?? (scheme == "https" ? 443 : 80) }
    public var isSecure: Bool { scheme == "https" }

    init(url: URL) {
        self.url = url
        self.rpcURL = url.appendingPathComponent("ubus")
    }
}

public enum URLNormalizer {
    /// Keep reverse-proxy base paths; reduce pasted LuCI and /ubus addresses
    /// to their base. Do not accept embedded credentials or query strings.
    public static func normalize(_ input: String) throws -> RouterAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            throw OpenWrtKitError.invalidAddress
        }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw OpenWrtKitError.invalidAddress
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw OpenWrtKitError.invalidAddress
        }
        let bareHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bareHost.allSatisfy({ $0.isNumber || $0 == "." }) {
            let octets = bareHost.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else {
                throw OpenWrtKitError.invalidAddress
            }
        }
        components.scheme = scheme
        if let range = components.path.range(of: "/cgi-bin/luci") {
            components.path = String(components.path[..<range.lowerBound])
        } else if components.path.hasSuffix("/ubus") {
            components.path = String(components.path.dropLast(5))
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url, url.host != nil else {
            throw OpenWrtKitError.invalidAddress
        }
        return RouterAddress(url: url)
    }
}
