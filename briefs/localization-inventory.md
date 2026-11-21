# 本地化全量盘点（本地化系统包，2026-11-21）

用户拍板口径：全部页面（含所有子页面/详情页）的用户可见文字跟随 iOS 系统语言，系统性做法、不逐页补丁。本盘点是这套系统的登记册：每个用户可见字符串属于哪一类、由哪个机制治理。逐条登记的载体是代码本身——①类在 `App/Localizable.xcstrings`（534 键，zh-Hans 源＋en），kit 固定文案在 `Packages/OpenWrtKit/Sources/OpenWrtKit/KitStringsTable.swift`（197 条英译）；本文件登记分类口径、按文件的条数与各类处理方式，数字由 `scripts/audit_release.py` 的解析器复算（审计不过不许交卷，见文末口径）。

## 四类与处理方式

| 类别 | 定义 | 治理机制 |
|---|---|---|
| ① App 自有 UI 文案 | 按钮/标题/空状态/错误/提示/状态消息，App 自己生产的文字 | String Catalog（`Localizable.xcstrings`）：SwiftUI 字面量调用点由系统自动按目录解析；String 型生产点（store/错误/活动记录）经 `L10n`（`App/Infrastructure/AppLocalization.swift`）解析同一目录；日期/数字/单位走 Locale 格式化（ByteCountFormatter、Date.FormatStyle、%lld/%@ 格式键）。语言来源＝系统（Bundle 跟随系统语言＋系统设置里的 App 单独语言），App 内不设语言开关 |
| ② 路由器源显示串 | 菜单标题、LuCI 字段标签、通用页 section/字段名、服务页标题等源自 LuCI 的显示串 | 统一走一个翻译入口 `LuciLocalization`（发现期协商语言→拉取路由器自家 translations 目录→SuperFastHash 查译，无译文保留原文，与 LuCI 网页同一机制）：协商顺序＝系统首选语言对应目录优先→路由器 luci 配置语言→原文；FieldCatalog 字段标签是 kit 固定文案（归①的 kit 侧，经 KitL10n），通用页无 FieldCatalog 命中的键名再过 LuCI 目录 |
| ③ 状态/枚举显示值 | 代码映射出的显示词：up/down、运行/停止、启用/禁用、是/否、协议与接口状态词等 | App 侧本地化映射：生产点直接用目录键（L10n.string 或字面量），如 已连接/未连接、运行中/已停止、已启用/未启用、未知、启用、是/否、已检出/未检出；kit 侧同理经 KitL10n（GenericPageModel 的 是/否、ServiceAction 五动作名等） |
| ④ 设备数据本体 | 日志正文、进程名/命令行、主机名、IP/MAC、SSID、软件包名、原始配置值、设备型号/固件串、UCI 选项值 | **不翻译（豁免）**。理由（大厂惯例）：这是设备数据的本体而非界面文案，翻译会改变其含义且无从核对；LuCI 网页与各厂商 App 均原样呈现。界面框架文字（标签/状态词）仍按①②③本地化。少数产品专名（WireGuard、MosDNS、Open-Box、DHCP、DNS 等）在 LuCI 官方中文目录里本身也不译，与网页呈现一致，不算缺口 |

## 条数统计（2026-11-21 实测，审计解析器复算）

### ① App 层（按文件，中文字符面量出现次数 / 唯一数）

| 文件 | 出现 | 唯一 |
|---|---:|---:|
| App/Views/SystemTab.swift | 89 | 83 |
| App/Views/NetworkTab.swift | 87 | 76 |
| App/Views/OverviewTab.swift | 83 | 73 |
| App/Views/ServicesTab.swift | 73 | 47 |
| App/Views/GenericViews.swift | 36 | 35 |
| App/Views/AppInformationView.swift | 35 | 33 |
| App/Models/RouterStore.swift | 34 | 33 |
| App/Views/TransactionViews.swift | 32 | 31 |
| App/Views/SharedComponents.swift | 30 | 25 |
| App/Views/RouterLoginView.swift | 30 | 24 |
| App/Views/RouterScanView.swift | 21 | 21 |
| App/Views/ConnectFlowView.swift | 22 | 20 |
| App/Views/FileManagerView.swift | 20 | 17 |
| App/Views/AppSettingsView.swift | 19 | 12 |
| App/Views/DesignSystem.swift | 16 | 16 |
| App/Views/TerminalView.swift | 11 | 11 |
| App/Views/SettingsTab.swift | 10 | 10 |
| App/Infrastructure/RouterTransport.swift（FriendlyError） | 7 | 7 |
| App/Infrastructure/RouterDiscoveryService.swift | 5 | 5 |
| App/Views/ActivityListView.swift | 5 | 5 |
| App/Views/RootView.swift | 5 | 5 |
| App/Views/RouterRecordsView.swift | 5 | 5 |
| App/Models/AppPreferences.swift | 4 | 4 |
| App/Views/PageDestination.swift | 3 | 2 |
| App/Infrastructure/CredentialStore.swift | 2 | 2 |
| App/Models/RouterProfile.swift | 2 | 2 |
| **合计** | **686** | — |

唯一键合计 **534**（含格式键与 3 个插值内层键），全部登记在 `App/Localizable.xcstrings`，zh-Hans＋en 双语齐全、格式符一致（审计校验）。InfoPlist 的 `NSLocalNetworkUsageDescription` 单独登记在 `App/InfoPlist.xcstrings`（zh＋en）。

### kit 层（OpenWrtKit 展示层）

