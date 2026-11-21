import Foundation

/// The strengthened online-upgrade transaction (spec section 6). The
/// upgrade button may only exist on top of this flow, and every step is
/// mandatory, in this order:
///   0. storage precheck — the image must fit the router's /tmp
///      (tmpfs) before anything is written; /tmp and overlay free
///      space are read and reported separately
///   1. automatic backup of the current configuration
///   2. image streamed to the router chunk by chunk (never held whole
///      in memory) and its SHA-256 verified against the digest
///      computed while streaming; when the user supplied an expected
///      digest (official value), the image must match it too
///   3. image validated by sysupgrade's own test mode
///   4. a second, separate user confirmation (the UI collects it
///      between steps 3 and 5 — this type refuses to run without it)
///   5. upgrade executed
///   6. automatic reconnection verification (the caller polls until
///      the router answers again; this type drives the polling)
/// Any failure before step 5 aborts with the router untouched; a
/// staging failure also removes the partial image from the router.
public enum UpgradeFlow {
    public enum Step: Equatable, Sendable {
        case spacePrecheck, backup, staging, hashVerification, imageValidation, awaitingSecondConfirmation
        case upgrading, reconnectVerification, succeeded
        case failed(String)
    }

    public struct Operations: Sendable {
        /// Creates a config backup on the router and returns its path.
        public var createBackup: @Sendable () async throws -> String
        /// Stages the image at the given router path (verified write).
        public var stageImage: @Sendable (Data, String) async throws -> Void
        /// Streams the image to the router chunk by chunk and returns
        /// the SHA-256 hex digest computed over the streamed bytes.
        /// The default (built in init when not supplied) collects the
        /// stream in memory and stages it via stageImage — a fallback
        /// for test doubles; the standard operations stream for real.
        public var stageImageStream: @Sendable (FirmwareChunkReader, String, @Sendable (Int64) -> Void) async throws -> String
        /// SHA-256 of a file on the router, hex encoded.
        public var remoteSHA256: @Sendable (String) async throws -> String
        /// sysupgrade -T: validates the image without flashing.
        public var validateImage: @Sendable (String) async throws -> Bool
        /// Runs sysupgrade; the connection is expected to drop.
        public var runUpgrade: @Sendable (String) async throws -> Void
        /// One reconnection probe; true when the router answers again.
        public var probeReconnect: @Sendable () async -> Bool
        /// Free storage on the router, /tmp and overlay reported
        /// separately (nil fields when the router did not report them).
        public var routerSpace: @Sendable () async throws -> RouterStorageSpace
        /// Best-effort removal of a file on the router (partial-image
        /// cleanup); never throws.
        public var removeFile: @Sendable (String) async -> Void

