import Foundation
import Network
import Observation
import Darwin
import OpenWrtKit

struct DiscoveredRouter: Identifiable, Hashable, Sendable {
    let address: String
    let name: String
    let source: String
    var model: String? = nil
    var firmware: String? = nil
    /// True only when the OpenWrt fingerprint check passed — an open
    /// web port alone never earns this.
    var verified = false
    var id: String { address }
}

private struct ProbeTarget: Sendable {
    let host: String
    let port: UInt16
    var address: String { "\(port == 443 ? "https" : "http")://\(host)" }
}

/// LAN auto-discovery (package B, item 4 — replaces the original
/// whole-subnet web-port sweep): probe only the handful of addresses
/// a home router actually sits at (gateway-first, from the kit's
/// DiscoveryCandidates), then verify each open port is really
/// OpenWrt before listing it — LuCI login-page fingerprint first,
/// the anonymous ubus board call for model/firmware when the build
/// answers it. Bonjour services are verified the same way when they
/// resolve. Nothing here logs in; credentials stay in the normal
/// add flow that follows a tap.
@MainActor @Observable
final class RouterDiscoveryService {
    private(set) var results: [DiscoveredRouter] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var message: String?
    private(set) var permissionDenied = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var generation = UUID()

    func start() {
        stop()
        generation = UUID()
        let run = generation
        results = []
        completed = 0
        permissionDenied = false
        message = nil
        hasScanned = true
        isScanning = true
        startBonjour(generation: run)
        let hosts = Self.localGatewayCandidates()
        let targets = hosts.flatMap { host in
            [ProbeTarget(host: host, port: 80), ProbeTarget(host: host, port: 443)]
        }
        total = targets.count
        if targets.isEmpty {
            message = L10n.string("未获取到 Wi-Fi IPv4 网段，正在尝试 Bonjour 发现。你也可以手动输入地址。")
        } else {
            message = L10n.string("只检查网关等少数常用地址，并逐个验证是否为 OpenWrt，不做全网段扫描。")
        }
        scanTask = Task { [weak self] in
            var openTargets: [ProbeTarget] = []
            await withTaskGroup(of: (ProbeTarget, Bool).self) { group in
                var next = 0
                for _ in 0..<min(8, targets.count) {
                    let target = targets[next]
                    next += 1
                    group.addTask { (target, await TCPProbe.check(host: target.host, port: target.port)) }
                }
                while let (target, open) = await group.next() {
                    guard let self, self.generation == run, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.completed += 1
                    if open { openTargets.append(target) }
                    if next < targets.count {
                        let target = targets[next]
                        next += 1
                        group.addTask { (target, await TCPProbe.check(host: target.host, port: target.port)) }
                    }
                }
            }
            guard let self, self.generation == run, !Task.isCancelled else { return }
            // Verification phase: an open port is a lead, not a result.
            for target in openTargets {
                guard self.generation == run, !Task.isCancelled else { return }
                let check = await OpenWrtProbe.verify(host: target.host, port: target.port)
                guard self.generation == run, !Task.isCancelled else { return }
                if check.isOpenWrt {
                    self.insert(.init(address: target.address,
                                      name: check.board?.hostname ?? target.host,
                                      source: L10n.string("已验证为 OpenWrt"),
                                      model: check.board?.model,
                                      firmware: check.board?.firmware,
                                      verified: true))
                }
            }
            // Give Bonjour time to resolve when no IPv4 interface was available.
            if targets.isEmpty { try? await Task.sleep(for: .seconds(4)) }
            guard self.generation == run, !Task.isCancelled else { return }
            self.finish()
        }
    }

