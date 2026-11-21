import Foundation
import OpenWrtKit

/// The outcome of one package action as the UI presents it:
/// executed and confirmed by read-back, executed but the read-back
/// does not agree (said out loud, never hidden), or failed.
enum PackageActionRunResult: Equatable {
    case succeeded(detail: String)
    case executedUnverified(detail: String)
    case failed(detail: String)

    var isFailure: Bool { if case .failed = self { return true }; return false }

    var detail: String {
        switch self {
        case .succeeded(let detail), .executedUnverified(let detail), .failed(let detail):
            return detail
        }
    }
}

extension RouterStore {
    /// One package action through the single gate (package J, audit
    /// F7): run the router's package-manager helper, refresh the
    /// inventory, and verify the end state by read-back — the same
    /// confirm-by-reread discipline as configuration transactions.
    /// `upgradableBefore` is the caller's pre-action upgradable
    /// count, used to verify a bulk upgrade.
    func performPackageAction(action: PackageActionKind, packages: [String] = [],
                              upgradableBefore: Int? = nil) async -> PackageActionRunResult {
        guard let client = packageActionClient else {
            return .failed(detail: L10n.string("未连接路由器。"))
        }
        let outcome: PackageActionOutcome
        do {
            outcome = try await client.run(action: action, packages: packages)
        } catch {
            return .failed(detail: FriendlyError.message(error))
        }
        let subject = packages.isEmpty ? "" : "：" + packages.joined(separator: "、")
        guard outcome.succeeded else {
            let output = [outcome.stderr, outcome.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let detail = output.isEmpty
                ? L10n.format("路由器返回失败（代码 %lld）。", Int64(outcome.code))
                : String(output.prefix(400))
            EventLogStore.shared.append(
                category: .operation, kind: .operation,
                title: L10n.format("软件包操作失败%@%@", action.eventTitle, subject),
                detail: detail, routerID: activeProfile?.id.uuidString)
            return .failed(detail: detail)
        }
        await refresh()
        let verified: Bool?
        switch action {
        case .update:
            verified = true // an index refresh has no end state to re-read
        case .install:
            verified = packages.allSatisfy { name in inventory.packages.contains { $0.name == name } }
        case .remove:
            verified = packages.allSatisfy { name in !inventory.packages.contains { $0.name == name } }
        case .upgrade:
            if let check = try? await readClient?.upgradablePackages() {
                if packages.isEmpty {
                    // Bulk upgrade: verified when the upgradable list
                    // actually shrank (or was already empty).
                    verified = upgradableBefore.map { check.lines.count < $0 || check.lines.isEmpty }
                } else {
                    let names = inventory.packages.map(\.name)
                    verified = packages.allSatisfy { name in
                        !check.lines.contains {
                            UpgradableNameExtractor.packageName(inLine: $0, installed: names) == name
                        }
                    }
                }
            } else { verified = nil }
        }
        let outputTail = [outcome.stdout, outcome.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if verified == false {
            let detail = L10n.format("命令已执行，但回读的软件包列表与预期不一致，请核对。%@", outputTail.map { "输出：\($0.prefix(200))" } ?? "")
            EventLogStore.shared.append(
                category: .operation, kind: .operation,
                title: L10n.format("软件包操作待核对%@%@", action.eventTitle, subject),
                detail: detail, routerID: activeProfile?.id.uuidString)
            return .executedUnverified(detail: detail)
        }
        let detail = outputTail.map { String($0.prefix(300)) } ?? L10n.string("已完成并回读确认。")
        EventLogStore.shared.append(
            category: .operation, kind: .operation,
            title: L10n.format("软件包操作完成%@%@", action.eventTitle, subject),
            detail: detail, routerID: activeProfile?.id.uuidString)
        return .succeeded(detail: detail)
    }
}

extension PackageActionKind {
    /// User-facing verb for confirmations and the operation record.
    var eventTitle: String {
        switch self {
        case .update: return L10n.string("刷新软件源")
        case .install: return L10n.string("安装软件包")
        case .upgrade: return L10n.string("更新软件包")
        case .remove: return L10n.string("卸载软件包")
        }
    }
}
