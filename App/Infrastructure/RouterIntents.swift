import AppIntents
import Foundation

/// The bridge from App Intents into the running app (package D).
/// Intents execute in their own context where no live router
/// session is guaranteed, so they never touch the router directly:
/// they record a request, open the app (openAppWhenRun), and the
/// app carries it out through its existing channels — refresh
/// through the store, reboot through the store's reboot door
/// behind the app's own confirmation. A write is therefore never
/// executed silently from a shortcut.
@MainActor
final class RouterIntentBridge: ObservableObject {
    static let shared = RouterIntentBridge()

    @Published var refreshRequested = false
    @Published var rebootRequested = false

    private init() {}
}

/// Refresh the connected router's status (read-only).
struct RefreshRouterStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新路由器状态"
    static var description = IntentDescription("打开 Zirox-openwrt 并刷新当前路由器的状态。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RouterIntentBridge.shared.refreshRequested = true
        return .result()
    }
}

/// Reboot the connected router. The intent itself performs no
/// write: it opens the app, where the reboot is confirmed again
/// with the same wording as the in-app quick action before the
/// store's reboot door is used.
struct RebootRouterIntent: AppIntent {
    static var title: LocalizedStringResource = "重启路由器"
    static var description = IntentDescription("打开 Zirox-openwrt 并请求重启当前路由器，执行前会在 App 内再次确认。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RouterIntentBridge.shared.rebootRequested = true
        return .result()
    }
}

struct RouterAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshRouterStatusIntent(),
                    phrases: ["用 \(.applicationName) 刷新路由器状态"],
                    shortTitle: "刷新路由器状态",
                    systemImageName: "arrow.clockwise")
        AppShortcut(intent: RebootRouterIntent(),
                    phrases: ["用 \(.applicationName) 重启路由器"],
                    shortTitle: "重启路由器",
                    systemImageName: "power")
    }
}
