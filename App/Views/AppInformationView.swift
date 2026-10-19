import SwiftUI
import UIKit

struct AppHelpView: View {
    var body: some View {
        List {
            Section("连接路由器") {
                Text("使用路由器的管理地址和路由器账户登录，通常与 LuCI 网页管理使用同一账户。无需注册云端账户。")
                Text("手机需能访问管理地址。局域网内可连接同一 Wi-Fi；自定义端口、反向代理和远程地址可手动输入。")
            }
            Section("无法扫描或连接") {
                Text("允许本地网络访问后重试。访客 Wi-Fi、客户端隔离、VPN 或防火墙可能阻止访问。扫描只检查当前 Wi-Fi 网段的 Web 端口，不保证找到所有路由器。")
                Text("网页能打开但 App 不能登录时，请检查 rpcd、uhttpd-mod-ubus 和账户 ACL。各页的数据接口不同，部分内容读取失败不会用演示数据替代。")
                Button("打开系统设置", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Section("插件与 iStore") {
                Text("插件页根据路由器报告的服务名称识别部分插件。运行实例不代表插件配置已生效，也不代表业务可用。")
                Text("已安装兼容 iStore 的路由器可从插件页打开 iStore 网页。网页需要独立登录；原生安装、卸载和插件配置尚未接入。")
            }
            Section("连接安全") {
                Text("优先使用 HTTPS。自签名证书须通过可信渠道核对指纹后再信任；证书变更时应重新核对。HTTP 会明文传输登录信息和会话。")
            }
            Section {
                Link(destination: URL(string: "https://github.com/yyyyymmmmm/openwrt-manager/issues")!) {
                    Label("项目支持", systemImage: "arrow.up.right.square")
                }
            } footer: {
                Text("提交问题前请移除密码、会话标识、公网地址和设备标识。链接将在浏览器打开。")
            }
        }
        .font(AppTypography.reading)
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .appDetailStyle("帮助与连接")
    }
}

struct AppPrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("更新日期：2026 年 10 月 19 日")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                Text("本说明适用于当前开发版本。App 直接连接你指定的路由器，没有云端账户、广告或分析 SDK，也不向开发者服务器上传路由器数据。")
            }
            Section("连接与本地存储") {
                Text("登录时，用户名和密码发送到你指定的路由器，用于建立 ubus 会话。会话和读取的设备、网络及服务信息保留在当前进程内存中；断开连接后清除。")
                Text("路由器名称、地址、用户名、上次连接时间及显示偏好保存在本机 App 存储中。设备的备份由 iOS 系统设置管理。")
                Text("选择记住密码时，密码写入此设备解锁时可访问的钥匙串。你确认的证书指纹也保存在钥匙串中；这些条目使用 ThisDeviceOnly 保护，不通过 iCloud 钥匙串同步。")
            }
            Section("权限") {
                Text("本地网络权限用于扫描和连接路由器，在你开始访问时由 iOS 请求。拒绝后可以在系统设置中修改。App 不请求位置、通讯录、照片或麦克风权限。")
            }
            Section("删除数据") {
                Text("在连接页长按已保存的路由器，选择删除并确认，可移除此 App 保存的对应地址记录和钥匙串凭据。断开连接会清除本次会话的数据及最近活动，不更改路由器配置。")
            }
            Section("外部网页与分享") {
                Text("LuCI、软件包和 iStore 网页直接访问路由器，使用独立的网页登录。App 不向网页注入保存的密码或会话。网页内容与其数据处理由路由器及所安装插件决定。")
                Text("设备信息仅在你主动分享时交给系统分享面板。你选择的接收应用或服务按其自身政策处理数据。项目支持链接会打开 GitHub，受其隐私政策约束。")
            }
        }
        .font(AppTypography.reading)
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .appDetailStyle("隐私说明")
    }
}

struct AppAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    var body: some View {
        List {
            Section {
                Label("OpenWrt Manager", systemImage: "wifi.router")
                    .font(AppTypography.rowTitle)
                LabeledContent("版本", value: version)
                Text("第三方 OpenWrt 路由器管理客户端，与 OpenWrt 或 iStore 官方项目无隶属关系。")
                    .font(AppTypography.secondary)
                    .foregroundStyle(.secondary)
            }
            Section("当前版本") {
                Text("提供连接、状态读取和路由器管理网页入口。路由器配置写入、软件包任务和原生插件配置尚未开放。")
                    .font(AppTypography.reading)
            }
            Section {
                Link("项目源码", destination: URL(string: "https://github.com/yyyyymmmmm/openwrt-manager")!)
                NavigationLink("隐私说明") { AppPrivacyView() }
                NavigationLink("帮助与连接") { AppHelpView() }
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .appDetailStyle("关于")
    }
}
