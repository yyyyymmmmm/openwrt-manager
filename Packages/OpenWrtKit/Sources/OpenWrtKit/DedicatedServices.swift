import Foundation

/// Data plane for the dedicated service pages (package F): ddns,
/// appfilter and Wake-on-LAN. The parsers are deliberately tolerant —
/// these ubus objects are provided by per-service rpcd plugins and
/// daemons whose payload nesting varies between builds — but every
/// field extracted here is one the service's own LuCI view consumes
/// (ddns overview.js / wol.js read the same keys), never an invented
/// shape. UCI-side write discovery works the same way: it locates the
/// option that actually holds a setting in the freshly read
/// configuration instead of assuming a section layout, and reports
/// "not found" so the page can degrade to read-only honestly.

// MARK: - Shared truthiness for UCI/ubus scalar forms

public enum DedicatedValue {
    /// UCI stores booleans as "1"/"0" strings, ubus plugins use real
    /// booleans or numbers; all three forms mean the same thing here.
    public static func truthy(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if let flag = value.boolValue { return flag }
        if let number = value.doubleValue { return number != 0 }
        if let text = value.stringValue {
            switch text.lowercased() {
            case "1", "true", "on", "yes", "enabled": return true
            case "0", "false", "off", "no", "disabled", "": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Dynamic DNS (luci.ddns)

public struct DDNSGlobalState: Equatable, Sendable {
    public var autostartEnabled: Bool?
    public var version: String?
    public var servicesListUpdated: String?
    public init(autostartEnabled: Bool? = nil, version: String? = nil, servicesListUpdated: String? = nil) {
        self.autostartEnabled = autostartEnabled
        self.version = version
        self.servicesListUpdated = servicesListUpdated
    }
}

public struct DDNSServiceRuntime: Identifiable, Equatable, Sendable {
    public var section: String
    public var ip: String?
    public var lastUpdate: String?
    /// Raw next-update token from the daemon: either a formatted time
    /// or one of the state words LuCI maps for display ("Verify",
    /// "Run once", "Disabled", "Stopped").
    public var nextUpdate: String?
    public var nextCheck: String?
    public var pid: Int?
    public var id: String { section }
    public var running: Bool { (pid ?? 0) > 0 }
    public init(section: String, ip: String? = nil, lastUpdate: String? = nil,
                nextUpdate: String? = nil, nextCheck: String? = nil, pid: Int? = nil) {
        self.section = section; self.ip = ip; self.lastUpdate = lastUpdate
        self.nextUpdate = nextUpdate; self.nextCheck = nextCheck; self.pid = pid
    }
}

public enum DDNSParser {
    /// luci.ddns get_ddns_state — the state object LuCI's overview
    /// reads its "_enabled" / "_version" / "_services_list" fields
    /// from.
    public static func globalState(_ value: JSONValue) -> DDNSGlobalState {
        DDNSGlobalState(
            autostartEnabled: DedicatedValue.truthy(value["_enabled"]),
            version: value["_version"].textValue,
            servicesListUpdated: value["_services_list"].textValue)
    }

    /// luci.ddns get_services_status — an object keyed by UCI section
    /// id; each entry carries ip / last_update / next_update /
    /// next_check / pid (the exact fields ddns overview.js renders).
    public static func servicesStatus(_ value: JSONValue) -> [DDNSServiceRuntime] {
        (value.objectValue ?? [:]).map { section, entry in
            DDNSServiceRuntime(
                section: section,
                ip: entry["ip"].textValue,
                lastUpdate: entry["last_update"].textValue,
                nextUpdate: entry["next_update"].textValue,
                nextCheck: entry["next_check"].textValue,
                pid: entry["pid"].intValue ?? entry["pid"].stringValue.flatMap(Int.init))
        }.sorted { $0.section < $1.section }
    }

    /// luci.ddns get_services_log — log lines for one service. The
    /// plugin's wrapping varies, so arrays are accepted at the top
    /// level or under the usual container keys, and a plain string is
    /// split into lines.
    public static func serviceLog(_ value: JSONValue) -> [String] {
        if let lines = value.arrayValue {
            return lines.compactMap { $0.stringValue ?? $0.textValue }
        }
        for key in ["log", "lines", "data", "entries"] where value[key] != .null {
            let lines = serviceLog(value[key])
            if !lines.isEmpty { return lines }
        }
        if let text = value.stringValue {
            return text.split(separator: "\n").map(String.init)
        }
        return []
    }
}

// MARK: - App filter (appfilter ubus object, OpenAppFilter daemon)

public struct AppFilterStatus: Equatable, Sendable {
    public var enabled: Bool?
    public init(enabled: Bool? = nil) { self.enabled = enabled }
}

public struct AppFilterClass: Identifiable, Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var apps: [String]
    public var id: String { identifier }
    public init(identifier: String, name: String, apps: [String] = []) {
        self.identifier = identifier; self.name = name; self.apps = apps
    }
}

public struct AppFilterClassVisit: Identifiable, Equatable, Sendable {
    public var name: String
    public var value: Int
    public var id: String { name }
    public init(name: String, value: Int) { self.name = name; self.value = value }
}

public struct AppFilterDeviceVisit: Identifiable, Equatable, Sendable {
    public var device: String
    public var visits: Int?
    public var durationSeconds: Int?
    public var id: String { device }
    public init(device: String, visits: Int? = nil, durationSeconds: Int? = nil) {
        self.device = device; self.visits = visits; self.durationSeconds = durationSeconds
    }
}

public enum AppFilterParser {
    /// appfilter get_oaf_status — the daemon's status object; the
    /// master switch has travelled under several key names.
    public static func status(_ value: JSONValue) -> AppFilterStatus {
        for key in ["enable", "enabled", "oaf_enable", "status"] {
            if let flag = DedicatedValue.truthy(value[key]) { return AppFilterStatus(enabled: flag) }
        }
        return AppFilterStatus(enabled: nil)
    }

    /// appfilter class_list — the category catalogue with the app
    /// names under each category.
    public static func classes(_ value: JSONValue) -> [AppFilterClass] {
        items(value, containerKeys: ["class_list", "classes", "list", "data"]).compactMap { item in
            let name = item["name"].stringValue ?? item["class"].stringValue
                ?? item["title"].stringValue ?? item["cname"].stringValue
            let identifier = item["id"].textValue ?? item["class_id"].textValue
                ?? item["cid"].textValue ?? name
            guard let identifier, !identifier.isEmpty else { return nil }
            let apps = (item["apps"].arrayValue ?? item["app_list"].arrayValue
                        ?? item["applications"].arrayValue ?? [])
                .compactMap { $0.stringValue ?? $0["name"].stringValue ?? $0["app_name"].stringValue }
            return AppFilterClass(identifier: identifier, name: name ?? identifier, apps: apps)
        }.sorted { $0.name < $1.name }
    }

    /// appfilter get_app_filter — the currently selected rule set, as
    /// the set of category identifiers it references.
    public static func selection(_ value: JSONValue) -> Set<String> {
        var identifiers = Set<String>()
        func absorb(_ item: JSONValue) {
            if let text = item.stringValue ?? item.textValue, !text.isEmpty {
                identifiers.insert(text); return
            }
            for key in ["id", "class", "class_id", "cid", "name", "appid", "app_id"] {
                if let text = item[key].textValue, !text.isEmpty { identifiers.insert(text); return }
            }
        }
        if let object = value.objectValue {
            for key in ["appfilter", "filter", "rules", "class", "classes", "list", "data"] {
                if let array = value[key].arrayValue { array.forEach(absorb) }
            }
            if identifiers.isEmpty {
                // A class -> bool map is also a plausible daemon form.
                for (key, flag) in object where DedicatedValue.truthy(flag) == true {
                    identifiers.insert(key)
                }
            }
        }
        (value.arrayValue ?? []).forEach(absorb)
        return identifiers
    }

    /// appfilter app_class_visit_time — per-category hit statistics.
    public static func classVisits(_ value: JSONValue) -> [AppFilterClassVisit] {
        var visits: [AppFilterClassVisit] = []
        if let object = value.objectValue, value.arrayValue == nil,
           object.values.allSatisfy({ $0.intValue != nil || $0.doubleValue != nil }) {
            visits = object.map { AppFilterClassVisit(name: $0.key, value: $0.value.intValue ?? 0) }
        } else {
            visits = items(value, containerKeys: ["list", "data", "classes", "class_list"]).compactMap { item in
                let name = item["name"].stringValue ?? item["class"].stringValue ?? item["title"].stringValue
                let count = item["count"].intValue ?? item["times"].intValue
                    ?? item["visit_time"].intValue ?? item["time"].intValue ?? item["num"].intValue
                guard let name, let count else { return nil }
                return AppFilterClassVisit(name: name, value: count)
            }
        }
        return visits.sorted { $0.value > $1.value }
    }

    /// appfilter dev_visit_list — per-device hit statistics.
    public static func deviceVisits(_ value: JSONValue) -> [AppFilterDeviceVisit] {
        items(value, containerKeys: ["list", "data", "devices", "dev_list"]).compactMap { item in
            let device = item["mac"].stringValue ?? item["ip"].stringValue
                ?? item["hostname"].stringValue ?? item["name"].stringValue ?? item["device"].stringValue
            guard let device, !device.isEmpty else { return nil }
            return AppFilterDeviceVisit(
                device: device,
                visits: item["count"].intValue ?? item["times"].intValue ?? item["num"].intValue,
                durationSeconds: item["duration"].intValue ?? item["total_time"].intValue
                    ?? item["visit_time"].intValue ?? item["time"].intValue)
        }.sorted { $0.device < $1.device }
    }

    private static func items(_ value: JSONValue, containerKeys: [String]) -> [JSONValue] {
        if let array = value.arrayValue { return array }
        for key in containerKeys {
            if let array = value[key].arrayValue { return array }
        }
        return []
    }
}

/// Locates the UCI storage a dedicated page writes through, from the
/// configuration actually read off the router. Nothing here assumes a
/// section exists: a miss is a first-class result the page renders as
/// "read-only, storage not recognised".
public enum DedicatedConfigDiscovery {
    public struct SwitchLocation: Equatable, Sendable {
        public var sectionID: String
        public var option: String
        public var current: Bool
        public init(sectionID: String, option: String, current: Bool) {
            self.sectionID = sectionID; self.option = option; self.current = current
        }
    }

    /// The first section (in configuration order) carrying one of the
    /// named boolean options — the appfilter master switch travels as
    /// "enable" in the daemon's global section.
    public static func booleanSwitch(in configuration: RouterConfiguration,
                                     options: [String]) -> SwitchLocation? {
        for section in configuration.sections {
            for option in options {
                if let value = section.values[option], let flag = DedicatedValue.truthy(value) {
                    return SwitchLocation(sectionID: section.id, option: option, current: flag)
                }
            }
        }
        return nil
    }

    public struct ListLocation: Equatable, Sendable {
        public var sectionID: String
        public var option: String
        public var values: [String]
        public init(sectionID: String, option: String, values: [String]) {
            self.sectionID = sectionID; self.option = option; self.values = values
        }
    }

    /// The list option whose values best overlap the known category
    /// identifiers — where the daemon persists its selected classes.
    /// Requires at least one overlapping value so an unrelated list is
    /// never mistaken for the rule set.
    public static func classListStorage(in configuration: RouterConfiguration,
                                        knownIdentifiers: Set<String>) -> ListLocation? {
        guard !knownIdentifiers.isEmpty else { return nil }
        var best: (location: ListLocation, overlap: Int)?
        for section in configuration.sections {
            for (option, value) in section.values {
                let values = (value.arrayValue ?? []).compactMap(\.stringValue)
                guard !values.isEmpty else { continue }
                let overlap = values.filter { knownIdentifiers.contains($0) }.count
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (ListLocation(sectionID: section.id, option: option, values: values), overlap)
                }
            }
        }
        return best?.location
    }
}

// MARK: - Wake-on-LAN (luci.wol)

public struct WolPrograms: Equatable, Sendable {
    public var etherwake: Bool
    public var wakeonlan: Bool
    public var anyAvailable: Bool { etherwake || wakeonlan }
    public init(etherwake: Bool = false, wakeonlan: Bool = false) {
        self.etherwake = etherwake; self.wakeonlan = wakeonlan
    }
}

public struct WolExecResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int?
    public var succeeded: Bool { code == nil || code == 0 }
    public init(stdout: String = "", stderr: String = "", code: Int? = nil) {
        self.stdout = stdout; self.stderr = stderr; self.code = code
    }
}

public enum WolParser {
    /// luci.wol stat — {etherwake: bool, wakeonlan: bool}, the exact
    /// shape the service's own view branches on.
    public static func programs(_ value: JSONValue) -> WolPrograms {
        WolPrograms(etherwake: DedicatedValue.truthy(value["etherwake"]) ?? false,
                    wakeonlan: DedicatedValue.truthy(value["wakeonlan"]) ?? false)
    }

