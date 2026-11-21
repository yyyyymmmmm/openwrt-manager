import XCTest
@testable import OpenWrtKit

/// Package J (audit F4/F5/F6/F7): password-change channel support,
/// UPnP mapping parsing, authorized-keys handling, package-name
/// validation, package-action reply parsing, the custom-commands
/// discovery exclusion, and the administration page's registry kind.
final class AdminOperationsTests: XCTestCase {

    // MARK: Package name validation (F7)

    func testPackageNameValidationAcceptsRealNames() {
        for name in ["luci-app-upnp", "miniupnpd", "kmod-nft-core", "libopenssl3",
                     "python3-base", "zoneinfo-europe", "wpad-basic-mbedtls", "a.b+c_d"] {
            XCTAssertTrue(PackageNameValidator.isValid(name), name)
        }
    }

    func testPackageNameValidationRejectsInjectionShapes() {
        for name in ["", " ", "-rf", "--force-overwrite", "pkg name", "pkg;rm", "pkg|cat",
                     "pkg$(id)", "pkg`id`", "pkg/name", "中文包", String(repeating: "a", count: 129)] {
            XCTAssertFalse(PackageNameValidator.isValid(name), name)
        }
    }

    func testPackageActionClientRejectsBadNameBeforeCalling() async {
        let caller = RecordingCaller()
        let client = PackageActionClient(caller: caller)
        do {
            _ = try await client.run(action: .install, packages: ["ok-pkg", "bad;name"])
            XCTFail("invalid name must fail the whole request")
        } catch {
            // expected: validation error, router never contacted
        }
        let calls = await caller.packageCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPackageActionClientPassesValidatedNamesThrough() async throws {
        let caller = RecordingCaller()
        let client = PackageActionClient(caller: caller)
        let outcome = try await client.run(action: .remove, packages: [" miniupnpd "])
        XCTAssertTrue(outcome.succeeded)
        let calls = await caller.packageCalls
        XCTAssertEqual(calls.first?.action, .remove)
        XCTAssertEqual(calls.first?.packages, ["miniupnpd"])
    }

    // MARK: Package action reply parsing (F7)

    func testPackageActionOutcomeParsing() throws {
        let value: JSONValue = .object([
            "code": .number(0), "pkmcmd": .string("opkg install nano"),
            "stdout": .string("Installing nano"), "stderr": .string("")
        ])
        let outcome = try PackageActionParser.outcome(value)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.commandLine, "opkg install nano")
        XCTAssertEqual(outcome.stdout, "Installing nano")
    }

