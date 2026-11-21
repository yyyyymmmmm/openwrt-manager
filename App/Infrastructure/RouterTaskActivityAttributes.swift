import ActivityKit
import Foundation

/// Live Activity attributes for long router tasks (package D):
/// firmware upgrade, backup restore, backup creation. This file is
/// compiled into BOTH the app (which starts/updates/ends the
/// activity) and the widget extension (which renders it) — the two
/// processes agree on the activity by this exact type shape.
/// Content state carries only display data: the current phase in
/// words. Progress is phase-based, not a fabricated percentage —
/// sysupgrade gives no honest byte-level progress to show.
struct RouterTaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var isFinished: Bool
        var succeeded: Bool
    }

    var routerName: String
    var taskTitle: String
}
