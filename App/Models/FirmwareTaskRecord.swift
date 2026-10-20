import Foundation
import OpenWrtKit

enum FirmwareMaintenanceRequest {
    case restore(BackupInspection)
    case upgrade(FirmwareValidation, FirmwareUpgradeOptions)
    case reset

    var title: String {
        switch self {
        case .restore: return "恢复配置并重启"
        case .upgrade: return "刷写固件"
        case .reset: return "恢复出厂配置"
        }
    }
}

struct FirmwareTaskRecord: Codable, Identifiable {
    var id = UUID()
    let title: String
    let startedAt: Date
    let connectionID: UUID
    let previousFirmware: String?
    let result: RouterCommandResult?
    let message: String
    var reconnectedAt: Date?
    var observedFirmware: String?
    var observedModel: String?
    var verifiedAt: Date?
    var requiresReconnect: Bool { verifiedAt == nil }
}
