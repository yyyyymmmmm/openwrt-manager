import Foundation

/// Isolates IDs and mutable transport state. The app uses a URLSession delegate
/// that refuses redirects: credentials must never leave the selected origin.
public actor UbusClient {
    private let endpoint: URL
    private let address: RouterAddress
    private let session: URLSession
    private var requestID = 0

    public init(address: RouterAddress, session: URLSession = .shared) {
        self.endpoint = address.rpcURL; self.address = address; self.session = session
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
            throw OpenWrtKitError.ubus(code: error.code ?? -1, message: error.message ?? "JSON-RPC 请求失败")
        }
        guard let result = response.result, let code = result.first?.intValue else {
            throw OpenWrtKitError.malformedResponse
        }
        switch code {
        case 0: return result.count > 1 ? result[1] : .object([:])
        case 6: throw OpenWrtKitError.permissionDenied
        case 3, 4: throw OpenWrtKitError.unsupported("路由器未提供 \(object).\(method)，可能缺少模块或该版本不支持。")
        default: throw OpenWrtKitError.ubus(code: code, message: "\(object).\(method) 未成功")
        }
    }

    public func menu(session auth: UbusSession) async throws -> JSONValue {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/luci/admin/menu"))
        let cookieName = address.isSecure ? "sysauth_https" : "sysauth_http"
        request.setValue("\(cookieName)=\(auth.token)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return try JSONDecoder().decode(JSONValue.self, from: await checkedData(request))
    }

    /// Native data requests only. No arbitrary commands or web UI are exposed.
    public func installedPackages(session auth: UbusSession) async throws -> [InstalledPackage] {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-exec"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "sessionid", value: auth.token),
                           URLQueryItem(name: "command", value: "/usr/libexec/package-manager-call list-installed"),
                           URLQueryItem(name: "stderr", value: "0")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        do {
            let data = try await checkedData(request)
            return try InventoryParser.packages(JSONDecoder().decode(JSONValue.self, from: data))
        } catch {
            let primaryError = error
            if error is URLError || error is CancellationError { throw error }
            if let failure = error as? OpenWrtKitError {
                switch failure {
                case .permissionDenied, .http(401), .http(403): throw error
                case .http(let code) where code != 404 && code != 405: throw error
                default: break
                }
            }
            // Older opkg firmware has no package-manager-call helper.
            do {
                let result = try await call(session: auth, object: "file", method: "exec", parameters: [
                    "command": .string("/bin/opkg"), "params": .array([.string("list-installed")])
                ])
                guard result["code"].intValue == 0, let text = result["stdout"].stringValue else { throw primaryError }
                return try InventoryParser.opkg(text)
            } catch {
                throw OpenWrtKitError.unsupported("软件包主接口：\(primaryError.localizedDescription)；opkg 接口：\(error.localizedDescription)")
            }
        }
    }

    private func checkedData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == address.url.host,
              http.url?.scheme == address.scheme, http.url?.port == address.url.port else {
            throw OpenWrtKitError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else { throw OpenWrtKitError.unsupported("响应过大，已停止解析。") }
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
            throw OpenWrtKitError.unsupported("响应过大，已停止解析。")
        }
        guard let decoded = try? JSONDecoder().decode(UbusResponse.self, from: data),
              decoded.jsonrpc == "2.0", decoded.id == payload.id,
              decoded.result != nil || decoded.error != nil else {
            throw OpenWrtKitError.malformedResponse
        }
        return decoded
    }
}
