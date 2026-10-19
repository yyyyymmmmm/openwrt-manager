import Foundation

/// Local session events, never inferred router logs or device-online claims.
struct RouterActivity: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let date: Date
    let isWarning: Bool

    init(_ title: String, detail: String, date: Date = Date(), isWarning: Bool = false) {
        self.title = title
        self.detail = detail
        self.date = date
        self.isWarning = isWarning
    }
}
