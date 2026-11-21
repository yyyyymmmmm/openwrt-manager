import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSH

/// Transport protection schemes beyond the AES-GCM pair bundled with
/// swift-nio-ssh, added through the framework's documented extension
/// point (`NIOSSHTransportProtection` +
/// `SSHClientConfiguration.transportProtectionSchemes`).
///
/// Why: the dropbear builds shipped with current OpenWrt (verified live
/// on the household's 25.12.5 bypass router and 24.10.8 main router)
/// offer only `chacha20-poly1305@openssh.com`, `aes256-ctr` and
/// `aes128-ctr` with `hmac-sha2-256` — no AES-GCM at all — so a stock
/// swift-nio-ssh client fails the handshake with "no matching cipher".
/// Upstream swift-nio-ssh (checked at the 0.15.1 tag and on `main`)
/// still bundles AES-GCM only, so the missing schemes are implemented
/// here, following PROTOCOL.chacha20poly1305 (OpenSSH) and RFC 4344
/// (AES-CTR) + RFC 4253 §6.4 (HMAC over the plaintext packet).
public enum SSHTransportProtectionSchemes {
    /// The client's proposal, in preference order: the two OpenWrt
    /// dropbear AES-CTR intersections first, then the bundled AES-GCM
    /// pair for full OpenSSH servers.
    ///
    /// `ChaCha20Poly1305OpenSSHTransportProtection` below is complete
    /// and unit-tested but deliberately NOT proposed: it needs a
    /// 64-byte encryption key, and swift-nio-ssh 0.15.1's key
    /// derivation never performs the RFC 4253 §7.2 expansion loop —
    /// each key item is a single KEX hash digest, asserted in
    /// EllipticCurveKeyExchange.generateServerToClientEncryptionKey
    /// (`expectedKeySize <= Digest.byteCount`). With the SHA-256 KEX
    /// both routers negotiate, a 64-byte key cannot be derived, so
    /// proposing chacha would fail every such handshake. Re-enable it
    /// once upstream derives expanded keys (or guarantees a SHA-512
    /// KEX). AES-CTR's largest item is 32 bytes and always fits.
    public static var supported: [NIOSSHTransportProtection.Type] {
        var schemes: [NIOSSHTransportProtection.Type] = [
            AES256CTRTransportProtection.self,
            AES128CTRTransportProtection.self,
        ]
        schemes.append(contentsOf: Constants.bundledTransportProtectionSchemes.map { $0 })
        return schemes
    }
}

enum TransportProtectionError: Error {
    case macVerificationFailed
    case malformedPacket
    case invalidKeySize
    case insufficientPadding
}

/// Constant-time equality for MAC/tag comparisons.
func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
        difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
}

// MARK: - chacha20-poly1305@openssh.com

