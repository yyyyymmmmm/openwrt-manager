# 原生插件协议与交付边界

2026-10-20。新增页面全部为 SwiftUI，调用真实 `/ubus` JSON-RPC；没有 LuCI WebView 或模拟结果。这里只记录已接线的增量和公开协议依据，不表示完成逐层交互、固件兼容或真实写入验收。本轮按用户要求不运行协议与 UI 测试。

## 入口与共用配置

五项 Tab 仍为概览、系统、服务、网络、设置。服务与网络中的扩展按路由器实际菜单分类；未知菜单保留全部返回的层级及未适配说明。插件目录仍列出全部实际返回的软件包，适配器注册只决定哪些插件具有专用表单，不过滤未知扩展。

配置遵循模块→类型→实例→分组→字段→草稿→预览→应用→确认/回滚。UCI 未修改字段保持原值，插件业务操作单独确认。没有将“已保存配置”“进程运行”“控制器授权”“数据包可达”混为一个成功状态。

## HomeProxy

- 专用草稿覆盖部分节点、订阅、分流、路由/DNS规则、DNS服务器、规则集及访问控制。主配置按真实的 `homeproxy` 节类型及命名节区分，避免把多个同类型节重复列在所有分组中。
- `luci.homeproxy.singbox_get_features` 读取版本与构建/内核能力，决定节点、DNS传输及代理模式；TUN 同时要求 `hp_has_tun` 与 `hp_has_ip_full`。失败时保留当前值并禁止编辑相应类型，不猜测固件能力。
- `resources_get_version` / `resources_update` 限定为 `china_ip4`、`china_ip6`、`china_list`、`gfw_list`。更新程序状态 0、2、3 分别显示程序成功、已有任务、已是最新；其他状态明确失败。
- `connection_check` 仅传 `baidu` 或 `google`。结果只表示路由器本次访问该站点，不推断所有客户端或代理可达。
- `file.exec` 固定调用 `/usr/bin/tail -n 200 /var/run/homeproxy/{homeproxy,sing-box-c,sing-box-s}.log`，不接受用户输入路径或命令。
- 更新订阅固定调用 `/etc/homeproxy/scripts/update_subscriptions.uc`。先检查当前会话的 `uci.changes` 为空，拒绝待提交变更；仍不能排除其他会话修改。退出码 0 仅说明程序返回，页面要求重读配置/日志核对各订阅。操作可能修改节点配置及重启服务。

剩余：服务端、证书与导入、全部协议高级字段、全部条件依赖、跨节引用/循环校验、不同版本适配和更新结果验收。字段不齐不宣称完整支持某个协议。

依据：[HomeProxy LuCI 与 RPC 源码](https://github.com/immortalwrt/homeproxy)。当前适配依据 master；用户固件版本仍需独立核对。

## MosDNS

- 专用表单针对 v5 的部分内置配置。自定义 YAML 模式隐藏不会影响 YAML 的内置字段，保留启用、配置文件及 dnsmasq 转发；缓存、预取及统计持久化字段遵循已实现的父级条件。
- `luci.mosdns.get_version`、`print_log`、`get_update_log` 返回真实版本与日志；显示日志的最近 200 行。RPC 后端本身返回完整文件，仍受传输层大小限制。
- `flush_cache` 清空 lazy_cache；`start_update` 只表示固件接受后台更新请求。后台成功与否从更新日志核对，不显示虚构完成百分比。

剩余：规则及自定义文件编辑、Cloudflare 网段文件、统计/查询记录、全部深层选项及运行结果验收。

依据：[MosDNS v5 RPC](https://github.com/sbwml/luci-app-mosdns/blob/v5/luci-app-mosdns/root/usr/share/rpcd/ucode/luci.mosdns)。旧版或其他分支缺少接口时保留真实错误。

## ZeroTier

- 专用 UCI 全局/网络配置，网络 ID 校验为 16 位 ASCII 十六进制并拒绝重复；通过持久配置新增/删除网络，不额外用 CLI join/leave 制造重启即丢失的另一份配置。
- `file.exec` 固定调用 `/usr/bin/zerotier-cli -j info` 与 `-j listnetworks`。保留退出码、标准输出/错误与权限失败。
- 网络列表→详情显示控制器状态、接口、地址、MAC、MTU、接口错误、控制器下发路由和实际接受策略。字段缺失为未返回，不能填成关闭、零或空列表。
- `ONLINE` 不代表虚拟网络授权；`OK` 表示控制器返回配置，不代表连通；控制器路由不代表已进入内核。路由需另到概览的内核路由表核对。

配置页不再提供未经上游启动脚本核对的 network.enabled 开关。网络节由固件的 zerotier init 脚本生成 networks.d 配置；状态页提供该启动项的真实启停、重载和开机启动入口。重载后必须重新读取客户端网络列表，并到概览内核路由核对，不能把服务返回成功当成控制器授权或连通。

剩余：加入/退出后的生命周期与不同自定义配置目录语义、控制器认证流程、真实连通性和不同软件包版本联调。

依据：[OpenWrt 安装路径](https://github.com/openwrt/packages/blob/master/net/zerotier/Makefile)、[ZeroTier 1.16.2 CLI](https://github.com/zerotier/ZeroTierOne/blob/1.16.2/one.cpp)、[运行 JSON](https://github.com/zerotier/ZeroTierOne/blob/1.16.2/service/OneService.cpp)。

## UPnP

- `luci.upnp.get_status` 原生映射列表→详情。真实协议、端口、内网地址、说明、主机及可选租期分别解析；字段异常不静默删除记录。
- 删除确认后检查 `session.access`，重读整张映射表并比对；通过 `uci.get upnpd.config.upnp_lease_file` 和 `file.read` 核对对应租约行的协议、地址、端口及说明。不可读或行序不一致时拒绝调用删除接口。
- `luci.upnp.delete_rule {token}` 返回 `OK` 后重读，只有所选端点不再出现才报告已核对。读取失败、端点仍存在或被客户端重建都不显示成功。
- 上游接口按可变行号删除租约并重启 miniupnpd，未提供原子条件删除。检查与执行之间仍有并发变化风险，确认界面明确提示；服务重启可能影响其他映射。需要 `uci.get`、`file.read` 及插件接口权限，不按 SSH root 推定 HTTP 权限。

剩余：各 miniupnpd 后端、IPv6/PCP/防火墙差异、并发条件及真实删除结果验收。

依据：[UPnP RPC](https://github.com/openwrt/luci/blob/master/applications/luci-app-upnp/root/usr/share/rpcd/ucode/luci.upnp)、[原始设置字段](https://github.com/openwrt/luci/blob/master/applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js)。

## 配置备份归档

- 配置备份下载和上传会校验完整 gzip 流与 tar 结构：头部校验和、成员长度、PAX/GNU 长路径、路径穿越、重复成员和文件/目录冲突；拒绝设备文件、FIFO、稀疏及无法确认的扩展语义。链接目标需要存在且不穿越归档根目录。
- 上传先把用户选择的文件复制到 App 私有暂存，再校验该副本并从同一副本制作 multipart，避免检查与上传之间源文件被替换。路由器随后仍复核暂存文件大小和 SHA-256。
- 这些检查不验证备份来源身份或对另一固件的兼容性；路由器既有目标路径、链接状态及备份恢复命令行为仍需按实际固件核对。未运行本地解析测试。

旁路由的硬件或菜单缺项不删除主路由、无线、WAN、IPv6 或其他插件的目标范围。更多未完成项目继续保留在 [TASKS.md](../TASKS.md)。
