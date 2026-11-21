import XCTest
@testable import OpenWrtKit

/// Online-upgrade safety closure: storage precheck (df parsing +
/// verdict), streaming staging (FileClient chunked write + the
/// streaming UpgradeFlow.prepare), expected-digest gate and
/// partial-image cleanup. The df fixtures are the verbatim outputs
/// measured read-only on the household routers on 2026-11-21.
final class UpgradeSafetyClosureTests: XCTestCase {

    // MARK: df parsing (measured outputs)

    /// Main router 192.168.31.1 (AX3000T, OpenWrt 24.10.8): /tmp is a
    /// small tmpfs, /overlay is its own ubi volume.
    private let dfMainRouter = """
    Filesystem           1K-blocks      Used Available Use% Mounted on
    tmpfs                   119860      2148    117712   2% /tmp
    /dev/ubi0_1              62388      5576     53584   9% /overlay
    overlayfs:/overlay       62388      5576     53584   9% /
    """

    /// Bypass router 192.168.31.167 (OpenWrt 25.12.5, VM): /overlay
    /// has no row of its own; df answers with the root row.
    private let dfBypassRouter = """
    Filesystem           1K-blocks      Used Available Use% Mounted on
    tmpfs                  2012400     12228   2000172   1% /tmp
    /dev/root               935084    581212    337488  63% /
    /dev/root               935084    581212    337488  63% /
    """

    func testDfParserMainRouterKeepsVolumesSeparate() {
        let space = DfOutputParser.parse(dfMainRouter)
        XCTAssertEqual(space.tmpFreeBytes, 117_712 * 1024)
        XCTAssertEqual(space.overlayFreeBytes, 53_584 * 1024)
    }

    func testDfParserOverlayFallsBackToRootRow() {
        let space = DfOutputParser.parse(dfBypassRouter)
        XCTAssertEqual(space.tmpFreeBytes, 2_000_172 * 1024)
        XCTAssertEqual(space.overlayFreeBytes, 337_488 * 1024)
    }

    func testDfParserGarbageYieldsUnknown() {
        let space = DfOutputParser.parse("not df output\n")
        XCTAssertNil(space.tmpFreeBytes)
        XCTAssertNil(space.overlayFreeBytes)
    }

    // MARK: Space verdict

    func testSpaceVerdictSufficientInsufficientUnknown() {
        let image: Int64 = 20 * 1024 * 1024
        XCTAssertEqual(
            UpgradeSpaceCheck.tmpVerdict(imageSize: image, space: .init(tmpFreeBytes: image, overlayFreeBytes: nil)),
            .sufficient)
        XCTAssertEqual(
            UpgradeSpaceCheck.tmpVerdict(imageSize: image, space: .init(tmpFreeBytes: image - 1, overlayFreeBytes: nil)),
            .insufficient(freeBytes: image - 1, requiredBytes: image))
        XCTAssertEqual(
            UpgradeSpaceCheck.tmpVerdict(imageSize: image, space: .init(tmpFreeBytes: nil, overlayFreeBytes: 0)),
            .unknown)
    }

    func testByteSizeFormatter() {
        XCTAssertEqual(ByteSizeFormatter.string(512), "512 B")
        XCTAssertEqual(ByteSizeFormatter.string(2048), "2.0 KB")
        XCTAssertEqual(ByteSizeFormatter.string(12 * 1024 * 1024), "12.0 MB")
    }

    // MARK: Streaming write (FileClient)

    func testChunkedWriteReassemblesOddSizedChunks() async throws {
        let caller = StreamFakeCaller()
        let files = FileClient(caller: caller)
        let original = Data((0..<70_000).map { UInt8($0 % 251) })
        // Deliberately awkward chunk sizes: not multiples of 3, not
        // aligned to the writer's internal block size.
        let chunks = [original.subdata(in: 0..<1_000), original.subdata(in: 1_000..<1_007),
                      original.subdata(in: 1_007..<51_007), original.subdata(in: 51_007..<70_000)]
        var index = 0
        let total = try await files.writeChunkedVerified(path: "/tmp/firmware-image.bin") {
            defer { index += 1 }
            return index < chunks.count ? chunks[index] : nil
        }
        XCTAssertEqual(total, Int64(original.count))
        XCTAssertEqual(caller.binaryStorage["/tmp/firmware-image.bin"], original)
        let writes = caller.calls.filter { $0 == "write" }
        XCTAssertGreaterThan(writes.count, 1)
    }

