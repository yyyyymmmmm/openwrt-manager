import Foundation

/// Native file management over rpcd's ubus file object (spec 0A/3):
/// browse, stat, read and write without any web file manager. Writes go
/// through writeVerified (write, then re-read and compare) and are gated
/// by the UI's confirmation, like every other write in the app.
public struct FileEntry: Identifiable, Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var mode: Int?
    public var modifiedAt: Date?
    public var id: String { name }
    public init(name: String, isDirectory: Bool, size: Int64? = nil, mode: Int? = nil, modifiedAt: Date? = nil) {
        self.name = name; self.isDirectory = isDirectory; self.size = size
        self.mode = mode; self.modifiedAt = modifiedAt
    }
}

public enum FileParser {
    /// file list: {"entries": [{"name": ..., "type": "file"|"directory",
    /// "size": n, "mode": n, "mtime": n}]}.
    public static func entries(_ value: JSONValue) -> [FileEntry] {
        (value["entries"].arrayValue ?? []).compactMap { item in
            guard let name = item["name"].stringValue else { return nil }
            return FileEntry(
                name: name,
                isDirectory: item["type"].stringValue == "directory",
                size: item["size"].intValue.map(Int64.init),
                mode: item["mode"].intValue,
                modifiedAt: item["mtime"].intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }.sorted { lhs, rhs in
            lhs.isDirectory == rhs.isDirectory ? lhs.name < rhs.name : lhs.isDirectory
        }
    }

    /// file stat: {"type": ..., "size": n, "mode": n, "mtime": n}.
    public static func stat(_ value: JSONValue, name: String) -> FileEntry {
        FileEntry(
            name: name,
            isDirectory: value["type"].stringValue == "directory",
            size: value["size"].intValue.map(Int64.init),
            mode: value["mode"].intValue,
            modifiedAt: value["mtime"].intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

public struct FileClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public func list(path: String) async throws -> [FileEntry] {
        let value = try await caller.call(object: "file", method: "list", parameters: ["path": .string(path)])
        return FileParser.entries(value)
    }

    public func stat(path: String) async throws -> FileEntry {
        let value = try await caller.call(object: "file", method: "stat", parameters: ["path": .string(path)])
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return FileParser.stat(value, name: name)
    }

    public func readText(path: String) async throws -> String {
        let value = try await caller.call(object: "file", method: "read", parameters: ["path": .string(path)])
        guard let text = value["data"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return text
    }

    /// Reads a (possibly binary) file as base64 via the file object's
    /// base64 flag, so upgrade backups and images survive the trip.
    public func readBase64(path: String) async throws -> String {
        let value = try await caller.call(object: "file", method: "read", parameters: [
            "path": .string(path), "base64": .bool(true)
        ])
        guard let text = value["data"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return text
    }

    /// Writes text and verifies by reading it back; a mismatch throws
    /// instead of reporting success (verify-by-readback discipline).
    public func writeTextVerified(path: String, content: String) async throws {
        _ = try await caller.call(object: "file", method: "write", parameters: [
            "path": .string(path), "data": .string(content)
        ])
        let reread = try await readText(path: path)
        guard reread == content else { throw TransactionError.verificationFailed(path) }
    }

    /// Writes binary data in base64 chunks (file write with the base64
    /// flag for the first chunk, append mode afterwards), then verifies
    /// the remote size.
    public func writeDataVerified(path: String, data: Data, chunkSize: Int = 32 * 1024) async throws {
        let base64 = data.base64EncodedString()
        let chunks = stride(from: 0, to: base64.count, by: chunkSize).map { start -> String in
            let from = base64.index(base64.startIndex, offsetBy: start)
            let to = base64.index(from, offsetBy: min(chunkSize, base64.count - start))
            return String(base64[from..<to])
        }
        for (index, chunk) in chunks.enumerated() {
            var parameters: [String: JSONValue] = [
                "path": .string(path), "data": .string(chunk), "base64": .bool(true)
            ]
            if index > 0 { parameters["append"] = .bool(true) }
            _ = try await caller.call(object: "file", method: "write", parameters: parameters)
        }
        if chunks.isEmpty {
            _ = try await caller.call(object: "file", method: "write", parameters: [
                "path": .string(path), "data": .string("")
            ])
        }
        let stat = try await stat(path: path)
        guard stat.size == Int64(data.count) else { throw TransactionError.verificationFailed(path) }
    }

    public func remove(path: String) async throws {
        _ = try await caller.call(object: "file", method: "remove", parameters: ["path": .string(path)])
    }

    public func md5(path: String) async throws -> String {
        let value = try await caller.call(object: "file", method: "md5", parameters: ["path": .string(path)])
        guard let digest = value["md5"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return digest
    }

    /// Runs a fixed command through file exec and returns (code, stdout).
    public func exec(command: String, arguments: [String]) async throws -> (code: Int, stdout: String) {
        let value = try await caller.call(object: "file", method: "exec", parameters: [
            "command": .string(command), "params": .array(arguments.map(JSONValue.string))
        ])
        return (value["code"].intValue ?? -1, value["stdout"].stringValue ?? "")
    }
}
