import Foundation

/// A validated OpenSSH authorized_keys line. Keep the source row verbatim:
/// options and comments affect the meaning of a key and must not be rewritten.
public struct SSHAuthorizedKey: Identifiable, Equatable, Sendable {
    public let raw: String
    public let algorithm: String
    public let comment: String?
    public let lineNumber: Int
    public var id: String { "\(lineNumber):\(raw)" }

    public init(raw: String, algorithm: String, comment: String?, lineNumber: Int = 0) {
        self.raw = raw
        self.algorithm = algorithm
        self.comment = comment
        self.lineNumber = lineNumber
    }
}

public struct SSHAuthorizedKeysSnapshot: Equatable, Sendable {
    public let text: String
    public let keys: [SSHAuthorizedKey]
    /// Rows not recognized as supported OpenSSH public keys remain visible and
    /// are preserved verbatim. They are never silently dropped on save.
    public struct UnrecognizedRow: Equatable, Sendable, Identifiable {
        public let lineNumber: Int
        public let text: String
        public var id: Int { lineNumber }
    }
    public let unrecognizedRows: [UnrecognizedRow]

    public init(text: String) throws {
        guard !text.contains("\0"), text.utf8.count <= 1_048_576 else {
            throw OpenWrtKitError.unsupported("SSH 公钥文件不是可编辑的文本，或超过 1 MiB。")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { throw OpenWrtKitError.malformedResponse }
        self.text = text
        var parsed: [SSHAuthorizedKey] = []
        var unrecognized: [UnrecognizedRow] = []
        for (index, raw) in normalized.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            do {
                let key = try Self.parseLine(raw)
                parsed.append(SSHAuthorizedKey(raw: key.raw, algorithm: key.algorithm, comment: key.comment, lineNumber: index + 1))
            } catch {
                unrecognized.append(UnrecognizedRow(lineNumber: index + 1, text: raw))
            }
        }
        self.keys = parsed
        self.unrecognizedRows = unrecognized
    }

    /// Add a newly validated key without changing any existing row.
    public func adding(_ rawKey: String) throws -> String {
        let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.contains("\n"), !normalizedKey.contains("\r"),
              !normalizedKey.contains("\0") else { throw OpenWrtKitError.malformedResponse }
        _ = try Self.parseLine(normalizedKey)
        guard !keys.contains(where: { $0.raw == normalizedKey }) else {
            throw OpenWrtKitError.unsupported("这条 SSH 公钥已经存在。")
        }
        let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        let prepared = prefix + normalizedKey + "\n"
        guard prepared.utf8.count <= 1_048_576 else { throw OpenWrtKitError.unsupported("SSH 公钥文件超过 1 MiB。") }
        return prepared
    }

    /// Remove only the selected, validated row; comments, blank rows and
    /// unrecognized existing lines are copied unchanged.
    public func removing(_ key: SSHAuthorizedKey) throws -> String {
        guard keys.contains(where: { $0.id == key.id }) else {
            throw OpenWrtKitError.unsupported("所选公钥不属于当前读取的文件，请重新读取。")
        }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard key.lineNumber > 0, key.lineNumber <= rows.count,
              rows[key.lineNumber - 1] == key.raw else {
            throw OpenWrtKitError.unsupported("公钥文件行号已变化，请重新读取后再删除。")
        }
        var updated = rows
        updated.remove(at: key.lineNumber - 1)
        let prepared = updated.joined(separator: "\n")
        guard prepared.utf8.count <= 1_048_576 else { throw OpenWrtKitError.unsupported("SSH 公钥文件超过 1 MiB。") }
        return prepared
    }

