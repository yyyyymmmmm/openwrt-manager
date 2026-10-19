import Foundation

struct RouterProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var username: String
    var rememberPassword: Bool
    var lastConnected = Date()
}

struct StoredCredential: Codable {
    var password: String?
    var certificateFingerprint: String?
}

struct CertificateNotice: Identifiable, Equatable {
    let host: String
    let fingerprint: String
    let subject: String
    let changed: Bool
    var id: String { fingerprint }
}

enum AppFailure: LocalizedError {
    case storage(String)
    case certificate(CertificateNotice)

    var errorDescription: String? {
        switch self {
        case .storage(let text): return text
        case .certificate(let notice):
            return notice.changed ? "证书与已保存的指纹不同，请核对路由器证书。" : "路由器证书未获系统信任，请核对证书指纹。"
        }
    }
}
