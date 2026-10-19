import SwiftUI
import OpenWrtKit

struct NetworkScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        NavigationStack {
            List {
                DataStatusSection(updatedAt: store.overviewUpdatedAt, error: store.overviewError)
                Section {
                    if let error = store.overviewError, store.snapshot?.interfaces.isEmpty != false {
                        DataUnavailableView(
                            title: "无法读取网络接口",
                            message: "确认账户具有 network.interface.dump 权限。",
                            error: error,
                            isLoading: store.isRefreshing && !store.hasLoaded,
                            retry: { Task { await store.refresh() } }
                        )
                    } else if store.snapshot?.interfaces.isEmpty != false {
                        ContentUnavailableView(
                            "暂无接口信息",
                            systemImage: "network",
                            description: Text("网络接口数据由路由器的 ubus 服务提供。")
                        )
                    } else {
                        ForEach(store.snapshot?.interfaces ?? []) { interface in
                            InterfaceRow(interface: interface, showAddresses: true)
                        }
                    }
                    ForEach(Array((store.snapshot?.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("网络接口")
                } footer: {
                    Text("当前版本提供只读状态。修改 IP、DNS 或 WAN 设置需要事务校验和恢复机制，暂未开放。")
                }

                DataStatusSection(updatedAt: store.wirelessUpdatedAt, error: store.wirelessError)
                Section {
                    if let error = store.wirelessError, store.radios.isEmpty {
                        DataUnavailableView(
                            title: "无法读取无线状态",
                            message: "检查 network.wireless.status 权限。",
                            error: error,
                            isLoading: store.isRefreshing && !store.hasLoaded,
                            retry: { Task { await store.refresh() } }
                        )
                    } else if store.radios.isEmpty {
                        ContentUnavailableView(
                            "没有无线电信息",
                            systemImage: "wifi.slash",
                            description: Text("设备可能没有无线硬件，或者无线功能不可用。")
                        )
                    } else {
                        ForEach(store.radios) { radio in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: radio.up ? "wifi" : "wifi.slash")
                                        .foregroundStyle(radio.up ? .green : .secondary)
                                    Text(radio.name)
                                        .font(AppTypography.rowTitle)
                                    Spacer()
                                    Text(radio.up ? "已启用" : "未启用")
                                        .font(.caption)
                                        .foregroundStyle(radio.up ? .primary : .secondary)
                                }
                                LabeledContent("信道", value: radio.channel)
                                if radio.networks.isEmpty {
                                    Text("没有广播中的网络")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(radio.networks, id: \.self) { ssid in
                                        Label(ssid, systemImage: "dot.radiowaves.left.and.right")
                                            .font(.subheadline)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Wi-Fi")
                } footer: {
                    Text("Wi-Fi 名称可能包含隐私信息。截图或分享前请留意。当前只读取状态，不会更改无线设置。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("网络")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
        }
    }
}

struct InterfaceRow: View {
    let interface: NetworkInterfaceSnapshot
    var showAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle()
                    .fill(interface.up ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(interface.name)
                    .font(AppTypography.rowTitle)
                Spacer()
                Text(interface.up ? "在线" : "离线")
                    .font(.caption)
                    .foregroundStyle(interface.up ? .primary : .secondary)
            }
            LabeledContent("协议", value: interface.protocolName)
            if let device = interface.device {
                LabeledContent("设备", value: device)
            }
            if showAddresses {
                if interface.addresses.isEmpty {
                    Text("未分配 IP 地址")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(interface.addresses, id: \.self) { address in
                        LabeledContent("IP 地址", value: address)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
            } else if let address = interface.addresses.first {
                LabeledContent("IP 地址", value: address)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}