/// The OpenSSH ChaCha20-Poly1305 AEAD construction
/// (PROTOCOL.chacha20poly1305): the 64-byte SSH encryption key splits
/// into K_2 (first 32 bytes, payload AEAD) and K_1 (last 32 bytes,
/// packet-length stream). The per-packet nonce is the packet sequence
/// number; the Poly1305 one-time key is the first 32 bytes of the K_2
/// block-0 keystream and the payload stream starts at block counter 1.
/// The raw stream is swift-crypto's `Insecure.ChaCha20CTR` (the IETF
/// form: a 12-byte nonce of eight zero bytes + the big-endian sequence
/// number and a 32-bit counter reproduce the original 64-bit-nonce
/// variant exactly for counters 0 and 1).
public final class ChaCha20Poly1305OpenSSHTransportProtection: NIOSSHTransportProtection {
    public static var cipherName: String { "chacha20-poly1305@openssh.com" }
    public static var macName: String? { nil }
    public static var cipherBlockSize: Int { 8 }
    public static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 64, macKeySize: 32) }

    public var macBytes: Int { 16 }
    public var lengthEncrypted: Bool { true }

    private var outboundPayloadKey: SymmetricKey
    private var outboundLengthKey: SymmetricKey
    private var inboundPayloadKey: SymmetricKey
    private var inboundLengthKey: SymmetricKey
    /// The parser hands sequence numbers to two of the three entry
    /// points; the inbound length decryption tracks its own counter.
    /// SSH sequence numbers are monotonic for the whole connection and
    /// are NOT reset by rekeying (RFC 4253 §6.4), so updateKeys must
    /// not touch this.
    private var inboundSequenceNumber: UInt32 = 0
    /// Ciphertext of the current inbound packet's length field, kept
    /// from decryptFirstBlock: the Poly1305 tag covers the length
    /// ciphertext, which the parser has us overwrite in place.
    private var inboundEncryptedLength: [UInt8]?

    public init(initialKeys: NIOSSHSessionKeys) throws {
        let outbound = try Self.splitKey(initialKeys.outboundEncryptionKey)
        let inbound = try Self.splitKey(initialKeys.inboundEncryptionKey)
        outboundPayloadKey = outbound.payload
        outboundLengthKey = outbound.length
        inboundPayloadKey = inbound.payload
        inboundLengthKey = inbound.length
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        let outbound = try Self.splitKey(newKeys.outboundEncryptionKey)
        let inbound = try Self.splitKey(newKeys.inboundEncryptionKey)
        outboundPayloadKey = outbound.payload
        outboundLengthKey = outbound.length
        inboundPayloadKey = inbound.payload
        inboundLengthKey = inbound.length
        inboundEncryptedLength = nil
    }

    private static func splitKey(_ key: SymmetricKey) throws -> (payload: SymmetricKey, length: SymmetricKey) {
        let bytes = key.withUnsafeBytes { [UInt8]($0) }
        guard bytes.count == 64 else { throw TransportProtectionError.invalidKeySize }
        // Spec order: the FIRST 256 bits are K_2 (payload), the second
        // 256 bits are K_1 (length).
        return (SymmetricKey(data: bytes[0..<32]), SymmetricKey(data: bytes[32..<64]))
    }

    private static func nonce(sequenceNumber: UInt32) -> Insecure.ChaCha20CTR.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[8] = UInt8((sequenceNumber >> 24) & 0xff)
        bytes[9] = UInt8((sequenceNumber >> 16) & 0xff)
        bytes[10] = UInt8((sequenceNumber >> 8) & 0xff)
        bytes[11] = UInt8(sequenceNumber & 0xff)
        // A 12-byte nonce cannot fail to construct.
        return try! Insecure.ChaCha20CTR.Nonce(data: bytes)
    }

    private static func applyChaCha(key: SymmetricKey, counter: UInt32, sequenceNumber: UInt32, bytes: [UInt8]) throws -> [UInt8] {
        let encrypted = try Insecure.ChaCha20CTR.encrypt(
            bytes, using: key,
            counter: try Insecure.ChaCha20CTR.Counter(offset: counter),
            nonce: nonce(sequenceNumber: sequenceNumber))
        return [UInt8](encrypted)
    }

    private static func poly1305Key(payloadKey: SymmetricKey, sequenceNumber: UInt32) throws -> [UInt8] {
        let block0 = try applyChaCha(key: payloadKey, counter: 0, sequenceNumber: sequenceNumber,
                                     bytes: [UInt8](repeating: 0, count: 64))
        return Array(block0[0..<32])
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        // Called exactly once per packet by the parser. Only the four
        // length bytes are decrypted (K_1); the payload belongs to K_2
        // and is handled in decryptAndVerifyRemainingPacket.
        guard inboundEncryptedLength == nil else { return }
        let start = source.readerIndex
        guard let lengthBytes = source.getBytes(at: start, length: 4) else {
            throw TransportProtectionError.malformedPacket
        }
        inboundEncryptedLength = lengthBytes
        let plain = try Self.applyChaCha(key: inboundLengthKey, counter: 0,
                                         sequenceNumber: inboundSequenceNumber, bytes: lengthBytes)
        source.setBytes(plain, at: start)
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        let total = source.readableBytes
        guard total >= 4 + macBytes, let encryptedLength = inboundEncryptedLength else {
            throw TransportProtectionError.malformedPacket
        }
        inboundEncryptedLength = nil
        let packet = [UInt8](source.readableBytesView)
        let ciphertext = Array(packet[4..<(total - macBytes)])
        let tag = Array(packet[(total - macBytes)..<total])

        // The MAC is verified BEFORE decrypting the payload (spec).
        let polyKey = try Self.poly1305Key(payloadKey: inboundPayloadKey, sequenceNumber: sequenceNumber)
        var macMessage = encryptedLength
        macMessage.append(contentsOf: ciphertext)
        let expectedTag = Poly1305.authenticate(key: polyKey, message: macMessage)
        guard constantTimeEqual(expectedTag, tag) else {
            throw TransportProtectionError.macVerificationFailed
        }

        var plaintext = try Self.applyChaCha(key: inboundPayloadKey, counter: 1,
                                             sequenceNumber: sequenceNumber, bytes: ciphertext)
        guard let paddingLength = plaintext.first, paddingLength >= 4,
              plaintext.count > Int(paddingLength) else {
            throw TransportProtectionError.insufficientPadding
        }
        plaintext = Array(plaintext[1..<(plaintext.count - Int(paddingLength))])
        inboundSequenceNumber &+= 1

        source.moveReaderIndex(to: source.writerIndex - plaintext.count)
        source.setBytes(plaintext, at: source.readerIndex)
        return source.readSlice(length: plaintext.count)!
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let start = destination.readerIndex
        let packet = [UInt8](destination.readableBytesView)
        guard packet.count >= 4 else { throw TransportProtectionError.malformedPacket }

        let polyKey = try Self.poly1305Key(payloadKey: outboundPayloadKey, sequenceNumber: sequenceNumber)
        let encryptedLength = try Self.applyChaCha(key: outboundLengthKey, counter: 0,
                                                   sequenceNumber: sequenceNumber, bytes: Array(packet[0..<4]))
        let encryptedBody = try Self.applyChaCha(key: outboundPayloadKey, counter: 1,
                                                 sequenceNumber: sequenceNumber, bytes: Array(packet[4..<packet.count]))
        var macMessage = encryptedLength
        macMessage.append(contentsOf: encryptedBody)
        let tag = Poly1305.authenticate(key: polyKey, message: macMessage)

        destination.setBytes(encryptedLength, at: start)
        destination.setBytes(encryptedBody, at: start + 4)
        destination.writeBytes(tag)
    }
}

