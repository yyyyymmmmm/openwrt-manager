import Foundation

// MARK: - Health grades (package E, standard 2)
//
// One rating vocabulary for the whole app. Thresholds live here and
// nowhere else: a page never invents its own idea of "high". Grades
// are ordered by severity so callers can take the worst of several.

public enum HealthGrade: Int, Equatable, Sendable, Comparable {
    case excellent = 0
    case good = 1
    case fair = 2
    case poor = 3
    case critical = 4
    case unknown = 5

    public static func < (lhs: HealthGrade, rhs: HealthGrade) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The worst of a set of grades; unknown only wins when nothing
    /// else is known.
    public static func worst(of grades: [HealthGrade]) -> HealthGrade {
        let known = grades.filter { $0 != .unknown }
        return known.max() ?? .unknown
    }

    /// Label for level-type metrics (usage, load, CPU): how bad the
    /// level is.
    public var label: String {
        switch self {
        case .excellent: return KitL10n.text("优秀")
        case .good: return KitL10n.text("良好")
        case .fair: return KitL10n.text("一般")
        case .poor: return KitL10n.text("偏高")
        case .critical: return KitL10n.text("异常")
        case .unknown: return KitL10n.text("未知")
        }
    }

    /// Label for strength-type metrics (Wi-Fi signal): how strong the
    /// signal is. The thresholds are the same grades; only the words
    /// differ, because "high" is praise for a signal and a warning
    /// for a usage level.
    public var strengthLabel: String {
        switch self {
        case .excellent: return KitL10n.text("优秀")
        case .good: return KitL10n.text("良好")
        case .fair: return KitL10n.text("一般")
        case .poor: return KitL10n.text("较弱")
        case .critical: return KitL10n.text("很弱")
        case .unknown: return KitL10n.text("未知")
        }
    }
}

public enum HealthRating {
    /// Fill-ratio metrics — memory, storage, connection table: what
    /// percent of the capacity is used.
    public static func usageGrade(percent: Double) -> HealthGrade {
        switch percent {
        case ..<0: return .unknown
        case ...50: return .excellent
        case ...70: return .good
        case ...85: return .fair
        case ...95: return .poor
        default: return .critical
        }
    }

    /// A single process's (or the whole CPU's) busy percent.
    public static func cpuGrade(percent: Double) -> HealthGrade {
        switch percent {
        case ..<0: return .unknown
        case ...25: return .excellent
        case ...50: return .good
        case ...75: return .fair
        case ...90: return .poor
        default: return .critical
        }
    }

    /// 1-minute load average, judged per core: a load of 2 is idle on
    /// a 4-core box and saturated on a single core. Callers that do
    /// not know the core count pass nil and get the conservative
    /// single-core judgement.
    public static func loadGrade(load: Double, cores: Int?) -> HealthGrade {
        guard load >= 0 else { return .unknown }
        let perCore = load / Double(max(cores ?? 1, 1))
        switch perCore {
        case ...0.5: return .excellent
        case ...0.8: return .good
        case ...1.0: return .fair
        case ...1.5: return .poor
        default: return .critical
        }
    }

    /// Wi-Fi signal strength in dBm (negative; closer to zero is
    /// stronger). The -67 dBm boundary is the usual voice-grade line.
    public static func signalGrade(dBm: Double) -> HealthGrade {
        switch dBm {
        case (-50.0)...: return .excellent
        case (-60.0)...: return .good
        case (-67.0)...: return .fair
        case (-75.0)...: return .poor
        default: return .critical
        }
    }

    /// Display fraction for a signal strength: the meter under a
    /// dBm value. Linear over the range a user can act on — −30 dBm
    /// (next to the AP) is full, −90 dBm (edge of audibility) empty.
    /// A rendering scale only; the grade above carries the verdict.
    public static func signalFraction(dBm: Double) -> Double {
        min(max((dBm + 90) / 60, 0), 1)
    }