    func stop() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        browsers.forEach { $0.cancel() }
        browsers = []
        isScanning = false
    }

    private func finish() {
        isScanning = false
        browsers.forEach { $0.cancel() }
        browsers = []
        scanTask = nil
    }

    private func insert(_ result: DiscoveredRouter) {
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            // A verified result upgrades an unverified entry for the
            // same address; never the other way round.
            if result.verified && !results[index].verified {
                results[index] = result
            }
            return
        }
        results.append(result)
        results.sort {
            if $0.verified != $1.verified { return $0.verified && !$1.verified }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }

    private func startBonjour(generation run: UUID) {
        for type in ["_http._tcp", "_https._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                guard case .waiting(let error) = state else { return }
                // A DNS policy error is the usual denial signal. Avoid
                // depending on the SDK's DNSServiceErrorType spelling here.
                guard String(describing: error).localizedCaseInsensitiveContains("policy")
                    || String(describing: error).localizedCaseInsensitiveContains("denied") else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run else { return }
                    self.permissionDenied = true
                    self.message = L10n.string("本地网络访问被拒绝。请在系统设置中允许本地网络访问，或手动输入可访问的地址。")
                    self.stop()
                }
            }
            browser.browseResultsChangedHandler = { [weak self] entries, _ in
                for entry in entries {
                    guard case .service(let name, _, _, _) = entry.endpoint else { continue }
                    let connection = NWConnection(to: entry.endpoint, using: .tcp)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            defer { connection.cancel() }
                            guard let endpoint = connection.currentPath?.remoteEndpoint,
                                  case .hostPort(let host, let port) = endpoint else { return }
                            let hostText: String
                            switch host {
                            case .ipv4(let ip): hostText = ip.debugDescription
                            case .ipv6(let ip): hostText = "[\(ip.debugDescription)]"
                            case .name(let value, _): hostText = value
                            @unknown default: return
                            }
                            let scheme = type == "_https._tcp" ? "https" : "http"
                            let address = "\(scheme)://\(hostText):\(port.rawValue)"
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == run, self.isScanning else { return }
                                // Listed at once as an unverified
                                // Bonjour lead, then upgraded in place
                                // when the fingerprint check passes.
                                self.insert(.init(address: address, name: name,
                                                  source: L10n.string("Bonjour Web 服务 · 尚未验证 OpenWrt")))
                                let check = await OpenWrtProbe.verify(host: hostText, port: port.rawValue)
                                guard self.generation == run, check.isOpenWrt else { return }
                                self.insert(.init(address: address,
                                                  name: check.board?.hostname ?? name,
                                                  source: L10n.string("Bonjour · 已验证为 OpenWrt"),
                                                  model: check.board?.model,
                                                  firmware: check.board?.firmware,
                                                  verified: true))
                            }
                        case .failed, .cancelled:
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                        connection.cancel()
                    }
                }
            }
            browsers.append(browser)
            browser.start(queue: .global(qos: .utility))
        }
    }

    /// Gateway-first candidates inside the phone's own /24, computed
    /// by the kit (the list itself is unit-tested there).
    private static func localGatewayCandidates() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            guard String(cString: interface.ifa_name) == "en0",
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let maskAddress = interface.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = maskAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return DiscoveryCandidates.hosts(phoneIP: dotted(ip), netmask: dotted(mask))
        }
        return []
    }

    private static func dotted(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }
}

/// The OpenWrt fingerprint probe. Its URLSession accepts any server
/// trust because this step only *identifies* a LAN candidate by its
/// public login page — no credential is ever sent through it. The
/// address it returns still goes through the normal login flow,
/// whose own certificate handling runs before a password is typed.
private enum OpenWrtProbe {
    struct Result {
        var isOpenWrt: Bool
        var board: OpenWrtFingerprint.BoardInfo?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration,
                          delegate: ProbeTrustDelegate(), delegateQueue: nil)
    }()

    static func verify(host: String, port: UInt16) async -> Result {
        let scheme = port == 443 ? "https" : "http"
        let authority = (port == 80 || port == 443) ? host : "\(host):\(port)"
        let base = "\(scheme)://\(authority)"
        if let url = URL(string: "\(base)/cgi-bin/luci/"),
           let (data, _) = try? await session.data(for: request(url)),
           let html = String(data: data, encoding: .utf8),
           OpenWrtFingerprint.looksLikeLuCI(html: html) {
            return Result(isOpenWrt: true, board: await boardInfo(base: base))
        }
        // Some builds redirect or gate the login page yet still answer
        // the board call; that answer is itself strong evidence.
        if let board = await boardInfo(base: base) {
            return Result(isOpenWrt: true, board: board)
        }
        return Result(isOpenWrt: false, board: nil)
    }

    private static func boardInfo(base: String) async -> OpenWrtFingerprint.BoardInfo? {
        guard let url = URL(string: "\(base)/ubus") else { return nil }
        var post = request(url)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","system","board",{}]}"#.utf8)
        guard let (data, _) = try? await session.data(for: post) else { return nil }
        return OpenWrtFingerprint.boardInfo(from: data)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        return request
    }
}

private final class ProbeTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// A bounded TCP check. Each continuation completes exactly once on success,
/// timeout or cancellation, and every connection is closed.
private final class TCPProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func check(host: String, port: UInt16) async -> Bool {
        let probe = TCPProbe(host: host, port: port)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.begin(continuation)
            }
        } onCancel: {
            probe.finish(false)
        }
    }

    private func begin(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.finish(true)
            case .failed, .cancelled: self?.finish(false)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.finish(false)
        }
    }

    private func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(returning: value)
    }
}
