import SwiftUI
import OpenWrtKit

struct DevicesScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        NavigationStack {
            DevicesContent(showingRouterPicker: $showingRouterPicker)
        }
    }
}

struct DevicesContent: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var search = ""

    private var filteredLeases: [DHCPLease] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.leases }
        return store.leases.filter { lease in
            [lease.hostname, lease.address, lease.mac, lease.duid ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    init(showingRouterPicker: Binding<Bool> = .constant(false)) {
        _showingRouterPicker = showingRouterPicker
    }

    var body: some View {
        List {
            DataStatusSection(updatedAt: store.devicesUpdatedAt, error: store.devicesError)
            Section {
                if store.isRefreshing && !store.hasLoaded {
                    DataUnavailableView(title: "", message: "", error: nil, isLoading: true)
                } else if let error = store.devicesError, store.leases.isEmpty {
                    DataUnavailableView(
                        title: "无法读取 DHCP 设备",
                        message: "确认路由器提供 LuCI RPC 租约接口，或检查账户 ACL。",
                        error: error,
                        isLoading: store.isRefreshing && !store.hasLoaded,
                        retry: { Task { await store.refresh() } }
                    )
                } else if store.leases.isEmpty {
                    ContentUnavailableView(
                        "暂无 DHCP 租约",
                        systemImage: "iphone",
                        description: Text("路由器尚未报告已分配的地址。静态地址设备可能不会出现在这里。")
                    )
                } else if filteredLeases.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filteredLeases) { lease in
                        NavigationLink {
                            DeviceDetailView(leaseID: lease.id)
                        } label: {
                            DeviceRow(lease: lease)
                        }
                        .accessibilityIdentifier("device-\(lease.id)")
                    }
                }
            } header: {
                Text(store.leases.isEmpty ? "客户端设备" : "客户端设备 · \(store.leases.count)")
            } footer: {
                Text("此列表来自 DHCP 租约，不代表网络中所有在线设备。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "名称、IP、MAC 或 DUID")
        .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
        .refreshable { await store.refresh() }
    }
}

private struct DeviceDetailView: View {
    @Environment(RouterStore.self) private var store
    let leaseID: String

    private var lease: DHCPLease? { store.leases.first { $0.id == leaseID } }

    var body: some View {
        List {
            DataStatusSection(updatedAt: store.devicesUpdatedAt, error: store.devicesError)
            if let lease {
                Section("DHCP 租约") {
                    LabeledContent("设备名称", value: lease.hostname.isEmpty ? "未报告" : lease.hostname)
                    LabeledContent("IP 地址", value: lease.address)
                    LabeledContent("MAC 地址", value: lease.mac.isEmpty ? "未报告" : lease.mac)
                    if let duid = lease.duid { LabeledContent("DUID", value: duid) }
                    LabeledContent("读取时剩余租期", value: lease.remainingLeaseDescription)
                }
                .textSelection(.enabled)
                Section {
                    LabeledContent("在线状态", value: "尚未确认")
                    LabeledContent("无线关联", value: "尚未读取")
                } header: {
                    Text("连接状态")
                } footer: {
                    Text("租约表示路由器曾分配过地址，不能据此判断设备当前是否在线。租期是上次成功读取时的值。")
                }
                Section {
                    ShareLink(item: "设备：\(lease.hostname.isEmpty ? "未命名设备" : lease.hostname)\nIP：\(lease.address)\nMAC：\(lease.mac)") {
                        Label("分享设备信息", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                ContentUnavailableView("租约已不在列表中", systemImage: "network.slash",
                                       description: Text("路由器的最新响应未包含此租约，可返回设备列表查看。"))
            }
        }
        .navigationTitle("设备详情")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}

private extension DHCPLease {
    var remainingLeaseDescription: String {
        guard let expires else { return "未知" }
        if expires < 0 { return "无限租期" }
        if expires == 0 { return "0 分钟（请刷新确认）" }
        let hours = expires / 3600
        let minutes = (expires % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "不足 1 分钟"
    }
}

struct DeviceRow: View {
    let lease: DHCPLease

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(lease.hostname.isEmpty ? "未命名设备" : lease.hostname)
                    .font(AppTypography.rowTitle)
                Text(lease.address)
                    .font(AppTypography.secondary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(lease.mac)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("读取时剩余 \(lease.remainingLeaseDescription)")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var deviceSymbol: String {
        let name = lease.hostname.lowercased()
        if name.contains("phone") || name.contains("iphone") { return "iphone" }
        if name.contains("ipad") || name.contains("tablet") { return "ipad" }
        if name.contains("mac") || name.contains("pc") || name.contains("电脑") { return "laptopcomputer" }
        if name.contains("tv") || name.contains("电视") { return "tv" }
        return "network"
    }
}
