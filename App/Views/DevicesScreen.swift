import SwiftUI
import OpenWrtKit

struct DevicesScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        NavigationStack {
            DevicesContent(showingRouterPicker: $showingRouterPicker, isRoot: true)
        }
    }
}

struct DevicesContent: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var search = ""
    @State private var filter = "全部"
    var isRoot = false

    private var filteredLeases: [DHCPLease] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.leases.filter { lease in
            (filter == "全部" || (filter == "IPv6" ? lease.address.contains(":") : !lease.address.contains(":"))) &&
            (query.isEmpty || [lease.hostname, lease.address, lease.mac, lease.duid ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    init(showingRouterPicker: Binding<Bool> = .constant(false), isRoot: Bool = false) {
        _showingRouterPicker = showingRouterPicker
        self.isRoot = isRoot
    }

    var body: some View {
        Group {
            if isRoot {
                AppRootPage(showingRouterPicker: $showingRouterPicker, title: "设备", subtitle: "局域网客户端与地址分配") { deviceBody }
            } else {
                AppPage(title: "设备", subtitle: "局域网客户端与地址分配") { deviceBody }.appDetailStyle("设备")
            }
        }
    }

    private var deviceBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReadStatus(updatedAt: store.devicesUpdatedAt, error: store.devicesError)
            HStack(spacing: 12) {
                summary("DHCP 租约", store.devicesUpdatedAt == nil ? "—" : "\(store.leases.count)")
            }.padding(.vertical, 14)
            AppDivider(inset: 0).padding(.bottom, 18)
            AppSearchField(prompt: "名称、IP、MAC 或 DUID", text: $search, identifier: "deviceSearchField")
            HStack(spacing: 6) {
                ForEach(["全部", "IPv4", "IPv6"], id: \.self) { item in
                    FilterButton(title: item, selected: filter == item) { filter = item }
                }
            }.padding(.top, 12)
            AppSection(title: "DHCP 租约 · \(filteredLeases.count)", note: "租约不代表设备当前在线；固定 IP 设备可能不会出现在此列表。") {
                AppGroup {
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
                        .buttonStyle(.plain)
                        if lease.id != filteredLeases.last?.id { AppDivider(inset: 60) }
                    }
                }
                }
            }
        }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(AppTypography.title).monospacedDigit().foregroundStyle(AppPalette.text)
            Text(title).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                    ShareLink(item: "设备：\(lease.hostname.isEmpty ? "未命名设备" : lease.hostname)\nIP：\(lease.address)\nMAC：\(lease.mac)") {
                        Label("分享设备信息", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                ContentUnavailableView("租约已不在列表中", systemImage: "network.slash",
                                       description: Text("路由器的最新响应未包含此租约，可返回设备列表查看。"))
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .listRowBackground(AppPalette.surface)
        .appDetailStyle("设备详情")
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
        HStack(spacing: 10) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(AppPalette.blue)
                .frame(width: 38, height: 38)
                .background(AppPalette.blueSoft, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(lease.hostname.isEmpty ? "未命名设备" : lease.hostname)
                    .font(AppTypography.rowTitle)
                Text(lease.address)
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppPalette.muted)
                Text("仅租约 · 在线状态未确认").font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppPalette.muted)
        }
        .foregroundStyle(AppPalette.text)
        .padding(.horizontal, 12).padding(.vertical, 12)
        .contentShape(Rectangle())
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
