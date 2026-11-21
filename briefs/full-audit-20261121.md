# Zirox-openwrt 全量审计报告（2026-11-21）

## 审计基线与方法

- **审计对象**：分支 `feature/hotfix-discovery-session` 已 push 顶 `b4d528d`（包 C）。审计开始时实测 `git rev-parse HEAD` = b4d528d、工作树干净，故磁盘文件即审计对象。**包 F 在途未提交内容不在本仓工作树内，不在审计范围**；包 F 拟补的专用页缺口按 b4d528d 现状记录。
- **方法**：逐页通读五 Tab 全部视图源码（App/Views 全部 27 文件）＋ kit 展示/数据层关键文件；`scripts/audit_release.py` 复跑通过（catalog 813 键、App 面量 1031、kit 面量 377、kit 英译 674 条）；菜单/服务对账用两台真机夹具（`Packages/OpenWrtKit/Tests/OpenWrtKitTests/Fixtures/snapshot-192.168.31.*-2026-11-20.json`）；**.167 于 2026-11-21 经只读通道活查复核三项**（`which opkg apk`、luci-app-commands 菜单在位、init.d 清单），.1 未活查、用夹具。
- **边界**：本机无 Xcode，未运行 App；一切结论为代码级证据（文件:行），渲染层判断以代码路径为准，不声称真机所见。分级口径：**阻断**＝可致失联/误导决策/核心诉求未达；**重要**＝明显伤体感或口径错误、应排期修；**次要**＝瑕疵与一致性问题。

## 分级计数总览

| 审计轴 | 阻断 | 重要 | 次要 |
|---|---|---|---|
| 一、用户体验 | 0 | 11 | 11 |
| 二、英文残留 | 0 | 4 | 4 |
| 三、功能完整性 | 1 | 6 | 6 |
| **合计** | **1** | **21** | **21** |

## 最要紧的 5 条（按用户体感排序）

1. **核心服务可被无差别停用/关自启，存在把自己锁在路由器外的路径**（三-F1）：.1 的 26 个 init 兜底服务（含 rpcd、ubusd、network、uhttpd、dropbear）全部带启停与自启开关；停 rpcd/ubusd 或关其自启，App 与 LuCI 会同时失联，全程没有任何差别警告。
2. **.1 的 DHCP 页标题是写死英文「DHCP and DNS」**（二-L1）：不在字符串目录内、审计脚本原理上查不到，用户在 .1 每次进这页都撞见——正对此前四轮本地化治理的主诉。
3. **.167 在线升级页恒报「暂无可更新项」是假结论**（三-F2）：该页只跑 opkg，而 .167 只有 apk（今日活查实证），查询失败被吞成空列表，用户会被误导以为系统已最新。
4. **「看不懂」残留两处最扎眼**（一-U5＋U2）：设备页信号只给原始 dBm、无评级（kit 里现成的 signalGrade 没被用，正是产品评审点名的「−65 dBm 是好是坏」）；带宽监控页没有任何人话层，只剩一坨 nlbw 原始 JSON。
5. **测速页是占位页且误报**（三-F3）：执行功能缺席（文案自认「后续版本提供」），且把 netspeedtest 的存在误标成「iPerf3 已检出」——没有的东西报了有，能做的事没做。

---

## 一、用户体验（按包 E 五条标准逐页复查＋通用体验）

先说达标面（避免重复建设）：概览首页、路由、防火墙状态、日志、进程、实时、WireGuard、信道分析、网络首页、接口、DHCP、防火墙配置、服务首页与各服务页、系统首页、软件包、启动项、计划任务、挂载点、通用 UCI 页均已有 SummaryBanner 结论在前；计划任务的人话卡片、接口卡片化、原始数据折叠（诊断/带宽）是标准 4/5 的正确样本；事务确认面、备份恢复、重启/重拨的确认文案与恢复验证为全仓最佳实践。以下为未达标项。

### 重要

