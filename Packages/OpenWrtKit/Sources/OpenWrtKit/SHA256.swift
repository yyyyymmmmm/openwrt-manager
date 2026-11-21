import Foundation

/// Minimal SHA-256 (FIPS 180-4) used to verify upgrade images locally
/// before they are staged on the router. Implemented in-package so the
/// kit stays dependency-free and fully testable against the standard
/// vectors.
public struct SHA256Hasher: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer = Data()
    private var totalLength: UInt64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        totalLength &+= UInt64(data.count)
        buffer.append(data)
        while buffer.count >= 64 {
            let block = buffer.prefix(64)
            compress(block)
            buffer.removeFirst(64)
        }
    }

    public mutating func finalize() -> Data {
        let bitLength = totalLength &* 8
        var padding = Data([0x80])
        while (buffer.count + padding.count) % 64 != 56 { padding.append(0) }
        buffer.append(padding)
        var lengthBytes = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            lengthBytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        buffer.append(lengthBytes)
        while buffer.count >= 64 {
            let block = buffer.prefix(64)
            compress(block)
            buffer.removeFirst(64)
        }
        var digest = Data()
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    public static func hash(_ data: Data) -> Data {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalize()
    }

    public static func hexDigest(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func compress(_ block: Data.SubSequence) {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var w = [UInt32](repeating: 0, count: 64)
        let bytes = [UInt8](block)
        for i in 0..<16 {
            w[i] = UInt32(bytes[i * 4]) << 24 | UInt32(bytes[i * 4 + 1]) << 16
                 | UInt32(bytes[i * 4 + 2]) << 8 | UInt32(bytes[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotated(right: 7) ^ w[i - 15].rotated(right: 18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotated(right: 17) ^ w[i - 2].rotated(right: 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = e.rotated(right: 6) ^ e.rotated(right: 11) ^ e.rotated(right: 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = a.rotated(right: 2) ^ a.rotated(right: 13) ^ a.rotated(right: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    func rotated(right: UInt32) -> UInt32 {
        (self >> right) | (self << (32 - right))
    }
}
