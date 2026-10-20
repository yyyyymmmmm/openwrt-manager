import Foundation
import OpenWrtKit

extension NativeConfigurationSchema {
    static let wol = Self(id: "wol", title: "唤醒目标配置", config: "luci-wol", sections: [
        s("wol", "默认工具", [g("工具", [f("executable", "默认唤醒工具", .choice([]), "选择当前路由器实际可执行的工具；未设置时发送页要求明确选择。")])], named: true, addable: false, ids: ["defaults"]),
        s("target", "唤醒目标", [
            g("目标设备", [f("name", "目标名称", required: true), f("mac", "MAC 地址", .mac, "主机提示不代表设备当前在线。", required: true)]),
            g("Etherwake 选项", [f("iface", "发送接口", .choice([]), "未设置时使用 Etherwake 的默认接口。Wakeonlan 不支持此项。"),
                f("broadcast", "广播发送", .flag, "仅 Etherwake 使用。"),
                f("password", "SecureOn 密码", .secret, "六组十六进制字节或四组十进制字节；不是路由器登录密码。仅 Etherwake 使用。")])
        ])
    ], note: "目标保存在路由器 luci-wol 配置。新增、修改、删除和排序先存为草稿，再预览、应用并确认。网络唤醒页只发送已重新读取的目标。")

    func resolvedWOLSections(runtime: WakeOnLANSnapshot?) -> [NativeSectionSchema] {
        sections.map { original in
            var section = original
            section.groups = section.groups.map { original in
                var group = original
                group.fields = group.fields.map { original in
                    var field = original
                    if field.id == "executable" {
                        field.restrictToChoices = true
                        field.kind = .choice(runtime?.capabilities?.tools.map(\.rawValue) ?? [])
                        field.choiceLabels = Dictionary(uniqueKeysWithValues: (runtime?.capabilities?.tools ?? []).map { ($0.rawValue, $0.title) })
                        if runtime?.capabilities == nil { field.editingUnavailableReason = "未能确认唤醒工具，请返回重新读取。" }
                    } else if field.id == "iface" {
                        field.restrictToChoices = true
                        field.kind = .choice(runtime?.devices?.filter { $0.up == true }.map(\.name) ?? [])
                        if runtime?.devices == nil { field.editingUnavailableReason = "网络设备读取失败，不能猜测接口。" }
                    } else if field.id == "mac" {
                        field.suggestions = Dictionary(uniqueKeysWithValues: (runtime?.hosts ?? []).map { ($0.mac, $0.label.isEmpty ? $0.mac : $0.label + " · " + $0.mac) })
                    }
                    return field
                }
                return group
            }
            return section
        }
    }

    func resolvedSQMSections(runtime: SQMRuntimeSnapshot?) -> [NativeSectionSchema] {
        sections.map { definition in
            var section = definition
            section.groups = section.groups.map { originalGroup in
                var group = originalGroup
                group.fields = group.fields.map { original in
                    var field = original
                    switch field.id {
                    case "interface":
                        field.kind = .choice(runtime?.devices?.map(\.name) ?? [])
                        field.restrictToChoices = true
                        if runtime?.devices == nil { field.editingUnavailableReason = "网络设备读取失败；保留当前值，不能猜测接口。" }
                    case "qdisc":
                        field.kind = .choice(runtime?.qdiscs ?? [])
                        field.restrictToChoices = true
                        if runtime?.qdiscs == nil { field.editingUnavailableReason = "队列规则清单读取失败；保留当前值，不能猜测已安装能力。" }
                    case "script":
                        field.kind = .choice(runtime?.scripts ?? [])
                        field.restrictToChoices = true
                        if runtime?.scripts == nil { field.editingUnavailableReason = "SQM 脚本清单读取失败；保留当前值，不能猜测已安装脚本。" }
                    case "verbosity":
                        field.choiceLabels = ["0": "静默", "1": "错误", "2": "警告", "5": "信息（上游默认）", "8": "调试", "10": "跟踪"]
                        field.restrictToChoices = true
                    case "use_mq", "squash_dscp", "squash_ingress", "ingress_ecn", "egress_ecn":
                        field.additionalConditions["qdisc_advanced"] = ["1"]
                    case "qdisc_really_really_advanced":
                        field.additionalConditions["qdisc_advanced"] = ["1"]
                    case "ilimit", "elimit", "itarget", "etarget", "iqdisc_opts", "eqdisc_opts":
                        field.additionalConditions["qdisc_advanced"] = ["1"]
                        field.additionalConditions["qdisc_really_really_advanced"] = ["1"]
                    case "overhead", "linklayer_advanced":
                        field.additionalConditions["linklayer"] = ["ethernet", "atm"]
                    case "tcMTU", "tcTSIZE", "tcMPU", "linklayer_adaptation_mechanism":
                        field.additionalConditions["linklayer"] = ["ethernet", "atm"]
                        field.additionalConditions["linklayer_advanced"] = ["1"]
                    default: break
                    }
                    return field
                }
                return group
            }
            return section
        }
    }

