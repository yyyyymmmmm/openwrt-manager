import XCTest
import Crypto
import _CryptoExtras
import NIOCore
import NIOSSH
@testable import OpenWrtSSH

/// Hotfix round 5: the transport protection schemes that let the
/// terminal shake hands with dropbear (chacha20-poly1305@openssh.com,
/// aes*-ctr + hmac-sha2-256), plus the SSH error classification that
/// keeps raw NIO errors off the user's screen.
final class SSHTransportProtectionTests: XCTestCase {

    // MARK: - Poly1305 primitive (RFC 8439 §2.5.2 test vector)

    func testPoly1305RFC8439Vector() {
        let key: [UInt8] = [
            0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33, 0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
            0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd, 0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
        ]
        let message = [UInt8]("Cryptographic Forum Research Group".utf8)
        let expected: [UInt8] = [
            0xa8, 0x06, 0x1d, 0xc1, 0x30, 0x51, 0x36, 0xc6, 0xc2, 0x2b, 0x8b, 0xaf, 0x0c, 0x01, 0x27, 0xa9,
        ]
        XCTAssertEqual(Poly1305.authenticate(key: key, message: message), expected)
    }

    func testPoly1305EmptyAndShortMessages() {
        let key = [UInt8](repeating: 0x42, count: 32)
        XCTAssertEqual(Poly1305.authenticate(key: key, message: []).count, 16)
        // A one-byte change must change the tag.
        let a = Poly1305.authenticate(key: key, message: [0x01, 0x02, 0x03])
        let b = Poly1305.authenticate(key: key, message: [0x01, 0x02, 0x04])
        XCTAssertNotEqual(a, b)
        // Partial blocks of every length 1...15 authenticate distinctly.
        var tags = Set<[UInt8]>()
        for length in 1...15 {
            tags.insert(Poly1305.authenticate(key: key, message: [UInt8](repeating: 0x07, count: length)))
        }
        XCTAssertEqual(tags.count, 15)
    }

    // MARK: - ChaCha20CTR primitive (RFC 8439 A.1 vector #2)

    func testChaCha20CTRRFC8439Vector() throws {
        let key = SymmetricKey(data: (0..<32).map { UInt8($0) })
        let nonce = try Insecure.ChaCha20CTR.Nonce(data: [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00,
        ])
        let plaintext = [UInt8]("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let ciphertext = try Insecure.ChaCha20CTR.encrypt(
            plaintext, using: key, counter: try Insecure.ChaCha20CTR.Counter(offset: 1), nonce: nonce)
        XCTAssertEqual([UInt8](ciphertext).prefix(16),
                       [0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80, 0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81])
    }

    // MARK: - Scheme list

    func testSupportedSchemeListMatchesDropbearIntersection() {
        // chacha20-poly1305 is implemented and round-trip-tested below
        // but intentionally not proposed: swift-nio-ssh 0.15.1 cannot
        // derive its 64-byte key under a SHA-256 KEX (no RFC 4253
        // expansion loop upstream). See SSHTransportProtectionSchemes.
        let schemes = SSHTransportProtectionSchemes.supported
        XCTAssertEqual(schemes.map { $0.cipherName }, [
            "aes256-ctr", "aes128-ctr",
            "aes256-gcm@openssh.com", "aes128-gcm@openssh.com",
        ])
        XCTAssertEqual(schemes.map { $0.macName }, [
            "hmac-sha2-256", "hmac-sha2-256", nil, nil,
        ])
        for scheme in schemes {
            XCTAssertLessThanOrEqual(scheme.keySizes.encryptionKeySize, 32,
                                     "\(scheme.cipherName) must fit a single SHA-256 KEX digest")
            XCTAssertLessThanOrEqual(scheme.keySizes.macKeySize, 32)
            XCTAssertLessThanOrEqual(scheme.keySizes.ivSize, 32)
        }
    }

    // MARK: - Packet round trips

    private func makeKeys(encryptionSize: Int, ivSize: Int, macSize: Int, seed: UInt8) -> NIOSSHSessionKeys {
        func bytes(_ count: Int, _ offset: UInt8) -> [UInt8] {
            (0..<count).map { seed &+ offset &+ UInt8($0 & 0xff) }
        }
        return NIOSSHSessionKeys(
            initialInboundIV: bytes(ivSize, 0x10),
            initialOutboundIV: bytes(ivSize, 0x50),
            inboundEncryptionKey: SymmetricKey(data: bytes(encryptionSize, 0x20)),
            outboundEncryptionKey: SymmetricKey(data: bytes(encryptionSize, 0x60)),
            inboundMACKey: SymmetricKey(data: bytes(macSize, 0x30)),
            outboundMACKey: SymmetricKey(data: bytes(macSize, 0x70)))
    }

