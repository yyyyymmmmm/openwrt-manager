import SwiftUI
import Charts
import OpenWrtKit

// MARK: - Design tokens
//
// New phase-1 components take every spacing and radius from these tokens;
// page code never writes raw layout numbers (spec section 0.4). The older
// components in DesignSystem.swift carry their own established values and
// are migrated opportunistically, not in bulk.

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum AppRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

// MARK: - Load state

enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

// MARK: - Status card

struct StatusCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(AppPalette.accent)
                }
                Text(title).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
            Text(value).font(AppTypography.title).foregroundStyle(AppPalette.text)
                .lineLimit(2).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Freshness

/// The single freshness label used across the app: live data says so,
/// stale data is marked with its age, cached snapshots are named as cache.
struct FreshnessBadge: View {
    let freshness: Freshness
    var cached = false

    var body: some View {
        switch freshness {
        case .missing:
            StatusBadge(title: "暂无数据")
        case .live:
            StatusBadge(title: cached ? "离线缓存" : "实时", good: !cached)
        case .stale(let age):
            StatusBadge(title: "已过期 · \(Self.ageText(age))")
        }
    }

    static func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "\(Int(age)) 秒前" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前" }
        return "\(Int(age / 3600)) 小时前"
    }
}

// MARK: - Empty and error states

struct EmptyStateView: View {
    let title: String
    let message: String
    var symbol = "tray"

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("读取失败", systemImage: "exclamationmark.triangle")
                .font(AppTypography.rowTitle).foregroundStyle(AppPalette.orange)
            Text(message).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                .textSelection(.enabled)
            if let retry {
                Button("重试", action: retry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppPalette.orangeSoft, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Collapsible group

struct CollapsibleGroup<Content: View>: View {
    let title: String
    var detail: String? = nil
    @State private var expanded = true
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
        } label: {
            HStack {
                Text(title).font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                Spacer()
                if let detail {
                    Text(detail).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - Realtime chart

enum RealtimeMetric: String, CaseIterable, Identifiable {
    case load, bandwidth, connections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .load: return "负载"
        case .bandwidth: return "带宽"
        case .connections: return "连接"
        }
    }
}

/// One chart component for all three realtime series; the metric switch is
/// a native segmented control.
struct RealtimeChartView: View {
    let samples: [RealtimeSample]
    @State private var metric: RealtimeMetric = .load

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Picker("指标", selection: $metric) {
                ForEach(RealtimeMetric.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            if points.isEmpty {
                EmptyStateView(title: "暂无实时数据", message: "轮询引擎正在采集，稍后将显示曲线。", symbol: "chart.line.uptrend.xyaxis")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("时间", point.at), y: .value("值", point.value),
                                 series: .value("序列", point.series))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("时间", point.at), y: .value("值", point.value),
                                 series: .value("序列", point.series))
                            .opacity(0.15)
                    }
                }
                .frame(height: 160)
                .chartXAxis(.hidden)
            }
        }
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private struct Point: Identifiable {
        var at: Date
        var series: String
        var value: Double
        var id: String { "\(at.timeIntervalSince1970)|\(series)" }
    }

    private var points: [Point] {
        switch metric {
        case .load:
            return samples.compactMap { sample in
                sample.load1.map { Point(at: sample.at, series: "负载", value: $0) }
            }
        case .connections:
            return samples.compactMap { sample in
                sample.connections.map { Point(at: sample.at, series: "连接", value: Double($0)) }
            }
        case .bandwidth:
            return samples.flatMap { sample -> [Point] in
                guard let total = sample.totalRate else { return [] }
                return [Point(at: sample.at, series: "下载", value: total.rxBytesPerSecond / 1024),
                        Point(at: sample.at, series: "上传", value: total.txBytesPerSecond / 1024)]
            }
        }
    }
}

// MARK: - Router chrome (visible on every tab)

/// Router switcher + connection state + capability freshness. Spec
/// section 2: from any tab the user can see which router is connected and
/// how fresh its data is.
struct RouterChromeHeader: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button { showingRouterPicker = true } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "wifi.router").foregroundStyle(AppPalette.accent)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(store.activeProfile?.name ?? "未连接")
                            .font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                        Text(store.activeProfile?.address ?? "")
                            .font(AppTypography.metadata).foregroundStyle(AppPalette.muted).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isMutating || store.pendingConfiguration != nil)
            Spacer()
            if store.capabilityIsFromCache {
                FreshnessBadge(freshness: .live, cached: true)
            } else {
                FreshnessBadge(freshness: store.freshnessPolicy.evaluate(
                    fetchedAt: store.capabilityUpdatedAt, now: Date()))
            }
            Button { Task { await store.refresh() } } label: {
                if store.isRefreshing { ProgressView() }
                else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(store.isRefreshing)
            .accessibilityLabel("刷新")
        }
    }
}

// MARK: - Formatting helpers

enum FormatHelpers {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.2f MB/s", bytesPerSecond / (1024 * 1024))
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }

    static func percent(used: Int64?, total: Int64?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return String(format: "%.0f%%", Double(used) / Double(total) * 100)
    }
}
