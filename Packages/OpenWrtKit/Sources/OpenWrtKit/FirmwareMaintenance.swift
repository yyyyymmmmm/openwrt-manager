import Foundation
import CryptoKit
import zlib

public enum FirmwareFileKind: String, Equatable, Sendable {
    case backup, firmware
    var path: String { self == .backup ? "/tmp/backup.tar.gz" : "/tmp/firmware.bin" }
    public var title: String { self == .backup ? "配置备份" : "固件镜像" }
}

public struct FirmwareUpload: Equatable, Sendable {
    public let kind: FirmwareFileKind
    public let size: Int
    public let sha256: String
    public let md5: String?
    public let uploadedAt: Date
    public let originalFilename: String

    init(kind: FirmwareFileKind, size: Int, sha256: String, md5: String?, originalFilename: String) {
        self.kind = kind; self.size = size; self.sha256 = sha256; self.md5 = md5
        self.originalFilename = originalFilename; uploadedAt = Date()
    }
}

public struct FirmwareBackupDownload: Sendable {
    public let fileURL: URL
    public let size: Int
    public let sha256: String
}

public struct FirmwareValidation: Equatable, Sendable {
    public let upload: FirmwareUpload
    public let valid: Bool
    public let forceable: Bool
    public let allowBackup: Bool
    public let test: RouterCommandResult
    public let details: JSONValue
    public let storageSize: Int64?
    public var tooLarge: Bool { storageSize.map { Int64(upload.size) > $0 } ?? false }
    public var needsForce: Bool { !valid || test.exitCode != 0 || tooLarge }
}

public struct FirmwareUpgradeOptions: Sendable {
    public var keepSettings: Bool
    public var force: Bool
    public var skipUnchanged: Bool
    public var packageList: Bool
    public init(keepSettings: Bool, force: Bool = false, skipUnchanged: Bool = false, packageList: Bool = false) {
        self.keepSettings = keepSettings; self.force = force
        self.skipUnchanged = skipUnchanged; self.packageList = packageList
    }
}

public struct FirmwareCapabilities: Sendable {
    public let sysupgrade: Bool?
    public let overlay: Bool?
    public let storageSize: Int64?
    public let permissions: [String: Bool]
    public let issues: [String: String]
    public let readAt: Date
}

public struct BackupInspection: Equatable, Sendable {
    public let upload: FirmwareUpload
    public let listing: RouterCommandResult
}

public enum FirmwareMaintenanceError: LocalizedError, Sendable {
    case failed(String), uncertain(String), changed
    public var errorDescription: String? {
        switch self {
        case .failed(let text): return text
        case .uncertain(let text): return "操作结果未确认：\(text)。路由器可能已执行请求；请勿重复提交或断电，等待后重新连接并核对实际状态。"
        case .changed: return "路由器上的暂存文件或校验结果已变化。未继续执行，请重新选择文件并校验。"
        }
    }
}

