import Foundation
import OSLog
import UIKit
import OpenWrtKit

/// App-side diagnostics facade (package A).
///
/// The kit's `DiagnosticLog` ring buffer is the store of record: events
/// are structured (category + message + metadata) and redacted inside
/// the kit before they are stored, so nothing downstream can observe a
/// password or a session token. Every recorded event is also mirrored
/// to the unified log via os.Logger — the platform's own channel, so
/// Console.app and sysdiagnose see the same stream — and the mirror
/// forwards the stored (redacted) event text, never the raw input.
/// The export on the diagnostics page is rendered from the buffer by
/// the kit's `DiagnosticExport`.
enum AppDiagnostics {
    static let buffer = DiagnosticLog()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.openwrtmanager.ios",
        category: "diagnostics")

    static func record(_ category: DiagnosticCategory, _ message: String,
                       metadata: [String: String] = [:]) {
        let event = buffer.record(category: category, message: message, metadata: metadata)
        logger.log("[\(event.category.rawValue, privacy: .public)] \(event.message, privacy: .public)")
    }

    // MARK: Header facts

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Hardware model identifier (e.g. "iPhone17,2") — the value that
    /// actually identifies a device in a bug report, unlike the
    /// marketing name UIDevice exposes.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "unknown"
            }
        }
        return machine.isEmpty ? "unknown" : machine
    }

    static var systemSummary: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    static func makeHeader(routerName: String?, routerModel: String?,
                           firmwareDescription: String?) -> DiagnosticExportHeader {
        DiagnosticExportHeader(
            appVersion: appVersion, appBuild: appBuild,
            deviceModel: deviceModel,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            routerName: routerName, routerModel: routerModel,
            firmwareDescription: firmwareDescription)
    }

    /// Renders the export and writes it to a shareable text file.
    /// Returns nil when the write fails; the caller surfaces that as a
    /// normal error state instead of pretending a share happened.
    static func writeExportFile(header: DiagnosticExportHeader) -> URL? {
        let text = DiagnosticExport.render(header: header, events: buffer.events)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zirox-diagnostics-\(formatter.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
