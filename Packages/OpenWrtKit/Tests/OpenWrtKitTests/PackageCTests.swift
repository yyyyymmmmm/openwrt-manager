import XCTest
@testable import OpenWrtKit

/// Package C: SSH host-key trust (first use / match / changed),
/// configuration backup & restore (manifest diff, staged restore
/// with structural confirmation), the multi-source device roster
/// and its block planners, and event kinds for the records surface.
final class PackageCTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Host key fingerprint form

    func testFingerprintDisplayFormMatchesOpenSSHConvention() {
        // SHA-256 of the empty input, the canonical test vector.
        let hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(HostKeyFingerprint.displayForm(hexDigest: hex),
                       "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        // Uppercase hex and padding rules: same digest, same display.
        XCTAssertEqual(HostKeyFingerprint.displayForm(hexDigest: hex.uppercased()),
                       "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        // Not a digest: passed through untouched rather than mangled.
        XCTAssertEqual(HostKeyFingerprint.displayForm(hexDigest: "abcd"), "abcd")
    }

    // MARK: - Host key trust: the three states

    func testTrustFirstUseThenMatchThenChanged() {
        var store = HostKeyTrustStore()
        let keyA = String(repeating: "a", count: 64)
        let keyB = String(repeating: "b", count: 64)

        // No record: first use, and evaluating must not create trust.
        XCTAssertEqual(store.evaluate(host: "192.168.31.1", port: 22, presentedFingerprint: keyA),
                       .firstUse(presented: keyA))
        XCTAssertTrue(store.records.isEmpty)

        store.trust(host: "192.168.31.1", port: 22, fingerprint: keyA, at: t0)
        // Match is case-insensitive on the presented side.
        XCTAssertEqual(store.evaluate(host: "192.168.31.1", port: 22,
                                      presentedFingerprint: keyA.uppercased()), .match)
        // A different key is a change: trusted and presented both named.
        XCTAssertEqual(store.evaluate(host: "192.168.31.1", port: 22, presentedFingerprint: keyB),
                       .changed(trusted: keyA, presented: keyB))
        // The host scope is normalized; a different port is a
        // different endpoint with no trust.
        XCTAssertEqual(store.evaluate(host: " 192.168.31.1 ", port: 22, presentedFingerprint: keyA), .match)
        XCTAssertEqual(store.evaluate(host: "192.168.31.1", port: 2222, presentedFingerprint: keyA),
                       .firstUse(presented: keyA))
    }

    func testTrustRevokeAndRetustReplace() {
        var store = HostKeyTrustStore()
        let keyA = String(repeating: "a", count: 64)
        let keyB = String(repeating: "b", count: 64)
        store.trust(host: "router.lan", port: 22, fingerprint: keyA, at: t0)
        // Explicit re-trust replaces the record in place.
        store.trust(host: "router.lan", port: 22, fingerprint: keyB, at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.evaluate(host: "router.lan", port: 22, presentedFingerprint: keyB), .match)
        XCTAssertEqual(store.records.first?.trustedAt, t0.addingTimeInterval(60))
        store.revoke(host: "router.lan", port: 22)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.evaluate(host: "router.lan", port: 22, presentedFingerprint: keyB),
                       .firstUse(presented: keyB))
    }

    // MARK: - Event kinds

    func testStoredEventKindDefaultsAndLegacyDecoding() throws {
        let explicit = StoredEvent(at: t0, category: .operation, kind: .backupRestore,
                                   title: "t", detail: "d")
        XCTAssertEqual(explicit.kind, .backupRestore)
        let derived = StoredEvent(at: t0, category: .alert, title: "t", detail: "d")
        XCTAssertEqual(derived.kind, .alert)

        // A pre-kind event payload (no "kind" key) must still decode,
        // with the kind derived from its category.
        let legacy = #"{"id":"x","at":0,"category":"operation","title":"旧","detail":"d"}"#
        let decoded = try JSONDecoder().decode(StoredEvent.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.kind, .operation)

        var log = EventLog()
        log.append(StoredEvent(at: t0, category: .operation, kind: .login, title: "登录", detail: ""))
        log.append(StoredEvent(at: t0, category: .operation, kind: .configuration, title: "改配置", detail: ""))
        log.append(StoredEvent(at: t0, category: .alert, title: "告警", detail: ""))
        XCTAssertEqual(log.recent(kind: .configuration).map(\.title), ["改配置"])
        XCTAssertEqual(log.recent().count, 3)
    }

    // MARK: - Backup naming, manifest, diff

    func testBackupFileNaming() {
        let name = BackupFileNaming.fileName(routerName: "家里 主路由!", at: t0)
        XCTAssertTrue(name.hasPrefix("zirox-backup-"), name)
        XCTAssertTrue(name.hasSuffix(".tar.gz"), name)
        XCTAssertFalse(name.contains(" "), name)
        XCTAssertFalse(name.contains("!"), name)
        XCTAssertEqual(BackupFileNaming.fileName(routerName: "!!!", at: t0),
                       BackupFileNaming.fileName(routerName: "router", at: t0))
        XCTAssertEqual(BackupFileNaming.stagingPath(fileName: "a.tar.gz"), "/tmp/a.tar.gz")
    }

    func testBackupDiffAgainstCurrentInventory() {
        let manifest = BackupManifest(
            createdAt: t0, routerName: "r", address: "http://192.168.31.1",
            sha256: "x", byteCount: 10,
            configs: [.init(name: "network", sectionCount: 5),
                      .init(name: "wireless", sectionCount: 3),
                      .init(name: "luci", sectionCount: 1)])
        let diff = BackupDiff.diff(manifest: manifest, currentConfigNames: ["network", "firewall", "wireless"])
        XCTAssertEqual(diff.onlyInBackup, ["luci"])
        XCTAssertEqual(diff.inBoth, ["network", "wireless"])
        XCTAssertEqual(diff.onlyInCurrent, ["firewall"])
        XCTAssertEqual(manifest.totalSections, 9)
    }

    // MARK: - Restore flow

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []
        func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    }

    private func restoreOperations(recorder: CallRecorder,
                                   remoteDigest: String? = nil,
                                   snapshotData: Data = Data(),
                                   probeAnswers: [Bool] = [true]) -> BackupRestoreFlow.Operations {
        var probes = probeAnswers
        return BackupRestoreFlow.Operations(
            createBackupOnRouter: { recorder.record("snapshot"); return "/tmp/pre.tar.gz" },
            downloadFile: { _ in snapshotData },
            uploadFile: { _, path in recorder.record("upload:\(path)") },
            remoteSHA256: { _ in recorder.record("sha"); return remoteDigest ?? "" },
            restoreBackup: { _ in recorder.record("restore") },
            reboot: { recorder.record("reboot") },
            probeReconnect: { recorder.record("probe"); return probes.isEmpty ? false : probes.removeFirst() },
            probeDelay: {})
    }

    func testRestoreRefusesWithoutConfirmation() async {
        let recorder = CallRecorder()
        let operations = restoreOperations(recorder: recorder)
        do {
            _ = try await BackupRestoreFlow.restore(
                backupData: Data("abc".utf8), fileName: "b.tar.gz",
                confirmed: false, operations: operations)
            XCTFail("restore without confirmation must refuse")
        } catch {
            XCTAssertEqual(error as? OpenWrtKitError, .permissionDenied)
        }
        XCTAssertTrue(recorder.calls.isEmpty, "no operation may run before confirmation: \(recorder.calls)")
    }

    func testRestoreHappyPathOrderAndResult() async throws {
        let recorder = CallRecorder()
        let data = Data("abc".utf8)
        // SHA-256("abc"), the standard vector.
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let operations = restoreOperations(recorder: recorder, remoteDigest: digest,
                                           snapshotData: Data("pre".utf8),
                                           probeAnswers: [false, true])
        let result = try await BackupRestoreFlow.restore(
            backupData: data, fileName: "b.tar.gz", confirmed: true, operations: operations)
        XCTAssertTrue(result.reconnected)
        XCTAssertEqual(result.preRestoreSnapshotPath, "/tmp/pre.tar.gz")
        // The snapshot's bytes travel with the result: the on-router
        // copy is in tmpfs and dies with the restore's own reboot.
        XCTAssertEqual(result.preRestoreSnapshotData, Data("pre".utf8))
        // Snapshot strictly before upload; restore strictly after the
        // hash check; reboot last before probing. The payload stages
        // at the one path the restore exec key authorizes, whatever
        // the library file is called (package L, permission audit #4).
        XCTAssertEqual(recorder.calls,
                       ["snapshot", "upload:/tmp/backup.tar.gz", "sha", "restore", "reboot", "probe", "probe"])
    }

    func testRestoreAbortsOnHashMismatchBeforeRestore() async {
        let recorder = CallRecorder()
        let operations = restoreOperations(recorder: recorder, remoteDigest: String(repeating: "0", count: 64))
        do {
            _ = try await BackupRestoreFlow.restore(
                backupData: Data("abc".utf8), fileName: "b.tar.gz",
                confirmed: true, operations: operations)
            XCTFail("hash mismatch must abort")
        } catch {
            XCTAssertEqual(error as? TransactionError, .verificationFailed("/tmp/backup.tar.gz"))
        }
        XCTAssertFalse(recorder.calls.contains("restore"))
        XCTAssertFalse(recorder.calls.contains("reboot"))
    }

    func testRestoreReportsUnreconnected() async throws {
        let recorder = CallRecorder()
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let operations = restoreOperations(recorder: recorder, remoteDigest: digest, probeAnswers: [false])
        let result = try await BackupRestoreFlow.restore(
            backupData: Data("abc".utf8), fileName: "b.tar.gz", confirmed: true,
            operations: operations, reconnectAttempts: 2)
        XCTAssertFalse(result.reconnected)
        XCTAssertEqual(result.preRestoreSnapshotPath, "/tmp/pre.tar.gz")
    }

    func testCreateBackupDigestsDownloadedBytes() async throws {
        let operations = BackupRestoreFlow.Operations(
            createBackupOnRouter: { "/tmp/zirox-backup.tar.gz" },
            downloadFile: { _ in Data("abc".utf8) },
            uploadFile: { _, _ in },
            remoteSHA256: { _ in "" },
            restoreBackup: { _ in },
            reboot: {},
            probeReconnect: { false })
        let created = try await BackupRestoreFlow.createBackup(operations: operations)
        XCTAssertEqual(created.data, Data("abc".utf8))
        XCTAssertEqual(created.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Device roster

    func testNormalizeMAC() {
        XCTAssertEqual(DeviceRoster.normalizeMAC("aa-bb-cc-dd-ee-ff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(DeviceRoster.normalizeMAC("aabbccddeeff"), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(DeviceRoster.normalizeMAC("AA:BB:CC:DD:EE:FF"), "AA:BB:CC:DD:EE:FF")
        XCTAssertNil(DeviceRoster.normalizeMAC("AA:BB:CC"))
        XCTAssertNil(DeviceRoster.normalizeMAC("zz:bb:cc:dd:ee:ff"))
    }

    func testRosterMergesSameDeviceAcrossSources() {
        let leases = [DHCPLease(hostname: "iphone", address: "192.168.31.120",
                                mac: "aa:bb:cc:dd:ee:ff", expires: 3600)]
        let stations = [WirelessStation(mac: "AA:BB:CC:DD:EE:FF", device: "wlan0",
                                        signal: -52, rxBytes: 100, txBytes: 200)]
        let neighbors = [
            NeighborEntry(address: "192.168.31.120", device: "br-lan",
                          mac: "AA:BB:CC:DD:EE:FF", state: "REACHABLE", isRouter: false),
            NeighborEntry(address: "192.168.31.1", device: "br-lan",
                          mac: "11:22:33:44:55:66", state: "REACHABLE", isRouter: true),
            NeighborEntry(address: "fe80::1", device: "br-lan", mac: nil, state: "STALE", isRouter: false),
        ]
        let roster = DeviceRoster.merge(leases: leases, neighbors: neighbors, stations: stations)
        XCTAssertEqual(roster.count, 3)
        let phone = roster.first { $0.mac == "AA:BB:CC:DD:EE:FF" }
        XCTAssertNotNil(phone)
        XCTAssertEqual(phone?.sources, [.lease, .neighbor, .station])
        XCTAssertEqual(phone?.hostname, "iphone")
        XCTAssertEqual(phone?.connection, .wireless)
        XCTAssertEqual(phone?.signal, -52)
        XCTAssertEqual(phone?.leaseExpiresIn, 3600)
        XCTAssertEqual(phone?.addresses, ["192.168.31.120"])
        XCTAssertEqual(phone?.rxBytes, 100)
        let router = roster.first { $0.mac == "11:22:33:44:55:66" }
        XCTAssertEqual(router?.connection, .wired)
        XCTAssertEqual(router?.isRouter, true)
        // The MAC-less neighbor stays its own visibly unmerged row.
        let orphan = roster.first { $0.id == "ip:fe80::1" }
        XCTAssertNotNil(orphan)
        XCTAssertNil(orphan?.mac)
    }

    func testStationParser() {
        let value: JSONValue = .object(["results": .array([
            .object(["mac": .string("aa:bb:cc:dd:ee:ff"), "signal": .number(-52),
                     "noise": .number(-95),
                     "rx": .object(["bytes": .number(1234)]),
                     "tx": .object(["bytes": .number(5678)])]),
            .object(["signal": .number(-1)]), // no MAC: skipped
        ])])
        let stations = StationParser.assoclist(value, device: "wlan0")
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(stations.first?.signal, -52)
        XCTAssertEqual(stations.first?.rxBytes, 1234)
        XCTAssertEqual(stations.first?.txBytes, 5678)
    }

    // MARK: - Device blocking planners

    private func wirelessConfig(macfilter: String?, maclist: JSONValue?) -> RouterConfiguration {
        var values: [String: JSONValue] = ["ssid": .string("home")]
        if let macfilter { values["macfilter"] = .string(macfilter) }
        if let maclist { values["maclist"] = maclist }
        return RouterConfiguration(name: "wireless", sections: [
            ConfigurationSection(id: "radio0", type: "wifi-device"),
            ConfigurationSection(id: "iface0", type: "wifi-iface", values: values),
        ])
    }

    func testWirelessBlockDenyMode() throws {
        let mac = "AA:BB:CC:DD:EE:FF"
        let original = wirelessConfig(macfilter: nil, maclist: nil)
        XCTAssertFalse(DeviceBlock.isWirelessBlocked(mac: mac, wireless: original))
        let blocked = try XCTUnwrap(DeviceBlock.wirelessPlan(mac: mac, block: true, original: original))
        XCTAssertEqual(blocked.sections[1].values["macfilter"], .string("deny"))
        XCTAssertEqual(blocked.sections[1].values["maclist"], .string(mac))
        XCTAssertTrue(DeviceBlock.isWirelessBlocked(mac: mac, wireless: blocked))
        // Already blocked: no further plan.
        XCTAssertNil(DeviceBlock.wirelessPlan(mac: mac, block: true, original: blocked))
        // Unblock is the exact inverse and restores the empty state.
        let unblocked = try XCTUnwrap(DeviceBlock.wirelessPlan(mac: mac, block: false, original: blocked))
        XCTAssertNil(unblocked.sections[1].values["maclist"])
        XCTAssertFalse(DeviceBlock.isWirelessBlocked(mac: mac, wireless: unblocked))
        XCTAssertNil(DeviceBlock.wirelessPlan(mac: mac, block: false, original: original))
    }

    func testWirelessBlockAllowModeRemovesFromList() throws {
        let mac = "AA:BB:CC:DD:EE:FF"
        let original = wirelessConfig(macfilter: "allow",
                                      maclist: .array([.string(mac), .string("11:22:33:44:55:66")]))
        XCTAssertFalse(DeviceBlock.isWirelessBlocked(mac: mac, wireless: original))
        let blocked = try XCTUnwrap(DeviceBlock.wirelessPlan(mac: mac, block: true, original: original))
        XCTAssertEqual(blocked.sections[1].values["maclist"], .string("11:22:33:44:55:66"))
        XCTAssertTrue(DeviceBlock.isWirelessBlocked(mac: mac, wireless: blocked))
        // Unblock in allow mode re-adds the device to the list.
        let unblocked = try XCTUnwrap(DeviceBlock.wirelessPlan(mac: mac, block: false, original: blocked))
        guard case .array(let values) = unblocked.sections[1].values["maclist"] else {
            return XCTFail("expected a two-entry maclist after unblock")
        }
        XCTAssertEqual(values.compactMap(\.stringValue), ["11:22:33:44:55:66", mac])
    }

    func testWiredBlockRuleLifecycle() throws {
        let mac = "AA:BB:CC:DD:EE:FF"
        let original = RouterConfiguration(name: "firewall", sections: [
            ConfigurationSection(id: "cfg01", type: "defaults"),
        ])
        XCTAssertFalse(DeviceBlock.isWiredBlocked(mac: mac, firewall: original))
        let blocked = try XCTUnwrap(DeviceBlock.wiredPlan(mac: mac, block: true, original: original))
        let rule = try XCTUnwrap(blocked.sections.first { $0.type == "rule" })
        XCTAssertEqual(rule.values["name"], .string("zirox-block-aabbccddeeff"))
        XCTAssertEqual(rule.values["src_mac"], .string(mac))
        XCTAssertEqual(rule.values["target"], .string("DROP"))
        XCTAssertTrue(DeviceBlock.isWiredBlocked(mac: mac, firewall: blocked))
        XCTAssertNil(DeviceBlock.wiredPlan(mac: mac, block: true, original: blocked))
        let unblocked = try XCTUnwrap(DeviceBlock.wiredPlan(mac: mac, block: false, original: blocked))
        XCTAssertTrue(unblocked.sections.allSatisfy { $0.type != "rule" })
        XCTAssertNil(DeviceBlock.wiredPlan(mac: mac, block: false, original: original))
    }
}
