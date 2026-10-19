# LuCI 与五项原生 Tab 的映射

2026-10-20 更新。原始菜单来自先前对用户设备的浏览器只读核对：OpenWrt 25.12.5 / x86/64 / APK，共 47 个二级菜单。浏览过这些页面及部分深层选项，但未逐一打开所有条目编辑器，更未执行真实写入；不能称为全面交互验收。未记录登录凭据。

## 原始固件树

```text
状态
├─ 概况：系统、内存、存储、端口、上联、连接、速率、租约、DDNS、UPnP
├─ 路由：IPv4 / IPv6 → 邻居、活动路由、活动规则
├─ 防火墙：nftables 表 → 链 → 规则、计数器
├─ 系统日志：系统日志 / 内核日志
├─ 进程：进程 → 暂停 / 终止 / 强制结束
├─ 实时信息：负载 / 带宽 / 连接
├─ WireGuard：接口 → 对端与握手状态
└─ 释放内存
系统
├─ 系统：常规 / 日志 / 时间同步 / 语言界面 / ZRam
├─ 管理权：密码 / SSH / SSH 公钥 / 软件源公钥
├─ 软件包：可用 / 已安装 / 更新 / 上传 / APK 配置
├─ 启动项：启用、启动、重启、重载、停止 / 本地启动脚本
├─ 计划任务
├─ 挂载点：全局 / 已挂载文件系统 / 挂载配置 / 交换分区
├─ 终端：终端 / 配置
├─ 磁盘管理：磁盘 / BTRFS 池
├─ 在线升级
├─ 备份与更新：操作 / 配置
├─ 自定义命令：执行目录 / 配置
├─ 文件管理：目录 → 上传、新建、复制、移动、压缩、删除、重命名、权限
├─ Argon 设置
├─ 定时重启
└─ 重启
服务
├─ HomeProxy
│  ├─ 客户端：路由设置、节点、规则、DNS设置、DNS服务器、DNS规则、规则集
│  │  └─ 访问控制：接口 / LAN IP / WAN IP / 代理域名 / 直连域名
│  ├─ 节点：节点 / 订阅 → 自动更新、时间、代理、URL、过滤、UA、证书、编码
│  ├─ 服务端：全局 / 服务实例
│  └─ 状态：连通性 / 资源更新 / HomeProxy、sing-box 客户端及服务端日志
├─ MosDNS
│  ├─ 基本：基本 / 高级 / Cloudflare / API / GeoData 导出
│  ├─ 规则：白名单、黑名单、灰名单、DDNS、Hosts、重定向、PTR黑名单、流媒体
│  ├─ 更新：广告 / GeoIP / GeoSite → 计划与更新
│  ├─ 统计：统计 / 查询日志
│  └─ 日志
├─ Open-Box：状态 / 启停 / 自启 / 更新；完整管理另有 3036 端口
├─ 动态 DNS：信息 / 全局 → 服务实例 → 基本 / 高级 / 计时器 / 日志
├─ KMS 服务器：基本 / 配置文件
├─ 网络唤醒：默认 / 目标 / 执行结果；此固件页面提示未安装 wakeonlan
├─ 隔空播放：启用 / 接口 / UPnP Sonos / Sonos 流 / Chromecast
├─ Airplay2：名称 / 采样 / 端口 / ALSA / 缓冲 / 会话
├─ 应用过滤：用户列表 / 应用过滤 / 用户 / 时间 / 特征库 / 高级
├─ Frp 客户端：常规 / 自启 / 代理列表 → 实例
├─ NATMap：映射列表 → 实例
├─ Socat：全局 / 转发列表 → 实例
├─ WebDAV：端口 / 用户密码 / 目录 / 只读 / 防火墙 / SSL / 证书密钥
└─ ZeroTier：配置 / 接口
网络
├─ 接口：接口 / 设备 / 全局网络选项
│  ├─ 接口编辑：常规 / 高级 / 防火墙 / DHCP服务器
│  │  └─ DHCP服务器：常规 / IPv4 / IPv6 → DHCPv6 / RA
│  └─ 设备编辑：物理设备 / 网桥端口 / VLAN
├─ 路由：静态IPv4 / 静态IPv6 / IPv4规则 / IPv6规则
├─ DHCP：租约 / dnsmasq / odhcpd
│  ├─ dnsmasq：常规 / 设置及端口 / 日志 / 文件 / 中继 / 标签 / PXE/TFTP
│  │  └─ 标签：匹配标签 / 设置标签 / 厂商类 / 用户类
│  └─ odhcpd：常规 / IPv6 PXE
├─ DNS：常规 / 缓存 / 设置及端口 / DNS记录 / DNSSEC / 过滤器 / 转发 / 限制 / 日志 / 文件 / IP集
│  └─ DNS记录：主机映射 / SRV / MX / CNAME / 资源记录
├─ 网络诊断
├─ 网速测试：iperf3 / speedtest
├─ SQM：基本 / 队列 → 高级、危险选项 / 链路层 → 高级
├─ 防火墙：区域 / 端口转发 / 通信规则 / 源NAT / IP集合 / 自定义
├─ UPnP IGD和PCP：映射 / 常规 / 高级 / ACL
└─ 带宽监控：分布 / 协议 / IPv6 / 导出；配置 / 协议映射 / 备份
```

