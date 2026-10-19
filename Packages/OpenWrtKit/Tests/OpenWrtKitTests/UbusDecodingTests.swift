import XCTest
@testable import OpenWrtKit

final class UbusDecodingTests: XCTestCase {
    func testDecodesLoginResponse() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":[0,{"ubus_rpc_session":"abc","expires":3600}]}"#.utf8)
        let response = try JSONDecoder().decode(UbusResponse.self, from: data)
        XCTAssertEqual(response.result?[0].intValue, 0)
        XCTAssertEqual(response.result?[1].objectValue?["ubus_rpc_session"]?.stringValue, "abc")
    }
}
