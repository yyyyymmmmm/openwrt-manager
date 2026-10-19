import XCTest
@testable import OpenWrtKit

final class URLNormalizerTests: XCTestCase {
    func testAddsHTTPAndDefaultPort() throws {
        let address = try URLNormalizer.normalize("192.168.1.1")
        XCTAssertEqual(address.scheme, "http")
        XCTAssertEqual(address.host, "192.168.1.1")
        XCTAssertEqual(address.port, 80)
    }

    func testPreservesHTTPSPort() throws {
        let address = try URLNormalizer.normalize("https://router.local:8443/path")
        XCTAssertEqual(address.scheme, "https")
        XCTAssertEqual(address.host, "router.local")
        XCTAssertEqual(address.port, 8443)
    }

    func testRejectsMissingHost() {
        XCTAssertThrowsError(try URLNormalizer.normalize("https://"))
    }

    func testPastedLuCIAddressKeepsReverseProxyBasePath() throws {
        let address = try URLNormalizer.normalize("https://router.example/gateway/cgi-bin/luci/admin/status")
        XCTAssertEqual(address.rpcURL.absoluteString, "https://router.example/gateway/ubus")
    }

    func testPastedUbusAddressDoesNotDuplicateEndpoint() throws {
        let address = try URLNormalizer.normalize("https://router.local:8443/ubus")
        XCTAssertEqual(address.rpcURL.absoluteString, "https://router.local:8443/ubus")
    }

    func testIPv6Literal() throws {
        let address = try URLNormalizer.normalize("http://[fd00::1]:8080")
        XCTAssertEqual(address.host, "fd00::1")
        XCTAssertEqual(address.port, 8080)
    }

    func testRejectsCredentialsQueriesAndInvalidPorts() {
        for input in ["https://root:secret@router.local", "https://router.local/?token=secret",
                      "http://router.local:65536", "http://999.1.1.1", "ftp://router.local"] {
            XCTAssertThrowsError(try URLNormalizer.normalize(input), input)
        }
    }
}