- **U1 启动项页：滑动启停无确认、无反馈、错误被吞，页脚文案与实际可写矛盾。** 证据：`App/Views/SystemTab.swift:135-145` 滑动按钮直接 `try? await store.performServiceAction(...)`——无确认对话框、无结果提示、失败静默；同文件 `:151` 页脚仍写「启停与脚本编辑将在写操作阶段提供，本页为只读视图」，与已可写事实矛盾。与服务页动作面（有确认＋结果回显，`GenericViews.swift:180-199`）口径完全不一致。修法：滑动动作改走与 ServiceActionsSection 相同的确认＋结果回显；删过期页脚。
- **U2 带宽监控页没有人话层，只有原始 JSON。** 证据：`App/Views/NetworkTab.swift` BandwidthView（:519-576）——结论横幅只有一句「已读取流量分布报表，原始数据在下方」，正文是 `nlbw -c json` 原文塞进 RawDataSection。包 E 标准 4 是「原始数据降级＋人话层在上」，此页只做了降级、没做人话层；LuCI 同页是按主机/流量的表格。修法：解析 nlbw JSON 出每设备流量表（可复用设备名解析），JSON 留在折叠区。
- **U3 静态路由页名不副实，与接口页配置入口内容重复。** 证据：`App/Views/NetworkTab.swift:215-222` StaticRoutesView 直接嵌未过滤的 `UCIConfigView(configNames: ["network"])`，展示整份 network 配置（接口/设备/交换机全在内），与接口页「网络配置」入口（同文件 InterfacesView）打开的是同一内容、两个标题。修法：按 section 类型（route/route6/rule）过滤渲染，或改名为与内容相符的入口并去重。
- **U4 信道分析名不副实。** 证据：`App/Views/OverviewTab.swift` ChannelAnalysisView（:545-577）只列自家电台的开关/信道/SSID，没有邻频 AP 扫描、信道占用或拥挤度——LuCI 同名页的核心就是扫描图。标题承诺「分析」，页面只有「状态」。修法：补 iwinfo scan 渲染（拥挤度评级可复用 HealthRating），或页面改名为「无线状态」并与无线页合并口径。
- **U5 设备页信号无评级。** 证据：`App/Views/ManagementViews.swift:72-74`（列表行）与 `:181-182`（详情）均为 `"\(signal) dBm"` 原始值；kit `Comprehension.swift` 已有 `HealthRating.signalGrade` 与 GradeChip 组件，设备面未用。修法：两处加 GradeChip（strength 口径）。
- **U6 防火墙状态页看不到规则本体。** 证据：`App/Views/OverviewTab.swift` FirewallStatusView（:305-348）只渲染每链的「N 条计数规则 · M 包」，nft 数据已全量拉回（kit nftables 解析含规则），界面无任何一层能展开看规则——标准 4 的「详情层」在此页缺席，用户判断「这条转发在不在」无从下手。修法：链行可展开规则列表（规则本体属④类数据、原样呈现即可）。
- **U7 「重拨 WAN」在 .167 上的动作与文案双错位。** 证据：`App/Models/RouterStore.swift:488-494` redialWAN 重拨的是 `capability.upstream.interfaceName`；.167 的上游是 br-lan（发现层定版口径），即实际重拨的是局域网侧接口；而确认文案（`App/Views/HistoryViews.swift` QuickActionsSection）写「外网会短暂中断（通常 10–60 秒），局域网不受影响」——对 .167 不成立。修法：按上游性质分文案（真 WAN 口径/局域上游口径），或在无 WAN 的路由器上把该动作改名「重启上游接口」并写明影响。
- **U8 停服务确认不写影响。** 证据：`App/Views/GenericViews.swift:180-199` ServiceActionsSection 的确认只有「确认停止『dnsmasq』？」一句；停 dnsmasq＝全网 DNS 中断、停 network＝全网中断，确认面无一字说明。与重启/恢复备份的确认文案标准（写明中断范围与时长）落差明显。修法：按服务关键度给影响模板（DNS/网络/防火墙/管理面四类，其余通用句）。
- **U9 三处读取失败被静默吞成空状态。** 证据：计划任务 `App/Views/SystemTab.swift:213` `catch { state = .loaded("") }`（权限失败也显示「root 的 crontab 为空」）；WireGuard `App/Views/OverviewTab.swift:540` `catch { state = .loaded(nil) }`（配置读失败无任何提示）；带宽 `App/Views/NetworkTab.swift:562` `catch { state = .loaded(nil) }`（exec 被拒也显示「暂无流量数据，可能尚未积累」）。失败伪装成空会直接误导排障。修法：三处改走 .failed(FriendlyError) 真失败态；确属「文件不存在＝空」的 crontab 单独区分错误码。
- **U10 HomeProxy 三个分组入口打开同一份全量配置。** 证据：`App/Views/ServicesTab.swift:256-267`「客户端/节点/服务器」三行 ForEach 的分组键被绑定到 `_` 丢弃，三者都打开未过滤的 `UCIConfigView(configNames: ["homeproxy"])`，只有标题不同。UCIConfigView 本有 sectionTypeFilter 机制（DNS 页在用）。修法：按分组传 sectionTypeFilter，或撤掉假分组只留一个入口。
- **U11 隐私说明与帮助文案已过期，与现行功能矛盾。** 证据：`App/Views/AppInformationView.swift:38` 隐私说明更新日期仍为 2026 年 10 月 20 日，`:44-45` 只声明会话内存与档案存储，未覆盖现已落地的诊断日志、历史采样、事件记录、设备备注名、本地备份文件等本地数据；`:20` 帮助仍以「插件目录」旧口径描述（与产品定版「软件包≠服务」相悖），`:12` 仍写扫描「检查当前 Wi-Fi 网段的 Web 端口」，与现行「只查常用网关、逐个验证」口径不符。修法：按 A/B/C 三包后的实际数据清单重写隐私条目并更新日期，帮助两处按现口径改。