/// Closed commands and fixed temporary paths matching LuCI's flash protocol.
/// The firmware offers no atomic compare-and-flash operation. Hashes are checked
/// again immediately before execution, but another administrator can still race.
struct FirmwareMaintenanceClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func upload(_ url: URL, kind: FirmwareFileKind) async throws -> FirmwareUpload {
        try await noChanges()
        try await require("cgi-io", "upload", "write")
        try await require("file", kind.path, "write")
        return try await client.uploadMaintenanceFile(session: session, url: url, kind: kind)
    }

    func backup() async throws -> FirmwareBackupDownload {
        try await noChanges()
        try await require("cgi-io", "backup", "read")
        return try await client.downloadConfigurationBackup(session: session)
    }

    func capabilities() async -> FirmwareCapabilities {
        var issues: [String: String] = [:], permissions: [String: Bool] = [:]
        var platform: Bool?, overlay: Bool?, mtd: String?, mounts: String?, parts: String?
        do {
            let value = try await client.call(session: session, object: "file", method: "stat", parameters: ["path": .string("/lib/upgrade/platform.sh")])
            guard let type = value["type"].stringValue else { throw OpenWrtKitError.malformedResponse }
            platform = type == "file"
        } catch { issues["升级平台"] = error.localizedDescription }
        do { mtd = try await text("/proc/mtd") } catch { issues["MTD"] = error.localizedDescription }
        do { mounts = try await text("/proc/mounts") } catch { issues["挂载"] = error.localizedDescription }
        do { parts = try await text("/proc/partitions") } catch { issues["分区"] = error.localizedDescription }
        let mtdOverlay = mtd?.contains("\"rootfs_data\"") == true
        let mountedOverlay = mounts?.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3 && fields[1] == "/" && fields[2] == "overlay"
        } == true
        if mtdOverlay || mountedOverlay { overlay = true }
        else if mtd != nil && mounts != nil { overlay = false }
        let requests: [(String, String, String, String)] = [
            ("backup", "cgi-io", "backup", "read"), ("upload", "cgi-io", "upload", "write"),
            ("validate", "ubus", "system", "validate_firmware_image"),
            ("exec", "ubus", "file", "exec"),
            ("backupPath", "file", FirmwareFileKind.backup.path, "write"),
            ("firmwarePath", "file", FirmwareFileKind.firmware.path, "write")
        ]
        for (key, scope, object, function) in requests {
            do { permissions[key] = try await access(scope, object, function) }
            catch { issues["权限 " + key] = error.localizedDescription }
        }
        return FirmwareCapabilities(sysupgrade: platform, overlay: overlay, storageSize: Self.storageSize(mtd: mtd, partitions: parts),
                                    permissions: permissions, issues: issues, readAt: Date())
    }

    func backupList() async throws -> RouterCommandResult {
        try await exec("/sbin/sysupgrade", ["--list-backup"])
    }

    func inspectBackup(_ upload: FirmwareUpload) async throws -> BackupInspection {
        guard upload.kind == .backup else { throw FirmwareMaintenanceError.changed }
        try await verify(upload)
        let listing = try await exec("/bin/tar", ["-tzf", upload.kind.path])
        guard listing.exitCode == 0, !listing.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FirmwareMaintenanceError.failed("备份不可读（退出码 \(listing.exitCode)）：\(listing.stderr)")
        }
        // This is a readable-file inventory, not a sandboxed tar extractor.
        // It cannot establish whether links or existing router paths are safe.
        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("/"), !line.split(separator: "/").contains("..") else {
                throw FirmwareMaintenanceError.failed("备份包含绝对路径或上级目录，未开放恢复。")
            }
        }
        return BackupInspection(upload: upload, listing: listing)
    }

    func validate(_ upload: FirmwareUpload) async throws -> FirmwareValidation {
        guard upload.kind == .firmware else { throw FirmwareMaintenanceError.changed }
        try await verify(upload)
        try await require("ubus", "system", "validate_firmware_image")
        let details = try await client.call(session: session, object: "system", method: "validate_firmware_image", parameters: ["path": .string(upload.kind.path)])
        guard let valid = details["valid"].boolValue, let forceable = details["forceable"].boolValue,
              let backup = details["allow_backup"].boolValue else { throw OpenWrtKitError.malformedResponse }
        let test = try await exec("/sbin/sysupgrade", ["--test", upload.kind.path])
        let capabilities = await capabilities()
        guard capabilities.sysupgrade == true else { throw FirmwareMaintenanceError.failed("无法确认平台升级能力，请查看能力读取错误。") }
        return FirmwareValidation(upload: upload, valid: valid, forceable: forceable, allowBackup: backup,
                                  test: test, details: details, storageSize: capabilities.storageSize)
    }

    func upgrade(_ observed: FirmwareValidation, options: FirmwareUpgradeOptions) async throws -> RouterCommandResult {
        try await noChanges()
        let current = try await validate(observed.upload)
        // Diagnostic text can contain transient values. Compare the security
        // verdict and file identity, not incidental stdout formatting.
        guard current.upload == observed.upload, current.valid == observed.valid,
              current.forceable == observed.forceable, current.allowBackup == observed.allowBackup,
              current.test.exitCode == observed.test.exitCode, current.storageSize == observed.storageSize else {
            throw FirmwareMaintenanceError.changed
        }
        guard !current.needsForce || (current.forceable && options.force),
              !options.force || current.forceable,
              !options.keepSettings || current.allowBackup,
              options.keepSettings || (!options.skipUnchanged && !options.packageList) else {
            throw FirmwareMaintenanceError.failed("镜像未通过所需校验，或所选升级选项不受固件支持。")
        }
        if options.skipUnchanged {
            let capabilities = await capabilities()
            guard options.keepSettings && capabilities.overlay == true else { throw FirmwareMaintenanceError.failed("跳过原始文件需要保留配置并确认 overlay 能力。") }
        }
        var args: [String] = []
        if !options.keepSettings { args.append("-n") }
        if options.force { args.append("--force") }
        if options.keepSettings && options.skipUnchanged { args.append("-u") }
        if options.keepSettings && options.packageList { args.append("-k") }
        args.append(observed.upload.kind.path)
        try await requireCommand("/sbin/sysupgrade", args)
        try await noChanges()
        try await verify(observed.upload)
        try Task.checkCancellation()
        do { return try await executeAuthorized("/sbin/sysupgrade", args) }
        catch { throw FirmwareMaintenanceError.uncertain(error.localizedDescription) }
    }

    func restore(_ observed: BackupInspection) async throws -> RouterCommandResult {
        try await noChanges()
        guard try await inspectBackup(observed.upload) == observed else { throw FirmwareMaintenanceError.changed }
        try await requireCommand("/sbin/sysupgrade", ["--restore-backup", observed.upload.kind.path])
        try await requireCommand("/sbin/reboot", [])
        try await noChanges()
        try await verify(observed.upload)
        try Task.checkCancellation()
        do {
            let restored = try await executeAuthorized("/sbin/sysupgrade", ["--restore-backup", observed.upload.kind.path])
            guard restored.exitCode == 0 else { return restored }
            let reboot = try await executeAuthorized("/sbin/reboot", [])
            if reboot.exitCode != 0 { throw FirmwareMaintenanceError.uncertain("备份恢复命令返回 0，但重启失败（\(reboot.exitCode)）：\(reboot.stderr)") }
            return restored
        } catch let error as FirmwareMaintenanceError {
            if case .uncertain = error { throw error }
            throw FirmwareMaintenanceError.uncertain(error.localizedDescription)
        } catch { throw FirmwareMaintenanceError.uncertain(error.localizedDescription) }
    }

    func reset() async throws -> RouterCommandResult {
        try await noChanges()
        let capabilities = await capabilities()
        guard capabilities.overlay == true else { throw FirmwareMaintenanceError.failed("尚未确认 rootfs_data / overlay 能力，无法恢复出厂配置。") }
        try await requireCommand("/sbin/firstboot", ["-r", "-y"])
        try await noChanges()
        try Task.checkCancellation()
        do { return try await executeAuthorized("/sbin/firstboot", ["-r", "-y"]) }
        catch { throw FirmwareMaintenanceError.uncertain(error.localizedDescription) }
    }

    func discard(_ upload: FirmwareUpload) async throws {
        try await require("ubus", "file", "remove")
        try await require("file", upload.kind.path, "write")
        try await require("ubus", "file", "list")
        try await require("file", "/tmp", "list")
        try await verify(upload)
        _ = try await client.call(session: session, object: "file", method: "remove", parameters: ["path": .string(upload.kind.path)])
        // Read the parent directory because the transport deliberately maps
        // ubus NOT_FOUND to unsupported. Never treat that error as absence.
        do {
            let value = try await client.call(session: session, object: "file", method: "list", parameters: ["path": .string("/tmp")])
            guard let entries = value["entries"].arrayValue,
                  entries.allSatisfy({ $0["name"].stringValue?.isEmpty == false }) else { throw OpenWrtKitError.malformedResponse }
            let name = (upload.kind.path as NSString).lastPathComponent
            guard !entries.contains(where: { $0["name"].stringValue == name }) else {
                throw FirmwareMaintenanceError.failed("暂存路径仍存在或已被其他操作重新创建。")
            }
        } catch {
            throw FirmwareMaintenanceError.failed("删除请求已返回，但无法确认暂存文件消失：" + error.localizedDescription)
        }
    }

    private func verify(_ upload: FirmwareUpload) async throws {
        let stat = try await client.call(session: session, object: "file", method: "stat", parameters: ["path": .string(upload.kind.path)])
        guard stat["type"].stringValue == "file", stat["size"].intValue == upload.size else { throw FirmwareMaintenanceError.changed }
        let result = try await exec("/bin/busybox", ["sha256sum", upload.kind.path])
        let fields = result.stdout.split(whereSeparator: \.isWhitespace)
        guard result.exitCode == 0, fields.count == 2, fields[1] == Substring(upload.kind.path),
              fields[0].lowercased() == upload.sha256 else { throw FirmwareMaintenanceError.changed }
    }

    private func noChanges() async throws {
        let value = try await client.call(session: session, object: "uci", method: "changes")
        guard let changes = value["changes"].objectValue else { throw OpenWrtKitError.malformedResponse }
        guard changes.isEmpty else { throw ConfigurationError.existingChanges }
    }

    private func text(_ path: String) async throws -> String {
        let value = try await client.call(session: session, object: "file", method: "read", parameters: ["path": .string(path)])
        guard let text = value["data"].stringValue else { throw OpenWrtKitError.malformedResponse }
        return text
    }

    private func exec(_ command: String, _ args: [String]) async throws -> RouterCommandResult {
        try await requireCommand(command, args)
        return try await executeAuthorized(command, args)
    }
    private func executeAuthorized(_ command: String, _ args: [String]) async throws -> RouterCommandResult {
        return try RouterCommandResult(value: await client.call(session: session, object: "file", method: "exec", parameters: [
            "command": .string(command), "params": .array(args.map(JSONValue.string))
        ]))
    }
    private func requireCommand(_ command: String, _ args: [String]) async throws {
        try await require("ubus", "file", "exec")
        if try await access("file", command, "exec") { return }
        try await require("file", ([command] + args).joined(separator: " "), "exec")
    }
    private func require(_ scope: String, _ object: String, _ function: String) async throws {
        guard try await access(scope, object, function) else { throw OpenWrtKitError.permissionDenied }
    }
    private func access(_ scope: String, _ object: String, _ function: String) async throws -> Bool {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string(scope), "object": .string(object), "function": .string(function)
        ])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }

    // Same MTD/block heuristic as LuCI. Unknown remains nil and is disclosed.
    private static func storageSize(mtd: String?, partitions: String?) -> Int64? {
        var whole: Int64 = 0, kernel: Int64 = 0, root: Int64 = 0
        for line in (mtd ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[0].hasPrefix("mtd"), let size = Int64(String(fields[1]), radix: 16) else { continue }
            let name = fields[3].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if ["linux", "firmware"].contains(name) { whole = max(whole, size) }
            if ["kernel", "kernel0"].contains(name) { kernel = size }
            if ["rootfs", "rootfs0", "ubi", "ubi0"].contains(name) { root = size }
        }
        if whole > 0 { return whole }
        if kernel > 0 && root > kernel && root <= Int64.max - kernel { return kernel + root }
        for line in (partitions ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 4, !fields[3].contains(where: \.isNumber), let blocks = Int64(String(fields[2])),
               blocks > 2048, blocks <= Int64.max / 1024 { return blocks * 1024 }
        }
        return nil
    }
}

