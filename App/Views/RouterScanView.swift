import SwiftUI
import UIKit

struct RouterScanView: View {
    let onSelect: (String) -> Void
    @State private var discovery = RouterDiscoveryService()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppPage(title: "扫描局域网", subtitle: "连接路由器所在的 Wi-Fi，查找可用的管理地址。", setup: true) {
            AppGroup {
                AppRow(title: "当前网络", detail: "只检查本地网络，不需要路由器密码", symbol: "wifi")
                AppDivider()
                AppRow(title: "由你确认并登录", detail: "发现 Web 端口不代表已验证为 OpenWrt", symbol: "lock.shield")
            }
            if discovery.isScanning {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(value: Double(discovery.completed), total: Double(max(discovery.total, 1)))
                        .accessibilityLabel("局域网扫描进度")
                    Text(discovery.total == 0 ? "正在发现服务…" : "已检查 \(discovery.completed) / \(discovery.total) 个端口")
                        .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                    Button("停止扫描") { discovery.stop() }.buttonStyle(AppSecondaryButtonStyle())
                }.padding(.top, 24)
            } else {
                Button(discovery.hasScanned ? "重新扫描" : "开始扫描", systemImage: "dot.radiowaves.left.and.right") {
                    discovery.start()
                }.buttonStyle(AppPrimaryButtonStyle()).padding(.top, 24)
                    .accessibilityIdentifier("startScanButton")
            }
            if let message = discovery.message {
                Text(message).font(AppTypography.secondary).foregroundStyle(AppPalette.muted).padding(.top, 12)
            }
            if discovery.permissionDenied {
                AppSection(title: "需要本地网络权限", note: "允许访问本地网络后，返回这里重新扫描。") {
                    AppGroup {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: { AppRow(title: "打开系统设置", symbol: "gearshape", chevron: true) }.buttonStyle(.plain)
                    }
                }
            }
            if !discovery.results.isEmpty {
                AppSection(title: "发现的 Web 管理地址") {
                    AppGroup {
                        ForEach(discovery.results) { result in
                            Button {
                                discovery.stop()
                                onSelect(result.address)
                            } label: {
                                AppRow(title: result.name, detail: result.address + "\n" + result.source,
                                       symbol: "wifi.router", chevron: true)
                            }.buttonStyle(.plain)
                            if result.id != discovery.results.last?.id { AppDivider() }
                        }
                    }
                }
            } else if discovery.hasScanned && !discovery.isScanning && !discovery.permissionDenied {
                ContentUnavailableView("没有发现管理地址", systemImage: "wifi.exclamationmark",
                                       description: Text("路由器可能使用其他端口、只提供 IPv6，或没有广播服务。请确认 Wi-Fi，也可以手动输入管理网址。"))
                    .padding(.top, 24)
            }
            AppSection(title: "其他连接方式", note: "扫描无法发现所有 OpenWrt。使用自定义端口、VPN、蜂窝网络或网络隔离时，请手动连接。") {
                AppGroup {
                    Button { dismiss() } label: { AppRow(title: "手动输入地址", symbol: "keyboard", chevron: true) }.buttonStyle(.plain)
                }
            }
        }.appDetailStyle("")
            .onDisappear { discovery.stop() }
    }
}
