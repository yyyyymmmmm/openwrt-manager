import Foundation

// MARK: - Configuration backup & restore (package C, item 1)
//
// The backup artefact is OpenWrt's own: `sysupgrade --create-backup`
// produces the same tar.gz LuCI's flash page downloads, and
// `sysupgrade --restore-backup` consumes it — a backup made here
// restores in LuCI and vice versa. Both run over the ubus file plane
// the app already holds (the exact channel the upgrade flow's own
// automatic backup uses). Alongside the tarball the app keeps a
// manifest — model/firmware at capture time and the UCI config
// inventory — so a restore can be previewed and diffed before
// anything is sent. The manifest is app-side metadata only; it never
// enters the tarball and is not needed to restore.

public struct BackupManifest: Codable, Equatable, Sendable {
    public struct ConfigEntry: Codable, Equatable, Sendable {
        public var name: String
        public var sectionCount: Int
        public init(name: String, sectionCount: Int) {
            self.name = name; self.sectionCount = sectionCount
        }
    }

    public var createdAt: Date
    public var routerID: String?
    public var routerName: String
    public var address: String
    public var model: String?
    public var firmware: String?
    public var hostname: String?
    /// SHA-256 (hex) of the tarball bytes, computed locally at capture.
    public var sha256: String
    public var byteCount: Int
    public var configs: [ConfigEntry]

    public init(createdAt: Date, routerID: String? = nil, routerName: String, address: String,
                model: String? = nil, firmware: String? = nil, hostname: String? = nil,
                sha256: String, byteCount: Int, configs: [ConfigEntry] = []) {
        self.createdAt = createdAt; self.routerID = routerID
        self.routerName = routerName; self.address = address
        self.model = model; self.firmware = firmware; self.hostname = hostname
        self.sha256 = sha256; self.byteCount = byteCount; self.configs = configs
    }

    public var totalSections: Int { configs.reduce(0) { $0 + $1.sectionCount } }
}

/// Name-level comparison of a backup against the router's current
/// configuration inventory — the honest preview a restore shows
/// before overwriting: which configs the restore brings, which it
/// leaves untouched, and which current configs the backup does not
/// contain (those survive a sysupgrade restore only if the restore
/// does not remove them; the UI copy says the backup's set wins).
public struct BackupDiff: Equatable, Sendable {
    public var onlyInBackup: [String]
    public var inBoth: [String]
    public var onlyInCurrent: [String]
    public init(onlyInBackup: [String], inBoth: [String], onlyInCurrent: [String]) {
        self.onlyInBackup = onlyInBackup; self.inBoth = inBoth; self.onlyInCurrent = onlyInCurrent
    }

    public static func diff(manifest: BackupManifest, currentConfigNames: [String]) -> BackupDiff {
        let backupNames = Set(manifest.configs.map(\.name))
        let currentNames = Set(currentConfigNames)
        return BackupDiff(
            onlyInBackup: backupNames.subtracting(currentNames).sorted(),
            inBoth: backupNames.intersection(currentNames).sorted(),
            onlyInCurrent: currentNames.subtracting(backupNames).sorted())
    }
}

public enum BackupFileNaming {
    /// `zirox-backup-<router>-<yyyyMMdd-HHmmss>.tar.gz`. The router
    /// component is reduced to filesystem-safe characters; an empty
    /// result falls back to "router".
    public static func fileName(routerName: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = routerName.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(scalar) : "-"
        }
        let trimmed = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "zirox-backup-\(trimmed.isEmpty ? "router" : trimmed)-\(formatter.string(from: date)).tar.gz"
    }

    /// The on-router staging path for one backup/restore round.
    public static func stagingPath(fileName: String) -> String {
        "/tmp/\(fileName)"
    }
}

/// The restore transaction, staged like the upgrade flow so that "no
/// explicit confirmation, no restore" is structural: `restore` refuses
/// to run without the confirmation flag the UI collects on the
/// preview surface. Before anything is overwritten, the router's
/// current configuration is backed up on the router itself and its
/// path reported back, so a bad restore leaves a recovery artefact
/// one restore away.
public enum BackupRestoreFlow {
    public enum Step: Equatable, Sendable {
        case snapshottingCurrent, uploading, verifyingUpload, restoring, rebooting, reconnectVerification, succeeded
        case failed(String)
    }

    public struct Operations: Sendable {
        /// Creates a sysupgrade backup on the router; returns its path.
        public var createBackupOnRouter: @Sendable () async throws -> String
        /// Downloads a router file's bytes.
        public var downloadFile: @Sendable (String) async throws -> Data
        /// Uploads bytes to a router path with readback verification.
        public var uploadFile: @Sendable (Data, String) async throws -> Void
        /// SHA-256 (hex) of a file on the router.
        public var remoteSHA256: @Sendable (String) async throws -> String
        /// `sysupgrade --restore-backup <path>`; throws on failure.
        public var restoreBackup: @Sendable (String) async throws -> Void
        /// Reboots the router; the connection drop is expected.
        public var reboot: @Sendable () async throws -> Void
        /// One reconnection probe; true when the router answers again.
        public var probeReconnect: @Sendable () async -> Bool
        /// Delay between reconnection probes (the app sleeps; tests
        /// pass a no-op).
        public var probeDelay: @Sendable () async -> Void

