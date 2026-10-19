import XCTest

final class RouterSmokeTests: XCTestCase {
    @MainActor
    func testConnectEntryAndReadOnlyTabsInDemoMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["连接你的路由器"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["routerAddressField"].exists)
        attachScreenshot(named: "01-connect", from: app)
        let demoButton = app.buttons["demoModeButton"]
        app.swipeUp()
        XCTAssertTrue(demoButton.waitForExistence(timeout: 5))
        demoButton.tap()
        XCTAssertTrue(app.staticTexts["演示数据 · 未连接路由器"].waitForExistence(timeout: 5))
        attachScreenshot(named: "02-overview", from: app)
        visitTab("设备", in: app)
        XCTAssertTrue(app.staticTexts["我的 iPhone"].waitForExistence(timeout: 5))
        attachScreenshot(named: "03-devices", from: app)
        visitTab("网络", in: app)
        XCTAssertTrue(app.staticTexts["lan"].waitForExistence(timeout: 5))
        attachScreenshot(named: "04-network", from: app)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Home · 2.4 GHz"].waitForExistence(timeout: 5))
        attachScreenshot(named: "04-wifi", from: app)
        visitTab("服务", in: app)
        XCTAssertTrue(app.staticTexts["dnsmasq"].waitForExistence(timeout: 5))
        attachScreenshot(named: "05-services", from: app)
        visitTab("系统", in: app)
        let firmware = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "OpenWrt 24.10")
        ).firstMatch
        XCTAssertTrue(firmware.waitForExistence(timeout: 5))
        attachScreenshot(named: "06-system", from: app)
    }

    @MainActor
    func testManualAddressOpensLogin() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["routerAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://router.example:8443")
        app.buttons["continueToLoginButton"].tap()
        XCTAssertTrue(app.secureTextFields["routerPasswordField"].waitForExistence(timeout: 5))
        let address = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "https://router.example:8443")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        attachScreenshot(named: "07-login", from: app)
    }

    @MainActor
    func testScanEntryWaitsForUserToStart() {
        let app = XCUIApplication()
        app.launch()
        let scanLink = app.buttons["scanLocalNetworkLink"]
        XCTAssertTrue(scanLink.waitForExistence(timeout: 10))
        scanLink.tap()
        XCTAssertTrue(app.buttons["startScanButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["手动输入地址"].exists)
        attachScreenshot(named: "09-scan-entry", from: app)
    }

    @MainActor
    func testDarkModeAndLargeType() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--dark", "--large-type"]
        app.launch()
        XCTAssertTrue(app.staticTexts["演示数据 · 未连接路由器"].waitForExistence(timeout: 10))
        attachScreenshot(named: "08-dark-large-type", from: app)
    }

    @MainActor
    private func visitTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing tab: \(title)")
        button.tap()
    }

    @MainActor
    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
