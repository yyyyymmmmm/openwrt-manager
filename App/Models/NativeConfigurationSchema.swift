import Foundation
import OpenWrtKit

/// Native business fields. Unlisted options stay untouched in the original UCI snapshot.
struct NativeField: Identifiable {
    enum Kind {
        case text, secret, list, flag
        case integer(Int, Int)
        case choice([String])
        case address, prefix, mac, netmask4
    }
    enum ListItem { case address, prefix, mac }
    let id: String
    let title: String
    var kind: Kind = .text
    var help = ""
    var required = false
    var when: (String, [String])? = nil
    var items: ListItem? = nil
    func visible(in section: ConfigurationSection) -> Bool {
        guard let (key, values) = when else { return true }
        return values.contains(section.values[key]?.stringValue ?? "")
    }
}

struct NativeFieldGroup: Identifiable {
    let title: String
    let fields: [NativeField]
    var id: String { title }
}

struct NativeSectionSchema: Identifiable {
    let type: String
    let title: String
    let groups: [NativeFieldGroup]
    var named = false
    var addable = true
    var id: String { type }
    var fields: [NativeField] { groups.flatMap(\.fields) }
    func label(_ section: ConfigurationSection) -> String {
        for key in ["name", "ssid", "interface", "target", "hostname"] {
            if let value = section.values[key]?.stringValue, !value.isEmpty { return value }
        }
        return section.anonymous ? title : section.id
    }
}

struct NativeConfigurationSchema: Identifiable {
    let id: String
    let title: String
    let config: String
    let sections: [NativeSectionSchema]
    var note = "未设置的字段沿用固件行为；打开页面不会写入默认值。"

    private static func f(_ key: String, _ title: String, _ kind: NativeField.Kind = .text,
                          _ help: String = "", required: Bool = false,
                          when: (String, [String])? = nil, items: NativeField.ListItem? = nil) -> NativeField {
        NativeField(id: key, title: title, kind: kind, help: help, required: required, when: when, items: items)
    }
    private static func g(_ title: String, _ fields: [NativeField]) -> NativeFieldGroup {
        NativeFieldGroup(title: title, fields: fields)
    }
    private static func s(_ type: String, _ title: String, _ groups: [NativeFieldGroup],
                          named: Bool = false, addable: Bool = true) -> NativeSectionSchema {
        NativeSectionSchema(type: type, title: title, groups: groups, named: named, addable: addable)
    }

    static let system = Self(id: "system", title: "系统", config: "system", sections: [
        s("system", "系统设置", [
            g("常规设置", [f("hostname", "主机名"), f("description", "设备描述"), f("notes", "备注"),
                         f("timezone", "POSIX 时区", .text, "填写系统使用的 POSIX 时区；地区名称不会自动转换为 POSIX 值。"),
                         f("zonename", "时区地区名称")]),
            g("日志", [f("log_size", "日志缓冲区（KiB）", .integer(1, 2_147_483_647)),
                     f("log_ip", "远程日志服务器", .address), f("log_port", "远程日志端口", .integer(1, 65535)),
                     f("log_proto", "传输协议", .choice(["udp", "tcp"])), f("log_file", "日志文件路径"),
                     f("conloglevel", "内核控制台日志等级", .integer(0, 8)), f("cronloglevel", "计划任务日志等级", .integer(0, 9))])
        ], addable: false),
        s("timeserver", "时间同步", [g("NTP", [f("enabled", "启用 NTP 客户端", .flag),
            f("enable_server", "提供 NTP 服务", .flag, "sysntpd 需已启用；开机启动在系统→启动项中单独管理。"), f("interface", "监听接口"),
            f("use_dhcp", "使用 DHCP 下发的服务器", .flag), f("server", "NTP 服务器", .list)])], addable: false)
    ])

