import SwiftUI
import OpenWrtKit

struct ZeroTierNetworksView: View {
    @Environment(RouterStore.self) private var store
    @State private var networks: [ZeroTierNetwork] = []
    @State private var loading = false
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var requestID = UUID()
    private var service: InitService? { store.inventory.initServices.first { $0.name == "zerotier" } }
    var body: some View {
        List {
            Section {
                if loading { ProgressView("正在读取 ZeroTier…") }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                if let updatedAt {
                    Text((error == nil ? "读取时间：" : "上次数据：") + updatedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(AppPalette.muted)
                }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
            Section("运行网络") {
                if networks.isEmpty && updatedAt != nil {
                    Text(error == nil ? "客户端当前未返回已加入的网络。" : "上次列表为空，当前状态未知。").foregroundStyle(AppPalette.muted)
                }
                ForEach(networks) { network in
                    NavigationLink {
                        ZeroTierNetworkDetail(network: network, updatedAt: updatedAt, stale: error != nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(network.name.flatMap { $0.isEmpty ? nil : $0 } ?? network.id)
                            Text("\(network.id) · \(network.status)").font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                }
            }
            Section {
                Text("数据来自路由器上的 ZeroTier 客户端。配置保存不代表已加入网络；ACCESS_DENIED 需要控制器授权。控制器下发的路由是否进入内核，还需到概览的路由表核对。")
                NativeConfigurationLink(schema: .zerotier)
            }
            Section("应用配置与服务") {
                if let service {
                    NavigationLink {
                        ServiceDetailView(name: service.name)
                    } label: {
                        Label("启停、重载与开机启动", systemImage: "gearshape.2")
                    }.accessibilityIdentifier("zerotier-service-lifecycle")
                    Text("编辑网络 ID 后，先在上方配置页预览、应用并确认，再返回此处重载服务。网络节由固件启动脚本处理；配置目录、客户端退出结果与控制器授权需在重读状态中分别核对。")
                } else {
                    Label("路由器没有报告 zerotier 启动项", systemImage: "exclamationmark.triangle")
                    Text("不提供未经验证的启动命令。请先确认 ZeroTier 服务包及 LuCI 启动项 RPC。")
                }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("ZeroTier 网络")
            .task(id: store.connectionID) { networks = []; updatedAt = nil; error = nil; await load() }
    }
    private func load() async {
        let generation = store.connectionID, request = UUID()
        requestID = request
        loading = true; error = nil
        defer { if generation == store.connectionID && request == requestID { loading = false } }
        do {
            let result = try await store.zeroTierNetworks()
            guard generation == store.connectionID, request == requestID, !Task.isCancelled else { return }
            networks = result; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, request == requestID, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }
}

private struct ZeroTierNetworkDetail: View {
    let network: ZeroTierNetwork
    let updatedAt: Date?
    let stale: Bool
    var body: some View {
        List {
            Section("运行状态") {
                if let updatedAt { Text((stale ? "上次数据：" : "读取时间：") + updatedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(AppPalette.muted) }
                LabeledContent("网络 ID", value: network.id)
                LabeledContent("名称", value: network.name ?? "未返回")
                LabeledContent("状态", value: network.status)
                Text(network.statusExplanation)
                LabeledContent("类型", value: network.type ?? "未返回")
                LabeledContent("网络设备", value: network.device ?? "未返回")
                LabeledContent("MAC", value: network.mac ?? "未返回")
                LabeledContent("MTU", value: network.mtu.map(String.init) ?? "未返回")
                LabeledContent("接口错误码", value: network.portError.map(String.init) ?? "未返回")
            }
            Section("分配地址") {
                if let addresses = network.addresses {
                    if addresses.isEmpty { Text("客户端未返回分配地址。") }
                    ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in Text(address).textSelection(.enabled) }
                } else { Text("客户端未提供地址字段。") }
            }
            Section("控制器下发的路由") {
                if let routes = network.routes {
                    if routes.isEmpty { Text("客户端返回的路由列表为空。") }
                    ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(route.target).textSelection(.enabled)
                            Text("下一跳：\(route.via ?? "链路路由") · Metric：\(route.metric.map(String.init) ?? "未返回")")
                                .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                        }
                    }
                } else { Text("客户端未提供路由字段。") }
            }
            Section("客户端实际接受策略") {
                LabeledContent("私网 IP 与路由", value: flag(network.allowManaged))
                LabeledContent("公网 IP 与路由", value: flag(network.allowGlobal))
                LabeledContent("默认路由", value: flag(network.allowDefault))
                LabeledContent("DNS", value: flag(network.allowDNS))
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("网络详情")
    }
    private func flag(_ value: Bool?) -> String { value.map { $0 ? "接受" : "不接受" } ?? "未返回" }
}
