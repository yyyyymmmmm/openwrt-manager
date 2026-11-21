import XCTest
@testable import OpenWrtKit

final class Phase3CoreTests: XCTestCase {

    // MARK: SHA-256 (FIPS 180-4 vectors)

    func testSHA256StandardVectors() {
        XCTAssertEqual(SHA256Hasher.hexDigest(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hexDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hexDigest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256StreamingMatchesOneShot() {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        var hasher = SHA256Hasher()
        hasher.update(data.prefix(100))
        hasher.update(data.dropFirst(100))
        XCTAssertEqual(hasher.finalize(), SHA256Hasher.hash(data))
    }

    // MARK: Terminal core

    func testTerminalRendersPlainTextAndNewlines() {
        var parser = TerminalParser(columns: 10, rows: 3)
        parser.feed(Data("hello\r\nworld".utf8))
        XCTAssertEqual(parser.screen.lineText(0), "hello")
        XCTAssertEqual(parser.screen.lineText(1), "world")
        XCTAssertEqual(parser.screen.cursorRow, 1)
    }

    func testTerminalHandlesCursorMovementAndErase() {
        var parser = TerminalParser(columns: 10, rows: 3)
        parser.feed(Data("abcdef\u{1B}[2DZ".utf8))
        XCTAssertEqual(parser.screen.lineText(0), "abcdZf")
        parser.feed(Data("\u{1B}[K".utf8))
        XCTAssertEqual(parser.screen.lineText(0), "abcdZ")
    }

    func testTerminalSGRAttributes() {
        var parser = TerminalParser(columns: 10, rows: 2)
        parser.feed(Data("\u{1B}[1;31mX\u{1B}[0mY".utf8))
        let first = parser.screen.grid[0][0]
        XCTAssertTrue(first.bold)
        XCTAssertEqual(first.foreground, 1)
        let second = parser.screen.grid[0][1]
        XCTAssertFalse(second.bold)
        XCTAssertNil(second.foreground)
    }

    func testTerminalScrollsIntoScrollback() {
        var parser = TerminalParser(columns: 5, rows: 2)
        parser.feed(Data("a\r\nb\r\nc".utf8))
        XCTAssertEqual(parser.screen.lineText(0), "b")
        XCTAssertEqual(parser.screen.lineText(1), "c")
        XCTAssertEqual(parser.screen.scrollback.count, 1)
        XCTAssertEqual(String(parser.screen.scrollback[0].map(\.character)), "a    ")
    }

    func testTerminalIgnoresOSCAndHandlesWrap() {
        var parser = TerminalParser(columns: 4, rows: 3)
        parser.feed(Data("\u{1B}]0;title\u{07}abcdefg".utf8))
        XCTAssertEqual(parser.screen.lineText(0), "abcd")
        XCTAssertEqual(parser.screen.lineText(1), "efg")
    }

    func testTerminalInputEncoding() {
        XCTAssertEqual(TerminalInput.data(for: .enter), Data("\r".utf8))
        XCTAssertEqual(TerminalInput.data(for: .arrowUp), Data("\u{1B}[A".utf8))
        XCTAssertEqual(TerminalInput.data(for: .control("C")), Data([0x03]))
        XCTAssertEqual(TerminalInput.data(for: .delete), Data("\u{1B}[3~".utf8))
    }

    // MARK: File client

    func testFileParserSortsDirectoriesFirst() throws {
        let json = #"{"entries":[{"name":"b.txt","type":"file","size":12},{"name":"etc","type":"directory"},{"name":"a.txt","type":"file"}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let entries = FileParser.entries(value)
        XCTAssertEqual(entries.map(\.name), ["etc", "a.txt", "b.txt"])
        XCTAssertEqual(entries[2].size, 12)
    }

    func testFileWriteVerifiedReReadsContent() async throws {
        let caller = FileFakeCaller()
        let files = FileClient(caller: caller)
        try await files.writeTextVerified(path: "/etc/config/test", content: "config x 'y'")
        XCTAssertEqual(caller.storage["/etc/config/test"], "config x 'y'")
    }

    func testFileWriteVerifiedDetectsCorruption() async throws {
        let caller = FileFakeCaller()
        caller.corruptWrites = true
        let files = FileClient(caller: caller)
        do {
            try await files.writeTextVerified(path: "/tmp/x", content: "payload")
            XCTFail("Expected verification failure")
        } catch let error as TransactionError {
            XCTAssertEqual(error, .verificationFailed("/tmp/x"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFileWriteDataChunksAndVerifiesSize() async throws {
        let caller = FileFakeCaller()
        let files = FileClient(caller: caller)
        let data = Data((0..<5_000).map { UInt8($0 % 256) })
        try await files.writeDataVerified(path: "/tmp/image.bin", data: data, chunkSize: 1_000)
        XCTAssertEqual(caller.binaryStorage["/tmp/image.bin"], data)
        let writes = caller.calls.filter { $0.1 == "write" }
        XCTAssertGreaterThan(writes.count, 1)
    }

    // MARK: Upgrade flow (spec section 6 order)

    func testUpgradePrepareOrderAndHashGate() async throws {
        let recorder = UpgradeRecorder()
        let operations = recorder.operations()
        let image = Data("firmware-bytes".utf8)
        let prepared = try await UpgradeFlow.prepare(image: image, operations: operations) { step in
            recorder.record(step: step)
        }
        XCTAssertEqual(prepared.imageSHA256, SHA256Hasher.hexDigest(image))
        XCTAssertEqual(recorder.steps, [.backup, .staging, .hashVerification, .imageValidation, .awaitingSecondConfirmation])
    }

    func testUpgradePrepareAbortsOnHashMismatchBeforeValidation() async throws {
        let recorder = UpgradeRecorder()
        recorder.remoteDigest = String(repeating: "0", count: 64)
        let operations = recorder.operations()
        do {
            _ = try await UpgradeFlow.prepare(image: Data("x".utf8), operations: operations)
            XCTFail("Expected hash verification failure")
        } catch let error as TransactionError {
            guard case .verificationFailed = error else { return XCTFail("Wrong error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(recorder.validated)
        XCTAssertFalse(recorder.upgraded)
    }

    func testUpgradeFinishRefusesWithoutSecondConfirmation() async throws {
        let recorder = UpgradeRecorder()
        let operations = recorder.operations()
        do {
            _ = try await UpgradeFlow.finish(secondConfirmation: false, operations: operations)
            XCTFail("Expected refusal")
        } catch let error as OpenWrtKitError {
            XCTAssertEqual(error, .permissionDenied)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(recorder.upgraded)
    }

    func testUpgradeFinishUpgradesAndVerifiesReconnection() async throws {
        let recorder = UpgradeRecorder()
        recorder.probeResults = [false, false, true]
        let operations = recorder.operations()
        let reconnected = try await UpgradeFlow.finish(secondConfirmation: true, operations: operations) { step in recorder.record(step: step) }
        XCTAssertTrue(reconnected)
        XCTAssertTrue(recorder.upgraded)
        XCTAssertEqual(recorder.steps, [.upgrading, .reconnectVerification, .succeeded])
    }

    // MARK: Field catalog

    func testFieldCatalogLabelsAndKinds() {
        XCTAssertEqual(FieldCatalog.label(config: "dhcp", sectionType: "dnsmasq", option: "cachesize"), "缓存大小")
        XCTAssertEqual(FieldCatalog.label(config: "network", sectionType: "interface", option: "proto"), "协议")
        XCTAssertEqual(FieldCatalog.descriptor(config: "firewall", sectionType: "defaults", option: "input")?.kind,
                       .enumeration(["ACCEPT", "REJECT", "DROP"]))
        XCTAssertEqual(FieldCatalog.descriptor(config: "anything", sectionType: "x", option: "enabled")?.kind, .boolean)
        XCTAssertNil(FieldCatalog.label(config: "x", sectionType: "y", option: "totally_unknown_option"))
    }

    func testGenericRowsCarryCatalogLabels() {
        let configuration = RouterConfiguration(name: "dhcp", sections: [
            .init(id: "cfg", type: "dnsmasq", values: ["cachesize": .number(8000), "mystery": .string("v")])
        ])
        let rows = GenericPageModel.sections(from: configuration)[0].rows
        XCTAssertEqual(rows.first { $0.key == "cachesize" }?.displayKey, "缓存大小")
        XCTAssertEqual(rows.first { $0.key == "mystery" }?.displayKey, "mystery")
    }

    func testRegistryPhase3PagesPresentButMenuExclusionsStay() throws {
        let url = Bundle.module.url(forResource: "snapshot-192.168.31.167-2026-11-20", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/snapshot-192.168.31.167-2026-11-20.json")
        let collected = try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
        let system = PageRegistry.tabs(for: CapabilitySnapshot(collected: collected))
            .first { $0.tab == .system }?.pages ?? []
        XCTAssertTrue(system.contains { $0.kind == .terminal })
        XCTAssertTrue(system.contains { $0.kind == .fileManager })
        XCTAssertFalse(system.contains { $0.menuPath == "admin/system/ttyd" })
        XCTAssertFalse(system.contains { $0.menuPath == "admin/system/quickfile" })
    }
}

/// In-memory ubus file plane for FileClient tests.
private final class FileFakeCaller: UbusCalling, @unchecked Sendable {
    private let lock = NSLock()
    var storage: [String: String] = [:]
    var binaryStorage: [String: Data] = [:]
    var corruptWrites = false
    private var recorded: [(String, String)] = []
    var calls: [(String, String)] { lock.lock(); defer { lock.unlock() }; return recorded }

    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        lock.lock(); recorded.append((object, method)); lock.unlock()
        let path = parameters["path"]?.stringValue ?? ""
        switch method {
        case "write":
            if parameters["base64"]?.boolValue == true {
                let chunk = Data(base64Encoded: parameters["data"]?.stringValue ?? "") ?? Data()
                if parameters["append"]?.boolValue == true {
                    binaryStorage[path, default: Data()].append(chunk)
                } else {
                    binaryStorage[path] = chunk
                }
            } else {
                storage[path] = corruptWrites ? "corrupted" : (parameters["data"]?.stringValue ?? "")
            }
            return .object([:])
        case "read":
            return .object(["data": .string(storage[path] ?? "")])
        case "stat":
            if let data = binaryStorage[path] {
                return .object(["type": .string("file"), "size": .number(Double(data.count))])
            }
            return .object(["type": .string("file"), "size": .number(Double((storage[path] ?? "").count))])
        default:
            return .object([:])
        }
    }

    func menu() async throws -> JSONValue { .object([:]) }
    func installedPackages() async throws -> [InstalledPackage] { [] }
}

/// Scripted upgrade operations with step recording.
private final class UpgradeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [UpgradeFlow.Step] = []
    var steps: [UpgradeFlow.Step] { lock.lock(); defer { lock.unlock() }; return recordedSteps }
    var remoteDigest: String?
    var validated = false
    var upgraded = false
    var probeResults: [Bool] = [true]

    func record(step: UpgradeFlow.Step) {
        lock.lock(); recordedSteps.append(step); lock.unlock()
    }

    func operations() -> UpgradeFlow.Operations {
        UpgradeFlow.Operations(
            createBackup: { "/tmp/zirox-backup.tar.gz" },
            stageImage: { _, _ in },
            remoteSHA256: { _ in
                if let digest = self.remoteDigest { return digest }
                return SHA256Hasher.hexDigest(Data("firmware-bytes".utf8))
            },
            validateImage: { _ in self.validated = true; return true },
            runUpgrade: { _ in self.upgraded = true },
            probeReconnect: {
                self.probeResults.isEmpty ? true : self.probeResults.removeFirst()
            })
    }
}