    /// Channel congestion: how many *other* networks share the
    /// channel this radio is on. Co-channel neighbours are the one
    /// thing a channel choice can actually fix, so the count is the
    /// grade — none is excellent, a crowd is critical.
    public static func channelGrade(coChannelCount: Int) -> HealthGrade {
        switch coChannelCount {
        case ...0: return .excellent
        case 1...2: return .good
        case 3...4: return .fair
        case 5...7: return .poor
        default: return .critical
        }
    }

    /// Connection-table fill (conntrack): a ratio when the maximum
    /// is known, unknown otherwise — never guessed.
    public static func connectionsGrade(used: Int, maximum: Int?) -> HealthGrade {
        guard let maximum, maximum > 0 else { return .unknown }
        return usageGrade(percent: Double(used) / Double(maximum) * 100)
    }

    public static func fraction(used: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    public static func percent(used: Int64, total: Int64) -> Double? {
        fraction(used: used, total: total).map { $0 * 100 }
    }
}

// MARK: - Page summaries (package E, standard 1)
//
// Every major page opens with one human sentence: what this page is
// about and whether things are fine. The sentences are generated
// from the data by these rules — thresholds come from HealthRating,
// wording from the string table — never written per page.

public enum SummaryTone: String, Equatable, Sendable {
    case good, neutral, warning, bad, unknown
}

public struct PageSummary: Equatable, Sendable {
    public var headline: String
    public var tone: SummaryTone
    public init(headline: String, tone: SummaryTone) {
        self.headline = headline; self.tone = tone
    }
}

public enum SummaryEngine {

    public static func overview(upstreamUp: Bool?, memoryPercent: Double?,
                                storagePercent: Double?, onlineDevices: Int?) -> PageSummary {
        if upstreamUp == false {
            return PageSummary(headline: KitL10n.text("上网异常：路由器没有连上互联网"), tone: .bad)
        }
        let memoryGrade = memoryPercent.map(HealthRating.usageGrade) ?? .unknown
        let storageGrade = storagePercent.map(HealthRating.usageGrade) ?? .unknown
        if memoryGrade == .critical {
            return PageSummary(headline: KitL10n.text("内存几乎占满，路由器可能运行不稳定"), tone: .bad)
        }
        if storageGrade == .critical {
            return PageSummary(headline: KitL10n.text("存储几乎占满，可能影响运行"), tone: .bad)
        }
        if memoryGrade == .poor {
            return PageSummary(headline: KitL10n.text("内存偏紧，建议关注"), tone: .warning)
        }
        if storageGrade == .poor {
            return PageSummary(headline: KitL10n.text("存储空间偏紧，建议关注"), tone: .warning)
        }
        if let onlineDevices {
            return PageSummary(headline: KitL10n.format("网络正常，%lld 台设备在线", onlineDevices), tone: .good)
        }
        if upstreamUp == true {
            return PageSummary(headline: KitL10n.text("网络正常，路由器运行平稳"), tone: .good)
        }
        return PageSummary(headline: KitL10n.text("路由器运行平稳"), tone: .neutral)
    }

    public static func services(running: Int, stopped: Int, unknown: Int) -> PageSummary {
        let total = running + stopped + unknown
        guard total > 0 else {
            return PageSummary(headline: KitL10n.text("尚未发现服务"), tone: .neutral)
        }
        if running == total {
            return PageSummary(headline: KitL10n.format("全部 %lld 个服务都在运行", total), tone: .good)
        }
        if running == 0 && stopped == 0 {
            return PageSummary(headline: KitL10n.text("暂时读不到服务状态"), tone: .neutral)
        }
        if running == 0 {
            return PageSummary(headline: KitL10n.format("%lld 个服务全部处于停止状态", stopped), tone: .warning)
        }
        if unknown > 0 {
            return PageSummary(headline: KitL10n.format("%lld 个运行中 · %lld 个已停止 · %lld 个状态未知",
                                                        running, stopped, unknown), tone: .neutral)
        }
        return PageSummary(headline: KitL10n.format("%lld 个运行中 · %lld 个已停止", running, stopped), tone: .neutral)
    }

