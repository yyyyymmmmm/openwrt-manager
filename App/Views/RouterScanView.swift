import SwiftUI
import UIKit

struct RouterScanView: View {
    let onSelect: (String) -> Void
    @State private var discovery = RouterDiscoveryService()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Label("连接路由器所在的 Wi-Fi", systemImage: "wifi")
                    .font(AppTypography.rowTitle)
                Text("扫描只检查当前网络，不需要路由器密码。检测到 Web 端口后，仍需你确认地址并登录。")
                    .font(AppTypography.reading)
                    .foregroundStyle(.secondary)
                if discovery.isScanning {
                    ProgressView(value: Double(discovery.completed), total: Double(max(discovery.total, 1)))
                        .accessibilityLabel("局域网扫描进度")
                    HStack {
                        Text(discovery.total == 0 ? "正在发现服务…" : "已检查 \(discovery.completed) / \(discovery.total) 个端口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("停止") { discovery.stop() }
                    }
                } else {
                    Button(discovery.hasScanned ? "重新扫描" : "开始扫描", systemImage: "dot.radiowaves.left.and.right") {
                        discovery.start()
                    }
                    .accessibilityIdentifier("startScanButton")
                }
            } footer: {
                if let message = discovery.message {
                    Text(message)
                }
            }

            if discovery.permissionDenied {
                Section {
                    Label("需要本地网络权限", systemImage: "hand.raised")
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("允许访问本地网络后，返回这里重新扫描。")
                }
            }

            if !discovery.results.isEmpty {
                Section("发现的 Web 管理地址") {
                    ForEach(discovery.results) { result in
                        Button {
                            discovery.stop()
                            onSelect(result.address)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name)
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(.primary)
                                    Text(result.address)
                                        .font(AppTypography.secondary)
                                    Text(result.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else if discovery.hasScanned && !discovery.isScanning && !discovery.permissionDenied {
                Section {
                    ContentUnavailableView(
                        "没有发现管理地址",
                        systemImage: "wifi.exclamationmark",
                        description: Text("路由器可能使用其他端口、只提供 IPv6，或没有广播服务。请确认 Wi-Fi，也可以手动输入管理网址。")
                    )
                }
            }

            Section {
                Button("手动输入地址", systemImage: "keyboard") { dismiss() }
            } footer: {
                Text("扫描无法发现所有 OpenWrt。使用自定义端口、VPN、蜂窝网络或路由器之间隔离时，请使用手动连接。")
            }
        }
        .navigationTitle("扫描局域网")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { discovery.stop() }
    }
}
