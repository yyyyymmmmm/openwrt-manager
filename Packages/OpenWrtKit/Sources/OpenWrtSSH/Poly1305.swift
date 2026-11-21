/// Poly1305 one-time authenticator (RFC 8439 §2.5), implemented in the
/// radix-2^26 form used by the reference poly1305-donna design.
///
/// swift-crypto exposes Poly1305 only inside its RFC 8439 AEAD
/// (ChaChaPoly), whose key schedule cannot be reused for the OpenSSH
/// chacha20-poly1305 construction: there, the one-time Poly1305 key is
/// the first 32 bytes of the ChaCha20 block-0 keystream. This small,
/// self-contained implementation fills exactly that gap and is pinned
/// down by the RFC 8439 §2.5.2 test vector in the test suite.
enum Poly1305 {
    /// Computes the 16-byte Poly1305 tag of `message` under the 32-byte
    /// one-time key (r || s). The caller must never reuse a key.
    static func authenticate(key: [UInt8], message: [UInt8]) -> [UInt8] {
        precondition(key.count == 32, "Poly1305 key must be 32 bytes")

        func load32(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
            UInt64(bytes[offset])
                | UInt64(bytes[offset + 1]) << 8
                | UInt64(bytes[offset + 2]) << 16
                | UInt64(bytes[offset + 3]) << 24
        }

        // r, clamped, split into 26-bit limbs.
        let t0 = load32(key, 0), t1 = load32(key, 4), t2 = load32(key, 8), t3 = load32(key, 12)
        let r0 = t0 & 0x3ff_ffff
        let r1 = ((t0 >> 26) | (t1 << 6)) & 0x3ff_ff03
        let r2 = ((t1 >> 20) | (t2 << 12)) & 0x3ff_c0ff
        let r3 = ((t2 >> 14) | (t3 << 18)) & 0x3f0_3fff
        let r4 = (t3 >> 8) & 0x00f_ffff
        let s1 = r1 &* 5, s2 = r2 &* 5, s3 = r3 &* 5, s4 = r4 &* 5

        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
        let mask: UInt64 = 0x3ff_ffff

        var offset = 0
        while offset < message.count {
            let blockLength = min(16, message.count - offset)
            var block = [UInt8](repeating: 0, count: 16)
            block.replaceSubrange(0..<blockLength, with: message[offset..<(offset + blockLength)])
            if blockLength < 16 {
                block[blockLength] = 1  // the appended 2^(8L) marker byte
            }
            let bt0 = load32(block, 0), bt1 = load32(block, 4), bt2 = load32(block, 8), bt3 = load32(block, 12)
            h0 &+= bt0 & mask
            h1 &+= ((bt0 >> 26) | (bt1 << 6)) & mask
            h2 &+= ((bt1 >> 20) | (bt2 << 12)) & mask
            h3 &+= ((bt2 >> 14) | (bt3 << 18)) & mask
            h4 &+= bt3 >> 8
            if blockLength == 16 {
                h4 &+= 1 << 24  // the appended 2^128 bit
            }

            let d0 = h0 &* r0 &+ h1 &* s4 &+ h2 &* s3 &+ h3 &* s2 &+ h4 &* s1
            var d1 = h0 &* r1 &+ h1 &* r0 &+ h2 &* s4 &+ h3 &* s3 &+ h4 &* s2
            var d2 = h0 &* r2 &+ h1 &* r1 &+ h2 &* r0 &+ h3 &* s4 &+ h4 &* s3
            var d3 = h0 &* r3 &+ h1 &* r2 &+ h2 &* r1 &+ h3 &* r0 &+ h4 &* s4
            var d4 = h0 &* r4 &+ h1 &* r3 &+ h2 &* r2 &+ h3 &* r1 &+ h4 &* r0

            var c = d0 >> 26; h0 = d0 & mask
            d1 &+= c; c = d1 >> 26; h1 = d1 & mask
            d2 &+= c; c = d2 >> 26; h2 = d2 & mask
            d3 &+= c; c = d3 >> 26; h3 = d3 & mask
            d4 &+= c; c = d4 >> 26; h4 = d4 & mask
            h0 &+= c &* 5; c = h0 >> 26; h0 &= mask; h1 &+= c

            offset += blockLength
        }

        // Full carry.
        var c = h1 >> 26; h1 &= mask; h2 &+= c
        c = h2 >> 26; h2 &= mask; h3 &+= c
        c = h3 >> 26; h3 &= mask; h4 &+= c
        c = h4 >> 26; h4 &= mask; h0 &+= c &* 5
        c = h0 >> 26; h0 &= mask; h1 &+= c

        // Compute h + -p, select h if h < p else h - p (constant-time
        // style branch-free selection, as in the reference design).
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        let g4 = h4 &+ c &- (1 << 26)
        // g4's top bit is set iff h < p (the subtraction borrowed).
        let selectG: UInt64 = (g4 >> 63) &- 1  // all-ones iff h >= p
        let selectH: UInt64 = ~selectG
        h0 = (h0 & selectH) | (g0 & selectG)
        h1 = (h1 & selectH) | (g1 & selectG)
        h2 = (h2 & selectH) | (g2 & selectG)
        h3 = (h3 & selectH) | (g3 & selectG)
        h4 = (h4 & selectH) | (g4 & selectG)

        // Serialize h (mod 2^128) and add s.
        var f0 = UInt32(truncatingIfNeeded: h0 | (h1 << 26))
        var f1 = UInt32(truncatingIfNeeded: (h1 >> 6) | (h2 << 20))
        var f2 = UInt32(truncatingIfNeeded: (h2 >> 12) | (h3 << 14))
        var f3 = UInt32(truncatingIfNeeded: (h3 >> 18) | (h4 << 8))

        var acc = UInt64(f0) &+ load32(key, 16)
        f0 = UInt32(truncatingIfNeeded: acc)
        acc = UInt64(f1) &+ load32(key, 20) &+ (acc >> 32)
        f1 = UInt32(truncatingIfNeeded: acc)
        acc = UInt64(f2) &+ load32(key, 24) &+ (acc >> 32)
        f2 = UInt32(truncatingIfNeeded: acc)
        acc = UInt64(f3) &+ load32(key, 28) &+ (acc >> 32)
        f3 = UInt32(truncatingIfNeeded: acc)

        var tag = [UInt8]()
        tag.reserveCapacity(16)
        for word in [f0, f1, f2, f3] {
            tag.append(UInt8(truncatingIfNeeded: word))
            tag.append(UInt8(truncatingIfNeeded: word >> 8))
            tag.append(UInt8(truncatingIfNeeded: word >> 16))
            tag.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return tag
    }
}
