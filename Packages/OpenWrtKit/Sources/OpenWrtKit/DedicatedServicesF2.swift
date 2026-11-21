import Foundation

/// Data plane for the package-F2 dedicated service pages (frpc,
/// natmap, socat, zerotier, webdav). All five are UCI-shaped services:
/// the gap inventory verified the configurations are readable through
/// the session's uci grant on the bypass router, but none of them has
/// a verified live-status channel beyond the init.d state the
/// discovery snapshot already carries — so this layer only shapes the
/// configuration the router actually reports. Extractors are tolerant
/// about option aliases (each service's LuCI app has renamed options
/// across versions) and strict about one thing: a value that is not
/// in the configuration is never invented, and secret options are
/// recognised by name so the app layer can mask them everywhere,
/// including raw dumps.

// MARK: - Secret option recognition

public enum DedicatedSecret {
    /// Option names that carry credentials. Matched as substrings so
    /// variants (auth_token, oidc_client_secret, user_pass) are all
    /// covered; a hit means "a value exists", never the value itself.
    private static let markers = ["password", "passwd", "pwd", "token",
                                  "secret", "credential", "auth_key", "private_key"]

    public static func isSecretOption(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// Whether the named option is present with a non-empty value.
    public static func isSet(_ section: ConfigurationSection, optionNames: [String]) -> Bool {
        for name in optionNames {
            guard let value = section.values[name] else { continue }
            if let text = value.stringValue, !text.isEmpty { return true }
            if value.arrayValue?.isEmpty == false { return true }
            if value.boolValue != nil || value.doubleValue != nil { return true }
        }
        return false
    }
}

private func firstText(_ section: ConfigurationSection, _ names: [String]) -> String? {
    for name in names {
        if let text = section.values[name]?.stringValue ?? section.values[name]?.textValue,
           !text.isEmpty { return text }
    }
    return nil
}

private func firstBool(_ section: ConfigurationSection, _ names: [String]) -> Bool? {
    for name in names {
        if let flag = DedicatedValue.truthy(section.values[name]) { return flag }
    }
    return nil
}

// MARK: - frpc (FRP client)

public struct FrpcServer: Equatable, Sendable {
    public var sectionID: String
    public var address: String?
    public var port: String?
    public var hasToken: Bool
    public init(sectionID: String, address: String? = nil, port: String? = nil, hasToken: Bool = false) {
        self.sectionID = sectionID; self.address = address; self.port = port; self.hasToken = hasToken
    }
    /// "host:port" when both halves are known, whichever half exists
    /// otherwise; nil when the server is not configured at all.
    public var endpointText: String? {
        switch (address, port) {
        case let (host?, port?): return "\(host):\(port)"
        case let (host?, nil): return host
        case let (nil, port?): return port
        case (nil, nil): return nil
        }
    }
}

public struct FrpcTunnel: Identifiable, Equatable, Sendable {
    public var sectionID: String
    public var name: String
    public var enabled: Bool?
    public var type: String?
    public var localIP: String?
    public var localPort: String?
    public var remotePort: String?
    public var domains: [String]
    public var id: String { sectionID }
    public init(sectionID: String, name: String, enabled: Bool? = nil, type: String? = nil,
                localIP: String? = nil, localPort: String? = nil,
                remotePort: String? = nil, domains: [String] = []) {
        self.sectionID = sectionID; self.name = name; self.enabled = enabled; self.type = type
        self.localIP = localIP; self.localPort = localPort
        self.remotePort = remotePort; self.domains = domains
    }
    /// The local endpoint the tunnel forwards from, "ip:port" shaped.
    public var localText: String? {
        switch (localIP, localPort) {
        case let (ip?, port?): return "\(ip):\(port)"
        case let (ip?, nil): return ip
        case let (nil, port?): return port
        case (nil, nil): return nil
        }
    }
}

public struct FrpcOverview: Equatable, Sendable {
    public var server: FrpcServer?
    public var tunnels: [FrpcTunnel]
    public init(server: FrpcServer? = nil, tunnels: [FrpcTunnel] = []) {
        self.server = server; self.tunnels = tunnels
    }
}

public enum FrpcParser {
    /// luci-app-frpc stores the server in the section named "common"
    /// (type "conf"); every other section of the file is one tunnel.
    /// Builds that rename the common section are recognised by the
    /// server options themselves.
    public static func parse(_ configuration: RouterConfiguration) -> FrpcOverview {
        let serverSection = configuration.sections.first { $0.id == "common" || $0.type == "common" }
            ?? configuration.sections.first {
                $0.values["server_addr"] != nil || $0.values["server_address"] != nil
            }
        var server: FrpcServer?
        if let section = serverSection {
            server = FrpcServer(
                sectionID: section.id,
                address: firstText(section, ["server_addr", "server_address", "addr", "server"]),
                port: firstText(section, ["server_port", "port"]),
                hasToken: DedicatedSecret.isSet(section, optionNames: [
                    "token", "auth_token", "auth/token", "oidc_client_secret", "secret"
                ]))
        }
        let tunnels = configuration.sections
            .filter { $0.id != serverSection?.id }
            .map { section in
                FrpcTunnel(
                    sectionID: section.id,
                    name: firstText(section, ["name", "remarks", "remark"]) ?? section.id,
                    enabled: firstBool(section, ["enabled", "enable"]),
                    type: firstText(section, ["type", "proto", "protocol"]),
                    localIP: firstText(section, ["local_ip", "local_addr", "local_address"]),
                    localPort: firstText(section, ["local_port"]),
                    remotePort: firstText(section, ["remote_port"]),
                    domains: (section.values["custom_domains"]?.arrayValue
                              ?? section.values["custom_domain"]?.arrayValue ?? [])
                        .compactMap { $0.stringValue }
                        + [firstText(section, ["subdomain", "custom_domain"])].compactMap { $0 })
            }
        return FrpcOverview(server: server, tunnels: tunnels)
    }
}

// MARK: - NATMap

public struct NatmapEntry: Identifiable, Equatable, Sendable {
    public var sectionID: String
    public var enabled: Bool?
    public var stunServer: String?
    /// The port the daemon keeps mapped (the config's port option).
    public var port: String?
    /// The keep-alive target the daemon pings (http_server in the
    /// daemon's own naming).
    public var keepAliveTarget: String?
    public var family: String?
    public var id: String { sectionID }
    public init(sectionID: String, enabled: Bool? = nil, stunServer: String? = nil,
                port: String? = nil, keepAliveTarget: String? = nil, family: String? = nil) {
        self.sectionID = sectionID; self.enabled = enabled; self.stunServer = stunServer
        self.port = port; self.keepAliveTarget = keepAliveTarget; self.family = family
    }
}

public enum NatmapParser {
    public static func parse(_ configuration: RouterConfiguration) -> [NatmapEntry] {
        configuration.sections.map { section in
            NatmapEntry(
                sectionID: section.id,
                enabled: firstBool(section, ["enable", "enabled"]),
                stunServer: firstText(section, ["stun_server", "stunserver", "stun"]),
                port: firstText(section, ["port", "map_port", "public_port", "bind_port"]),
                keepAliveTarget: firstText(section, ["http_server", "keep_alive", "keepalive", "url"]),
                family: firstText(section, ["family", "ip_family"]))
        }
    }
}

// MARK: - Socat (config luci_socat)

public struct SocatRule: Identifiable, Equatable, Sendable {
    public var sectionID: String
    public var remarks: String?
    public var enabled: Bool?
    public var `protocol`: String?
    public var listenPort: String?
    public var destIP: String?
    public var destPort: String?
    public var id: String { sectionID }
    public init(sectionID: String, remarks: String? = nil, enabled: Bool? = nil,
                protocol: String? = nil, listenPort: String? = nil,
                destIP: String? = nil, destPort: String? = nil) {
        self.sectionID = sectionID; self.remarks = remarks; self.enabled = enabled
        self.protocol = `protocol`; self.listenPort = listenPort
        self.destIP = destIP; self.destPort = destPort
    }
    /// The destination endpoint, "ip:port" shaped.
    public var destinationText: String? {
        switch (destIP, destPort) {
        case let (ip?, port?): return "\(ip):\(port)"
        case let (ip?, nil): return ip
        case let (nil, port?): return port
        case (nil, nil): return nil
        }
    }
}

public enum SocatParser {
    public static func parse(_ configuration: RouterConfiguration) -> [SocatRule] {
        configuration.sections.map { section in
            SocatRule(
                sectionID: section.id,
                remarks: firstText(section, ["remarks", "remark", "name", "comment"]),
                enabled: firstBool(section, ["enable", "enabled"]),
                protocol: firstText(section, ["protocol", "proto"]),
                listenPort: firstText(section, ["listen_port", "port"]),
                destIP: firstText(section, ["dest_ip", "remote_ip", "target_ip", "dest_addr"]),
                destPort: firstText(section, ["dest_port", "remote_port", "target_port"]))
        }
    }
}

// MARK: - ZeroTier (UCI layer only)

public struct ZeroTierNetwork: Identifiable, Equatable, Sendable {
    public var networkID: String
    /// Where the membership is stored, so the page can remove exactly
    /// this entry: a whole section, or one value of a list option.
    public enum Storage: Equatable, Sendable {
        case section(id: String)
        case listValue(sectionID: String, option: String)
    }
    public var storage: Storage
    public var allowManaged: Bool?
    public var allowGlobal: Bool?
    public var allowDefault: Bool?
    public var allowDNS: Bool?
    public var id: String { networkID }
    public init(networkID: String, storage: Storage, allowManaged: Bool? = nil,
                allowGlobal: Bool? = nil, allowDefault: Bool? = nil, allowDNS: Bool? = nil) {
        self.networkID = networkID; self.storage = storage
        self.allowManaged = allowManaged; self.allowGlobal = allowGlobal
        self.allowDefault = allowDefault; self.allowDNS = allowDNS
    }
    public var hasAllowFlags: Bool {
        allowManaged != nil || allowGlobal != nil || allowDefault != nil || allowDNS != nil
    }
}

public struct ZeroTierOverview: Equatable, Sendable {
    public var enabled: Bool?
    public var switchLocation: DedicatedConfigDiscovery.SwitchLocation?
    public var networks: [ZeroTierNetwork]
    /// Where a join should write when no network exists yet: the
    /// existing list option if that is the file's form, otherwise a
    /// new "network" section.
    public var joinTarget: JoinTarget
    public enum JoinTarget: Equatable, Sendable {
        case newSection
        case listOption(sectionID: String, option: String)
    }
    public init(enabled: Bool? = nil,
                switchLocation: DedicatedConfigDiscovery.SwitchLocation? = nil,
                networks: [ZeroTierNetwork] = [], joinTarget: JoinTarget = .newSection) {
        self.enabled = enabled; self.switchLocation = switchLocation
        self.networks = networks; self.joinTarget = joinTarget
    }
}

public enum ZeroTierParser {
    /// Two storage forms exist in the wild and both are honoured: one
    /// "network" section per joined network (carrying the allow_*
    /// flags), and a "network" list option on the service section.
    /// The node secret is never read into the model — only its
    /// presence could matter, and no page here needs it.
    public static func parse(_ configuration: RouterConfiguration) -> ZeroTierOverview {
        let switchLocation = DedicatedConfigDiscovery.booleanSwitch(
            in: configuration, options: ["enabled", "enable"])
        var networks: [ZeroTierNetwork] = []
        var listTarget: ZeroTierOverview.JoinTarget?
        for section in configuration.sections where section.type == "network" {
            guard let networkID = firstText(section, ["id", "network_id", "nwid"]), !networkID.isEmpty
            else { continue }
            networks.append(ZeroTierNetwork(
                networkID: networkID,
                storage: .section(id: section.id),
                allowManaged: firstBool(section, ["allow_managed", "allowManaged"]),
                allowGlobal: firstBool(section, ["allow_global", "allowGlobal"]),
                allowDefault: firstBool(section, ["allow_default", "allowDefault"]),
                allowDNS: firstBool(section, ["allow_dns", "allowDNS"])))
        }
        for section in configuration.sections {
            guard let values = section.values["network"]?.arrayValue else { continue }
            let ids = values.compactMap { $0.stringValue }.filter { !$0.isEmpty }
            guard !ids.isEmpty else { continue }
            if listTarget == nil {
                listTarget = .listOption(sectionID: section.id, option: "network")
            }
            for networkID in ids where !networks.contains(where: { $0.networkID == networkID }) {
                networks.append(ZeroTierNetwork(
                    networkID: networkID,
                    storage: .listValue(sectionID: section.id, option: "network")))
            }
        }
        networks.sort { $0.networkID < $1.networkID }
        return ZeroTierOverview(
            enabled: switchLocation?.current,
            switchLocation: switchLocation,
            networks: networks,
            joinTarget: listTarget ?? .newSection)
    }