    public static func serviceState(running: Bool?) -> PageSummary {
        switch running {
        case true:
            return PageSummary(headline: KitL10n.text("服务正在运行"), tone: .good)
        case false:
            return PageSummary(headline: KitL10n.text("服务已停止，可在下方操作中启动"), tone: .neutral)
        case nil:
            return PageSummary(headline: KitL10n.text("暂时读不到运行状态"), tone: .neutral)
        }
    }

    public static func network(upstreamUp: Bool?, interfacesUp: Int,
                               interfacesTotal: Int, leaseCount: Int) -> PageSummary {
        if upstreamUp == false {
            return PageSummary(headline: KitL10n.text("上游未连接，家里暂时上不了网"), tone: .bad)
        }
        if leaseCount > 0 {
            return PageSummary(headline: KitL10n.format("%lld 个接口在线 · %lld 台设备已分配地址",
                                                        interfacesUp, leaseCount),
                               tone: interfacesUp > 0 ? .good : .neutral)
        }
        return PageSummary(headline: KitL10n.format("%lld 个接口在线", interfacesUp),
                           tone: interfacesUp > 0 ? .good : .neutral)
    }

    public static func interfaces(up: Int, total: Int) -> PageSummary {
        guard total > 0 else {
            return PageSummary(headline: KitL10n.text("路由器没有报告接口"), tone: .neutral)
        }
        if up == total {
            return PageSummary(headline: KitL10n.format("全部 %lld 个接口都已连接", total), tone: .good)
        }
        if up == 0 {
            return PageSummary(headline: KitL10n.text("所有接口都未连接"), tone: .warning)
        }
        return PageSummary(headline: KitL10n.format("%lld 个接口已连接 · %lld 个未连接", up, total - up), tone: .neutral)
    }

    public static func dhcp(leaseCount: Int) -> PageSummary {
        if leaseCount > 0 {
            return PageSummary(headline: KitL10n.format("%lld 台设备已分配到地址", leaseCount), tone: .good)
        }
        return PageSummary(headline: KitL10n.text("暂时没有设备拿到地址"), tone: .neutral)
    }

    public static func wireless(radiosOn: Int, radiosTotal: Int, networkCount: Int) -> PageSummary {
        guard radiosTotal > 0 else {
            return PageSummary(headline: KitL10n.text("这台路由器没有无线"), tone: .neutral)
        }
        if radiosOn == 0 {
            return PageSummary(headline: KitL10n.text("无线已关闭，设备只能插线连接"), tone: .warning)
        }
        return PageSummary(headline: KitL10n.format("%lld 个无线网络正在广播", networkCount), tone: .good)
    }

    public static func wireguard(up: Int, total: Int) -> PageSummary {
        guard total > 0 else {
            return PageSummary(headline: KitL10n.text("没有 WireGuard 接口"), tone: .neutral)
        }
        if up > 0 {
            return PageSummary(headline: KitL10n.text("WireGuard 已连接"), tone: .good)
        }
        return PageSummary(headline: KitL10n.text("WireGuard 未连接"), tone: .warning)
    }

    public static func firewall(tables: Int, chains: Int) -> PageSummary {
        guard tables > 0 else {
            return PageSummary(headline: KitL10n.text("没有读到防火墙规则，防护状态未知"), tone: .warning)
        }
        return PageSummary(headline: KitL10n.format("防火墙正在工作：%lld 张表 · %lld 个链", tables, chains), tone: .good)
    }

    public static func logs(total: Int, errors: Int) -> PageSummary {
        guard total > 0 else {
            return PageSummary(headline: KitL10n.text("暂无日志"), tone: .neutral)
        }
        if errors > 0 {
            return PageSummary(headline: KitL10n.format("最近 %lld 条日志里有 %lld 条错误", total, errors), tone: .warning)
        }
        return PageSummary(headline: KitL10n.format("最近 %lld 条日志，没有错误级别的记录", total), tone: .good)
    }

    public static func processes(total: Int, topName: String?, topCPU: Double?) -> PageSummary {
        if let topName, let topCPU, HealthRating.cpuGrade(percent: topCPU) == .critical {
            return PageSummary(headline: KitL10n.format("%@ 占用了 %lld%% 的 CPU，可能拖慢路由器",
                                                        topName, Int(topCPU.rounded())), tone: .warning)
        }
        return PageSummary(headline: KitL10n.format("共 %lld 个进程在运行", total), tone: .neutral)
    }