此设备没有显示无线菜单，也没有安装 iStore。它们不从产品范围中删除；无线读取拒绝访问也不能用来断言无硬件。`wan`/`wan6` 存在但 eth1 缺失，上联实际经 LAN/br-lan 默认路由。

## 目前原生实现树（完整目标尚未完成）

以下只列已经连接真实读取/草稿/请求的入口。固件中未适配的菜单在原分类中显示“暂不支持原生管理”，不可点击；不跳转网页。通用 UCI 编辑另列高级入口，不作为专用适配完成。

```text
概览〔对应状态〕
├─ 上联：netifd 实际默认路由 → 接口、网关、DNS、固件错误
├─ Wi-Fi状态 → 无线电读取 → 无线配置
├─ DHCP租约 → 搜索 → 租约详情
├─ 常用管理：接口 / 防火墙 / 扩展包信息 / 高级配置
├─ 负载 / 内存 / 根文件系统
├─ 状态：内核路由与邻居 → IPv4/IPv6 → 记录详情；日志；进程〔只读〕
├─ 固件扩展〔尚未适配项保留名称与子菜单〕
└─ 本次会话活动
系统〔对应系统〕
├─ 设备与系统信息
├─ 系统 → 系统实例 → 常规 / 日志 → 字段
│        └─ 时间同步实例 → NTP配置 → 字段
├─ 管理权 → SSH → 实例 → 访问设置 → 字段
├─ 软件包 → 搜索 → 已安装包 → 依赖、文件〔只读〕
├─ 启动项 → 搜索 → 实例 → 启动/停止/重启/开机启用/禁用
├─ 挂载记录〔只读〕
├─ 重启 → 确认 → system.reboot → 响应/真实错误 → 重新连接
└─ 固件扩展〔未适配的计划任务、文件、升级等仍保留〕
服务〔仅对应 services 分类〕
├─ 动态DNS → 配置 → 全局 / 服务 → 基本 / 高级 / 计时器 → 字段
│           └─ 系统启动项〔仅在真实目录中发现时〕
├─ 其他固件服务菜单〔原生专有操作尚未适配，不能宣称完成〕
└─ 扩展包信息 → 所有已安装 luci-app 包 → 配置关联/服务关联/依赖文件
网络〔对应网络〕
├─ 接口 → 运行状态；逻辑接口；设备与网桥VLAN
│  ├─ 逻辑接口 → 实例 → 常规 / 高级 / IPv6 / WireGuard（按协议显示）→ 字段
│  ├─ WireGuard对端 → 对端 → 密钥与地址 / 端点 → 字段
│  └─ 设备、网桥VLAN、全局网络选项 → 实例 → 分组 → 字段
├─ 无线〔始终保留〕 → 无线状态 / 配置
│  ├─ 无线电 → 基本设置 → 字段
│  └─ 无线网络 → 常规 / 安全 / 高级 → 字段
├─ 静态与策略路由 → IPv4/IPv6路由或规则 → 实例 → 常规/高级或匹配/动作 → 字段
├─ DHCP → 租约；配置
│  └─ dnsmasq / 接口地址分配 / 静态租约 / odhcpd → 实例 → 分组 → 字段
│      └─ 接口地址分配 → 常规 / IPv4 / IPv6 DHCPv6 / IPv6 RA
├─ DNS → DNS实例 / 主机映射 / SRV / MX / CNAME → 实例 → 分组 → 字段
├─ 防火墙 → 默认 / 区域 / 区域转发 / 端口转发 / 通信规则 / 源NAT / IP集合
│           └─ 实例 → 常规 / 高级或时间限制 → 字段
├─ 网络诊断 → IPv4/IPv6 Ping / IPv4 Traceroute / DNS查询 → 目标 → 输出、退出码、错误
├─ SQM〔固件菜单发现后〕 → 配置 / 系统启动项
│  └─ 队列 → 基本 / 队列 / 链路层 → 字段
├─ UPnP〔固件菜单发现后〕 → 配置 / 系统启动项
│  └─ 服务常规/高级；访问控制规则 → 字段
├─ 其他固件网络菜单〔尚未适配〕
└─ 高级：全部实际配置文件 → 通用UCI编辑
设置〔App自身〕
├─ 当前连接 / 切换路由器 / 断开确认
├─ 字号 / 外观
└─ 帮助 / 隐私 / 关于 → 说明详情
```

