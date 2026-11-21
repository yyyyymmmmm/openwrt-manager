# TestFlight 开通清单（Zirox-openwrt）

2026-11-21 · 包 A 第 3 件。代码与配置层已就绪，本文只列**还差用户侧完成的步骤**。全部做完后，在 Codemagic 手动触发一次 `zirox-testflight` 工作流即可出第一个 TestFlight 包。

## 代码侧已就绪（无需再动）

- Bundle ID 沿用 `app.openwrtmanager.ios`（UI 测试为 `app.openwrtmanager.ios.uitests`），与工程前缀一致、全仓单一事实源在 `project.yml`。不换 ID：换了会孤立现在已装的未签名版和它钥匙串里的路由器凭据。
- 版本策略：`MARKETING_VERSION`（当前 0.3.0）人工维护；TestFlight 构建号由工作流在构建时自动取「App Store Connect 已有最大构建号 +1」（填了 `APP_STORE_APPLE_ID` 时），否则用 Codemagic 构建号，不回写工程文件，与未签名线互不干扰。
- `codemagic.yaml` 已有 `zirox-testflight` 工作流骨架：审计＋kit 测试→生成工程→`app-store-connect fetch-signing-files --create` 拉/建签名文件→`xcode-project use-profiles`→设构建号→`xcode-project build-ipa`→发布到 TestFlight。写法按 Codemagic 官方原生 iOS 文档核对过。
- 隐私清单 `PrivacyInfo.xcprivacy` 已在包内（声明不追踪）。

## 用户侧步骤（按顺序）

1. **加入 Apple Developer Program**（$99/年）：用你自己的 Apple ID 在 developer.apple.com 完成注册。这是硬前置，没有它没有 TestFlight。
2. **在 App Store Connect 建 App 记录**：appstoreconnect.apple.com → 我的 App → 新建：名称 `Zirox-openwrt`、平台 iOS、Bundle ID 选/建 `app.openwrtmanager.ios`、SKU 任意（如 `zirox-openwrt`）。建完记下该 App 的 **Apple ID（数字）**（App 信息页可见），填进 codemagic.yaml 里 `zirox-testflight` 的 `APP_STORE_APPLE_ID`（也可以之后再填，不填则用 Codemagic 构建号）。
3. **创建 App Store Connect API 密钥**：App Store Connect → 用户和访问 → 集成 → App Store Connect API → 生成密钥，权限选 **App Manager**，命名如 `Codemagic`。生成后**立即下载 .p8 文件（只能下载一次）**，并记下 **Key ID** 与页面上方的 **Issuer ID**。
4. **把密钥交接到 Codemagic（不要经过聊天/仓库）**：Codemagic → Team settings → Team integrations → Developer Portal → Manage keys → Add key：名字逐字填 **`Zirox App Store Connect`**（必须与 codemagic.yaml 里 `integrations.app_store_connect` 的值一致，不一致就改 yaml 那一行），填 Issuer ID、Key ID，上传 .p8，保存。
   - 红线：**.p8 文件内容、Key 原文绝不贴进聊天、绝不进 Git 仓库、绝不写进 codemagic.yaml**。yaml 里只有集成名这一个占位。
5. **出口合规（加密）答复**：App 用了 TLS/SSH（含自实现 SSH 传输加密）。首次上传后 App Store Connect 会问出口合规；内部测试阶段可在 ASC 后台按实际情况答复。若想免去每次答复，需要在 Info.plist 加 `ITSAppUsesNonExemptEncryption` 键——**这个键填 true/false 取决于合规判断，不要让助手替你拍**，届时单独议。
6. **App 隐私问卷**：App Store Connect → App 隐私：按实际填写。本 App 不收集数据上报（凭据只存本机钥匙串、诊断日志只在用户手动导出时离机），大概率是「不收集数据」，但请以你本人名义确认后提交。
7. **加内部测试人员**：TestFlight → 内部测试 → 添加你自己的 Apple ID（内部测试无需 Beta 审核，包处理完即可装）。外部测试才需要建组＋Beta 审核＋隐私政策 URL，暂不需要。
8. **首次触发**：Codemagic 打开本应用 → 用 `zirox-testflight` 工作流、选当前分支手动跑一次。成功后在 TestFlight 里把构建加到内部测试组，手机 TestFlight App 即可安装。

## 常见卡点

- 工作流在 `fetch-signing-files` 失败：多半是集成名对不上或 API 密钥权限不足（需 App Manager 及以上）。
- 提示 Bundle ID 不存在/无权：App 记录还没建，或密钥所属团队不对。
- 构建号冲突：同一版本号下构建号必须递增；工作流的自动 +1 逻辑就是为此设的，前提是 `APP_STORE_APPLE_ID` 已填。
- 证书数量上限：Apple Distribution 证书上限 3 张，`--create` 若报已达上限，去开发者后台删一张废弃的再跑。
