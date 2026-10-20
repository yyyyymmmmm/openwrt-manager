import Foundation

/// An allowlist, never a path supplied by a view or a router menu.
public enum RouterSystemFile: String, CaseIterable, Sendable {
    case sshKeys, localStartup, sysupgradeFiles
    case mosDNSWhitelist, mosDNSBlocklist, mosDNSGreylist, mosDNSDDNS, mosDNSHosts, mosDNSRedirect, mosDNSLocalPTR, mosDNSStreaming, mosDNSCustom
    public static let mosDNSRules: [Self] = [.mosDNSWhitelist, .mosDNSBlocklist, .mosDNSGreylist, .mosDNSDDNS, .mosDNSHosts, .mosDNSRedirect, .mosDNSLocalPTR, .mosDNSStreaming]
    public var path: String {
        switch self {
        case .sshKeys: return "/etc/dropbear/authorized_keys"
        case .localStartup: return "/etc/rc.local"
        case .sysupgradeFiles: return "/etc/sysupgrade.conf"
        case .mosDNSCustom: return "/etc/mosdns/config_custom.yaml"
        default: return "/etc/mosdns/rule/" + ruleFilename
        }
    }
    private var ruleFilename: String {
        switch self {
        case .mosDNSWhitelist: return "whitelist.txt"
        case .mosDNSBlocklist: return "blocklist.txt"
        case .mosDNSGreylist: return "greylist.txt"
        case .mosDNSDDNS: return "ddnslist.txt"
        case .mosDNSHosts: return "hosts.txt"
        case .mosDNSRedirect: return "redirect.txt"
        case .mosDNSLocalPTR: return "local-ptr.txt"
        case .mosDNSStreaming: return "streaming.txt"
        default: return ""
        }
    }
    public var title: String {
        switch self {
        case .sshKeys: return "SSH 公钥"
        case .localStartup: return "本地启动脚本"
        case .sysupgradeFiles: return "备份包含文件"
        case .mosDNSWhitelist: return "白名单"
        case .mosDNSBlocklist: return "黑名单"
        case .mosDNSGreylist: return "灰名单"
        case .mosDNSDDNS: return "DDNS 域名"
        case .mosDNSHosts: return "Hosts"
        case .mosDNSRedirect: return "域名重定向"
        case .mosDNSLocalPTR: return "阻止 PTR"
        case .mosDNSStreaming: return "流媒体域名"
        case .mosDNSCustom: return "自定义 YAML"
        }
    }
    public var explanation: String {
        switch self {
        case .sshKeys: return "OpenSSH 授权公钥。"
        case .localStartup: return "/etc/rc.local 会在系统启动末尾执行。请把自定义命令放在 exit 0 之前；保存只写入文件，不会立即执行其中命令。"
        case .sysupgradeFiles: return "每行填写一个要额外包含在配置备份中的绝对路径，可保留注释；保存后重新读取备份清单核对实际包含的文件。"
        case .mosDNSWhitelist: return "默认配置规则：由本地 DNS 解析，优先级最高。每行一条，保留 MosDNS 匹配语法。"
        case .mosDNSBlocklist: return "默认配置规则：阻止匹配域名解析。每行一条，保留 MosDNS 匹配语法。"
        case .mosDNSGreylist: return "默认配置规则：使用远程 DNS 解析。每行一条。"
        case .mosDNSDDNS: return "默认配置规则：使用本地 DNS，TTL 5 秒且不缓存。每行一个匹配项。"
        case .mosDNSHosts: return "默认配置规则：每行填写域名与 IP，以空格分隔。以当前 MosDNS 版本支持的语法为准。"
        case .mosDNSRedirect: return "默认配置规则：每行填写源域名与目标域名，以空格分隔。"
        case .mosDNSLocalPTR: return "默认配置规则：阻止匹配的 PTR 反向查询。每行一条。"
        case .mosDNSStreaming: return "默认配置规则：通过已配置的流媒体专用 DNS 解析匹配域名。"
        case .mosDNSCustom: return "完整自定义 MosDNS YAML。只有配置文件选用此路径时才会加载；默认配置的规则页不能保证被该 YAML 引用。App 不会伪造 YAML 或插件语义校验。"
        }
    }
    public var savedExplanation: String {
        switch self {
        case .localStartup: return "启动脚本已写入并重读核对；保存不会立即执行脚本。"
        case .sshKeys: return "公钥文件已写入并重读一致；实际 SSH 认证仍需核对。"
        case .sysupgradeFiles: return "备份包含文件已写入并重读一致；请重新生成备份清单核对。"
        default: return "文件已写入并重读一致。请到 MosDNS 系统服务重启，再检查运行日志和实际 DNS 解析；保存不代表规则已生效。"
        }
    }
    var parent: String { (path as NSString).deletingLastPathComponent }
    var name: String { (path as NSString).lastPathComponent }
    var limit: Int { self == .localStartup || self == .sysupgradeFiles ? 65_536 : 1_048_576 }

