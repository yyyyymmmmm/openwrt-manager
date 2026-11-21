import Foundation
import LocalAuthentication
import OpenWrtKit

// MARK: - Credential gate (package K)
//
// The interaction-layer gate over *using* a saved router password:
// one-tap switching, manual reconnects and terminal sign-ins that
// would spend the Keychain copy first ask the system policy
// `.deviceOwnerAuthentication` (Face ID / Touch ID, device passcode
// as the built-in fallback) — the Termius / 1Password shape the user
// asked for: tap, face, connected; the password form is only for the
// first save, for a refused or unavailable check, and for editing.
//
// The Keychain items themselves deliberately carry NO biometric
// access control (package C ruling, see CredentialStore): background
// sampling reads the remembered password with no user present, and
// an ACL prompt there would break it silently. This gate therefore
// lives purely in the foreground interaction layer — it decides
// whether *this tap* may spend the credential, and background paths
// (Monitoring's sampler, the session manager's silent re-login with
// its in-memory credential box) never come through here.

enum CredentialGate {
    enum Outcome: Equatable {
        /// The user authenticated; the caller may read and spend
        /// the saved credential.
        case authorized
        /// The user cancelled or authentication failed. Not a lock:
        /// the next tap asks again.
        case refused
        /// The device cannot evaluate the policy at all (no
        /// biometrics enrolled and no passcode set). Callers fall
        /// back to manual password entry, same as a refusal.
        case unavailable
    }

    /// Runs one system authentication prompt and reports the
    /// outcome. Never throws: every failure mode is a value the
    /// caller can route on.
    ///
    /// Every non-authorized path records the system's own reason in
    /// the diagnostics log (package N): until that existed, a prompt
    /// that never appeared — the missing-usage-description build —
    /// was indistinguishable from a user who kept cancelling.
    static func authorize(reason: String) async -> Outcome {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            let status = BiometricAvailability.probe(
                canEvaluate: false,
                errorCode: laErrorCode(evaluationError),
                biometry: biometryKind(context.biometryType))
            AppDiagnostics.record(
                .error, L10n.string("身份验证不可用，未弹出系统验证"),
                metadata: ["reason": status.diagnosticToken, "source": "credential-gate"])
            return .unavailable
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            if !success {
                AppDiagnostics.record(
                    .error, L10n.string("身份验证失败"),
                    metadata: ["reason": "evaluate-returned-false", "source": "credential-gate"])
            }
            return success ? .authorized : .refused
        } catch {
            AppDiagnostics.record(
                .error, L10n.string("身份验证失败"),
                metadata: ["reason": BiometricAvailability.failureToken(errorCode: laErrorCode(error)),
                           "source": "credential-gate"])
            return .refused
        }
    }

    /// Read-only probe for the settings security section: what the
    /// system would do if a prompt were requested right now. No
    /// prompt is shown; `biometryType` is read after the
    /// can-evaluate call, the order LAContext documents it for.
    static func currentStatus() -> BiometricAvailability {
        let context = LAContext()
        var evaluationError: NSError?
        let canEvaluate = context.canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &evaluationError)
        return BiometricAvailability.probe(
            canEvaluate: canEvaluate,
            errorCode: laErrorCode(evaluationError),
            biometry: biometryKind(context.biometryType))
    }

    private static func biometryKind(_ type: LABiometryType) -> BiometryKind {
        switch type {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// LAError.Code raw value out of whatever the framework handed
    /// back; a non-LAError keeps its NSError code so the log still
    /// carries a number instead of nothing.
    private static func laErrorCode(_ error: Error?) -> Int? {
        guard let error else { return nil }
        if let laError = error as? LAError { return laError.code.rawValue }
        return (error as NSError).code
    }

    /// The one localized reason every credential spend shows, so the
    /// system prompt reads the same from every entry point.
    static var savedPasswordReason: String {
        L10n.string("验证身份以使用保存的路由器密码")
    }
}
