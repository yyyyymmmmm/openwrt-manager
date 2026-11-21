import Foundation

/// The kit-side counterpart of the app's FriendlyError: a short,
/// semantic, localized name for an error, safe to show to the user.
///
/// Reader code folds per-section failures into snapshot warnings, and
/// those warnings are user-visible — so they must never splice in an
/// error's own description: platform errors (DecodingError, URL
/// loading, SSH stacks) describe themselves in English sentences,
/// which used to land verbatim in lines like "硬件信息：The data
/// couldn't be read because…" (audit L3). Raw error text belongs to
/// the diagnostics channel only; warnings carry this semantic name.
public enum KitErrorSummary {
    public static func summary(for error: Error) -> String {
        if let kitError = error as? OpenWrtKitError {
            switch kitError {
            case .invalidAddress: return KitL10n.text("地址无效")
            case .transport: return KitL10n.text("连接失败")
            case .http(let code): return KitL10n.format("HTTP %lld", code)
            case .authenticationFailed: return KitL10n.text("登录失败")
            case .permissionDenied: return KitL10n.text("权限不足")
            case .unsupported: return KitL10n.text("路由器不支持")
            case .malformedResponse: return KitL10n.text("响应格式异常")
            case .ubus(let code, _):
                if let label = OpenWrtKitError.ubusStatusLabel(code: code) { return label }
                return KitL10n.format("ubus 错误 %lld", code)
            }
        }
        if error is DecodingError { return KitL10n.text("数据解析失败") }
        if error is CancellationError { return KitL10n.text("已取消") }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return KitL10n.text("连接超时")
            case .cancelled: return KitL10n.text("已取消")
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return KitL10n.text("连接失败")
            default: return KitL10n.text("网络错误")
            }
        }
        return KitL10n.text("未知错误")
    }
}