    public func prepared(_ text: String) throws -> String {
        guard !text.contains("\0"), text.utf8.count <= limit else {
            throw OpenWrtKitError.unsupported("文件不能包含 NUL，且不能超过 \(limit / 1024) KiB。")
        }
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !unix.contains("\r") else { throw OpenWrtKitError.unsupported("请使用 Unix 换行。") }
        let prepared = unix.isEmpty || unix.hasSuffix("\n") ? unix : unix + "\n"
        guard prepared.utf8.count <= limit else { throw OpenWrtKitError.unsupported("补齐末尾换行后文件超过大小限制。") }
        return prepared
    }
}

public struct RouterSystemFileSnapshot: Equatable, Sendable {
    public let file: RouterSystemFile
    /// nil is confirmed absence, never a failed read.
    public let contents: String?
    public init(file: RouterSystemFile, contents: String?) { self.file = file; self.contents = contents }
}

struct RouterSystemFileClient: Sendable {
    let client: UbusClient
    let session: UbusSession

    func read(_ file: RouterSystemFile) async throws -> RouterSystemFileSnapshot {
        do {
            let value = try await client.call(session: session, object: "file", method: "read", parameters: ["path": .string(file.path)])
            guard let text = value["data"].stringValue, !text.contains("\0"), text.utf8.count <= file.limit else {
                throw OpenWrtKitError.unsupported("响应不是可编辑的文本或超过大小限制；未开放覆盖。")
            }
            return RouterSystemFileSnapshot(file: file, contents: text)
        } catch {
            let readError = error
            guard let failure = error as? OpenWrtKitError, case .unsupported = failure else { throw error }
            do {
                let directory = try await client.call(session: session, object: "file", method: "list", parameters: ["path": .string(file.parent)])
                guard let entries = directory["entries"].arrayValue,
                      entries.allSatisfy({ $0["name"].stringValue != nil }),
                      !entries.contains(where: { $0["name"].stringValue == file.name }) else { throw readError }
                return RouterSystemFileSnapshot(file: file, contents: nil)
            } catch { throw readError }
        }
    }

    func writable(_ file: RouterSystemFile) async throws -> Bool {
        let method = try await access(scope: "ubus", object: "file", function: "write")
        let path = try await access(scope: "file", object: file.path, function: "write")
        return method && path
    }

    func save(observed: RouterSystemFileSnapshot, text: String) async throws -> RouterSystemFileSnapshot {
        let file = observed.file
        let prepared = try file.prepared(text)
        if file == .sshKeys {
            _ = try SSHAuthorizedKeysSnapshot(text: observed.contents ?? "").validateMutation(prepared)
        }
        guard try await writable(file) else { throw OpenWrtKitError.permissionDenied }
        guard try await read(file) == observed else {
            throw OpenWrtKitError.unsupported("路由器文件已变化，未写入。请保留草稿并重新读取后合并。")
        }
        try Task.checkCancellation()
        do {
            var parameters: [String: JSONValue] = ["path": .string(file.path), "data": .string(prepared), "append": .bool(false)]
            if file == .sshKeys { parameters["mode"] = .number(384) }
            _ = try await client.call(session: session, object: "file", method: "write", parameters: parameters)
            let saved = try await read(file)
            guard saved.contents == prepared else { throw OpenWrtKitError.unsupported("写入后重读内容与提交内容不同。") }
            return saved
        } catch {
            throw OpenWrtKitError.unsupported("文件写入或重读结果未确认：\(error.localizedDescription)。文件可能已经改变；请保留草稿并重新读取，不要直接重试。")
        }
    }

    private func access(scope: String, object: String, function: String) async throws -> Bool {
        let value = try await client.call(session: session, object: "session", method: "access", parameters: [
            "scope": .string(scope), "object": .string(object), "function": .string(function)
        ])
        guard let allowed = value["access"].boolValue else { throw OpenWrtKitError.malformedResponse }
        return allowed
    }
}