// MARK: - aes128-ctr / aes256-ctr with hmac-sha2-256

/// AES in counter mode (RFC 4344) with the RFC 4253 §6.4
/// encrypt-and-MAC construction: HMAC-SHA-256 over the packet sequence
/// number and the *plaintext* packet, appended after the ciphertext.
/// The raw cipher is swift-crypto's `AES._CTR`; the 16-byte SSH IV is
/// the initial counter block, incremented big-endian per block.
/// Mirrors the shape of upstream's AESGCM base/subclass pair.
public class AESCTRTransportProtection {
    private var outboundEncryptionKey: SymmetricKey
    private var inboundEncryptionKey: SymmetricKey
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey
    private var outboundCounter: [UInt8]
    private var inboundCounter: [UInt8]

    public class var cipherName: String { fatalError("Must override cipher name") }
    public class var macName: String? { "hmac-sha2-256" }
    public class var keySizes: ExpectedKeySizes { fatalError("Must override key sizes") }

    public required init(initialKeys: NIOSSHSessionKeys) throws {
        guard initialKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              initialKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              initialKeys.initialOutboundIV.count == Self.keySizes.ivSize,
              initialKeys.initialInboundIV.count == Self.keySizes.ivSize
        else { throw TransportProtectionError.invalidKeySize }
        outboundEncryptionKey = initialKeys.outboundEncryptionKey
        inboundEncryptionKey = initialKeys.inboundEncryptionKey
        outboundMACKey = initialKeys.outboundMACKey
        inboundMACKey = initialKeys.inboundMACKey
        outboundCounter = initialKeys.initialOutboundIV
        inboundCounter = initialKeys.initialInboundIV
    }

    /// Runs the CTR stream over a block-aligned chunk, advancing the
    /// counter (a 128-bit big-endian integer) past the chunk.
    private static func crypt(_ bytes: [UInt8], key: SymmetricKey, counter: inout [UInt8]) throws -> [UInt8] {
        if bytes.isEmpty { return [] }
        precondition(bytes.count % 16 == 0, "CTR chunks must be block-aligned")
        let nonce = try AES._CTR.Nonce(nonceBytes: counter)
        let result = try AES._CTR.encrypt(bytes, using: key, nonce: nonce)
        var advanced = counter
        var carry = bytes.count / 16
        var index = 15
        while carry > 0, index >= 0 {
            let sum = Int(advanced[index]) + (carry & 0xff)
            advanced[index] = UInt8(sum & 0xff)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }
        counter = advanced
        return [UInt8](result)
    }

