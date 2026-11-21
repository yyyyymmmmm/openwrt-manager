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

    /// Streams binary data to the router chunk by chunk (upgrade
    /// staging): the producer is pulled for one chunk at a time, so
    /// neither the raw image nor its base64 form ever exists whole in
    /// memory. Chunks are re-blocked into 24 KiB raw blocks — a
    /// multiple of 3, so each block's base64 encoding is
    /// quantum-aligned and the concatenation decodes as the whole —
    /// written with the base64 flag (append mode after the first
    /// block), and the remote size is verified at the end. Any failure
    /// mid-stream removes the partial file before rethrowing, so a
    /// half-written image is never left behind to be mistaken for a
    /// complete one.
    public func writeChunkedVerified(path: String,
                                     nextChunk: () async throws -> Data?) async throws -> Int64 {
        let blockSize = 24 * 1024
        var pending = Data()
        var total: Int64 = 0
        var wroteAny = false

        func emit(_ block: Data) async throws {
            var parameters: [String: JSONValue] = [
                "path": .string(path), "data": .string(block.base64EncodedString()), "base64": .bool(true)
            ]
            if wroteAny { parameters["append"] = .bool(true) }
            _ = try await caller.call(object: "file", method: "write", parameters: parameters)
            wroteAny = true
        }

        do {
            while let chunk = try await nextChunk() {
                if chunk.isEmpty { continue }
                pending.append(chunk)
                total += Int64(chunk.count)
                while pending.count >= blockSize {
                    let block = pending.prefix(blockSize)
                    try await emit(Data(block))
                    pending.removeFirst(blockSize)
                }
            }
            if !pending.isEmpty || !wroteAny {
                try await emit(pending)
            }
        } catch {
            _ = try? await remove(path: path)
            throw error
        }
        let stat = try await stat(path: path)
        guard stat.size == total else {
            _ = try? await remove(path: path)
            throw TransactionError.verificationFailed(path)
        }
        return total
    }

    public func remove(path: String) async throws {
        _ = try await caller.call(object: "file", method: "remove", parameters: ["path": .string(path)])
    }

    /// Creates a directory (package D, audit F8). rpcd's file object
    /// has no mkdir, so this goes through file exec with a fixed
    /// command path and the path as a single argument — no shell is
    /// involved, so a hostile name cannot become a command. A nonzero
    /// exit (permissions, ACL, existing entry) throws instead of
    /// pretending success; callers verify by re-listing.
    public func makeDirectory(path: String) async throws {
        let (code, _) = try await exec(command: "/bin/mkdir", arguments: [path])
        guard code == 0 else { throw OpenWrtKitError.transport(KitL10n.format("文件操作失败（退出码 %lld）", code)) }
    }

    /// Renames or moves a file or directory (package D, audit F8):
    /// same fixed-command exec discipline as makeDirectory.
    public func rename(from source: String, to destination: String) async throws {
        let (code, _) = try await exec(command: "/bin/mv", arguments: [source, destination])
        guard code == 0 else { throw OpenWrtKitError.transport(KitL10n.format("文件操作失败（退出码 %lld）", code)) }
    }

    /// Removes an EMPTY directory (package D, audit F8). Deliberately
    /// rmdir, never a recursive delete: a non-empty directory fails
    /// honestly instead of vanishing with its contents.
    public func removeDirectory(path: String) async throws {
        let (code, _) = try await exec(command: "/bin/rmdir", arguments: [path])
        guard code == 0 else { throw OpenWrtKitError.transport(KitL10n.format("文件操作失败（退出码 %lld）", code)) }
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