### 次要

- **U12 发现警告被渲染成「读取失败」错误卡。** `App/Models/RouterStore.swift:173` 成功发现后只要有子项警告，capabilityError 即为警告全文；概览页用 ErrorStateView 呈现（`App/Views/SharedComponents.swift:100-118` 固定标题「读取失败」＋重试按钮）。数据已加载却挂失败卡，语义错位。修法：警告走独立的弱提示样式（无「失败」字样、无重试或重试指向子项）。
- **U13 概览「实时」区无失败形态。** `App/Views/OverviewTab.swift:166-180`：无样本时永远显示「正在采集实时数据…」，轮询持续失败也无提示、无重试入口。
- **U14 概览摘要行不可达详情。** 同文件 `:186-196`：DDNS 只显示「运行中/已检出」、UPnP 写「详情见网络页」但整行不可点，用户需自己去服务/网络页翻找。
- **U15 Open-Box 在服务页出现两个入口。** `App/Views/ServicesTab.swift:30-48` 专区入口与下方服务列表中的 Open-Box 行指向同一页，同屏重复。
- **U16 MosDNS 专用页正文仍是键值平铺。** `App/Views/ServicesTab.swift` MosDNSView（:281-347）：状态区达标，但配置区整页 LabeledContent 罗列、无折叠分层，是五条标准里标准 4 的残留（HomeProxy 页同病较轻）。
- **U17 进程页 CPU 无评级。** `App/Views/OverviewTab.swift:436-441`：仅汇总横幅点名最高占用者，逐行 CPU 为裸百分比；异常进程在长列表里不醒目。可复用 RatedRow/GradeChip（cpuGrade 已有）。
- **U18 固件升级 prepare 后无取消出口。** `App/Views/SystemTab.swift` FirmwareUpgradeSection：备份校验完成后选择器被禁用、无「取消本次升级」按钮，用户改主意只能退出页面（状态随视图销毁，虽无实际危害但无明确交代）。
- **U19 删除路由器档案两处口径不一致。** 设置页滑动删除无确认（`App/Views/SettingsTab.swift:37-45`），连接页长按删除却有完整确认 Alert（`App/Views/ConnectFlowView.swift:64-70`，且写明凭据一并移除）。修法：统一到带确认的一处口径。
- **U20 关闭 App 锁无需认证。** `App/Views/ManagementViews.swift` AppLockToggleRow（:322-335）：开启需认证、关闭直接 `lock.disable()`——拿到已解锁手机的人可无声关掉这层锁。修法：关闭同样走一次认证（系统惯例）。
- **U21 操作记录按当前路由器过滤，换机后「记录消失」。** `App/Views/AlertViews.swift:104-106` entries 只取 activeProfile 的记录；在 B 路由器上看不到 A 的记录且无任何说明，易被误解为记录丢失。修法：加「全部路由器」筛选档或在空/切换时注明口径。
- **U22 配置编辑器仍有工程师口径直出。** `App/Views/TransactionViews.swift:170` 节标题直出 `cfg…` 内部 ID；`:232-282` 未命中 FieldCatalog 的选项以原始 UCI 键名为标签（编辑场景可接受，但与全 App 人话口径相比是洼地，登记备查）。

---

## 二、英文残留（audit 口径之外）

