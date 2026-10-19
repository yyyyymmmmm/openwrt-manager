import SwiftUI
import OpenWrtKit

struct UPnPMappingsView: View {
    @Environment(RouterStore.self) private var store
    @State private var mappings: [UPnPMapping] = []
    @State private var updatedAt: Date?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loading { ProgressView("正在读取映射…") }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
                if let updatedAt {
                    Text((error == nil ? "读取时间：" : "上次数据：") + updatedAt.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(AppPalette.muted)
                }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(loading || store.isMutating)
            }
            Section("活动映射") {
                if updatedAt != nil && mappings.isEmpty {
                    Text(error == nil ? "固件返回的映射列表为空。" : "上次读取未返回映射，当前状态未知。")
                        .foregroundStyle(AppPalette.muted)
                }
                ForEach(mappings) { mapping in
                    NavigationLink {
                        UPnPMappingDetail(mapping: mapping, observed: mappings, updatedAt: updatedAt, stale: error != nil) { refreshed in
                            mappings = refreshed; updatedAt = Date()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(mapping.transport) \(mapping.externalPort) → \(mapping.internalAddress):\(mapping.internalPort)")
                            if !mapping.description.isEmpty { Text(mapping.description).font(AppTypography.secondary).foregroundStyle(AppPalette.muted) }
                        }
                    }
                }
            }
            Section {
                Text("映射由局域网客户端动态建立，和配置中的访问控制规则不同。删除会调用固件程序并可能重启 UPnP 服务、影响其他映射；客户端仍可能自动重新申请。")
                Text("执行前会核对映射列表和固件租约文件中的对应条目，需要读取权限。固件未提供原子条件删除，其他设备同时修改时仍可能发生变化。")
                    .foregroundStyle(AppPalette.muted)
                if store.pendingConfiguration != nil { Text("请先处理待确认配置。").foregroundStyle(AppPalette.orange) }
            }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("活动端口映射")
            .task(id: store.connectionID) { mappings = []; updatedAt = nil; await load() }
    }

    private func load() async {
        let generation = store.connectionID
        loading = true; error = nil
        defer { if generation == store.connectionID { loading = false } }
        do {
            let result = try await store.upnpMappings()
            guard generation == store.connectionID, !Task.isCancelled else { return }
            mappings = result; updatedAt = Date()
        } catch {
            guard generation == store.connectionID, !Task.isCancelled else { return }
            self.error = FriendlyError.message(error)
        }
    }

}

private struct UPnPMappingDetail: View {
    @Environment(RouterStore.self) private var store
    let mapping: UPnPMapping
    let observed: [UPnPMapping]
    let updatedAt: Date?
    let stale: Bool
    let onUpdate: ([UPnPMapping]) -> Void
    @State private var confirming = false
    @State private var running = false
    @State private var notice: String?
    @State private var error: String?
    private var canDelete: Bool {
        !stale && !running && notice == nil && error == nil && !store.isMutating && store.pendingConfiguration == nil
    }
    var body: some View {
        List {
            Section("映射详情") {
                if let updatedAt {
                    Text((stale ? "上次数据：" : "读取时间：") + updatedAt.formatted(date: .omitted, time: .standard)).foregroundStyle(AppPalette.muted)
                }
                LabeledContent("协议", value: mapping.transport)
                LabeledContent("外部端口", value: String(mapping.externalPort))
                LabeledContent("内部地址", value: mapping.internalAddress)
                LabeledContent("内部端口", value: String(mapping.internalPort))
                LabeledContent("主机", value: mapping.host ?? "固件未返回")
                LabeledContent("说明", value: mapping.description.isEmpty ? "未提供" : mapping.description)
                LabeledContent("临时序号", value: mapping.token)
                LabeledContent("读取时剩余租期", value: mapping.expires.map { $0 > 0 ? "\($0) 秒" : "固件返回 \($0) 秒" } ?? "固件未返回")
            }
            Section {
                Button("删除活动映射", systemImage: "trash", role: .destructive) { confirming = true }.disabled(!canDelete)
                if running { ProgressView("正在删除并重新核对…") }
                if let notice { Text(notice).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(AppPalette.red).textSelection(.enabled) }
            } footer: { Text("删除前后重新读取核对。发生错误后请返回列表刷新再选择。租期为读取时的快照，不是倒计时。") }
        }.font(AppTypography.row).tint(AppPalette.accent).appDetailStyle("映射详情")
            .confirmationDialog("删除此活动映射？", isPresented: $confirming, titleVisibility: .visible) {
                Button("删除并重新核对", role: .destructive) { Task { await remove() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(mapping.transport) \(mapping.externalPort) → \(mapping.internalAddress):\(mapping.internalPort)。可能重启 UPnP 服务并影响其他映射。其他设备同时修改时仍存在序号变化风险。")
            }
    }

    private func remove() async {
        let generation = store.connectionID
        running = true; error = nil
        defer { running = false }
        do {
            let result = try await store.deleteUPnPMapping(mapping, observed: observed)
            guard generation == store.connectionID else { return }
            onUpdate(result)
            notice = "重新读取后未发现所选端点映射。客户端仍可能重新建立，请返回列表按需刷新。"
        } catch {
            guard generation == store.connectionID else { return }
            self.error = FriendlyError.message(error) + "\n请求中断不代表已取消，请返回列表重新读取映射。"
        }
    }
}
