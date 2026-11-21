import XCTest
@testable import OpenWrtKit

/// Package N (Face ID repair): the biometric availability model is
/// the one place an LAContext verdict becomes a diagnostic token
/// and a human status line. These tests pin the LAError code
/// mapping — the codes are LocalAuthentication's stable public
/// constants (LAError.Code raw values) — so a future refactor
/// cannot quietly re-label "not enrolled" as "unavailable" and
/// send the next diagnosis back to guessing.
final class PackageNTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KitL10n.appLanguage = nil
    }

    override func tearDown() {
        KitL10n.appLanguage = nil
        super.tearDown()
    }

    func testProbeAvailableCarriesTheBiometryKind() {
        for kind in [BiometryKind.faceID, .touchID, .opticID, .none] {
            XCTAssertEqual(
                BiometricAvailability.probe(canEvaluate: true, errorCode: nil, biometry: kind),
                .available(biometry: kind))
        }
    }

    func testProbeMapsTheSpecificLAErrorCodes() {
        // LAError.biometryNotEnrolled / .biometryNotAvailable /
        // .biometryLockout / .passcodeNotSet.
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: -7, biometry: .faceID), .notEnrolled)
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: -6, biometry: .faceID), .notAvailable)
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: -8, biometry: .faceID), .lockout)
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: -5, biometry: .none), .passcodeNotSet)
    }

    func testProbeKeepsUnknownCodesVerbatim() {
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: -999, biometry: .faceID),
                       .unavailable(code: -999))
        XCTAssertEqual(BiometricAvailability.probe(canEvaluate: false, errorCode: nil, biometry: .faceID),
                       .unavailable(code: 0))
    }

    func testDiagnosticTokensAreStableAndDistinct() {
        let cases: [BiometricAvailability] = [
            .available(biometry: .faceID), .available(biometry: .touchID),
            .available(biometry: .opticID), .available(biometry: .none),
            .notEnrolled, .notAvailable, .lockout, .passcodeNotSet,
            .unavailable(code: -42),
        ]
        let tokens = cases.map(\.diagnosticToken)
        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertEqual(BiometricAvailability.available(biometry: .faceID).diagnosticToken, "available-faceID")
        XCTAssertEqual(BiometricAvailability.notEnrolled.diagnosticToken, "biometry-not-enrolled")
        XCTAssertEqual(BiometricAvailability.unavailable(code: -42).diagnosticToken, "la-error--42")
    }

    func testFailureTokenDistinguishesCancelsFromFailures() {
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -2), "user-cancel")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -4), "system-cancel")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -9), "app-cancel")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -1), "authentication-failed")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -3), "user-fallback")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -8), "biometry-lockout")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -7), "biometry-not-enrolled")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -6), "biometry-not-available")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -5), "passcode-not-set")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -10), "invalid-context")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: -1004), "not-interactive")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: 7), "la-error-7")
        XCTAssertEqual(BiometricAvailability.failureToken(errorCode: nil), "unknown-error")
    }

    func testStatusLinesAreHumanAndDistinctInBothLanguages() {
        let cases: [BiometricAvailability] = [
            .available(biometry: .faceID), .available(biometry: .touchID),
            .available(biometry: .opticID), .available(biometry: .none),
            .notEnrolled, .notAvailable, .lockout, .passcodeNotSet,
            .unavailable(code: -42),
        ]
        let zh = cases.map(\.statusLine)
        XCTAssertTrue(zh.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(zh).count, zh.count)
        XCTAssertEqual(BiometricAvailability.available(biometry: .faceID).statusLine, "Face ID 可用")

        KitL10n.appLanguage = "en"
        let en = cases.map(\.statusLine)
        XCTAssertTrue(en.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(en).count, en.count)
        // Every line must actually translate — an untranslated line
        // would come back as the Chinese source string.
        XCTAssertEqual(BiometricAvailability.available(biometry: .faceID).statusLine, "Face ID is available")
        XCTAssertEqual(BiometricAvailability.lockout.statusLine,
                       "Biometrics are locked; unlock once with your device passcode")
    }
}
