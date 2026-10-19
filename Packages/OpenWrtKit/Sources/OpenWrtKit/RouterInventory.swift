import Foundation

public struct InstalledPackage: Identifiable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let description: String
    public let dependencies: [String]
    public let files: [String]
    public var id: String { name }

    public init(name: String, version: String, description: String = "", dependencies: [String] = [], files: [String] = []) {
        self.name = name; self.version = version; self.description = description
        self.dependencies = dependencies; self.files = files
    }
}

public struct RouterMenuEntry: Identifiable, Equatable, Sendable {
    public let path: [String]
    public let title: String
    public let order: Int
    public let configs: [String]
    public let aclGroups: [String]
    public let children: [RouterMenuEntry]
    public var id: String { path.joined(separator: "/") }
    public var group: String { path.dropFirst().first ?? "" }
    public var descendants: [RouterMenuEntry] { children.flatMap { [$0] + $0.descendants } }

    public init(path: [String], title: String, order: Int = 100, configs: [String] = [], aclGroups: [String] = [], children: [RouterMenuEntry] = []) {
        self.path = path; self.title = title; self.order = order
        self.configs = configs; self.aclGroups = aclGroups; self.children = children
    }
}

public struct InitService: Identifiable, Equatable, Sendable {
    public let name: String
    public let enabled: Bool?
    public var id: String { name }
    public init(name: String, enabled: Bool?) { self.name = name; self.enabled = enabled }
}

public struct InstalledPlugin: Identifiable, Equatable, Sendable {
    public let package: InstalledPackage
    public let menus: [RouterMenuEntry]
    public let configs: [String]
    public let serviceNames: [String]
    public var id: String { package.name }
    public var title: String { menus.first?.title ?? String(package.name.dropFirst("luci-app-".count)) }
}

public struct RouterInventory: Sendable {
    public var packages: [InstalledPackage] = []
    public var menus: [RouterMenuEntry] = []
    public var configNames: [String] = []
    public var initServices: [InitService] = []
    public var warnings: [String] = []
    public var packagesRead = false
    public var menuRead = false
    public var configsRead = false
    public var initRead = false
    public init() {}

    public var allMenus: [RouterMenuEntry] { menus.flatMap { [$0] + $0.descendants } }
    public func menu(_ id: String) -> RouterMenuEntry? { allMenus.first { $0.id == id } }

    public var plugins: [InstalledPlugin] {
        let byName = Dictionary(packages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return packages.filter { $0.name.hasPrefix("luci-app-") }.map { package in
            let matches = allMenus.filter { $0.aclGroups.contains(package.name) }
            let roots = matches.filter { item in !matches.contains { parent in item.id.hasPrefix(parent.id + "/") } }
            var visited = Set<String>()
            var files = Set<String>()
            func collect(_ name: String) {
                guard visited.insert(name).inserted, let value = byName[name] else { return }
                files.formUnion(value.files.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 })
                for dependency in value.dependencies {
                    let key = dependency.components(separatedBy: CharacterSet(charactersIn: "<>=~ ")).first ?? dependency
                    // Shared platform packages do not belong to each plugin's settings.
                    if !["luci-base", "luci-compat", "rpcd", "uci", "ubus", "libc"].contains(key) { collect(key) }
                }
            }
            collect(package.name)
            let menuConfigs = matches.flatMap(\.configs)
            let fileConfigs = files.filter { $0.hasPrefix("etc/config/") }.map { String($0.dropFirst(11)) }
            let configs = Set(menuConfigs + fileConfigs).intersection(Set(configNames)).sorted()
            let services = files.filter { $0.hasPrefix("etc/init.d/") }.map { String($0.dropFirst(11)) }.sorted()
            return InstalledPlugin(package: package, menus: roots, configs: configs, serviceNames: services)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

public enum InventoryParser {
    public static func packages(_ value: JSONValue) throws -> [InstalledPackage] {
        guard let array = value.arrayValue else { throw OpenWrtKitError.malformedResponse }
        return try array.map { item in
            guard let name = item["name"].stringValue, let version = item["version"].stringValue,
                  !name.isEmpty else { throw OpenWrtKitError.malformedResponse }
            return InstalledPackage(name: name, version: version, description: item["description"].stringValue ?? "",
                                    dependencies: (item["depends"].arrayValue ?? []).compactMap(\.stringValue),
                                    files: (item["contents"].arrayValue ?? []).compactMap(\.stringValue))
        }.sorted { $0.name < $1.name }
    }

    public static func opkg(_ text: String) throws -> [InstalledPackage] {
        let rows = text.split(whereSeparator: \.isNewline)
        let values = rows.compactMap { row -> InstalledPackage? in
            let fields = row.components(separatedBy: " - ")
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            return InstalledPackage(name: fields[0], version: fields[1], description: fields.dropFirst(2).joined(separator: " - "))
        }
        guard !values.isEmpty || rows.isEmpty else { throw OpenWrtKitError.malformedResponse }
        return values.sorted { $0.name < $1.name }
    }

    public static func menus(_ value: JSONValue) throws -> [RouterMenuEntry] {
        let admin = value["children"]["admin"]
        guard admin["children"].objectValue != nil, admin["satisfied"].boolValue != false else {
            throw OpenWrtKitError.permissionDenied
        }
        func children(_ node: JSONValue, path: [String]) -> [RouterMenuEntry] {
            (node["children"].objectValue ?? [:]).compactMap { key, child -> RouterMenuEntry? in
                guard child["satisfied"].boolValue != false, child["wildcard"].boolValue != true,
                      !["logout", "uci", "ubus", "menu", "translations"].contains(key),
                      validIdentifier(key), let title = child["title"].stringValue, !title.isEmpty,
                      child["action"]["post"].boolValue != true else { return nil }
                let current = path + [key]
                let configs = Array((child["depends"]["uci"].objectValue ?? [:]).keys).sorted()
                return RouterMenuEntry(path: current, title: title, order: child["order"].intValue ?? 100,
                                       configs: configs, aclGroups: (child["depends"]["acl"].arrayValue ?? []).compactMap(\.stringValue),
                                       children: children(child, path: current))
            }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        }
        return children(admin, path: ["admin"])
    }

    public static func initServices(_ value: JSONValue) throws -> [InitService] {
        guard let object = value.objectValue else { throw OpenWrtKitError.malformedResponse }
        return object.map {
            let value = $0.value["enabled"]
            return InitService(name: $0.key, enabled: value.boolValue ?? value.intValue.map { $0 != 0 })
        }.sorted { $0.name < $1.name }
    }

    public static func configNames(_ value: JSONValue) throws -> [String] {
        guard let entries = value["entries"].arrayValue else { throw OpenWrtKitError.malformedResponse }
        return entries.compactMap { item in
            guard item["type"].stringValue == "file", let name = item["name"].stringValue,
                  validIdentifier(name) else { return nil }
            return name
        }.sorted()
    }

    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
}