    func resolvedPluginSections(configuration: RouterConfiguration?, capabilities: HomeProxyCapabilities?) -> [NativeSectionSchema] {
        sections.map { definition in
            let groups = definition.groups.map { group in
                let fields = group.fields.map { original -> NativeField in
                    var field = original
                    if id == "mosdns", !["enabled", "configfile", "redirect"].contains(field.id) {
                        field.additionalConditions["configfile"] = ["", "/var/etc/mosdns.json"]
                        if ["prefetch_before_expire", "prefetch_min_hits", "prefetch_scan_interval", "dump_interval"].contains(field.id) {
                            field.additionalConditions["cache"] = ["1"]
                        }
                        if field.id == "stats_dump_interval" { field.additionalConditions["stats_collector"] = ["1"] }
                    }
                    if id == "homeproxy" {
                        let nodeType = definition.type == "node" && field.id == "type"
                        let proxyMode = definition.sectionIDs == ["config"] && field.id == "proxy_mode"
                        if nodeType || proxyMode {
                            if let capabilities { field.kind = .choice(nodeType ? capabilities.nodeTypes : capabilities.proxyModes) }
                            else { field.editingUnavailableReason = "内核能力尚未确认，当前值保留；返回上级重新读取。" }
                        }
                        if definition.type == "dns_server", field.id == "type" {
                            if let capabilities {
                                field.kind = .choice(["udp", "tcp", "tls", "https"] + (capabilities.features["with_quic"] == true ? ["h3", "quic"] : []))
                            } else { field.editingUnavailableReason = "内核能力尚未确认，当前值保留；返回上级重新读取。" }
                        }
                        if let configuration {
                            let nodeLabels = labels(configuration, type: "node")
                            let routingLabels = labels(configuration, type: "routing_node", enabledOnly: true)
                            let dnsLabels = labels(configuration, type: "dns_server", enabledOnly: true)
                                .merging(["default-dns": "默认 DNS（由上联下发）", "system-dns": "系统 DNS"]) { _, new in new }
                            var choices: [String: String]?
                            if definition.sectionIDs == ["config"] {
                                if field.id == "main_node" { choices = nodeLabels.merging(["nil": "停用", "urltest": "URLTest"]) { _, new in new } }
                                if field.id == "main_udp_node" { choices = nodeLabels.merging(["nil": "停用", "same": "与主节点相同", "urltest": "URLTest"]) { _, new in new } }
                            }
                            if definition.sectionIDs == ["routing"] {
                                if field.id == "default_outbound" { choices = routingLabels.merging(["nil": "停用服务", "direct-out": "直连", "block-out": "阻止"]) { _, new in new } }
                                if field.id == "default_outbound_dns" { choices = dnsLabels }
                            }
                            if definition.sectionIDs == ["dns"], field.id == "default_server" { choices = dnsLabels }
                            if definition.type == "routing_node", field.id == "node" { choices = nodeLabels.merging(["urltest": "URLTest"]) { _, new in new } }
                            if definition.type == "routing_node", field.id == "domain_resolver" { choices = dnsLabels.merging(["": "默认"]) { _, new in new } }
                            if definition.type == "dns_rule", field.id == "server" { choices = dnsLabels }
                            if definition.type == "routing_rule", field.id == "resolve_server" { choices = dnsLabels }
                            if let choices {
                                field.kind = .choice(choices.keys.sorted()); field.choiceLabels = choices
                                field.help = "标识与名称来自当前配置草稿；保存后仍需核对业务结果。"
                            }
                        }
                    }
                    return field
                }
                return NativeFieldGroup(title: group.title, fields: fields)
            }
            return NativeSectionSchema(type: definition.type, title: definition.title, groups: groups,
                                       named: definition.named, addable: definition.addable, sectionIDs: definition.sectionIDs)
        }
    }