    private static func mac(key: SymmetricKey, sequenceNumber: UInt32, packet: [UInt8]) -> [UInt8] {
        var message = [UInt8]()
        message.reserveCapacity(4 + packet.count)
        message.append(UInt8((sequenceNumber >> 24) & 0xff))
        message.append(UInt8((sequenceNumber >> 16) & 0xff))
        message.append(UInt8((sequenceNumber >> 8) & 0xff))
        message.append(UInt8(sequenceNumber & 0xff))
        message.append(contentsOf: packet)
        return [UInt8](HMAC<SHA256>.authenticationCode(for: message, using: key))
    }
}

extension AESCTRTransportProtection: NIOSSHTransportProtection {
    public static var cipherBlockSize: Int { 16 }

    public var macBytes: Int { 32 }

    public var lengthEncrypted: Bool { true }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard newKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              newKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              newKeys.initialOutboundIV.count == Self.keySizes.ivSize,
              newKeys.initialInboundIV.count == Self.keySizes.ivSize
        else { throw TransportProtectionError.invalidKeySize }
        outboundEncryptionKey = newKeys.outboundEncryptionKey
        inboundEncryptionKey = newKeys.inboundEncryptionKey
        outboundMACKey = newKeys.outboundMACKey
        inboundMACKey = newKeys.inboundMACKey
        outboundCounter = newKeys.initialOutboundIV
        inboundCounter = newKeys.initialInboundIV
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        let start = source.readerIndex
        guard let block = source.getBytes(at: start, length: 16) else {
            throw TransportProtectionError.malformedPacket
        }
        let plain = try Self.crypt(block, key: inboundEncryptionKey, counter: &inboundCounter)
        source.setBytes(plain, at: start)
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        let total = source.readableBytes
        guard total >= 16 + macBytes else { throw TransportProtectionError.malformedPacket }
        let packet = [UInt8](source.readableBytesView)
        let cipherEnd = total - macBytes
        let tag = Array(packet[cipherEnd..<total])

        // The first block was already decrypted by decryptFirstBlock;
        // decrypt the rest of the packet continuing the CTR stream.
        var plaintext = Array(packet[0..<16])
        if cipherEnd > 16 {
            let rest = try Self.crypt(Array(packet[16..<cipherEnd]), key: inboundEncryptionKey, counter: &inboundCounter)
            plaintext.append(contentsOf: rest)
        }

        let expected = Self.mac(key: inboundMACKey, sequenceNumber: sequenceNumber, packet: plaintext)
        guard constantTimeEqual(expected, tag) else {
            throw TransportProtectionError.macVerificationFailed
        }

        var content = Array(plaintext[4..<plaintext.count])
        guard let paddingLength = content.first, paddingLength >= 4,
              content.count > Int(paddingLength) else {
            throw TransportProtectionError.insufficientPadding
        }
        content = Array(content[1..<(content.count - Int(paddingLength))])

        source.moveReaderIndex(to: source.writerIndex - content.count)
        source.setBytes(content, at: source.readerIndex)
        return source.readSlice(length: content.count)!
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let start = destination.readerIndex
        let packet = [UInt8](destination.readableBytesView)
        let tag = Self.mac(key: outboundMACKey, sequenceNumber: sequenceNumber, packet: packet)
        let ciphertext = try Self.crypt(packet, key: outboundEncryptionKey, counter: &outboundCounter)
        destination.setBytes(ciphertext, at: start)
        destination.writeBytes(tag)
    }
}

/// aes256-ctr with hmac-sha2-256.
public final class AES256CTRTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    public override static var cipherName: String { "aes256-ctr" }

    public override static var keySizes: ExpectedKeySizes {
        .init(ivSize: 16, encryptionKeySize: 32, macKeySize: 32)
    }
}

/// aes128-ctr with hmac-sha2-256.
public final class AES128CTRTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    public override static var cipherName: String { "aes128-ctr" }

    public override static var keySizes: ExpectedKeySizes {
        .init(ivSize: 16, encryptionKeySize: 16, macKeySize: 32)
    }
}