    public static func prepared(_ text: String) throws -> String {
        guard !text.contains("\0"), text.utf8.count <= 1_048_576 else {
            throw OpenWrtKitError.unsupported("SSH 公钥文件不能包含 NUL，且不能超过 1 MiB。")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { throw OpenWrtKitError.unsupported("请使用 Unix 换行。") }
        let prepared = normalized.isEmpty || normalized.hasSuffix("\n") ? normalized : normalized + "\n"
        guard prepared.utf8.count <= 1_048_576 else { throw OpenWrtKitError.unsupported("补齐末尾换行后的 SSH 公钥文件超过 1 MiB。") }
        return prepared
    }

    /// Protect existing unsupported lines from a malformed or hand-edited
    /// mutation. This manager only adds or removes validated key rows.
    func validateMutation(_ proposed: String) throws -> String {
        let prepared = try Self.prepared(proposed)
        let next = try Self(text: prepared)
        let oldOpaque = opaqueRows(text)
        let newOpaque = opaqueRows(next.text)
        guard oldOpaque == newOpaque else {
            throw OpenWrtKitError.unsupported("原有注释、空行或未识别内容被改动；为避免丢失路由器数据，未保存。")
        }
        return prepared
    }

    private func opaqueRows(_ source: String) -> [String] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        // A terminal newline is normalized on save, not an opaque content row.
        let body = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized
        return body.isEmpty ? [] : body.components(separatedBy: "\n").filter { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || (try? Self.parseLine(row)) == nil
        }
    }

    public static func parseLine(_ line: String) throws -> SSHAuthorizedKey {
        guard !line.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }), line.utf8.count <= 1_048_576 else { throw OpenWrtKitError.malformedResponse }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(?:(?:[^\s=,]+)(?:=(?:[^\s\",]+|\"(?:[^\"\\]|\\.)*\"))?)(?:,(?:[^\s=,]+)(?:=(?:[^\s\",]+|\"(?:[^\"\\]|\\.)*\"))?)*[ \t]+)?(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|sk-ssh-ed25519@openssh\.com)[ \t]+([^ \t]+)(?:[ \t]+(.*))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let typeRange = Range(match.range(at: 1), in: trimmed),
              let dataRange = Range(match.range(at: 2), in: trimmed) else { throw OpenWrtKitError.malformedResponse }
        let algorithm = String(trimmed[typeRange])
        let encoded = String(trimmed[dataRange])
        guard encoded.utf8.count >= 4, encoded.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil,
              let data = Data(base64Encoded: encoded), data.count >= 4 else {
            throw OpenWrtKitError.malformedResponse
        }
        var offset = 0
        func readString() -> Data? {
            guard offset + 4 <= data.count else { return nil }
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4
            guard length >= 1, length <= data.count - offset else { return nil }
            let result = data[offset..<(offset + length)]; offset += length
            return Data(result)
        }
        guard let wireType = readString(), String(data: wireType, encoding: .utf8) == algorithm else { throw OpenWrtKitError.malformedResponse }
        if algorithm.contains("ed25519") {
            guard readString()?.count == 32 else { throw OpenWrtKitError.malformedResponse }
            if algorithm.hasPrefix("sk-") { guard readString() != nil else { throw OpenWrtKitError.malformedResponse } }
        } else if algorithm.contains("ecdsa") {
            let curve = algorithm.contains("384") ? "nistp384" : algorithm.contains("521") ? "nistp521" : "nistp256"
            guard let curveData = readString(), String(data: curveData, encoding: .utf8) == curve,
                  let point = readString(), point.first == 4, point.count == (curve == "nistp256" ? 65 : curve == "nistp384" ? 97 : 133) else { throw OpenWrtKitError.malformedResponse }
            if algorithm.hasPrefix("sk-") { guard readString() != nil else { throw OpenWrtKitError.malformedResponse } }
        } else {
            for _ in 0..<(algorithm == "ssh-rsa" ? 2 : 4) {
                guard readString() != nil else { throw OpenWrtKitError.malformedResponse }
            }
        }
        guard offset == data.count else { throw OpenWrtKitError.malformedResponse }
        let comment = Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) }
        return SSHAuthorizedKey(raw: line, algorithm: algorithm, comment: comment?.isEmpty == true ? nil : comment)
    }
}

