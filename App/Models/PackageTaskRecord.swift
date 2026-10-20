import Foundation
import OpenWrtKit

struct PackageTaskRecord: Identifiable {
    let id = UUID()
    let operation: PackageOperation
    let startedAt: Date
    var completedAt: Date?
    var result: PackageOperationResult?
    var error: String?
    var verification: String?
    var uncertain = false
    var running: Bool { completedAt == nil }
}
