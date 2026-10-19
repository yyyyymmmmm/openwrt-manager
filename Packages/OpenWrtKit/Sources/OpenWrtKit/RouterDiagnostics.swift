import Foundation
import Darwin

public enum DiagnosticTool: String, CaseIterable, Identifiable, Sendable {
    case ping, ping6, traceroute, nslookup
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ping: return "IPv4 Ping"
        case .ping6: return "IPv6 Ping"
        case .traceroute: return "IPv4 Traceroute"
        case .nslookup: return "DNS 查询"
        }
    }
    public var executable: String {
        switch self {
        case .ping: return "/bin/ping"
        case .ping6: return "/bin/ping6"
        case .traceroute: return "/usr/bin/traceroute"
        case .nslookup: return "/usr/bin/nslookup"
        }
    }
    public func arguments(host: String) throws -> [String] {
        guard Self.validHost(host) else {
            throw OpenWrtKitError.unsupported("请输入有效 IP 或 ASCII / Punycode 域名，不要填写 URL、空格或命令参数。")
        }
        switch self {
        case .ping, .ping6: return ["-c", "3", "-W", "2", "-w", "8", host]
        case .traceroute: return ["-n", "-m", "8", "-w", "1", "-q", "1", host]
        case .nslookup: return [host]
        }
    }
    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        var v4 = in_addr(); var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }) { return true }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

public struct RouterCommandResult: Equatable, Sendable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String
    public init(value: JSONValue) throws {
        guard let code = value["code"].intValue,
              value["stdout"] == .null || value["stdout"].stringValue != nil,
              value["stderr"] == .null || value["stderr"].stringValue != nil else {
            throw OpenWrtKitError.malformedResponse
        }
        exitCode = code; stdout = value["stdout"].stringValue ?? ""; stderr = value["stderr"].stringValue ?? ""
    }
}
