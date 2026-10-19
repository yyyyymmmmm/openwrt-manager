# OpenWrt Manager

适用于 iPhone 的原生 OpenWrt 管理客户端。当前开发版本包含手动添加、局域网发现、ubus 登录，以及概览、DHCP 设备搜索/详情、网络/Wi-Fi、插件服务和系统信息的只读视图。它不是 OpenWrt 官方应用。

## 技术方案

- SwiftUI 原生界面，部署目标 iOS 17；在 iOS 26 上使用系统当前的导航栏和材质外观。
- AppIcon 使用深蓝到青绿底色、无线信号和路由器图形，并提供 iPhone 与 App Store 所需尺寸。
- Packages/OpenWrtKit 负责地址规范化、ubus JSON-RPC 与数据模型。
- 用户名和密码用于路由器本地 session.login；密码仅在用户选择记住时写入 iOS 钥匙串。
- 不包含云端账户、云中转、任意命令执行、固件刷写或路由器配置写入。
- 运行数据只保留在当前进程；已保存的地址和用户名保存在本机，应用不发送分析数据。
- 全局使用系统语义字号：列表 subheadline（默认 15pt）、说明 footnote（13pt）、元信息 caption（12pt）；设置可选跟随系统、紧凑、标准、加大，系统辅助功能大字始终优先。外观支持跟随系统、浅色和深色。
- 本次连接保留最近 50 条本机会话活动；它不是路由器日志。帮助、隐私和关于页面在登录前与连接后均可访问。

## 在 Mac 上运行

需要安装 Xcode 26 或更新版本，以及 XcodeGen：

    brew install xcodegen
    git clone https://github.com/yyyyymmmmm/openwrt-manager.git
    cd openwrt-manager
    xcodegen generate
    open OpenWrtManager.xcodeproj

在 Xcode 中选择 OpenWrtManager scheme 和 iPhone Simulator，按 Run。真机运行时选择自己的 Apple 开发者团队并签名。首次扫描时，要允许应用访问本地网络。

## GitHub Actions

.github/workflows/ios.yml 会在推送、Pull Request 或手动触发时：

1. 运行 OpenWrtKit Swift Package 测试。
2. 使用 XcodeGen 生成 Xcode 工程。
3. 构建 Release 真机版本，打包并上传未签名 IPA（附件保留 30 天）。
4. 在 macOS iPhone Simulator 上编译并运行 UI 冒烟测试。
5. 上传 .xcresult 和测试截图。

这个工作流用于在 GitHub 上编译和运行模拟器测试，并上传未签名的 iOS IPA。未签名 IPA 不能直接安装到实体 iPhone，需先自行签名；TestFlight/App Store 分发还需要 Apple Developer Program。工作流不收集、存储或导出 Apple 私钥。

源码仓库为 https://github.com/yyyyymmmmm/openwrt-manager 。每次构建的状态和下载附件见仓库 Actions 页面；请以具体运行结果为准。尚未完成真实路由器联调。

## OpenWrt 兼容性

客户端通过 HTTP(S) 的 /ubus JSON-RPC 接口工作。需要固件启用了 rpcd 和 uhttpd-mod-ubus，并允许这个账户调用 session.login。DHCP、无线及服务信息还取决于 LuCI RPC 接口、具体固件版本和 rpcd ACL；某项接口缺失时，该页面会显示对应错误，不会拿演示数据填充。

优先使用 HTTPS。自签名证书需要先核对 SHA-256 指纹，再明确选择信任；证书信任按该路由器主机保存。使用 HTTP 时应用会说明登录信息在当前网络中未加密，并要求再次确认。

局域网发现会查找 Bonjour Web 服务，并检查手机当前 Wi-Fi IPv4 地址所在网段的 80/443 端口。较大的网段会限制在手机所在的 /24；扫描结果只说明 Web 端口开放，不证明它就是 OpenWrt。自定义端口、IPv6-only、VPN 或网络隔离环境请手动输入地址。设备必须允许 iPhone 访问其管理接口。

## 当前范围

当前所有路由器操作均为只读。用户已选定后续的功能方向，包括 Wi-Fi、DHCP、防火墙、VPN、服务和插件；这些写操作暂不开放，需先逐项确认路由器能力、ACL、配置回滚和断网恢复流程。

插件页按精确 procd 服务名称识别 DDNS、SQM、PBR、mwan3、SmartDNS、Adblock、Docker 和 Transmission。识别到服务不证明插件版本、可配置权限或业务健康；未识别不等于未安装。LuCI、软件包及 iStore 网页入口保持管理地址的协议、端口与代理前缀，网页使用独立登录，不注入保存的密码或会话。iStore 入口依赖路由器已安装兼容版本；当前没有原生安装、卸载或插件配置功能。

阶段待办见 TASKS.md。App Store 发布仍需正式开发者主体、公开政策与支持页面、签名、TestFlight 及真实设备兼容性验证。当前内置隐私说明描述开发版行为，不表示已经完成上架审核。

## 参考调研

- OpenWrt 官方 LuCI 的 rpcd-mod-luci 实现了 getDHCPLeases，并分别返回 dhcp_leases、dhcp6_leases、hostname、macaddr、ipaddr/ip6addr 和 expires 字段；客户端按这些字段兼容解析。
- GitHub Actions macOS-15 镜像提供 Xcode 26.x 与 iOS 26 Simulator SDK；工作流会选择已安装的 iOS 26 iPhone runtime，不把 Xcode 工程文件提交到仓库。
- 协议层直接使用 OpenWrt 的 ubus JSON-RPC，不复用 LuCI 网页界面。现有第三方客户端可供交互设计参考，但本项目不依赖其实现。