    public static func packages(installed: Int) -> PageSummary {
        PageSummary(headline: KitL10n.format("共安装 %lld 个软件包", installed), tone: .neutral)
    }

    public static func startup(enabled: Int, total: Int) -> PageSummary {
        PageSummary(headline: KitL10n.format("%lld 个启动项，其中 %lld 个开机自启", total, enabled), tone: .neutral)
    }

    public static func system(uptime: TimeInterval?, storagePercent: Double?) -> PageSummary {
        if let storagePercent, HealthRating.usageGrade(percent: storagePercent) >= .poor {
            return PageSummary(headline: KitL10n.format("存储偏紧（已用 %lld%%），建议关注",
                                                        Int(storagePercent.rounded())), tone: .warning)
        }
        guard let uptime else {
            return PageSummary(headline: KitL10n.text("系统信息已读取"), tone: .neutral)
        }
        let days = Int(uptime) / 86400
        if days >= 1 {
            return PageSummary(headline: KitL10n.format("已连续运行 %lld 天，运行稳定", days), tone: .good)
        }
        return PageSummary(headline: KitL10n.format("已连续运行 %lld 小时", Int(uptime) / 3600), tone: .neutral)
    }

    public static func storage(percent: Double) -> PageSummary {
        let value = Int(percent.rounded())
        switch HealthRating.usageGrade(percent: percent) {
        case .excellent, .good:
            return PageSummary(headline: KitL10n.format("存储占用 %lld%%，空间充足", value), tone: .good)
        case .fair:
            return PageSummary(headline: KitL10n.format("存储占用 %lld%%", value), tone: .neutral)
        case .poor:
            return PageSummary(headline: KitL10n.format("存储占用 %lld%%，空间偏紧", value), tone: .warning)
        case .critical:
            return PageSummary(headline: KitL10n.format("存储占用 %lld%%，几乎占满", value), tone: .bad)
        case .unknown:
            return PageSummary(headline: KitL10n.text("暂时读不到存储占用"), tone: .neutral)
        }
    }

    public static func genericConfig(sections: Int, rows: Int) -> PageSummary {
        PageSummary(headline: KitL10n.format("共 %lld 个配置节 · %lld 项设置", sections, rows), tone: .neutral)
    }

    public static func openBox(coreRunning: Bool?, groups: Int) -> PageSummary {
        switch coreRunning {
        case true:
            return PageSummary(headline: KitL10n.format("内核运行中 · %lld 个代理组", groups), tone: .good)
        case false:
            return PageSummary(headline: KitL10n.text("内核未运行，代理不可用"), tone: .warning)
        case nil:
            return PageSummary(headline: KitL10n.text("暂时读不到内核状态"), tone: .neutral)
        }
    }

