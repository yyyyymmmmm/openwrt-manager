import XCTest

/// Package A UI suite. Everything runs against the app's DEBUG-only
/// launch-argument seed (see UITestingSeed in the app target): saved
/// profiles and a full capability snapshot derived from a verified
/// real-router haul. No test touches the network or a real router,
/// and Release builds contain no seed code at all.
final class AppFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launch → welcome → address form validation → login form.
    /// The form rules pinned here: continue is disabled for an empty
    /// address, an unparseable address stays on the form with an
    /// error instead of navigating, and a valid address reaches the
    /// native login form.
    @MainActor
    func testWelcomeAddressValidationAndLoginForm() {
        let app = launch()
        let start = app.buttons["startConnectionButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let address = app.textFields["routerAddressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        let continueButton = app.buttons["continueToLoginButton"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertFalse(continueButton.isEnabled)

        // Invalid input: the form stays put and no login page opens.
        replace(address, with: "not a router")
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
        XCTAssertFalse(app.secureTextFields["routerPasswordField"].waitForExistence(timeout: 2))
        XCTAssertTrue(address.exists)

        // Valid input: the login form appears with its native fields.
        replace(address, with: "192.168.31.1")
        continueButton.tap()
        XCTAssertTrue(app.textFields["routerUsernameField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["routerPasswordField"].exists)
        XCTAssertTrue(app.buttons["loginButton"].exists)
    }

    /// Launch with seeded profiles → the saved-router list is the
    /// first screen (no welcome), listing both seeded profiles.
    @MainActor
    func testSeededProfilesAppearInList() {
        let app = launch(arguments: ["-ZiroxSeedProfiles"])
        XCTAssertTrue(app.textFields["routerAddressField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["startConnectionButton"].exists)
        XCTAssertTrue(app.staticTexts["已保存的路由器"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Home Router"].exists)
        XCTAssertTrue(app.staticTexts["Side Router"].exists)
    }

    /// Round 6: the terminal surface IS the text input. Under the
    /// DEBUG stub seed the typed bytes land in a visible byte log
    /// instead of an SSH session; assert the exact stream — plain
    /// characters, Return as CR, and a key-bar Escape.
    @MainActor
    func testTerminalTypingProducesTheExactByteStream() {
        let app = launch(arguments: ["-ZiroxSeedConnected", "-ZiroxSeedTerminal"])
        app.tabBars.buttons["系统"].tap()
        scrollUntilExists(app.buttons["终端"], app)
        app.buttons["终端"].tap()

        let surface = app.descendants(matching: .any)["terminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()

        let byteLog = app.staticTexts["terminalByteLog"]
        XCTAssertTrue(byteLog.waitForExistence(timeout: 5))
        app.typeText("ls")
        XCTAssertTrue(byteLog.label.contains("6c 73"), byteLog.label)
        app.typeText("\n")
        XCTAssertTrue(byteLog.label.contains("6c 73 0d"), byteLog.label)
        app.buttons["esc"].tap()
        XCTAssertTrue(byteLog.label.contains("6c 73 0d 1b"), byteLog.label)
    }

    /// Launch in the seeded connected state → all five tabs exist and
    /// each one opens to its own screen; the settings tab shows the
    /// profile section with the active profile.
    @MainActor
    func testFiveTabsReachable() {
        let app = launch(arguments: ["-ZiroxSeedConnected"])
        let tabs = ["概览", "网络", "服务", "系统", "设置"]
        for title in tabs {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "missing tab \(title)")
        }
        for title in tabs {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5),
                          "tab \(title) did not open its screen")
        }
        XCTAssertTrue(app.staticTexts["路由器档案"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Home Router"].exists)
        scrollUntilExists(app.staticTexts["App 设置（外观与文字）"], app)
    }

    /// From the connect flow's gear button → App 设置 shows its key
    /// rows, and the diagnostics page opens with its export action.
    @MainActor
    func testAppSettingsKeyRowsAndDiagnosticsPage() {
        let app = launch()
        let gear = app.buttons["appSettingsLink"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        XCTAssertTrue(app.buttons["textSizePicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearancePicker"].exists)
        XCTAssertTrue(app.buttons["privacyLink"].exists)
        let diagnostics = app.buttons["diagnosticsLink"]
        scrollUntilExists(diagnostics, app)
        if !diagnostics.isHittable { app.swipeUp() }
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["诊断日志"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["diagnosticsExportButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已记录事件"].exists)
    }

    // MARK: Helpers

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        return app
    }

    /// Lists and scroll views materialize rows lazily; swipe a few
    /// times before declaring an element missing.
    @MainActor
    private func scrollUntilExists(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<4 where !element.exists { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor
    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }
}
