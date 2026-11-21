import XCTest
@testable import OpenWrtKit

/// Package L (permission audit batches 1+2): every "permission
/// denied" that had an authorized alternative channel now takes it.
/// Fixtures marked "measured" are verbatim shapes read off the two
/// household routers on 2026-11-21 (read-only).
final class PackageLTests: XCTestCase {

    // MARK: - Scripted caller

    private final class LCaller: UbusCalling, @unchecked Sendable {
        struct Recorded: Equatable {
            var object: String
            var method: String
        }
        private(set) var calls: [Recorded] = []
        private(set) var execCommands: [String] = []
        var handler: (String, String, [String: JSONValue]) throws -> JSONValue = { _, _, _ in .object([:]) }
        var backupData = Data()
        var lists: PackageLists?

        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            calls.append(Recorded(object: object, method: method))
            if object == "file", method == "exec", let command = parameters["command"]?.stringValue {
                let args = parameters["params"]?.arrayValue?.map { $0.stringValue ?? "" } ?? []
                execCommands.append(([command] + args).joined(separator: " "))
            }
            return try handler(object, method, parameters)
        }

        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
        func packageLists() async throws -> PackageLists {
            guard let lists else { throw OpenWrtKitError.unsupported("no lists scripted") }
            return lists
        }
        func backupArchive() async throws -> Data { backupData }
    }

    private func rcListHandler(accessGranted: Bool) -> (String, String, [String: JSONValue]) throws -> JSONValue {
        { object, method, _ in
            switch (object, method) {
            case ("rc", "list"):
                return .object(["example": .object(["enabled": .bool(true), "running": .bool(true)])])
            case ("session", "access"):
                return .object(["access": .bool(accessGranted)])
            case ("luci", "setInitAction"):
                return .object(["result": .bool(true)])
            default:
                return .object([:])
            }
        }
    }

    // MARK: #1 Service actions: rc init fallback

    func testServiceActionFallsBackToRcInitWhenSetInitActionNotGranted() async throws {
        // The main router's shape: no acl group grants setInitAction.
        let caller = LCaller()
        caller.handler = rcListHandler(accessGranted: false)
        let reader = RouterReader(caller: caller)
        try await reader.serviceAction(name: "example", action: .restart)
        XCTAssertTrue(caller.calls.contains(.init(object: "rc", method: "init")),
                      "expected an rc init call, got \(caller.calls)")
        XCTAssertFalse(caller.calls.contains(.init(object: "luci", method: "setInitAction")))
    }

    func testServiceActionUsesLuciWhenSetInitActionGranted() async throws {
        // The bypass router's shape: setInitAction is granted.
        let caller = LCaller()
        caller.handler = rcListHandler(accessGranted: true)
        let reader = RouterReader(caller: caller)
        try await reader.serviceAction(name: "example", action: .stop)
        XCTAssertTrue(caller.calls.contains(.init(object: "luci", method: "setInitAction")))
        XCTAssertFalse(caller.calls.contains(.init(object: "rc", method: "init")))
    }

    // MARK: #2 Interface restart: ifdown/ifup exec

    func testRestartInterfaceCyclesThroughIfdownIfup() async throws {
        let caller = LCaller()
        caller.handler = { _, _, _ in .object(["code": .number(0), "stdout": .string("")]) }
        let control = SystemControlClient(caller: caller)
        try await control.restartInterface(name: "wan")
        XCTAssertEqual(caller.execCommands, ["/sbin/ifdown wan", "/sbin/ifup wan"])
    }

    func testRestartInterfaceIfupFailureThrows() async throws {
        let caller = LCaller()
        caller.handler = { _, _, parameters in
            let code = parameters["command"]?.stringValue == "/sbin/ifup" ? 1 : 0
            return .object(["code": .number(Double(code)), "stdout": .string("")])
        }
        let control = SystemControlClient(caller: caller)
        do {
            try await control.restartInterface(name: "wan")
            XCTFail("a failed ifup must surface")
        } catch let error as OpenWrtKitError {
            guard case .unsupported(let message) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(message.contains("ifup"), message)
        }
    }

    // MARK: #14 Records logs: syslog-wrapper fallback

    func testRecordsLogsFallBackToSyslogWrapper() async throws {
        let caller = LCaller()
        caller.handler = { object, method, _ in
            if object == "log" { throw OpenWrtKitError.permissionDenied }
            return .object(["code": .number(0), "stdout": .string("first\nsecond\nthird\n")])
        }
        let reader = RouterReader(caller: caller)
        let records = try await reader.records(.logs)
        XCTAssertEqual(records, [.string("first"), .string("second"), .string("third")])
        XCTAssertEqual(caller.execCommands, ["/usr/libexec/syslog-wrapper"])
    }

    func testRecordsLogsFallbackKeepsNewest200() async throws {
        let caller = LCaller()
        let lines = (1...250).map { "line-\($0)" }.joined(separator: "\n")
        caller.handler = { object, _, _ in
            if object == "log" { throw OpenWrtKitError.permissionDenied }
            return .object(["code": .number(0), "stdout": .string(lines)])
        }
        let reader = RouterReader(caller: caller)
        let records = try await reader.records(.logs)
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records.first, .string("line-51"))
        XCTAssertEqual(records.last, .string("line-250"))
    }

    // MARK: #5 Mount points space (measured shapes, bytes)

    func testMountPointsParserMainRouter() throws {
        // Measured on 192.168.31.1 (OpenWrt 24.10.8): avail values
        // are bytes (120528896 == df's 117704 KiB × 1024 at the time).
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"result":[
          {"device":"/dev/root","mount":"/rom","size":4980736,"avail":0,"free":0},
          {"device":"tmpfs","mount":"/tmp","size":122736640,"avail":120528896,"free":120528896},
          {"device":"/dev/ubi0_1","mount":"/overlay","size":63885312,"avail":54870016,"free":58175488},
          {"device":"overlayfs:/overlay","mount":"/","size":63885312,"avail":54870016,"free":58175488}
        ]}
        """#.utf8))
        let space = MountPointsParser.parse(value)
        XCTAssertEqual(space.tmpFreeBytes, 120_528_896)
        XCTAssertEqual(space.overlayFreeBytes, 54_870_016)
    }

    func testMountPointsParserOverlayFallsBackToRoot() throws {
        // Measured on 192.168.31.167 (OpenWrt 25.12.5): no /overlay
        // entry of its own; the root entry stands in for it.
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"result":[
          {"device":"/dev/root","mount":"/","size":957526016,"avail":345559040,"free":362336256},
          {"device":"tmpfs","mount":"/tmp","size":2060697600,"avail":2048262144,"free":2048262144}
        ]}
        """#.utf8))
        let space = MountPointsParser.parse(value)
        XCTAssertEqual(space.tmpFreeBytes, 2_048_262_144)
        XCTAssertEqual(space.overlayFreeBytes, 345_559_040)
    }

    func testMountPointsParserGarbageYieldsUnknown() {
        let space = MountPointsParser.parse(.object([:]))
        XCTAssertNil(space.tmpFreeBytes)
        XCTAssertNil(space.overlayFreeBytes)
    }

    // MARK: #6/#8/#9 Upgrade defaults + optional remote hash

    private final class UpgradeRecorder: @unchecked Sendable {
        var stagedPath: String?
        var upgradedPath: String?
        var remoteDigest: String?
        var remoteDigestError: Error?

        func operations() -> UpgradeFlow.Operations {
            UpgradeFlow.Operations(
                createBackup: { "/tmp/backup.tar.gz" },
                stageImage: { _, _ in },
                remoteSHA256: { _ in
                    if let error = self.remoteDigestError { throw error }
                    return self.remoteDigest ?? String(repeating: "0", count: 64)
                },
                validateImage: { _ in true },
                runUpgrade: { path in self.upgradedPath = path },
                probeReconnect: { true },
                routerSpace: { RouterStorageSpace(tmpFreeBytes: 1 << 40, overlayFreeBytes: nil) },
                stageImageStream: { reader, path, _ in
                    self.stagedPath = path
                    var hasher = SHA256Hasher()
                    while let chunk = try await reader.nextChunk() { hasher.update(chunk) }
                    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                })
        }
    }

    func testUpgradePrepareStagesAtAuthorizedPathAndVerifiesRemoteHash() async throws {
        let recorder = UpgradeRecorder()
        let image = Data("firmware".utf8)
        recorder.remoteDigest = SHA256Hasher.hexDigest(image)
        let prepared = try await UpgradeFlow.prepare(
            source: .inMemory(image), operations: recorder.operations())
        XCTAssertEqual(recorder.stagedPath, "/tmp/firmware.bin")
        XCTAssertEqual(UpgradeFlow.defaultImagePath, "/tmp/firmware.bin")
        XCTAssertTrue(prepared.remoteHashVerified)
    }

    func testUpgradePrepareSurvivesUnavailableRemoteHash() async throws {
        // rpcd grants no remote hashing to login sessions: the
        // readback being refused must not block the flow — size
        // verification and the sysupgrade test carry the verdict,
        // and the outcome says the hash check did not run.
        let recorder = UpgradeRecorder()
        recorder.remoteDigestError = OpenWrtKitError.permissionDenied
        let prepared = try await UpgradeFlow.prepare(
            source: .inMemory(Data("firmware".utf8)), operations: recorder.operations())
        XCTAssertFalse(prepared.remoteHashVerified)
    }

    func testUpgradePrepareRejectsMismatchedRemoteHash() async throws {
        let recorder = UpgradeRecorder()
        recorder.remoteDigest = String(repeating: "0", count: 64)
        do {
            _ = try await UpgradeFlow.prepare(
                source: .inMemory(Data("firmware".utf8)), operations: recorder.operations())
            XCTFail("a digest the router DID offer and that differs must abort")
        } catch is TransactionError {
            // expected
        }
    }

    func testUpgradeFinishRunsAtAuthorizedPath() async throws {
        let recorder = UpgradeRecorder()
        let reconnected = try await UpgradeFlow.finish(
            secondConfirmation: true, operations: recorder.operations())
        XCTAssertTrue(reconnected)
        XCTAssertEqual(recorder.upgradedPath, "/tmp/firmware.bin")
    }

    // MARK: #3/#4 Backup standard operations (cgi-io + aligned path)

    private final class FilePlaneCaller: UbusCalling, @unchecked Sendable {
        var storage: [String: Data] = [:]
        var execLog: [String] = []
        var backupData = Data()

        func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
            let path = parameters["path"]?.stringValue ?? ""
            switch method {
            case "write":
                let chunk = Data(base64Encoded: parameters["data"]?.stringValue ?? "") ?? Data()
                if parameters["append"]?.boolValue == true {
                    storage[path, default: Data()].append(chunk)
                } else {
                    storage[path] = chunk
                }
                return .object([:])
            case "read":
                return .object(["data": .string((storage[path] ?? Data()).base64EncodedString())])
            case "stat":
                return .object(["type": .string("file"),
                                "size": .number(Double(storage[path]?.count ?? 0))])
            case "exec":
                let command = parameters["command"]?.stringValue ?? ""
                let args = parameters["params"]?.arrayValue?.map { $0.stringValue ?? "" } ?? []
                execLog.append(([command] + args).joined(separator: " "))
                return .object(["code": .number(0), "stdout": .string("")])
            case "getMountPoints":
                return .object(["result": .array([
                    .object(["mount": .string("/tmp"), "avail": .number(1_073_741_824)]),
                    .object(["mount": .string("/"), "avail": .number(536_870_912)])
                ])])
            default:
                return .object([:])
            }
        }

        func menu() async throws -> JSONValue { .object([:]) }
        func installedPackages() async throws -> [InstalledPackage] { [] }
        func backupArchive() async throws -> Data { backupData }
    }

    func testBackupStandardOperationsUseCgiBackupAndAuthorizedPath() async throws {
        let caller = FilePlaneCaller()
        caller.backupData = Data("config-tarball".utf8)
        let files = FileClient(caller: caller)
        let operations = BackupRestoreFlow.standardOperations(files: files)

        let path = try await operations.createBackupOnRouter()
        XCTAssertEqual(path, "/tmp/backup.tar.gz")
        XCTAssertEqual(BackupFileNaming.routerBackupPath, "/tmp/backup.tar.gz")
        XCTAssertEqual(caller.storage["/tmp/backup.tar.gz"], Data("config-tarball".utf8))

        let downloaded = try await operations.downloadFile(path)
        XCTAssertEqual(downloaded, Data("config-tarball".utf8))

        // The upload digest is a readback hash, not the ungranted
        // sha256sum exec.
        let digest = try await operations.remoteSHA256(path)
        XCTAssertEqual(digest, SHA256Hasher.hexDigest(Data("config-tarball".utf8)))
        XCTAssertFalse(caller.execLog.contains { $0.contains("sha256sum") })

        try await operations.restoreBackup(path)
        XCTAssertEqual(caller.execLog, ["/sbin/sysupgrade --restore-backup /tmp/backup.tar.gz"])
    }

    func testUpgradeStandardOperationsUseGrantedChannels() async throws {
        let caller = FilePlaneCaller()
        caller.backupData = Data("config-tarball".utf8)
        let files = FileClient(caller: caller)
        let operations = UpgradeFlow.standardOperations(files: files)

        let backupPath = try await operations.createBackup()
        XCTAssertEqual(backupPath, "/tmp/backup.tar.gz")
        XCTAssertEqual(caller.storage["/tmp/backup.tar.gz"], Data("config-tarball".utf8))

        let space = try await operations.routerSpace()
        XCTAssertEqual(space.tmpFreeBytes, 1 << 30)
        XCTAssertEqual(space.overlayFreeBytes, 1 << 29)
        XCTAssertFalse(caller.execLog.contains { $0.contains("/bin/df") })

        let valid = try await operations.validateImage("/tmp/firmware.bin")
        XCTAssertTrue(valid)
        XCTAssertEqual(caller.execLog, ["/sbin/sysupgrade --test /tmp/firmware.bin"])
    }

    // MARK: #11 Bandwidth download (measured nlbwmon-action output)

    private let nlbwmonSample = #"{"columns":["family","proto","port","mac","ip","conns","rx_bytes","rx_pkts","tx_bytes","tx_pkts","layer7"],"data":[[4,"TCP",443,"d0:11:e5:75:ab:63","192.168.31.121",4924,29352061542,14111031,512589304,10114377,"HTTPS"],[4,"IP",0,"f0:2c:7b:38:67:8b","192.168.31.105",5031,6861236942,3422781,128364554,2055225,null]]}"#

    func testBandwidthDownloadUsesActionHelperAndParses() async throws {
        let caller = LCaller()
        caller.handler = { _, _, _ in
            .object(["code": .number(0), "stdout": .string(self.nlbwmonSample)])
        }
        let client = ReadOnlyDataClient(caller: caller)
        let raw = try await client.bandwidthDownload()
        XCTAssertEqual(caller.execCommands, ["/usr/libexec/nlbwmon-action download -f json"])
        let report = BandwidthParser.parse(raw ?? "")
        XCTAssertEqual(report?.hosts.count, 2)
        XCTAssertEqual(report?.hosts.first?.mac, "D0:11:E5:75:AB:63")
        XCTAssertEqual(report?.hosts.first?.downloadBytes, 29_352_061_542)
        XCTAssertEqual(report?.hosts.first?.uploadBytes, 512_589_304)
        XCTAssertEqual(report?.totalDownload, 29_352_061_542 + 6_861_236_942)
    }

    func testBandwidthDownloadRefusedReadsAsComponentMissing() async throws {
        // The main router's shape: nlbwmon is not installed, so the
        // helper is not granted either — nil, not an error.
        let caller = LCaller()
        caller.handler = { _, _, _ in throw OpenWrtKitError.permissionDenied }
        let client = ReadOnlyDataClient(caller: caller)
        let raw = try await client.bandwidthDownload()
        XCTAssertNil(raw)
    }

    // MARK: Batch 2 — session access precheck

    func testSessionAccessHelper() async throws {
        let caller = LCaller()
        caller.handler = { _, _, parameters in
            .object(["access": .bool(parameters["object"]?.stringValue == "network")])
        }
        let client = ReadOnlyDataClient(caller: caller)
        let granted = await client.sessionAccess(scope: "uci", object: "network", function: "read")
        let denied = await client.sessionAccess(scope: "uci", object: "keepalived", function: "read")
        XCTAssertTrue(granted)
        XCTAssertFalse(denied)

        caller.handler = { _, _, _ in throw OpenWrtKitError.transport("down") }
        let unanswered = await client.sessionAccess(scope: "uci", object: "network", function: "read")
        XCTAssertFalse(unanswered, "an unanswerable check must read as not granted")
    }
}
