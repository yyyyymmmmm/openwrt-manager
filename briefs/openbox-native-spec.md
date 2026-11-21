# Open-Box 原生深度面规格（包 F 2026-11-21；包 F+ 同日续订）

依据：`dedicated-page-gap-inventory.md`（2026-11-21 双机实测盘点）＋仓内既有
OpenBoxPanel 客户端。原则：只用已实证的通道落码；带面板认证的数据面在返回
结构验证前一律诚实降级，不编造接口。

## 包 F+ 修订（用户 2026-11-21 亲令）

用户令：Open-Box 页让用户输入面板登录密码、登录进去把数据原生显示。
据此修订两条包 F 口径：①面板密码改为**只进钥匙串**保存（按路由器档案
隔离，独立 service），会话 Cookie 同样只进钥匙串，跨启动恢复；②四组降级
数据面按下表实证形状全部点亮。包 F 的「不保存面板密码」口径就此作废。

### API 对位表（证据＝面板自带前端代码，只读 HTTP 拉取实证）

2026-11-21 经路由器本机只读拉取面板前端（/opt/open-box/panel/dist 的
index.html 与 assets 主包 index-DQjuW0vQ.js、页面包 index-C78-NlkQ.js 及
openboxSubscriptions/trafficName 等小分包），逐项读出：

| 端点 | 方法/参数 | 形状证据 |
|---|---|---|
| /api/auth/status | GET | {enabled, authenticated, passwordSet}（前端常量＋既有解析器） |
| /api/auth/login | POST {password}，Cookie 会话（credentials: same-origin） | 前端登录函数原文：失败体 code=ACCESS_PASSWORD_INVALID 即密码错（常量实证）；code=ACCESS_PASSWORD_REQUIRED 即未登录；成功返回 auth 状态 JSON 并置 Cookie |
| /api/openbox/subscriptions | GET | 前端解包 `.subscriptions` 数组（原文 `…)).subscriptions;`） |
| /api/openbox/subscriptions | POST JSON（表单对象） | 前端函数原文 method POST＋JSON.stringify(body) |
| /api/openbox/subscriptions/{id} | PATCH JSON / DELETE | 前端函数原文 |
| /api/openbox/subscriptions/{id}/refresh | POST {} | 前端函数原文；结果 {changed, skipped:[{name, reason, detail}]} 由 openboxSubscriptions 分包原文实证 |
| /api/openbox/subscriptions/order | PUT {ids:[…]} | 前端函数原文（body {ids} 实证；URL 混淆，按盘点参考文档 api.md 对位） |
| /api/openbox/traffic/day?day=&limit=[&hour=] | GET | 前端调用原文；行 {key, up, down, conns} 由 trafficName 分包合并/排序代码实证 |
| /api/openbox/traffic/month?month= | GET | 前端调用原文；行形状同上 |
| /api/openbox/traffic/usage | GET | 盘点参考文档 api.md（前端字面量被混淆未直读，解析器容错多形态） |
| /api/openbox/policies/entries | GET（过滤参数可空） | 前端函数原文 |
| /api/openbox/rulesets/entries?tag=&offset=&limit=[&q=] | GET，tag 必填 | 前端函数原文（无 tag 面板报「不合法的规则集名」） |
| /api/openbox/node-quality | GET | 前端函数原文；字段集随版本变，解析器只认 name/score/latency，其余进原始层 |
| /api/openbox/nodes/latency | POST（触发测速） | 盘点参考文档 api.md（前端字面量未直读） |

订阅条目字段实证到的只有 id、name（前端渲染与刷新逻辑原文）；url、
enabled、节点数、更新时间在解析器里全部容错可选，拿不到就如实缺省。

### 已点亮（包 F+）

- 面板登录区（原生表单）：密码错与面板不可达分开报错；登录成功把密码与
  会话 Cookie 写入钥匙串；下次打开先恢复 Cookie 再探活。
- 退出登录＝清本机 Cookie（钥匙串与共享存储），已保存密码保留供一键
  重登；另有「清除已保存的面板密码」彻底遗忘。更换密码＝退出后用新密码
  登录即覆盖。面板端没有实证到的 logout 端点，不编造。
- 会话失效（401 或体 code=ACCESS_PASSWORD_REQUIRED）：清令牌、回落未登录
  态、明示请重新登录，不重试循环。
- 订阅：列表＋添加＋编辑（名称/链接/启用，编辑器内二次确认）＋删除＋
  单个/全部刷新，全部写动作先过确认面，完成后进操作记录（只记订阅名，
  订阅链接按凭据对待、永不入日志——操作记录会镜像进诊断导出）。
- 流量：今日/本月上下载总量（day/month 端点）＋今日 Top 5 行＋原始层。
- 规则与策略：policies/entries 全量展示；规则集条目按 tag 拉取——面板没有
  规则集索引端点，tag 从策略条目自身字段收割，收割不到时页面明示只展示
  策略条目（此为本包唯一保留的降级项）。
- 节点质量：node-quality 列表（面板给什么显示什么）＋触发测速（POST
  nodes/latency）后回读。

### 安全口径

- 面板密码与会话 Cookie 只进钥匙串（PanelCredentialStore，service 与
  路由器凭据分开，按档案 UUID 隔离）；不进日志/诊断导出/操作记录正文。
- 诊断脱敏：DiagnosticRedactor 的敏感键片段（password/token/cookie/
  session…）覆盖本包全部新键名，kit 有断言测试钉住。
- 订阅链接在操作记录与诊断里一律不出现（链接本身常含令牌）。

## 已落码（包 F）

| 能力 | 通道 | 证据 |
|---|---|---|
| 内核/面板运行态、自启、待重启标记 | 面板 `GET /api/openbox/service/status`（既有解析器） | 既有专用页在用 |
| 内核版本 | 面板 `GET /api/openbox/kernel/version` | 既有专用页在用 |
| 代理组与当前节点 | 面板 `GET /api/controller/proxies`（＋`/api/openbox/groups` 解析器在 kit） | 既有专用页在用 |
| 节点切换 | 面板 `PUT /api/controller/proxies/<group>`，下发后回读组状态核对 | 既有专用页在用（确认弹窗＋回读） |
| 当前连接数 | 面板 `GET /api/controller/connections`（解析器既有，本包接线） | 解析器随 3 期落码；本包接线，真机待验 |
| 面板登录态 | 面板 `GET /api/auth/status` | 盘点实测 200（唯一未认证可达的认证类端点） |
| 内核启停/重启/自启开关 | 既有服务动作通道（init.d `openbox`，快照→执行→回读→验证） | 全 App 统一服务动作事务 |
| 路由器侧 UCI 配置 | UCI `openbox` 配置的结构化只读视图＋L4 编辑器入口 | UCI 通道全 App 在用；配置不存在/未授权时页面按既有口径降级为说明型空状态 |

## 红线对位

- 全原生：面板仅作 HTTP 数据源，无 WebView、无跳转；登录也是原生表单。
- 写操作：节点切换走面板通道＋回读核对；服务启停走 init.d 动作事务；
  UCI 编辑走 L4 唯一写门；订阅写走面板 API＋确认面＋操作记录。各通道
  各自验证，无第五条写路。
