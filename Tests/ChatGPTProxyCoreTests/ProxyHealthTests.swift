import XCTest
@testable import ChatGPTProxyCore

final class ProxyHealthTests: XCTestCase {
    func testParsesCloudflareLocation() throws {
        let trace = "fl=1\nh=www.cloudflare.com\nip=203.0.113.1\nloc=JP\ntls=TLSv1.3\n"
        XCTAssertEqual(try EgressLocationParser.location(from: trace), "JP")
    }

    func testRejectsMissingLocation() {
        XCTAssertThrowsError(try EgressLocationParser.location(from: "ip=203.0.113.1\n"))
    }

    func testDetectsEnabledProxyBridgeExtension() {
        let output = "* * L4HJT32Z59 com.interceptsuite.ProxyBridge.extension (4.1.0/1) ProxyBridge [activated enabled]"
        XCTAssertTrue(SystemExtensionParser.proxyBridgeIsEnabled(in: output))
        XCTAssertFalse(SystemExtensionParser.proxyBridgeIsEnabled(in: "No extensions"))
    }
}
