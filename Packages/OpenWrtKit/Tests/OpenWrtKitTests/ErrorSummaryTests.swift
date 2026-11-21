import XCTest
@testable import OpenWrtKit

/// Package H (audit L3/L5): user-visible error text must be semantic
/// and localized — never a platform error's own English description,
/// never rpcd's raw ubus message for a well-known status code.
final class ErrorSummaryTests: XCTestCase {

    override func tearDown() {
        KitL10n.appLanguage = nil
        super.tearDown()
    }

    // MARK: KitErrorSummary

    func testKitErrorsMapToSemanticNames() {
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.invalidAddress), "地址无效")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.transport("raw socket detail")), "连接失败")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.http(404)), "HTTP 404")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.authenticationFailed), "登录失败")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.permissionDenied), "权限不足")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.unsupported("detail")), "路由器不支持")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.malformedResponse), "响应格式异常")
    }

    func testUbusCodesMapToSemanticNames() {
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 6, message: "Access denied")), "权限不足")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 4, message: "Not found")), "未找到")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 5, message: "No data")), "暂无数据")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 7, message: "Timeout")), "请求超时")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 42, message: "???")), "ubus 错误 42")
    }

    func testPlatformErrorsNeverLeakTheirOwnDescription() {
        let decoding = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "The data couldn't be read because it is corrupt."))
        XCTAssertEqual(KitErrorSummary.summary(for: decoding), "数据解析失败")
        XCTAssertEqual(KitErrorSummary.summary(for: URLError(.timedOut)), "连接超时")
        XCTAssertEqual(KitErrorSummary.summary(for: URLError(.cannotConnectToHost)), "连接失败")
        XCTAssertEqual(KitErrorSummary.summary(for: URLError(.badURL)), "网络错误")
        XCTAssertEqual(KitErrorSummary.summary(for: CancellationError()), "已取消")
        struct OpaqueError: Error {}
        XCTAssertEqual(KitErrorSummary.summary(for: OpaqueError()), "未知错误")
    }

    func testSummariesResolveInEnglish() {
        KitL10n.appLanguage = "en"
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.permissionDenied), "Permission denied")
        XCTAssertEqual(KitErrorSummary.summary(for: OpenWrtKitError.ubus(code: 6, message: "Access denied")), "Permission denied")
        XCTAssertEqual(KitErrorSummary.summary(for: URLError(.timedOut)), "Connection timed out")
    }

    // MARK: ubus errorDescription (audit L5)

    func testUbusErrorDescriptionUsesSemanticLabelForKnownCodes() {
        XCTAssertEqual(OpenWrtKitError.ubus(code: 6, message: "Access denied").errorDescription, "权限不足（ubus 6）")
        XCTAssertEqual(OpenWrtKitError.ubus(code: 3, message: "Method not found").errorDescription, "路由器不支持此功能（ubus 3）")
    }

    func testUbusErrorDescriptionKeepsRawMessageForUnknownCodes() {
        XCTAssertEqual(OpenWrtKitError.ubus(code: 42, message: "Backend exploded").errorDescription, "Backend exploded（ubus 42）")
    }

    func testUbusErrorDescriptionResolvesInEnglish() {
        KitL10n.appLanguage = "en"
        XCTAssertEqual(OpenWrtKitError.ubus(code: 6, message: "Access denied").errorDescription, "Permission denied (ubus 6)")
    }

    // MARK: Diagnostics export header (audit L8)

    func testExportHeaderFollowsTheAppLanguage() {
        let header = DiagnosticExportHeader(
            appVersion: "0.3.0", appBuild: "6", deviceModel: "iPhone17,2",
            systemName: "iOS", systemVersion: "26.0",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_120))
        let chinese = DiagnosticExport.render(header: header, events: [])
        XCTAssertTrue(chinese.contains("Zirox-openwrt 诊断日志"))
        XCTAssertTrue(chinese.contains("事件：共 0 条，显示最近 0 条"))
        KitL10n.appLanguage = "en"
        let english = DiagnosticExport.render(header: header, events: [])
        XCTAssertTrue(english.contains("Zirox-openwrt diagnostics"))
        XCTAssertTrue(english.contains("App: 0.3.0 (6)"))
        XCTAssertTrue(english.contains("Events: 0 total, showing last 0"))
    }
}
