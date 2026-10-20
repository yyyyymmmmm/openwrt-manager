import Foundation

public enum PackageBackend: String, Sendable { case apk = "APK", opkg = "opkg" }

public struct PackageListSnapshot: Sendable {
    public let backend: PackageBackend
    public let packages: [InstalledPackage]
    public let readAt: Date

    public init(data: Data, installed: Bool) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw OpenWrtKitError.malformedResponse }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenWrtKitError.unsupported("软件包接口没有返回清单。可能尚未更新软件源、helper 执行失败或包数据库不可读；不能据此推定软件包数量为 0。")
        }
        if trimmed.hasPrefix("[") {
            backend = .apk
            packages = try InventoryParser.packages(JSONDecoder().decode(JSONValue.self, from: data))
        } else {
            // An empty opkg repository list is valid; HTML, errors and arbitrary
            // command output must never become a successful empty inventory.
            guard trimmed.hasPrefix("Package:") else { throw OpenWrtKitError.malformedResponse }
            backend = .opkg
            packages = try Self.opkgControl(text, installed: installed)
        }
        readAt = Date()
    }

    private static func opkgControl(_ text: String, installed: Bool) throws -> [InstalledPackage] {
        var records: [[String: String]] = [], fields: [String: String] = [:], lastKey: String?
        func finish() {
            if !fields.isEmpty { records.append(fields) }
            fields = [:]; lastKey = nil
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.isEmpty { finish(); continue }
            if raw.first == " " || raw.first == "\t" {
                guard let key = lastKey else { throw OpenWrtKitError.malformedResponse }
                fields[key, default: ""] += "\n" + raw.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { throw OpenWrtKitError.malformedResponse }
            let key = raw[..<colon].lowercased()
            guard !key.isEmpty, fields[key] == nil else { throw OpenWrtKitError.malformedResponse }
            fields[key] = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        finish()
        var result: [String: InstalledPackage] = [:]
        for record in records {
            guard let name = record["package"], PackageOperation.validName(name),
                  let version = record["version"], !version.isEmpty else { throw OpenWrtKitError.malformedResponse }
            if installed {
                guard let status = record["status"] else { throw OpenWrtKitError.malformedResponse }
                if status.split(separator: " ").last != "installed" { continue }
            }
            let dependencies = (record["depends"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result[name] = InstalledPackage(name: name, version: version, description: record["description"] ?? "",
                dependencies: dependencies, essential: record["essential"] == "yes", architecture: record["architecture"],
                installedSize: record["installed-size"].flatMap(Int64.init), downloadSize: record["size"].flatMap(Int64.init))
        }
        return result.values.sorted { $0.name < $1.name }
    }
}

public enum PackageOperation: Equatable, Sendable {
    public static let helper = "/usr/libexec/package-manager-call"
    case updateLists, install(String), upgrade(String), remove(String)
    public var name: String? {
        switch self { case .updateLists: return nil; case .install(let name), .upgrade(let name), .remove(let name): return name }
    }
    public var title: String {
        switch self { case .updateLists: return "更新软件源清单"; case .install: return "安装"; case .upgrade: return "升级"; case .remove: return "卸载" }
    }
    public var removesPackage: Bool { if case .remove = self { return true }; return false }
    public func command() throws -> String {
        let verb: String
        switch self { case .updateLists: verb = "update"; case .install: verb = "install"; case .upgrade: verb = "upgrade"; case .remove: verb = "remove" }
        if let name {
            guard Self.validName(name) else { throw PackageOperationError.invalidName }
            return Self.helper + " " + verb + " " + name
        }
        return Self.helper + " " + verb
    }
    public static func validName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), let first = name.utf8.first,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }
    }
}

public enum PackageOperationError: LocalizedError, Sendable {
    case invalidName, changed, essential, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "软件包名称无效；只允许固件返回的包名，不接受路径、URL 或命令参数。"
        case .changed: return "软件包清单已变化。请重新读取并查看当前版本，再重新确认操作。"
        case .essential: return "此软件包被固件标记为必需组件，不能从这里卸载。"
        case .uncertain(let detail): return "操作结果未确认：\(detail)。请求可能已经执行，请先重新读取清单和检查路由器日志，不要直接重复提交。"
        }
    }
}

public struct PackageOperationResult: Sendable {
    public let output: RouterCommandResult
    public let command: String?
    public init(data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        output = try RouterCommandResult(value: value)
        guard value["pkmcmd"] == .null || value["pkmcmd"].stringValue != nil else { throw OpenWrtKitError.malformedResponse }
        command = value["pkmcmd"].stringValue
    }
}