        public init(createBackupOnRouter: @escaping @Sendable () async throws -> String,
                    downloadFile: @escaping @Sendable (String) async throws -> Data,
                    uploadFile: @escaping @Sendable (Data, String) async throws -> Void,
                    remoteSHA256: @escaping @Sendable (String) async throws -> String,
                    restoreBackup: @escaping @Sendable (String) async throws -> Void,
                    reboot: @escaping @Sendable () async throws -> Void,
                    probeReconnect: @escaping @Sendable () async -> Bool,
                    probeDelay: @escaping @Sendable () async -> Void = {}) {
            self.createBackupOnRouter = createBackupOnRouter
            self.downloadFile = downloadFile
            self.uploadFile = uploadFile
            self.remoteSHA256 = remoteSHA256
            self.restoreBackup = restoreBackup
            self.reboot = reboot
            self.probeReconnect = probeReconnect
            self.probeDelay = probeDelay
        }
    }

    public struct RestoreResult: Equatable, Sendable {
        /// On-router path of the pre-restore snapshot of the
        /// configuration that was current just before the restore.
        public var preRestoreSnapshotPath: String
        public var reconnected: Bool
        public init(preRestoreSnapshotPath: String, reconnected: Bool) {
            self.preRestoreSnapshotPath = preRestoreSnapshotPath
            self.reconnected = reconnected
        }
    }

    /// Creates one backup package: asks the router for a sysupgrade
    /// backup, downloads it, and digests it locally. The caller
    /// attaches the inventory (config names + section counts) and
    /// persists bytes + manifest together.
    public static func createBackup(operations: Operations) async throws -> (data: Data, sha256: String) {
        let remotePath = try await operations.createBackupOnRouter()
        let data = try await operations.downloadFile(remotePath)
        guard !data.isEmpty else {
            throw OpenWrtKitError.unsupported(KitL10n.text("路由器返回了空的备份文件，未保存。"))
        }
        return (data, SHA256Hasher.hexDigest(data))
    }

    /// The restore proper. Refuses without `confirmed`. Order is the
    /// L4 discipline applied to a non-UCI write: snapshot the current
    /// state first, stage + verify the upload byte-for-byte, only
    /// then restore, reboot, and verify the router comes back.
    public static func restore(backupData: Data, fileName: String,
                               confirmed: Bool,
                               operations: Operations,
                               reconnectAttempts: Int = 40,
                               onStep: @Sendable (Step) -> Void = { _ in }) async throws -> RestoreResult {
        guard confirmed else { throw OpenWrtKitError.permissionDenied }
        onStep(.snapshottingCurrent)
        let snapshotPath = try await operations.createBackupOnRouter()
        let staging = BackupFileNaming.stagingPath(fileName: fileName)
        onStep(.uploading)
        try await operations.uploadFile(backupData, staging)
        onStep(.verifyingUpload)
        let localDigest = SHA256Hasher.hexDigest(backupData)
        let remoteDigest = try await operations.remoteSHA256(staging)
        guard remoteDigest.lowercased() == localDigest else {
            throw TransactionError.verificationFailed(staging)
        }
        onStep(.restoring)
        try await operations.restoreBackup(staging)
        onStep(.rebooting)
        // The reboot call drops the connection as the router goes
        // down; that transport failure is the expected shape.
        try? await operations.reboot()
        onStep(.reconnectVerification)
        for _ in 0..<max(1, reconnectAttempts) {
            if await operations.probeReconnect() {
                onStep(.succeeded)
                return RestoreResult(preRestoreSnapshotPath: snapshotPath, reconnected: true)
            }
            await operations.probeDelay()
        }
        onStep(.failed(KitL10n.text("恢复后未能重新连接路由器")))
        return RestoreResult(preRestoreSnapshotPath: snapshotPath, reconnected: false)
    }

    /// Builds the standard operations on top of the ubus file plane —
    /// the same wiring the upgrade flow uses, plus the restore exec.
    public static func standardOperations(files: FileClient) -> Operations {
        Operations(
            createBackupOnRouter: {
                let path = "/tmp/zirox-backup.tar.gz"
                let (code, _) = try await files.exec(command: "/sbin/sysupgrade", arguments: ["--create-backup", path])
                guard code == 0 else {
                    throw OpenWrtKitError.unsupported(KitL10n.format("备份创建失败（sysupgrade 返回 %lld）。", code))
                }
                return path
            },
            downloadFile: { path in
                let base64 = try await files.readBase64(path: path)
                guard let data = Data(base64Encoded: base64) else {
                    throw OpenWrtKitError.malformedResponse
                }
                return data
            },
            uploadFile: { data, path in
                try await files.writeDataVerified(path: path, data: data)
            },
            remoteSHA256: { path in
                let (code, output) = try await files.exec(command: "/usr/bin/sha256sum", arguments: [path])
                guard code == 0, let digest = output.split(separator: " ").first else {
                    throw OpenWrtKitError.unsupported(KitL10n.text("无法读取路由器上的备份哈希。"))
                }
                return String(digest)
            },
            restoreBackup: { path in
                let (code, _) = try await files.exec(command: "/sbin/sysupgrade", arguments: ["--restore-backup", path])
                guard code == 0 else {
                    throw OpenWrtKitError.unsupported(KitL10n.format("恢复失败（sysupgrade 返回 %lld），路由器配置未变更。", code))
                }
            },
            reboot: {
                // Replaced by the app's session wiring (SystemControlClient).
            },
            probeReconnect: { false } // replaced by the app's session wiring
        )
    }
}
