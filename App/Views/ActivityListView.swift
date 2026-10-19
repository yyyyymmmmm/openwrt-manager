import SwiftUI

struct ActivityListView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        List {
            Section {
                if store.activities.isEmpty {
                    ContentUnavailableView("暂无活动", systemImage: "clock", description: Text("本次会话尚未产生管理记录。"))
                } else {
                    ForEach(store.activities) { activity in
                        ActivityRow(activity: activity)
                    }
                }
            } footer: {
                Text("仅保留本次连接最近 50 条会话记录，不代表路由器完整日志。断开连接后清除。")
            }
        }
        .navigationTitle("最近活动")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ActivityRow: View {
    let activity: RouterActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activity.isWarning ? "exclamationmark.circle" : "clock")
                .foregroundStyle(activity.isWarning ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title)
                    .font(.subheadline.weight(.medium))
                Text(activity.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(activity.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