    private func labels(_ configuration: RouterConfiguration, type: String, enabledOnly: Bool = false) -> [String: String] {
        var result: [String: String] = [:]
        for section in configuration.sections where section.type == type && (!enabledOnly || section.values["enabled"]?.stringValue == "1") {
            result[section.id] = (section.values["label"]?.stringValue ?? section.id) + " (" + section.id + ")"
        }
        return result
    }
    static func pluginAdapter(menuID: String) -> Self? {
        switch menuID {
        case "admin/services/homeproxy": return .homeproxy
        case "admin/services/mosdns": return .mosdns
        case "admin/services/zerotier": return .zerotier
        case "admin/services/ddns": return .ddns
        case "admin/network/sqm": return .sqm
        case "admin/services/upnp", "admin/network/upnp": return .upnp
        case "admin/services/wol", "admin/network/wol": return .wol
        default: return nil
        }
    }

    static func pluginAdapter(packageName: String) -> Self? {
        // This registers dedicated adapters; package discovery still lists every extension.
        switch packageName {
        case "luci-app-homeproxy": return .homeproxy
        case "luci-app-mosdns": return .mosdns
        case "luci-app-zerotier": return .zerotier
        case "luci-app-ddns": return .ddns
        case "luci-app-sqm": return .sqm
        case "luci-app-upnp": return .upnp
        case "luci-app-wol": return .wol
        default: return nil
        }
    }
    static let homeproxyMatchGroups: [NativeFieldGroup] = [
        g("匹配条件", [f("label", "说明"), f("enabled", "启用", .flag), f("mode", "匹配模式", .choice(["default"])),
            f("ip_version", "IP 版本", .choice(["", "4", "6"])), f("protocol", "协议", .list), f("network", "网络", .choice(["", "tcp", "udp"])),
            f("user", "用户", .list), f("rule_set", "规则集标识", .list), f("rule_set_ip_cidr_match_source", "规则集匹配源地址", .flag), f("invert", "反向匹配", .flag)]),
        g("域名与地址", [f("domain", "域名", .list), f("domain_suffix", "域名后缀", .list), f("domain_keyword", "域名关键词", .list),
            f("domain_regex", "域名正则表达式", .list), f("source_ip_cidr", "源 IP 网段", .list, items: .prefix), f("source_ip_is_private", "源为私网地址", .flag),
            f("ip_cidr", "目标 IP 网段", .list, items: .prefix), f("ip_is_private", "目标为私网地址", .flag)]),
        g("端口与进程", [f("source_port", "源端口", .list), f("source_port_range", "源端口范围", .list, "每行 START:END、START: 或 :END。"),
            f("port", "目标端口", .list), f("port_range", "目标端口范围", .list), f("process_name", "进程名称", .list),
            f("process_path", "进程路径", .list), f("process_path_regex", "进程路径正则表达式", .list)])
    ]

    static let zerotier = Self(id: "zerotier", title: "ZeroTier 配置", config: "zerotier", sections: [
        s("zerotier", "全局配置", [g("基本设置", [f("enabled", "启用", .flag), f("port", "监听端口", .integer(1, 65535)),
            f("secret", "客户端身份密钥", .secret), f("fw_allow_input", "允许守护进程入站流量", .flag)]),
            g("配置存储", [f("local_conf_path", "local.conf 路径"), f("config_path", "持久配置目录"),
            f("copy_config_path", "将持久配置复制到内存", .flag)])], addable: false, ids: ["global"]),
        s("network", "虚拟网络", [g("网络", [f("id", "网络 ID", .hexadecimal(16), "16 位十六进制网络 ID；加入后还需控制器授权。上游启动脚本按 network 节加入网络，不读取网络级 enabled 开关。", required: true),
            f("allow_managed", "接受私网 IP 和路由", .flag), f("allow_global", "接受公网 IP 和路由", .flag),
            f("allow_default", "接受默认路由", .flag, "可能改变旁路由或主路由的上联。"), f("allow_dns", "接受 DNS", .flag)]),
            g("防火墙", [f("fw_allow_input", "允许入站", .flag), f("fw_allow_forward", "允许转发", .flag),
            f("fw_forward_ifaces", "转发设备", .list, "未设置时使用固件行为。", when: ("fw_allow_forward", ["1"])),
            f("fw_allow_masq", "启用地址伪装", .flag), f("fw_masq_ifaces", "伪装出口设备", .list, when: ("fw_allow_masq", ["1"]))])])
    ], note: "新增、删除网络先存为草稿，预览、应用并确认后，到网络状态页执行服务操作并核对实际网络。自定义持久目录可能保留已从 UCI 删除的网络；以客户端重读为准。未识别的现有字段保持原值，不提供未经核实的启用开关。")

