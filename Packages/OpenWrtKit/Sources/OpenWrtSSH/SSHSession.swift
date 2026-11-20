import Foundation
import NIO
import NIOSSH
import OpenWrtKit

/// Native SSH terminal transport (phase 3, spec 0A): a real SSH client
/// speaking to the router's dropbear/OpenSSH daemon — password auth from
/// the app's credential store, host-key verification by SHA-256
/// fingerprint, PTY + shell channel feeding the kit's TerminalCore.
/// The library is Apple's swift-nio-ssh 0.12 (pure Swift, actively
/// maintained); no web terminal and no external jumps are involved.

public enum SSHSessionError: Error, Equatable {
    case hostKeyMismatch(expected: String, actual: String)
    case connectionFailed(String)
    case shellUnavailable
}

public final class SSHTerminalSession: Sendable {
    public enum HostKeyPolicy: Sendable {
        /// Accept any key but report its fingerprint (first-connect UX
        /// shows it; the app stores it in the profile credentials).
        case acceptAny
        /// Require the presented key to match this SHA-256 hex digest.
        case verifySHA256(String)
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let shellBox: ShellBox
    /// SHA-256 (hex) of the host key presented during the handshake.
    public let hostKeySHA256: String

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, shellBox: ShellBox, hostKeySHA256: String) {
        self.group = group
        self.channel = channel
        self.shellBox = shellBox
        self.hostKeySHA256 = hostKeySHA256
    }

    public static func connect(host: String, port: Int = 22,
                               username: String, password: String,
                               policy: HostKeyPolicy = .acceptAny) async throws -> SSHTerminalSession {
        let fingerprintBox = FingerprintBox()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(15))
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: PasswordAuthDelegate(username: username, password: password),
                            serverAuthDelegate: FingerprintAuthDelegate(policy: policy, box: fingerprintBox))),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                ])
            }
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            return SSHTerminalSession(group: group, channel: channel,
                                      shellBox: ShellBox(), hostKeySHA256: fingerprintBox.value ?? "")
        } catch {
            try? await group.shutdownGracefully()
            if let mismatch = error as? SSHSessionError { throw mismatch }
            throw SSHSessionError.connectionFailed(error.localizedDescription)
        }
    }

    /// Opens the shell channel with a PTY of the given size. Output arrives
    /// on the returned stream; feed it to TerminalParser.
    public func openShell(columns: Int, rows: Int) async throws -> AsyncStream<Data> {
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        handler.createChannel(promise) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.close()
            }
            return childChannel.pipeline.addHandler(
                ShellChannelHandler(box: self.shellBox, columns: columns, rows: rows))
        }
        let childChannel = try await promise.futureResult.get()
        shellBox.attach(channel: childChannel)
        try await shellBox.waitReady()
        return shellBox.stream
    }

    public func send(_ data: Data) {
        shellBox.send(data)
    }

    public func resize(columns: Int, rows: Int) {
        shellBox.resize(columns: columns, rows: rows)
    }

    public func close() async {
        shellBox.close()
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Authentication delegates

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if availableMethods.contains(.password) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .password(.init(password: password))))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

private final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func store(_ fingerprint: String) { lock.lock(); stored = fingerprint; lock.unlock() }
}

private final class FingerprintAuthDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let policy: SSHTerminalSession.HostKeyPolicy
    private let box: FingerprintBox

    init(policy: SSHTerminalSession.HostKeyPolicy, box: FingerprintBox) {
        self.policy = policy
        self.box = box
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // OpenSSH fingerprint convention: SHA-256 over the wire-format
        // key blob, which is the base64 payload of the OpenSSH string.
        let openSSHString = String(openSSHPublicKey: hostKey)
        let base64 = openSSHString.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let bytes = Data(base64Encoded: base64) ?? Data()
        let fingerprint = SHA256Hasher.hexDigest(bytes)
        box.store(fingerprint)
        switch policy {
        case .acceptAny:
            validationCompletePromise.succeed(())
        case .verifySHA256(let expected):
            if expected.lowercased() == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSessionError.hostKeyMismatch(expected: expected, actual: fingerprint))
            }
        }
    }
}

// MARK: - Shell channel plumbing

private final class ShellBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var continuation: AsyncStream<Data>.Continuation?
    private var readyPromise: CheckedContinuation<Void, Error>?
    private var readyResult: Result<Void, Error>?

    lazy var stream: AsyncStream<Data> = AsyncStream { continuation in
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(channel: Channel) {
        lock.lock(); self.channel = channel; lock.unlock()
    }

    func waitReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let readyResult {
                lock.unlock()
                continuation.resume(with: readyResult)
            } else {
                readyPromise = continuation
                lock.unlock()
            }
        }
    }

    func markReady() {
        finishReady(with: .success(()))
    }

    func markFailed(_ error: Error) {
        finishReady(with: .failure(error))
    }

    private func finishReady(with result: Result<Void, Error>) {
        lock.lock()
        readyResult = result
        let pending = readyPromise
        readyPromise = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func yield(_ data: Data) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.yield(data)
    }

    func finishStream() {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.finish()
    }

    func send(_ data: Data) {
        lock.lock(); let channel = self.channel; lock.unlock()
        guard let channel else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            channel.writeAndFlush(wrapped, promise: nil)
        }
    }

    func resize(columns: Int, rows: Int) {
        lock.lock(); let channel = self.channel; lock.unlock()
        guard let channel else { return }
        channel.eventLoop.execute {
            _ = channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns,
                                                           terminalRowHeight: rows,
                                                           terminalPixelWidth: 0, terminalPixelHeight: 0))
        }
    }

    func close() {
        lock.lock(); let channel = self.channel; lock.unlock()
        channel?.eventLoop.execute {
            _ = channel?.close()
        }
        finishStream()
    }
}

private final class ShellChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let box: ShellBox
    private let columns: Int
    private let rows: Int

    init(box: ShellBox, columns: Int, rows: Int) {
        self.box = box
        self.columns = columns
        self.rows = rows
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty).whenComplete { _ in
            let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            context.triggerUserOutboundEvent(shell).whenComplete { result in
                switch result {
                case .success: self.box.markReady()
                case .failure(let error): self.box.markFailed(error)
                }
            }
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel || channelData.type == .stdErr else { return }
        switch channelData.data {
        case .byteBuffer(let buffer):
            if let bytes = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) {
                box.yield(bytes)
            }
        case .fileRegion:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        box.finishStream()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        box.markFailed(error)
        context.close(promise: nil)
    }
}
