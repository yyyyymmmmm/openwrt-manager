import Foundation
import Network
import Observation
import Darwin

struct DiscoveredRouter: Identifiable, Hashable, Sendable {
    let address: String
    let name: String
    let source: String
    var id: String { address }
}

private struct ProbeTarget: Sendable {
    let host: String
    let port: UInt16
    var address: String { "\(port == 443 ? "https" : "http")://\(host)" }
}

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
        let hosts = Self.localIPv4Candidates()
        let targets = hosts.flatMap { host in
            [ProbeTarget(host: host, port: 80), ProbeTarget(host: host, port: 443)]
        }
        total = targets.count
        if targets.isEmpty {
            message = "未获取到 Wi-Fi IPv4 网段，正在尝试 Bonjour 发现。你也可以手动输入地址。"
        } else {
            message = "检查当前 Wi-Fi 所在网段的 80 / 443 端口；较大的网段仅检查手机所在的 /24 范围。"
        }
        scanTask = Task { [weak self] in
            await withTaskGroup(of: (ProbeTarget, Bool).self) { group in
                var next = 0
                for _ in 0..<min(16, targets.count) {
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
                    if open {
                        self.insert(.init(address: target.address, name: target.host, source: "开放 Web 端口 · 尚未验证 OpenWrt"))
                    }
                    if next < targets.count {
                        let target = targets[next]
                        next += 1
                        group.addTask { (target, await TCPProbe.check(host: target.host, port: target.port)) }
                    }
                }
            }
            // Give Bonjour time to resolve when no IPv4 interface was available.
            if targets.isEmpty { try? await Task.sleep(for: .seconds(4)) }
            guard let self, self.generation == run, !Task.isCancelled else { return }
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
        guard !results.contains(where: { $0.id == result.id }) else { return }
        results.append(result)
        results.sort { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
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
                    self.message = "本地网络访问被拒绝。请在系统设置中允许本地网络访问，或手动输入可访问的地址。"
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
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == run, self.isScanning else { return }
                                self.insert(.init(
                                    address: "\(scheme)://\(hostText):\(port.rawValue)",
                                    name: name, source: "Bonjour Web 服务 · 尚未验证 OpenWrt"
                                ))
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

    /// No guessed remote subnets: inspect only the active Wi-Fi IPv4 interface.
    /// A /16 or larger network is bounded to this phone's /24.
    private static func localIPv4Candidates() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var hosts = Set<String>()
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
            // Broad networks are capped at /24; narrower masks stay intact.
            let boundedMask = mask | 0xFFFFFF00
            let network = ip & boundedMask
            let broadcast = network | ~boundedMask
            guard broadcast > network + 1 else { continue }
            for candidate in (network + 1)..<broadcast where candidate != ip {
                let octets = [24, 16, 8, 0].map { String((candidate >> $0) & 255) }
                hosts.insert(octets.joined(separator: "."))
            }
        }
        return hosts.sorted()
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