    func testPackageActionOutcomeFailureAndMalformed() throws {
        let failed = try PackageActionParser.outcome(.object([
            "code": .number(255), "stderr": .string("Failed to acquire lock")
        ]))
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.stderr, "Failed to acquire lock")
        XCTAssertThrowsError(try PackageActionParser.outcome(.object(["stdout": .string("x")])))
    }

    func testUpgradableNameExtractorBothManagers() {
        let installed = ["nano", "nano-plus", "luci-app-upnp"]
        XCTAssertEqual(UpgradableNameExtractor.packageName(
            inLine: "nano - 7.2-1 - 8.0-1", installed: installed), "nano")
        XCTAssertEqual(UpgradableNameExtractor.packageName(
            inLine: "nano-plus-8.0-r1 x86_64 [upgradable from: nano-plus-7.2-r1]", installed: installed), "nano-plus")
        XCTAssertNil(UpgradableNameExtractor.packageName(
            inLine: "unknown - 1 - 2", installed: installed))
    }

    // MARK: UPnP mappings (F5)

    func testUPnPParserEmptyRules() {
        // Measured live on the bypass router 2026-11-21 (UPnP
        // disabled there): get_status answers an empty rules array.
        XCTAssertTrue(UPnPParser.mappings(.object(["rules": .array([])])).isEmpty)
        XCTAssertTrue(UPnPParser.mappings(.object([:])).isEmpty)
    }

    func testUPnPParserFullRule() {
        let value: JSONValue = .object(["rules": .array([.object([
            "token": .string("abc123"), "extport": .number(8080), "proto": .string("TCP"),
            "intaddr": .string("192.168.31.50"), "intport": .number(80),
            "descr": .string("Webcam")
        ])])])
        let mappings = UPnPParser.mappings(value)
        XCTAssertEqual(mappings.count, 1)
        let rule = mappings[0]
        XCTAssertEqual(rule.token, "abc123")
        XCTAssertEqual(rule.externalPort, 8080)
        XCTAssertEqual(rule.protocolName, "TCP")
        XCTAssertEqual(rule.internalAddress, "192.168.31.50")
        XCTAssertEqual(rule.internalPort, 80)
        XCTAssertEqual(rule.mappingDescription, "Webcam")
        XCTAssertEqual(rule.id, "abc123")
    }

    func testUPnPParserVariantSpellingsAndRawFieldsSurvive() {
        let value: JSONValue = .object(["rules": .array([.object([
            "external_port": .string("9000"), "protocol": .string("UDP"),
            "internal_addr": .string("192.168.31.9"), "internal_port": .string("9001"),
            "expires": .string("3600")
        ])])])
        let rule = UPnPParser.mappings(value)[0]
        XCTAssertEqual(rule.externalPort, 9000)
        XCTAssertEqual(rule.internalPort, 9001)
        XCTAssertEqual(rule.protocolName, "UDP")
        // Unknown-but-present fields stay available for the raw layer.
        XCTAssertEqual(rule.fields["expires"], "3600")
    }

    // MARK: Authorized keys (F4)

    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRk0rFakeBase64Body0123456789 laptop"
    private let keyB = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQFakeRsaBody0123456789abcdef"

    func testAuthorizedKeysParseSerializeRoundTrip() {
        let text = "\n\(keyA)\n\n# a comment line\n\(keyB)\n"
        let keys = AuthorizedKeys.parse(text)
        XCTAssertEqual(keys, [keyA, keyB])
        XCTAssertEqual(AuthorizedKeys.parse(AuthorizedKeys.serialize(keys)), keys)
        XCTAssertEqual(AuthorizedKeys.serialize([]), "")
    }

    func testAuthorizedKeysValidation() {
        XCTAssertTrue(AuthorizedKeys.isValidKeyLine(keyA))
        XCTAssertTrue(AuthorizedKeys.isValidKeyLine(keyB))
        // Options-led line (restrict,port-forwarding style) still counts.
        XCTAssertTrue(AuthorizedKeys.isValidKeyLine("restrict \(keyA)"))
        XCTAssertFalse(AuthorizedKeys.isValidKeyLine("not-a-key"))
        XCTAssertFalse(AuthorizedKeys.isValidKeyLine("ssh-ed25519 short"))
        XCTAssertFalse(AuthorizedKeys.isValidKeyLine("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI!!!"))
        XCTAssertFalse(AuthorizedKeys.isValidKeyLine(""))
    }

    func testAuthorizedKeysDisplayName() {
        XCTAssertEqual(AuthorizedKeys.displayName(for: keyA), "ssh-ed25519 · laptop")
        XCTAssertTrue(AuthorizedKeys.displayName(for: keyB).hasPrefix("ssh-rsa · …"))
    }

    // MARK: Custom commands exclusion (F6)

    func testCustomCommandsNeverDisplayable() {
        for path in ["admin/system/commands", "admin/system/commands/config",
                     "admin/system/commands/dashboard", "admin/system/commands/run/x",
                     "admin/system/commands/download/x"] {
            XCTAssertFalse(DiscoveryRules.isDisplayablePath(path), path)
        }
        // Neighbours stay displayable.
        XCTAssertTrue(DiscoveryRules.isDisplayablePath("admin/system/startup"))
        XCTAssertTrue(DiscoveryRules.isDisplayablePath("admin/system/admin"))
    }

    func testBypassSystemPagesHaveAdminSecurityAndNoCommands() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/snapshot-192.168.31.167-2026-11-20.json")
        let collected = try JSONDecoder().decode(CollectedRouterSnapshot.self, from: Data(contentsOf: url))
        let tabs = PageRegistry.tabs(for: CapabilitySnapshot(collected: collected))
        let system = tabs.first { $0.tab == .system }?.pages ?? []
        XCTAssertTrue(system.contains { $0.kind == .adminSecurity && $0.menuPath == "admin/system/admin" })
        XCTAssertFalse(system.contains { ($0.menuPath ?? "").hasPrefix("admin/system/commands") })
    }
}

/// Minimal UbusCalling double: records package actions, answers a
/// canned success, and refuses everything else.
private actor RecordingCaller: UbusCalling {
    struct PackageCall: Equatable {
        let action: PackageActionKind
        let packages: [String]
    }

    private(set) var packageCalls: [PackageCall] = []

    func packageManagerAction(action: PackageActionKind, packages: [String]) async throws -> PackageActionOutcome {
        packageCalls.append(PackageCall(action: action, packages: packages))
        return PackageActionOutcome(code: 0, commandLine: "opkg \(action.rawValue)", stdout: "", stderr: "")
    }

    func call(object: String, method: String, parameters: [String: JSONValue]) async throws -> JSONValue {
        throw OpenWrtKitError.unsupported("recording caller")
    }

    func menu() async throws -> JSONValue { throw OpenWrtKitError.unsupported("recording caller") }
    func installedPackages() async throws -> [InstalledPackage] { [] }
}