复跑 `scripts/audit_release.py` 通过，但其口径只校验「中文面量是否在册」——**纯英文面量、运行时拼装串、枚举 rawValue 直出、路由器返回的英文 message 都不在其视野内**。以下均为从该盲区漏出的实证。先说已达标面：通知文案全量走 L10n（`App/Infrastructure/Monitoring.swift:173-198` 逐条核对）、SSH/网络错误有 FriendlyError 人话映射（`App/Infrastructure/RouterTransport.swift`）、登录主路径错误走 FriendlyError、值渲染的布尔/列表已映射（kit GenericPageModel.displayText）、日期数字走系统 Locale 格式化。

### 重要

- **L1 「DHCP and DNS」标题写死英文。** 证据：`App/Views/NetworkTab.swift:286` `.navigationTitle(merged ? "DHCP and DNS" : "DHCP")`；在 Localizable.xcstrings 中检索该键为 0 条——它是 Swift 字面量直出，不经 L10n。.1（DHCP/DNS 合并形态）上每次打开该页标题即英文。应走层：①App 文案（目录键，如「DHCP 与 DNS」）。修法：一行改 L10n.key。
- **L2 设备详情「邻居状态」直出英文枚举。** 证据：`App/Views/ManagementViews.swift:188` `LabeledContent("邻居状态", value: state)`，state 是路由器原始值（REACHABLE/STALE/FAILED…）；而路由页对同一数据已有中文映射 `RoutesStatusView.neighborStateLabel`（`App/Views/OverviewTab.swift:288-299`）。同一数据两页两种语言。应走层：③状态映射，复用既有映射函数。
- **L3 发现/刷新警告拼入底层错误原文上屏。** 证据：`Packages/OpenWrtKit/Sources/OpenWrtKit/RouterReader.swift:26-174` 与 `ReadOnlyDataClient.swift:47-57` 多处 `KitL10n.format("硬件信息：%@", error.localizedDescription)`，警告经 `RouterStore.swift:173`（capabilityError）与 `:270`（overviewError）在概览页以错误卡呈现。底层错误为 OpenWrtKitError 时是中文，但解码/传输类错误（如 DecodingError、NIOSSH 原始错误）的 localizedDescription 是英文整句，会原样出现在「硬件信息：The data couldn't be read because…」里。应走层：kit 侧警告只拼语义化错误名（FriendlyError 的 kit 对应物），原文只进诊断日志。
- **L4（机制）audit 需补英文面量扫描。** L1/L2/L6 全部漏自同一盲区：audit 只查中文面量在册，不查英文面量直出、不查 rawValue/枚举上屏点。建议给 audit_release.py 增加：App/kit 源码中纯 ASCII 字符串面量白名单扫描（产品专名/协议名登记豁免）＋ `.rawValue` 出现在 View 层的告警。此项不修，英文残留会持续复发。

### 次要

- **L5 ubus 原始英文 message 可直达用户。** `Packages/OpenWrtKit/Sources/OpenWrtKit/Models.swift:137` `.ubus` 把 rpcd 返回的 message（如 "Access denied"、"Not found"）原样拼进 errorDescription，经 FriendlyError 兜底（`App/Infrastructure/RouterTransport.swift:118` `return error.localizedDescription`）上屏。常见码应做语义映射，未知码保留原文＋代码即可。
- **L6 FriendlyError 兜底仍是裸 localizedDescription。** 同上 `:118`：未覆盖的错误类型（解码失败等）英文原文上脸；另 `App/Models/RouterStore.swift:470` 活动记录 detail 也直用 error.localizedDescription（活动列表用户可见）。频率低，登记为兜底改进项：兜底文案改为「发生未知错误（已记入诊断日志）」类人话＋原文转诊断通道。
- **L7 Open-Box 代理组类型直出英文枚举。** `App/Views/ServicesTab.swift:135` `Text(proxy.type)`：值来自面板 API，为 Selector/URLTest/Fallback/LoadBalance 等英文词，无映射。属③层可映射词汇（或至少标注为产品专名口径并全 App 统一）。
- **L8 诊断导出文件头全英文硬编码。** `Packages/OpenWrtKit/Sources/OpenWrtKit/Diagnostics.swift:198-202` 起：`Zirox-openwrt diagnostics / Generated: / App: / Device: / System: / Router: / Events:` 等字段名为写死英文，不随系统语言。用户本人导出后阅读即英文（本项目用户已实际回传过该文件样本，属实证）。若定位为支持工单格式可保留英文，但应在报告登记此口径；若给用户自查，应跟随语言或双语表头。