    /// ZeroTier network IDs are 16 hexadecimal digits; anything else
    /// is rejected before it can reach a plan.
    public static func isValidNetworkID(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.count == 16 && trimmed.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - WebDAV (configuration layer; running state has no source)

public struct WebdavSettings: Equatable, Sendable {
    public var sectionID: String
    public var enabled: Bool?
    public var listenPort: String?
    public var rootDir: String?
    public var ssl: Bool?
    public var allowWAN: Bool?
    public var username: String?
    public var hasPassword: Bool
    public init(sectionID: String, enabled: Bool? = nil, listenPort: String? = nil,
                rootDir: String? = nil, ssl: Bool? = nil, allowWAN: Bool? = nil,
                username: String? = nil, hasPassword: Bool = false) {
        self.sectionID = sectionID; self.enabled = enabled; self.listenPort = listenPort
        self.rootDir = rootDir; self.ssl = ssl; self.allowWAN = allowWAN
        self.username = username; self.hasPassword = hasPassword
    }
}

public enum WebdavParser {
    /// The settings live in the first section carrying any of the
    /// known options; other sections (shares and the like) stay in
    /// the raw layer only.
    public static func parse(_ configuration: RouterConfiguration) -> WebdavSettings? {
        let known = ["enable", "enabled", "listen_port", "root_dir", "ssl", "allow_wan"]
        guard let section = configuration.sections.first(where: { section in
            section.type == "webdav" || known.contains { section.values[$0] != nil }
        }) else { return nil }
        return WebdavSettings(
            sectionID: section.id,
            enabled: firstBool(section, ["enable", "enabled"]),
            listenPort: firstText(section, ["listen_port", "port"]),
            rootDir: firstText(section, ["root_dir", "root", "path"]),
            ssl: firstBool(section, ["ssl", "use_ssl", "https"]),
            allowWAN: firstBool(section, ["allow_wan", "wan_access", "allow_remote"]),
            username: firstText(section, ["username", "user", "account"]),
            hasPassword: DedicatedSecret.isSet(section, optionNames: ["password", "passwd", "pass"]))
    }
}
