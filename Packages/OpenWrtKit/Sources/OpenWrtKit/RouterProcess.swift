import Foundation

public struct RouterProcess: Identifiable, Sendable {
    public let pid: Int
    public let user: String
    public let command: String
    public let cpu: String?
    public let memory: String?
    public var id: Int { pid }

    public static func parse(_ values: [JSONValue]) throws -> [Self] {
        var seen = Set<Int>()
        return try values.map { value in
            guard let pid = value["PID"].intValue ?? value["PID"].stringValue.flatMap(Int.init),
                  pid > 0, seen.insert(pid).inserted,
                  let user = value["USER"].stringValue, !user.isEmpty,
                  let command = value["COMMAND"].stringValue, !command.isEmpty else {
                throw OpenWrtKitError.malformedResponse
            }
            func percent(_ key: String) throws -> String? {
                if value[key] == .null { return nil }
                let text: String
                if let number = value[key].doubleValue { text = String(number) }
                else if let string = value[key].stringValue { text = string }
                else { throw OpenWrtKitError.malformedResponse }
                guard let number = Double(text), number.isFinite, number >= 0 else {
                    throw OpenWrtKitError.malformedResponse
                }
                return text + "%"
            }
            return try Self(pid: pid, user: user, command: command, cpu: percent("%CPU"), memory: percent("%MEM"))
        }.sorted { $0.pid < $1.pid }
    }

    func matches(_ other: Self) -> Bool {
        pid == other.pid && user == other.user && command == other.command
    }
}

/// A /proc identity captured when the detail is loaded, not a bare reusable PID.
public struct RouterProcessIdentity: Sendable {
    public let process: RouterProcess
    let startTime: String

    static func startTime(_ text: String, pid: Int) throws -> String {
        guard let firstSpace = text.firstIndex(of: " "), Int(text[..<firstSpace]) == pid,
              let closingName = text.lastIndex(of: ")") else { throw OpenWrtKitError.malformedResponse }
        // /proc/PID/stat field 2 may contain spaces and ')' characters. Fields
        // after its last ')' begin at state (field 3); starttime is field 22.
        let fields = text[text.index(after: closingName)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, UInt64(fields[19]) != nil else { throw OpenWrtKitError.malformedResponse }
        return String(fields[19])
    }
}

public enum RouterProcessSignal: Int, CaseIterable, Identifiable, Sendable {
    case hangup = 1, terminate = 15, kill = 9
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .hangup: return "发送 HUP"
        case .terminate: return "终止进程"
        case .kill: return "强制结束"
        }
    }
    public var explanation: String {
        switch self {
        case .hangup: return "发送 SIGHUP（1）。由进程决定重新加载配置或退出，不是暂停进程。"
        case .terminate: return "发送 SIGTERM（15），请求进程退出；进程可能延迟处理或忽略。"
        case .kill: return "发送 SIGKILL（9），无法由进程处理，可能丢失未保存数据。"
        }
    }
}