---

## 三、功能完整性（路由器支持 vs App 暴露）

先说达标面：数据层降级是全仓最扎实的部分——服务列表（service list 被拒→rc list）、系统日志（log 对象被拒→syslog-wrapper）、实时流量（network.device 被拒→luci-rpc）、nft（JSON 式被拒→文本式）、无线（getWirelessDevices）、发现菜单过滤（routesj/iptables 等非显示端点已被 `CapabilitySnapshot.isDisplayablePath` 正确剔除，`CapabilitySnapshot.swift:423-448`）均有实证兜底；两台菜单/服务与页面的对位在 0 期已逐项闭合。以下为缺口。

### 阻断

- **F1 核心服务无差别可停/可关自启，存在自锁路径。** 证据链：.1 夹具 services 清单 26 项含 `rpcd、ubusd、network、uhttpd、dropbear、dnsmasq、firewall`；这些服务在 App 中走 GenericServiceView，页面带 ServiceActionsSection 全套动作（启动/停止/重启/启用/关闭自启，`App/Views/GenericViews.swift:149-153, 180-199`），启动项页另有无确认的滑动自启开关（U1）。rpcd 是 App 与 LuCI 的共同后端：停 rpcd 或关其自启并重启后，手机与电脑同时失去管理通道，只能物理接触路由器恢复；停 network/ubusd 同理。LuCI 启动项页虽同样允许，但本 App 的用户画像与「手机是唯一管理端」的场景使后果放大，且确认文案对核心服务与普通服务毫无区别。修法：立核心服务保护名单（rpcd/ubusd/network/uhttpd/dropbear/dnsmasq/firewall）：停止/关闭自启需专属强警告（写明失联后果）或直接禁用停止动作只留重启；名单外服务维持现行确认。

### 重要

