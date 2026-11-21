import Foundation

/// The strengthened online-upgrade transaction (spec section 6). The
/// upgrade button may only exist on top of this flow, and every step is
/// mandatory, in this order:
///   1. automatic backup of the current configuration
///   2. image staged on the router and its SHA-256 verified against the
///      locally computed digest
///   3. image validated by sysupgrade's own test mode
///   4. a second, separate user confirmation (the UI collects it between
///      steps 3 and 5 — this type refuses to run without it)
///   5. upgrade executed
///   6. automatic reconnection verification (the caller polls until the
///      router answers again; this type drives the polling)
/// Any failure before step 5 aborts with the router untouched.
public enum UpgradeFlow {
    public enum Step: Equatable, Sendable {
        case backup, staging, hashVerification, imageValidation, awaitingSecondConfirmation
        case upgrading, reconnectVerification, succeeded
        case failed(String)
    }

    public struct Operations: Sendable {
        /// Creates a config backup on the router and returns its path.
        public var createBackup: @Sendable () async throws -> String
        /// Stages the image at the given router path (verified write).
        public var stageImage: @Sendable (Data, String) async throws -> Void
        /// SHA-256 of a file on the router, hex encoded.
        public var remoteSHA256: @Sendable (String) async throws -> String
        /// sysupgrade -T: validates the image without flashing.
        public var validateImage: @Sendable (String) async throws -> Bool
        /// Runs sysupgrade; the connection is expected to drop.
        public var runUpgrade: @Sendable (String) async throws -> Void
        /// One reconnection probe; true when the router answers again.
        public var probeReconnect: @Sendable () async -> Bool

        public init(createBackup: @escaping @Sendable () async throws -> String,
                    stageImage: @escaping @Sendable (Data, String) async throws -> Void,
                    remoteSHA256: @escaping @Sendable (String) async throws -> String,
                    validateImage: @escaping @Sendable (String) async throws -> Bool,
                    runUpgrade: @escaping @Sendable (String) async throws -> Void,
                    probeReconnect: @escaping @Sendable () async -> Bool) {
            self.createBackup = createBackup
            self.stageImage = stageImage
            self.remoteSHA256 = remoteSHA256
            self.validateImage = validateImage
            self.runUpgrade = runUpgrade
            self.probeReconnect = probeReconnect
        }
    }

    public struct Result: Equatable, Sendable {
        public var backupPath: String
        public var imageSHA256: String
        public var reconnected: Bool
    }

    /// Runs steps 1-3 and returns the local digest; the UI then collects
    /// the second confirmation and calls finish(). Splitting the flow at
    /// exactly this point makes "no second confirmation, no upgrade" a
    /// structural property, not a promise.
    public static func prepare(image: Data, imagePath: String = "/tmp/firmware-image.bin",
                               operations: Operations,
                               onStep: @Sendable (Step) -> Void = { _ in }) async throws -> (backupPath: String, imageSHA256: String) {
        onStep(.backup)
        let backupPath = try await operations.createBackup()
        onStep(.staging)
        try await operations.stageImage(image, imagePath)
        onStep(.hashVerification)
        let localDigest = SHA256Hasher.hexDigest(image)
        let remoteDigest = try await operations.remoteSHA256(imagePath)
        guard remoteDigest.lowercased() == localDigest else {
            throw TransactionError.verificationFailed(KitL10n.format("镜像哈希不一致：本地 %@，路由器 %@", localDigest, remoteDigest))
        }
        onStep(.imageValidation)
        guard try await operations.validateImage(imagePath) else {
            throw OpenWrtKitError.unsupported(KitL10n.text("路由器拒绝了此镜像（sysupgrade 校验未通过），未执行升级。"))
        }
        onStep(.awaitingSecondConfirmation)
        return (backupPath, localDigest)
    }

    /// Steps 5-6. Only callable with the second confirmation in hand.
    public static func finish(imagePath: String = "/tmp/firmware-image.bin",
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
    public static func standardOperations(files: FileClient) -> Operations {
        Operations(
            createBackup: {
                let path = "/tmp/zirox-backup.tar.gz"
                let (code, _) = try await files.exec(command: "/sbin/sysupgrade", arguments: ["--create-backup", path])
                guard code == 0 else { throw OpenWrtKitError.unsupported(KitL10n.format("备份创建失败（sysupgrade 返回 %lld）。", code)) }
                return path
            },
            stageImage: { data, path in
                try await files.writeDataVerified(path: path, data: data)
            },
            remoteSHA256: { path in
                let (code, output) = try await files.exec(command: "/usr/bin/sha256sum", arguments: [path])
                guard code == 0, let digest = output.split(separator: " ").first else {
                    throw OpenWrtKitError.unsupported(KitL10n.text("无法读取路由器上的镜像哈希。"))
                }
                return String(digest)
            },
            validateImage: { path in
                let (code, _) = try await files.exec(command: "/sbin/sysupgrade", arguments: ["-T", path])
                return code == 0
            },
            runUpgrade: { path in
                // The router reboots mid-call; a transport failure here is
                // the expected shape and is swallowed by the caller wiring.
                _ = try? await files.exec(command: "/sbin/sysupgrade", arguments: [path])
            },
            probeReconnect: { false } // replaced by the app's session wiring
        )
    }
}
