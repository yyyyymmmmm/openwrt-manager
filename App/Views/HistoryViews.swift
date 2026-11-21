import SwiftUI
import Charts
import OpenWrtKit

// MARK: - History charts (package B, item 1)

enum HistoryMetric: String, CaseIterable, Identifiable {
    case traffic, load, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .traffic: return L10n.string("流量")
        case .load: return L10n.string("负载")
        case .memory: return L10n.string("内存")
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }
    /// Bucket width for averaging inside a segment; an hour of raw
    /// 45-second samples is already chart-sized, longer ranges are not.
    var bucket: TimeInterval {
        switch self {
        case .hour: return 0
        case .day: return 300
        case .week: return 1800
        }
    }
    var title: String {
        switch self {
        case .hour: return L10n.string("近 1 小时")
        case .day: return L10n.string("近 24 小时")
        case .week: return L10n.string("近 7 天")
        }
    }
}

/// History curves fed by MonitoringService's local samples. Segments
/// come from the kit already split at data gaps, so the chart shows
/// blanks where nothing was measured — never an interpolated bridge.
struct HistoryChartView: View {
    @Environment(MonitoringService.self) private var monitoring
    var fixedMetric: HistoryMetric? = nil
    @State private var metric: HistoryMetric = .traffic
    @State private var range: HistoryRange = .day

    private var effectiveMetric: HistoryMetric { fixedMetric ?? metric }

