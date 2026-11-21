import Foundation
import Observation
import LocalAuthentication
import OpenWrtKit

// MARK: - Backup library (package C, item 1)
//
// Backup tarballs and their manifests live in Application
// Support/ZiroxOpenWrt/Backups. The tarball is the standard
// sysupgrade artefact (LuCI-compatible); the manifest is app-side
// metadata for preview/diff. Backup files contain the router's full
// configuration — they are stored locally only, never written to
// the diagnostic log, and leave the device only through the user's
// own share action.

struct BackupEntry: Identifiable, Equatable {
    var id: String { fileName }
    var fileName: String
    var fileURL: URL
    /// nil for backups imported from elsewhere (e.g. a LuCI
    /// download): restorable, but with no inventory to preview.
    var manifest: BackupManifest?
    var byteCount: Int
    var addedAt: Date
}

@MainActor @Observable
final class BackupLibraryStore {
    private(set) var entries: [BackupEntry] = []
    @ObservationIgnored private let directory: URL?

    init() {
        directory = MonitoringFiles.directory()?.appendingPathComponent("Backups", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        reload()
    }

    func reload() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { entries = []; return }
        entries = files.filter { $0.pathExtension == "gz" || $0.lastPathComponent.hasSuffix(".tar.gz") }
            .map { url in
                let manifest = MonitoringFiles.load(
                    BackupManifest.self,
                    from: url.appendingPathExtension("manifest.json"))
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return BackupEntry(
                    fileName: url.lastPathComponent,
                    fileURL: url,
                    manifest: manifest,
                    byteCount: manifest?.byteCount ?? values?.fileSize ?? 0,
                    addedAt: manifest?.createdAt ?? values?.contentModificationDate ?? Date())
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// Persists a freshly created backup (bytes + manifest together).
    func save(data: Data, manifest: BackupManifest, fileName: String) throws {
        guard let directory else { throw AppFailure.storage(L10n.string("无法访问本地备份目录。")) }
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        MonitoringFiles.save(manifest, to: url.appendingPathExtension("manifest.json"))
        reload()
    }

    /// Imports a backup file produced elsewhere. No manifest exists,
    /// so the entry previews as file-level information only.
    func importBackup(from source: URL) throws {
        guard let directory else { throw AppFailure.storage(L10n.string("无法访问本地备份目录。")) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).tar.gz")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        reload()
    }

    func data(for entry: BackupEntry) throws -> Data {
        try Data(contentsOf: entry.fileURL)
    }

    func remove(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
        try? FileManager.default.removeItem(at: entry.fileURL.appendingPathExtension("manifest.json"))
        reload()
    }
}

// MARK: - Device names (package C, item 2)
//
// User-assigned names for network devices, keyed by router + MAC.
// Local presentation only — nothing is written to the router.

@MainActor @Observable
final class DeviceNameStore {
    static let shared = DeviceNameStore()

    private(set) var names: [String: [String: String]] = [:]
    @ObservationIgnored private let fileURL: URL?

    init() {
        fileURL = MonitoringFiles.directory()?.appendingPathComponent("device-names.json")
        if let saved: [String: [String: String]] = MonitoringFiles.load(
            [String: [String: String]].self, from: fileURL) {
            names = saved
        }
    }

    func name(routerID: String, mac: String) -> String? {
        guard let normalized = DeviceRoster.normalizeMAC(mac) else { return nil }
        return names[routerID]?[normalized]
    }

    func setName(_ name: String?, routerID: String, mac: String) {
        guard let normalized = DeviceRoster.normalizeMAC(mac) else { return }
        var perRouter = names[routerID] ?? [:]
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { perRouter.removeValue(forKey: normalized) }
        else { perRouter[normalized] = trimmed }
        names[routerID] = perRouter
        MonitoringFiles.save(names, to: fileURL)
    }
}

// MARK: - SSH host-key trust persistence (package C, item 5)
//
// The kit owns the trust logic; this wrapper owns the JSON file.
// Fingerprints are public identifiers, not credentials — the file
// sits beside the other local stores, not in the Keychain.

@MainActor @Observable
final class SSHTrustStore {
    static let shared = SSHTrustStore()

    private(set) var trust = HostKeyTrustStore()
    @ObservationIgnored private let fileURL: URL?

    init() {
        fileURL = MonitoringFiles.directory()?.appendingPathComponent("ssh-trust.json")
        if let saved: HostKeyTrustStore = MonitoringFiles.load(HostKeyTrustStore.self, from: fileURL) {
            trust = saved
        }
    }

    func evaluate(host: String, port: Int, presentedFingerprint: String) -> HostKeyTrustStore.Verdict {
        trust.evaluate(host: host, port: port, presentedFingerprint: presentedFingerprint)
    }

    func trustedFingerprint(host: String, port: Int) -> String? {
        trust.record(host: host, port: port)?.fingerprint
    }

    func confirmTrust(host: String, port: Int, fingerprint: String) {
        trust.trust(host: host, port: port, fingerprint: fingerprint)
        MonitoringFiles.save(trust, to: fileURL)
    }

    func revoke(_ record: HostKeyTrustStore.Record) {
        let parts = record.endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return }
        trust.revoke(host: String(parts[0]), port: port)
        MonitoringFiles.save(trust, to: fileURL)
    }
}

// MARK: - App lock (package C, item 4)
//
// Optional biometric/passcode gate over the whole app. While locked
// the root content is fully covered — no router names, lists or
// values render. Returning from the background within the grace
// window (30 s: a quick switch to copy a password or check a message
// should not demand a fresh unlock) keeps the session open; longer
// absences, and every cold start with the lock on, require
// authentication. Authentication is the system policy
// `.deviceOwnerAuthentication`: Face ID / Touch ID with the device
// passcode as the built-in fallback.
//
// The router credentials in the Keychain are NOT re-gated behind
// biometrics: they already sit at
// kSecAttrAccessibleWhenUnlockedThisDeviceOnly (unavailable while
// the device itself is locked, never synced), and gating each read
// behind an interactive prompt would break background sampling,
// which reads the remembered password with no user present.

@MainActor @Observable
final class AppLockController {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Observable mirror of the persisted setting, so the settings
    /// toggle reflects authentication outcomes immediately.
    private(set) var enabled: Bool

