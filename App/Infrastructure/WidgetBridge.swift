import Foundation
import OpenWrtKit
import WidgetKit

/// Publishes the router status summary the home-screen widget
/// renders (package D). The widget never connects to the router:
/// the app writes its already-fetched summary into the App Group
/// store after each refresh and asks WidgetKit to reload. Reloads
/// ride the app's own refresh cadence (plus the widget's own
/// restrained timeline policy), so this adds no router traffic.
enum WidgetBridge {
    static let widgetKind = "RouterStatusWidget"

    static func publish(summary: RouterStatusSummary) {
        guard let defaults = UserDefaults(suiteName: RouterStatusSummaryStore.appGroupIdentifier) else { return }
        RouterStatusSummaryStore.save(summary, to: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
