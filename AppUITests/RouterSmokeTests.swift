import XCTest

// All fixture data comes through ordinary HTTP requests to a CI-only server.
// The production target has no test mode, injected data or launch switches.
final class RouterSmokeTests: XCTestCase {
    @MainActor
    func testAOnboardingPrivacyAndScan() {
        let app = launch()
        XCTAssertFalse(app.buttons["demoModeButton"].exists)
        attach("00-welcome", app)
        openAddress(app)
        attach("01-connect", app)
        app.buttons["scanLocalNetworkLink"].tap()
        XCTAssertTrue(app.buttons["startScanButton"].waitForExistence(timeout: 5))
        attach("09-scan-entry", app)
        back(app)
        app.buttons["appSettingsLink"].tap()
        tapVisible(app.buttons["privacyLink"], app)
        XCTAssertTrue(app.staticTexts["连接与本地存储"].waitForExistence(timeout: 5))
        attach("13-privacy", app)
    }

    @MainActor
    func testBRealLoginPathAndNativeTabs() {
        let app = launch()
        connect(app, captureLogin: true)
        attach("02-overview", app)
        openLeases(app)
        let device = app.buttons["device-02:00:00:00:00:01|192.0.2.10"]
        XCTAssertTrue(device.waitForExistence(timeout: 15))
        attach("03-devices", app)
        device.tap()
        XCTAssertTrue(app.staticTexts["设备名称"].waitForExistence(timeout: 5))
        attach("11-device-detail", app)
        back(app)
        let search = app.textFields["deviceSearchField"]
        search.tap(); search.typeText("no-match")
        XCTAssertFalse(device.exists)
        attach("12-device-search", app)
        back(app)
        visit("网络", app)
        attach("04-network", app)
        openExtensions(app)
        XCTAssertTrue(app.buttons["plugin-luci-app-ci-extension"].waitForExistence(timeout: 15))
        attach("05-plugins", app)
        visit("系统", app)
        attach("06-system", app)
        visit("概览", app)
        tapVisible(app.buttons["系统日志"], app)
        tapVisible(app.buttons["router-system-log"], app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CI fixture log")).firstMatch.waitForExistence(timeout: 5))
        attach("20-records", app)
        back(app); back(app)
        visit("设置", app)
        XCTAssertTrue(app.buttons["settings-router-picker"].exists)
        attach("27-settings", app)
    }

    @MainActor
    func testCConfigurationApplyConfirmAndServiceControl() {
        let app = launch()
        connect(app)
        openExtensions(app)
        let plugin = app.buttons["plugin-luci-app-ci-extension"]
        XCTAssertTrue(plugin.waitForExistence(timeout: 15)); plugin.tap()
        attach("21-plugin-detail", app)
        app.buttons["plugin-config-ci_extension"].tap()
        let section = app.buttons["config-section-main"]
        XCTAssertTrue(section.waitForExistence(timeout: 10)); section.tap()
        app.buttons["config-field-enabled"].tap()
        let input = app.textFields["configValueInput"].exists ? app.textFields["configValueInput"] : app.textViews["configValueInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); replace(input, with: "0")
        app.buttons["完成"].tap()
        back(app)
        app.buttons["previewConfigChanges"].tap()
        XCTAssertTrue(app.buttons["applyConfigurationButton"].waitForExistence(timeout: 5))
        attach("22-config-preview", app)
        app.buttons["applyConfigurationButton"].tap()
        app.buttons["应用修改"].tap()
        let confirm = app.buttons["验证连接并保留修改"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        attach("23-config-confirm", app)
        confirm.tap()
        XCTAssertTrue(section.waitForExistence(timeout: 15))
        back(app)
        tapVisible(app.buttons["plugin-service-ci_extension"], app)
        XCTAssertTrue(app.buttons["停止"].waitForExistence(timeout: 5))
        app.buttons["停止"].tap(); app.buttons["确认停止"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "路由器已确认执行停止")).firstMatch.waitForExistence(timeout: 15))
        attach("24-service-result", app)
    }

    @MainActor
    func testDReadOnlyAccountCannotEdit() {
        let app = launch()
        connect(app, username: "readonly")
        openExtensions(app)
        let plugin = app.buttons["plugin-luci-app-ci-extension"]
        XCTAssertTrue(plugin.waitForExistence(timeout: 15)); plugin.tap()
        app.buttons["plugin-config-ci_extension"].tap()
        let section = app.buttons["config-section-main"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["当前账户仅可读取"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["previewConfigChanges"].isEnabled)
        section.tap()
        XCTAssertFalse(app.buttons["config-field-enabled"].isEnabled)
        attach("25-readonly-config", app)
        back(app); back(app)
        tapVisible(app.buttons["plugin-service-ci_extension"], app)
        app.buttons["停止"].tap(); app.buttons["确认停止"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "权限不足")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "路由器已确认执行")).firstMatch.exists)
        attach("28-readonly-service", app)
    }

    @MainActor
    func testEAppearanceAndTextSizePersistThroughSettings() {
        let app = launch()
        app.buttons["appSettingsLink"].tap()
        app.buttons["textSizePicker"].tap(); app.buttons["加大"].tap()
        XCTAssertEqual(app.buttons["textSizePicker"].value as? String, "加大")
        attach("10-text-size-large", app)
        app.terminate(); app.launch()
        app.buttons["appSettingsLink"].tap()
        XCTAssertEqual(app.buttons["textSizePicker"].value as? String, "加大")
        attach("16-text-size-restored", app)
        app.buttons["textSizePicker"].tap(); app.buttons["紧凑"].tap()
        app.buttons["appearancePicker"].tap(); app.buttons["深色"].tap()
        back(app)
        connect(app)
        attach("08-dark-overview", app)
        openLeases(app); attach("14-dark-devices", app)
        back(app)
        openExtensions(app)
        XCTAssertTrue(app.buttons["plugin-luci-app-ci-extension"].waitForExistence(timeout: 15))
        attach("15-dark-plugins", app)
    }

    @MainActor
    func testFRejectedCredentialsNeverOpenDashboard() {
        let app = launch()
        enterCredentials(app, password: "wrong")
        submit(app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "登录失败")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["概览"].exists)
        attach("26-login-error", app)
    }

    @MainActor
    func testGRoutingFamiliesNeighborsRoutesAndSearch() {
        let app = launch(); connect(app)
        visit("概览", app)
        tapVisible(app.buttons["network-routing"], app)
        let v4Neighbor = app.buttons["neighbor-IPv4-192.0.2.10|br-lan"]
        XCTAssertTrue(v4Neighbor.waitForExistence(timeout: 15))
        v4Neighbor.tap()
        expectText("REACHABLE", app); expectText("lan", app)
        attach("30-neighbor-ipv4", app); back(app)
        tapVisible(app.buttons["route-IPv4-default via 192.0.2.254 dev br-lan proto static metric 10"], app)
        expectText("目标网络", app); expectText("192.0.2.254", app)
        attach("31-route-ipv4", app); back(app)
        app.segmentedControls["routingFamilyPicker"].buttons["IPv6"].tap()
        tapVisible(app.buttons["neighbor-IPv6-fd00::10|br-lan"], app)
        expectText("STALE", app); expectText("fd00::10", app)
        attach("32-neighbor-ipv6", app); back(app)
        tapVisible(app.buttons["route-IPv6-fd00::/64 dev br-lan proto kernel metric 256"], app)
        expectText("fd00::/64", app); expectText("kernel", app)
        attach("33-route-ipv6", app); back(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        replace(search, with: "no-match")
        expectText("没有匹配邻居", app)
        XCTAssertFalse(app.buttons["neighbor-IPv6-fd00::10|br-lan"].exists)
        replace(search, with: "02:00:00:00:00:01")
        XCTAssertTrue(app.buttons["neighbor-IPv6-fd00::10|br-lan"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHRouteACLFailureIsNotAnEmptySuccessfulTable() {
        checkRoutingFailure(username: "route-denied", message: "权限不足", screenshot: "34-route-acl")
    }

    @MainActor
    func testIRouteCommandFailureIsNotAnEmptySuccessfulTable() {
        checkRoutingFailure(username: "route-failure", message: "ip: CI command unavailable", screenshot: "35-route-command-error")
    }

    @MainActor
    func testJNativeNetworkFormsReachNestedFieldsAndDraftPreview() {
        let app = launch(); connect(app); visit("网络", app)
        tapVisible(app.buttons["network-interfaces"], app)
        tapVisible(app.buttons["native-config-interfaces"], app)
        inspectNative(section: "interfaces-lan", type: "interface", groups: [
            ("常规设置", ["proto", "device", "ipaddr", "netmask", "gateway"]),
            ("高级设置", ["metric", "dns", "mtu"]), ("IPv6", ["ip6addr", "ip6gw", "ip6assign"])
        ], app)
        back(app); back(app)
        tapVisible(app.buttons["native-config-routes"], app)
        for type in ["route", "route6", "rule", "rule6"] {
            tapVisible(app.buttons["native-add-routes-\(type)"], app)
            XCTAssertTrue(app.buttons["存入草稿"].exists)
            app.buttons["取消"].tap()
        }
        back(app)
        tapVisible(app.buttons["network-dhcp-leases"], app)
        tapVisible(app.buttons["native-config-dhcp"], app)
        inspectNative(section: "dhcp-lan", type: "dhcp", groups: [
            ("常规设置", ["interface", "ignore", "start", "limit", "leasetime"]),
            ("IPv4 设置", ["force", "dhcp_option"]), ("IPv6 DHCPv6", ["dhcpv6", "dns"]),
            ("IPv6 RA", ["ra", "ra_slaac", "ra_flags"])
        ], app)
        back(app); back(app)
        tapVisible(app.buttons["network-wireless"], app)
        expectText("权限不足", app)
        tapVisible(app.buttons["编辑无线配置"], app)
        inspectNative(section: "wireless-radio0", type: "wifi-device", groups: [("基本设置", ["disabled", "band", "channel", "htmode", "country"])], app)
        back(app); back(app)
        tapVisible(app.buttons["native-config-firewall"], app)
        inspectNative(section: "firewall-defaults", type: "defaults", groups: [("默认策略", ["input", "output", "forward", "synflood_protect"])], app)
        tapVisible(app.buttons["native-section-firewall-defaults"], app)
        tapVisible(app.buttons["native-group-defaults-默认策略"], app)
        tapVisible(app.buttons["native-field-input"], app)
        app.buttons["native-value-input"].tap(); app.buttons["ACCEPT"].tap()
        app.buttons["native-save-field"].tap()
        back(app); back(app)
        tapVisible(app.buttons["native-preview-firewall"], app)
        XCTAssertTrue(app.buttons["applyConfigurationButton"].exists)
        attach("36-native-firewall-preview", app)
    }

    @MainActor
    func testKSystemRecordsAndNativeConfiguration() {
        let app = launch(); connect(app); visit("系统", app)
        tapVisible(app.buttons["native-config-system"], app)
        inspectNative(section: "system-main", type: "system", groups: [
            ("常规设置", ["hostname", "description", "timezone"]), ("日志", ["log_size", "log_ip", "log_port"])
        ], app)
        back(app)
        tapVisible(app.buttons["挂载记录"], app); expectText("preserved", app); back(app)
        visit("概览", app)
        tapVisible(app.buttons["系统日志"], app)
        tapVisible(app.buttons["router-system-log"], app)
        expectText("CI fixture log", app); attach("38-system-log", app); back(app)
        tapVisible(app.buttons["router-kernel-log"], app)
        expectText("CI fixture kernel warning", app); attach("38-kernel-log", app); back(app); back(app)
        tapVisible(app.buttons["进程"], app)
        expectText("preserved", app)
        tapVisible(app.buttons["router-process-432"], app)
        expectText("进程控制", app); attach("38-process-detail", app)
    }

    @MainActor
    func testLServiceDirectoryAllActionsAndPackageDetails() {
        let app = launch(); connect(app); visit("系统", app)
        tapVisible(app.buttons["services-directory"], app)
        tapVisible(app.buttons["service-ci_extension"], app)
        for (action, state) in [("停止", "0 / 1 个实例运行"), ("启动", "1 / 1 个实例运行"), ("重启", "1 / 1 个实例运行"), ("重载", "1 / 1 个实例运行"), ("关闭开机启动", "关闭"), ("启用开机启动", "启用")] {
            tapVisible(app.buttons[action], app)
            app.buttons["确认\(action)"].tap()
            expectText("路由器已确认执行\(action)", app)
            expectText(state, app)
        }
        attach("39-service-actions", app); back(app); back(app)
        tapVisible(app.buttons["软件包"], app)
        tapVisible(app.buttons["package-ci-extension"], app)
        expectText("etc/config/ci_extension", app); expectText("etc/init.d/ci_extension", app)
        attach("40-package-files", app); back(app); back(app)
        openExtensions(app)
        tapVisible(app.buttons["plugin-luci-app-ci-extension"], app)
        tapVisible(app.buttons["plugin-package-details"], app)
        expectText("ci-extension", app)
        attach("41-plugin-dependencies", app)
    }

    @MainActor
    func testMListDraftValidationSectionDeletionAndRollback() {
        let app = launch(); connect(app); openExtensions(app)
        tapVisible(app.buttons["plugin-luci-app-ci-extension"], app)
        tapVisible(app.buttons["plugin-config-ci_extension"], app)
        tapVisible(app.buttons["config-section-main"], app)
        app.buttons["config-field-servers"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["文本列表"].isSelected)
        replace(valueInput(app), with: "three\nfour")
        app.buttons["完成"].tap()
        expectText("three · four", app)
        app.buttons["新增字段"].tap()
        replace(app.textFields["configFieldName"], with: "bad/name")
        XCTAssertFalse(app.buttons["完成"].isEnabled)
        replace(app.textFields["configFieldName"], with: "enabled")
        XCTAssertFalse(app.buttons["完成"].isEnabled)
        replace(app.textFields["configFieldName"], with: "note")
        replace(valueInput(app), with: "temporary")
        app.buttons["完成"].tap()
        tapVisible(app.buttons["config-field-note"], app)
        tapVisible(app.buttons["删除字段"], app)
        lastButton("删除字段", app).tap()
        XCTAssertFalse(app.buttons["config-field-note"].exists)
        back(app)
        tapVisible(app.buttons["新增配置节"], app)
        replace(app.textFields["节类型"], with: "service")
        replace(app.textFields["节名称"], with: "extra")
        app.buttons["添加"].tap()
        tapVisible(app.buttons["config-section-extra"], app)
        app.buttons["删除配置节"].tap(); lastButton("删除配置节", app).tap()
        XCTAssertFalse(app.buttons["config-section-extra"].exists)
        app.buttons["previewConfigChanges"].tap()
        attach("42-list-preview", app)
        app.buttons["applyConfigurationButton"].tap(); app.buttons["应用修改"].tap()
        let rollback = app.buttons["回滚修改"]
        XCTAssertTrue(rollback.waitForExistence(timeout: 10)); rollback.tap()
        tapVisible(app.buttons["config-section-main"], app)
        expectText("one · two", app)
        app.buttons["config-field-enabled"].tap(); replace(valueInput(app), with: "0"); app.buttons["完成"].tap()
        back(app); back(app)
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(app.buttons["previewConfigChanges"].isEnabled)
        back(app); app.buttons["放弃修改"].tap()
        tapVisible(app.buttons["plugin-config-ci_extension"], app)
        inspectFields(section: "main", fields: ["enabled", "servers"], app)
        XCTAssertFalse(app.buttons["previewConfigChanges"].isEnabled)
    }

    @MainActor
    func testNSettingsEveryChoiceNestedInformationAndDisconnect() {
        let app = launch(); connect(app); visit("设置", app)
        for choice in ["跟随系统", "标准", "加大", "紧凑"] {
            tapVisible(app.buttons["textSizePicker"], app); app.buttons[choice].tap()
            XCTAssertEqual(app.buttons["textSizePicker"].value as? String, choice)
        }
        for choice in ["深色", "浅色", "跟随系统"] {
            tapVisible(app.buttons["appearancePicker"], app); app.buttons[choice].tap()
            XCTAssertEqual(app.buttons["appearancePicker"].value as? String, choice)
        }
        for (link, text) in [("helpLink", "连接路由器"), ("privacyLink", "连接与本地存储"), ("aboutLink", "Zirox-openwrt")] {
            tapVisible(app.buttons[link], app); expectText(text, app)
            if link == "aboutLink" {
                tapVisible(app.buttons["隐私说明"], app); expectText("连接与本地存储", app); back(app)
                tapVisible(app.buttons["帮助与连接"], app); expectText("连接路由器", app); back(app)
            }
            back(app)
        }
        tapVisible(app.buttons["settings-router-picker"], app)
        XCTAssertTrue(app.textFields["routerAddressField"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        tapVisible(app.buttons["settings-disconnect"], app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        tapVisible(app.buttons["settings-disconnect"], app)
        lastButton("断开连接", app).tap()
        XCTAssertTrue(app.buttons["appSettingsLink"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["概览"].exists)
        attach("43-disconnected", app)
    }

    @MainActor
    func testOOverviewShortcutsAndHeaderSearch() {
        let app = launch(); connect(app)
        for entry in ["overview-wan", "overview-interfaces"] {
            tapVisible(app.buttons[entry], app)
            XCTAssertTrue(app.buttons["interface-edit-config"].waitForExistence(timeout: 5)); back(app)
        }
        tapVisible(app.buttons["overview-wireless"], app); expectText("权限不足", app); back(app)
        tapVisible(app.buttons["overview-leases"], app)
        tapVisible(app.buttons["device-02:00:00:00:00:01|192.0.2.10"], app)
        expectText("设备名称", app); back(app); back(app)
        tapVisible(app.buttons["overview-firewall"], app)
        inspectNative(section: "firewall-defaults", type: "defaults", groups: [("默认策略", ["forward", "input"])], app); back(app)
        tapVisible(app.buttons["overview-plugins"], app)
        tapVisible(app.buttons["plugin-luci-app-ci-extension"], app)
        XCTAssertTrue(app.buttons["plugin-config-ci_extension"].exists); back(app); back(app)
        tapVisible(app.buttons["overview-configurations"], app)
        tapVisible(app.buttons["configuration-system"], app)
        inspectFields(section: "main", fields: ["hostname"], app); back(app); back(app)
        tapVisible(app.buttons["查看全部活动"], app)
        expectText("部分信息读取失败", app); back(app)
        app.buttons["搜索管理功能"].tap()
        replace(app.textFields["searchField"], with: "防火墙")
        tapVisible(app.buttons["native-config-firewall"], app)
        inspectNative(section: "firewall-defaults", type: "defaults", groups: [("默认策略", ["forward", "input"])], app)
        attach("44-search-to-field", app)
    }

    @MainActor
    func testPScheduledTasksNativeHelpPreviewSaveAndRead() {
        let app = launch(); connect(app); visit("系统", app)
        tapVisible(app.buttons["system-crontab"], app)
        tapVisible(app.buttons["cron-help"], app)
        expectText("分钟 小时 日期 月份 星期 命令", app); back(app)
        let editor = app.textViews["cron-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.isEnabled)
        replace(editor, with: "# CI fixture edited tasks\n")
        app.buttons["收起键盘"].tap()
        tapVisible(app.buttons["cron-help"], app)
        expectText("保存与恢复", app); back(app)
        XCTAssertTrue((editor.value as? String)?.contains("edited tasks") == true)
        tapVisible(app.buttons["cron-preview"], app)
        expectText("读取时内容", app); expectText("将保存的完整内容", app)
        app.buttons["完成"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("edited tasks") == true)
        tapVisible(app.buttons["cron-preview"], app)
        tapVisible(app.buttons["cron-save"], app)
        lastButton("确认保存并请求重载", app).tap()
        expectText("重读内容与提交内容一致", app)
        expectText("重载程序返回 0", app)
        app.buttons["完成"].tap()
        tapVisible(app.buttons["cron-read"], app)
        XCTAssertTrue((editor.value as? String)?.contains("edited tasks") == true)
        attach("45-native-crontab", app)
    }

    @MainActor
    func testQScheduledTasksReadOnlyKeepsRealContents() {
        let app = launch(); connect(app, username: "readonly"); visit("系统", app)
        tapVisible(app.buttons["system-crontab"], app)
        expectText("没有计划任务文件的写入权限", app)
        XCTAssertFalse(app.textViews["cron-editor"].isEnabled)
        XCTAssertTrue((app.textViews["cron-editor"].value as? String)?.contains("CI fixture scheduled tasks") == true)
        XCTAssertFalse(app.buttons["cron-preview"].isEnabled)
    }

    @MainActor
    private func checkRoutingFailure(username: String, message: String, screenshot: String) {
        let app = launch(); connect(app, username: username); visit("概览", app)
        tapVisible(app.buttons["network-routing"], app)
        expectText("无法读取邻居表", app); expectText(message, app)
        XCTAssertFalse(app.staticTexts["暂无邻居记录"].exists)
        XCTAssertFalse(app.staticTexts["暂无路由记录"].exists)
        tapVisible(app.buttons["重试"], app)
        expectText(message, app); attach(screenshot, app)
    }

    @MainActor
    private func inspectFields(section: String, fields: [String], _ app: XCUIApplication) {
        tapVisible(app.buttons["config-section-\(section)"], app)
        for key in fields {
            tapVisible(app.buttons["config-field-\(key)"], app)
            XCTAssertTrue(valueInput(app).waitForExistence(timeout: 5))
            XCTAssertFalse(app.textFields["configFieldName"].isEnabled)
            app.buttons["取消"].tap()
        }
        back(app)
    }

    @MainActor
    private func openExtensions(_ app: XCUIApplication) {
        visit("服务", app)
        tapVisible(app.buttons["已安装扩展包"], app)
    }

    @MainActor
    private func lastButton(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        let query = app.buttons.matching(identifier: id)
        XCTAssertGreaterThan(query.count, 0)
        return query.element(boundBy: max(0, query.count - 1))
    }

    @MainActor
    private func inspectNative(section: String, type: String, groups: [(String, [String])], _ app: XCUIApplication) {
        tapVisible(app.buttons["native-section-\(section)"], app)
        for (group, fields) in groups {
            tapVisible(app.buttons["native-group-\(type)-\(group)"], app)
            for field in fields {
                tapVisible(app.buttons["native-field-\(field)"], app)
                XCTAssertTrue(app.switches["明确设置此项"].exists)
                app.buttons["取消"].tap()
            }
            back(app)
        }
        back(app)
    }

    @MainActor
    private func valueInput(_ app: XCUIApplication) -> XCUIElement {
        if app.secureTextFields["configValueInput"].exists { return app.secureTextFields["configValueInput"] }
        return app.textFields["configValueInput"].exists ? app.textFields["configValueInput"] : app.textViews["configValueInput"]
    }

    @MainActor
    private func expectText(_ text: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 15), "Missing router response: \(text)")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["appSettingsLink"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openAddress(_ app: XCUIApplication) {
        if app.buttons["startConnectionButton"].exists { app.buttons["startConnectionButton"].tap() }
        XCTAssertTrue(app.textFields["routerAddressField"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func enterCredentials(_ app: XCUIApplication, username: String = "root", password: String = "ci-only-password", capture: Bool = false) {
        openAddress(app)
        replace(app.textFields["routerAddressField"], with: "http://127.0.0.1:18795")
        app.buttons["continueToLoginButton"].tap()
        let field = app.secureTextFields["routerPasswordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replace(app.textFields["routerUsernameField"], with: username)
        field.tap(); field.typeText(password)
        app.swipeUp()
        if capture { attach("07-login", app) }
    }

    @MainActor
    private func submit(_ app: XCUIApplication) {
        tapVisible(app.buttons["loginButton"], app)
        let warning = app.alerts.buttons["继续使用 HTTP"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5)); warning.tap()
    }

    @MainActor
    private func connect(_ app: XCUIApplication, username: String = "root", captureLogin: Bool = false) {
        enterCredentials(app, username: username, capture: captureLogin)
        submit(app)
        XCTAssertTrue(app.tabBars.buttons["概览"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        for title in ["概览", "系统", "服务", "网络", "设置"] { XCTAssertTrue(app.tabBars.buttons[title].exists) }
    }

    @MainActor
    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }

    @MainActor
    private func visit(_ title: String, _ app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }

    @MainActor
    private func openLeases(_ app: XCUIApplication) {
        visit("网络", app)
        tapVisible(app.buttons["network-dhcp-leases"], app)
        tapVisible(app.buttons["DHCP 租约"], app)
        XCTAssertTrue(app.buttons["device-02:00:00:00:00:01|192.0.2.10"].waitForExistence(timeout: 20))
    }

    @MainActor
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }

    @MainActor
    private func tapVisible(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        for _ in 0..<6 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.isHittable); element.tap()
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
