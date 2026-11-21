import Foundation

/// Biometric availability model (package N).
///
/// Why this exists: package K put a `LAContext` gate in front of
/// every saved-credential spend, and package C had already built the
/// App lock on the same policy — but the app shipped without
/// `NSFaceIDUsageDescription`, so on a real device the system never
/// let either prompt use Face ID and the user silently landed on
/// password forms. The failure was invisible because every layer
/// swallowed the system's reason. This model is the single place
/// that turns the LocalAuthentication verdict — the
/// `canEvaluatePolicy` error and the `evaluatePolicy` error — into
/// (a) a stable diagnostic token that lands in the diagnostics log
/// verbatim, and (b) a human line for the settings security section,
/// so the next "Face ID didn't appear" is answered by the export,
/// not by guessing.
///
/// The kit stays free of LocalAuthentication: callers pass the
/// `LAError.Code` raw value (stable public constants, listed below)
/// and the biometry kind they read off their context.
public enum BiometryKind: String, Equatable, Sendable {
    case none
    case touchID
    case faceID
    case opticID
}

public enum BiometricAvailability: Equatable, Sendable {
    /// The policy can be evaluated; a prompt would appear.
    case available(biometry: BiometryKind)
    /// LAError.biometryNotEnrolled (-7): hardware exists, nothing
    /// enrolled yet.
    case notEnrolled
    /// LAError.biometryNotAvailable (-6): no biometric hardware, or
    /// biometrics are off at the system level.
    case notAvailable
    /// LAError.biometryLockout (-8): too many failed attempts; the
    /// device passcode must be entered once to re-enable biometrics.
    case lockout
    /// LAError.passcodeNotSet (-5): `.deviceOwnerAuthentication`
    /// has nothing to fall back to either.
    case passcodeNotSet
    /// Any other canEvaluate failure, with the LAError code kept
    /// for the diagnostics log.
    case unavailable(code: Int)

    /// Maps one `LAContext.canEvaluatePolicy` verdict. `errorCode`
    /// is the `LAError.Code` raw value when evaluation is
    /// impossible, nil when it is possible (or unknown).
    public static func probe(canEvaluate: Bool, errorCode: Int?,
                             biometry: BiometryKind) -> BiometricAvailability {
        if canEvaluate { return .available(biometry: biometry) }
        switch errorCode {
        case -7: return .notEnrolled
        case -6: return .notAvailable
        case -8: return .lockout
        case -5: return .passcodeNotSet
        default: return .unavailable(code: errorCode ?? 0)
        }
    }

    /// Stable token for the diagnostics log — never user copy, so
    /// the reason survives localization and can be grepped in an
    /// exported diagnostics file.
    public var diagnosticToken: String {
        switch self {
        case .available(let kind): return "available-\(kind.rawValue)"
        case .notEnrolled: return "biometry-not-enrolled"
        case .notAvailable: return "biometry-not-available"
        case .lockout: return "biometry-lockout"
        case .passcodeNotSet: return "passcode-not-set"
        case .unavailable(let code): return "la-error-\(code)"
        }
    }

    /// Maps an `evaluatePolicy` failure (an `LAError.Code` raw
    /// value) to the same kind of stable diagnostic token. User and
    /// system cancels are expected traffic, not malfunctions — the
    /// token keeps them distinguishable from real failures in the
    /// log instead of lumping everything into "failed".
    public static func failureToken(errorCode: Int?) -> String {
        switch errorCode {
        case -1: return "authentication-failed"
        case -2: return "user-cancel"
        case -3: return "user-fallback"
        case -4: return "system-cancel"
        case -5: return "passcode-not-set"
        case -6: return "biometry-not-available"
        case -7: return "biometry-not-enrolled"
        case -8: return "biometry-lockout"
        case -9: return "app-cancel"
        case -10: return "invalid-context"
        case -1004: return "not-interactive"
        case let code?: return "la-error-\(code)"
        case nil: return "unknown-error"
        }
    }

    /// The human line the settings security section shows next to
    /// the App lock switch: what would happen if a prompt were
    /// requested right now, and — when it would not appear — why,
    /// in words the user can act on.
    public var statusLine: String {
        switch self {
        case .available(.faceID):
            return KitL10n.text("Face ID 可用")
        case .available(.touchID):
            return KitL10n.text("触控 ID 可用")
        case .available(.opticID):
            return KitL10n.text("Optic ID 可用")
        case .available(.none):
            return KitL10n.text("仅设备密码可用，未设置生物识别")
        case .notEnrolled:
            return KitL10n.text("尚未录入 Face ID 或指纹，请先到系统设置中录入")
        case .notAvailable:
            return KitL10n.text("此设备不支持生物识别，或已被系统关闭")
        case .lockout:
            return KitL10n.text("生物识别已锁定，请先用设备密码解锁一次")
        case .passcodeNotSet:
            return KitL10n.text("尚未设置设备密码，无法验证身份")
        case .unavailable:
            return KitL10n.text("生物识别当前不可用")
        }
    }
}