    static let ssh = Self(id: "ssh", title: "SSH 访问", config: "dropbear", sections: [
        s("dropbear", "SSH 实例", [g("访问设置", [f("enable", "启用实例", .flag),
            f("Port", "监听端口", .integer(1, 65535)), f("Interface", "监听接口"),
            f("PasswordAuth", "允许密码认证", .choice(["on", "off"])),
            f("RootPasswordAuth", "允许 root 密码认证", .choice(["on", "off"])),
            f("GatewayPorts", "允许远程端口转发", .choice(["on", "off"])),
            f("IdleTimeout", "空闲超时（秒）", .integer(0, 2_147_483_647))])])
    ])

    static let interfaces = Self(id: "interfaces", title: "接口", config: "network", sections: [
        s("interface", "逻辑接口", [
            g("常规设置", [f("proto", "协议", .text, "协议处理程序必须由固件提供；保留当前协议，不推定其他协议已经安装。", required: true),
                f("device", "网络设备"), f("auto", "开机自动连接", .flag),
                f("ipaddr", "IPv4 地址", .list, "每行一个地址，可带 CIDR 前缀。", when: ("proto", ["static"]), items: .prefix),
                f("netmask", "IPv4 子网掩码", .netmask4, when: ("proto", ["static"])),
                f("gateway", "IPv4 网关", .address, when: ("proto", ["static"])),
                f("username", "拨号用户名", when: ("proto", ["ppp", "pppoe", "pptp", "l2tp"])),
                f("password", "拨号密码", .secret, when: ("proto", ["ppp", "pppoe", "pptp", "l2tp"])),
                f("ac", "PPPoE 接入集中器", when: ("proto", ["pppoe"])),
                f("service", "PPPoE 服务名称", when: ("proto", ["pppoe"]))]),
            g("高级设置", [f("defaultroute", "使用默认网关", .flag), f("metric", "路由跃点", .integer(0, 2_147_483_647)),
                f("peerdns", "使用对端 DNS", .flag), f("dns", "DNS 服务器", .list, items: .address),
                f("dns_search", "DNS 搜索域", .list), f("mtu", "MTU", .integer(68, 65535)),
                f("delegate", "委派 IPv6 前缀", .flag), f("ip4table", "IPv4 路由表"), f("ip6table", "IPv6 路由表")]),
            g("WireGuard", [f("private_key", "私钥", .secret, required: true, when: ("proto", ["wireguard"])),
                f("listen_port", "监听端口", .integer(1, 65535), when: ("proto", ["wireguard"])),
                f("addresses", "隧道地址", .list, when: ("proto", ["wireguard"]), items: .prefix),
                f("nohostroute", "不创建端点主机路由", .flag, when: ("proto", ["wireguard"]))]),
            g("IPv6", [f("ip6addr", "IPv6 地址", .list, when: ("proto", ["static"]), items: .prefix),
                f("ip6gw", "IPv6 网关", .address, when: ("proto", ["static"])),
                f("ip6assign", "IPv6 分配长度", .integer(0, 128)), f("ip6hint", "IPv6 子网提示"),
                f("ip6class", "IPv6 前缀类", .list), f("reqaddress", "请求 IPv6 地址", .choice(["try", "force", "none"]), when: ("proto", ["dhcpv6"])),
                f("reqprefix", "请求前缀长度", .text, when: ("proto", ["dhcpv6"]))])
        ], named: true)
    ], note: "这里编辑 network 配置。接口的 DHCP 服务和防火墙区域分别在 DHCP、防火墙中管理，各次应用单独预览和确认。")

