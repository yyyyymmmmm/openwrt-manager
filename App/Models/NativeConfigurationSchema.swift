import Foundation
import OpenWrtKit

/// Native business fields. Unlisted options stay untouched in the original UCI snapshot.
struct NativeField: Identifiable {
    enum Kind {
        case text, secret, list, flag
        case integer(Int, Int)
        case choice([String])
        case address, prefix, mac, netmask4
        case hexadecimal(Int)
    }
    enum ListItem { case address, prefix, mac }
    let id: String
    let title: String
    var kind: Kind = .text
    var help = ""
    var required = false
    var when: (String, [String])? = nil
    var items: ListItem? = nil
    var choiceLabels: [String: String] = [:]
    var additionalConditions: [String: [String]] = [:]
    var editingUnavailableReason: String? = nil
    var restrictToChoices = false
    var suggestions: [String: String] = [:]
    func visible(in section: ConfigurationSection) -> Bool {
        guard additionalConditions.allSatisfy({ key, values in values.contains(section.values[key]?.stringValue ?? "") }) else { return false }
        guard let (key, values) = when else { return true }
        return values.contains(section.values[key]?.stringValue ?? "")
    }
}

struct NativeFieldGroup: Identifiable {
    let title: String
    var fields: [NativeField]
    var id: String { title }
}

