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
        visit("设备", app)
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
        visit("网络", app)
        attach("04-network", app)
        visit("插件", app)
        XCTAssertTrue(app.buttons["plugin-luci-app-ci-extension"].waitForExistence(timeout: 15))
        attach("05-plugins", app)
        visit("系统", app)
        attach("06-system", app)
        tapVisible(app.buttons["系统日志"], app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CI fixture log")).firstMatch.waitForExistence(timeout: 5))
        attach("20-records", app)
    }

    @MainActor
    func testCConfigurationApplyConfirmAndServiceControl() {
        let app = launch()
        connect(app)
        visit("插件", app)
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
        visit("插件", app)
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
        visit("设备", app); attach("14-dark-devices", app)
        visit("插件", app)
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
        visit("设备", app)
        XCTAssertTrue(app.buttons["device-02:00:00:00:00:01|192.0.2.10"].waitForExistence(timeout: 15))
        visit("概览", app)
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
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }

    @MainActor
    private func tapVisible(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); XCTAssertTrue(element.isHittable); element.tap()
    }

    @MainActor
    private func attach(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