    static let devices = Self(id: "devices", title: "设备与网桥 VLAN", config: "network", sections: [
        s("device", "网络设备", [
            g("常规设置", [f("name", "设备名称", required: true), f("type", "设备类型", .choice(["bridge", "8021q", "8021ad"])),
                f("macaddr", "MAC 地址", .mac), f("mtu", "MTU", .integer(68, 65535)), f("ipv6", "启用 IPv6", .flag)]),
            g("网桥", [f("ports", "网桥端口", .list, when: ("type", ["bridge"])),
                f("stp", "生成树协议", .flag, when: ("type", ["bridge"])),
                f("igmp_snooping", "IGMP 侦听", .flag, when: ("type", ["bridge"])),
                f("vlan_filtering", "VLAN 过滤", .flag, when: ("type", ["bridge"])),
                f("bridge_empty", "无端口时保持网桥", .flag, when: ("type", ["bridge"]))]),
            g("VLAN 设备", [f("ifname", "基础设备", when: ("type", ["8021q", "8021ad"])),
                f("vid", "VLAN ID", .integer(1, 4094), when: ("type", ["8021q", "8021ad"]))])
        ]),
        s("bridge-vlan", "网桥 VLAN", [g("VLAN", [f("device", "网桥设备", required: true),
            f("vlan", "VLAN ID", .integer(1, 4094), required: true),
            f("ports", "端口与标记", .list, "每行一个端口，保留固件的 :t、:u、* 标记语法。"), f("local", "本机参与此 VLAN", .flag)])]),
        s("globals", "全局网络选项", [g("全局", [f("ula_prefix", "IPv6 ULA 前缀", .prefix), f("packet_steering", "数据包分流", .choice(["0", "1", "2"]))])], addable: false)
    ])

    private static let routeGroups = [g("常规设置", [f("interface", "逻辑接口"),
        f("type", "路由类型", .choice(["unicast", "local", "broadcast", "multicast", "unreachable", "prohibit", "blackhole", "throw"])),
        f("target", "目标地址/网段", .prefix, required: true), f("gateway", "网关", .address), f("netmask", "IPv4 子网掩码", .netmask4)]),
        g("高级设置", [f("metric", "跃点", .integer(0, 2_147_483_647)), f("mtu", "MTU", .integer(68, 65535)),
        f("table", "路由表"), f("source", "首选源地址", .prefix), f("onlink", "强制网关在链路上", .flag), f("disabled", "禁用此路由", .flag)])]
    private static let ruleGroups = [g("匹配条件", [f("priority", "优先级", .integer(0, 2_147_483_647)),
        f("in", "入站接口"), f("out", "出站接口"), f("src", "源网段", .prefix), f("dest", "目标网段", .prefix),
        f("ipproto", "IP 协议"), f("sport", "源端口/范围"), f("dport", "目标端口/范围"), f("mark", "防火墙标记/掩码"), f("invert", "反向匹配", .flag)]),
        g("动作", [f("action", "动作", .choice(["unicast", "blackhole", "unreachable", "prohibit"])),
        f("lookup", "查询路由表"), f("goto", "跳转优先级", .integer(0, 2_147_483_647)),
        f("suppress_prefixlength", "抑制前缀长度", .integer(0, 128)), f("disabled", "禁用此规则", .flag)])]
    static let routes = Self(id: "routes", title: "静态与策略路由", config: "network", sections: [
        s("route", "静态 IPv4 路由", routeGroups), s("route6", "静态 IPv6 路由", routeGroups.map {
            g($0.title, $0.fields.filter { $0.id != "netmask" })
        }), s("rule", "IPv4 策略规则", ruleGroups), s("rule6", "IPv6 策略规则", ruleGroups)
    ])

