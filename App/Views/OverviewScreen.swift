import SwiftUI
import OpenWrtKit

struct OverviewScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool

    var body: some View {
        NavigationStack {
            List {
                DataStatusSection(updatedAt: store.overviewUpdatedAt, error: store.overviewError)

                Section {
                    if let profile = store.activeProfile {
                        HStack(spacing: 14) {
                            Image(systemName: "wifi.router")
                                .font(.title)
                                .foregroundStyle(.tint)
                                .frame(width: 42, height: 42)
                                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.snapshot?.system.hostname ?? profile.name)
                                    .font(AppTypography.rowTitle)
                                Text(profile.address)
                                    .font(AppTypography.secondary)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Text("会话已建立")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else if store.isDemo {
                        HStack(spacing: 14) {
                            Image(systemName: "wifi.router")
                                .font(.title)
                                .foregroundStyle(.tint)
                                .frame(width: 42, height: 42)
                                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.snapshot?.system.hostname ?? "OpenWrt")
                                    .font(AppTypography.rowTitle)
                                Text("示例路由器")
                                    .font(AppTypography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("演示")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.vertical, 4)
                    } else {
                        DataUnavailableView(
                            title: "无法读取路由器状态",
                            message: "请检查路由器地址和账户权限。",
                            error: store.overviewError,
                            isLoading: store.isRefreshing && store.snapshot == nil,
                            retry: { Task { await store.refresh() } }
                        )
                    }
                } header: {
                    Text("连接")
                } footer: {
                    if let updated = store.overviewUpdatedAt {
                        Text("上次更新：\(updated.formatted(date: .omitted, time: .shortened))")
                    }
                }

                Section("设备") {
                    if let error = store.devicesError, store.leases.isEmpty, !store.isDemo {
                        DataUnavailableView(title: "无法读取设备", message: "", error: error)
                    } else {
                        LabeledContent("DHCP 租约", value: "\(store.leases.count) 台")
                        ForEach(store.leases.prefix(3)) { lease in
                            DeviceRow(lease: lease)
                        }
                        if store.leases.count > 3 {
                            NavigationLink("查看全部设备", destination: DevicesContent(showingRouterPicker: $showingRouterPicker))
                        }
                    }
                }

                Section("网络") {
                    if store.snapshot?.interfaces.isEmpty != false {
                        DataUnavailableView(
                            title: "网络接口不可用",
                            message: "当前账户可能没有读取网络状态的权限。",
                            error: store.overviewError,
                            isLoading: store.isRefreshing && !store.hasLoaded
                        )
                    } else {
                        ForEach(Array((store.snapshot?.interfaces ?? []).prefix(3))) { interface in
                            InterfaceRow(interface: interface)
                        }
                    }
                    if let error = store.wirelessError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if store.wirelessUpdatedAt != nil {
                        LabeledContent("无线电", value: "\(store.radios.count) 个")
                    }
                }

                Section {
                    if store.activities.isEmpty {
                        Text("本次连接暂无管理记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.activities.prefix(2)) { activity in
                            ActivityRow(activity: activity)
                        }
                        NavigationLink("查看全部活动") { ActivityListView() }
                    }
                } header: {
                    Text("最近活动")
                } footer: {
                    Text("本次会话记录，不代表路由器完整日志。")
                }

                if let snapshot = store.snapshot, !snapshot.warnings.isEmpty {
                    Section("部分信息不可用") {
                        ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("概览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
        }
    }
}
