# OpenWrt 路由器管理客户端

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

用户已确认原生 SwiftUI；GitHub Actions 在 macOS runner 编译。协议与模型使用独立 Swift Package。iOS 26 SDK 构建，最低 iOS 17 是本轮实现默认值，旧系统使用相应系统外观。

## Users

先供用户个人管理现有 OpenWrt 路由器，之后考虑 TestFlight/App Store。

## Product Purpose

从 iPhone 连接路由器：扫描局域网或输入地址，使用路由器账户登录，了解设备和网络状态，并逐步提供配置管理。

## Operating Context

用户当前在 Windows 上开发，通过 GitHub 仓库 yyyyymmmmm/openwrt-manager 的 macOS Actions 编译和运行模拟器测试。没有已提供的真实路由器地址、测试凭据或 Apple 开发者签名。

## Capabilities and Constraints

- 已确认：多路由器、手动网址、局域网扫描、路由器登录。
- 已确认完整功能方向：设备、Wi-Fi、网络维护、服务和插件。
- 产品目标：成为手机上的完整 OpenWrt 管理入口，覆盖核心网络/系统能力、已识别的官方与社区插件，以及未知插件的 LuCI 补充入口。
- 当前实现状态：连接/登录闭环、概览与只读设备/网络/服务/系统页面、演示模式、编译工作流；写入与插件适配按能力矩阵分阶段接入。
- HTTP/HTTPS 访问；默认校验 TLS，自签证书不能静默绕过。
- OpenWrt 功能依赖实际固件、ACL 与 rpcd 模块；无法保证发现所有设备。
- 所有演示数据必须可辨识，真实连接不能以演示数据填补错误。
- 不做云中转或任意命令执行。网络配置写入、软件包、备份、固件和插件管理属于产品目标，但必须在能力探测、权限校验、变更预览和恢复流程完成后分阶段开放；固件刷写不会被伪装成普通设置开关。

## Brand Commitments

用户指定 iOS 26 原生工具风，参考系统设置/家庭 App。玻璃材质用于原生导航和操作，数据内容保持清晰。暂用 OpenWrt Manager 工作名称，未宣称官方出品。

## Product Principles

1. 先连接成功，再逐步展示能力。
2. 状态来自真实响应；缓存必须标注时间。
3. 配置修改必须有可验证的恢复路径。
4. 原生可访问性、深色模式和错误恢复属于基础体验。

## Evidence on Hand

已有 SwiftUI 原生工程和 GitHub macOS 构建工作流；前版构建 f0bc665 已通过协议测试与模拟器 UI 测试。当前新增代码必须重新通过 CI，并审阅实际模拟器截图后交付。没有真实路由器或实体 iPhone 联调证据，不宣称全功能兼容或已具备上架条件。
