import Foundation
import LocalAuthentication

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
    static func authorize(reason: String) async -> Outcome {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            return .unavailable
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            return success ? .authorized : .refused
        } catch {
            return .refused
        }
    }

    /// The one localized reason every credential spend shows, so the
    /// system prompt reads the same from every entry point.
    static var savedPasswordReason: String {
        L10n.string("验证身份以使用保存的路由器密码")
    }
}
