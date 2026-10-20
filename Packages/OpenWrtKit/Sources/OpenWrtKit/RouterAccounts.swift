import Foundation

public enum RouterAccountKind: String, CaseIterable, Identifiable, Sendable {
    case unix, rpcd
    public var id: String { rawValue }
    public var title: String { self == .unix ? "路由器账户" : "rpcd 账户" }
}

public struct RouterAccount: Identifiable, Equatable, Sendable {
    public let username: String
    public let kind: RouterAccountKind
    public var id: String { kind.rawValue + ":" + username }
    public init(username: String, kind: RouterAccountKind) { self.username = username; self.kind = kind }
}

public struct RouterPasswordPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let minimumLength: Int?
    public let digits: Bool
    public let mixedCase: Bool
    public let specialCharacters: Bool

    static func parse(_ section: ConfigurationSection?) throws -> Self {
        func flag(_ name: String) throws -> Bool {
            guard let value = section?.values[name] else { return false }
            guard let text = value.stringValue, ["0", "1"].contains(text) else { throw OpenWrtKitError.malformedResponse }
            return text == "1"
        }
        let enabled = try flag("enabled")
        var minimumLength: Int?
        if let value = section?.values["pw_length"] {
            guard let text = value.stringValue, let number = Int(text), number > 0, number <= 4096 else { throw OpenWrtKitError.malformedResponse }
            minimumLength = number
        }
        return try Self(enabled: enabled, minimumLength: minimumLength, digits: flag("digits"),
                        mixedCase: flag("uc_lc"), specialCharacters: flag("special_characters"))
    }

    public func validate(_ password: String) throws {
        guard !password.isEmpty, password.utf8.count <= 4096,
              !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw RouterPasswordError.invalid("密码不能为空，不能包含换行或 NUL，且不能超过 4096 字节。")
        }
        guard enabled else { return }
        if let minimumLength, password.count < minimumLength { throw RouterPasswordError.invalid("密码至少需要 \(minimumLength) 个字符。") }
        if digits, password.rangeOfCharacter(from: .decimalDigits) == nil { throw RouterPasswordError.invalid("固件密码策略要求包含数字。") }
        if mixedCase, password.rangeOfCharacter(from: .uppercaseLetters) == nil || password.rangeOfCharacter(from: .lowercaseLetters) == nil {
            throw RouterPasswordError.invalid("固件密码策略要求同时包含大写和小写字母。")
        }
        if specialCharacters, password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
            throw RouterPasswordError.invalid("固件密码策略要求包含特殊字符。")
        }
    }
}

public struct RouterAccountsSnapshot: Equatable, Sendable {
    public let accounts: [RouterAccount]
    public let policy: RouterPasswordPolicy?
    public let issues: [String]
    public let writable: Bool?
}

/// Password failures never interpolate a server message, request or password.
public enum RouterPasswordError: LocalizedError, Equatable, Sendable {
    case invalid(String), permissionDenied, changed, rejected, unavailable, uncertain
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .permissionDenied: return "当前账户没有修改密码的权限。"
        case .changed: return "账户或密码策略已变化，请重新读取后再提交。"
        case .rejected: return "固件未接受密码修改，请核对旧密码、账户类型与密码策略。"
        case .unavailable: return "无法核对账户或密码策略，未发送修改请求。请重新读取。"
        case .uncertain: return "密码请求结果未确认，密码可能已经改变。不要重复提交，请用新密码重新登录核对；失败时再核对旧密码。"
        }
    }
}

struct RouterAccountsClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read() async -> RouterAccountsSnapshot {
        var accounts: [RouterAccount] = [], issues: [String] = []
        var policy: RouterPasswordPolicy?, writable: Bool?
        do {
            let value = try await client.call(session: session, object: "file", method: "read", parameters: ["path": .string("/etc/passwd")])
            guard let text = value["data"].stringValue, !text.contains("\0"), text.utf8.count <= 1_048_576 else { throw OpenWrtKitError.malformedResponse }
            let rows = text.split(separator: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
            var unixAccounts: [RouterAccount] = []
            for row in rows {
                let fields = row.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 7, Self.validUsername(String(fields[0])) else { throw OpenWrtKitError.malformedResponse }
                unixAccounts.append(RouterAccount(username: String(fields[0]), kind: .unix))
            }
            accounts.append(contentsOf: unixAccounts)
        } catch { issues.append("路由器账户：" + error.localizedDescription) }
        do {
            let configuration = try await RouterConfigurationClient(client: client, session: session).read("rpcd")
            var rpcAccounts: [RouterAccount] = []
            for entry in configuration.sections where entry.type == "login" {
                guard let name = entry.values["username"]?.stringValue, Self.validUsername(name) else { throw OpenWrtKitError.malformedResponse }
                // LuCI manages root via the Unix password, not a new rpcd root record.
                if name != "root" { rpcAccounts.append(RouterAccount(username: name, kind: .rpcd)) }
            }
            policy = try RouterPasswordPolicy.parse(configuration.sections.first { $0.id == "policy" })
            accounts.append(contentsOf: rpcAccounts)
        } catch { issues.append("rpcd 账户与密码策略：" + error.localizedDescription) }
        do { writable = try await access() }
        catch { issues.append("密码写入权限：" + error.localizedDescription) }
        return RouterAccountsSnapshot(accounts: Array(Set(accounts.map(\.id))).sorted().compactMap { id in accounts.first { $0.id == id } },
                                      policy: policy, issues: issues, writable: writable)
    }

    func change(account: RouterAccount, observedPolicy: RouterPasswordPolicy, password: String, oldPassword: String) async throws {
        try observedPolicy.validate(password)
        guard Self.validUsername(account.username), !oldPassword.contains("\0"), oldPassword.utf8.count <= 4096 else {
            throw RouterPasswordError.invalid("账户名称或旧密码格式无效。")
        }
        if account.kind == .rpcd, oldPassword.isEmpty { throw RouterPasswordError.invalid("修改已有 rpcd 账户需要旧密码。") }
        let current = await read()
        guard current.writable == true else {
            if current.writable == false { throw RouterPasswordError.permissionDenied }
            throw RouterPasswordError.unavailable
        }
        guard current.accounts.contains(account), let policy = current.policy else { throw RouterPasswordError.unavailable }
        guard policy == observedPolicy else { throw RouterPasswordError.changed }
        try policy.validate(password)
        try Task.checkCancellation()
        let value: JSONValue
        do {
            value = try await client.call(session: session, object: "luci", method: "setPassword", parameters: [
                "username": .string(account.username), "password": .string(password),
                "oldpassword": .string(oldPassword), "rpcd": .bool(account.kind == .rpcd)
            ])
        } catch OpenWrtKitError.permissionDenied { throw RouterPasswordError.permissionDenied }
        catch { throw RouterPasswordError.uncertain }
        if value["result"] == .bool(false) || value["result"] == .number(0) { throw RouterPasswordError.rejected }
        guard value["result"] == .bool(true) || value["result"] == .number(1) else { throw RouterPasswordError.uncertain }
    }

    private func access() async throws -> Bool {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string("ubus"), "object": .string("luci"), "function": .string("setPassword")
        ])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }

    private static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\0" })
    }
}
