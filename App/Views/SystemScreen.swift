import SwiftUI

struct SystemScreen: View {
    @Environment(RouterStore.self) private var store
    @Binding var showingRouterPicker: Bool
    @State private var showDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                DataStatusSection(updatedAt: store.overviewUpdatedAt, error: store.overviewError)

                Section {
                    systemLine("主机名", value: store.snapshot?.system.hostname ?? "—", symbol: "server.rack")
                    systemLine("设备型号", value: store.snapshot?.system.model ?? "—", symbol: "wifi.router")
                    systemLine("固件版本", value: store.snapshot?.system.firmware ?? "—", symbol: "shippingbox")
                    systemLine("内核", value: store.snapshot?.system.kernel ?? "—", symbol: "terminal")
                    systemLine("架构", value: store.snapshot?.system.architecture ?? "—", symbol: "cpu")
                } header: {
                    Text("设备信息")
                }

                Section {
                    if let uptime = store.snapshot?.system.uptime {
                        systemLine("运行时间", value: Self.duration(uptime), symbol: "clock")
                    } else {
                        systemLine("运行时间", value: "—", symbol: "clock")
                    }
                    memoryLine(
                        title: "内存",
                        used: store.snapshot?.system.memoryUsed,
                        total: store.snapshot?.system.memoryTotal
                    )
                    memoryLine(
                        title: "存储",
                        used: store.snapshot?.system.storageUsed,
                        total: store.snapshot?.system.storageTotal
                    )
                    if let load = store.snapshot?.system.loadAverage, !load.isEmpty {
                        systemLine("系统负载", value: load.map { String(format: "%.2f", $0) }.joined(separator: " · "), symbol: "chart.bar")
                    } else {
                        systemLine("系统负载", value: "—", symbol: "chart.bar")
                    }
                } header: {
                    Text("运行状态")
                }

                if let profile = store.activeProfile {
                    Section("连接信息") {
                        LabeledContent("路由器", value: profile.name)
                        LabeledContent("管理地址", value: profile.address)
                        LabeledContent("登录用户", value: profile.username)
                        if let updated = store.overviewUpdatedAt {
                            LabeledContent("数据更新时间", value: updated.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }

                Section {
                    Button("切换或添加路由器", systemImage: "arrow.left.arrow.right") {
                        showingRouterPicker = true
                    }
                    Button("断开连接", systemImage: "wifi.slash", role: .destructive) {
                        showDisconnectConfirmation = true
                    }
                    .accessibilityIdentifier("disconnectRouterButton")
                } footer: {
                    Text("断开连接只会结束本机的管理会话，不会更改路由器配置。")
                }

                Section("关于") {
                    LabeledContent("应用", value: "OpenWrt Manager")
                    Text("第三方管理客户端，与 OpenWrt 官方项目无隶属关系。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("系统")
            .toolbar { ScreenToolbar(showingRouterPicker: $showingRouterPicker) }
            .refreshable { await store.refresh() }
            .confirmationDialog(
                "断开与 \(store.activeProfile?.name ?? "路由器") 的连接？",
                isPresented: $showDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("断开连接", role: .destructive) { store.disconnect() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这不会删除保存的地址或修改路由器设置。")
            }
        }
    }

    @ViewBuilder
    private func systemLine(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            LabeledContent(title, value: value)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func memoryLine(title: String, used: Int64?, total: Int64?) -> some View {
        if let used, let total, total > 0 {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent(title, value: "\(Self.bytes(used)) / \(Self.bytes(total))")
                ProgressView(value: min(1, Double(used) / Double(total)))
                    .tint(Double(used) / Double(total) > 0.9 ? .orange : .teal)
                    .accessibilityLabel("\(title)占用率")
            }
        } else {
            LabeledContent(title, value: "—")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}
