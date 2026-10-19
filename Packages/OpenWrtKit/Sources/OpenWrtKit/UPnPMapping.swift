import Foundation

/// Runtime mappings returned by luci.upnp, separate from configured ACL entries.
public struct UPnPMapping: Identifiable, Equatable, Sendable {
    public let token: String
    public let transport: String
    public let externalPort: Int
    public let internalAddress: String
    public let internalPort: Int
    public let description: String
    public let host: String?
    public let expires: Int?
    public var id: String { token }

    public static func parse(_ value: JSONValue) throws -> [Self] {
        guard let records = value["rules"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        var tokens = Set<String>()
        return try records.map { record in
            guard let token = record["num"].textValue, let number = Int(token), number > 0,
                  tokens.insert(token).inserted,
                  let transport = record["proto"].stringValue, ["TCP", "UDP"].contains(transport),
                  let external = record["extport"].intValue, (1...65535).contains(external),
                  let internalPort = record["intport"].intValue, (1...65535).contains(internalPort),
                  let address = record["intaddr"].stringValue, !address.isEmpty,
                  let description = record["descr"].stringValue else { throw OpenWrtKitError.malformedResponse }
            if record["expires"] != .null && record["expires"].intValue == nil { throw OpenWrtKitError.malformedResponse }
            if record["host_hint"] != .null && record["host_hint"].stringValue == nil { throw OpenWrtKitError.malformedResponse }
            return Self(token: token, transport: transport, externalPort: external, internalAddress: address,
                        internalPort: internalPort, description: description,
                        host: record["host_hint"].stringValue, expires: record["expires"].intValue)
        }
    }

    /// Lease time and hostname may change between reads without changing the rule.
    public func isSameRule(as other: Self) -> Bool {
        token == other.token && transport == other.transport && externalPort == other.externalPort &&
        internalAddress == other.internalAddress && internalPort == other.internalPort && description == other.description
    }

    public func hasSameEndpoint(as other: Self) -> Bool {
        transport == other.transport && externalPort == other.externalPort &&
        internalAddress == other.internalAddress && internalPort == other.internalPort
    }
}
