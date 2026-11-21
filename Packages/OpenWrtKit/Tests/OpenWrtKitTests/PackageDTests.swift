import XCTest
@testable import OpenWrtKit

/// Package D kit coverage: wcwidth grid layout, screen resize,
/// bracketed paste, terminal geometry, file directory operations and
/// the widget status summary.
final class PackageDTests: XCTestCase {

    // MARK: wcwidth

    func testCharWidthTable() {
        XCTAssertEqual(TerminalCharWidth.width(of: "a"), 1)
        XCTAssertEqual(TerminalCharWidth.width(of: "路"), 2)
        XCTAssertEqual(TerminalCharWidth.width(of: "由"), 2)
        XCTAssertEqual(TerminalCharWidth.width(of: "Ａ"), 2) // fullwidth A
        XCTAssertEqual(TerminalCharWidth.width(of: "ｱ"), 1) // halfwidth katakana
        XCTAssertEqual(TerminalCharWidth.width(of: Character("\u{0301}")), 0) // combining acute
        XCTAssertEqual(TerminalCharWidth.width(of: "😀"), 2)
    }

    func testWideCharacterOccupiesTwoCells() {
        var screen = TerminalScreen(columns: 6, rows: 2)
        screen.putCharacter("a")
        screen.putCharacter("路")
        screen.putCharacter("b")
        XCTAssertEqual(screen.lineText(0), "a路b")
        XCTAssertEqual(screen.cursorColumn, 4)
        XCTAssertTrue(screen.grid[0][2].isWideContinuation)
        XCTAssertFalse(screen.grid[0][1].isWideContinuation)
    }

    func testWideCharacterAtRightEdgeWraps() {
        var screen = TerminalScreen(columns: 4, rows: 3)
        for ch: Character in ["a", "b", "c"] { screen.putCharacter(ch) }
        screen.putCharacter("路") // only one column left: blank it and wrap
        XCTAssertEqual(screen.lineText(0), "abc")
        XCTAssertEqual(screen.lineText(1), "路")
        XCTAssertEqual(screen.cursorRow, 1)
    }

    func testCombiningMarkMergesIntoPreviousGlyph() {
        var screen = TerminalScreen(columns: 6, rows: 1)
        screen.putCharacter("e")
        screen.putCharacter(Character("\u{0301}"))
        XCTAssertEqual(screen.lineText(0), "é")
        XCTAssertEqual(screen.cursorColumn, 1)
    }

    // MARK: Resize

    func testScreenResizePreservesAndClamps() {
        var parser = TerminalParser(columns: 6, rows: 2)
        parser.feed(Data("abcdef".utf8))
        parser.resize(columns: 4, rows: 3)
        XCTAssertEqual(parser.screen.columns, 4)
        XCTAssertEqual(parser.screen.rows, 3)
        XCTAssertEqual(parser.screen.lineText(0), "abcd")
        parser.resize(columns: 10, rows: 1)
        XCTAssertEqual(parser.screen.lineText(0), "abcd")
        XCTAssertEqual(parser.screen.cursorRow, 0)
    }

    func testGeometryClampsDegenerateSizes() {
        XCTAssertEqual(TerminalGeometry.gridSize(viewWidth: 0, viewHeight: 0, cellWidth: 7, cellHeight: 14).columns, 80)
        let tiny = TerminalGeometry.gridSize(viewWidth: 10, viewHeight: 10, cellWidth: 7, cellHeight: 14)
        XCTAssertEqual(tiny.columns, 20)
        XCTAssertEqual(tiny.rows, 5)
        let normal = TerminalGeometry.gridSize(viewWidth: 700, viewHeight: 280, cellWidth: 7, cellHeight: 14)
        XCTAssertEqual(normal.columns, 100)
        XCTAssertEqual(normal.rows, 20)
    }

    // MARK: Bracketed paste

    func testBracketedPasteModeTracking() {
        var parser = TerminalParser()
        XCTAssertFalse(parser.bracketedPasteEnabled)
        parser.feed(Data("\u{1B}[?2004h".utf8))
        XCTAssertTrue(parser.bracketedPasteEnabled)
        parser.feed(Data("\u{1B}[?2004l".utf8))
        XCTAssertFalse(parser.bracketedPasteEnabled)
    }

