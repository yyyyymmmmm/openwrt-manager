import Foundation
import CryptoKit

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
        do {
            return try await packageList(session: auth, installed: true).packages
        } catch {
            let primaryError = error
            if error is URLError || error is CancellationError { throw error }
            if let failure = error as? OpenWrtKitError {
                switch failure {
                case .http(404), .http(405): break
                default: throw error
                }
            } else { throw error }
            do {
                let result = try await call(session: auth, object: "file", method: "exec", parameters: [
                    "command": .string("/bin/opkg"), "params": .array([.string("list-installed")])
                ])
                let output = try RouterCommandResult(value: result)
                guard output.exitCode == 0 else { throw primaryError }
                return try InventoryParser.opkg(output.stdout)
            } catch {
                throw OpenWrtKitError.unsupported("软件包主接口：\(primaryError.localizedDescription)；opkg 接口：\(error.localizedDescription)")
            }
        }
    }

    /// The CGI endpoint accepts shell command text. Only this closed protocol
    /// builds that text; no caller-provided command, flags, paths or URLs.
    public func packageList(session auth: UbusSession, installed: Bool) async throws -> PackageListSnapshot {
        let operation = installed ? "list-installed" : "list-available"
        let data = try await packageHelper(session: auth, command: PackageOperation.helper + " " + operation, timeout: 60, limit: 32 * 1024 * 1024)
        return try PackageListSnapshot(data: data, installed: installed)
    }

    public func packageOperationAccess(session auth: UbusSession, operation: PackageOperation) async throws -> Bool {
        let command = try operation.command()
        let cgi = try await call(session: auth, object: "session", method: "access", parameters: [
            "scope": .string("cgi-io"), "object": .string("exec"), "function": .string("read")
        ])
        let path = try await call(session: auth, object: "session", method: "access", parameters: [
            "scope": .string("file"), "object": .string(command), "function": .string("exec")
        ])
        guard let cgiAllowed = cgi["access"].boolValue, let commandAllowed = path["access"].boolValue else {
            throw OpenWrtKitError.malformedResponse
        }
        return cgiAllowed && commandAllowed
    }

    public func performPackageOperation(session auth: UbusSession, operation: PackageOperation) async throws -> PackageOperationResult {
        guard try await packageOperationAccess(session: auth, operation: operation) else { throw OpenWrtKitError.permissionDenied }
        let command = try operation.command()
        try Task.checkCancellation()
        do {
            let data = try await packageHelper(session: auth, command: command, timeout: 600, limit: 4 * 1024 * 1024)
            return try PackageOperationResult(data: data)
        } catch {
            // Do not retry a mutation or silently fall back to another backend.
            throw PackageOperationError.uncertain(error.localizedDescription)
        }
    }

    private func packageHelper(session auth: UbusSession, command: String, timeout: TimeInterval, limit: Int) async throws -> Data {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-exec"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLComponents leaves '+' unescaped, which form decoders treat as a
        // space. Encode each form component with the unreserved character set.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = [("sessionid", auth.token), ("command", command), ("stderr", "0")]
        request.httpBody = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").data(using: .utf8)
        return try await checkedData(request, limit: limit)
    }

    /// Files are streamed from a private multipart spool, never loaded as a
    /// firmware-sized Data value. Only the two closed maintenance paths exist.
    func uploadMaintenanceFile(session auth: UbusSession, url: URL, kind: FirmwareFileKind) async throws -> FirmwareUpload {
        let body = try FirmwareLocalFile.multipart(url, token: auth.token, kind: kind)
        defer { try? FileManager.default.removeItem(at: body.url) }
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=" + body.boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let data: Data
        do {
            let response: URLResponse
            (data, response) = try await session.upload(for: request, fromFile: body.url)
            try checkResponse(response, request: request)
        } catch {
            throw FirmwareMaintenanceError.failed("上传未确认，暂存文件可能只写入了一部分；请重新上传并校验，未请求恢复或刷写。" + error.localizedDescription)
        }
        guard data.count <= 65_536 else { throw OpenWrtKitError.malformedResponse }
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        if result["failure"] != .null {
            let failure = String(data: try JSONEncoder().encode(result["failure"]), encoding: .utf8) ?? "未知失败"
            throw FirmwareMaintenanceError.failed("固件拒绝上传：" + (result["message"].stringValue ?? failure))
        }
        guard result["size"].intValue == body.size,
              let hash = result["sha256sum"].stringValue, hash.lowercased() == body.sha256 else {
            throw FirmwareMaintenanceError.failed("路由器回传的大小或 SHA-256 与本机文件不一致；未开放后续操作。")
        }
        return FirmwareUpload(kind: kind, size: body.size, sha256: body.sha256,
                              md5: result["checksum"].stringValue, originalFilename: url.lastPathComponent)
    }

    func downloadConfigurationBackup(session auth: UbusSession) async throws -> FirmwareBackupDownload {
        var request = URLRequest(url: address.url.appendingPathComponent("cgi-bin/cgi-backup"))
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("sessionid=" + auth.token).utf8)
        let (bytes, response) = try await session.bytes(for: request)
        try checkResponse(response, request: request)
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard ["application/x-targz", "application/gzip", "application/x-gzip", "application/octet-stream"].contains(where: { type.hasPrefix($0) }) else {
            throw FirmwareMaintenanceError.failed("备份接口没有返回归档文件；未将登录页或错误页保存为备份。")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zirox-backup-" + UUID().uuidString + ".tar.gz")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FirmwareMaintenanceError.failed("无法创建本机备份暂存文件。")
        }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        var keep = false
        defer { try? output.close(); if !keep { try? FileManager.default.removeItem(at: url) } }
        var chunk = Data(), header = Data(), hash = SHA256(), size = 0
        for try await byte in bytes {
            if size % 65_536 == 0 { try Task.checkCancellation() }
            size += 1
            guard size <= 128 * 1024 * 1024 else { throw FirmwareMaintenanceError.failed("备份超过本机下载限制 128 MiB。") }
            if header.count < 3 { header.append(byte) }
            chunk.append(byte)
            if chunk.count == 65_536 {
                try output.write(contentsOf: chunk); hash.update(data: chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        guard size >= 18, header == Data([0x1f, 0x8b, 0x08]) else { throw FirmwareMaintenanceError.failed("备份响应不是 gzip 归档，未开放导出。") }
        try output.write(contentsOf: chunk); hash.update(data: chunk)
        try output.synchronize(); try output.close()
        try FirmwareLocalFile.validateBackupArchive(url)
        keep = true
        return FirmwareBackupDownload(fileURL: url, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func checkResponse(_ response: URLResponse, request: URLRequest) throws {
        guard let http = response as? HTTPURLResponse, http.url == request.url else {
            throw OpenWrtKitError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
    }

    private func checkedData(_ request: URLRequest, limit: Int = 4 * 1024 * 1024) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == address.url.host,
              http.url?.scheme == address.scheme, http.url?.port == address.url.port else {
            throw OpenWrtKitError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw OpenWrtKitError.http(http.statusCode) }
        guard data.count <= limit else { throw OpenWrtKitError.unsupported("响应过大，已停止解析。") }
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