    private func mirrored(_ keys: NIOSSHSessionKeys) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: keys.initialOutboundIV,
            initialOutboundIV: keys.initialInboundIV,
            inboundEncryptionKey: keys.outboundEncryptionKey,
            outboundEncryptionKey: keys.inboundEncryptionKey,
            inboundMACKey: keys.outboundMACKey,
            outboundMACKey: keys.inboundMACKey)
    }

    /// Builds a plaintext SSH packet the way SSHPacketSerializer does.
    private func framedPacket(payload: [UInt8], blockSize: Int) -> [UInt8] {
        let payloadLength = payload.count + 5  // length field + padding-length byte
        var paddingLength = blockSize - (payloadLength % blockSize)
        if paddingLength < 4 { paddingLength += blockSize }
        let packetLength = 1 + payload.count + paddingLength
        var packet = [UInt8]()
        packet.append(UInt8((packetLength >> 24) & 0xff))
        packet.append(UInt8((packetLength >> 16) & 0xff))
        packet.append(UInt8((packetLength >> 8) & 0xff))
        packet.append(UInt8(packetLength & 0xff))
        packet.append(UInt8(paddingLength))
        packet.append(contentsOf: payload)
        packet.append(contentsOf: (0..<paddingLength).map { UInt8(0xa0 + $0) })
        return packet
    }

    private func roundTrip<Scheme: NIOSSHTransportProtection>(
        _ scheme: Scheme.Type, keys: NIOSSHSessionKeys, payloads: [[UInt8]]
    ) throws {
        let encryptor = try Scheme(initialKeys: keys)
        let decryptor = try Scheme(initialKeys: mirrored(keys))
        for (index, payload) in payloads.enumerated() {
            let sequence = UInt32(index)
            var out = ByteBufferAllocator().buffer(capacity: 0)
            out.writeBytes(framedPacket(payload: payload, blockSize: Scheme.cipherBlockSize))
            try encryptor.encryptPacket(&out, sequenceNumber: sequence)
            XCTAssertEqual(out.readableBytes, framedPacket(payload: payload, blockSize: Scheme.cipherBlockSize).count + encryptor.macBytes)

            var inbound = ByteBufferAllocator().buffer(capacity: 0)
            inbound.writeBytes([UInt8](out.readableBytesView))
            try decryptor.decryptFirstBlock(&inbound)
            let length = inbound.getInteger(at: inbound.readerIndex, as: UInt32.self)
            XCTAssertEqual(length, UInt32(framedPacket(payload: payload, blockSize: Scheme.cipherBlockSize).count - 4))
            let content = try decryptor.decryptAndVerifyRemainingPacket(&inbound, sequenceNumber: sequence)
            XCTAssertEqual([UInt8](content.readableBytesView), payload)
        }
    }

    private func tamperThrows<Scheme: NIOSSHTransportProtection>(
        _ scheme: Scheme.Type, keys: NIOSSHSessionKeys
    ) throws {
        let encryptor = try Scheme(initialKeys: keys)
        let decryptor = try Scheme(initialKeys: mirrored(keys))
        var out = ByteBufferAllocator().buffer(capacity: 0)
        out.writeBytes(framedPacket(payload: [UInt8]("hello router".utf8), blockSize: Scheme.cipherBlockSize))
        try encryptor.encryptPacket(&out, sequenceNumber: 0)
        var wire = [UInt8](out.readableBytesView)
        wire[10] ^= 0x01  // flip a payload ciphertext bit
        var inbound = ByteBufferAllocator().buffer(capacity: 0)
        inbound.writeBytes(wire)
        try decryptor.decryptFirstBlock(&inbound)
        XCTAssertThrowsError(try decryptor.decryptAndVerifyRemainingPacket(&inbound, sequenceNumber: 0))
    }

    func testChaChaRoundTrip() throws {
        let keys = makeKeys(encryptionSize: 64, ivSize: 16, macSize: 32, seed: 0x11)
        try roundTrip(ChaCha20Poly1305OpenSSHTransportProtection.self, keys: keys, payloads: [
            [UInt8]("a".utf8),
            [UInt8]("hello router, this is a shell packet".utf8),
            (0..<300).map { UInt8($0 & 0xff) },
        ])
    }

    func testChaChaTamperThrows() throws {
        let keys = makeKeys(encryptionSize: 64, ivSize: 16, macSize: 32, seed: 0x22)
        try tamperThrows(ChaCha20Poly1305OpenSSHTransportProtection.self, keys: keys)
    }

    func testAES256CTRRoundTrip() throws {
        let keys = makeKeys(encryptionSize: 32, ivSize: 16, macSize: 32, seed: 0x33)
        try roundTrip(AES256CTRTransportProtection.self, keys: keys, payloads: [
            [UInt8]("seven77".utf8),  // minimal packet: exactly one cipher block
            [UInt8]("ctr mode packet with hmac".utf8),
            (0..<200).map { UInt8($0 & 0xff) },
        ])
    }

    func testAES128CTRRoundTrip() throws {
        let keys = makeKeys(encryptionSize: 16, ivSize: 16, macSize: 32, seed: 0x44)
        try roundTrip(AES128CTRTransportProtection.self, keys: keys, payloads: [
            [UInt8]("aes128 ctr".utf8),
        ])
    }

    func testCTRTamperThrows() throws {
        let keys = makeKeys(encryptionSize: 32, ivSize: 16, macSize: 32, seed: 0x55)
        try tamperThrows(AES256CTRTransportProtection.self, keys: keys)
    }

    // MARK: - Error classification

    func testClassifyPassesThroughSessionErrors() {
        let error = SSHSessionError.hostKeyMismatch(expected: "aa", actual: "bb")
        XCTAssertEqual(SSHTerminalSession.classify(error, authRejected: false), error)
    }

    func testClassifyAuthRejectionWins() {
        let raw = NSError(domain: "test", code: 1)
        XCTAssertEqual(SSHTerminalSession.classify(raw, authRejected: true), .authenticationFailed)
    }

    func testClassifyConnectTimeout() {
        let error = ChannelError.connectTimeout(.seconds(15))
        XCTAssertEqual(SSHTerminalSession.classify(error, authRejected: false), .connectionTimedOut)
    }

    func testClassifyFallsBackToConnectionFailed() {
        let raw = NSError(domain: "test", code: 42)
        guard case .connectionFailed = SSHTerminalSession.classify(raw, authRejected: false) else {
            return XCTFail("expected connectionFailed fallback")
        }
    }
}