    static let wireless = Self(id: "wireless", title: "无线网络", config: "wireless", sections: [
        s("wifi-device", "无线电", [g("基本设置", [f("disabled", "禁用无线电", .flag),
            f("band", "频段", .choice(["2g", "5g", "6g"])), f("channel", "信道", .text, "auto 或硬件支持的信道编号。"),
            f("htmode", "工作模式与带宽", .text, "模式受驱动、频段和固件限制；不能仅凭配置认定支持。"),
            f("country", "国家代码"), f("txpower", "发射功率（dBm）", .integer(0, 100)),
            f("cell_density", "覆盖密度", .choice(["0", "1", "2", "3"]))])], addable: false),
        s("wifi-iface", "无线网络", [g("常规设置", [f("device", "所属无线电", required: true),
            f("mode", "工作模式", .choice(["ap", "sta", "adhoc", "mesh", "monitor"]), required: true),
            f("ssid", "SSID"), f("mesh_id", "Mesh ID", when: ("mode", ["mesh"])), f("network", "关联逻辑网络", .list),
            f("disabled", "禁用此网络", .flag), f("hidden", "隐藏 SSID", .flag)]),
            g("无线安全", [f("encryption", "加密方式", .text, "沿用驱动/wpad 支持的名称，例如 psk2、sae 或 sae-mixed。"),
            f("key", "无线密码/密钥", .secret), f("ieee80211w", "管理帧保护", .choice(["0", "1", "2"])),
            f("isolate", "隔离客户端", .flag), f("macfilter", "MAC 过滤策略", .choice(["disable", "allow", "deny"])),
            f("maclist", "MAC 地址列表", .list, items: .mac)]),
            g("高级设置", [f("wds", "WDS", .flag), f("wmm", "WMM", .flag), f("maxassoc", "最大关联数", .integer(1, 2007)),
            f("dtim_period", "DTIM 周期", .integer(1, 255)), f("ieee80211r", "快速漫游 802.11r", .flag), f("mobility_domain", "移动域")])])
    ], note: "无线配置始终保留在客户端中。读取失败会显示真实错误；本机没有返回无线电不能推定其他路由器不支持。硬件、驱动和 wpad 能力仍需分别核对。")

    static func wireguardPeers(interface: String) -> NativeSectionSchema {
        s("wireguard_" + interface, "WireGuard 对端 · " + interface, [
            g("密钥与地址", [f("description", "说明"), f("public_key", "对端公钥", required: true),
                f("preshared_key", "预共享密钥", .secret), f("allowed_ips", "允许的 IP/网段", .list, items: .prefix),
                f("route_allowed_ips", "为允许网段创建路由", .flag)]),
            g("端点", [f("endpoint_host", "端点 IP/域名"), f("endpoint_port", "端点端口", .integer(1, 65535)),
                f("persistent_keepalive", "持久保活（秒）", .integer(0, 65535)), f("disabled", "禁用此对端", .flag)])
        ])
    }

