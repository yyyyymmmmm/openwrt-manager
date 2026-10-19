import XCTest
@testable import OpenWrtKit

final class PluginCatalogTests: XCTestCase {
    func testUnknownAndSimilarlyNamedServicesDoNotBecomeDetectedPlugins() {
        let services = ["smartdns", "smartdns-helper", "uhttpd", "custom-plugin"].map {
            RouterService(name: $0, runningInstances: 1, totalInstances: 1)
        }
        XCTAssertEqual(PluginCatalog.recognize(services).map(\.id), ["smartdns"])
    }

    func testStoppedServiceIsRetainedWithoutClaimingItIsRunning() {
        let services = [RouterService(name: "adblock", runningInstances: 0, totalInstances: 1)]
        XCTAssertEqual(PluginCatalog.recognize(services).first?.service.runningInstances, 0)
    }

    func testWebFallbackPreservesProxyPrefixPortAndOrigin() throws {
        let address = try URLNormalizer.normalize("https://router.example:8443/gateway/cgi-bin/luci/admin/status")
        XCTAssertEqual(RouterWebPage.istore.url(address: address).absoluteString,
                       "https://router.example:8443/gateway/cgi-bin/luci/admin/store")
        XCTAssertEqual(RouterWebPage.packages.url(address: address).host, address.url.host)
    }
}