    static let mosdns = Self(id: "mosdns", title: "MosDNS 配置", config: "mosdns", sections: [
        s("mosdns", "配置", [
            g("基本设置", [f("enabled", "启用", .flag), f("configfile", "配置文件", .choice(["/var/etc/mosdns.json", "/etc/mosdns/config_custom.yaml"])),
                f("redirect", "转发 dnsmasq 查询", .flag),
                f("listen_port", "监听端口", .integer(1, 65535)), f("listen_address", "监听地址", .address),
                f("log_level", "日志等级", .choice(["debug", "info", "warn", "error"])), f("log_file", "日志文件"), f("log_size", "日志大小（MB）", .integer(0, 2_147_483_647))]),
            g("上游与分流", [f("prefer_ipv4_cn", "中国 DNS 优先 IPv4", .flag), f("prefer_ipv4", "远程 DNS 优先 IPv4", .flag),
                f("custom_local_dns", "自定义中国 DNS", .flag), f("apple_optimization", "Apple 域名优化", .flag, when: ("custom_local_dns", ["1"])),
                f("local_dns", "中国 DNS", .list, when: ("custom_local_dns", ["1"])), f("remote_dns", "远程 DNS", .list),
                f("custom_stream_media_dns", "自定义流媒体 DNS", .flag), f("stream_media_dns", "流媒体 DNS", .list, when: ("custom_stream_media_dns", ["1"])),
                f("bootstrap_dns", "引导 DNS", .text, "用于解析 DoH / DoT 上游的服务器地址。")]),
            g("高级设置", [f("concurrent", "并发上游数", .integer(1, 3)), f("idle_timeout", "空闲超时（秒）", .integer(1, 2_147_483_647)),
                f("enable_pipeline", "TCP / DoT 流水线", .flag), f("insecure_skip_verify", "跳过 TLS 证书校验", .flag),
                f("enable_ecs_remote", "远程 EDNS 客户端网段", .flag), f("remote_ecs_ip", "EDNS IP 地址", .address, when: ("enable_ecs_remote", ["1"])),
                f("dns_leak", "防止 DNS 泄漏", .flag), f("minimal_ttl", "最小 TTL（秒）", .integer(0, 604800)),
                f("maximum_ttl", "最大 TTL（秒）", .integer(0, 604800)), f("reject_type65", "拒绝 HTTPS / SVCB 记录", .flag)]),
            g("缓存", [f("cache", "启用 DNS 缓存", .flag), f("cache_size", "缓存条目数", .integer(0, 2_147_483_647), when: ("cache", ["1"])),
                f("lazy_cache_ttl", "惰性缓存 TTL（秒）", .integer(0, 2_147_483_647), when: ("cache", ["1"])),
                f("prefetch", "预取缓存", .flag, when: ("cache", ["1"])), f("prefetch_before_expire", "过期前预取（秒）", .integer(1, 2_147_483_647), when: ("prefetch", ["1"])),
                f("prefetch_min_hits", "预取最少命中次数", .integer(1, 2_147_483_647), when: ("prefetch", ["1"])),
                f("prefetch_scan_interval", "预取扫描间隔（秒）", .integer(1, 2_147_483_647), when: ("prefetch", ["1"])),
                f("dump_file", "持久化缓存", .flag, when: ("cache", ["1"])), f("dump_interval", "保存间隔（秒）", .integer(0, 2_147_483_647), when: ("dump_file", ["1"]))]),
            g("广告与 Cloudflare", [f("adblock", "DNS 广告过滤", .flag), f("ad_source", "规则来源", .list, when: ("adblock", ["1"])),
                f("cloudflare", "替换 Cloudflare 解析结果", .flag), f("cloudflare_ip", "替换 IP", .list, when: ("cloudflare", ["1"]), items: .address)]),
            g("API 与统计", [f("listen_port_api", "API 监听端口", .integer(1, 65535)), f("stats_collector", "收集查询统计", .flag),
                f("stats_capacity", "统计环形缓冲区容量", .integer(1, 2_147_483_647), when: ("stats_collector", ["1"])),
                f("stats_dump_file", "持久化统计", .flag, when: ("stats_collector", ["1"])),
                f("stats_dump_interval", "统计保存间隔（秒）", .integer(1, 2_147_483_647), when: ("stats_dump_file", ["1"]))]),
            g("GeoData 导出", [f("geosite_tags", "GeoSite 标签", .list), f("geoip_tags", "GeoIP 标签", .list)])
        ], addable: false, ids: ["config"])
    ], note: "字段对应 MosDNS v5 的内置配置；自定义 YAML 模式下仅编辑启用、配置文件及 dnsmasq 转发。状态页提供日志、缓存清空、规则更新请求及更新日志。自定义文件、Cloudflare 网段文件与统计查询尚未适配。")
}