    private static let dnsmasqDHCP = [g("常规设置", [f("authoritative", "权威 DHCP", .flag), f("domain", "本地域名"),
        f("sequential_ip", "顺序分配 IP", .flag), f("dhcpleasemax", "最大租约数", .integer(1, 2_147_483_647))]),
        g("监听与日志", [f("interface", "监听接口", .list), f("notinterface", "排除接口", .list), f("listen_address", "监听地址", .list),
        f("nonwildcard", "绑定接口", .flag), f("logdhcp", "DHCP 日志", .flag), f("quietdhcp", "减少 DHCP 日志", .flag), f("logfacility", "日志设施/文件")]),
        g("文件与 PXE/TFTP", [f("leasefile", "租约文件"), f("readethers", "读取 ethers 文件", .flag),
        f("enable_tftp", "启用 TFTP", .flag), f("tftp_root", "TFTP 根目录"), f("dhcp_boot", "引导文件/服务器")])]
    static let dhcp = Self(id: "dhcp", title: "DHCP", config: "dhcp", sections: [
        s("dnsmasq", "dnsmasq 实例", dnsmasqDHCP, addable: false),
        s("dhcp", "接口地址分配", [g("常规设置", [f("interface", "逻辑接口", required: true),
            f("ignore", "忽略此接口", .flag), f("start", "地址池起始偏移", .integer(0, 2_147_483_647)),
            f("limit", "地址池大小", .integer(1, 2_147_483_647)), f("leasetime", "租期", .text, "使用固件支持的时间，如 12h、30m 或 infinite。")]),
            g("IPv4 设置", [f("force", "强制提供 DHCP", .flag), f("dynamicdhcp", "动态地址分配", .flag),
            f("dhcp_option", "DHCP 选项", .list), f("dhcp_option_force", "强制发送选项", .list), f("netmask", "子网掩码", .netmask4)]),
            g("IPv6 DHCPv6", [f("dhcpv6", "DHCPv6 模式", .choice(["disabled", "server", "relay", "hybrid"])),
            f("ndp", "NDP 模式", .choice(["disabled", "relay", "hybrid"])), f("master", "主接口", .flag),
            f("dns", "IPv6 DNS 服务器", .list, items: .address), f("domain", "IPv6 搜索域", .list)]),
            g("IPv6 RA", [f("ra", "路由通告模式", .choice(["disabled", "server", "relay", "hybrid"])),
            f("ra_slaac", "启用 SLAAC", .flag), f("ra_flags", "RA 标志", .list),
            f("ra_default", "默认路由通告", .choice(["0", "1", "2"])), f("ra_lifetime", "RA 有效期（秒）", .integer(0, 65535))])], named: true),
        s("host", "静态租约", [g("绑定", [f("name", "主机名"), f("mac", "MAC 地址", .list, items: .mac),
            f("ip", "IPv4 地址", .text, "使用有效 IPv4 地址；ignore 表示不分配 IPv4。"), f("leasetime", "租期"),
            f("dns", "创建 DNS 记录", .flag), f("duid", "IPv6 DUID"), f("hostid", "IPv6 主机标识"), f("tag", "DHCP 标签")])]),
        s("odhcpd", "odhcpd", [g("服务设置", [f("maindhcp", "作为主要 DHCP 服务", .flag),
            f("leasefile", "租约文件"), f("leasetrigger", "租约事件程序"), f("loglevel", "日志等级", .integer(0, 7))])], addable: false)
    ])

    static let dns = Self(id: "dns", title: "DNS", config: "dhcp", sections: [
        s("dnsmasq", "DNS 实例", [g("常规设置", [f("domainneeded", "仅转发完整域名", .flag),
            f("boguspriv", "过滤私网反向解析", .flag), f("localise_queries", "本地化查询", .flag),
            f("local", "本地域名范围"), f("domain", "本地域名"), f("expandhosts", "扩展 hosts 主机名", .flag)]),
            g("缓存与端口", [f("cachesize", "缓存条目数", .integer(0, 2_147_483_647)),
            f("port", "DNS 监听端口", .integer(0, 65535)), f("queryport", "查询源端口", .integer(0, 65535)),
            f("dnsforwardmax", "并发转发数", .integer(1, 2_147_483_647)), f("ednspacket_max", "EDNS 最大报文", .integer(512, 65535))]),
            g("转发与过滤", [f("server", "上游/分流服务器", .list), f("noresolv", "忽略 resolv 文件", .flag),
            f("resolvfile", "resolv 文件"), f("strictorder", "严格使用上游顺序", .flag), f("allservers", "同时查询上游", .flag),
            f("address", "域名地址覆盖", .list), f("rebind_protection", "重绑定保护", .flag),
            f("rebind_localhost", "允许回环重绑定", .flag), f("rebind_domain", "重绑定域名例外", .list),
            f("filter_aaaa", "过滤 AAAA", .flag), f("filter_a", "过滤 A", .flag)]),
            g("DNSSEC 与日志", [f("dnssec", "启用 DNSSEC", .flag), f("dnsseccheckunsigned", "检查未签名响应", .flag),
            f("logqueries", "记录查询", .flag), f("nohosts", "忽略 hosts 文件", .flag), f("addnhosts", "附加 hosts 文件", .list)])], addable: false),
        s("domain", "主机名映射", [g("记录", [f("name", "主机名", required: true), f("ip", "IP 地址", .address, required: true)])]),
        s("srvhost", "SRV 记录", [g("记录", [f("srv", "服务名称", required: true), f("target", "目标主机", required: true),
            f("port", "端口", .integer(0, 65535)), f("class", "优先级", .integer(0, 65535)), f("weight", "权重", .integer(0, 65535))])]),
        s("mxhost", "MX 记录", [g("记录", [f("domain", "域名", required: true), f("relay", "邮件服务器", required: true), f("pref", "优先级", .integer(0, 65535))])]),
        s("cname", "CNAME 记录", [g("记录", [f("cname", "别名", required: true), f("target", "目标", required: true), f("ttl", "TTL（秒）", .integer(0, 2_147_483_647))])])
    ])

