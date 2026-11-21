import Foundation

// MARK: - Package actions (audit F7)
//
// Package install / remove / upgrade go through the router's own
// package-manager helper — /usr/libexec/package-manager-call, the
// exact channel LuCI's software page uses (measured on-device
// 2026-11-21 on both managed routers: it accepts
// update|install|upgrade|remove, translates opkg vs apk itself and
// answers with a JSON {code, pkmcmd, stdout, stderr} document).
// The helper is reached through the same cgi-exec form channel as
// the installed-package list; package names are validated strictly
// before they are placed on its command line, so nothing a user
// types can become an extra argument, an option, or shell syntax.

public enum PackageActionKind: String, Equatable, Sendable {
    case update, install, upgrade, remove
}

public struct PackageActionOutcome: Equatable, Sendable {
    public var code: Int
    /// The exact manager command line the router ran (its own echo).
    public var commandLine: String?
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { code == 0 }

    public init(code: Int, commandLine: String? = nil, stdout: String = "", stderr: String = "") {
        self.code = code; self.commandLine = commandLine
        self.stdout = stdout; self.stderr = stderr
    }
}

public enum PackageActionParser {
    /// Parses the helper's JSON answer. A reply that is not the
    /// helper's document is a malformed response, never a success.
    public static func outcome(_ value: JSONValue) throws -> PackageActionOutcome {
        guard let code = value["code"].intValue else { throw OpenWrtKitError.malformedResponse }
        return PackageActionOutcome(
            code: code,
            commandLine: value["pkmcmd"].stringValue,
            stdout: value["stdout"].stringValue ?? "",
            stderr: value["stderr"].stringValue ?? "")
    }
}

public enum PackageNameValidator {
    /// OpenWrt package names: letters, digits, and - _ . + — never a
    /// leading dash (it would read as an option), never whitespace
    /// or shell metacharacters (the helper's command line is a
    /// single form field). Length-capped well above any real name.
    public static func isValid(_ name: String) -> Bool {
        // ASCII only — Character.isLetter would also admit CJK and
        // other scripts, which no package name ever contains.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+")
        guard name.count >= 1, name.count <= 128 else { return false }
        guard let first = name.first, allowed.contains(first), !"-_.+".contains(first) else { return false }
        return name.allSatisfy { allowed.contains($0) }
    }

    public static func requireValid(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else {
            throw OpenWrtKitError.unsupported(KitL10n.format("软件包名「%@」不合法：只能含字母、数字和 - _ . +，且须以字母或数字开头。", name))
        }
        return trimmed
    }
}

/// Extracts the package name from one upgradable-list line. The
/// two managers print different shapes — opkg: "name - old - new",
/// apk: "name-version arch [upgradable from: …]" — so the name is
/// recovered by longest-prefix match against the installed list
/// rather than by splitting, which would corrupt apk lines.
public enum UpgradableNameExtractor {
    public static func packageName(inLine line: String, installed: [String]) -> String? {
        installed
            .filter { line.hasPrefix($0 + " - ") || line.hasPrefix($0 + "-") || line == $0 }
            .max(by: { $0.count < $1.count })
    }
}

/// Runs package actions on the live session (via UbusCalling, so
/// session renewal stays single-sourced with every other plane).
public struct PackageActionClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    /// Validates every name first — a bad name fails the whole
    /// request before anything reaches the router.
    public func run(action: PackageActionKind, packages: [String] = []) async throws -> PackageActionOutcome {
        let validated = try packages.map(PackageNameValidator.requireValid)
        if action != .update, validated.isEmpty {
            throw OpenWrtKitError.unsupported(KitL10n.text("没有指定软件包。"))
        }
        return try await caller.packageManagerAction(action: action, packages: validated)
    }
}

// MARK: - UPnP active mappings (audit F5)
//
// miniupnpd's rpcd object luci.upnp answers get_status with
// {"rules": [...]} — measured live on the bypass router 2026-11-21
// (empty rules while UPnP is disabled there). Rule fields follow
// the LuCI consumer's vocabulary; the parser accepts the known
// spelling variants and keeps every raw field, so a firmware that
// spells a field differently still shows its data in the raw layer
// instead of dropping the rule.

public struct UPnPMapping: Equatable, Sendable, Identifiable {
    public var token: String?
    public var externalPort: Int?
    public var protocolName: String?
    public var internalAddress: String?
    public var internalPort: Int?
    public var mappingDescription: String?
    /// Every string field the router sent, verbatim (raw layer).
    public var fields: [String: String]