    func testPasteEncodingWrapsAndSanitizes() {
        let wrapped = TerminalInput.data(forPaste: "ls\nrm", bracketed: true)
        XCTAssertEqual(String(decoding: wrapped, as: UTF8.self), "\u{1B}[200~ls\nrm\u{1B}[201~")
        let smuggled = TerminalInput.data(forPaste: "a\u{1B}[2Jb", bracketed: true)
        XCTAssertEqual(String(decoding: smuggled, as: UTF8.self), "\u{1B}[200~a[2Jb\u{1B}[201~")
        let plain = TerminalInput.data(forPaste: "a\nb", bracketed: false)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "a\rb")
    }

    // MARK: File directory operations

    func testDirectoryOperationsUseFixedCommandsAndCheckExitCodes() async throws {
        let caller = ExecFakeCaller()
        let files = FileClient(caller: caller)
        try await files.makeDirectory(path: "/etc/new dir")
        try await files.rename(from: "/etc/a", to: "/etc/b")
        try await files.removeDirectory(path: "/etc/empty")
        XCTAssertEqual(caller.commands, ["/bin/mkdir", "/bin/mv", "/bin/rmdir"])
        XCTAssertEqual(caller.arguments[0], ["/etc/new dir"])
        XCTAssertEqual(caller.arguments[1], ["/etc/a", "/etc/b"])

        caller.exitCode = 1
        do {
            try await files.makeDirectory(path: "/root/nope")
            XCTFail("a nonzero exit must throw")
        } catch {
            // expected: failure is reported, never swallowed
        }
    }

    // MARK: Widget summary

    func testWidgetSummaryBuildAndCodableRoundTrip() throws {
        var snapshot = RouterSnapshot()
        snapshot.system.model = "AX3000T"
        snapshot.system.firmware = "OpenWrt 24.10.8"
        snapshot.system.uptime = 3661
        snapshot.system.loadAverage = [0.42, 0.3, 0.2]
        snapshot.system.memoryUsed = 50
        snapshot.system.memoryTotal = 200
        snapshot.system.storageUsed = 30
        snapshot.system.storageTotal = 100
        let leases = [DHCPLease(hostname: "phone", address: "192.168.31.100", mac: "AA", expires: nil)]
        let services = [
            RouterService(name: "dnsmasq", runningInstances: 1, totalInstances: 1),
            RouterService(name: "cron", runningInstances: 0, totalInstances: 1),
            RouterService(name: "boot", runningInstances: nil, totalInstances: nil),
        ]
        let summary = RouterStatusSummary.build(routerName: "主路由", snapshot: snapshot,
                                                leases: leases, services: services,
                                                at: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(summary.routerName, "主路由")
        XCTAssertEqual(summary.connectedDevices, 1)
        XCTAssertEqual(summary.runningServices, 1)
        XCTAssertEqual(summary.totalServices, 3)
        XCTAssertEqual(summary.memoryUsedFraction, 0.25)
        XCTAssertEqual(summary.loadOneMinute, 0.42)
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(RouterStatusSummary.self, from: data), summary)
    }
}

/// Records file-exec calls and answers with a scripted exit code.
private final class ExecFakeCaller: UbusCalling, @unchecked Sendable {
    private let lock = NSLock()
    var exitCode = 0
    private var recordedCommands: [String] = []
    private var recordedArguments: [[String]] = []
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return recordedCommands }
    var arguments: [[String]] { lock.lock(); defer { lock.unlock() }; return recordedArguments }

    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        if method == "exec" {
            lock.lock()
            recordedCommands.append(parameters["command"]?.stringValue ?? "")
            recordedArguments.append((parameters["params"]?.arrayValue ?? []).compactMap { $0.stringValue })
            let code = exitCode
            lock.unlock()
            return .object(["code": .number(Double(code)), "stdout": .string("")])
        }
        return .object([:])
    }

    func menu() async throws -> JSONValue { .object([:]) }
    func installedPackages() async throws -> [InstalledPackage] { [] }
}
