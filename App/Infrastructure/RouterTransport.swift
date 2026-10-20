import Foundation
import Security
import CryptoKit
import OpenWrtKit

final class RouterTransport {
    let session: URLSession
    let delegate: RouterSessionDelegate

    init(address: RouterAddress, fingerprint: String?) {
        delegate = RouterSessionDelegate(host: address.host, fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        // Package-manager CGI requests can hold the response until the fixed
        // command exits. Ordinary RPCs keep their own 12-second request limit.
        configuration.timeoutIntervalForResource = 660
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
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return "网络不可用。请连接路由器所在的 Wi-Fi，并在设置中允许本地网络访问。"
            case .timedOut: return "连接超时。请检查路由器地址、管理端口和当前网络。"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "找不到路由器。请检查地址，并确认手机能访问这个网络。"
            case .appTransportSecurityRequiresSecureConnection:
                return "系统阻止了此 HTTP 连接，请改用 HTTPS 或局域网地址。"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
                return "HTTPS 证书验证失败。请检查路由器证书、设备时间或证书指纹。"
            case .cancelled: return "连接已取消。"
            default: return "网络请求失败（\(error.errorCode)），请检查连接后重试。"
            }
        }
        return error.localizedDescription
    }
}
