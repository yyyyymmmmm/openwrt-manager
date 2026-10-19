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
                } else {
                    ForEach(store.leases) { lease in
                        DeviceRow(lease: lease)
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
        .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
        .refreshable { await store.refresh() }
    }
}

struct DeviceRow: View {
    let lease: DHCPLease

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(lease.hostname.isEmpty ? "未命名设备" : lease.hostname)
                    .font(.body.weight(.medium))
                Text(lease.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(lease.mac)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(expiration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }

    private var expiration: String {
        guard let expires = lease.expires else { return "租期未知" }
        if expires <= 0 { return "无限租期" }
        let hours = expires / 3600
        let minutes = (expires % 3600) / 60
        if hours > 0 { return "剩余 \(hours) 小时" }
        if minutes > 0 { return "剩余 \(minutes) 分钟" }
        return "即将到期"
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