    private static let policy = NativeField.Kind.choice(["ACCEPT", "REJECT", "DROP"])
    static let firewall = Self(id: "firewall", title: "防火墙", config: "firewall", sections: [
        s("defaults", "常规设置", [g("默认策略", [f("input", "入站", policy), f("output", "出站", policy), f("forward", "转发", policy),
            f("synflood_protect", "SYN 洪水保护", .flag), f("drop_invalid", "丢弃无效数据包", .flag),
            f("flow_offloading", "软件流量卸载", .flag), f("flow_offloading_hw", "硬件流量卸载", .flag)])], addable: false),
        s("zone", "区域", [g("常规设置", [f("name", "区域名称", required: true), f("network", "关联网络", .list),
            f("input", "入站策略", policy), f("output", "出站策略", policy), f("forward", "区域内转发", policy),
            f("masq", "IPv4 地址伪装", .flag), f("masq6", "IPv6 地址伪装", .flag), f("mtu_fix", "MSS 钳制", .flag)]),
            g("高级设置", [f("device", "关联设备", .list), f("subnet", "关联子网", .list), f("family", "地址族", .choice(["ipv4", "ipv6", "any"])),
            f("masq_src", "伪装源网段", .list), f("masq_dest", "伪装目标网段", .list), f("log_limit", "日志速率限制")])]),
        s("forwarding", "区域转发", [g("转发关系", [f("src", "源区域", required: true), f("dest", "目标区域", required: true)])]),
        s("redirect", "端口转发", [g("常规设置", [f("name", "名称"), f("enabled", "启用规则", .flag),
            f("target", "目标动作", .choice(["DNAT", "SNAT"]), required: true), f("family", "地址族", .choice(["ipv4", "ipv6", "any"])),
            f("proto", "协议", .list), f("src", "源区域", required: true), f("src_dport", "外部端口"),
            f("dest", "内部区域"), f("dest_ip", "内部 IP", .address), f("dest_port", "内部端口")]),
            g("高级设置", [f("src_ip", "源 IP/网段", .prefix), f("src_dip", "外部 IP", .address), f("src_port", "源端口"),
            f("reflection", "NAT 回环", .flag), f("reflection_src", "回环源地址", .choice(["internal", "external"])), f("log", "记录匹配", .flag)])]),
        s("rule", "通信规则", [g("匹配与动作", [f("name", "名称"), f("enabled", "启用规则", .flag),
            f("family", "地址族", .choice(["ipv4", "ipv6", "any"])), f("proto", "协议", .list),
            f("src", "源区域"), f("src_ip", "源地址", .list), f("src_mac", "源 MAC", .list), f("src_port", "源端口"),
            f("dest", "目标区域"), f("dest_ip", "目标地址", .list), f("dest_port", "目标端口"),
            f("target", "动作", .choice(["ACCEPT", "REJECT", "DROP", "MARK", "NOTRACK", "HELPER", "DSCP"]), required: true),
            f("set_mark", "设置标记", when: ("target", ["MARK"])), f("set_dscp", "设置 DSCP", when: ("target", ["DSCP"])),
            f("set_helper", "连接跟踪助手", when: ("target", ["HELPER"]))]),
            g("高级与时间限制", [f("ipset", "IP 集合"), f("limit", "匹配速率"), f("limit_burst", "突发包数", .integer(0, 2_147_483_647)),
            f("log", "记录匹配", .flag), f("weekdays", "星期"), f("monthdays", "每月日期"),
            f("start_time", "开始时间"), f("stop_time", "结束时间"), f("start_date", "开始日期"), f("stop_date", "结束日期"), f("utc_time", "使用 UTC", .flag)])]),
        s("nat", "源 NAT", [g("规则", [f("name", "名称"), f("enabled", "启用规则", .flag), f("src", "出口区域", required: true),
            f("proto", "协议", .list), f("src_ip", "源 IP/网段", .prefix), f("dest_ip", "目标 IP/网段", .prefix),
            f("dest_port", "目标端口"), f("target", "动作", .choice(["SNAT", "MASQUERADE", "ACCEPT"]), required: true),
            f("snat_ip", "改写源 IP", .address, when: ("target", ["SNAT"])), f("snat_port", "改写源端口")])]),
        s("ipset", "IP 集合", [g("集合", [f("name", "名称", required: true), f("family", "地址族", .choice(["ipv4", "ipv6"])),
            f("match", "匹配类型", .list), f("entry", "集合条目", .list), f("loadfile", "条目文件"), f("timeout", "超时（秒）", .integer(0, 2_147_483_647))])])
    ])

