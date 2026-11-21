import SwiftUI
import Observation
import OpenWrtKit

/// Shared orchestration for one-tap router switching (package K):
/// the CredentialGate prompt, the saved-credential connection, and
/// the three routings that can follow — manual password entry,
/// certificate confirmation, inline failure with retry. The
/// settings profile list and the connect flow's saved list both
/// drive their rows through one of these, so the behaviour — and
/// its wording — cannot drift apart between surfaces.
@MainActor @Observable
final class QuickConnectModel {
    /// A certificate the user must confirm before the switch may
    /// proceed; the view presents it with the shared alert below.
    struct CertificatePrompt: Identifiable {
        let profile: RouterProfile
        let notice: CertificateNotice
        var id: String { notice.id }
    }

    private(set) var connectingID: UUID?
    private(set) var failures: [UUID: String] = [:]
    var certificatePrompt: CertificatePrompt?
    /// Set when the tap must continue as manual password entry
    /// (gate refused or unavailable, or the profile has no saved
    /// password). The view navigates to the login form in manual
    /// mode and clears this afterwards.
    var manualEntryProfile: RouterProfile?

    func isConnecting(_ profile: RouterProfile) -> Bool { connectingID == profile.id }
    func failure(for profile: RouterProfile) -> String? { failures[profile.id] }

    /// The row tap: Face ID first, the saved credential second,
    /// the password form only when either cannot carry the tap.
    /// Tapping the already-connected router, or any row while a
    /// switch is in flight, does nothing.
    func tap(_ profile: RouterProfile, store: RouterStore) async {
        guard store.activeProfile?.id != profile.id, connectingID == nil else { return }
        connectingID = profile.id
        failures[profile.id] = nil
        defer { connectingID = nil }
        switch await CredentialGate.authorize(reason: CredentialGate.savedPasswordReason) {
        case .authorized:
            await run(profile, store: store, fingerprint: nil)
        case .refused, .unavailable:
            manualEntryProfile = profile
        }
    }

    /// Retry after the user confirmed the certificate fingerprint
    /// in the shared alert. No second gate prompt: the explicit
    /// confirmation is the deliberate act this retry spends.
    func confirmCertificate(store: RouterStore) async {
        guard let prompt = certificatePrompt else { return }
        certificatePrompt = nil
        connectingID = prompt.profile.id
        defer { connectingID = nil }
        await run(prompt.profile, store: store, fingerprint: prompt.notice.fingerprint)
    }

    private func run(_ profile: RouterProfile, store: RouterStore, fingerprint: String?) async {
        switch await store.connectSaved(profile: profile, fingerprint: fingerprint) {
        case .connected:
            failures[profile.id] = nil
        case .needsManualPassword:
            manualEntryProfile = profile
        case .certificate(let notice):
            certificatePrompt = CertificatePrompt(profile: profile, notice: notice)
        case .failed(let message):
            failures[profile.id] = message
        }
    }
}

extension View {
    /// The certificate confirmation shared by every one-tap switch
    /// surface (package K): same wording as the login form's own
    /// certificate alert; trusting retries the switch through the
    /// model with the confirmed fingerprint.
    func quickConnectCertificateAlert(model: QuickConnectModel, store: RouterStore) -> some View {
        alert(item: Binding(
            get: { model.certificatePrompt },
            set: { if $0 == nil { model.certificatePrompt = nil } }
        )) { prompt in
            let notice = prompt.notice
            return Alert(
                title: Text(notice.changed ? "路由器证书已更改" : "路由器证书未获系统信任"),
                message: Text("\(notice.host)\n\(notice.subject)\nSHA-256\n\(notice.fingerprint)\n\n请通过可信方式核对指纹。信任后只对这个路由器地址生效。"),
                primaryButton: .default(Text("核对后信任并继续")) {
                    Task { await model.confirmCertificate(store: store) }
                },
                secondaryButton: .cancel())
        }
    }
}