struct NativeSectionSchema: Identifiable {
    let type: String
    let title: String
    var groups: [NativeFieldGroup]
    var named = false
    var addable = true
    var sectionIDs: Set<String>? = nil
    var id: String { type + (sectionIDs?.sorted().joined(separator: ",") ?? "") }
    func matches(_ section: ConfigurationSection) -> Bool {
        section.type == type && (sectionIDs?.contains(section.id) ?? true)
    }
    var fields: [NativeField] { groups.flatMap(\.fields) }
    func label(_ section: ConfigurationSection) -> String {
        for key in ["label", "name", "ssid", "interface", "target", "hostname"] {
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

    static func f(_ key: String, _ title: String, _ kind: NativeField.Kind = .text,
                          _ help: String = "", required: Bool = false,
                          when: (String, [String])? = nil, items: NativeField.ListItem? = nil) -> NativeField {
        NativeField(id: key, title: title, kind: kind, help: help, required: required, when: when, items: items)
    }
    static func g(_ title: String, _ fields: [NativeField]) -> NativeFieldGroup {
        NativeFieldGroup(title: title, fields: fields)
    }
    static func s(_ type: String, _ title: String, _ groups: [NativeFieldGroup],
                          named: Bool = false, addable: Bool = true, ids: Set<String>? = nil) -> NativeSectionSchema {
        NativeSectionSchema(type: type, title: title, groups: groups, named: named, addable: addable, sectionIDs: ids)
    }

    static let system = Self(id: "system", title: "系统", config: "system", sections: [
        s("system", "系统设置", [
            g("常规设置", [f("hostname", "主机名"), f("description", "设备描述"), f("notes", "备注"),
                         f("zonename", "时区", .choice([]), "选择地区后同步更新 POSIX 时区；目录由当前路由器返回。"),
                         f("clock_timestyle", "显示完整时区名称", .flag),
                         f("clock_hourcycle", "时间格式", .choice(["", "h12", "h23"]))]),
            g("ZRam", [f("zram_size_mb", "ZRam 大小（MB）", .integer(0, 2_147_483_647), "空值交由固件处理；应用可能重建交换设备。"),
                         f("zram_comp_algo", "ZRam 压缩算法", .choice([]), "读取内核 comp_algorithm 列出的实际算法，保留当前值。")]),
            g("日志", [f("log_size", "日志缓冲区（KiB）", .integer(0, 2_147_483_647)),
                     f("log_ip", "远程日志服务器", .text, "IP 地址或服务器域名。"), f("log_port", "远程日志端口", .integer(1, 65535)),
                     f("log_proto", "传输协议", .choice(["udp", "tcp"])), f("log_file", "日志文件路径"),
                     f("conloglevel", "内核控制台日志等级", .choice((1...8).map(String.init))), f("cronloglevel", "计划任务日志等级", .choice(["5", "7", "9"]))])
        ], addable: false),
        s("timeserver", "时间同步", [g("NTP", [f("enabled", "NTP 配置启用", .flag, "这是配置字段。NTP 服务的开机启用和运行状态须在时间状态与启动项中核对。"),
            f("enable_server", "提供 NTP 服务", .flag, "sysntpd 需已启用；开机启动在系统→启动项中单独管理。"), f("interface", "监听接口"),
            f("use_dhcp", "使用 DHCP 下发的服务器", .flag), f("server", "NTP 服务器", .list)])], addable: false)
    ])

    static let luciInterface = Self(id: "luci-interface", title: "语言与界面", config: "luci", sections: [
        s("core", "路由器 Web 管理界面", [g("语言与界面", [
            f("lang", "界面语言", .choice([])), f("mediaurlbase", "界面主题", .choice([])),
            f("tablefilters", "表格筛选器", .flag)
        ])], addable: false, ids: ["main"])
    ], note: "这些选项修改路由器 LuCI 的界面设置。手机 App 的外观和字号在底部“设置”中管理；本页独立预览并提交 luci 配置。")

    func resolvedSystemSections(configuration: RouterConfiguration?, runtime: SystemRuntimeSnapshot?) -> [NativeSectionSchema] {
        guard id == "system" || id == "luci-interface" else { return sections }
        return sections.map { section in
            var section = section
            section.groups = section.groups.map { group in
                var group = group
                group.fields = group.fields.map { original in
                    var field = original
                    if id == "system" {
                        switch field.id {
                        case "zonename":
                            field.restrictToChoices = true
                            if let zones = runtime?.timezones { field.kind = .choice(zones.map(\.name)) }
                            else { field.editingUnavailableReason = "未能读取路由器时区目录。" }
                        case "zram_size_mb", "zram_comp_algo":
                            if runtime?.zramSupported != true { field.editingUnavailableReason = runtime?.zramSupported == false ? "固件未提供 ZRam 能力。" : "未能确认 ZRam 能力。" }
                            else if field.id == "zram_comp_algo" {
                                field.restrictToChoices = true
                                if let algorithms = runtime?.zramAlgorithms { field.kind = .choice(algorithms) }
                                else { field.editingUnavailableReason = "未能读取内核可用算法；可能没有活动 ZRam 设备或缺少读取权限。" }
                            }
                        case "clock_hourcycle": field.choiceLabels = ["": "固件默认", "h12": "12 小时", "h23": "24 小时"]
                        case "cronloglevel": field.choiceLabels = ["5": "调试", "7": "正常", "9": "禁用"]
                        default: break
                        }
                    } else if field.id == "lang" {
                        field.restrictToChoices = true
                        let languages = configuration?.sections.first { $0.id == "languages" }?.values ?? [:]
                        field.choiceLabels = languages.compactMapValues(\.stringValue).merging(["auto": "自动", "en": "English"]) { current, _ in current }
                        field.kind = .choice(field.choiceLabels.keys.sorted())
                    } else if field.id == "mediaurlbase" {
                        field.restrictToChoices = true
                        let themes = configuration?.sections.first { $0.id == "themes" }?.values ?? [:]
                        field.choiceLabels = Dictionary(themes.compactMap { name, value in value.stringValue.map { ($0, name) } }, uniquingKeysWith: { first, _ in first })
                        field.kind = .choice(field.choiceLabels.keys.sorted())
                        if field.choiceLabels.isEmpty { field.editingUnavailableReason = "路由器未返回可用主题。" }
                    }
                    return field
                }
                return group
            }
            return section
        }
    }

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
            f("debug_logging", "调试日志", .flag), f("verbosity", "日志等级", .choice(["0", "1", "2", "5", "8", "10"]))]),
            g("队列设置", [f("qdisc", "队列规则", .text, "必须使用路由器已安装的队列规则。", required: true),
            f("script", "队列脚本", .text, "必须使用路由器已安装的 SQM 脚本文件名。", required: true),
            f("qdisc_advanced", "高级配置", .flag), f("use_mq", "多队列", .flag),
            f("squash_dscp", "清除入站 DSCP", .choice(["0", "1"])), f("squash_ingress", "忽略入站 DSCP", .choice(["0", "1"])),
            f("ingress_ecn", "入站 ECN", .choice(["ECN", "NOECN"])), f("egress_ecn", "出站 ECN", .choice(["ECN", "NOECN"])),
            f("qdisc_really_really_advanced", "危险队列参数", .flag),
            f("ilimit", "入站队列上限", .integer(0, 2_147_483_647)), f("elimit", "出站队列上限", .integer(0, 2_147_483_647)),
            f("itarget", "入站延迟目标", .text, "示例 5ms；允许 s、ms、us 或 default。留空由脚本决定。"),
            f("etarget", "出站延迟目标", .text, "示例 5ms；允许 s、ms、us 或 default。留空由脚本决定。"),
            f("iqdisc_opts", "入站队列参数", .text, "原样传给队列脚本，固件不校验语义；仅在确认上游脚本支持时使用。"),
            f("eqdisc_opts", "出站队列参数", .text, "原样传给队列脚本，固件不校验语义；仅在确认上游脚本支持时使用。")]),
            g("链路层", [f("linklayer", "链路层类型", .choice(["none", "ethernet", "atm"])),
            f("overhead", "每包额外开销（字节）", .integer(-1500, 2_147_483_647)), f("linklayer_advanced", "高级链路层选项", .flag),
            f("tcMTU", "最大报文大小", .integer(0, 2_147_483_647)), f("tcTSIZE", "速率表大小", .integer(0, 2_147_483_647)),
            f("tcMPU", "最小报文大小", .integer(0, 2_147_483_647)), f("linklayer_adaptation_mechanism", "开销补偿机制", .choice(["default", "cake", "htb_private", "tc_stab"]))])])
    ], note: "速率为 kbit/s，设为 0 表示关闭该方向整形。高级参数按 SQM 上游配置语义显示；危险队列参数会原样传给脚本。实际队列及统计另在运行状态读取，不以配置替代。")

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
    ], note: "本页编辑服务及访问控制；运行管理单独读取实际端口映射并提供详情和删除。静态 ACL 不代表当前映射。")

    static let homeproxy = Self(id: "homeproxy", title: "HomeProxy", config: "homeproxy", sections: [
        s("homeproxy", "主配置", [g("路由", [f("main_node", "主节点", .text, "节点名称由路由器当前配置返回；此处不猜测节点。"),
            f("main_urltest_nodes", "URLTest 节点", .list), f("main_urltest_interval", "URLTest 间隔（秒）", .integer(1, 2_147_483_647)),
            f("main_urltest_tolerance", "URLTest 容差（毫秒）", .integer(0, 2_147_483_647)), f("main_udp_node", "UDP 主节点"),
            f("main_udp_urltest_nodes", "UDP URLTest 节点", .list), f("main_udp_urltest_interval", "UDP URLTest 间隔（秒）", .integer(1, 2_147_483_647)),
            f("main_udp_urltest_tolerance", "UDP URLTest 容差（毫秒）", .integer(0, 2_147_483_647)),
            f("dns_server", "DNS 服务器"), f("china_dns_server", "中国 DNS 服务器"),
            f("routing_mode", "分流模式", .choice(["gfwlist", "bypass_mainland_china", "proxy_mainland_china", "custom", "global"])),
            f("routing_port", "分流端口", .text, "留空为全部端口，common 为常用端口，也可填写固件支持的端口范围。"), f("proxy_mode", "代理模式", .text, "可用模式取决于固件 TUN / TProxy 内核能力。"),
            f("ipv6_support", "IPv6 支持", .flag)])], addable: false, ids: ["config"]),
        s("homeproxy", "自定义路由设置", [g("路由", [f("tcpip_stack", "TCP/IP 协议栈"), f("endpoint_independent_nat", "端点无关 NAT", .flag),
            f("udp_timeout", "UDP NAT 超时（秒）", .integer(0, 2_147_483_647)), f("bypass_cn_traffic", "绕过中国流量", .flag),
            f("domain_strategy", "域名策略"), f("default_outbound", "默认出口"), f("default_outbound_dns", "默认出口 DNS")])], addable: false, ids: ["routing"]),
        s("homeproxy", "DNS 设置", [g("DNS", [f("default_strategy", "默认解析策略"), f("default_server", "默认 DNS 服务器"),
            f("disable_cache", "禁用 DNS 缓存", .flag), f("disable_cache_expire", "不让缓存过期", .flag),
            f("client_subnet", "EDNS 客户端网段", .prefix), f("cache_file_store_rdrc", "缓存拒绝响应", .flag),
            f("cache_file_rdrc_timeout", "拒绝响应缓存超时（秒）", .integer(0, 2_147_483_647))])], addable: false, ids: ["dns"]),
        s("node", "代理节点", [g("节点", [f("label", "节点名称", required: true),
            f("type", "节点类型", .text, "可选类型来自当前 sing-box 编译能力；现有未知值保持原样。", required: true),
            f("address", "地址", required: true, when: ("type", ["anytls", "http", "hysteria", "hysteria2", "shadowsocks", "shadowtls", "socks", "ssh", "trojan", "tuic", "wireguard", "vless", "vmess"])),
            f("port", "端口", .integer(1, 65535), required: true, when: ("type", ["anytls", "http", "hysteria", "hysteria2", "shadowsocks", "shadowtls", "socks", "ssh", "trojan", "tuic", "wireguard", "vless", "vmess"])), f("override_address", "直连覆盖地址", when: ("type", ["direct"])),
            f("override_port", "直连覆盖端口", .integer(1, 65535), when: ("type", ["direct"])),
            f("username", "用户名"), f("password", "密码", .secret), f("uuid", "UUID", .secret),
            f("tls_sni", "TLS 服务器名"), f("tls", "启用 TLS", .flag), f("tls_insecure", "允许不安全 TLS", .flag),
            f("transport", "传输方式"), f("http_host", "HTTP 主机", .list), f("http_path", "HTTP 路径"), f("ws_path", "WebSocket 路径"),
            f("grpc_servicename", "gRPC 服务名"), f("multiplex", "多路复用", .flag), f("tcp_fast_open", "TCP Fast Open", .flag)]),
            g("协议参数", [f("shadowsocks_encrypt_method", "Shadowsocks 加密方法", when: ("type", ["shadowsocks"])),
            f("vmess_encrypt", "VMess 加密方法", when: ("type", ["vmess"])), f("vmess_alterid", "VMess Alter ID", .integer(0, 65535), when: ("type", ["vmess"])),
            f("vless_flow", "VLESS Flow", when: ("type", ["vless"])), f("packet_encoding", "数据包编码"),
            f("tls_alpn", "TLS ALPN", .list), f("tls_utls", "uTLS 指纹"), f("tls_reality", "Reality", .flag),
            f("tls_reality_public_key", "Reality 公钥"), f("tls_reality_short_id", "Reality Short ID")]),
            g("WireGuard", [f("wireguard_local_address", "本地隧道地址", .list, when: ("type", ["wireguard"]), items: .prefix),
            f("wireguard_private_key", "私钥", .secret, when: ("type", ["wireguard"])),
            f("wireguard_peer_public_key", "对端公钥", when: ("type", ["wireguard"])),
            f("wireguard_pre_shared_key", "预共享密钥", .secret, when: ("type", ["wireguard"])),
            f("wireguard_mtu", "MTU", .integer(0, 9000), when: ("type", ["wireguard"])),
            f("wireguard_persistent_keepalive_interval", "保活间隔（秒）", .integer(0, 65535), when: ("type", ["wireguard"]))])], named: true),
        s("homeproxy", "节点订阅", [g("订阅", [f("auto_update", "自动更新", .flag), f("auto_update_time", "更新时间（小时）", .integer(0, 23)),
            f("update_via_proxy", "通过代理更新", .flag), f("subscription_url", "订阅 URL", .list),
            f("filter_nodes", "节点过滤", .choice(["disabled", "blacklist", "whitelist"])), f("filter_keywords", "过滤关键词", .list),
            f("user_agent", "User-Agent"), f("allow_insecure", "允许不安全连接", .flag), f("packet_encoding", "默认数据包编码", .choice(["", "packetaddr", "xudp"]))])], addable: false, ids: ["subscription"]),
        s("routing_node", "路由节点", [g("节点", [f("label", "说明"), f("enabled", "启用", .flag), f("node", "代理节点标识"),
            f("domain_resolver", "域名解析服务器"), f("domain_strategy", "解析策略"), f("bind_interface", "绑定设备"),
            f("outbound", "上级出口"), f("urltest_nodes", "URLTest 节点", .list), f("urltest_url", "测试 URL"),
            f("urltest_interval", "测试间隔（秒）", .integer(1, 2_147_483_647)), f("urltest_tolerance", "测试容差（毫秒）", .integer(0, 2_147_483_647)),
            f("urltest_idle_timeout", "空闲超时（秒）", .integer(0, 2_147_483_647)), f("urltest_interrupt_exist_connections", "中断已有连接", .flag)])], named: true),
        s("dns_server", "DNS 服务器", [g("服务器", [f("label", "说明"), f("enabled", "启用", .flag),
            f("type", "传输类型", .choice(["udp", "tcp", "tls", "https", "h3", "quic"]), required: true), f("server", "服务器地址", required: true),
            f("server_port", "端口", .integer(1, 65535)), f("path", "DoH 路径", when: ("type", ["https", "h3"])), f("headers", "请求头", .list, when: ("type", ["https", "h3"])),
            f("tls_sni", "TLS SNI", when: ("type", ["tls", "https", "h3", "quic"])), f("address_resolver", "地址解析器"), f("address_strategy", "地址策略"), f("outbound", "连接出口")])], named: true),
        s("ruleset", "规则集", [g("规则集", [f("label", "说明"), f("enabled", "启用", .flag), f("type", "类型", .choice(["local", "remote"]), required: true),
            f("format", "格式", .choice(["binary", "source"]), required: true), f("path", "本地路径", required: true, when: ("type", ["local"])),
            f("url", "规则集 URL", required: true, when: ("type", ["remote"])), f("outbound", "下载出口"), f("update_interval", "更新间隔")])], named: true),
        s("homeproxy", "访问控制", [g("接口控制", [f("listen_interfaces", "监听设备", .list), f("bind_interface", "出口绑定设备")]),
            g("LAN IP 策略", [f("lan_proxy_mode", "代理过滤模式", .choice(["disabled", "listed_only", "except_listed"])),
                f("lan_direct_ipv4_ips", "直连 IPv4", .list, items: .prefix), f("lan_direct_ipv6_ips", "直连 IPv6", .list, items: .prefix),
                f("lan_direct_mac_addrs", "直连 MAC", .list, items: .mac), f("lan_proxy_ipv4_ips", "代理 IPv4", .list, items: .prefix),
                f("lan_proxy_ipv6_ips", "代理 IPv6", .list, items: .prefix), f("lan_proxy_mac_addrs", "代理 MAC", .list, items: .mac)]),
            g("WAN IP 策略", [f("wan_proxy_ipv4_ips", "代理 IPv4", .list, items: .prefix), f("wan_proxy_ipv6_ips", "代理 IPv6", .list, items: .prefix),
                f("wan_direct_ipv4_ips", "直连 IPv4", .list, items: .prefix), f("wan_direct_ipv6_ips", "直连 IPv6", .list, items: .prefix)])], addable: false, ids: ["control"]),
        s("routing_rule", "路由规则", homeproxyMatchGroups + [g("路由动作", [
            f("action", "动作", .choice(["route", "route-options", "reject", "resolve"])), f("outbound", "出口节点", when: ("action", ["route"])),
            f("override_address", "覆盖地址", when: ("action", ["route", "route-options"])), f("override_port", "覆盖端口", .integer(1, 65535), when: ("action", ["route", "route-options"])),
            f("udp_disable_domain_unmapping", "禁用 UDP 域名反向映射", .flag), f("udp_connect", "UDP 使用 connect", .flag), f("udp_timeout", "UDP 超时"),
            f("resolve_server", "解析服务器", when: ("action", ["resolve"])), f("resolve_strategy", "解析策略", when: ("action", ["resolve"])),
            f("resolve_disable_cache", "禁用解析缓存", .flag, when: ("action", ["resolve"])), f("resolve_rewrite_ttl", "解析 TTL", .integer(0, 2_147_483_647), when: ("action", ["resolve"])),
            f("resolve_client_subnet", "EDNS 客户端网段", .prefix, when: ("action", ["resolve"])),
            f("reject_method", "拒绝方式", .choice(["default", "drop"]), when: ("action", ["reject"])), f("reject_no_drop", "不自动丢弃", .flag, when: ("action", ["reject"]))])], named: true),
        s("dns_rule", "DNS 规则", homeproxyMatchGroups + [g("DNS 动作", [f("query_type", "查询类型", .list),
            f("action", "动作", .choice(["route", "route-options", "reject", "predefined"])), f("server", "DNS 服务器", when: ("action", ["route"])),
            f("domain_strategy", "域名策略", when: ("action", ["route"])), f("dns_disable_cache", "禁用缓存", .flag, when: ("action", ["route", "route-options"])),
            f("rewrite_ttl", "改写 TTL", .integer(0, 2_147_483_647), when: ("action", ["route", "route-options"])),
            f("client_subnet", "EDNS 客户端网段", .prefix, when: ("action", ["route", "route-options"])), f("rule_set_ip_cidr_accept_empty", "接受空查询响应", .flag),
            f("reject_method", "拒绝方式", .choice(["default", "drop"]), when: ("action", ["reject"])), f("reject_no_drop", "不自动丢弃", .flag, when: ("action", ["reject"])),
            f("predefined_rcode", "响应码", .choice(["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"]), when: ("action", ["predefined"])),
            f("predefined_answer", "响应记录", .list, when: ("action", ["predefined"])), f("predefined_ns", "名称服务器记录", .list, when: ("action", ["predefined"])),
            f("predefined_extra", "附加记录", .list, when: ("action", ["predefined"]))])], named: true)
    ], note: "节点、订阅、分流和 DNS 使用专用配置草稿；状态页单独读取内核能力、资源版本、连通性及日志。保存订阅 URL 不等于已经更新节点。服务端、证书、导入和部分协议高级参数仍待适配。")
}
