import XCTest
@testable import ChatGPTProxyCore

final class ProxyHealthTests: XCTestCase {
    func testDetectsEnabledProxyBridgeExtension() {
        let output = "* * L4HJT32Z59 com.interceptsuite.ProxyBridge.extension (4.1.1/1) ProxyBridge [activated enabled]"
        XCTAssertTrue(SystemExtensionParser.proxyBridgeIsEnabled(in: output))
        XCTAssertFalse(SystemExtensionParser.proxyBridgeIsEnabled(in: "No extensions"))
    }
}
