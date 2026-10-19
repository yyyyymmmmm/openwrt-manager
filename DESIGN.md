# iOS 设计约定

## Direction

用户指定 iOS 26 原生工具界面。采用 SwiftUI 系统 NavigationStack、TabView、Form、List、Sheet。Operate 模式：让用户首先完成连接和登录；视觉表达服从可读性与系统习惯。

## Tokens

- 字体：系统语义字体 largeTitle/title2/headline/body/subheadline/caption，支持 Dynamic Type。
- 颜色：primary/secondary、systemGroupedBackground、secondarySystemGroupedBackground；交互 tint 为系统 teal，状态使用系统语义色并配文字。
- 间距：8、12、16、24、32 pt；控件触摸区域至少 44×44 pt。
- 圆角：内容分组使用系统 insetGrouped，独立内容容器 16 pt；不嵌套装饰卡片。
- 材质：系统导航、Tab Bar 与 Sheet 自动采用运行系统材质；不自绘玻璃导航。
- 动效：系统 push/sheet；尊重 Reduce Motion。不以动画隐藏必要内容。
- 目标：iPhone 竖屏/横屏。iPad 专门布局暂不在本轮声明。

## First viewport contract

首次进入看到“连接你的路由器”、手动输入、扫描局域网和明确标识的演示模式。无账户注册、无云端登录。连接后第一屏说明当前路由器、数据时间与连接状态。

## Flows and states

- 添加路由器是独立 Sheet，提供取消，输入保留到成功或主动放弃。
- 扫描：空闲、权限说明、进行中/进度、可停止、结果、不支持接口、未找到及手动输入出口。
- 登录：连接中、用户名/密码错误、HTTP 明文确认、证书错误、缺少 ubus、成功。
- 读取：首次加载、空结果、部分权限不足、读取失败、保留上次成功数据及更新时间。
- 删除本机保存记录使用系统确认；不等于修改路由器。
- 演示模式持久显示“演示数据”，不会发网络请求或保存凭据。

## Verification boundary

当前 Windows 环境无法运行 iOS Simulator。本轮可以交付源代码、协议测试、CI 与 UI 截图测试，但没有本机原生截图，不以网页截图替代 iOS 截图。GitHub Actions 应产出 .xcresult 和演示页截图以便后续检查。