    public static func crontab(entries: Int) -> PageSummary {
        if entries > 0 {
            return PageSummary(headline: KitL10n.format("共 %lld 条计划任务", entries), tone: .neutral)
        }
        return PageSummary(headline: KitL10n.text("没有计划任务"), tone: .neutral)
    }
}

// MARK: - Glossary (package E, standard 3)
//
// One term table for the whole app. Pages name a term; the lookup
// resolves aliases and case, and the explanation is fixed kit copy
// (one human sentence, no jargon inside the explanation itself).

public struct GlossaryTerm: Equatable, Sendable {
    public var term: String
    public var aliases: [String]
    public var explanation: String
    public init(term: String, aliases: [String] = [], explanation: String) {
        self.term = term; self.aliases = aliases; self.explanation = explanation
    }
}

public enum Glossary {
    public static let terms: [GlossaryTerm] = [
        GlossaryTerm(term: "DHCP", aliases: ["dhcp"],
                     explanation: KitL10n.text("自动给家里设备分配 IP 地址的服务；设备连上路由器就能上网，靠的就是它。")),
        GlossaryTerm(term: "DHCP 租约", aliases: ["租约", "lease"],
                     explanation: KitL10n.text("路由器借给一台设备的地址和有效期；到期自动续借，设备地址不变、不会断网。")),
        GlossaryTerm(term: "DNS", aliases: ["dns"],
                     explanation: KitL10n.text("把网址翻译成 IP 地址的电话本；它慢了或出错，网页就会打不开。")),
        GlossaryTerm(term: "ubus", aliases: ["ubus"],
                     explanation: KitL10n.text("OpenWrt 内部的通信总线；这个 App 和网页管理界面都通过它读取和修改路由器。")),
        GlossaryTerm(term: "UCI", aliases: ["uci"],
                     explanation: KitL10n.text("OpenWrt 的统一配置系统；路由器的几乎所有设置都存成 UCI 配置。")),
        GlossaryTerm(term: "nftables", aliases: ["nft", "nftables"],
                     explanation: KitL10n.text("Linux 的新一代防火墙引擎；OpenWrt 的防火墙规则最终都由它执行。")),
        GlossaryTerm(term: "防火墙", aliases: ["firewall"],
                     explanation: KitL10n.text("按规则决定哪些流量能进出路由器的门卫，挡住未经允许的访问。")),
        GlossaryTerm(term: "MTU", aliases: ["mtu"],
                     explanation: KitL10n.text("一个数据包允许的最大尺寸；设置不当会让某些网站打不开或网速变慢。")),
        GlossaryTerm(term: "信道", aliases: ["channel"],
                     explanation: KitL10n.text("Wi-Fi 使用的无线频道；和邻居挤在同一信道会互相干扰、降低速度。")),
        GlossaryTerm(term: "频段", aliases: ["band"],
                     explanation: KitL10n.text("Wi-Fi 的工作频段：2.4 GHz 穿墙好但速度慢，5 GHz 速度快但覆盖近。")),
        GlossaryTerm(term: "SSID", aliases: ["ssid"],
                     explanation: KitL10n.text("Wi-Fi 的网络名称，就是在手机 Wi-Fi 列表里看到的那个名字。")),
        GlossaryTerm(term: "WAN", aliases: ["wan", "上游"],
                     explanation: KitL10n.text("路由器的上行方向，连接光猫或上级网络，是全家上网的出口。")),
        GlossaryTerm(term: "LAN", aliases: ["lan", "局域网"],
                     explanation: KitL10n.text("局域网一侧：家里的手机、电脑、电视都接在这一侧。")),
        GlossaryTerm(term: "网关", aliases: ["gateway"],
                     explanation: KitL10n.text("设备上网时先要经过的下一站，一般就是路由器自己的地址。")),
        GlossaryTerm(term: "子网掩码", aliases: ["netmask"],
                     explanation: KitL10n.text("划定局域网范围的尺子，决定哪些地址算「自己人」。")),
        GlossaryTerm(term: "MAC 地址", aliases: ["mac", "mac 地址"],
                     explanation: KitL10n.text("每块网卡全球唯一的硬件编号；路由器靠它认出是哪一台设备。")),
        GlossaryTerm(term: "IPv4", aliases: ["ipv4"],
                     explanation: KitL10n.text("目前最常用的网络地址格式，例如 192.168.1.1。")),
        GlossaryTerm(term: "IPv6", aliases: ["ipv6"],
                     explanation: KitL10n.text("新一代网络地址格式，地址更长、数量近乎无限。")),
        GlossaryTerm(term: "端口转发", aliases: ["port forwarding", "redirect"],
                     explanation: KitL10n.text("把外网对某个端口的访问转给家里某台设备，常用于在外访问家里的 NAS。")),
        GlossaryTerm(term: "UPnP", aliases: ["upnp"],
                     explanation: KitL10n.text("让家里设备自动向路由器申请开端口的协议；方便，但会放松边界管控。")),
        GlossaryTerm(term: "SQM", aliases: ["sqm"],
                     explanation: KitL10n.text("智能队列管理：有人下载占满带宽时，优先保证游戏和语音通话不卡。")),
        GlossaryTerm(term: "VLAN", aliases: ["vlan"],
                     explanation: KitL10n.text("把一个物理网络虚拟切成多个互不相通的局域网，常用来隔离访客或智能家居设备。")),
        GlossaryTerm(term: "网桥", aliases: ["bridge"],
                     explanation: KitL10n.text("把多个网口和 Wi-Fi 拼成同一个局域网的虚拟交换机。")),
        GlossaryTerm(term: "静态路由", aliases: ["static route"],
                     explanation: KitL10n.text("手动指定某一段地址要走哪个网关；普通家庭网络一般用不到。")),
        GlossaryTerm(term: "WireGuard", aliases: ["wireguard"],
                     explanation: KitL10n.text("现代 VPN 协议，速度快、配置简单，常用于在外面安全地连回家。")),
        GlossaryTerm(term: "SSH", aliases: ["ssh"],
                     explanation: KitL10n.text("加密的远程命令行通道；终端功能就是通过它在手机上操作路由器。")),
        GlossaryTerm(term: "init.d", aliases: ["init.d", "启动项"],
                     explanation: KitL10n.text("OpenWrt 存放服务脚本的目录；服务的启动、停止和开机自启都由它管理。")),
        GlossaryTerm(term: "固件", aliases: ["firmware"],
                     explanation: KitL10n.text("路由器的系统软件，相当于手机的操作系统；在线升级换的就是它。")),
        GlossaryTerm(term: "内核", aliases: ["kernel"],
                     explanation: KitL10n.text("操作系统最核心的部分，负责驱动硬件和管理网络转发。")),
        GlossaryTerm(term: "挂载点", aliases: ["mount"],
                     explanation: KitL10n.text("存储设备接入系统的位置，例如 U 盘挂载到 /mnt 目录下。")),
        GlossaryTerm(term: "计划任务", aliases: ["crontab", "cron"],
                     explanation: KitL10n.text("按时间表自动执行的命令清单，例如每天凌晨自动重启路由器。")),
        GlossaryTerm(term: "连接跟踪", aliases: ["conntrack", "活动连接"],
                     explanation: KitL10n.text("路由器为每一条上网连接记的账；连接数太多会占用内存。")),
        GlossaryTerm(term: "系统负载", aliases: ["load", "负载"],
                     explanation: KitL10n.text("等待 CPU 处理的任务有多少；持续高于 CPU 核数，说明路由器忙不过来了。")),
        GlossaryTerm(term: "信号强度", aliases: ["signal", "dbm", "rssi"],
                     explanation: KitL10n.text("Wi-Fi 信号的强弱，单位 dBm：越接近 0 越强，-50 很好，-75 已较弱。")),
    ]

