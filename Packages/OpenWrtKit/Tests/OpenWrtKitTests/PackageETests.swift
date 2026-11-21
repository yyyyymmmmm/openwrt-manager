import XCTest
@testable import OpenWrtKit

/// Package E: the comprehension layer — one rating vocabulary with
/// thresholds in one place, rule-generated page summaries, the
/// glossary, and the crontab humanizer. All pure functions; wording
/// assertions pin the Chinese source strings (the kit's source
/// language when no app shell has set a language).
final class PackageETests: XCTestCase {

    // MARK: HealthRating

    func testUsageGradeBoundaries() {
        XCTAssertEqual(HealthRating.usageGrade(percent: 0), .excellent)
        XCTAssertEqual(HealthRating.usageGrade(percent: 50), .excellent)
        XCTAssertEqual(HealthRating.usageGrade(percent: 51), .good)
        XCTAssertEqual(HealthRating.usageGrade(percent: 70), .good)
        XCTAssertEqual(HealthRating.usageGrade(percent: 85), .fair)
        XCTAssertEqual(HealthRating.usageGrade(percent: 95), .poor)
        XCTAssertEqual(HealthRating.usageGrade(percent: 96), .critical)
        XCTAssertEqual(HealthRating.usageGrade(percent: 130), .critical)
        XCTAssertEqual(HealthRating.usageGrade(percent: -1), .unknown)
    }

    func testCPUGradeBoundaries() {
        XCTAssertEqual(HealthRating.cpuGrade(percent: 25), .excellent)
        XCTAssertEqual(HealthRating.cpuGrade(percent: 50), .good)
        XCTAssertEqual(HealthRating.cpuGrade(percent: 75), .fair)
        XCTAssertEqual(HealthRating.cpuGrade(percent: 90), .poor)
        XCTAssertEqual(HealthRating.cpuGrade(percent: 91), .critical)
    }

    func testLoadGradeIsPerCore() {
        XCTAssertEqual(HealthRating.loadGrade(load: 0.4, cores: nil), .excellent)
        XCTAssertEqual(HealthRating.loadGrade(load: 1.0, cores: nil), .fair)
        XCTAssertEqual(HealthRating.loadGrade(load: 2.0, cores: nil), .critical)
        // The same load on four cores is light work.
        XCTAssertEqual(HealthRating.loadGrade(load: 2.0, cores: 4), .excellent)
        XCTAssertEqual(HealthRating.loadGrade(load: 3.2, cores: 4), .good)
        XCTAssertEqual(HealthRating.loadGrade(load: -0.5, cores: 2), .unknown)
    }

