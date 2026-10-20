import SwiftUI
import OpenWrtKit

struct SystemRuntimeView: View {
    @Environment(RouterStore.self) private var store
    @State private var value: SystemRuntimeSnapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var actionError: String?
    @State private var actionMessage: String?
    @State private var showingZones = false
    @State private var confirming: ClockAction?
    @State private var localtimeAllowed: Bool?
    @State private var ntpAllowed: Bool?
    @State private var permissionError: String?
    private enum ClockAction: Equatable { case localtime, ntp }
    private var busy: Bool { loading || store.isMutating || store.pendingConfiguration != nil }

    var body: some View {
        AppPage(title: "", subtitle: nil) {
            if loading { ProgressView("正在读取路由器时间…") }
            if let error { DataUnavailableView(title: "无法读取时间状态", message: "无法读取的状态保持未知。", error: error) { Task { await load() } } }
            if let value {
                AppSection(title: "路由器时钟", note: "时间按手机时区显示，刷新后更新。") {
                    AppGroup {
                        AppRow(title: "当前时间", value: value.unixTime.map(Self.format) ?? "未报告")
                        AppDivider(inset: 12)
                        AppRow(title: "Unix 时间", value: value.unixTime.map(String.init) ?? "未报告")
                        AppDivider(inset: 12)
                        AppRow(title: "读取时间", value: value.readAt.formatted(date: .abbreviated, time: .standard))
                        AppDivider(inset: 12)
                        AppRow(title: "sysntpd", value: serviceState(value))
                    }
                }
                AppSection(title: "时间操作", note: "NTP 重启请求返回不代表已完成上游校时。") {
                    AppGroup {
                        Button { confirming = .localtime } label: { AppRow(title: "与手机时间同步", detail: "立即设置路由器时钟", symbol: "clock.arrow.circlepath", chevron: true) }
                            .buttonStyle(.plain).disabled(busy || localtimeAllowed != true).accessibilityIdentifier("system-sync-localtime")
                        AppDivider(inset: 48)
                        Button { confirming = .ntp } label: { AppRow(title: "请求 NTP 同步", detail: "重启 sysntpd 并重新读取状态", symbol: "arrow.triangle.2.circlepath", chevron: true) }
                            .buttonStyle(.plain).disabled(busy || ntpAllowed != true).accessibilityIdentifier("system-sync-ntp")
                    }
                }
                if localtimeAllowed == false || ntpAllowed == false { Text("当前账户没有对应操作的权限。").foregroundStyle(AppPalette.orange) }
                if let permissionError { Text(permissionError).foregroundStyle(AppPalette.orange) }
                if let actionMessage { Text(actionMessage).foregroundStyle(AppPalette.accent).textSelection(.enabled).accessibilityIdentifier("system-time-action-result") }
                if !value.issues.isEmpty {
                    AppSection(title: "读取问题") {
                        AppGroup {
                            ForEach(value.issues.keys.sorted(), id: \.self) { key in
                                AppRow(title: SystemRuntimeSnapshot.issueTitle(key), value: value.issues[key] ?? "读取失败")
                            }
                        }
                    }
                }
                AppSection(title: "时区目录", note: "选择时区请返回系统配置。地区名称和 POSIX 时区会一同进入变更预览。") {
                    AppGroup {
                        Button { showingZones = true } label: {
                            AppRow(title: "可用时区", symbol: "globe", value: value.timezones.map { "\($0.count) 项" } ?? "读取失败", chevron: true)
                        }.buttonStyle(.plain).disabled(value.timezones == nil).accessibilityIdentifier("system-timezones")
                    }
                }
                if store.inventory.initServices.contains(where: { $0.name == "sysntpd" }) {
                    AppSection(title: "服务生命周期") {
                        AppGroup {
                            NavigationLink { ServiceDetailView(name: "sysntpd") } label: {
                                AppRow(title: "NTP 启动项", detail: "启停、重载与开机启用", symbol: "gearshape.2", chevron: true)
                            }.buttonStyle(.plain).accessibilityIdentifier("system-ntp-service")
                        }
                    }
                }
            }
            if let actionError { Text(actionError).foregroundStyle(AppPalette.red).textSelection(.enabled) }
        }
        .font(AppTypography.secondary).appDetailStyle("时间与 NTP")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(busy) } }
        .task(id: store.connectionID) { value = nil; actionMessage = nil; actionError = nil; await load() }
        .confirmationDialog("确认时间操作", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if confirming == .localtime { Button("设置为手机当前时间") { run(.localtime) } }
            if confirming == .ntp { Button("请求重启 sysntpd") { run(.ntp) } }
            Button("取消", role: .cancel) { confirming = nil }
        } message: {
            Text(confirming == .localtime ? "将立即改变路由器系统时间。" : "将立即请求重启 NTP 客户端，不会修改服务器配置。")
        }
        .sheet(isPresented: $showingZones) {
            NavigationStack {
                List(value?.timezones ?? []) { zone in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(zone.name).font(AppTypography.row)
                        Text(zone.posix).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    }
                }.navigationTitle("路由器时区")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingZones = false } } }
            }
        }
    }

    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil; permissionError = nil; localtimeAllowed = nil; ntpAllowed = nil
        defer { if generation == store.connectionID { loading = false } }
        do {
            let snapshot = try await store.readSystemRuntime()
            guard generation == store.connectionID, !Task.isCancelled else { return }
            value = snapshot
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            value = nil; self.error = FriendlyError.message(error)
        }
        let localResult = await accessResult("setLocaltime")
        let ntpResult = await accessResult("restartNTP")
        guard generation == store.connectionID, !Task.isCancelled else { return }
        if case .success(let allowed) = localResult { localtimeAllowed = allowed }
        if case .success(let allowed) = ntpResult { ntpAllowed = allowed }
        let accessErrors = [localResult, ntpResult].compactMap { result -> String? in
            if case .failure(let error) = result { return FriendlyError.message(error) }
            return nil
        }
        if !accessErrors.isEmpty { permissionError = "无法确认部分操作权限：" + accessErrors.joined(separator: "；") }
    }

    private func run(_ action: ClockAction) {
        confirming = nil; actionError = nil; actionMessage = nil
        let generation = store.connectionID
        Task {
            do {
                switch action {
                case .localtime: try await store.setRouterClock()
                case .ntp: try await store.syncRouterNTP()
                }
                guard generation == store.connectionID, !Task.isCancelled else { return }
                await load()
                guard generation == store.connectionID, !Task.isCancelled else { return }
                if action == .ntp {
                    actionMessage = "NTP 重启请求已返回。当前状态：" + (value.map(serviceState) ?? "读取失败") + "；尚不能确认上游校时成功。"
                } else if let seconds = value?.unixTime {
                    actionMessage = abs(TimeInterval(seconds) - Date().timeIntervalSince1970) < 10
                        ? "已重新读取路由器时钟，与手机时间相差小于 10 秒。"
                        : "请求已返回，但路由器时间与手机仍有差异：" + Self.format(seconds)
                } else { actionMessage = "设置请求已返回，但无法重新读取路由器时钟。" }
            } catch {
                guard generation == store.connectionID, !Task.isCancelled else { return }
                actionError = "请求失败或结果未知：" + FriendlyError.message(error) + "。请重新读取后核对，不要重复提交。"
            }
        }
    }

    private func serviceState(_ value: SystemRuntimeSnapshot) -> String {
        let enabled = value.ntpdEnabled.map { $0 ? "开机启用" : "开机禁用" } ?? "开机状态未报告"
        let running = value.ntpdRunning.map { $0 ? "运行中" : "未运行" } ?? "运行状态未报告"
        return enabled + " · " + running
    }
    private func accessResult(_ function: String) async -> Result<Bool, Error> {
        do { return .success(try await store.systemActionAccess(function)) }
        catch { return .failure(error) }
    }
    private static func format(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .complete, time: .complete)
    }
}