    public var id: String {
        token ?? [externalPort.map(String.init), internalAddress, internalPort.map(String.init)]
            .compactMap { $0 }.joined(separator: ":")
    }

    public init(token: String? = nil, externalPort: Int? = nil, protocolName: String? = nil,
                internalAddress: String? = nil, internalPort: Int? = nil,
                mappingDescription: String? = nil, fields: [String: String] = [:]) {
        self.token = token; self.externalPort = externalPort
        self.protocolName = protocolName; self.internalAddress = internalAddress
        self.internalPort = internalPort; self.mappingDescription = mappingDescription
        self.fields = fields
    }
}

public enum UPnPParser {
    public static func mappings(_ value: JSONValue) -> [UPnPMapping] {
        (value["rules"].arrayValue ?? []).map { rule in
            var fields: [String: String] = [:]
            if let object = rule.objectValue {
                for (key, field) in object {
                    if let text = field.stringValue { fields[key] = text }
                    else if let number = field.intValue { fields[key] = String(number) }
                    else if let flag = field.boolValue { fields[key] = flag ? "1" : "0" }
                }
            }
            func pick(_ keys: [String]) -> String? {
                for key in keys { if let found = fields[key] { return found } }
                return nil
            }
            return UPnPMapping(
                token: pick(["token"]),
                externalPort: pick(["extport", "ext_port", "external_port", "eport"]).flatMap(Int.init),
                protocolName: pick(["proto", "protocol"]),
                internalAddress: pick(["intaddr", "int_addr", "internal_addr", "internal_address", "host"]),
                internalPort: pick(["intport", "int_port", "internal_port", "iport"]).flatMap(Int.init),
                mappingDescription: pick(["descr", "desc", "description", "name"]),
                fields: fields)
        }
    }
}

// MARK: - SSH authorized keys (audit F4, second half)
//
// /etc/dropbear/authorized_keys: one public key per line, the file
// dropbear consults on every new SSH connection (measured present
// on both managed routers 2026-11-21). The app reads and rewrites
// it through the verified file plane; parsing keeps each line
// verbatim so a round-trip never reformats a key.

public enum AuthorizedKeys {
    public static let knownTypes = [
        "ssh-ed25519", "ssh-rsa", "ssh-dss",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// Key lines only — blank lines and comments are not keys and
    /// are dropped on rewrite (the file is machine-managed here).
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValidKeyLine($0) }
    }

    public static func serialize(_ keys: [String]) -> String {
        keys.isEmpty ? "" : keys.joined(separator: "\n") + "\n"
    }

    /// A key line is `<type> <base64> [comment…]`, optionally led by
    /// an options field — the type token is what identifies it.
    public static func isValidKeyLine(_ line: String) -> Bool {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        // The type may be the first token or follow an options token.
        for index in 0..<min(2, parts.count - 1) where knownTypes.contains(String(parts[index])) {
            let body = String(parts[index + 1])
            let base64 = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=")
            guard body.count >= 16, body.allSatisfy({ base64.contains($0) }) else { return false }
            return true
        }
        return false
    }

    /// Human label for one key line: its type plus the trailing
    /// comment when the user supplied one, else the key body's tail.
    public static func displayName(for line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let typeIndex = parts.firstIndex(where: { knownTypes.contains($0) }),
              typeIndex + 1 < parts.count else { return line }
        let type = parts[typeIndex]
        if parts.count > typeIndex + 2 {
            return "\(type) · \(parts[(typeIndex + 2)...].joined(separator: " "))"
        }
        return "\(type) · …\(parts[typeIndex + 1].suffix(8))"
    }
}

// MARK: - Admin security client (audit F4/F5)

/// Password change and UPnP status on the live session. The
/// password change goes through rpcd's luci.setPassword — the
/// router's own sanctioned channel, the same one LuCI's
/// administration page uses (measured present on both managed
/// routers 2026-11-21, signature {username, password}). The new
/// password travels as a call parameter only: it is never logged,
/// never stored by the kit, and the caller verifies it with a
/// fresh login before adopting it locally.
public struct AdminSecurityClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public func setPassword(username: String, password: String) async throws {
        _ = try await caller.call(object: "luci", method: "setPassword", parameters: [
            "username": .string(username), "password": .string(password)
        ])
    }

    /// Active UPnP port mappings. Throws when the router has no
    /// luci.upnp object (UPnP not installed) — the UI presents that
    /// as "no live-mapping channel", distinct from an empty list.
    public func upnpMappings() async throws -> [UPnPMapping] {
        UPnPParser.mappings(try await caller.call(object: "luci.upnp", method: "get_status"))
    }
}