    func testChunkedWriteFailureRemovesPartialFile() async throws {
        let caller = StreamFakeCaller()
        let files = FileClient(caller: caller)
        var calls = 0
        do {
            _ = try await files.writeChunkedVerified(path: "/tmp/firmware-image.bin") {
                calls += 1
                if calls > 2 { throw OpenWrtKitError.transport("boom") }
                return Data(repeating: 0xAB, count: 30_000)
            }
            XCTFail("Expected mid-stream failure")
        } catch let error as OpenWrtKitError {
            XCTAssertEqual(error, .transport("boom"))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(caller.binaryStorage["/tmp/firmware-image.bin"])
        XCTAssertTrue(caller.calls.contains("remove"))
    }

    func testChunkedWriteSizeMismatchRemovesAndThrows() async throws {
        let caller = StreamFakeCaller()
        caller.statSizeLie = 42
        let files = FileClient(caller: caller)
        var sent = false
        do {
            _ = try await files.writeChunkedVerified(path: "/tmp/firmware-image.bin") {
                if sent { return nil }
                sent = true
                return Data(repeating: 1, count: 100)
            }
            XCTFail("Expected size verification failure")
        } catch let error as TransactionError {
            XCTAssertEqual(error, .verificationFailed("/tmp/firmware-image.bin"))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(caller.binaryStorage["/tmp/firmware-image.bin"])
    }

    func testChunkedWriteEmptyStreamCreatesEmptyFile() async throws {
        let caller = StreamFakeCaller()
        let files = FileClient(caller: caller)
        let total = try await files.writeChunkedVerified(path: "/tmp/empty.bin") { nil }
        XCTAssertEqual(total, 0)
        XCTAssertEqual(caller.binaryStorage["/tmp/empty.bin"], Data())
    }

    // MARK: Streaming prepare (UpgradeFlow)

    func testStreamingPrepareOrderAndDigest() async throws {
        let recorder = ClosureUpgradeRecorder()
        recorder.spaceSequence = [
            .init(tmpFreeBytes: Int64(500 * 1024 * 1024), overlayFreeBytes: Int64(50 * 1024 * 1024)),
            .init(tmpFreeBytes: Int64(480 * 1024 * 1024), overlayFreeBytes: Int64(50 * 1024 * 1024))
        ]
        let image = Data((0..<150_000).map { UInt8($0 % 253) })
        recorder.remoteDigest = SHA256Hasher.hexDigest(image)
        var steps: [UpgradeFlow.Step] = []
        let prepared = try await UpgradeFlow.prepare(
            source: .inMemory(image, chunkSize: 1_000),
            operations: recorder.operations(), onStep: { steps.append($0) })
        XCTAssertEqual(prepared.imageSHA256, SHA256Hasher.hexDigest(image))
        XCTAssertFalse(prepared.expectedHashVerified)
        XCTAssertEqual(prepared.space.tmpFreeBytes, Int64(480 * 1024 * 1024))
        XCTAssertEqual(recorder.stagedBytes, Int64(image.count))
        XCTAssertEqual(steps, [.spacePrecheck, .backup, .spacePrecheck, .staging,
                               .hashVerification, .imageValidation, .awaitingSecondConfirmation])
    }

    func testPrepareBlocksBeforeBackupWhenTmpTooSmall() async throws {
        let recorder = ClosureUpgradeRecorder()
        recorder.spaceSequence = [.init(tmpFreeBytes: 1_000, overlayFreeBytes: nil)]
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data(repeating: 7, count: 5_000)),
                operations: recorder.operations())
            XCTFail("Expected space refusal")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("可用空间不足"), message)
            XCTAssertTrue(message.contains("还差"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(recorder.backupCreated)
        XCTAssertFalse(recorder.staged)
    }

    func testPrepareBlocksWhenSpaceUnreadable() async throws {
        let recorder = ClosureUpgradeRecorder()
        recorder.spaceSequence = [.init(tmpFreeBytes: nil, overlayFreeBytes: nil)]
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data(repeating: 7, count: 5_000)),
                operations: recorder.operations())
            XCTFail("Expected unknown-space refusal")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("无法读取"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(recorder.backupCreated)
    }

