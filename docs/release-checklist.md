# 出包清单 Release Checklist

> 2026-11-21 定版。构建走 Codemagic（GitHub Actions 自 2026-11-20 起被账户账单拦截，不作数）。
> 实验室绿 ≠ 真机绿：本清单最后一节的真机验收不过，版本不算交付。

## 一、出包前（本机可验）

1. kit 测试全绿：
   ```sh
   ~/tools/swift-6.2/usr/bin/swift test --package-path Packages/OpenWrtKit
   ```
2. 发布审计 exit 0（含 scripts 单测）：
   ```sh
   python3 scripts/audit_release.py
   python3 -m unittest discover -s scripts -p 'test_*.py'
   ```
3. 工作树干净、提交已 push 到 `feature/hotfix-discovery-session`（合 main、打 tag 需用户明确批准，不在本清单授权内）。

## 二、Codemagic 构建（工作流 `zirox-ios`）

在 Codemagic 应用（ID `6b006cd7857804e1126a509d`）对目标分支触发构建，步骤须全绿，缺一不可：

- Audit production sources（审计脚本单测 + 源码审计）
- Test OpenWrtKit（与本机同数）
- Run UI tests on simulator（AppFlowUITests，DEBUG-only 种子注入，不连真路由器）
- Build unsigned iPhone app for personal signing
- Audit unsigned release bundle（IPA 内容审计）

产物 `Zirox-openwrt-unsigned.ipa` 下载后覆盖交付位 `~/workspace/Zirox-openwrt-unsigned.ipa` 再发用户。构建红先看第一处错误原文，当轮修复，不带病出包。

## 三、真机验收（用户复验为准）

每版按该版改动点列验收项，以下为恒定项：

- 两台路由器（旁路由 .167 / 主路由 .1）各连通一次，菜单与发现结果与各自实况一致。
- 涉及写操作的版本：只在约定时间内、用户在场时验高风险项（改密全程、备份恢复演练、真刷固件）——助手不单独对真实路由器执行这三类操作。
- 涉及权限的版本：以真实会话结果为准，本机/模拟器结论不作数（见 [permissions.md](permissions.md)）。
- 涉及界面的版本：以用户真机截图对位为准；视频须逐帧量测，不凭一眼印象下结论。
- Face ID 相关：用途说明是安装期声明，必须装新包才生效，旧包在真机上不会认脸（见 [localization.md](localization.md)）。

## 四、TestFlight（骨架就绪，未启用）

工作流 `zirox-testflight` 已备，启用前置（用户侧，清单在 `briefs/testflight-checklist.md`）：App Store Connect API 密钥经 Codemagic 后台集成交接（.p8 绝不经聊天/仓库）、ASC 建好 Bundle ID `app.openwrtmanager.ios` 的 App 记录等。Bundle ID 不改：改 ID 会孤立已装未签名版与其钥匙串凭据。
