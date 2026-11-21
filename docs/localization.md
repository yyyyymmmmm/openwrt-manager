# 本地化 Localization

> 来源：仓内 `briefs/localization-inventory.md`（本地化全量盘点，2026-11-21）与本地化系统包实现，2026-11-21 收编。
> 定版口径（用户 2026-11-21）：全部页面（含子页面）跟随 iOS 系统语言，做法系统性、与大厂对齐，不逐页打补丁；App 内不设语言开关。

## 四类字符串，四种治理

| 类 | 定义 | 机制 |
|---|---|---|
| ① App 自有 UI 文案 | 按钮/标题/空状态/错误/提示/状态消息 | String Catalog `App/Localizable.xcstrings`：zh-Hans 为源语言，en 为译文。SwiftUI 字面量由系统按目录解析；String 型生产点（store、错误、活动记录）经 `L10n`（`App/Infrastructure/AppLocalization.swift`）解析同一目录。日期/数字/单位走 Locale 格式化 |
| ② 路由器源显示串 | 菜单标题、LuCI 字段标签、通用页 section/字段名、服务页标题 | 统一翻译入口 `LuciLocalization`：复刻 LuCI 网页版机制——发现期协商语言，拉取路由器自家 `/cgi-bin/luci/admin/translations/<lang>` 目录，以 SuperFastHash 查译文，无译文保留原文 |
| ③ 状态/枚举显示值 | up/down、运行/停止、启用/禁用等代码映射出的显示词 | App 侧本地化映射（目录键）；kit 侧经 `KitL10n`（`KitStringsTable.swift` 英译表） |
| ④ 设备数据本体 | 日志正文、进程名、主机名、IP/MAC、SSID、软件包名、原始配置值、固件串 | **不翻译（豁免）**。这是设备数据本体而非界面文案，翻译会改变含义且无从核对；LuCI 网页与厂商 App 均原样呈现。界面框架文字仍按 ①②③ 本地化 |

kit（OpenWrtKit）固定文案同理：中文源串 + `KitStringsTable.swift` 英译表，经 `KitL10n` 解析。

## 语言协商

- 候选生成须处理 CLDR 细节：脚本默认地区（如 zh-Hans → zh-cn）与同 base 变体回退；协商顺序为系统首选语言对应目录 → 路由器 `luci.main.lang` 配置 → 原文。
- 两台联调实测：translations 端点只在连字符形式出真目录（zh-cn：旁路由 243,215 字节 / 主路由 142,752 字节；zh_cn 仅 13 字节空壳）；旁路由 `luci.main.lang=auto`，主路由为定值 zh_cn。
- 协商降级（拿到空壳目录）不缓存，快照 schema 随语言失效（本地化系统包时升至 3），防把降级结果当正常缓存。

## InfoPlist 文案

系统权限用途说明登记在 `App/InfoPlist.xcstrings`（zh-Hans + en）：本地网络、Face ID。Face ID 的 `NSFaceIDUsageDescription` 曾漏登记，导致认脸在真机从未生效（2026-11-21 包 N 补齐）——新增任何系统权限时，用途说明必须同步进本目录，缺一条即真机静默失效。

## 防回归

`scripts/audit_release.py` 含英文面量扫描与目录完整性校验：新增用户可见文案必须进 String Catalog（zh-Hans + en 齐全、格式符一致），写死英文或漏译会在出包审计被拦。盘点登记册（按文件的条数与分类）见 `briefs/localization-inventory.md`；目录键数随功能增减，以审计解析器复算为准。
