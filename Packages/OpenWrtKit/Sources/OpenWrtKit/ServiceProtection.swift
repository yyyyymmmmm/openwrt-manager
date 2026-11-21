/// Safety policy for service actions (full audit 2026-11-21, F1).
///
/// A small set of init.d services carries the router's management
/// plane and basic connectivity. Stopping one of them — or turning
/// off its autostart and rebooting — can lock a phone-only user out
/// of every management channel at once (the app and LuCI share the
/// rpcd/ubus backend; network/dnsmasq carry the LAN itself). LuCI's
/// startup page allows these actions without distinction; this app
/// does not: for core services the destructive pair (stop, disable
/// autostart) is blocked outright, with the reason shown in place.
/// Start, restart and enable-autostart stay available — restart is
/// the standard recovery gesture and enable only ever restores the
/// safe state. The judgment is a pure function of the init.d service
/// name so every surface (service page, startup page, the store's
/// own guard) applies exactly the same rule.
public enum ServiceImpact: String, Equatable, Sendable {
    /// rpcd / ubusd / uhttpd / dropbear: the management plane itself.
    case management
    /// network: all connectivity.
    case network
    /// dnsmasq: name resolution and address assignment for the LAN.
    case dns
    /// firewall: the packet filter.
    case firewall
}

public enum ServiceProtection {
    /// The core list, by init.d service name. It is deliberately
    /// short and closed: a service joins it only when losing it
    /// removes the user's ability to manage or reach the router.
    /// Both audited routers (.1's 26 init-fallback services and
    /// .167's menu services) were checked against it: every name
    /// here exists in at least one real init.d directory, and no
    /// audited day-to-day service (openbox, mosdns, ddns, …) is on
    /// it — stopping those is recoverable and stays allowed.
    private static let coreImpacts: [String: ServiceImpact] = [
        "rpcd": .management,
        "ubusd": .management,
        "uhttpd": .management,
        "dropbear": .management,
        "network": .network,
        "dnsmasq": .dns,
        "firewall": .firewall,
    ]

    /// The impact category of a core service, or nil for a standard
    /// service with no special protection.
    public static func impact(forServiceNamed name: String) -> ServiceImpact? {
        coreImpacts[name]
    }

    public static func isCoreService(_ name: String) -> Bool {
        coreImpacts[name] != nil
    }

    /// Whether an action is blocked for a service: stop and
    /// disable-autostart on a core service. Everything else —
    /// including stop/disable on standard services and restart on
    /// core services — is allowed (behind the usual confirmation).
    public static func isBlocked(action: ServiceAction, forServiceNamed name: String) -> Bool {
        guard isCoreService(name) else { return false }
        return action == .stop || action == .disable
    }
}
