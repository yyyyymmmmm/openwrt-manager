# 权限模型 Permissions

> 来源：目标工作区 `briefs/permission-audit-20261121.md`（权限全盘复查，2026-11-21）与 `briefs/permission-batch3-install-20261121.md`（批次 3 安装报告，同日），2026-11-21 收编。
> 授权文件本体已于收编当日从旁路由实读回读，md5 与安装报告一致。与路由器实况冲突时以路由器上的文件为准。

## rpcd ACL 模型：逐项枚举

OpenWrt 的会话权限由 rpcd 按 `/usr/share/rpcd/acl.d/*.json` **逐项枚举**授予：

| 维度 | 枚举粒度 |
|---|---|
| ubus 对象 | 逐对象、逐方法 |
| file exec | 逐条**完整命令行**（带参数的键以 fnmatch 匹配，如 `/usr/bin/sha256sum *`；只有命令路径的裸键对带参调用同样放行） |
| file 读写 | 逐条**路径** |
| uci | 逐个**配置名** |

登录会话拿到哪些组，由 `/etc/config/rpcd` 的 login 节决定。联调两台的 login 节均为 `list read '*'` + `list write '*'`，即 root 登录会话拿到 acl.d 全部组的授权并集——**但并集仍是枚举的并集**：枚举之外的对象方法、命令行、路径、配置名一律被 ubus 状态码 6（JSON-RPC -32002）拒绝，App 将其映射为 `permissionDenied` 并显示「权限不足」。这不是账号权限不够，重登多少次都不会改变。

两个实测推论，写下来防再踩：

1. **路由器本机 ubus CLI 不能用来验 App 通道**：本机会话走特权内部通道、绕过会话 ACL——在主路由上用本机 ubus 跑无任何授权键的命令返回成功。故一切权限结论必须以真实 HTTP 登录会话（与 App 同路）复验为准。
2. **file stat 不按路径级 stat 权限校验**（批次 3 安装时定性）：任意路径 stat 在装授权前即返回 0，文件详情与写后校验不受路径授权影响；授权文件仍按口径授予 stat，使入口预检与实际一致。

## App 侧口径

- 功能优先走路由器**已授权的正规通道**：如服务动作走 `rc init`、备份创建/下载走 LuCI 官方 cgi-io、固件落盘对齐授权路径 `/tmp/firmware.bin`、刷前校验对齐 `--test` 参数名、空间预检走 `luci getMountPoints`、可更新列表走 package-manager-call 双列表比对、带宽走 `nlbwmon-action`。2026-11-21 权限修复（包 L）共 13 项此类对齐，全部纯 App 侧解决，未动路由器。
- 入口先以 `session access` 预检：未授权的入口置灰并说明原因，不让用户点进去撞墙；错误文案区分「会话过期」与「路由器未授权此功能」，不再混为一谈。
- 只有两类能力在 acl.d 里无任何现成通道，必须路由器侧补授权：**文件管理全功能**（任意路径读写、mkdir/mv/rmdir、sha256sum）与 **keepalived 配置**。经用户 2026-11-21 拍板，补下述授权文件。

## zirox 授权文件

- 路径：`/usr/share/rpcd/acl.d/luci-app-zirox.json`
- 组名：`luci-app-zirox`
- 规格：287 字节，md5 `c81d3c7f2eb5b996b5018145146273af`（双机同一份）
- 持久化：路径已登记进 `/etc/sysupgrade.conf`，固件升级保留；写入后需重启 rpcd 生效（`/etc/init.d/rpcd restart`，只重启 rpcd，不动其他服务）

磁盘上的本体为紧凑单行 JSON，逐字如下（排版展开仅供阅读，校验以 md5 为准）：

```json
{"luci-app-zirox":{"description":"Grant Zirox app full file manager access","read":{"file":{"/*":["read","stat"]},"uci":["keepalived"]},"write":{"file":{"/*":["write"],"/bin/mkdir":["exec"],"/bin/mv":["exec"],"/bin/rmdir":["exec"],"/usr/bin/sha256sum *":["exec"]},"uci":["keepalived"]}}}
```

授权内容拆解：

| 组 | 范围 | 授权 |
|---|---|---|
| read | file `/*` | read、stat |
| read | uci | keepalived |
| write | file `/*` | write |
| write | file `/bin/mkdir`、`/bin/mv`、`/bin/rmdir`、`/usr/bin/sha256sum *` | exec |
| write | uci | keepalived |

影响面（装前已向用户讲明并获批）：登录令牌泄露时可达面随之变大——文件任意路径可读写、keepalived 配置可改。仅建议在自有设备、自用 App 的前提下安装。

## 安装

1. 将上述 JSON 写入 `/usr/share/rpcd/acl.d/luci-app-zirox.json`。注意经多层 shell 引号传输会吞掉 JSON 双引号（安装时实证踩过），应以字节流直灌（如 SSH stdin 直送 `cat > 目标文件`），写后回读 md5 与本篇规格对账，不符不许继续。
2. 把路径 `/usr/share/rpcd/acl.d/luci-app-zirox.json` 追加进 `/etc/sysupgrade.conf`（先查防重复）。
3. `/etc/init.d/rpcd restart`。
4. 以真实 HTTP 会话（登录取令牌后）复验：文件 write/read/remove、exec mkdir/rmdir/sha256sum、读 `/etc/config/system`、uci get keepalived、session access 查询，应全部由状态码 6 变 0 / true。

## 回滚

1. `rm /usr/share/rpcd/acl.d/luci-app-zirox.json`
2. 从 `/etc/sysupgrade.conf` 删去该路径一行
3. `/etc/init.d/rpcd restart`

回滚后文件管理回到装前状态（相关调用恢复状态码 6），其余功能不受影响。

## 双机实测结论（2026-11-21）

- 旁路由（OpenWrt 25.12.5）：装前真实会话下 mkdir/rmdir/sha256sum/读配置全被拒；装后全部放行，session access 三项为 true。
- 主路由（OpenWrt 24.10.8）：同上全过；另 uci keepalived 由 code 6 变 0（授权文件初版漏 uci 段，同日补齐为现行 287 字节版，双机同步）。
- 双机 /tmp 均无测试残留；sysupgrade 登记行各 1 行在位。