专用表单共同的下一层：字段 → 明确设置/交由固件处理 → 文本、密码、列表、选择或数值 → 校验 → 存入草稿；返回模块 → 变更预览 → 应用确认 → 90 秒内验证保留/回滚。单个配置文件为一个事务，网络、DHCP、防火墙分别提交；没有伪装为跨文件原子事务。其他页面的未应用草稿不因一次无关配置确认而静默重置。

## 协议依据与剩余工作

字段依据公开 LuCI 源码核对，未复制网页进入 App。当前源码来源为上游 master，和用户固件可能不同，必须保留原字段及版本差异，不声称已在所有版本写入验证。

- [系统](https://github.com/openwrt/luci/blob/master/modules/luci-mod-system/htdocs/luci-static/resources/view/system/system.js)、[Dropbear](https://github.com/openwrt/luci/blob/master/modules/luci-mod-system/htdocs/luci-static/resources/view/system/dropbear.js)
- [接口](https://github.com/openwrt/luci/blob/master/modules/luci-mod-network/htdocs/luci-static/resources/view/network/interfaces.js)、[无线](https://github.com/openwrt/luci/blob/master/modules/luci-mod-network/htdocs/luci-static/resources/view/network/wireless.js)、[路由](https://github.com/openwrt/luci/blob/master/modules/luci-mod-network/htdocs/luci-static/resources/view/network/routes.js)
- [DHCP](https://github.com/openwrt/luci/blob/master/modules/luci-mod-network/htdocs/luci-static/resources/view/network/dhcp.js)、[DNS](https://github.com/openwrt/luci/blob/master/modules/luci-mod-network/htdocs/luci-static/resources/view/network/dns.js)
- [防火墙](https://github.com/openwrt/luci/tree/master/applications/luci-app-firewall/htdocs/luci-static/resources/view/firewall)、[DDNS](https://github.com/openwrt/luci/blob/master/applications/luci-app-ddns/htdocs/luci-static/resources/view/ddns/overview.js)、[SQM](https://github.com/openwrt/luci/blob/master/applications/luci-app-sqm/htdocs/luci-static/resources/view/network/sqm.js)、[UPnP](https://github.com/openwrt/luci/blob/master/applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js)
- [netifd 协议发现](https://github.com/openwrt/netifd/blob/master/ubus.c)：`network.get_proto_handlers`。ACL 拒绝或旧固件缺少方法时不展示假定可用的协议。

仍待完成且不能勾选：所有核心模块的完整字段与条件依赖校验、交换机与不同无线驱动能力、无线关联站/访客跨配置事务、密码/公钥、时区联动、ZRam、NTP服务生命周期、进程信号、内核日志、nftables与策略规则状态、实时图表、计划任务/挂载/磁盘/文件、软件包写操作、备份/恢复/重置/固件升级；全部插件业务状态和专有任务。DDNS缺注册IP/服务定义/单实例任务/日志；SQM缺运行队列核对/脚本与规则能力/危险参数；UPnP缺动态映射与删除。HomeProxy、MosDNS、ZeroTier等不能用通用字段编辑视为完成。

本轮未在用户路由器执行诊断、配置写入、服务控制或重启。遵照用户要求未运行本轮测试；Release 编译和包审计记录在 TASKS.md，不能替代逐层交互或真实写入验收。