    /// luci.wol exec — the rpcd result object wol.js renders:
    /// {stdout, stderr, code}.
    public static func execResult(_ value: JSONValue) -> WolExecResult {
        WolExecResult(stdout: value["stdout"].stringValue ?? "",
                      stderr: value["stderr"].stringValue ?? "",
                      code: value["code"].intValue)
    }
}

/// Builds the luci.wol exec request exactly the way the official
/// wol.js does: the binary is the configured default (the luci-wol
/// "defaults" section's executable option) when usable, otherwise the
/// available one; etherwake takes -D plus the optional -i/-b/-p
/// arguments, wakeonlan takes the bare MAC (it ignores the rest).
public enum WolWakeBuilder {
    public static let etherwakePath = "/usr/bin/etherwake"
    public static let wakeonlanPath = "/usr/bin/wakeonlan"

    public static func request(executable: String?, programs: WolPrograms,
                               mac: String, interface: String?,
                               broadcast: Bool, password: String?) -> (name: String, args: [String])? {
        var binary = executable ?? (programs.etherwake ? etherwakePath : wakeonlanPath)
        if binary == etherwakePath, !programs.etherwake { binary = wakeonlanPath }
        if binary == wakeonlanPath, !programs.wakeonlan { binary = etherwakePath }
        guard programs.anyAvailable else { return nil }
        if binary == etherwakePath {
            var args = ["-D"]
            if let interface, !interface.isEmpty { args += ["-i", interface] }
            if broadcast { args.append("-b") }
            if let password, !password.isEmpty { args += ["-p", password] }
            args.append(mac)
            return (name: binary, args: args)
        }
        return (name: binary, args: [mac])
    }
}

// MARK: - Client

/// Read/action plane for the dedicated service pages, on the same
/// session surface as every other component. The wol exec call is an
/// action, not a configuration write: it changes no router state and
/// is confirmed in the UI before it runs.
public struct DedicatedServiceClient: Sendable {
    private let caller: any UbusCalling