| 文件 | 出现 | 处理 |
|---|---:|---|
| FieldCatalog.swift | 144（146 个字段条目、127 个唯一标签） | 字段标签数据表，descriptor() 出口经 KitL10n 解析 |
| KitStringsTable.swift | 195 | 英译表本体（197 条，含后补 MosDNS/DHCP 长尾） |
| RouterReader.swift | 20 | 发现警告文案经 KitL10n.format |
| RouterConfiguration.swift | 17 | 事务摘要/错误经 KitL10n |
| PageRegistry.swift | 10 | 五 Tab 与固定页标题经 KitL10n.text |
| Models.swift | 6 | OpenWrtKitError 描述经 KitL10n |
| ReadOnlyDataClient.swift | 5 | 警告经 KitL10n.format |
| UbusClient.swift | 5 | 传输错误经 KitL10n |
| UpgradeFlow.swift | 5 | 升级流程文案经 KitL10n |
| GenericPageModel.swift | 4 | 是/否 与列表分隔符经 KitL10n |
| TransactionSupport.swift | 3 | 事务错误经 KitL10n |
| RouterDiscovery.swift | 1 | 匿名菜单警告经 KitL10n |
| UbusCalling.swift | 1 | 固定会话错误经 KitL10n |

kit 无 Bundle：App 启动时把系统选定的语言喂给 `KitL10n.appLanguage`（`L10n.syncKitLanguage()`），英文环境查英译表、其余回源中文——与 App 层同一语言。

### ② 路由器源串（实测量级）

- 菜单标题：发现期全量过 LuciLocalization。.167 目录 4793 条、.1 目录 2782 条（2026-11-21 活测拉取，存为测试夹具 `Fixtures/translations-*.txt`）。
- 通用页字段名：FieldCatalog 146 条目优先，无命中再过 LuCI 目录（键名命中率低——目录按显示串而非 UCI 键名索引，此为机制边界，见活测节）。
- 服务页标题：与菜单标题同一入口（PageRegistry 用发现后的标题组装）。

### ③ 状态/枚举映射（主要登记）

已连接/未连接、运行中/已停止、已启用/未启用、启用、未知、是/否、已检出/未检出、已检出（详情见网络页）、运行状态词（Live/Stale 的 实时/离线缓存/暂无数据/已过期 · %@）、时长与年龄（%lld 分/小时/天、%lld 秒前/分钟前/小时前，走格式键）、服务动作（启动/停止/重启/启用开机启动/关闭开机启动，kit ServiceAction）、布尔显示（是/否，kit GenericPageModel）。

### ④ 豁免登记（不翻译，理由同上表）

日志正文（系统日志/内核日志条目）、进程名与命令行、主机名、IP/MAC 地址、SSID 与无线参数值、软件包名与版本串、原始 UCI 配置值、设备型号/固件版本串、文件路径与文件名、终端会话内容、nftables 规则本体、邻居/租约的设备侧标识。

## 缓存与语言（治本项登记）

- `CollectedRouterSnapshot` 自本包起带 `schema_version`（当前 2）与 `language`（发现时协商到的目录语言标签，如 zh-cn；无目录为 source）。旧格式（无此二键）解码为版本 1。
- App 缓存门（RouterStore.cachedCapability）：版本≠当前或语言≠当前应使用语言（由系统语言预测，`SnapshotLanguage.expectedTag`）的快照不予呈现，改为重新发现；refresh 内含同一语言门（以「上次发现时的预测值」为基线防无目录路由器反复重发现）；系统语言变化通知（RootView）触发带语言门的 refresh。
- 效果：构建 #6 的英文快照在新版首次启动即作废，不再需要用户手动刷新才见中文。

## 防回归审计口径（scripts/audit_release.py · audit_localization）

- App：任一含中文字符（含全角标点）的字面量，归一化（插值→格式符）后必须是 Localizable.xcstrings 的键，否则失败；目录每键必须 zh-Hans＋en 齐全且格式符与键一致。
- kit：任一中文字符面量必须在 KitL10n 英译表中，且（FieldCatalog 数据表外）必须出现在 KitL10n 调用点，否则失败。
- 白名单：`scripts/localization_whitelist.txt`（当前为空——无豁免项；新增豁免必须在此登记并注明理由）。
- 已知边界：审计校验「字面量在册」，生产/渲染点是否经 L10n/KitL10n/共享组件解析由本包接线保证并在交卷报告中逐项登记；后续改动若新增 String 型生产点，须按同一接线规则处理（L10n/KitL10n），审计保证其键必然在册。

## 活测摘要（2026-11-21，详见交卷报告）

- 菜单四组标题中文覆盖（App 可见二级标题，kit 管线实测）：.167 为 38/49、.1 为 22/24；未译项全部为产品专名或路由器目录本身缺口（Software、DHCP and DNS），与 LuCI 网页中文呈现一致。
- 子页面（页面模型层）：接口（两台各 4–5 个接口，状态词走③映射）、DHCP 字段标签 .167 41/41、.1 37/37（FieldCatalog 补齐后 100%）、防火墙状态（.167 3 表/44 链/171 规则、.1 1 表/28 链/49 规则，数据层）、服务详情（MosDNS .167 34/34、Dropbear .1 4/4，补齐后 100%）、软件包（.167 apk 599 个、.1 opkg 192 个，名称属④豁免、框架文案属①）。
- 渲染层最终验收以用户真机为准（本盘点与活测只到发现数据＋页面模型层）。
