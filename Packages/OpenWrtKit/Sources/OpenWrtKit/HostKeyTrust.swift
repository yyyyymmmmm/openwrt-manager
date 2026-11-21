import Foundation

// MARK: - SSH host-key trust (package C, item 5)
//
// Trust-on-first-use for the terminal's SSH channel, with the same
// discipline OpenSSH applies: the first fingerprint a router presents
// must be confirmed by the user before it is trusted; a later key that
// matches connects silently; a later key that differs BLOCKS the
// connection until the user explicitly re-trusts. The store is a pure
// value type — the app persists it as JSON (fingerprints are public
// identifiers, not secrets, so they do not belong in the Keychain).

public enum HostKeyFingerprint {
    /// The human-comparable form of a SHA-256 host-key fingerprint:
    /// OpenSSH's `SHA256:<base64>` rendering of the raw digest. The
    /// SSH layer reports the digest as hex; anything that is not a
    /// 32-byte hex digest is returned unchanged rather than mangled.
    public static func displayForm(hexDigest: String) -> String {
        let hex = hexDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return hexDigest }
        var bytes = Data()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return hexDigest }
            bytes.append(byte)
            index = next
        }
        let base64 = bytes.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    /// Canonical storage form: lowercase hex, whitespace stripped.
    public static func canonical(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct HostKeyTrustStore: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Identifiable, Sendable {
        /// "host:port", host lowercased — the trust scope. The same
        /// router at a different address is a different trust decision.
        public var endpoint: String
        /// Canonical hex SHA-256 of the trusted host key.
        public var fingerprint: String
        public var trustedAt: Date
        public var id: String { endpoint }
        public init(endpoint: String, fingerprint: String, trustedAt: Date) {
            self.endpoint = endpoint; self.fingerprint = fingerprint; self.trustedAt = trustedAt
        }
        public var displayFingerprint: String { HostKeyFingerprint.displayForm(hexDigest: fingerprint) }
    }

    public private(set) var records: [Record] = []
    public init() {}

    public static func endpoint(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    public func record(host: String, port: Int) -> Record? {
        let endpoint = Self.endpoint(host: host, port: port)
        return records.first { $0.endpoint == endpoint }
    }

    public enum Verdict: Equatable, Sendable {
        /// No trust on file: the presented key must be confirmed by
        /// the user before it is trusted (first use).
        case firstUse(presented: String)
        /// The presented key is the trusted key.
        case match
        /// The presented key differs from the trusted key. The
        /// connection must be blocked; re-trusting is a separate,
        /// explicit user action.
        case changed(trusted: String, presented: String)
    }

    public func evaluate(host: String, port: Int, presentedFingerprint: String) -> Verdict {
        let presented = HostKeyFingerprint.canonical(presentedFingerprint)
        guard let record = record(host: host, port: port) else {
            return .firstUse(presented: presented)
        }
        return record.fingerprint == presented
            ? .match
            : .changed(trusted: record.fingerprint, presented: presented)
    }

    /// Records (or replaces) trust for one endpoint. Called only from
    /// an explicit user confirmation — never implicitly on connect.
    public mutating func trust(host: String, port: Int, fingerprint: String, at: Date = Date()) {
        let endpoint = Self.endpoint(host: host, port: port)
        let record = Record(endpoint: endpoint,
                            fingerprint: HostKeyFingerprint.canonical(fingerprint),
                            trustedAt: at)
        if let index = records.firstIndex(where: { $0.endpoint == endpoint }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.endpoint < $1.endpoint }
    }

    public mutating func revoke(host: String, port: Int) {
        let endpoint = Self.endpoint(host: host, port: port)
        records.removeAll { $0.endpoint == endpoint }
    }
}
