import Foundation

/// Live values used by LuCI's System page. These are separate from UCI so a
/// failed status RPC never gets represented as a guessed timestamp or state.
public struct SystemTimeZone: Identifiable, Equatable, Sendable {
    public let name: String
    public let posix: String
    public var id: String { name }
    public static func parse(_ value: JSONValue) throws -> [Self] {
        guard let object = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        let zones = try object.map { name, zone in
            guard !name.isEmpty, let posix = zone["tzstring"].stringValue, !posix.isEmpty else { throw OpenWrtKitError.malformedResponse }
            return Self(name: name, posix: posix)
        }
        // LuCI explicitly adds UTC even when zoneinfo omits it.
        return ([Self(name: "UTC", posix: "UTC0")] + zones.filter { $0.name != "UTC" }).sorted { $0.name < $1.name }
    }
}

public struct SystemRuntimeSnapshot: Equatable, Sendable {
    public static func issueTitle(_ key: String) -> String {
        switch key {
        case "clock": return "路由器时钟"
        case "ntp": return "NTP 启动项"
        case "timezones": return "时区目录"
        case "features": return "固件能力"
        case "zram": return "ZRam 算法"
        default: return key
        }
    }
    public let unixTime: Int64?
    public let ntpdEnabled: Bool?
    public let ntpdRunning: Bool?
    public let timezones: [SystemTimeZone]?
    public let zramSupported: Bool?
    public let zramAlgorithms: [String]?
    public let issues: [String: String]
    public let readAt: Date
    public init(unixTime: Int64?, ntpdEnabled: Bool?, ntpdRunning: Bool?, timezones: [SystemTimeZone]?,
                zramSupported: Bool?, zramAlgorithms: [String]?, issues: [String: String]) {
        self.unixTime = unixTime; self.ntpdEnabled = ntpdEnabled; self.ntpdRunning = ntpdRunning; self.timezones = timezones
        self.zramSupported = zramSupported; self.zramAlgorithms = zramAlgorithms; self.issues = issues; self.readAt = Date()
    }

    public static func parseAlgorithms(_ text: String) throws -> [String] {
        let algorithms = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        guard !algorithms.isEmpty, algorithms.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }) else {
            throw OpenWrtKitError.malformedResponse
        }
        return Array(Set(algorithms)).sorted()
    }
}
