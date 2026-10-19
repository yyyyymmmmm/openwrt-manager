import SwiftUI
import OpenWrtKit

struct NativePluginOperationsView: View {
    let pluginID: String
    var body: some View {
        List {
            if pluginID == "homeproxy" {
                Section("内核与连通性") {
                    readLink(.homeProxyFeatures)
                    readLink(.homeProxyConnection(google: false))
                    readLink(.homeProxyConnection(google: true))
                }
                Section("资源") {
                    ForEach(HomeProxyResource.allCases) { resource in
                        readLink(.homeProxyResource(resource))
                        actionLink(.homeProxyResource(resource))
                    }
                }
                Section("订阅") { actionLink(.homeProxySubscriptions) }
                Section("日志 · 最近 200 行") {
                    ForEach(HomeProxyLog.allCases) { log in readLink(.homeProxyLog(log)) }
                }
            } else if pluginID == "mosdns" {
                Section("运行信息") {
                    readLink(.mosDNSVersion)
                    readLink(.mosDNSLog)
                }
                Section("缓存与规则") {
                    actionLink(.mosDNSFlushCache)
                    actionLink(.mosDNSUpdate)
                    readLink(.mosDNSUpdateLog)
                }
            } else if pluginID == "zerotier" {
                Section("运行信息") {
                    readLink(.zeroTierInfo)
                    NavigationLink("网络、授权与路由") { ZeroTierNetworksView() }
                }
            }
            Section {
                Text("读取失败会保留固件与权限错误。配置保存、进程运行和业务成功分别核对；插件版本不同可能不提供部分接口。")
                    .foregroundStyle(AppPalette.muted)
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("状态与操作")
    }
    private func readLink(_ request: NativePluginRead) -> some View {
        NavigationLink(request.title) { NativePluginResultView(request: request) }
    }
    private func actionLink(_ action: NativePluginAction) -> some View {
        NavigationLink(action.title) { NativePluginActionView(action: action) }
    }
}

private struct NativePluginResultView: View {
    @Environment(RouterStore.self) private var store
    let request: NativePluginRead
    @State private var output: String?
    @State private var error: String?
    @State private var loading = false
    @State private var updatedAt: Date?
    var body: some View {
        List {
            Section {
                if loading { ProgressView("正在读取…") }
                if let error { Text(error).foregroundStyle(AppPalette.red) }
                if let updatedAt { Text("读取时间：" + updatedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(AppPalette.muted) }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
            if let output {
                Section(error == nil ? "路由器返回结果" : "上次读取结果") {
                    Text(output.isEmpty ? "路由器返回内容为空。" : output).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(request.title)
            .task(id: store.connectionID) { output = nil; updatedAt = nil; await load() }
    }
    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil
        defer { if generation == store.connectionID { loading = false } }
        do {
            let result = try await store.nativePluginRead(request)
            guard generation == store.connectionID, !Task.isCancelled else { return }
            output = result; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
}

private struct NativePluginActionView: View {
    @Environment(RouterStore.self) private var store
    let action: NativePluginAction
    @State private var confirming = false
    @State private var running = false
    @State private var result: String?
    @State private var error: String?
    @State private var completedAt: Date?
    var body: some View {
        List {
            Section {
                Text(action.explanation)
                Button(action.title) { confirming = true }
                    .disabled(running || store.isMutating || store.pendingConfiguration != nil)
                if running { ProgressView("正在等待固件响应…") }
                if store.pendingConfiguration != nil { Text("请先处理待确认的配置。").foregroundStyle(AppPalette.orange) }
            }
            if let error {
                Section("操作未确认成功") {
                    Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled)
                    Text("连接中断或超时无法证明操作已取消，请先查看日志及当前配置，再决定是否重试。")
                }
            }
            if let result {
                Section("固件响应") {
                    if let completedAt { Text(completedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(AppPalette.muted) }
                    Text(result).textSelection(.enabled)
                }
            }
            switch action {
            case .homeProxySubscriptions:
                Section("核对结果") {
                    NativeConfigurationLink(schema: .homeproxy)
                    NavigationLink("HomeProxy 日志") { NativePluginResultView(request: .homeProxyLog(.homeproxy)) }
                }
            case .homeProxyResource(let resource):
                Section("核对结果") { NavigationLink("重新读取资源版本") { NativePluginResultView(request: .homeProxyResource(resource)) } }
            case .mosDNSUpdate:
                Section("核对结果") { NavigationLink("读取规则更新日志") { NativePluginResultView(request: .mosDNSUpdateLog) } }
            case .mosDNSFlushCache: EmptyView()
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle(action.title)
            .confirmationDialog(action.title + "？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认执行", role: .destructive) { Task { await execute() } }
                Button("取消", role: .cancel) {}
            } message: { Text(action.explanation) }
            .task(id: store.connectionID) { result = nil; error = nil; completedAt = nil }
    }
    private func execute() async {
        let generation = store.connectionID
        running = true; result = nil; error = nil; completedAt = nil
        defer { if generation == store.connectionID { running = false } }
        do {
            let output = try await store.nativePluginAction(action)
            guard generation == store.connectionID else { return }
            result = output; completedAt = Date()
        } catch {
            guard generation == store.connectionID else { return }
            self.error = FriendlyError.message(error)
        }
    }
}