    private struct SeriesData {
        let name: String
        let segments: [SegmentData]
        /// One gap-free run of points with its chart series key
        /// precomputed in plain Swift — interpolating the key inside
        /// the Chart builder timed out the type checker (build #15).
        struct SegmentData {
            let key: String
            let points: [MetricChartPoint]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if fixedMetric == nil {
                Picker("指标", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
            Picker("范围", selection: $range) {
                ForEach(HistoryRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            let series = seriesData()
            if series.allSatisfy({ $0.segments.isEmpty }) {
                EmptyStateView(title: "暂无历史数据",
                               message: "保持连接一段时间后，这里会累积出曲线。App 未运行且后台采样未被系统调度的时段不会有数据。",
                               symbol: "chart.line.uptrend.xyaxis")
                    .frame(height: 140)
            } else {
                Chart {
                    ForEach(series, id: \.name) { item in
                        ForEach(item.segments, id: \.key) { segment in
                            ForEach(segment.points, id: \.at) { point in
                                LineMark(x: .value("时间", point.at),
                                         y: .value("值", point.value),
                                         series: .value("序列", segment.key))
                                    .foregroundStyle(by: .value("类型", item.name))
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                }
                .frame(height: 170)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(axisLabel(number))
                            }
                        }
                    }
                }
                if hasGap {
                    Text("曲线空白处是没有数据的时段（App 未运行、手机或路由器离线），未作补造。")
                        .font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func axisLabel(_ value: Double) -> String {
        switch effectiveMetric {
        case .traffic: return FormatHelpers.rate(value)
        case .memory: return String(format: "%.0f%%", value)
        case .load: return String(format: "%.1f", value)
        }
    }

    private var window: ClosedRange<Date> {
        let end = Date()
        return end.addingTimeInterval(-range.seconds)...end
    }

    private var hasGap: Bool {
        let history = monitoring.history
        switch effectiveMetric {
        case .traffic:
            return history.hasGap(metric: .trafficDown, in: window)
                || history.hasGap(metric: .trafficUp, in: window)
        case .load: return history.hasGap(metric: .load, in: window)
        case .memory: return history.hasGap(metric: .memory, in: window)
        }
    }

    private func seriesData() -> [SeriesData] {
        switch effectiveMetric {
        case .traffic:
            return [makeSeries(name: L10n.string("下载"), metric: .trafficDown),
                    makeSeries(name: L10n.string("上传"), metric: .trafficUp)]
        case .load:
            return [makeSeries(name: L10n.string("负载"), metric: .load)]
        case .memory:
            return [makeSeries(name: L10n.string("内存"), metric: .memory)]
        }
    }

    private func makeSeries(name: String, metric: MetricKey) -> SeriesData {
        let raw = monitoring.history.chartSegments(metric: metric, in: window,
                                                   bucketSeconds: range.bucket)
        let segments = raw.enumerated().map { index, points in
            SeriesData.SegmentData(key: "\(name)#\(index)", points: points)
        }
        return SeriesData(name: name, segments: segments)
    }
}

// MARK: - Quick actions (package B, item 3)

/// Overview quick actions. Reboot and redial are high-impact: the
/// confirmation states the household impact in plain words, and after
/// sending, the action waits and verifies recovery instead of
/// declaring victory at dispatch. Wi-Fi goes through the standard L4
/// transaction confirmation sheet — the same gate as every write.
struct QuickActionsSection: View {
    @Environment(RouterStore.self) private var store

    private enum Phase: Equatable {
        case idle, working(String), waiting(String), done(String), failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var confirmReboot = false
    @State private var confirmRedial = false
    @State private var wifiPlan: ConfigurationPlan?
    @State private var showingWiFiConfirm = false
    @State private var errorText: String?

    private var busy: Bool {
        switch phase {
        case .working, .waiting: return true
        default: return store.isMutating
        }
    }

    private var wirelessPresent: Bool { store.capability?.wireless.present == true }

    private var wifiEnabled: Bool {
        guard let radios = store.capability?.wireless.radios, !radios.isEmpty else { return true }
        return !radios.allSatisfy { $0.disabled == true }
    }

    private var routerID: String? { store.activeProfile?.id.uuidString }

    var body: some View {
        Section("快捷动作") {
            Button(role: .destructive) {
                confirmReboot = true
            } label: {
                Label("重启路由器", systemImage: "power")
            }
            .disabled(busy)

            Button {
                confirmRedial = true
            } label: {
                Label("重拨 WAN", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(busy || store.capability?.upstream == nil)

            if wirelessPresent {
                Button {
                    Task { await prepareWiFiToggle() }
                } label: {
                    Label(wifiEnabled ? "关闭 Wi-Fi" : "开启 Wi-Fi",
                          systemImage: wifiEnabled ? "wifi.slash" : "wifi")
                }
                .disabled(busy)
            }

            switch phase {
            case .idle:
                EmptyView()
            case .working(let text), .waiting(let text):
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                    Text(L10n.key(text)).font(AppTypography.secondary)
                        .foregroundStyle(AppPalette.muted)
                }
            case .done(let text):
                Label(L10n.key(text), systemImage: "checkmark.circle")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.green)
            case .failed(let text):
                Label(L10n.key(text), systemImage: "exclamationmark.triangle")
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.red)
            }
            if let errorText {
                Text(L10n.key(errorText)).font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.red)
            }
        }
        .confirmationDialog("确定要重启路由器吗？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("立即重启", role: .destructive) { runReboot() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("全家网络将中断约 2–5 分钟，所有设备的连接都会断开。发送后 App 会自动等待路由器恢复并重新读取状态。")
        }
        .confirmationDialog("重新拨号 WAN？", isPresented: $confirmRedial, titleVisibility: .visible) {
            Button("重拨") { runRedial() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("外网会短暂中断（通常 10–60 秒），局域网不受影响。完成后 App 会核对 WAN 是否恢复连接。")
        }
        .sheet(isPresented: $showingWiFiConfirm) {
            if let wifiPlan {
                TransactionConfirmationView(plan: wifiPlan,
                                            reloadServices: ConfigReloadMap.services(for: "wireless"))
            }
        }
    }

    // MARK: Reboot + recovery watch

    private func runReboot() {
        phase = .working(L10n.string("正在发送重启指令…"))
        errorText = nil
        EventLogStore.shared.append(category: .operation, kind: .quickAction, title: L10n.string("重启路由器"),
                                    detail: L10n.string("已从概览页发起重启，等待恢复。"),
                                    routerID: routerID)
        Task {
            do {
                try await store.rebootRouter()
            } catch {
                // A dropped connection as the router goes down is the
                // expected shape of success (same rule as the system
                // tab's reboot page); anything else is a real failure.
                guard error is URLError else {
                    phase = .failed(FriendlyError.message(error))
                    return
                }
            }
            phase = .waiting(L10n.string("路由器重启中，等待恢复…"))
            await waitForRebootRecovery()
        }
    }

    private func waitForRebootRecovery() async {
        // Give the router time to actually go down before probing, so
        // a still-up old session is not mistaken for recovery.
        try? await Task.sleep(for: .seconds(20))
        for _ in 0..<40 {
            if await store.probeRouterReachable() {
                await store.refresh()
                phase = .done(L10n.string("路由器已恢复，状态已重新读取。"))
                EventLogStore.shared.append(category: .operation, kind: .quickAction, title: L10n.string("路由器已恢复"),
                                            detail: L10n.string("重启后重新登录成功，状态已刷新。"),
                                            routerID: routerID)
                return
            }
            try? await Task.sleep(for: .seconds(10))
        }
        phase = .failed(L10n.string("等待超时，路由器尚未恢复。请检查电源与网络后手动刷新。"))
        EventLogStore.shared.append(category: .operation, kind: .quickAction, title: L10n.string("重启后未恢复"),
                                    detail: L10n.string("等待约 7 分钟仍无法重新登录路由器。"),
                                    routerID: routerID)
    }

    // MARK: Redial + verification

    private func runRedial() {
        phase = .working(L10n.string("正在重拨…"))
        errorText = nil
        EventLogStore.shared.append(category: .operation, kind: .quickAction, title: L10n.string("重拨 WAN"),
                                    detail: L10n.string("已从概览页发起重拨，等待核对。"),
                                    routerID: routerID)
        Task {
            do {
                try await store.redialWAN()
            } catch {
                phase = .failed(FriendlyError.message(error))
                return
            }
            phase = .waiting(L10n.string("等待 WAN 恢复…"))
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(6))
                await store.refresh()
                if let upstream = store.capability?.upstream,
                   store.snapshot?.interfaces.first(where: { $0.name == upstream.interfaceName })?.up == true {
                    phase = .done(L10n.string("WAN 已恢复连接。"))
                    EventLogStore.shared.append(category: .operation, kind: .quickAction, title: L10n.string("重拨完成"),
                                                detail: L10n.string("WAN 接口已恢复连接。"),
                                                routerID: routerID)
                    return
                }
            }
            phase = .failed(L10n.string("等待超时，WAN 尚未恢复。请检查线路，或到接口页确认状态。"))
        }
    }

    // MARK: Wi-Fi via the L4 gate

    private func prepareWiFiToggle() async {
        errorText = nil
        do {
            let original = try await store.configuration("wireless")
            var edited = original
            let target = wifiEnabled ? "1" : "0"
            var touched = false
            for index in edited.sections.indices where edited.sections[index].type == "wifi-device" {
                edited.sections[index].values["disabled"] = .string(target)
                touched = true
            }
            guard touched else {
                errorText = L10n.string("未找到无线设备配置，无法开关 Wi-Fi。")
                return
            }
            wifiPlan = try ConfigurationPlan(original: original, edited: edited)
            EventLogStore.shared.append(category: .operation, kind: .configuration,
                                        title: wifiEnabled ? L10n.string("关闭 Wi-Fi") : L10n.string("开启 Wi-Fi"),
                                        detail: L10n.string("已从概览页发起，经配置事务确认后生效。"),
                                        routerID: routerID)
            showingWiFiConfirm = true
        } catch {
            errorText = FriendlyError.message(error)
        }
    }
}