enum FirmwareLocalFile {
    /// Read the complete gzip stream, including its CRC/trailer. This checks
    /// transfer integrity, not the contents' compatibility with a router.
    static func validateGzip(_ url: URL) throws {
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        guard try source.read(upToCount: 3) == Data([0x1f, 0x8b, 0x08]) else {
            throw FirmwareMaintenanceError.failed("配置备份必须是 gzip 压缩的 tar 归档。")
        }
        guard let file = url.path.withCString({ gzopen($0, "rb") }) else {
            throw FirmwareMaintenanceError.failed("无法打开下载的 gzip 归档。")
        }
        defer { gzclose(file) }
        var buffer = [UInt8](repeating: 0, count: 65_536), total = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { gzread(file, $0.baseAddress, UInt32($0.count)) }
            if count > 0 {
                total += Int(count)
                guard total <= 512 * 1024 * 1024 else { throw FirmwareMaintenanceError.failed("备份解压大小超过 512 MiB，已停止完整性检查。") }
                continue
            }
            var code: Int32 = 0
            let message = gzerror(file, &code).map { String(cString: $0) } ?? "无法读取 gzip 校验结果"
            guard count == 0, code == Z_OK || code == Z_STREAM_END, gzeof(file) != 0, total > 0 else {
                throw FirmwareMaintenanceError.failed("备份压缩流不完整或校验失败：" + message)
            }
            break
        }
    }

    /// Validate the complete tar stream inside a configuration backup.  LuCI's
    /// tar listing is useful for display, but it does not tell the client
    /// whether a member is a link, a device, a PAX override, or a path that
    /// collides with another member.  Parse those semantics before a file is
    /// uploaded or exported; the bytes are still verified again on the router.
    static func validateBackupArchive(_ url: URL) throws {
        try validateGzip(url)
        guard let file = url.path.withCString({ gzopen($0, "rb") }) else {
            throw FirmwareMaintenanceError.failed("无法打开配置备份归档。")
        }
        defer { gzclose(file) }

        enum Node: Equatable { case directory, regular, symlink, hardlink }
        var nodes: [String: Node] = [:]
        var hardLinks: [(String, String)] = []
        var globalPAX: [String: String] = [:]
        var localPAX: [String: String] = [:]
        var longName: String?
        var longLink: String?
        var memberCount = 0
        var totalRead = 0
        var headerCount = 0
        var sawEnd = false

        func readExact(_ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0 else { throw FirmwareMaintenanceError.failed("备份归档读取长度无效。") }
            guard totalRead <= 512 * 1024 * 1024 - count else { throw FirmwareMaintenanceError.failed("备份解压大小超过 512 MiB。") }
            totalRead += count
            var data = Data(count: count), offset = 0
            while offset < count {
                try Task.checkCancellation()
                let read = data.withUnsafeMutableBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return -1 }
                    return gzread(file, base.advanced(by: offset), UInt32(count - offset))
                }
                guard read > 0 else { throw FirmwareMaintenanceError.failed("备份归档在 gzip 流结束前被截断。") }
                offset += Int(read)
            }
            return data
        }

        func discard(_ count: Int64) throws {
            guard count >= 0, count <= Int64(512 * 1024 * 1024 - totalRead) else { throw FirmwareMaintenanceError.failed("备份解压大小超过 512 MiB。") }
            totalRead += Int(count)
            var remaining = count
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while remaining > 0 {
                try Task.checkCancellation()
                let wanted = Int(min(remaining, Int64(buffer.count)))
                let read = buffer.withUnsafeMutableBytes { raw -> Int32 in
                    gzread(file, raw.baseAddress, UInt32(wanted))
                }
                guard read > 0 else { throw FirmwareMaintenanceError.failed("备份归档成员数据不完整。") }
                remaining -= Int64(read)
            }
        }

        func field(_ data: Data, _ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset + length <= data.count else {
                throw FirmwareMaintenanceError.failed("备份归档头部长度无效。")
            }
            let bytes = data[offset..<(offset + length)].prefix(while: { $0 != 0 })
            guard let value = String(bytes: bytes, encoding: .utf8) else {
                throw FirmwareMaintenanceError.failed("备份归档包含不是 UTF-8 的路径元数据。")
            }
            return value
        }

        func number(_ data: Data, _ offset: Int, _ length: Int, name: String) throws -> Int64 {
            guard offset + length <= data.count else { throw FirmwareMaintenanceError.failed("备份归档 \(name) 字段越界。") }
            let bytes = Array(data[offset..<(offset + length)])
            if let first = bytes.first, first & 0x80 != 0 {
                // GNU base-256 numeric field, two's-complement is not allowed
                // for the non-negative fields used by a tar member.
                guard first & 0x40 == 0 else { throw FirmwareMaintenanceError.failed("备份归档包含负的 \(name)。") }
                var value = Int64(bytes[0] & 0x7f)
                for byte in bytes.dropFirst() {
                    let part = Int64(byte)
                    guard value <= (Int64.max - part) / 256 else { throw FirmwareMaintenanceError.failed("备份归档 \(name) 过大。") }
                    value = value * 256 + part
                }
                return value
            }
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "7" }), let value = Int64(text, radix: 8) else {
                throw FirmwareMaintenanceError.failed("备份归档包含无效的 \(name)。")
            }
            return value
        }

        func archivePath(_ raw: String, base: String? = nil) throws -> String {
            guard !raw.isEmpty, !raw.contains("\\"), !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw FirmwareMaintenanceError.failed("备份归档包含空路径、反斜线或控制字符。")
            }
            var value = raw
            if base != nil && value.hasPrefix("/") {
                // Absolute link targets (e.g. /tmp/resolv.conf) are legitimate
                // on the router. They may never be used as member parents.
                value.removeFirst()
            } else if let base, !base.isEmpty { value = base + "/" + value }
            guard !value.hasPrefix("/"), base != nil || !value.split(separator: "/").contains("..") else {
                throw FirmwareMaintenanceError.failed("备份归档成员包含绝对路径或上级目录。")
            }
            var parts: [String] = []
            for part in value.split(separator: "/", omittingEmptySubsequences: true) {
                if part == "." { continue }
                if part == ".." {
                    guard !parts.isEmpty else { throw FirmwareMaintenanceError.failed("备份归档路径越过根目录。") }
                    parts.removeLast()
                } else { parts.append(String(part)) }
            }
            guard !parts.isEmpty else { throw FirmwareMaintenanceError.failed("备份归档包含空路径。") }
            let result = parts.joined(separator: "/")
            guard result.utf8.count <= 4096 else { throw FirmwareMaintenanceError.failed("备份归档路径过长。") }
            return result
        }

        func parsePAX(_ data: Data) throws -> [String: String] {
            guard data.count <= 1_048_576 else { throw FirmwareMaintenanceError.failed("备份归档 PAX 元数据过大。") }
            var result: [String: String] = [:], offset = 0
            while offset < data.count {
                guard let space = data[offset...].firstIndex(of: 0x20), space > offset,
                      let length = Int(String(decoding: data[offset..<space], as: UTF8.self)), length >= 5,
                      offset + length <= data.count else { throw FirmwareMaintenanceError.failed("备份归档 PAX 记录无效。") }
                let record = data[(space + 1)..<(offset + length)]
                guard record.last == 0x0a, let equals = record.firstIndex(of: 0x3d), equals > record.startIndex else {
                    throw FirmwareMaintenanceError.failed("备份归档 PAX 键值无效。")
                }
                let key = String(decoding: record[..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)..<(record.index(before: record.endIndex))], as: UTF8.self)
                guard !key.isEmpty, key.utf8.count <= 256 else { throw FirmwareMaintenanceError.failed("备份归档 PAX 键无效。") }
                result[key] = value; offset += length
            }
            return result
        }

        func nonZero(_ data: Data) -> Bool { data.contains { $0 != 0 } }
        while !sawEnd {
            headerCount += 1
            guard headerCount <= 200_000 else { throw FirmwareMaintenanceError.failed("备份归档元数据记录过多。") }
            let header = try readExact(512)
            if !nonZero(header) {
                let second = try readExact(512)
                guard !nonZero(second) else { throw FirmwareMaintenanceError.failed("备份归档结束标记无效。") }
                sawEnd = true
                break
            }
            let checksum = try number(header, 148, 8, name: "校验和")
            var sum: Int64 = 0
            for index in 0..<512 { sum += Int64(index >= 148 && index < 156 ? 0x20 : header[index]) }
            guard checksum == sum else { throw FirmwareMaintenanceError.failed("备份归档头部校验失败。") }
            let typeByte = header[156]
            let type = typeByte == 0 ? UInt8(ascii: "0") : typeByte
            let rawName = try field(header, 0, 100)
            let magic = try field(header, 257, 6)
            // Old GNU uses the ustar prefix area for different metadata.
            let prefix = magic == "ustar" ? try field(header, 345, 155) : ""
            let headerPath = prefix.isEmpty ? rawName : prefix + "/" + rawName
            var size = try number(header, 124, 12, name: "大小")
            guard size >= 0, size <= 512 * 1024 * 1024 else { throw FirmwareMaintenanceError.failed("备份归档成员过大。") }
            let rawLink = try field(header, 157, 100)
            guard magic.isEmpty || magic == "ustar" || magic == "ustar " else { throw FirmwareMaintenanceError.failed("备份归档格式不是受支持的 tar。") }
            let headerPadded = ((size + 511) / 512) * 512

            if type == UInt8(ascii: "x") || type == UInt8(ascii: "g") {
                guard size <= 1_048_576 else { throw FirmwareMaintenanceError.failed("备份归档 PAX 元数据过大。") }
                let payload = try readExact(Int(size)); let padding = headerPadded - size; if padding > 0 { try discard(padding) }
                let values = try parsePAX(payload)
                if type == UInt8(ascii: "g") { globalPAX.merge(values) { _, new in new } }
                else { localPAX.merge(values) { _, new in new } }
                continue
            }
            if type == UInt8(ascii: "L") || type == UInt8(ascii: "K") {
                guard size <= 1_048_576 else { throw FirmwareMaintenanceError.failed("备份归档 GNU 长名称过大。") }
                let payload = try readExact(Int(size)); let padding = headerPadded - size; if padding > 0 { try discard(padding) }
                let text = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
                if type == UInt8(ascii: "L") { longName = text } else { longLink = text }
                continue
            }

            var attributes = globalPAX; attributes.merge(localPAX) { _, new in new }; localPAX = [:]
            let allowedPAX: Set<String> = ["path", "linkpath", "size", "uid", "gid", "uname", "gname", "mtime", "atime", "ctime", "charset", "comment", "hdrcharset"]
            guard attributes.keys.allSatisfy({ allowedPAX.contains($0) }) else {
                throw FirmwareMaintenanceError.failed("备份包含未支持的 PAX 扩展（如稀疏文件或扩展属性），未开放恢复。原文件没有修改。")
            }
            guard longName == nil || attributes["path"] == nil || longName == attributes["path"],
                  longLink == nil || attributes["linkpath"] == nil || longLink == attributes["linkpath"] else {
                throw FirmwareMaintenanceError.failed("备份归档的 GNU 与 PAX 路径覆盖不一致。")
            }
            if let paxSize = attributes["size"] {
                guard let value = Int64(paxSize), value >= 0, value <= 512 * 1024 * 1024 else {
                    throw FirmwareMaintenanceError.failed("备份归档 PAX 大小覆盖无效。")
                }
                size = value
            }
            let selectedPath = longName ?? attributes["path"] ?? headerPath
            if type == UInt8(ascii: "5"), [".", "./"].contains(selectedPath), size == 0 {
                longName = nil; longLink = nil
                continue
            }
            let path = try archivePath(selectedPath)
            let link = longLink ?? attributes["linkpath"] ?? rawLink
            longName = nil; longLink = nil
            guard size <= 512 * 1024 * 1024 else { throw FirmwareMaintenanceError.failed("备份归档成员过大。") }
            let memberPadded = ((size + 511) / 512) * 512
            memberCount += 1; guard memberCount <= 100_000 else { throw FirmwareMaintenanceError.failed("备份归档成员数量过多。") }
            guard nodes[path] == nil else { throw FirmwareMaintenanceError.failed("备份归档包含重复路径：\(path)。") }
            let node: Node
            switch type {
            case UInt8(ascii: "0"), UInt8(ascii: "7"): node = .regular
            case UInt8(ascii: "5"): node = .directory
            case UInt8(ascii: "1"):
                let target = try archivePath(link); hardLinks.append((path, target)); node = .hardlink
            case UInt8(ascii: "2"):
                _ = try archivePath(link, base: (path as NSString).deletingLastPathComponent)
                node = .symlink
            case UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "6"):
                throw FirmwareMaintenanceError.failed("备份归档包含设备文件或 FIFO，未开放恢复。")
            default:
                throw FirmwareMaintenanceError.failed("备份归档包含未知成员类型。")
            }
            guard node == .regular || size == 0 else { throw FirmwareMaintenanceError.failed("备份归档的链接或目录携带了数据。") }
            nodes[path] = node
            try discard(memberPadded)
        }
        guard localPAX.isEmpty, longName == nil, longLink == nil, memberCount > 0 else {
            throw FirmwareMaintenanceError.failed("备份归档没有成员或末尾存在未使用的路径覆盖元数据。")
        }
        while true {
            try Task.checkCancellation()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let read = buffer.withUnsafeMutableBytes { gzread(file, $0.baseAddress, UInt32($0.count)) }
            if read == 0 { break }
            guard read > 0, buffer.prefix(Int(read)).allSatisfy({ $0 == 0 }) else { throw FirmwareMaintenanceError.failed("备份归档结束标记后仍有数据。") }
            totalRead += Int(read)
            guard totalRead <= 512 * 1024 * 1024 else { throw FirmwareMaintenanceError.failed("备份解压大小超过 512 MiB。") }
        }
        var code: Int32 = 0
        _ = gzerror(file, &code)
        guard gzeof(file) != 0, code == Z_OK || code == Z_STREAM_END else { throw FirmwareMaintenanceError.failed("备份 gzip 校验失败。") }
        for path in nodes.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard nodes[parent] == nil || nodes[parent] == .directory else { throw FirmwareMaintenanceError.failed("备份归档路径穿过链接或普通文件：\(path)。") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for (_, target) in hardLinks {
            guard nodes[target] == .regular else { throw FirmwareMaintenanceError.failed("备份归档硬链接目标不是已确认的普通文件。") }
        }
    }

    struct Multipart {
        let url: URL
        let boundary: String
        let size: Int
        let sha256: String
    }

    static func multipart(_ url: URL, token: String, kind: FirmwareFileKind) throws -> Multipart {
        guard token.count == 32, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw OpenWrtKitError.authenticationFailed
        }
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard resource.isRegularFile == true else { throw FirmwareMaintenanceError.failed("请选择普通文件。") }
        // Stage first, then validate and upload this private immutable payload.
        // A document-provider URL can change while the app is preparing it.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("zirox-payload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FirmwareMaintenanceError.failed("无法创建本机文件副本。")
        }
        let destination = try FileHandle(forWritingTo: staged)
        defer { try? destination.close() }
        var copied = 0
        while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += chunk.count
            guard copied <= (kind == .backup ? 128 * 1024 * 1024 : 1_073_741_824) else {
                throw FirmwareMaintenanceError.failed("文件超过本机上传限制。配置备份限制 128 MiB，固件限制 1 GiB。")
            }
            try destination.write(contentsOf: chunk)
        }
        guard copied > 0 else { throw FirmwareMaintenanceError.failed("不能上传空文件。") }
        try destination.synchronize(); try destination.close()
        if kind == .backup { try validateBackupArchive(staged) }
        let input = try FileHandle(forReadingFrom: staged)
        defer { try? input.close() }
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("zirox-upload-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: spool.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FirmwareMaintenanceError.failed("无法创建本机上传暂存文件。")
        }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: spool) }
        catch { try? FileManager.default.removeItem(at: spool); throw error }
        var keep = false
        defer { try? output.close(); if !keep { try? FileManager.default.removeItem(at: spool) } }
        let boundary = "Zirox" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Field order is part of cgi-io's streaming protocol. No filename from
        // the picker is interpolated into a header or a router destination.
        for (name, value) in [("sessionid", token), ("filename", kind.path), ("filemode", "0600")] {
            try output.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n").utf8))
        }
        try output.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"filedata\"; filename=\"upload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
        var hash = SHA256(), size = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            size += chunk.count
            guard size <= 1_073_741_824 else { throw FirmwareMaintenanceError.failed("文件超过本机上传限制 1 GiB。") }
            if kind == .backup && size > 128 * 1024 * 1024 { throw FirmwareMaintenanceError.failed("配置备份超过本机上传限制 128 MiB。") }
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard size > 0 else { throw FirmwareMaintenanceError.failed("不能上传空文件。") }
        try output.write(contentsOf: Data(("\r\n--\(boundary)--\r\n").utf8))
        try output.synchronize(); try output.close()
        keep = true
        return Multipart(url: spool, boundary: boundary, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
