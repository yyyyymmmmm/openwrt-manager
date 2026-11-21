import SwiftUI
import OpenWrtKit

/// Diagnostics page (package A): what the app has been doing, in a form
/// the user can inspect and share. The event list and the export both
/// read the same redacted ring buffer (AppDiagnostics), so what is on
/// screen is exactly what an export would contain — no second,
/// unredacted channel exists.
struct DiagnosticsView: View {
    @Environment(RouterStore.self) private var store
    @State private var shareItem: ShareItem?
    @State private var exportFailed = false
    @State private var showingClearConfirmation = false

    private var events: [DiagnosticEvent] { AppDiagnostics.buffer.events }

    /// Newest 50 events, newest first, with a stable row identity.
    private var recentRows: [EventRow] {
        events.suffix(50).reversed().enumerated().map { EventRow(id: $0.offset, event: $0.element) }
    }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            AppSection(title: "应用") {
                AppGroup {
                    AppRow(title: "App 版本", symbol: "app.badge",
                           value: "\(AppDiagnostics.appVersion) (\(AppDiagnostics.appBuild))")
                    AppDivider()
                    AppRow(title: "设备", symbol: "iphone", value: AppDiagnostics.deviceModel)
                    AppDivider()
                    AppRow(title: "系统", symbol: "gearshape.2", value: AppDiagnostics.systemSummary)
                    AppDivider()
                    AppRow(title: "已记录事件", symbol: "list.bullet", value: "\(events.count)")
                }
            }
            if let capability = store.capability {
                AppSection(title: "路由器") {
                    AppGroup {
                        AppRow(title: "主机名", symbol: "server.rack", value: capability.board.hostname ?? "")
                        AppDivider()
                        AppRow(title: "型号", symbol: "wifi.router", value: capability.board.model ?? "")
                        AppDivider()
                        AppRow(title: "固件", symbol: "cpu", value: capability.firmware.description ?? "")
                    }
                }
            }
            AppSection(title: "导出", note: "诊断事件记录连接、发现、会话与配置事务的结果，已自动脱敏，不含密码与会话令牌。") {
                AppGroup {
                    Button(action: export) {
                        AppRow(title: "导出诊断日志", symbol: "square.and.arrow.up", chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("diagnosticsExportButton")
                    AppDivider()
                    Button(role: .destructive) { showingClearConfirmation = true } label: {
                        AppRow(title: "清除日志", symbol: "trash", destructive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            if exportFailed {
                ErrorStateView(message: "导出文件生成失败，请稍后重试。")
            }
            AppSection(title: "最近事件") {
                AppGroup {
                    if events.isEmpty {
                        AppRow(title: "暂无诊断事件")
                    } else {
                        ForEach(recentRows) { row in
                            eventRow(row.event)
                        }
                    }
                }
            }
        }
        .appDetailStyle("诊断日志")
        .confirmationDialog("确定要清除全部诊断事件吗？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清除日志", role: .destructive) { AppDiagnostics.buffer.clear() }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func eventRow(_ event: DiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(categoryName(event.category))
                    .font(AppTypography.metadata)
                    .foregroundStyle(event.category == .error ? AppPalette.red : AppPalette.accent)
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(AppTypography.metadata)
                    .foregroundStyle(AppPalette.muted)
            }
            Text(event.message)
                .font(AppTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !event.metadata.isEmpty {
                Text(event.metadata.keys.sorted().map { "\($0)=\(event.metadata[$0] ?? "")" }.joined(separator: " · "))
                    .font(AppTypography.metadata)
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func categoryName(_ category: DiagnosticCategory) -> String {
        switch category {
        case .app: return L10n.string("应用")
        case .connection: return L10n.string("连接")
        case .discovery: return L10n.string("发现")
        case .session: return L10n.string("会话")
        case .transaction: return L10n.string("事务")
        case .refresh: return L10n.string("刷新")
        case .error: return L10n.string("错误")
        }
    }

    private func export() {
        let header = AppDiagnostics.makeHeader(
            routerName: store.activeProfile?.name,
            routerModel: store.capability?.board.model,
            firmwareDescription: store.capability?.firmware.description)
        if let url = AppDiagnostics.writeExportFile(header: header) {
            exportFailed = false
            shareItem = ShareItem(url: url)
        } else {
            exportFailed = true
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct EventRow: Identifiable {
    let id: Int
    let event: DiagnosticEvent
}
