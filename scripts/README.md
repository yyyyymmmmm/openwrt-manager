# scripts/

发布审计与辅助脚本。审计脚本是出包门禁的一部分：Codemagic 构建的第一步即跑脚本单测 + 源码审计，红则不出包（见 `../docs/release-checklist.md`）。

| 文件 | 用途 |
|---|---|
| `audit_release.py` | 发布审计主脚本。模式一（无参数）：扫生产源码——演示/测试标识拦截、英文面量扫描、rawValue 扫描、硬编码颜色扫描（`audit_hardcoded_colors`）、语义填充断言（`audit_semantic_fills`）、String Catalog 完整性。模式二（`--ipa <path>`）：审计未签名 IPA 内容（条目白名单、Bundle ID、隐私声明、Mach-O 架构、禁带测试资源） |
| `test_audit_release.py` | 审计脚本的单元测试（含故意埋雷样本：埋雷必报、白名单放行）。跑法：`python3 -m unittest discover -s scripts -p 'test_*.py'`（须在仓库根目录执行） |
| `english_literal_whitelist.txt` | 英文面量扫描白名单：合法保留的英文（如协议名）逐条注明理由 |
| `rawvalue_whitelist.txt` | rawValue 使用白名单：存储/比较等合法场景逐条注明理由 |
| `color_whitelist.txt` | 颜色扫描白名单兼口径档：大面积填充只许 accent/中性的定版口径全文写在其注释中 |
| `localization_whitelist.txt` | 本地化扫描白名单 |
| `select_simulator.py` | 从 `xcrun simctl list devices available --json` 的输出里选 UI 测试用模拟器（Codemagic 构建调用，stdin 读入、输出模拟器 ID） |
| `ui_test_router.py` | 旧 UI 测试用本地 HTTP 测试服务器（GitHub Actions 时代产物）。现行 UI 测试走 App 的 DEBUG-only 种子注入（见 `codemagic.yaml`），本脚本仅作历史参考 |
| `import_brand_icon.ps1` | 品牌图标导入脚本（PowerShell，Windows 侧把用户定版图标原稿导入 Assets.xcassets 时用） |

新增扫描规则时必须同步补单测样本：埋雷必报、白名单放行，两向都要有用例。