    public init(caller: any UbusCalling) {
        self.caller = caller
    }

    public func ddnsServicesStatus() async throws -> [DDNSServiceRuntime] {
        DDNSParser.servicesStatus(try await caller.call(object: "luci.ddns", method: "get_services_status"))
    }

    public func ddnsGlobalState() async throws -> DDNSGlobalState {
        DDNSParser.globalState(try await caller.call(object: "luci.ddns", method: "get_ddns_state"))
    }

    public func ddnsServiceLog(service: String) async throws -> [String] {
        DDNSParser.serviceLog(try await caller.call(object: "luci.ddns", method: "get_services_log",
                                                    parameters: ["service_name": .string(service)]))
    }

    public func appfilterStatus() async throws -> AppFilterStatus {
        AppFilterParser.status(try await caller.call(object: "appfilter", method: "get_oaf_status"))
    }

    public func appfilterClasses() async throws -> [AppFilterClass] {
        AppFilterParser.classes(try await caller.call(object: "appfilter", method: "class_list"))
    }

    public func appfilterSelection() async throws -> Set<String> {
        AppFilterParser.selection(try await caller.call(object: "appfilter", method: "get_app_filter"))
    }

    public func appfilterClassVisits() async throws -> [AppFilterClassVisit] {
        AppFilterParser.classVisits(try await caller.call(object: "appfilter", method: "app_class_visit_time"))
    }

    public func appfilterDeviceVisits() async throws -> [AppFilterDeviceVisit] {
        AppFilterParser.deviceVisits(try await caller.call(object: "appfilter", method: "dev_visit_list"))
    }

    public func wolPrograms() async throws -> WolPrograms {
        WolParser.programs(try await caller.call(object: "luci.wol", method: "stat"))
    }

    public func wolExec(name: String, args: [String]) async throws -> WolExecResult {
        WolParser.execResult(try await caller.call(object: "luci.wol", method: "exec",
                                                   parameters: ["name": .string(name),
                                                                "args": .array(args.map(JSONValue.string))]))
    }
}