    static let ddns = Self(id: "ddns", title: "动态 DNS 配置", config: "ddns", sections: [
        s("ddns", "全局设置", [g("常规设置", [f("upd_privateip", "允许非公网地址", .flag),
            f("ddns_loglines", "日志行数", .integer(1, 2_147_483_647)), f("ddns_rundir", "状态目录"),
            f("ddns_logdir", "日志目录"), f("use_curl", "使用 cURL", .flag), f("cacert", "CA 证书文件"), f("services_url", "服务定义下载地址")])], addable: false),
        s("service", "DDNS 服务", [g("基本设置", [f("enabled", "启用", .flag), f("lookup_host", "查询主机名", required: true),
            f("use_ipv6", "使用 IPv6", .flag), f("service_name", "服务商定义", .text, "填写固件已安装的服务定义名称；本页不下载服务定义。"),
            f("update_url", "自定义更新 URL"), f("domain", "域名"), f("username", "用户名"), f("password", "密码/令牌", .secret),
            f("param_enc", "编码参数"), f("param_opt", "附加参数"), f("use_https", "使用 HTTPS", .flag), f("cacert", "CA 证书文件")]),
            g("高级设置", [f("ip_source", "IP 地址来源", .choice(["network", "web", "interface", "script"])),
            f("ip_network", "来源网络", when: ("ip_source", ["network"])), f("ip_url", "查询 URL", when: ("ip_source", ["web"])),
            f("ip_interface", "来源设备", when: ("ip_source", ["interface"])),
            f("interface", "事件触发接口"), f("bind_network", "请求绑定网络"), f("force_ipversion", "强制地址族", .flag),
            f("dns_server", "查询 DNS 服务器"), f("force_dnstcp", "强制 TCP DNS", .flag), f("proxy", "代理 URL", .secret),
            f("use_syslog", "系统日志等级", .integer(0, 4)), f("use_logfile", "启用文件日志", .flag)]),
            g("计时器", [f("check_interval", "检查间隔", .integer(1, 2_147_483_647)), f("check_unit", "检查单位", .choice(["seconds", "minutes", "hours"])),
            f("force_interval", "强制更新间隔", .integer(0, 2_147_483_647)), f("force_unit", "更新单位", .choice(["minutes", "hours", "days"])),
            f("retry_max_count", "最大重试次数", .integer(0, 2_147_483_647)), f("retry_interval", "重试间隔", .integer(1, 2_147_483_647)),
            f("retry_unit", "重试单位", .choice(["seconds", "minutes"]))])], named: true)
    ], note: "本页编辑 DDNS 配置。服务商能力、注册 IP、单实例更新与日志读取仍需专有接口；启用配置不代表更新成功。")

