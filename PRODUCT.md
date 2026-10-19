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

用户当前在 Windows 上开发，希望通过 GitHub 编译。没有已提供的路由器地址、测试凭据、Apple 开发者证书或 GitHub 远端仓库。

## Capabilities and Constraints

- 已确认：多路由器、手动网址、局域网扫描、路由器登录。
- 已确认完整功能方向：设备、Wi-Fi、网络维护、服务和插件。
- 本轮范围：连接/登录闭环、概览与只读设备/网络/服务/系统页面、演示模式、编译工作流。
- HTTP/HTTPS 访问；默认校验 TLS，自签证书不能静默绕过。
- OpenWrt 功能依赖实际固件、ACL 与 rpcd 模块；无法保证发现所有设备。
- 所有演示数据必须可辨识，真实连接不能以演示数据填补错误。
- 暂不实现云中转、固件刷写、网络配置写入或任意命令执行。

## Brand Commitments

用户指定 iOS 26 原生工具风，参考系统设置/家庭 App。玻璃材质用于原生导航和操作，数据内容保持清晰。暂用 OpenWrt Manager 工作名称，未宣称官方出品。

## Product Principles

1. 先连接成功，再逐步展示能力。
2. 状态来自真实响应；缓存必须标注时间。
3. 配置修改必须有可验证的恢复路径。
4. 原生可访问性、深色模式和错误恢复属于基础体验。

## Evidence on Hand

空白项目。没有真机联调或 Xcode 编译证据；交付不能声称已经过真机验证。
