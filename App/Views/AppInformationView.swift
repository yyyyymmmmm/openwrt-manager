import SwiftUI
import UIKit

struct AppHelpView: View {
    var body: some View {
        List {
            Section("连接路由器") {
                Text("输入路由器管理地址，使用路由器账户登录。App 直接通过路由器的 ubus 接口建立会话，无需注册云端账户。")
                Text("手机需能访问管理地址。局域网内可连接同一 Wi-Fi；自定义端口、反向代理和远程地址可手动输入。")
            }
            Section("无法扫描或连接") {
                Text("允许本地网络访问后重试。访客 Wi-Fi、客户端隔离、VPN 或防火墙可能阻止访问。扫描只检查当前 Wi-Fi 网段的 Web 端口，不保证找到所有路由器。")
                Text("无法登录时，请检查 rpcd、uhttpd-mod-ubus 和账户 ACL。各页的数据接口不同，读取失败时会显示路由器返回的错误及重新读取入口。")
                Button("打开系统设置", systemImage: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Section("插件与配置") {
                Text("插件目录从已安装软件包读取，包含版本、依赖和关联配置。运行实例不代表插件配置已生效，也不代表业务可用。")
                Text("配置页面直接编辑路由器返回的 UCI 字段。应用修改前可预览；应用后需在 90 秒内验证连接并确认保留。修改网络或管理访问可能导致连接中断。")
                Text("插件服务页提供启动、停止、重启及开机启动操作。只有路由器确认请求成功后才显示执行结果；请同时核对服务运行状态。")
            }
            Section("连接安全") {
                Text("优先使用 HTTPS。自签名证书须通过可信渠道核对指纹后再信任；证书变更时应重新核对。HTTP 会明文传输登录信息和会话。")
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
                Text("更新日期：2026 年 10 月 20 日")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                Text("App 直接连接你指定的路由器，没有云端账户、广告或分析 SDK，也不向开发者服务器上传路由器数据。")
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
            Section("配置与分享") {
                Text("配置草稿保留在当前进程内存中。只有你预览并确认应用后，App 才将修改提交到路由器；服务操作也需要单独确认。配置内容可能包含敏感信息，请谨慎展示和分享。")
                Text("设备信息仅在你主动分享时交给系统分享面板。你选择的接收应用或服务按其自身政策处理数据。")
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
                Text("原生连接、状态读取、已安装插件目录、UCI 字段管理、系统服务控制与系统记录。页面内容和可执行操作取决于路由器实际接口、已安装软件包及账户权限。")
                    .font(AppTypography.reading)
            }
            Section {
                NavigationLink("隐私说明") { AppPrivacyView() }
                NavigationLink("帮助与连接") { AppHelpView() }
            }
        }
        .scrollContentBackground(.hidden).background(AppPalette.canvas)
        .appDetailStyle("关于")
    }
}
