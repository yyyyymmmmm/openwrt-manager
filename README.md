# Zirox-openwrt

原生 iOS 的 OpenWrt 路由器管理 App。全原生实现——不内嵌 LuCI 网页、不跳浏览器、不引导用户「去电脑上操作」；路由器的每个功能都在手机内以原生界面完成。

Zirox-openwrt is a fully native iOS app for managing OpenWrt routers. No WebView wrapping of LuCI, no browser hand-offs: every router function is implemented natively on the phone, over the same ubus JSON-RPC / UCI interfaces that LuCI itself uses.

- 平台 / Platform：iOS 26（只做 iOS 26 原生，不做旧系统降级兼容）
- 语言 / Language：Swift / SwiftUI
- Bundle ID：`app.openwrtmanager.ios`
- 版本 / Version：0.3.0（见 `project.yml`）
- 仓库性质：私有项目，与 OpenWrt 官方无隶属关系

## 功能全景 Features

**五 Tab 结构**（概览 / 网络 / 服务 / 系统 / 设置），导航由「发现快照 + 专用页注册表」生成：设备上没有的菜单不显示，没有专用页的服务走结构化通用页兜底，绝不假造入口。

**逐台发现**：连接后枚举固件版本、机型、真实菜单树、已装服务与接口清单，生成带时间戳的能力快照。两台联调设备实测：旁路由（OpenWrt 25.12.5）47 个二级菜单、主路由（OpenWrt 24.10.8）24 个菜单项加 26 项 init.d 核心服务，两台的页面构成完全不同，均由发现结果驱动。

**专用页**（服务类，按注册表）：Open-Box、HomeProxy、MosDNS、动态 DNS、应用过滤、网络唤醒、KMS（vlmcsd）、frpc、NATMap、Socat、ZeroTier、WebDAV。网络侧含接口、无线、DHCP、DNS、防火墙、静态路由、UPnP、带宽监控、网络诊断、网速测试、SQM、信道分析等页。

**事务层写操作**：一切配置写入走统一事务——改前快照 → 差异预览 → 用户确认 → 下发 → 服务重载 → 回读验证 → 失败回滚。核心服务（rpcd、ubusd、network 等）有保护名单，禁止停用以防自锁。

**终端与文件管理**：原生 SSH 终端（NIOSSH，含 AES-CTR/HMAC-SHA2 协商补全、wcwidth 网格、括号粘贴、快捷键栏）；文件管理走 ubus file 接口（浏览、上传分块校验、下载分享、新建/重命名/删除空目录）。

**备份恢复与在线升级安全闭环**：备份走官方 sysupgrade 机制并校验 SHA-256，恢复前自动留快照；固件升级有 /tmp 空间预检、流式落盘、官方哈希比对门与 `sysupgrade --test` 校验，校验不过绝不真刷，最终刷写只由用户在 App 内确认触发。

**Open-Box 面板原生接入**：面板密码只进钥匙串，登录后原生呈现订阅、流量、策略条目与节点质量（API 形状实证见 `briefs/openbox-native-spec.md`）。

**主题系统**：四套主题（腾讯蓝 #0052D9 为默认，与 App 图标主色一致；青绿 #087873 为初版配色、原值保留；另有紫罗兰、落日橙），深浅色跟随系统。状态色只作小面积圆点/图标，永不作大面积填充——口径见 [docs/themes.md](docs/themes.md)。

**Face ID 与凭据把关**：已保存的路由器密码只存钥匙串；前台使用凭据（切换路由器、终端连接）先经 Face ID 把关，取消认脸时落到的手动表单不预填密码。另有 App 锁与 SSH 主机指纹三态信任（首次确认、变更阻断）。

**诊断导出**：设置页可导出脱敏诊断日志（记录时即脱敏，零密码/令牌），供排障定位。

**其他**：历史采样曲线与本地告警通知、操作记录、设备管理（租约/邻居/无线关联三源合并）、管理安全页（改密闭环、SSH 授权密钥、软件包动作）、桌面小组件与长任务 Live Activity、iPad 侧边栏形态、中英双语（跟随系统语言）。

## 架构 Architecture

五层地基，页面只许建在地基之上（详见 [docs/architecture.md](docs/architecture.md)）：

