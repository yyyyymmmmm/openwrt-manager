# Zirox-openwrt

适用于 iPhone 的第三方原生 OpenWrt 管理客户端。目标是在手机上管理路由器的网络、系统和插件；目前实现范围与尚未完成项目分别记录在 [TASKS.md](TASKS.md)，不将通用配置编辑视为全部插件适配完成。本项目与 OpenWrt、iStore 官方项目无隶属关系。

应用显示名称为 `Zirox-openwrt`，品牌图标使用用户提供的 `zhifi-icon-final.zip` 原稿，覆盖 iOS App 图标、启动画面、引导页和关于页。资源来源与尺寸见 [design/app-icon.md](design/app-icon.md)。

## 当前实现

- 输入管理地址或扫描局域网，使用路由器账户通过 ubus 登录；保存多个路由器，按用户选择将密码写入本机钥匙串。
- 原生五项 TabView：概览、系统、服务、网络、设置。服务包含插件、软件包与启动项；网络包含接口、DHCP 租约、路由/邻居及实际发现的配置。绿色设计系统、紧凑语义字号、深浅外观、文字大小设置及系统辅助功能大字。
- 读取系统状态、网络接口、DHCP 租约、无线和 procd 实例。租约不等于设备在线，接口连接不等于互联网可达，进程存在不等于插件业务健康。
- 动态读取路由器菜单、已安装软件包、配置目录和启动项；列出所有返回的 `luci-app-*` 软件包。未知插件不会因客户端没有预置名称而被遗漏。菜单只用于发现能力，不提供管理网页入口。
- 原生 UCI 配置节和字段管理：字符串与列表编辑、新增与删除、权限检查、变更预览、并发修改检查、apply/confirm 与回滚。应用后须在 90 秒内验证连接并确认；已有待提交修改时拒绝覆盖。
- 原生服务启停、重启和开机启动设置；只有服务接口返回成功才显示执行结果，并重新读取状态。
- 原生系统日志、运行进程与存储挂载记录查看、筛选和刷新。
- 只读 IPv4/IPv6 内核路由与 ARP/NDP 邻居表、邻居搜索及记录详情。通过 `file.exec` 调用四条固定 `/sbin/ip -4|-6 route|neigh show`，依赖固件的 ip 命令和 HTTP 账户 ACL；不等同于全网在线检测或策略路由管理。命令失败明确报错。
- 设置、帮助、隐私及关于页面与实际实现对应。正式 App 不含演示模式、样例业务数据、测试注入分支或模拟成功操作。

尚未完成：网络和插件的专用业务表单、软件包安装/升级/卸载、诊断任务、文件和磁盘操作、备份恢复、重置及固件升级。共用 UCI 编辑只能处理实际返回的配置字段，不能代替这些专有流程；相关入口不会伪装成可用功能。

## 连接与兼容性

客户端使用 HTTP(S) `/ubus` JSON-RPC。需要 `rpcd`、`uhttpd-mod-ubus` 和账户 ACL；租约、启动项及部分系统记录还依赖相应 LuCI RPC 模块。无线、配置和插件内容以当前路由器的实际响应为准。接口缺失、拒绝访问和请求失败会显示错误，不以空数据冒充读取成功。接口、租约、无线、服务和软件包关键记录格式异常时明确报错，不静默略过异常记录后声称清单完整。

软件包清单优先使用固定命令 `/usr/libexec/package-manager-call list-installed` 的受控 CGI 接口；旧版固件可尝试固定的 opkg 清单命令。没有任意命令执行入口，无法读取时明确报错。APK/opkg 的可用性取决于固件和 ACL，不能按 SSH 的 root 权限推定 HTTP 权限。

HTTPS 默认验证系统信任链。自签名证书须核对 SHA-256 指纹后明确选择信任；证书变化会重新提示。HTTP 会在登录前提示明文传输。支持自定义端口与代理路径。

局域网发现查找 Bonjour Web 服务，并检查当前 Wi-Fi IPv4 网段的 80/443 端口；较大网段限制在所在 `/24`。结果仅为候选管理地址，不证明是 OpenWrt。自定义端口、IPv6-only、VPN 或网络隔离环境请手动输入地址。

## 数据处理

没有云端账户、中转服务、广告或分析 SDK。密码仅在选择记住时保存在钥匙串；会话、路由器读取数据和配置草稿保留在当前进程。路由器地址记录、用户名、上次连接时间与显示偏好保存在本机。最近活动只记录本次 App 会话，系统日志另行从路由器读取。

应用不编造运营主体、公开支持渠道或法律协议。App Store 发布仍需真实开发者主体、公开隐私政策与支持页面、隐私申报、签名和审核材料；当前内置隐私说明不表示这些工作已经完成。

## 构建与测试

原生 SwiftUI，最低 iOS 17，使用 Xcode 26 SDK。在 iOS 26 上使用系统导航、TabView 与材质外观。协议、解析与配置事务位于独立 Swift Package `Packages/OpenWrtKit`。

在安装 Xcode 26 和 XcodeGen 的 Mac 上运行：

```sh
brew install xcodegen
git clone https://github.com/yyyyymmmmm/openwrt-manager.git
cd openwrt-manager
swift test --package-path Packages/OpenWrtKit
xcodegen generate
open OpenWrtManager.xcodeproj
```

选择 OpenWrtManager scheme 和 iPhone Simulator。实体设备需要自己的 Apple 开发者团队与签名；首次局域网访问需要允许本地网络权限。

`.github/workflows/ios.yml` 在 GitHub macOS runner 上扫描正式源码与资源、执行协议测试、生成工程、构建并检查未签名 Release IPA，再运行模拟器 UI 测试。`scripts/audit_release.py` 拦截已知演示代码、CI 数据标识和测试资源进入正式包；其规则由 6 项 Python 测试验证，但不能代替逐项功能验收。UI 测试使用仅在 CI 主机环回地址监听的 HTTP 测试服务器，通过正常登录和请求路径验证权限、配置事务及服务操作。服务器和测试数据均不加入正式 App；其截图只能证明自动化测试结果，不能作为真实路由器写入验收证据。

每个提交的实际构建结果以 [GitHub Actions](https://github.com/yyyyymmmmm/openwrt-manager/actions) 为准。未签名 IPA 需自行签名后安装；TestFlight/App Store 分发还需 Apple Developer Program。工作流不收集或导出 Apple 私钥。

本轮逐层导航的自动化范围与尚未验证的分支见 [docs/native-validation.md](docs/native-validation.md)。本机可运行 `python -m unittest discover -s scripts -p 'test_*.py'`，目前包括 6 项发布审计规则和 4 项 CI HTTP 服务器协议测试；Swift 与模拟器结果以对应提交的 macOS 构建为准。

## 联调证据与边界

已对一台 OpenWrt 25.12.5 / x86_64 / APK 路由器完成只读接口核对：587 个软件包、27 个 `luci-app-*`、59 个启动项，以及菜单、配置、状态、日志、进程和挂载接口。当前路由器未安装 iStore；不能据此声称已经完成 iStore 适配。无线接口被 ACL 拒绝，不据此判定没有无线硬件。

未在真实路由器上自动执行配置写入、服务启停、重启或安装。实体 iPhone 的网络权限、断网恢复和各项写入仍需逐项验收。完整任务状态见 [TASKS.md](TASKS.md)。
