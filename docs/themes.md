# 主题 Themes

> 来源：包 M（主题系统）、包 O（配色审计）、包 P（视觉主色收口）的定版口径，2026-11-21 收编。
> 主题目录的单一事实源是代码：`Packages/OpenWrtKit/Sources/OpenWrtKit/AppTheme.swift`（`AppThemeCatalog`）；与本篇冲突时以代码为准。

## 主题目录

主题 = 一套强调色三件套（accent / accentStrong / accentSoft，各含浅色与深色值），与系统深浅色正交：深浅继续跟随系统（或 App 既有外观设置），主题只管强调色。选择存 UserDefaults（键 `theme.v1`），缺失或未知值回落默认主题。

| 主题 | accent 浅色 | accent 深色 | 说明 |
|---|---|---|---|
| 腾讯蓝（默认） | #0052D9 | #6EA8FF | 与 App 图标主色一致；strong #0043B8/#9CC2FF，soft #E3EEFD/#1D2D47 |
| 青绿 | #087873 | #74C8C0 | 初版（构建 #28 及以前）出厂配色，整套原值保留、测试逐值钉死防漂移；strong #056661/#8BD4CC，soft #E6F4F2/#1C3937 |
| 紫罗兰 | #6D4BD8 | #B79CFF | strong #5736B8/#CDBBFF，soft #EFEAFB/#2A2145 |
| 落日橙 | #C2410C | #FFB37E | strong #9A3412/#FFC79C，soft #FDF0E3/#3A2716 |

入口：设置 → App 设置 → 显示 → 主题（色板圆点 + 名称 + 选中打勾）。未存过选择的用户（含全部老用户升级）首次启动即腾讯蓝，想留旧配色切「青绿」即可。

语义色（成功绿/警告橙/错误红/信息蓝）与中性色**不随主题变**——换主题只换主色系，状态色恒定是大厂通行做法（TDesign/Arco 同口径）。

## 生效机制（包 O 实证，防再踩）

`AppPalette` 的三个 accent token 在颜色解析时经 `AppThemeSelection.current` 读当前主题，全部引用点（300 余处）零改动即跟随。两个曾经的劫持点，已拆并防回归：

1. **资产 AccentColor 曾钉死旧青绿**，且 App 入口内层 `.tint(.accentColor)` 就近压过外层主题 tint——一切吃环境 tint 的原生控件（开关、分段选择器、进度指示）在任何主题下都是青绿。现行：删内层 tint；资产色改为默认主题腾讯蓝对，仅作层级外系统面的静态兜底，活主题以 `AppPreferences` 的 tint 为准。
2. **图表曾吃默认色**：实时曲线与历史曲线现以 `chartForegroundStyleScale` 显式着色——主序列 = 主题 accent，上传序列 = 固定信息蓝 #32699C（与四主题主色均可辨）。

Widget 只用系统语义色、无强调色，不跟随主题。

## 状态色面积口径（包 P 定版，用户亲令）

**语义色只许以小面积出现（圆点、图标、文字），永不作大面积填充、背景与条带。**

- 结论横幅「状态正常」：底色走 accentSoft（跟主题），仅勾图标保留语义绿；警告/危险横幅的橙/红软底保留（罕见且本身即警示）。
- 进度条（MeterBar）：健康区间（excellent/good/fair）填主题 accent；poor 填语义橙、critical 填语义红，未知填中性灰。
- 评级胶囊与状态徽章：中性底，语义只留圆点与文字。
- 「实时」新鲜度胶囊：accentSoft 底 + accent 文字。

机器防回归：`scripts/audit_release.py` 的 `audit_semantic_fills` 断言公用件（SummaryBanner / MeterBar / GradeChip / StatusBadge 所在文件）不得以 greenSoft/blueSoft/grade.soft 等作填充来源；`audit_hardcoded_colors` 扫描硬编码颜色字面量与系统色直用，合法保留处进 `scripts/color_whitelist.txt` 并注明理由——口径全文亦写在该白名单注释中。机器断言覆盖不到的一次性视图大面积填充，靠评审按本篇口径把关，不冒充已机器化。

已知撞色提示：落日橙主题下警告橙与 accent 同为橙族，同屏区分度弱于其他主题（警告文案有 ⚠ 图标前缀辅助）；青绿主题下 accent 青绿与语义绿色相不同（青 vs 绿）、可区分。