| 层 | 职责 |
|---|---|
| L0 连接层 | 多路由器档案、连通性探测、地址候选 |
| L1 会话层 | LuCI 表单登录取会话、令牌生命周期、过期自动重登、凭据存钥匙串 |
| L2 发现层 | 枚举菜单/服务/接口，生成 CapabilitySnapshot（按路由器缓存） |
| L3 数据层 | ubus 客户端、UCI 只读客户端、全 App 共用的实时轮询引擎、数据新鲜度标记 |
| L4 事务层 | 唯一写门：快照 → 预览 → 确认 → 下发 → 重载 → 回读验证 → 回滚 |

协议、解析与事务逻辑位于独立 Swift Package `Packages/OpenWrtKit`（含 `OpenWrtKit` 与 `OpenWrtSSH` 两个库产品）；App 层只做呈现与编排。

## 构建与安装 Build & Install

出包走 **Codemagic**（工作流 `zirox-ios`，定义见 `codemagic.yaml`；GitHub Actions 自 2026-11-20 起被账户账单拦截，仅保留 `.github/workflows/ios.yml` 作镜像参考）。构建步骤：审计脚本单测 → 源码审计 → OpenWrtKit 测试 → 模拟器 UI 测试 → 未签名 Release 构建 → IPA 审计。

本地验证命令（需装有 Swift 工具链；App 本体构建需 macOS + Xcode 26 + XcodeGen）：

```sh
# 协议层测试（当前 365 项）
~/tools/swift-6.2/usr/bin/swift test --package-path Packages/OpenWrtKit
# 或在装有 Swift 的环境： swift test --package-path Packages/OpenWrtKit

# 发布审计（源码与 IPA 双模式）
python3 scripts/audit_release.py
python3 -m unittest discover -s scripts -p 'test_*.py'
```

产物为未签名 IPA（`Zirox-openwrt-unsigned.ipa`），使用者以自己的方式自签安装。TestFlight 工作流骨架（`zirox-testflight`）已就绪，启用条件见 `briefs/testflight-checklist.md`；App Store Connect API 密钥（.p8）只能经 Codemagic 后台集成交接，绝不入仓。出包流程与真机验收要点见 [docs/release-checklist.md](docs/release-checklist.md)。

## 权限模型 Permissions

OpenWrt 的 rpcd 按 acl.d **逐项枚举**授权：ubus 对象逐方法、file exec 逐条完整命令行、file 读写逐路径、uci 逐配置名。root 登录会话拿到的是全部 ACL 组的并集，但枚举之外的通道仍会被 ubus 状态码 6 拒绝。本 App 的功能一律优先走路由器已授权的正规通道；只有「文件管理全功能」与 keepalived 配置需要路由器侧补一份授权文件 `luci-app-zirox`（含安装与回滚方法），详见 [docs/permissions.md](docs/permissions.md)。

## 数据与隐私

无云端账户、无中转服务、无广告与分析 SDK。路由器密码与 Open-Box 面板密码只存本机钥匙串；诊断导出在记录时脱敏。详见 App 内置隐私说明与 `App/PrivacyInfo.xcprivacy`。

## 文档索引 Documentation

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 结构规格精要：五层地基、五 Tab、发现与注册表、双机差异 |
| [docs/permissions.md](docs/permissions.md) | rpcd ACL 模型、zirox 授权文件全文、双机实测结论、安装与回滚 |
| [docs/localization.md](docs/localization.md) | 双语机制：String Catalog、LuCI 翻译目录与 SuperFastHash、设备数据不译口径 |
| [docs/themes.md](docs/themes.md) | 主题目录与色值、状态色面积口径、配色防回归审计 |
| [docs/release-checklist.md](docs/release-checklist.md) | 出包流程与真机验收清单 |
| [CHANGELOG.md](CHANGELOG.md) | 按 Codemagic 构建编号整理的里程碑 |
| `briefs/` | 过程档案（审计报告、盘点表、TestFlight 清单），非耐久文档 |
| `scripts/README.md` | 审计与辅助脚本说明 |
| `Packages/OpenWrtKit/README.md` | 协议层包结构与测试跑法 |

> 历史文档 `PRODUCT.md`、`DESIGN.md`、`TASKS.md` 为重构前旧档，已在各自文件头标注作废，不再作为事实来源。