    func testPrepareBlocksAfterBackupWhenSpaceShrinks() async throws {
        let recorder = ClosureUpgradeRecorder()
        recorder.spaceSequence = [
            .init(tmpFreeBytes: Int64(10 * 1024 * 1024), overlayFreeBytes: nil),
            .init(tmpFreeBytes: 100, overlayFreeBytes: nil)
        ]
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data(repeating: 7, count: 5_000)),
                operations: recorder.operations())
            XCTFail("Expected post-backup space refusal")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("备份已生成"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(recorder.backupCreated)
        XCTAssertFalse(recorder.staged)
    }

    func testPrepareExpectedHashMatchAndMismatch() async throws {
        let image = Data("official-image".utf8)
        let digest = SHA256Hasher.hexDigest(image)

        let okRecorder = ClosureUpgradeRecorder()
        okRecorder.remoteDigest = digest
        let prepared = try await UpgradeFlow.prepare(
            source: .inMemory(image), expectedSHA256: digest.uppercased(),
            operations: okRecorder.operations())
        XCTAssertTrue(prepared.expectedHashVerified)

        let badRecorder = ClosureUpgradeRecorder()
        badRecorder.remoteDigest = digest
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(image), expectedSHA256: String(repeating: "a", count: 64),
                operations: badRecorder.operations())
            XCTFail("Expected expected-hash refusal")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("与提供的 SHA-256 不一致"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(badRecorder.validated)
    }

    func testPrepareMalformedExpectedHashFailsBeforeTouchingRouter() async throws {
        let recorder = ClosureUpgradeRecorder()
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data("x".utf8)), expectedSHA256: "not-a-hash",
                operations: recorder.operations())
            XCTFail("Expected format refusal")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("64 位十六进制"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(recorder.spaceCalls, 0)
        XCTAssertFalse(recorder.backupCreated)
    }

    func testPrepareStagingFailureCleansPartialImage() async throws {
        let recorder = ClosureUpgradeRecorder()
        recorder.stageError = OpenWrtKitError.transport("connection dropped")
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data(repeating: 3, count: 2_000)),
                operations: recorder.operations())
            XCTFail("Expected staging failure")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertTrue(message.contains("残缺镜像"), message)
        } catch { XCTFail("Unexpected error: \(error)") }
        // The default staging path is the one the firmware's exec
        // keys authorize (package L, permission audit #6/#8/#9).
        XCTAssertEqual(recorder.removedPaths, ["/tmp/firmware.bin"])
        XCTAssertFalse(recorder.validated)
    }
}

/// In-memory file plane for the streaming-write tests.
private final class StreamFakeCaller: UbusCalling, @unchecked Sendable {
    private let lock = NSLock()
    var binaryStorage: [String: Data] = [:]
    var statSizeLie: Int64?
    private var recorded: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        lock.lock(); recorded.append(method); lock.unlock()
        let path = parameters["path"]?.stringValue ?? ""
        switch method {
        case "write":
            let chunk = Data(base64Encoded: parameters["data"]?.stringValue ?? "") ?? Data()
            if parameters["append"]?.boolValue == true {
                binaryStorage[path, default: Data()].append(chunk)
            } else {
                binaryStorage[path] = chunk
            }
            return .object([:])
        case "stat":
            let size = statSizeLie ?? Int64(binaryStorage[path]?.count ?? 0)
            return .object(["type": .string("file"), "size": .number(Double(size))])
        case "remove":
            binaryStorage[path] = nil
            return .object([:])
        default:
            return .object([:])
        }
    }

    func menu() async throws -> JSONValue { .object([:]) }
    func installedPackages() async throws -> [InstalledPackage] { [] }
}

/// Scripted operations for the streaming prepare tests.
private final class ClosureUpgradeRecorder: @unchecked Sendable {
    var spaceSequence: [RouterStorageSpace] = [
        .init(tmpFreeBytes: Int64(1024 * 1024 * 1024), overlayFreeBytes: Int64(1024 * 1024))
    ]
    var spaceCalls = 0
    var backupCreated = false
    var staged = false
    var stagedBytes: Int64 = 0
    var validated = false
    var removedPaths: [String] = []
    var remoteDigest: String?
    var stageError: Error?

    func operations() -> UpgradeFlow.Operations {
        UpgradeFlow.Operations(
            createBackup: { self.backupCreated = true; return "/tmp/zirox-backup.tar.gz" },
            stageImage: { _, _ in },
            remoteSHA256: { _ in self.remoteDigest ?? String(repeating: "0", count: 64) },
            validateImage: { _ in self.validated = true; return true },
            runUpgrade: { _ in },
            probeReconnect: { true },
            routerSpace: {
                self.spaceCalls += 1
                return self.spaceSequence.isEmpty
                    ? RouterStorageSpace(tmpFreeBytes: nil, overlayFreeBytes: nil)
                    : self.spaceSequence.removeFirst()
            },
            removeFile: { path in self.removedPaths.append(path) },
            stageImageStream: { reader, _, onProgress in
                if let error = self.stageError { throw error }
                var hasher = SHA256Hasher()
                var sent: Int64 = 0
                while let chunk = try await reader.nextChunk() {
                    hasher.update(chunk)
                    sent += Int64(chunk.count)
                    onProgress(sent)
                }
                self.staged = true
                self.stagedBytes = sent
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            })
    }
}
