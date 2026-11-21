# OpenWrtKit

Zirox-openwrt 的协议与逻辑层 Swift Package。App 层只做呈现与编排；一切与路由器打交道的逻辑——会话、发现、解析、事务、升级、终端核心——都在这里，可独立于 UI 测试。

## 产品

| 库 | 内容 |
|---|---|
| `OpenWrtKit` | ubus JSON-RPC 客户端与会话管理（LuCI 表单登录）、发现与能力快照、页面注册表、UCI 读写与 L4 事务支持、专用页数据面（Open-Box 面板、DDNS、frpc 等）、备份恢复、在线升级流程、监控采样与告警、主题目录、本地化（KitL10n）、诊断 |
| `OpenWrtSSH` | 基于 swift-nio-ssh 的 SSH 传输：终端字节流、主机指纹信任、dropbear 协商补全（AES-CTR / HMAC-SHA2） |

依赖：swift-nio、swift-nio-ssh、swift-system（见 `Package.resolved`）。

## 测试

```sh
~/tools/swift-6.2/usr/bin/swift test --package-path Packages/OpenWrtKit
# 或在装有 Swift 的环境： swift test --package-path Packages/OpenWrtKit
```

当前 365 项（2026-11-21 实测），全绿是出包前置（见 `../docs/release-checklist.md`）。测试只用夹具与录制样本，不连真实路由器；涉及路由器行为的结论必须以真实会话实测为准（本机 ubus CLI 绕过会话 ACL，结论不作数——见 `../docs/permissions.md`）。
