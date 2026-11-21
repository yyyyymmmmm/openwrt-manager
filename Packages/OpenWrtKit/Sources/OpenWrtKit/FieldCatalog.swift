import Foundation

/// Human labels and value kinds for well-known UCI options (phase 3:
/// generic-page coverage upgrade). Generic pages and the editor consult
/// this catalog so a discovered service's page reads as structured fields
/// — label, boolean toggle, enum — instead of raw option keys. Unknown
/// options keep their raw key; the catalog only ever annotates, it never
/// hides data.
public enum FieldValueKind: Equatable, Sendable {
    case text, boolean, number, list, enumeration([String])
}

public struct FieldDescriptor: Equatable, Sendable {
    public var label: String
    public var kind: FieldValueKind
    public init(label: String, kind: FieldValueKind = .text) {
        self.label = label; self.kind = kind
    }
}

public enum FieldCatalog {
    /// Keyed by "<config>.<option>" first, then bare "<option>" for
    /// options whose meaning is stable across configs.
    public static let fields: [String: FieldDescriptor] = [
        // Common
        "enabled": .init(label: "启用", kind: .boolean),
        "disabled": .init(label: "禁用", kind: .boolean),
        "name": .init(label: "名称"),
        "type": .init(label: "类型"),
        "port": .init(label: "端口", kind: .number),
        "ports": .init(label: "端口", kind: .list),
        "server": .init(label: "服务器"),
        "username": .init(label: "用户名"),
        "password": .init(label: "密码"),
        "interface": .init(label: "接口"),
        "proto": .init(label: "协议"),
        "ipaddr": .init(label: "IP 地址"),
        "netmask": .init(label: "子网掩码"),
        "gateway": .init(label: "网关"),
        "dns": .init(label: "DNS 服务器", kind: .list),
        "macaddr": .init(label: "MAC 地址"),
        "hostname": .init(label: "主机名"),
        "description": .init(label: "描述"),
        "log_level": .init(label: "日志级别"),
        // DHCP / dnsmasq
        "dhcp.start": .init(label: "地址池起始"),
        "dhcp.limit": .init(label: "地址池数量", kind: .number),
        "dhcp.leasetime": .init(label: "租约时间"),
        "dhcp.ignore": .init(label: "忽略此接口", kind: .boolean),
        "dhcp.dynamicdhcp": .init(label: "动态 DHCP", kind: .boolean),
        "host.mac": .init(label: "MAC 地址"),
        "host.ip": .init(label: "IPv4 地址"),
        "host.name": .init(label: "主机名"),
        "dnsmasq.domainneeded": .init(label: "需要域名", kind: .boolean),
        "dnsmasq.boguspriv": .init(label: "过滤私有地址反查", kind: .boolean),
        "dnsmasq.filterwin2k": .init(label: "过滤无用包", kind: .boolean),
        "dnsmasq.localise_queries": .init(label: "本地化查询", kind: .boolean),
        "dnsmasq.readethers": .init(label: "读取 /etc/ethers", kind: .boolean),
        "dnsmasq.expandhosts": .init(label: "扩展主机名", kind: .boolean),
        "dnsmasq.nonegcache": .init(label: "不缓存负结果", kind: .boolean),
        "dnsmasq.authoritative": .init(label: "权威模式", kind: .boolean),
        "dnsmasq.cachesize": .init(label: "缓存大小", kind: .number),
        "dnsmasq.local": .init(label: "本地域"),
        "dnsmasq.domain": .init(label: "域名"),
        "dnsmasq.rebind_protection": .init(label: "重绑定保护", kind: .boolean),
        "dnsmasq.rebind_localhost": .init(label: "本地主机重绑定", kind: .boolean),
        "dnsmasq.leasefile": .init(label: "租约文件"),
        "dnsmasq.resolvfile": .init(label: "resolv 文件"),
        "dnsmasq.nonwildcard": .init(label: "非通配符绑定", kind: .boolean),
        "dnsmasq.localservice": .init(label: "仅本地服务", kind: .boolean),
        "dnsmasq.ednspacket_max": .init(label: "EDNS 数据包上限", kind: .number),
        "dnsmasq.filter_aaaa": .init(label: "过滤 IPv6 AAAA", kind: .boolean),
        "dnsmasq.filter_a": .init(label: "过滤 IPv4 A", kind: .boolean),
        "dnsmasq.confdir": .init(label: "附加配置目录"),
        "dnsmasq.noresolv": .init(label: "忽略 resolv 文件", kind: .boolean),
        "dhcp.dhcpv4": .init(label: "启用 DHCPv4", kind: .boolean),
        "dhcp.dhcpv6": .init(label: "启用 DHCPv6", kind: .boolean),
        "dhcp.ra": .init(label: "启用路由通告", kind: .boolean),
        "dhcp.ra_slaac": .init(label: "RA SLAAC", kind: .boolean),
        "dhcp.ra_flags": .init(label: "RA 标志", kind: .list),
        "dhcp.dhcp_option": .init(label: "DHCP 选项", kind: .list),
        "odhcpd.maindhcp": .init(label: "主 DHCP 服务", kind: .boolean),
        "odhcpd.leasefile": .init(label: "租约文件"),
        "odhcpd.leasetrigger": .init(label: "租约触发脚本"),
        "odhcpd.loglevel": .init(label: "日志级别", kind: .number),
        "odhcpd.piodir": .init(label: "PIO 目录"),
        "odhcpd.piofolder": .init(label: "PIO 目录"),
        "odhcpd.hostsdir": .init(label: "主机文件目录"),
        // Dropbear
        "dropbear.enable": .init(label: "启用", kind: .boolean),
        "dropbear.PasswordAuth": .init(label: "密码登录", kind: .boolean),
        "dropbear.RootPasswordAuth": .init(label: "root 密码登录", kind: .boolean),
        // MosDNS (core options; the geo/stats long tail stays raw)
        "mosdns.listen_address": .init(label: "监听地址"),
        "mosdns.log_file": .init(label: "日志文件"),
        "mosdns.cache": .init(label: "缓存", kind: .boolean),
        "mosdns.configfile": .init(label: "配置文件"),
        "mosdns.bootstrap_dns": .init(label: "引导 DNS"),
        "mosdns.remote_dns": .init(label: "远程 DNS"),
        "mosdns.prefer_ipv4": .init(label: "优先 IPv4", kind: .boolean),
        "mosdns.geo_auto_update": .init(label: "地理数据自动更新", kind: .boolean),
        "mosdns.geo_update_week_time": .init(label: "地理更新星期"),
        "mosdns.geo_update_day_time": .init(label: "地理更新时间"),
        "mosdns.geoip_type": .init(label: "GeoIP 类型"),
        "mosdns.log_size": .init(label: "日志大小", kind: .number),
        "mosdns.concurrent": .init(label: "并发数", kind: .number),
        "mosdns.idle_timeout": .init(label: "空闲超时", kind: .number),
        "mosdns.minimal_ttl": .init(label: "最小 TTL", kind: .number),
        "mosdns.maximum_ttl": .init(label: "最大 TTL", kind: .number),
        "mosdns.enable_pipeline": .init(label: "启用管道", kind: .boolean),
        "mosdns.insecure_skip_verify": .init(label: "跳过证书校验", kind: .boolean),
        "mosdns.dns_leak": .init(label: "防 DNS 泄漏", kind: .boolean),
        "mosdns.cloudflare": .init(label: "Cloudflare 优选", kind: .boolean),
        "mosdns.listen_port_api": .init(label: "API 监听端口", kind: .number),
        "mosdns.redirect": .init(label: "重定向", kind: .boolean),
        "mosdns.enable_ecs_remote": .init(label: "远程 ECS", kind: .boolean),
        "mosdns.lazy_cache_ttl": .init(label: "惰性缓存 TTL", kind: .number),
        "mosdns.dump_file": .init(label: "转储文件"),
        "mosdns.reject_type65": .init(label: "拒绝 TYPE65 查询", kind: .boolean),
        "mosdns.stats_collector": .init(label: "统计收集", kind: .boolean),
        "mosdns.stats_capacity": .init(label: "统计容量", kind: .number),
        "mosdns.stats_dump_file": .init(label: "统计转储文件"),
        "mosdns.stats_dump_interval": .init(label: "统计转储间隔", kind: .number),
        // DDNS
        "ddns.service_name": .init(label: "服务商"),
        "ddns.lookup_host": .init(label: "查询主机名"),
        "ddns.domain": .init(label: "域名"),
        "ddns.use_ipv6": .init(label: "使用 IPv6", kind: .boolean),
        "ddns.force_interval": .init(label: "强制更新间隔"),
        "ddns.check_interval": .init(label: "检查间隔"),
        // ZeroTier
        "zerotier.join": .init(label: "网络 ID", kind: .list),
        "zerotier.secret": .init(label: "身份密钥"),
        // Frp
        "frpc.server_addr": .init(label: "服务器地址"),
        "frpc.server_port": .init(label: "服务器端口", kind: .number),
        "frpc.token": .init(label: "令牌"),
        "frpc.protocol": .init(label: "协议", kind: .enumeration(["tcp", "kcp", "websocket"])),
        // Network interfaces
        "interface.device": .init(label: "设备"),
        "interface.proto": .init(label: "协议", kind: .enumeration(["static", "dhcp", "dhcpv6", "pppoe", "wireguard", "none"])),
        "interface.ipaddr": .init(label: "IPv4 地址"),
        "interface.netmask": .init(label: "IPv4 掩码"),
        "interface.gateway": .init(label: "IPv4 网关"),
        "interface.dns": .init(label: "DNS 服务器", kind: .list),
        "interface.mtu": .init(label: "MTU", kind: .number),
        "interface.peerdns": .init(label: "使用对端 DNS", kind: .boolean),
        "interface.auto": .init(label: "开机自启", kind: .boolean),
        // Firewall
        "defaults.syn_flood": .init(label: "SYN 洪水防护", kind: .boolean),
        "defaults.input": .init(label: "入站默认策略", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "defaults.output": .init(label: "出站默认策略", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "defaults.forward": .init(label: "转发默认策略", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "zone.network": .init(label: "覆盖网络", kind: .list),
        "zone.input": .init(label: "入站", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "zone.output": .init(label: "出站", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "zone.forward": .init(label: "转发", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "zone.masq": .init(label: "IP 动态伪装", kind: .boolean),
        "redirect.src": .init(label: "源区域"),
        "redirect.src_dport": .init(label: "外部端口", kind: .number),
        "redirect.dest": .init(label: "目标区域"),
        "redirect.dest_ip": .init(label: "内网 IP"),
        "redirect.dest_port": .init(label: "内网端口", kind: .number),
        "redirect.proto": .init(label: "协议", kind: .list),
        "rule.src": .init(label: "源区域"),
        "rule.dest": .init(label: "目标区域"),
        "rule.target": .init(label: "动作", kind: .enumeration(["ACCEPT", "REJECT", "DROP"])),
        "rule.family": .init(label: "地址族", kind: .enumeration(["any", "ipv4", "ipv6"])),
        // HomeProxy / MosDNS / Open-Box-adjacent services
        "homeproxy.routing_node": .init(label: "路由节点"),
        "homeproxy.main_node": .init(label: "主节点"),
        "homeproxy.dns_server": .init(label: "DNS 服务器"),
        "mosdns.listen_port": .init(label: "监听端口", kind: .number),
        "mosdns.log_level": .init(label: "日志级别", kind: .enumeration(["debug", "info", "warn", "error"])),
        "mosdns.cache_size": .init(label: "缓存大小", kind: .number),
        // System
        "system.hostname": .init(label: "主机名"),
        "system.timezone": .init(label: "时区"),
        "system.zonename": .init(label: "时区名称"),
        "system.conloglevel": .init(label: "控制台日志级别", kind: .number),
        "system.cronloglevel": .init(label: "Cron 日志级别", kind: .number),
    ]

    public static func descriptor(config: String, sectionType: String, option: String) -> FieldDescriptor? {
        guard let found = fields["\(config).\(option)"] ?? fields["\(sectionType).\(option)"] ?? fields[option]
        else { return nil }
        // The catalog's labels are kit-fixed copy (Chinese source);
        // they resolve through KitL10n like every other kit string.
        return FieldDescriptor(label: KitL10n.text(found.label), kind: found.kind)
    }

    public static func label(config: String, sectionType: String, option: String) -> String? {
        descriptor(config: config, sectionType: sectionType, option: option)?.label
    }
}