        public init(createBackup: @escaping @Sendable () async throws -> String,
                    stageImage: @escaping @Sendable (Data, String) async throws -> Void,
                    remoteSHA256: @escaping @Sendable (String) async throws -> String,
                    validateImage: @escaping @Sendable (String) async throws -> Bool,
                    runUpgrade: @escaping @Sendable (String) async throws -> Void,
                    probeReconnect: @escaping @Sendable () async -> Bool,
                    routerSpace: @escaping @Sendable () async throws -> RouterStorageSpace = { RouterStorageSpace(tmpFreeBytes: nil, overlayFreeBytes: nil) },
                    removeFile: @escaping @Sendable (String) async -> Void = { _ in },
                    stageImageStream: (@Sendable (FirmwareChunkReader, String, @Sendable (Int64) -> Void) async throws -> String)? = nil) {
            self.createBackup = createBackup
            self.stageImage = stageImage
            self.remoteSHA256 = remoteSHA256
            self.validateImage = validateImage
            self.runUpgrade = runUpgrade
            self.probeReconnect = probeReconnect
            self.routerSpace = routerSpace
            self.removeFile = removeFile
            if let stageImageStream {
                self.stageImageStream = stageImageStream
            } else {
                self.stageImageStream = { reader, path, _ in
                    var data = Data()
                    while let chunk = try await reader.nextChunk() { data.append(chunk) }
                    try await stageImage(data, path)
                    return SHA256Hasher.hexDigest(data)
                }
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public var backupPath: String
        public var imageSHA256: String
        public var reconnected: Bool
    }

    /// Outcome of the streaming prepare: everything the UI needs to
    /// present the second confirmation honestly.
    public struct PreparedUpgrade: Equatable, Sendable {
        public var backupPath: String
        /// SHA-256 of the image as streamed and verified on the router.
        public var imageSHA256: String
        /// True only when an expected digest was supplied AND matched.
        /// False means "no expected digest was provided" — the UI must
        /// say the official-hash comparison did not happen.
        public var expectedHashVerified: Bool
        /// True when the router-side digest readback ran and matched.
        /// False means the readback was unavailable on this firmware
        /// (rpcd grants no remote hashing to login sessions): the
        /// transfer's integrity then rests on the chunked write's
        /// size verification plus sysupgrade's own test-mode verdict,
        /// and the UI must say so instead of claiming a hash match.
        public var remoteHashVerified: Bool
        /// Router free space measured after the backup was created.
        public var space: RouterStorageSpace
    }

    /// The one staging path every firmware's acl.d authorizes for
    /// firmware work: file write, the `--test` validation exec and
    /// the bare sysupgrade exec are all keyed to exactly this path
    /// (permission audit #6/#8/#9). Any other staging name is
    /// refused with "permission denied" on stock firmware.
    public static let defaultImagePath = "/tmp/firmware.bin"

    /// Runs steps 1-3 and returns the local digest; the UI then collects
    /// the second confirmation and calls finish(). Splitting the flow at
    /// exactly this point makes "no second confirmation, no upgrade" a
    /// structural property, not a promise.
    ///
    /// Retained for callers that already hold the image in memory; the
    /// app uses the streaming prepare(source:) path, which adds the
    /// storage precheck and never holds the whole image in memory.
    public static func prepare(image: Data, imagePath: String = UpgradeFlow.defaultImagePath,
                               operations: Operations,
                               onStep: @Sendable (Step) -> Void = { _ in }) async throws -> (backupPath: String, imageSHA256: String) {
        onStep(.backup)
        let backupPath = try await operations.createBackup()
        onStep(.staging)
        try await operations.stageImage(image, imagePath)
        onStep(.hashVerification)
        let localDigest = SHA256Hasher.hexDigest(image)
        // The remote digest is an optional cross-check (permission
        // audit #7): when the router offers one it must match; when
        // it cannot be read, the size-verified write plus the
        // sysupgrade test below carry the integrity verdict.
        if let remoteDigest = try? await operations.remoteSHA256(imagePath) {
            guard remoteDigest.lowercased() == localDigest else {
                throw TransactionError.verificationFailed(KitL10n.format("镜像哈希不一致：本地 %@，路由器 %@", localDigest, remoteDigest))
            }
        }
        onStep(.imageValidation)
        guard try await operations.validateImage(imagePath) else {
            throw OpenWrtKitError.unsupported(KitL10n.text("路由器拒绝了此镜像（sysupgrade 校验未通过），未执行升级。"))
        }
        onStep(.awaitingSecondConfirmation)
        return (backupPath, localDigest)
    }

    /// The full safety-closure prepare: storage precheck, backup,
    /// streaming staging with incremental hashing, transfer-integrity
    /// verification, expected-digest verification (when one was
    /// supplied) and sysupgrade test-mode validation — in that order,
    /// aborting before anything is flashed on any failure.
    public static func prepare(source: FirmwareChunkReader,
                               imagePath: String = UpgradeFlow.defaultImagePath,
                               expectedSHA256: String? = nil,
                               operations: Operations,
                               onProgress: @Sendable (Int64) -> Void = { _ in },
                               onStep: @Sendable (Step) -> Void = { _ in }) async throws -> PreparedUpgrade {
        // Fail fast on a malformed expected digest, before the router
        // is touched at all.
        let expected = expectedSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedDigest: String?
        if let expected, !expected.isEmpty {
            guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
                throw OpenWrtKitError.unsupported(KitL10n.text("提供的 SHA-256 应为 64 位十六进制字符串，请核对后重试。"))
            }
            expectedDigest = expected
        } else {
            expectedDigest = nil
        }

        // Step 0: storage precheck. The image is staged in /tmp
        // (tmpfs, i.e. RAM), so /tmp free space is the hard gate;
        // overlay space is measured and reported alongside but does
        // not gate — sysupgrade does not stage through the overlay,
        // and small-overlay devices would be falsely blocked.
        onStep(.spacePrecheck)
        let spaceBefore = try await operations.routerSpace()
        switch UpgradeSpaceCheck.tmpVerdict(imageSize: source.size, space: spaceBefore) {
        case .sufficient:
            break
        case .unknown:
            throw OpenWrtKitError.unsupported(KitL10n.text("无法读取路由器内存盘（/tmp）的可用空间，已中止升级准备。请确认路由器连接正常后重试。"))
        case .insufficient(let freeBytes, let requiredBytes):
            throw OpenWrtKitError.unsupported(KitL10n.format(
                "路由器内存盘（/tmp）可用空间不足：镜像需要 %@，当前可用 %@，还差 %@。镜像暂存在内存盘上，可先重启路由器释放空间，或删除 /tmp 中不需要的文件后重试。",
                ByteSizeFormatter.string(requiredBytes), ByteSizeFormatter.string(freeBytes),
                ByteSizeFormatter.string(requiredBytes - freeBytes)))
        }

        onStep(.backup)
        let backupPath = try await operations.createBackup()

        // The backup itself consumes /tmp space, so the gate is
        // re-measured before staging. A failed re-measurement does not
        // block (the precheck already passed); a measured shortfall
        // does.
        onStep(.spacePrecheck)
        let spaceAfter = (try? await operations.routerSpace()) ?? spaceBefore
        if case .insufficient(let freeBytes, let requiredBytes) =
            UpgradeSpaceCheck.tmpVerdict(imageSize: source.size, space: spaceAfter) {
            throw OpenWrtKitError.unsupported(KitL10n.format(
                "备份已生成并保留在路由器上，但内存盘（/tmp）可用空间不足：镜像需要 %@，当前可用 %@，还差 %@。请释放 /tmp 空间后重试。",
                ByteSizeFormatter.string(requiredBytes), ByteSizeFormatter.string(freeBytes),
                ByteSizeFormatter.string(requiredBytes - freeBytes)))
        }

        // Streaming staging: chunks flow from the source to the router
        // while the digest is computed incrementally. A mid-stream
        // failure removes the partial image and says so.
        onStep(.staging)
        let localDigest: String
        do {
            localDigest = try await operations.stageImageStream(source, imagePath, onProgress)
        } catch {
            await operations.removeFile(imagePath)
            throw OpenWrtKitError.unsupported(KitL10n.format(
                "上传镜像中途失败，已清除路由器上的残缺镜像文件。原因：%@",
                error.localizedDescription))
        }

        onStep(.hashVerification)
        // Optional cross-check, as in the in-memory prepare: a
        // digest the router does offer must match; an unreadable one
        // (no remote hashing is granted to login sessions) leaves
        // the verdict to the size-verified staging above and the
        // sysupgrade test below, and is reported as unverified.
        var remoteHashVerified = false
        if let remoteDigest = try? await operations.remoteSHA256(imagePath) {
            guard remoteDigest.lowercased() == localDigest else {
                throw TransactionError.verificationFailed(KitL10n.format("镜像哈希不一致：本地 %@，路由器 %@", localDigest, remoteDigest))
            }
            remoteHashVerified = true
        }
        var expectedHashVerified = false
        if let expectedDigest {
            guard expectedDigest == localDigest else {
                throw OpenWrtKitError.unsupported(KitL10n.format(
                    "镜像与提供的 SHA-256 不一致：提供值 %@，镜像实际 %@。已中止，未执行升级。",
                    expectedDigest, localDigest))
            }
            expectedHashVerified = true
        }

        onStep(.imageValidation)
        guard try await operations.validateImage(imagePath) else {
            throw OpenWrtKitError.unsupported(KitL10n.text("路由器拒绝了此镜像（sysupgrade 校验未通过），未执行升级。"))
        }
        onStep(.awaitingSecondConfirmation)
        return PreparedUpgrade(backupPath: backupPath, imageSHA256: localDigest,
                               expectedHashVerified: expectedHashVerified,
                               remoteHashVerified: remoteHashVerified, space: spaceAfter)
    }