    static let sqm = Self(id: "sqm", title: "SQM 配置", config: "sqm", sections: [
        s("queue", "队列实例", [g("基本设置", [f("enabled", "启用队列", .flag), f("interface", "网络设备", required: true),
            f("download", "下载速率（kbit/s）", .integer(0, 2_147_483_647)), f("upload", "上传速率（kbit/s）", .integer(0, 2_147_483_647)),
            f("debug_logging", "调试日志", .flag), f("verbosity", "日志等级", .integer(0, 8))]),
            g("队列设置", [f("qdisc", "队列规则", .text, "必须使用路由器已安装的队列规则。"),
            f("script", "队列脚本", .text, "必须使用路由器已安装的 SQM 脚本文件名。"),
            f("qdisc_advanced", "高级配置", .flag), f("use_mq", "多队列", .flag),
            f("squash_dscp", "清除入站 DSCP", .choice(["0", "1"])), f("squash_ingress", "忽略入站 DSCP", .choice(["0", "1"])),
            f("ingress_ecn", "入站 ECN", .choice(["ECN", "NOECN"])), f("egress_ecn", "出站 ECN", .choice(["ECN", "NOECN"]))]),
            g("链路层", [f("linklayer", "链路层类型", .choice(["none", "ethernet", "atm"])),
            f("overhead", "每包额外开销（字节）", .integer(-127, 128)), f("linklayer_advanced", "高级链路层选项", .flag),
            f("tcMTU", "最大报文大小", .integer(1, 65535)), f("tcTSIZE", "速率表大小", .integer(1, 65535)),
            f("tcMPU", "最小报文大小", .integer(0, 65535)), f("linklayer_adaptation_mechanism", "开销补偿机制", .choice(["default", "cake", "htb_private", "tc_stab"]))])])
    ], note: "速率为 kbit/s，设为 0 表示关闭该方向整形。队列规则和脚本是否安装、内核队列是否生效仍需核对，不能将配置启用视为运行成功。")

    static let upnp = Self(id: "upnp", title: "UPnP / PCP 配置", config: "upnpd", sections: [
        s("upnpd", "服务设置", [g("常规设置", [f("enabled", "启用服务", .flag), f("enable_upnp", "UPnP IGD", .flag),
            f("enable_natpmp", "PCP / NAT-PMP", .flag), f("ext_allow_private_ipv4", "允许私网 IPv4", .flag), f("igdv1", "IGDv1 兼容模式", .flag),
            f("download", "下行速率（kByte/s）", .integer(0, 2_147_483_647)), f("upload", "上行速率（kByte/s）", .integer(0, 2_147_483_647))]),
            g("高级设置", [f("use_stun", "使用 STUN", .flag), f("stun_host", "STUN 主机"), f("stun_port", "STUN 端口", .integer(1, 65535)),
            f("secure_mode", "安全模式", .flag), f("notify_interval", "通告间隔（秒）", .integer(1, 2_147_483_647)),
            f("port", "SOAP / HTTP 端口", .integer(0, 65535)), f("presentation_url", "设备展示 URL"), f("uuid", "设备 UUID"),
            f("model_number", "型号"), f("serial_number", "序列号"), f("system_uptime", "报告系统运行时间", .flag),
            f("log_output", "详细日志", .flag), f("upnp_lease_file", "映射租约文件")])], addable: false),
        s("perm_rule", "访问控制", [g("ACL 规则", [f("comment", "说明"), f("int_addr", "客户端网段", .prefix, required: true),
            f("int_ports", "客户端端口/范围", required: true), f("ext_ports", "外部端口/范围", required: true),
            f("action", "动作", .choice(["allow", "deny"]), required: true)])])
    ], note: "本页编辑服务及访问控制；动态映射列表和单条映射删除尚未接入，不将静态 ACL 冒充当前映射。")
}
