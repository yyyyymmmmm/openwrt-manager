import SwiftUI

struct ActivityListView: View {
    @Environment(RouterStore.self) private var store

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "本次连接", note: "仅保留最近 50 条会话记录，不代表路由器完整日志。断开连接后清除。") {
                AppGroup {
                if store.activities.isEmpty {
                    ContentUnavailableView("暂无活动", systemImage: "clock", description: Text("本次会话尚未产生管理记录。"))
                } else {
                    ForEach(store.activities) { activity in
                        ActivityRow(activity: activity)
                        if activity.id != store.activities.last?.id { AppDivider(inset: 31) }
                    }
                }
                }
            }
        }
        .appDetailStyle("最近活动")
    }
}

struct ActivityRow: View {
    let activity: RouterActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(activity.isWarning ? AppPalette.orange : AppPalette.accent)
                .frame(width: 7, height: 7).padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title)
                    .font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                Text(activity.detail)
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.muted)
                Text(activity.date, format: .dateTime.month().day().hour().minute())
                    .font(AppTypography.metadata)
                    .foregroundStyle(AppPalette.muted)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
