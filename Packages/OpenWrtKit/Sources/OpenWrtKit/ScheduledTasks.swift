import Foundation

/// nil contents means absence was confirmed by listing the actual parent directory.
/// It never represents a failed file read.
public struct ScheduledTasksSnapshot: Equatable, Sendable {
    public let contents: String?
    public init(contents: String?) { self.contents = contents }

    public static func prepared(_ text: String) throws -> String {
        guard !text.contains("\0"), text.utf8.count <= 65_536 else {
            throw OpenWrtKitError.unsupported("计划任务不能包含 NUL，且内容不能超过 64 KiB。")
        }
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !unix.contains("\r") else {
            throw OpenWrtKitError.unsupported("发现单独的回车字符，请将文本转换为 Unix 换行。")
        }
        // Preserve comments, spacing, blank lines and firmware-specific syntax.
        let prepared = unix.isEmpty || unix.hasSuffix("\n") ? unix : unix + "\n"
        guard prepared.utf8.count <= 65_536 else {
            throw OpenWrtKitError.unsupported("补齐末尾换行后的任务文件超过 64 KiB。")
        }
        return prepared
    }
}

public struct ScheduledTasksSaveResult: Sendable {
    public let snapshot: ScheduledTasksSnapshot
    public let savedAndVerified: Bool
    public let reload: RouterCommandResult?
    public let reloadError: String?
}

/// Deliberately limited to LuCI's root crontab and fixed cron reload operation.
struct ScheduledTasksClient: Sendable {
    let client: UbusClient
    let session: UbusSession
    private let path = "/etc/crontabs/root"

    func read() async throws -> ScheduledTasksSnapshot {
        do {
            let result = try await client.call(session: session, object: "file", method: "read", parameters: ["path": .string(path)])
            guard let contents = result["data"].stringValue, !contents.contains("\0"), contents.utf8.count <= 65_536 else {
                throw OpenWrtKitError.unsupported("计划任务响应不是可编辑的文本，或超过 64 KiB；未开放覆盖。")
            }
            return ScheduledTasksSnapshot(contents: contents)
        } catch {
            let readError = error
            // rpcd uses NOT_FOUND both for a missing file and a missing method.
            // Only an actual directory listing may establish file absence.
            guard let failure = error as? OpenWrtKitError, case .unsupported = failure else { throw error }
            do {
                let directory = try await client.call(session: session, object: "file", method: "list", parameters: ["path": .string("/etc/crontabs")])
                guard let entries = directory["entries"].arrayValue,
                      entries.allSatisfy({ $0["name"].stringValue != nil }) else { throw readError }
                guard !entries.contains(where: { $0["name"].stringValue == "root" }) else { throw readError }
                return ScheduledTasksSnapshot(contents: nil)
            } catch { throw readError }
        }
    }

    func writable() async throws -> Bool {
        let method = try await access(scope: "ubus", object: "file", function: "write")
        let file = try await access(scope: "file", object: path, function: "write")
        return method && file
    }

    func save(observed: ScheduledTasksSnapshot, text: String) async throws -> ScheduledTasksSaveResult {
        let prepared = try ScheduledTasksSnapshot.prepared(text)
        guard try await writable() else { throw OpenWrtKitError.permissionDenied }
        guard try await read() == observed else {
            throw OpenWrtKitError.unsupported("路由器的计划任务已变化，未写入。请保留本地草稿，重新读取后合并。")
        }
        try Task.checkCancellation()
        do {
            _ = try await client.call(session: session, object: "file", method: "write", parameters: [
                "path": .string(path), "data": .string(prepared), "append": .bool(false), "mode": .number(384)
            ])
            guard try await read().contents == prepared else {
                throw OpenWrtKitError.unsupported("保存后内容与提交内容不同。")
            }
        } catch {
            throw OpenWrtKitError.unsupported("计划任务写入或重读未确认：\(error.localizedDescription)\n文件可能已经改变。未请求 cron 重载；请保留草稿并重新读取，勿直接重试。")
        }
        let saved = ScheduledTasksSnapshot(contents: prepared)
        return await reload(saved, savedAndVerified: true)
    }

    func reload(_ observed: ScheduledTasksSnapshot, savedAndVerified: Bool = false) async -> ScheduledTasksSaveResult {
        do {
            guard try await read() == observed else {
                throw OpenWrtKitError.unsupported("计划任务已变化，未请求重载。请重新读取。")
            }
            try Task.checkCancellation()
            let method = try await access(scope: "ubus", object: "file", function: "exec")
            let executable = try await access(scope: "file", object: "/etc/init.d/cron", function: "exec")
            let command = try await access(scope: "file", object: "/etc/init.d/cron reload", function: "exec")
            guard method && (executable || command) else { throw OpenWrtKitError.permissionDenied }
            let value = try await client.call(session: session, object: "file", method: "exec", parameters: [
                "command": .string("/etc/init.d/cron"), "params": .array([.string("reload")])
            ])
            return ScheduledTasksSaveResult(snapshot: observed, savedAndVerified: savedAndVerified, reload: try RouterCommandResult(value: value), reloadError: nil)
        } catch {
            return ScheduledTasksSaveResult(snapshot: observed, savedAndVerified: savedAndVerified, reload: nil, reloadError: error.localizedDescription)
        }
    }

    private func access(scope: String, object: String, function: String) async throws -> Bool {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string(scope), "object": .string(object), "function": .string(function)
        ])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }
}
