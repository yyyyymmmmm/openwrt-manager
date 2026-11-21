import SwiftUI
import UIKit

struct RouterScanView: View {
    let onSelect: (String) -> Void
    @State private var discovery = RouterDiscoveryService()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppPage(title: "自动发现路由器", subtitle: "连接路由器所在的 Wi-Fi，查找并验证 OpenWrt 路由器。", setup: true) {
            AppGroup {
                AppRow(title: "只查常用网关地址", detail: "检查 .1 / .254 等少数地址，逐个验证是否为 OpenWrt，不做全网段扫描", symbol: "wifi")
                AppDivider()
                AppRow(title: "由你确认并登录", detail: "发现只做识别，不会发送任何密码；登录在下一步由你完成", symbol: "lock.shield")
            }
            if discovery.isScanning {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(value: Double(discovery.completed), total: Double(max(discovery.total, 1)))
                        .accessibilityLabel("局域网发现进度")
                    Text(discovery.total == 0 ? "正在发现服务…" : "已检查 \(discovery.completed) / \(discovery.total) 个地址，正在验证 OpenWrt…")
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
                AppSection(title: "发现的路由器") {
                    AppGroup {
                        ForEach(discovery.results) { result in
                            Button {
                                discovery.stop()
                                onSelect(result.address)
                            } label: {
                                AppRow(title: result.model ?? result.name,
                                       detail: detail(for: result),
                                       symbol: "wifi.router",
                                       badge: result.verified ? "已验证 OpenWrt" : nil,
                                       chevron: true)
                            }.buttonStyle(.plain)
                            if result.id != discovery.results.last?.id { AppDivider() }
                        }
                    }
                }
            } else if discovery.hasScanned && !discovery.isScanning && !discovery.permissionDenied {
                ContentUnavailableView("没有发现 OpenWrt 路由器", systemImage: "wifi.exclamationmark",
                                       description: Text("已检查网关等常用地址，均未通过 OpenWrt 验证。路由器可能在其他地址、使用 IPv6 或未广播服务。请确认 Wi-Fi，也可以手动输入管理网址。"))
                    .padding(.top, 24)
            }
            AppSection(title: "其他连接方式", note: "自动发现只覆盖常用地址。使用自定义端口、VPN、蜂窝网络或网络隔离时，请手动连接。") {
                AppGroup {
                    Button { dismiss() } label: { AppRow(title: "手动输入地址", symbol: "keyboard", chevron: true) }.buttonStyle(.plain)
                }
            }
        }.appDetailStyle("")
            .onDisappear { discovery.stop() }
    }

    /// Address first, then the board facts the router actually
    /// reported (model/firmware are omitted when it did not answer),
    /// then where the lead came from.
    private func detail(for result: DiscoveredRouter) -> String {
        var lines = [result.address]
        if let firmware = result.firmware { lines.append(firmware) }
        lines.append(result.source)
        return lines.joined(separator: "\n")
    }
}
