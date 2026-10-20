import Foundation
import Darwin

public struct IPv6PrefixAddress: Equatable, Sendable {
    public let address: String
    public let length: Int
    public var cidr: String { "\(address)/\(length)" }
}

public struct IPv6PrefixAllocation: Identifiable, Equatable, Sendable {
    public let interfaceName: String
    public let prefix: IPv6PrefixAddress
    public var id: String { interfaceName }
}

/// netifd's ipv6-prefix / ipv6-prefix-assignment records, independent of UCI options.
public struct InterfaceIPv6Prefix: Equatable, Sendable {
    public let prefix: IPv6PrefixAddress
    /// Remaining seconds at read time. Missing lifetimes must not become zero.
    public let preferredLifetime: Int?
    public let validLifetime: Int?
    public let prefixClass: String?
    public let allocations: [IPv6PrefixAllocation]?
    /// netifd emits an empty local-address object when an assignment is not enabled.
    public let localAddressReported: Bool
    public let localAddress: IPv6PrefixAddress?
}

extension SnapshotParser {
    static func ipv6Prefixes(_ interface: JSONValue, key: String) throws -> [InterfaceIPv6Prefix]? {
        guard let value = interface.objectValue?[key] else { return nil }
        guard let records = value.arrayValue else { throw prefixError(key) }
        return try records.enumerated().map { index, record in
            let path = "\(key)[\(index)]"
            guard let fields = record.objectValue else { throw prefixError(path) }
            let prefix = try ipv6PrefixAddress(record, path: path)
            func lifetime(_ key: String) throws -> Int? {
                guard let reported = fields[key] else { return nil }
                guard let seconds = reported.intValue, (0...4_294_967_295).contains(seconds) else {
                    throw prefixError("\(path).\(key)")
                }
                return seconds
            }
            let preferred = try lifetime("preferred"), valid = try lifetime("valid")
            if let preferred, let valid, preferred > valid { throw prefixError("\(path).preferred > valid") }
            let prefixClass: String?
            if let value = fields["class"] {
                guard let text = value.stringValue, !text.isEmpty else { throw prefixError("\(path).class") }
                prefixClass = text
            } else { prefixClass = nil }
            let allocations: [IPv6PrefixAllocation]?
            if let value = fields["assigned"] {
                guard let assigned = value.objectValue else { throw prefixError("\(path).assigned") }
                allocations = try assigned.keys.sorted().map { name in
                    guard !name.isEmpty, let address = assigned[name] else { throw prefixError("\(path).assigned") }
                    return IPv6PrefixAllocation(interfaceName: name, prefix: try ipv6PrefixAddress(address, path: "\(path).assigned.\(name)"))
                }
            } else { allocations = nil }
            let local: IPv6PrefixAddress?
            if let value = fields["local-address"] {
                guard let object = value.objectValue else { throw prefixError("\(path).local-address") }
                local = object.isEmpty ? nil : try ipv6PrefixAddress(value, path: "\(path).local-address")
            } else { local = nil }
            return InterfaceIPv6Prefix(prefix: prefix, preferredLifetime: preferred, validLifetime: valid,
                                       prefixClass: prefixClass, allocations: allocations,
                                       localAddressReported: fields["local-address"] != nil, localAddress: local)
        }
    }

    private static func ipv6PrefixAddress(_ value: JSONValue, path: String) throws -> IPv6PrefixAddress {
        guard let address = value["address"].stringValue, let length = value["mask"].intValue,
              (0...128).contains(length) else { throw prefixError(path) }
        var parsed = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) == 1 }) else { throw prefixError("\(path).address") }
        return IPv6PrefixAddress(address: address, length: length)
    }

    private static func prefixError(_ path: String) -> OpenWrtKitError {
        .unsupported("IPv6 前缀响应格式错误：\(path)。未将格式错误解释为空列表。")
    }
}
