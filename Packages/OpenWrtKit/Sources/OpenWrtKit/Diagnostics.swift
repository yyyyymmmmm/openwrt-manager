import Foundation

// MARK: - Structured diagnostic events
//
// The portable core of the app's diagnostics (package A): a bounded
// ring buffer of structured events, a redactor that keeps credentials
// out of anything that can leave the device, and a plain-text export
// renderer. The platform pattern this follows is the standard one —
// structured events captured in-process (mirrored to os.Logger by the
// app layer) and exported on demand — rather than a bespoke logging
// framework. This file stays free of Apple-only APIs so the whole
// pipeline is unit-tested with `swift test` on any platform.

/// The event families the export groups by. Raw values are the stable
/// tags printed in the export file; display names are the app's job.
public enum DiagnosticCategory: String, CaseIterable, Sendable {
    case app
    case connection
    case discovery
    case session
    case transaction
    case refresh
    case error
}

public struct DiagnosticEvent: Equatable, Sendable {
    public let date: Date
    public let category: DiagnosticCategory
    public let message: String
    /// Already redacted by the time an event exists — see DiagnosticRedactor.
    public let metadata: [String: String]

    public init(date: Date, category: DiagnosticCategory, message: String, metadata: [String: String] = [:]) {
        self.date = date
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

// MARK: - Redaction
//
// The rule, stated once and enforced at record time so no consumer
// (export file, system-log mirror, future crash reporter) can ever
// observe a raw secret:
//   * A metadata value whose KEY names a credential (password, token,
//     session, cookie, …) is replaced wholesale.
//   * Any remaining text — messages and other values — is scrubbed of
//     the credential SHAPES that leak into free text: `Bearer <...>`
//     credentials and hex runs of 32+ characters (ubus session ids are
//     exactly 32 hex chars; API tokens are typically longer).
// Deliberately NOT redacted: IP addresses and hostnames. This is a
// self-use diagnostic for the owner's own LAN; an export without
// addresses cannot answer "which router, which client", and the file
// only leaves the device when the user explicitly shares it.
public enum DiagnosticRedactor {
    public static let placeholder = "<redacted>"

    private static let sensitiveKeyFragments = [
        "password", "passwd", "pwd", "token", "secret", "cookie",
        "authorization", "session", "credential", "privatekey",
        "private_key", "apikey", "api_key",
    ]

    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    public static func redact(metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            result[key] = isSensitiveKey(key) ? placeholder : redactValue(value)
        }
        return result
    }

    public static func redactValue(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)Bearer\s+\S+"#, with: "Bearer \(placeholder)", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{32,}\b"#, with: placeholder, options: .regularExpression)
        return result
    }

    public static func redactMessage(_ message: String) -> String {
        redactValue(message)
    }
}

// MARK: - Ring buffer

/// Bounded in-memory event store: newest events win, the oldest are
/// dropped once the capacity is reached, so a long session cannot grow
/// the buffer without bound. Thread-safe; recording is cheap enough to
/// call from any context.
public final class DiagnosticLog: @unchecked Sendable {
    public static let defaultCapacity = 500

    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []
    public let capacity: Int

    public init(capacity: Int = DiagnosticLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Records one event and returns it in its stored (redacted) form,
    /// so mirrors — the app's os.Logger feed — can forward exactly what
    /// was kept, never the raw input.
    @discardableResult
    public func record(category: DiagnosticCategory, message: String,
                       metadata: [String: String] = [:], date: Date = Date()) -> DiagnosticEvent {
        let event = DiagnosticEvent(
            date: date, category: category,
            message: DiagnosticRedactor.redactMessage(message),
            metadata: DiagnosticRedactor.redact(metadata: metadata))
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        return event
    }

    /// All retained events, oldest first.
    public var events: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// The most recent `limit` events, oldest first.
    public func recent(_ limit: Int) -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        let all = events
        return Array(all.suffix(limit))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Export

/// Everything the export header needs. The app fills this from the
/// bundle, the device and the active router's discovery snapshot; the
/// kit never reaches for platform APIs itself.
public struct DiagnosticExportHeader: Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var deviceModel: String
    public var systemName: String
    public var systemVersion: String
    /// The active profile's display name, when connected.
    public var routerName: String?
    /// Board model from discovery (e.g. the router's hardware name).
    public var routerModel: String?
    /// Firmware description from discovery (distribution + version).
    public var firmwareDescription: String?
    public var generatedAt: Date

    public init(appVersion: String, appBuild: String, deviceModel: String,
                systemName: String, systemVersion: String,
                routerName: String? = nil, routerModel: String? = nil,
                firmwareDescription: String? = nil, generatedAt: Date = Date()) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deviceModel = deviceModel
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.routerName = routerName
        self.routerModel = routerModel
        self.firmwareDescription = firmwareDescription
        self.generatedAt = generatedAt
    }
}

public enum DiagnosticExport {
    /// Header convention (settled in audit H / L8): the export's first
    /// reader is the owner troubleshooting their own router, so the
    /// structural labels follow the app language through KitL10n like
    /// every other kit-produced string — they are not hard-coded
    /// English. Event messages are rendered exactly as they were
    /// recorded (already localized by their producers), timestamps
    /// stay ISO 8601, and the category tags stay the stable English
    /// raw values: those are machine vocabulary, not prose.
    public static func render(header: DiagnosticExportHeader, events: [DiagnosticEvent],
                              maxEvents: Int = 200) -> String {
        let formatter = ISO8601DateFormatter()
        let shown = events.suffix(max(0, maxEvents))
        var lines: [String] = []
        lines.append(KitL10n.text("Zirox-openwrt 诊断日志"))
        lines.append(KitL10n.format("生成时间：%@", formatter.string(from: header.generatedAt)))
        lines.append(KitL10n.format("应用：%@（%@）", header.appVersion, header.appBuild))
        lines.append(KitL10n.format("设备：%@", header.deviceModel))
        lines.append(KitL10n.format("系统：%@ %@", header.systemName, header.systemVersion))
        if let routerName = header.routerName { lines.append(KitL10n.format("路由器：%@", routerName)) }
        if let routerModel = header.routerModel { lines.append(KitL10n.format("路由器型号：%@", routerModel)) }
        if let firmware = header.firmwareDescription { lines.append(KitL10n.format("固件：%@", firmware)) }
        lines.append(KitL10n.format("事件：共 %lld 条，显示最近 %lld 条", events.count, shown.count))
        lines.append("")
        for event in shown {
            var line = "[\(formatter.string(from: event.date))] [\(event.category.rawValue)] \(event.message)"
            if !event.metadata.isEmpty {
                let pairs = event.metadata.keys.sorted().map { "\($0)=\(event.metadata[$0] ?? "")" }
                line += " (\(pairs.joined(separator: "; ")))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