    private func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var hasUnlockedThisLaunch = false
    private static let enabledKey = "app-lock-enabled.v1"
    /// Grace window for background returns, in seconds.
    static let grace: TimeInterval = 30

    init() {
        // The XCUITest seed must never meet a lock screen.
        #if DEBUG
        let seeded = ProcessInfo.processInfo.arguments.contains(UITestingSeed.profilesArgument)
            || ProcessInfo.processInfo.arguments.contains(UITestingSeed.connectedArgument)
        #else
        let seeded = false
        #endif
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
        enabled = on
        isLocked = on && !seeded
        hasUnlockedThisLaunch = seeded
    }

    func handleScenePhase(_ phase: ScenePhaseLike) {
        switch phase {
        case .background:
            if enabled { backgroundedAt = Date() }
        case .active:
            guard enabled, let backgroundedAt else { return }
            self.backgroundedAt = nil
            if Date().timeIntervalSince(backgroundedAt) > Self.grace {
                isLocked = true
            }
        case .inactive:
            break
        }
    }

    /// Runs the system authentication prompt. On success the lock
    /// lifts; on failure or cancellation it stays.
    func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.string("解锁以查看路由器管理内容"))
            if success {
                isLocked = false
                hasUnlockedThisLaunch = true
            } else {
                recordAuthFailure(nil, action: "unlock")
            }
        } catch {
            // Cancelled or failed: remain locked, no error surface —
            // the lock screen's retry button is the whole story.
            // The reason still lands in the diagnostics log
            // (package N), where an export can tell a cancel from
            // a lockout from a prompt that could never appear.
            recordAuthFailure(error, action: "unlock")
        }
    }

    /// Package N: App lock authentication failures used to vanish
    /// into empty catches, exactly like the credential gate's did.
    /// The token is the kit's stable rendering of the LAError code
    /// — never the error's localized text, never any credential.
    private func recordAuthFailure(_ error: Error?, action: String) {
        let token: String
        if let error {
            let code = (error as? LAError)?.code.rawValue ?? (error as NSError).code
            token = BiometricAvailability.failureToken(errorCode: code)
        } else {
            token = "evaluate-returned-false"
        }
        AppDiagnostics.record(.error, L10n.string("App 锁身份验证失败"),
                              metadata: ["reason": token, "action": action])
    }

    /// Turning the lock on requires a successful authentication
    /// first, so a user cannot enable a gate they cannot pass.
    func enableWithAuthentication() async -> Bool {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.string("验证身份以启用 App 锁"))
            if success {
                setEnabled(true)
                isLocked = false
                hasUnlockedThisLaunch = true
                return true
            }
            recordAuthFailure(nil, action: "enable")
        } catch {
            recordAuthFailure(error, action: "enable")
        }
        return false
    }

    func disable() {
        setEnabled(false)
        isLocked = false
    }

    /// Turning the lock off requires the same authentication as
    /// turning it on (package I, audit U20): whoever holds an
    /// already-unlocked phone must not be able to silently remove
    /// the gate. On failure the setting simply stays on.
    func disableWithAuthentication() async -> Bool {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.string("验证身份以关闭 App 锁"))
            if success {
                disable()
                return true
            }
            recordAuthFailure(nil, action: "disable")
        } catch {
            recordAuthFailure(error, action: "disable")
        }
        return false
    }

    enum ScenePhaseLike { case active, inactive, background }
}