    /// Case-insensitive lookup by display term or alias; nil when the
    /// word is not in the table (callers then render it plainly).
    public static func lookup(_ text: String) -> GlossaryTerm? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return terms.first { entry in
            entry.term.lowercased() == needle
                || entry.aliases.contains { $0.lowercased() == needle }
        }
    }
}

// MARK: - Crontab, in human words (package E, standards 1/4)
//
// The crontab page used to show the raw file and nothing else. The
// entries are parsed here into (human schedule, command) pairs; the
// schedule wording covers the patterns home routers actually use
// and honestly falls back to "custom" for anything fancier, with
// the raw file still one tap away in the page's raw-data section.

public struct CronEntry: Equatable, Sendable {
    public var schedule: String
    public var command: String
    public init(schedule: String, command: String) {
        self.schedule = schedule; self.command = command
    }
}

public enum CronHumanizer {

    /// One crontab line -> an entry, or nil for blank lines,
    /// comments and environment assignments.
    public static func parse(line: String) -> CronEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("@") {
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let schedule = keywordSchedule(parts[0]) else { return nil }
            return CronEntry(schedule: schedule, command: parts[1])
        }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 6, !tokens[0].contains("=") else { return nil }
        let fields = Array(tokens[0..<5])
        return CronEntry(schedule: describe(minute: fields[0], hour: fields[1],
                                            dayOfMonth: fields[2], month: fields[3],
                                            dayOfWeek: fields[4]),
                         command: tokens[5...].joined(separator: " "))
    }

    public static func entries(in text: String) -> [CronEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0)) }
    }

    private static func keywordSchedule(_ keyword: String) -> String? {
        switch keyword.lowercased() {
        case "@reboot": return KitL10n.text("每次开机时")
        case "@hourly": return describe(minute: "0", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*")
        case "@daily", "@midnight": return describe(minute: "0", hour: "0", dayOfMonth: "*", month: "*", dayOfWeek: "*")
        case "@weekly": return describe(minute: "0", hour: "0", dayOfMonth: "*", month: "*", dayOfWeek: "0")
        case "@monthly": return describe(minute: "0", hour: "0", dayOfMonth: "1", month: "*", dayOfWeek: "*")
        case "@yearly", "@annually": return describe(minute: "0", hour: "0", dayOfMonth: "1", month: "1", dayOfWeek: "*")
        default: return nil
        }
    }

    public static func describe(minute: String, hour: String, dayOfMonth: String,
                                month: String, dayOfWeek: String) -> String {
        let raw = [minute, hour, dayOfMonth, month, dayOfWeek].joined(separator: " ")
        if minute == "*" && hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return KitL10n.text("每分钟")
        }
        if minute.hasPrefix("*/"), let step = Int(minute.dropFirst(2)),
           hour == "*", dayOfMonth == "*", month == "*", dayOfWeek == "*" {
            return KitL10n.format("每 %lld 分钟", step)
        }
        guard let minuteValue = Int(minute) else {
            return KitL10n.format("自定义计划（原始表达式 %@）", raw)
        }
        if hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return KitL10n.format("每小时的 %lld 分", minuteValue)
        }
        guard let hourValue = Int(hour) else {
            return KitL10n.format("自定义计划（原始表达式 %@）", raw)
        }
        if dayOfWeek != "*" && dayOfMonth == "*" && month == "*" {
            guard let days = weekdayNames(dayOfWeek) else {
                return KitL10n.format("自定义计划（原始表达式 %@）", raw)
            }
            return KitL10n.format("每周%@ %lld 点 %lld 分", days, hourValue, minuteValue)
        }
        if month != "*" && dayOfMonth != "*" && dayOfWeek == "*" {
            guard let monthValue = Int(month), let dayValue = Int(dayOfMonth) else {
                return KitL10n.format("自定义计划（原始表达式 %@）", raw)
            }
            return KitL10n.format("每年 %lld 月 %lld 日 %lld 点 %lld 分",
                                  monthValue, dayValue, hourValue, minuteValue)
        }
        if dayOfMonth != "*" && month == "*" && dayOfWeek == "*" {
            guard let dayValue = Int(dayOfMonth) else {
                return KitL10n.format("自定义计划（原始表达式 %@）", raw)
            }
            return KitL10n.format("每月 %lld 日 %lld 点 %lld 分", dayValue, hourValue, minuteValue)
        }
        if dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return KitL10n.format("每天 %lld 点 %lld 分", hourValue, minuteValue)
        }
        return KitL10n.format("自定义计划（原始表达式 %@）", raw)
    }

    /// "1,3,5" / "1-5" -> "周一、周三、周五" style text; nil for
    /// shapes the humanizer does not claim to understand.
    private static func weekdayNames(_ field: String) -> String? {
        var values: [Int] = []
        for part in field.split(separator: ",") {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] <= 6 else { return nil }
                values.append(contentsOf: bounds[0]...bounds[1])
            } else if let value = Int(part) {
                values.append(value)
            } else {
                return nil
            }
        }
        guard !values.isEmpty else { return nil }
        let names = [
            KitL10n.text("周日"), KitL10n.text("周一"), KitL10n.text("周二"), KitL10n.text("周三"),
            KitL10n.text("周四"), KitL10n.text("周五"), KitL10n.text("周六"),
        ]
        return values.map { names[(($0 % 7) + 7) % 7] }.joined(separator: KitL10n.text("、"))
    }
}
