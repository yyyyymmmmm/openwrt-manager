import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Isolates IDs and mutable transport state. The app uses a URLSession delegate
/// that refuses redirects: credentials must never leave the selected origin.
public actor UbusClient {
    private let endpoint: URL
    private let address: RouterAddress
    private let session: URLSession
    private var requestID = 0
    /// The client's preferred languages (device locale order). Sent as
    /// Accept-Language on every LuCI HTTP request and used to negotiate
    /// the menu-title catalog language; routers with a fixed
    /// luci.main.lang ignore the header, "auto" routers follow it.
    public let preferredLanguages: [String]

    public init(address: RouterAddress, session: URLSession = .shared,
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.endpoint = address.rpcURL; self.address = address; self.session = session
        self.preferredLanguages = preferredLanguages
    }

    private func applyLanguage(to request: inout URLRequest) {
        guard !preferredLanguages.isEmpty else { return }
        request.setValue(preferredLanguages.joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
    }

    public func login(username: String, password: String) async throws -> UbusSession {
        requestID += 1
        let response = try await send(.login(id: requestID, username: username, password: password))
        guard response.error == nil, let result = response.result,
              result.first?.intValue == 0, result.count > 1,
              let token = result[1]["ubus_rpc_session"].stringValue,
              token.count == 32, token != String(repeating: "0", count: 32),
              token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw OpenWrtKitError.authenticationFailed
        }
        return UbusSession(token: token, expiresIn: result[1]["expires"].intValue ?? 3600)
    }

    public func call(session: UbusSession, object: String, method: String, parameters: [String: JSONValue] = [:]) async throws -> JSONValue {
        requestID += 1
        let response = try await send(UbusRequest(id: requestID, session: session.token, object: object, method: method, parameters: parameters))
        if let error = response.error {
            if error.code == -32002 { throw OpenWrtKitError.permissionDenied }
            throw OpenWrtKitError.ubus(code: error.code ?? -1, message: error.message ?? KitL10n.text("JSON-RPC 请求失败"))
        }
        guard let result = response.result, let code = result.first?.intValue else {
            throw OpenWrtKitError.malformedResponse
        }
        switch code {
        case 0: return result.count > 1 ? result[1] : .object([:])
        case 6: throw OpenWrtKitError.permissionDenied
        case 3, 4: throw OpenWrtKitError.unsupported(KitL10n.format("路由器未提供 %@.%@，可能缺少模块或该版本不支持。", object, method))
        default: throw OpenWrtKitError.ubus(code: code, message: KitL10n.format("%@.%@ 未成功", object, method))
        }
    }

    /// LuCI's own web login, the same flow the web UI uses: POST the
    /// credentials to /cgi-bin/luci/ and keep the sysauth cookie from the
    /// 302 response. This is NOT interchangeable with the ubus session
    /// token: LuCI's dispatcher only treats a session as logged in when
    /// rpcd's session data carries the token LuCI's own login writes
    /// (dispatcher.uc `session_setup`), and a bare ubus `session login`
    /// never writes it — presenting the ubus token as the sysauth cookie
    /// therefore yields the anonymous menu (verified on-device: 7/58
    /// second-level nodes satisfied anonymously vs 52/58 after a real
    /// LuCI login). Writing the value remotely is impossible (rpcd denies
    /// `session set` to login sessions, -32002), so the cookie must come
    /// from this login. Returns the full "name=value" cookie pair.
    public func luciLogin(username: String, password: String) async throws -> String {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/luci/"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        applyLanguage(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "luci_username", value: username),
                           URLQueryItem(name: "luci_password", value: password)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        // Deliberately not checkedData: success is a 302 whose Set-Cookie
        // header carries the session, and the app's session delegate
        // refuses to follow redirects, so the 302 reaches us intact.
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == address.url.host,
              http.url?.scheme == address.scheme, http.url?.port == address.url.port else {
            throw OpenWrtKitError.malformedResponse
        }
        guard http.statusCode == 302 || (200..<300).contains(http.statusCode) else {
            throw OpenWrtKitError.http(http.statusCode)
        }
        let header = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        for name in ["sysauth_http", "sysauth_https"] {
            guard let range = header.range(of: "\(name)=") else { continue }
            let value = header[range.upperBound...].prefix { $0.isHexDigit }
            guard value.count == 32 else { continue }
            return "\(name)=\(value)"
        }
        throw OpenWrtKitError.authenticationFailed
    }

    /// The LuCI menu tree. Authenticated with the cookie pair issued by
    /// `luciLogin` — see its documentation for why the ubus token cannot
    /// be used here.
    public func menu(cookie: String) async throws -> JSONValue {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/luci/admin/menu"))
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyLanguage(to: &request)
        request.timeoutInterval = 15
        return try JSONDecoder().decode(JSONValue.self, from: await checkedData(request))
    }

    /// The LuCI translation catalog payload (`window.TR={...};`) for one
    /// language, from the same endpoint the web UI loads its strings
    /// from. The menu endpoint never translates titles (see
    /// LuciTranslationCatalog), so titles are localized client-side with
    /// this dictionary — the web UI's own mechanism.
    public func translations(cookie: String, language: String) async throws -> String {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/luci/admin/translations/\(language)"))
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        applyLanguage(to: &request)
        request.timeoutInterval = 15
        let data = try await checkedData(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenWrtKitError.malformedResponse
        }
        return text
    }

    /// The parsed catalog for the language this router effectively
    /// serves (negotiated from its luci config against the client's
    /// preferred languages), or nil when that language is English /
    /// undetermined. Fetch and parse failures throw — callers treat a
    /// missing catalog as "titles stay in the source language", never
    /// as a discovery failure.
    public func translationCatalog(cookie: String, luciConfig: JSONValue?) async throws -> LuciTranslationCatalog? {
        try await localization(cookie: cookie, luciConfig: luciConfig).catalog
    }

    /// The full localization context for this router: the negotiated
    /// catalog language (recorded in the discovery snapshot so a cache
    /// can be told apart by language) plus the parsed catalog. A
    /// negotiated language whose payload does not parse degrades to the
    /// source context — titles stay in the source language and the
    /// snapshot is tagged "source", never with a language whose strings
    /// were not actually applied.
    public func localization(cookie: String, luciConfig: JSONValue?) async throws -> LuciLocalization {
        guard let language = LuciLanguageNegotiator.effectiveLanguage(
            luciConfig: luciConfig, preferredLanguages: preferredLanguages) else { return .source }
        guard let catalog = LuciTranslationCatalog.parse(try await translations(cookie: cookie, language: language))
        else { return .source }
        return LuciLocalization(language: language, catalog: catalog)
    }

    /// Native data requests only. No arbitrary commands or web UI are exposed.
    public func installedPackages(session auth: UbusSession) async throws -> [InstalledPackage] {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-exec"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        applyLanguage(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "sessionid", value: auth.token),
                           URLQueryItem(name: "command", value: "/usr/libexec/package-manager-call list-installed"),
                           URLQueryItem(name: "stderr", value: "0")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let data = try await checkedData(request)
        // apk-based firmware answers with a JSON array; opkg-based
        // firmware answers with stanza text (Package:/Version:/Depends:
        // paragraphs) from the very same endpoint — verified on-device
        // against an opkg router, whose JSON parse failure was the
        // user-visible "软件包主接口格式错误". Parse whichever arrived.
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.arrayValue != nil {
            return try InventoryParser.packages(value)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenWrtKitError.malformedResponse
        }
        return try InventoryParser.opkgStanzas(text)
        // There is deliberately no file-exec fallback: rpcd never grants
        // arbitrary-command exec to login sessions (only whitelisted
        // command lines are callable, verified on-device), so the old
        // /bin/opkg exec fallback could only ever fail.
    }

    /// Package install / upgrade / remove through the router's own
    /// package-manager helper — the channel LuCI's software page
    /// uses (audit F7). Same cgi-exec form as the installed list,
    /// with the action and the already-validated package names on
    /// the helper's command line (its defined protocol); the helper
    /// translates opkg vs apk itself and answers with a JSON
    /// {code, pkmcmd, stdout, stderr} document. Actions can run for
    /// minutes (index refresh + payload downloads), so this request
    /// gets a far longer timeout than a list read.
    public func packageManagerAction(session auth: UbusSession, action: PackageActionKind,
                                     packages: [String]) async throws -> PackageActionOutcome {
        let validated = try packages.map(PackageNameValidator.requireValid)
        var command = "/usr/libexec/package-manager-call \(action.rawValue)"
        if !validated.isEmpty { command += " " + validated.joined(separator: " ") }
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-exec"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        applyLanguage(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "sessionid", value: auth.token),
                           URLQueryItem(name: "command", value: command),
                           URLQueryItem(name: "stderr", value: "0")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let data = try await checkedData(request)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw OpenWrtKitError.malformedResponse
        }
        return try PackageActionParser.outcome(value)
    }

    private func checkedData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == address.url.host,
              http.url?.scheme == address.scheme, http.url?.port == address.url.port else {
            throw OpenWrtKitError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else { throw OpenWrtKitError.unsupported(KitL10n.text("响应过大，已停止解析。")) }
        return data
    }

    private func send(_ payload: UbusRequest) async throws -> UbusResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)
        // Preserve certificate/local-network URLError values for specific recovery.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenWrtKitError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else {
            throw OpenWrtKitError.unsupported(KitL10n.text("响应过大，已停止解析。"))
        }
        guard let decoded = try? JSONDecoder().decode(UbusResponse.self, from: data),
              decoded.jsonrpc == "2.0", decoded.id == payload.id,
              decoded.result != nil || decoded.error != nil else {
            throw OpenWrtKitError.malformedResponse
        }
        return decoded
    }
}