- **F2 在线升级页在 apk 路由器上恒报无更新（假结论）。** 证据：`App/Views/SystemTab.swift:327-332` 只执行 `/bin/opkg list-upgradable`，catch 后按注释「treat as no data」落到空列表并显示「暂无可更新项」。.167 于 2026-11-21 活查：`which` 只有 `/usr/bin/apk`、无 opkg——该页在 .167 上永远查不到、永远报无更新。修法：按包管理器分支（apk 用 `apk list --upgradable` 等价命令），查询不可用时显示「本机无法检查更新」而非空结论。
- **F3 测速页：功能缺席＋检出误报。** 证据：`App/Views/NetworkTab.swift` SpeedTestView（:377-411）：正文自认「测速执行将在后续版本提供」；其「iPerf3 服务检出」判定为 `serviceList 含 iperf || netspeedtest 菜单存在`——.167 活查 init.d 有 netspeedtest 服务、与 iPerf3 无关，页面却会显示「iPerf3 已检出」。LuCI netspeedtest 是可执行的测速页。修法：二选一——接 netspeedtest 的执行通道做成可用页；或撤下 iPerf3 误报口径、页面改名并明示仅检出测速组件。
- **F4 无路由器管理员密码修改入口。** 证据：全仓 grep `passwd/修改密码` 仅命中诊断脱敏词表（kit Diagnostics.swift:60），无任何改密通道；注册表把 `admin/system/admin` 映射为 dropbear＋uhttpd 的 UCI 配置页（`PageRegistry.swift` systemPages），LuCI 该页的核心动作——改 root 密码、管理 SSH 授权密钥——在 App 内无处可做。对「手机是唯一管理端」的定位这是真实缺口。修法：新增管理安全页（改密走 rpcd/ubus 正规通道＋强确认，SSH 密钥列表增删）。
- **F5 UPnP 页只有配置、没有活动映射。** 证据：`App/Views/NetworkTab.swift:514-518` UPnPView 仅是 UCIConfigView(upnpd 配置）；LuCI UPnP 页的核心信息是当前活动端口映射表（miniupnpd 租约），App 无该读取通道，概览摘要也只报「已检出」。修法：读 miniupnpd 租约（iptables/nft 租约文件或 ubus）出活动映射表，配置降为次层。
- **F6 .167「自定义命令」是死胡同页。** 证据：luci-app-commands 在 .167 菜单在位（2026-11-21 活查 menu.d 文件存在）；`CapabilitySnapshot.swift:430-438` 只屏蔽其 run/download 子路径，本体 `admin/system/commands` 可达；注册表 systemPages 无此 case，落 default → GenericMenuPageView（`App/Views/GenericViews.swift:225-252`），页面只有名称＋菜单路径，无任何内容与动作。LuCI 该页可执行用户预置命令。修法：要么做命令列表＋执行面（走事务确认），要么在发现层把该节点归入不生成页面的名单并在服务/系统页不露出入口——不能留假入口。
- **F7 软件包页纯只读，包管理动作全缺。** 证据：`App/Views/SystemTab.swift` PackagesView（:76-117）只有搜索＋列表；LuCI 包管理可安装/卸载/更新，App 无一动作；升级页的可更新列表也只是文本行、无逐包更新入口。修法：至少补「更新全部可更新包」与逐包更新（走 exec 通道＋进度与回读），安装/卸载可后置但应在页面明示口径。

### 次要

- **F8 文件管理缺下载/分享/上传/新建。** `App/Views/FileManagerView.swift` 全文：仅浏览、文本编辑、删文件；无下载到本机/系统分享、无上传、无新建文件/文件夹、目录不可删。产品评审 P2-13 在 b4d528d 仍未关（包 D 已排期，登记现状）。
- **F9 终端仍为固定 80×24。** `App/Views/TerminalView.swift` parser 与 openShell 均写死 80×24、无 resize 通道接入视图尺寸；kit TerminalCore 网格为单字符单元、无 CJK 宽字符（wcwidth）处理，渲染只取字符、丢 ANSI 属性。产品评审 P2-12 仍未关（包 D 已排期，登记现状）。
- **F10 通用编辑器不能新增选项。** `App/Views/TransactionViews.swift` ConfigEditorView：可改/删既有键、增删配置节，但节内无「新增选项」入口，LuCI 表单可加的选项在 App 里加不了。
- **F11 DiskMan 被降级为只读挂载页。** `PageRegistry.swift` systemPages 把 `admin/system/diskman` 映射到 mounts 只读页；LuCI DiskMan 的分区/格式化/挂载管理动作缺席（高危动作可不做，但映射后标题与能力错位应注明）。
- **F12 交换机页是整份 network 配置。** `PageRegistry.swift` networkPages 把 `admin/network/switch` 映射为 UCIConfigView(["network"])，无 LuCI 的 VLAN/端口矩阵渲染；信息在但形态原始（与 U3 同源）。
- **F13 RouterRecordsView 为无入口遗留视图。** `App/Views/RouterRecordsView.swift` 全仓无导航引用（grep 实证），其 records 通道已被 MountsView 直用。此为死代码而非用户缺口，登记以便清理时勿误判为功能缺失。

---

## 建议修复包与顺序

1. **修复包 G（安全与假结论）——先行，量小、风险最高**：F1 核心服务保护名单＋U8 影响文案＋U1 启动项确认/反馈/删过期页脚；F2 apk 更新检查分支；F3 测速页去误报（二选一先止血）；U9 三处静默失败改真失败态；U7 重拨文案按上游分口径。
2. **修复包 H（英文清零第二波＋防回归）**：L1 标题入目录、L2 复用邻居状态映射、L7 代理类型映射、L3/L5 错误分级（原文只进诊断）、L8 给 audit 加英文面量与 rawValue 上屏扫描、L8' 诊断导出表头口径定版。
3. **修复包 I（可懂度补遗）**：U2 带宽人话表、U5 信号评级、U6 防火墙规则详情层、U3 静态路由过滤、U4 信道分析补扫描或改名、U10 HomeProxy 分组过滤、U16/U17 评级补齐、U12–U15/U18–U22 零碎一致性。
4. **修复包 J（功能补缺）**：F4 管理员改密页、F5 UPnP 活动映射、F7 包管理动作、F6 自定义命令去留定版、F10 编辑器新增选项。
5. F8/F9 由已排期的包 D 承接，不另立包；F11/F12/F13 随手清理，不单独排期。

## 审计声明

本报告全部结论均有代码或夹具/活查证据，未运行 App、未修改任何代码与路由器状态（.167 活查仅只读命令）。包 F 不在审计范围：其拟补的 Open-Box 深度面与 ddns/appfilter 等专用页缺口按 b4d528d 现状仍属缺口（GenericServiceView 覆盖中），待包 F 交卷后应复审本节相关条目。
