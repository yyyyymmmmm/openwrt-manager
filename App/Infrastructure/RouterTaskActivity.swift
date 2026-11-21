import ActivityKit
import Foundation

/// Starts, updates and ends the long-task Live Activity (package D).
/// Purely presentational: the flows themselves (UpgradeFlow,
/// BackupRestoreFlow) keep their own discipline; this controller
/// only mirrors the phase text they already produce. If the user
/// has Live Activities off, every call is a no-op.
@MainActor
final class RouterTaskActivityController {
    static let shared = RouterTaskActivityController()

    private var activity: Activity<RouterTaskActivityAttributes>?
    private init() {}

    func start(routerName: String, taskTitle: String, phase: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        finishImmediately()
        let attributes = RouterTaskActivityAttributes(routerName: routerName, taskTitle: taskTitle)
        let content = ActivityContent(
            state: RouterTaskActivityAttributes.ContentState(phase: phase, isFinished: false, succeeded: false),
            staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func update(phase: String) {
        guard let activity else { return }
        let content = ActivityContent(
            state: RouterTaskActivityAttributes.ContentState(phase: phase, isFinished: false, succeeded: false),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func finish(phase: String, succeeded: Bool) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(
            state: RouterTaskActivityAttributes.ContentState(phase: phase, isFinished: true, succeeded: succeeded),
            staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(Date.now.addingTimeInterval(10))) }
    }

    private func finishImmediately() {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: activity.content.state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