    /// Steps 5-6. Only callable with the second confirmation in hand.
    public static func finish(imagePath: String = UpgradeFlow.defaultImagePath,
                              secondConfirmation: Bool,
                              operations: Operations,
                              reconnectAttempts: Int = 30,
                              onStep: @Sendable (Step) -> Void = { _ in }) async throws -> Bool {
        guard secondConfirmation else { throw OpenWrtKitError.permissionDenied }
        onStep(.upgrading)
        try await operations.runUpgrade(imagePath)
        onStep(.reconnectVerification)
        for _ in 0..<max(1, reconnectAttempts) {
            if await operations.probeReconnect() {
                onStep(.succeeded)
                return true
            }
        }
        onStep(.failed(KitL10n.text("升级后未能重新连接路由器")))
        return false
    }

    /// Builds the standard operations on top of the ubus file plane.
    /// Every channel used here is one rpcd actually grants to login
    /// sessions (permission audit, 2026-11-21): the backup is made by
    /// cgi-io and staged at the one authorized tarball path; the
    /// image stages at /tmp/firmware.bin, the only path the file
    /// write, `--test` and bare sysupgrade exec keys all name; the
    /// space precheck reads luci getMountPoints instead of a df exec
    /// that has no grant; the remote digest is a readback hash (the
    /// sha256sum exec has no grant either) and stays optional in the
    /// flow, which reports whether it ran.
    public static func standardOperations(files: FileClient) -> Operations {
        Operations(
            createBackup: {
                let data = try await files.downloadSysupgradeBackup()
                guard !data.isEmpty else {
                    throw OpenWrtKitError.unsupported(KitL10n.text("路由器返回了空的备份文件，未保存。"))
                }
                try await files.writeDataVerified(path: BackupFileNaming.routerBackupPath, data: data)
                return BackupFileNaming.routerBackupPath
            },
            stageImage: { data, path in
                try await files.writeDataVerified(path: path, data: data)
            },
            remoteSHA256: { path in
                let base64 = try await files.readBase64(path: path)
                guard let data = Data(base64Encoded: base64) else {
                    throw OpenWrtKitError.unsupported(KitL10n.text("无法读取路由器上的镜像哈希。"))
                }
                return SHA256Hasher.hexDigest(data)
            },
            validateImage: { path in
                let (code, _) = try await files.exec(command: "/sbin/sysupgrade", arguments: ["--test", path])
                return code == 0
            },
            runUpgrade: { path in
                // The router reboots mid-call; a transport failure here is
                // the expected shape and is swallowed by the caller wiring.
                _ = try? await files.exec(command: "/sbin/sysupgrade", arguments: [path])
            },
            probeReconnect: { false }, // replaced by the app's session wiring
            routerSpace: {
                try await files.mountSpace()
            },
            removeFile: { path in
                _ = try? await files.remove(path: path)
            },
            stageImageStream: { reader, path, onProgress in
                var hasher = SHA256Hasher()
                var sent: Int64 = 0
                _ = try await files.writeChunkedVerified(path: path) {
                    guard let chunk = try await reader.nextChunk() else { return nil }
                    hasher.update(chunk)
                    sent += Int64(chunk.count)
                    onProgress(sent)
                    return chunk
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
        )
    }
}

/// A pull-based, single-pass source of firmware image chunks. The
/// producer returns the next chunk, or nil at end of file; the image
/// is never required to exist whole in memory. Create a fresh reader
/// for every pass over the image.
public final class FirmwareChunkReader: @unchecked Sendable {
    /// Total image size in bytes (known up front from the file).
    public let size: Int64
    private let producer: () async throws -> Data?

    public init(size: Int64, producer: @escaping () async throws -> Data?) {
        self.size = size
        self.producer = producer
    }

    public func nextChunk() async throws -> Data? {
        try await producer()
    }

    /// In-memory convenience (tests and small artefacts).
    public static func inMemory(_ data: Data, chunkSize: Int = 64 * 1024) -> FirmwareChunkReader {
        var offset = 0
        return FirmwareChunkReader(size: Int64(data.count)) {
            guard offset < data.count else { return nil }
            let end = min(offset + chunkSize, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }
}

/// Free storage on the router, with the two volumes the upgrade cares
/// about kept separate: /tmp is tmpfs (RAM) and holds the staged
/// image; the overlay is the writable flash root. Either field is nil
/// when the router did not report that volume.
public struct RouterStorageSpace: Equatable, Sendable {
    public var tmpFreeBytes: Int64?
    public var overlayFreeBytes: Int64?
    public init(tmpFreeBytes: Int64?, overlayFreeBytes: Int64?) {
        self.tmpFreeBytes = tmpFreeBytes
        self.overlayFreeBytes = overlayFreeBytes
    }
}

/// Parses busybox `df -k` output (measured on OpenWrt 24.10 and
/// 25.12): one row per requested path, keyed by the "Mounted on"
/// column, Available column in 1K blocks. /overlay is not always a
/// mount of its own — when it has no row, the root row stands in for
/// it (on such systems /overlay lives on the root filesystem).
public enum DfOutputParser {
    public static func parse(_ output: String) -> RouterStorageSpace {
        var freeByMount: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 6, let availableKiB = Int64(fields[3]) else { continue }
            freeByMount[fields[fields.count - 1]] = availableKiB * 1024
        }
        return RouterStorageSpace(
            tmpFreeBytes: freeByMount["/tmp"],
            overlayFreeBytes: freeByMount["/overlay"] ?? freeByMount["/"])
    }
}

/// Parses `luci getMountPoints` ({"result": [{"mount": "/tmp",
/// "avail": <bytes>, …}]}): the space source that replaces the df
/// exec, which rpcd grants to no login session (permission audit
/// #5). avail values are BYTES on both measured firmwares (OpenWrt
/// 24.10.8 and 25.12.5, cross-checked against df -k output
/// 2026-11-21). /overlay is not always a mount of its own — when it
/// has no entry, the root entry stands in for it, mirroring
/// DfOutputParser's rule.
public enum MountPointsParser {
    public static func parse(_ value: JSONValue) -> RouterStorageSpace {
        guard let entries = value["result"].arrayValue else {
            return RouterStorageSpace(tmpFreeBytes: nil, overlayFreeBytes: nil)
        }
        func avail(_ mount: String) -> Int64? {
            entries.first { $0["mount"].stringValue == mount }?["avail"].intValue.map(Int64.init)
        }
        return RouterStorageSpace(
            tmpFreeBytes: avail("/tmp"),
            overlayFreeBytes: avail("/overlay") ?? avail("/"))
    }
}

/// The storage gate for the upgrade: does the image fit the volume it
/// will be staged on (/tmp)?
public enum UpgradeSpaceCheck {
    public enum Verdict: Equatable, Sendable {
        case sufficient
        case insufficient(freeBytes: Int64, requiredBytes: Int64)
        case unknown
    }

    public static func tmpVerdict(imageSize: Int64, space: RouterStorageSpace) -> Verdict {
        guard let free = space.tmpFreeBytes else { return .unknown }
        return free >= imageSize
            ? .sufficient
            : .insufficient(freeBytes: free, requiredBytes: imageSize)
    }
}

/// Compact byte counts for user-facing storage messages
/// ("512 KB", "12.4 MB"). Units are the conventional abbreviations in
/// both app languages.
public enum ByteSizeFormatter {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value < 1024 { return "\(max(0, bytes)) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / (1024 * 1024)) }
        return String(format: "%.2f GB", value / (1024 * 1024 * 1024))
    }
}
