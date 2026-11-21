import Foundation
import Security
import CryptoKit
import OpenWrtKit
import OpenWrtSSH

final class RouterTransport {
    let session: URLSession
    let delegate: RouterSessionDelegate

    init(address: RouterAddress, fingerprint: String?) {
        delegate = RouterSessionDelegate(host: address.host, fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Traffic goes only to the address explicitly chosen by the user.
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }
}

/// Only the certificate observation is mutable; NSLock guards it because
/// URLSession delegate callbacks run outside the main actor.
final class RouterSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let fingerprint: String?
    private let lock = NSLock()
    private var observation: CertificateNotice?

    init(host: String, fingerprint: String?) {
        self.host = host; self.fingerprint = fingerprint
    }

    var certificateNotice: CertificateNotice? {
        lock.lock(); defer { lock.unlock() }
        return observation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not replay a username/password or session token after a redirect.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let current = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
        if let fingerprint, fingerprint == current {
            // Explicit, host-scoped trust for exactly the user-confirmed leaf.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if fingerprint == nil, SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let notice = CertificateNotice(host: host, fingerprint: current,
                                       subject: SecCertificateCopySubjectSummary(leaf) as String? ?? host,
                                       changed: fingerprint != nil)
        lock.lock(); observation = notice; lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

enum FriendlyError {
    static func message(_ error: Error) -> String {
        if let error = error as? SSHSessionError {
            // SSH failures are semantic cases by the time they reach
            // the UI; the raw SwiftNIO error text is never shown.
            switch error {
            case .hostKeyMismatch(let expected, let actual):
                return L10n.format("主机密钥与记录不一致，可能存在安全风险。预期指纹：%@；实际指纹：%@。请先核对路由器无误，再更新档案中的记录。", expected, actual)
            case .authenticationFailed:
                return L10n.string("SSH 登录失败：用户名或密码不正确。请核对档案中保存的密码后重试。")
            case .algorithmNegotiationFailed:
                return L10n.string("与路由器协商加密算法失败：双方没有共同支持的算法。请升级路由器固件或 App 后重试。")
            case .connectionTimedOut:
                return L10n.string("SSH 连接超时。请确认手机与路由器在同一网络，并检查路由器上的 SSH 服务（dropbear）是否已开启。")
            case .connectionRefused:
                return L10n.string("路由器拒绝了 SSH 连接：SSH 服务可能未开启，或端口不是 22。请在路由器上确认 dropbear 的运行状态。")
            case .connectionFailed:
                return L10n.string("SSH 连接失败。请检查网络与路由器状态后重试。")
            case .shellUnavailable:
                return L10n.string("无法打开终端会话：路由器没有接受 shell 通道。请稍后重试。")
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return L10n.string("网络不可用。请连接路由器所在的 Wi-Fi，并在设置中允许本地网络访问。")
            case .timedOut: return L10n.string("连接超时。请检查路由器地址、管理端口和当前网络。")
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return L10n.string("找不到路由器。请检查地址，并确认手机能访问这个网络。")
            case .appTransportSecurityRequiresSecureConnection:
                return L10n.string("系统阻止了此 HTTP 连接，请改用 HTTPS 或局域网地址。")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
                return L10n.string("HTTPS 证书验证失败。请检查路由器证书、设备时间或证书指纹。")
            case .cancelled: return L10n.string("连接已取消。")
            default: return L10n.format("网络请求失败（%lld），请检查连接后重试。", error.errorCode)
            }
        }
        return error.localizedDescription
    }
}
