import ActivityKit
import SwiftUI
import WidgetKit
import OpenWrtKit

// The widget extension (package D): renders the status summary the
// app publishes into the App Group store after each refresh, plus
// the Live Activity presentation for long router tasks. It opens
// no router connection of its own — freshness is the summary's own
// timestamp, shown on the face.

struct RouterStatusEntry: TimelineEntry {
    let date: Date
    let summary: RouterStatusSummary
    let hasData: Bool
}

struct RouterStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> RouterStatusEntry {
        RouterStatusEntry(date: Date(), summary: .placeholder(), hasData: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (RouterStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RouterStatusEntry>) -> Void) {
        // Restrained by policy: at most a twice-hourly re-read of the
        // shared store, and the app itself reloads the timeline on
        // every refresh — the widget never polls the router.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> RouterStatusEntry {
        let defaults = UserDefaults(suiteName: RouterStatusSummaryStore.appGroupIdentifier)
        if let defaults, let summary = RouterStatusSummaryStore.load(from: defaults) {
            return RouterStatusEntry(date: Date(), summary: summary, hasData: true)
        }
        return RouterStatusEntry(date: Date(), summary: .placeholder(), hasData: false)
    }
}

struct RouterStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RouterStatusEntry

    var body: some View {
        if entry.hasData {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary.routerName)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.summary.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    metric(title: "在线设备", value: "\(entry.summary.connectedDevices)")
                    if let load = entry.summary.loadOneMinute {
                        metric(title: "负载", value: String(format: "%.2f", load))
                    }
                    if let memory = entry.summary.memoryUsedFraction {
                        metric(title: "内存", value: "\(Int((memory * 100).rounded()))%")
                    }
                    if family == .systemMedium, let storage = entry.summary.storageUsedFraction {
                        metric(title: "存储", value: "\(Int((storage * 100).rounded()))%")
                    }
                }
                Text("更新于 \(entry.summary.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zirox-openwrt").font(.headline)
                Text("在 App 中连接路由器后，这里会显示状态摘要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct RouterStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RouterStatusWidget", provider: RouterStatusProvider()) { entry in
            RouterStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("路由器状态")
        .description("当前路由器的在线设备、负载与内存摘要。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Live Activity presentation (long router tasks)

struct RouterTaskActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouterTaskActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: context.state.isFinished
                      ? (context.state.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                      : "arrow.triangle.2.circlepath")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(context.attributes.routerName) · \(context.attributes.taskTitle)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(context.state.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "wifi.router")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.taskTitle).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "wifi.router")
            } compactTrailing: {
                Image(systemName: context.state.isFinished ? "checkmark" : "arrow.triangle.2.circlepath")
            } minimal: {
                Image(systemName: "wifi.router")
            }
        }
    }
}

@main
struct ZiroxWidgetBundle: WidgetBundle {
    var body: some Widget {
        RouterStatusWidget()
        RouterTaskActivityWidget()
    }
}
