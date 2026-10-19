import Foundation

/// Isolates IDs and mutable transport state. The app uses a URLSession delegate
/// that refuses redirects: credentials must never leave the selected origin.
public actor UbusClient {
    private let endpoint: URL
    private let session: URLSession
    private var requestID = 0

    public init(address: RouterAddress, session: URLSession = .shared) {
        self.endpoint = address.rpcURL; self.session = session
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