    func testSignalGradeBoundaries() {
        XCTAssertEqual(HealthRating.signalGrade(dBm: -30), .excellent)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -50), .excellent)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -60), .good)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -67), .fair)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -75), .poor)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -76), .critical)
        XCTAssertEqual(HealthRating.signalGrade(dBm: -90), .critical)
    }

    func testConnectionsGradeNeedsAMaximum() {
        XCTAssertEqual(HealthRating.connectionsGrade(used: 100, maximum: nil), .unknown)
        XCTAssertEqual(HealthRating.connectionsGrade(used: 100, maximum: 0), .unknown)
        XCTAssertEqual(HealthRating.connectionsGrade(used: 100, maximum: 1000), .excellent)
        XCTAssertEqual(HealthRating.connectionsGrade(used: 990, maximum: 1000), .critical)
    }

    func testGradeWorstAndLabels() {
        XCTAssertEqual(HealthGrade.worst(of: [.good, .poor, .excellent]), .poor)
        XCTAssertEqual(HealthGrade.worst(of: [.unknown, .fair]), .fair)
        XCTAssertEqual(HealthGrade.worst(of: [.unknown]), .unknown)
        XCTAssertEqual(HealthGrade.worst(of: []), .unknown)
        XCTAssertEqual(HealthGrade.excellent.label, "优秀")
        XCTAssertEqual(HealthGrade.poor.label, "偏高")
        XCTAssertEqual(HealthGrade.critical.label, "异常")
        XCTAssertEqual(HealthGrade.poor.strengthLabel, "较弱")
        XCTAssertEqual(HealthGrade.critical.strengthLabel, "很弱")
    }

    func testFractionAndPercent() {
        XCTAssertEqual(HealthRating.fraction(used: 1, total: 4), 0.25)
        XCTAssertEqual(HealthRating.percent(used: 1, total: 4), 25)
        XCTAssertNil(HealthRating.fraction(used: 1, total: 0))
        XCTAssertEqual(HealthRating.fraction(used: 9, total: 4), 1)
    }

    // MARK: SummaryEngine — overview

    func testOverviewUpstreamDownWinsOverEverything() {
        let summary = SummaryEngine.overview(upstreamUp: false, memoryPercent: 99,
                                             storagePercent: 99, onlineDevices: 5)
        XCTAssertEqual(summary.tone, .bad)
        XCTAssertEqual(summary.headline, "上网异常：路由器没有连上互联网")
    }

    func testOverviewMemoryPressureEscalates() {
        XCTAssertEqual(SummaryEngine.overview(upstreamUp: true, memoryPercent: 97,
                                              storagePercent: nil, onlineDevices: nil).tone, .bad)
        let tight = SummaryEngine.overview(upstreamUp: true, memoryPercent: 90,
                                           storagePercent: nil, onlineDevices: nil)
        XCTAssertEqual(tight.tone, .warning)
        XCTAssertEqual(tight.headline, "内存偏紧，建议关注")
    }

    func testOverviewHealthyHeadlineCarriesDeviceCount() {
        let summary = SummaryEngine.overview(upstreamUp: true, memoryPercent: 40,
                                             storagePercent: 30, onlineDevices: 23)
        XCTAssertEqual(summary.tone, .good)
        XCTAssertEqual(summary.headline, "网络正常，23 台设备在线")
    }

    // MARK: SummaryEngine — the rest

    func testServicesSummaryShapes() {
        XCTAssertEqual(SummaryEngine.services(running: 0, stopped: 0, unknown: 0).headline, "尚未发现服务")
        XCTAssertEqual(SummaryEngine.services(running: 14, stopped: 0, unknown: 0).tone, .good)
        XCTAssertEqual(SummaryEngine.services(running: 14, stopped: 0, unknown: 0).headline, "全部 14 个服务都在运行")
        XCTAssertEqual(SummaryEngine.services(running: 0, stopped: 3, unknown: 0).tone, .warning)
        XCTAssertEqual(SummaryEngine.services(running: 2, stopped: 1, unknown: 0).headline, "2 个运行中 · 1 个已停止")
        XCTAssertEqual(SummaryEngine.services(running: 2, stopped: 1, unknown: 4).headline,
                       "2 个运行中 · 1 个已停止 · 4 个状态未知")
        XCTAssertEqual(SummaryEngine.services(running: 0, stopped: 0, unknown: 5).headline, "暂时读不到服务状态")
    }

    func testNetworkAndInterfaceSummaries() {
        XCTAssertEqual(SummaryEngine.network(upstreamUp: false, interfacesUp: 3,
                                             interfacesTotal: 4, leaseCount: 9).tone, .bad)
        XCTAssertEqual(SummaryEngine.network(upstreamUp: true, interfacesUp: 3,
                                             interfacesTotal: 4, leaseCount: 9).headline,
                       "3 个接口在线 · 9 台设备已分配地址")
        XCTAssertEqual(SummaryEngine.interfaces(up: 4, total: 4).tone, .good)
        XCTAssertEqual(SummaryEngine.interfaces(up: 0, total: 4).tone, .warning)
        XCTAssertEqual(SummaryEngine.interfaces(up: 0, total: 0).headline, "路由器没有报告接口")
    }

    func testWirelessFirewallAndLogSummaries() {
        XCTAssertEqual(SummaryEngine.wireless(radiosOn: 0, radiosTotal: 2, networkCount: 0).tone, .warning)
        XCTAssertEqual(SummaryEngine.wireless(radiosOn: 2, radiosTotal: 2, networkCount: 3).headline,
                       "3 个无线网络正在广播")
        XCTAssertEqual(SummaryEngine.wireless(radiosOn: 0, radiosTotal: 0, networkCount: 0).headline,
                       "这台路由器没有无线")
        XCTAssertEqual(SummaryEngine.firewall(tables: 0, chains: 0).tone, .warning)
        XCTAssertEqual(SummaryEngine.firewall(tables: 2, chains: 11).headline, "防火墙正在工作：2 张表 · 11 个链")
        XCTAssertEqual(SummaryEngine.logs(total: 100, errors: 3).headline, "最近 100 条日志里有 3 条错误")
        XCTAssertEqual(SummaryEngine.logs(total: 100, errors: 0).tone, .good)
        XCTAssertEqual(SummaryEngine.logs(total: 0, errors: 0).headline, "暂无日志")
    }

    func testProcessSummaryNamesTheHogOnlyWhenCritical() {
        let hog = SummaryEngine.processes(total: 42, topName: "openbox", topCPU: 97)
        XCTAssertEqual(hog.tone, .warning)
        XCTAssertEqual(hog.headline, "openbox 占用了 97% 的 CPU，可能拖慢路由器")
        XCTAssertEqual(SummaryEngine.processes(total: 42, topName: "openbox", topCPU: 40).headline,
                       "共 42 个进程在运行")
    }

    func testStorageAndSystemSummariesFollowTheGrades() {
        XCTAssertEqual(SummaryEngine.storage(percent: 30).tone, .good)
        XCTAssertEqual(SummaryEngine.storage(percent: 80).tone, .neutral)
        XCTAssertEqual(SummaryEngine.storage(percent: 90).tone, .warning)
        XCTAssertEqual(SummaryEngine.storage(percent: 99).tone, .bad)
        let longRun = SummaryEngine.system(uptime: 3 * 86400, storagePercent: 20)
        XCTAssertEqual(longRun.headline, "已连续运行 3 天，运行稳定")
        XCTAssertEqual(SummaryEngine.system(uptime: 3 * 86400, storagePercent: 93).tone, .warning)
        XCTAssertEqual(SummaryEngine.system(uptime: nil, storagePercent: nil).headline, "系统信息已读取")
    }

    // MARK: Glossary

    func testGlossaryLookupIsCaseAndAliasTolerant() {
        XCTAssertEqual(Glossary.lookup("DHCP")?.term, "DHCP")
        XCTAssertEqual(Glossary.lookup("dhcp")?.term, "DHCP")
        XCTAssertEqual(Glossary.lookup(" 租约 ")?.term, "DHCP 租约")
        XCTAssertEqual(Glossary.lookup("nft")?.term, "nftables")
        XCTAssertEqual(Glossary.lookup("conntrack")?.term, "连接跟踪")
        XCTAssertNil(Glossary.lookup("不存在的词"))
        XCTAssertNil(Glossary.lookup(""))
    }

    func testGlossaryCoverageAndExplanations() {
        // The terms the pages actually show must all be explainable.
        for word in ["DHCP", "DNS", "ubus", "UCI", "nftables", "MTU", "信道", "频段",
                     "SSID", "WAN", "LAN", "网关", "MAC 地址", "IPv6", "端口转发",
                     "UPnP", "SQM", "VLAN", "网桥", "WireGuard", "SSH", "init.d",
                     "固件", "内核", "挂载点", "计划任务", "系统负载", "信号强度"] {
            XCTAssertNotNil(Glossary.lookup(word), "missing glossary term: \(word)")
        }
        for entry in Glossary.terms {
            XCTAssertFalse(entry.explanation.isEmpty, "empty explanation: \(entry.term)")
            XCTAssertFalse(entry.term.isEmpty)
        }
        // No lookup key may be claimed by two different terms (an
        // entry repeating its own name as an alias is harmless).
        var owner: [String: String] = [:]
        for entry in Glossary.terms {
            for key in Set([entry.term.lowercased()] + entry.aliases.map { $0.lowercased() }) {
                if let existing = owner[key] {
                    XCTFail("glossary key \(key) claimed by both \(existing) and \(entry.term)")
                }
                owner[key] = entry.term
            }
        }
    }

    // MARK: CronHumanizer

    func testCronCommonPatterns() {
        XCTAssertEqual(CronHumanizer.describe(minute: "*", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*"),
                       "每分钟")
        XCTAssertEqual(CronHumanizer.describe(minute: "*/5", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*"),
                       "每 5 分钟")
        XCTAssertEqual(CronHumanizer.describe(minute: "30", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*"),
                       "每小时的 30 分")
        XCTAssertEqual(CronHumanizer.describe(minute: "30", hour: "2", dayOfMonth: "*", month: "*", dayOfWeek: "*"),
                       "每天 2 点 30 分")
        XCTAssertEqual(CronHumanizer.describe(minute: "0", hour: "9", dayOfMonth: "*", month: "*", dayOfWeek: "1,3,5"),
                       "每周周一、周三、周五 9 点 0 分")
        XCTAssertEqual(CronHumanizer.describe(minute: "0", hour: "9", dayOfMonth: "*", month: "*", dayOfWeek: "1-5"),
                       "每周周一、周二、周三、周四、周五 9 点 0 分")
        XCTAssertEqual(CronHumanizer.describe(minute: "15", hour: "3", dayOfMonth: "1", month: "*", dayOfWeek: "*"),
                       "每月 1 日 3 点 15 分")
        XCTAssertEqual(CronHumanizer.describe(minute: "15", hour: "3", dayOfMonth: "1", month: "6", dayOfWeek: "*"),
                       "每年 6 月 1 日 3 点 15 分")
    }

    func testCronFancyShapesFallBackHonestly() {
        let fancy = CronHumanizer.describe(minute: "1,15", hour: "*", dayOfMonth: "*", month: "*", dayOfWeek: "*")
        XCTAssertTrue(fancy.hasPrefix("自定义计划"))
        XCTAssertTrue(fancy.contains("1,15"))
    }

    func testCronParseLines() {
        let daily = CronHumanizer.parse(line: "0 4 * * * /etc/init.d/openbox restart")
        XCTAssertEqual(daily?.schedule, "每天 4 点 0 分")
        XCTAssertEqual(daily?.command, "/etc/init.d/openbox restart")
        XCTAssertEqual(CronHumanizer.parse(line: "@reboot /root/start.sh")?.schedule, "每次开机时")
        XCTAssertEqual(CronHumanizer.parse(line: "@daily /root/a.sh")?.schedule, "每天 0 点 0 分")
        XCTAssertNil(CronHumanizer.parse(line: "# 0 4 * * * commented out"))
        XCTAssertNil(CronHumanizer.parse(line: ""))
        XCTAssertNil(CronHumanizer.parse(line: "PATH=/usr/bin:/bin"))
        XCTAssertNil(CronHumanizer.parse(line: "too short"))
        let entries = CronHumanizer.entries(in: "0 4 * * * /a.sh\n# comment\n*/10 * * * * /b.sh\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].schedule, "每 10 分钟")
    }
}
