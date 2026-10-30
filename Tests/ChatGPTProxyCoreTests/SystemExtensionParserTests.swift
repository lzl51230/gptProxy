import XCTest
@testable import ChatGPTProxyCore

final class SystemExtensionParserTests: XCTestCase {
    func testRejectsActivatedOldExtension() {
        XCTAssertFalse(SystemExtensionParser.proxyBridgeIsEnabled(in: "* * L4HJT32Z59 com.interceptsuite.ProxyBridge.extension (4.0.0/1) extension [activated enabled]"))
    }

    func testRequiresExpectedTeamBundleAndStateOnSameRow() {
        let valid = "* * L4HJT32Z59 com.interceptsuite.ProxyBridge.extension (4.1.0/1) ProxyBridge [activated enabled]"
        XCTAssertTrue(SystemExtensionParser.proxyBridgeIsEnabled(in: valid))

        let mixedRows = """
        * * WRONGTEAM com.interceptsuite.ProxyBridge.extension (4.1.0/1) ProxyBridge [activated waiting for user]
        * * L4HJT32Z59 com.example.unrelated.extension (1.0/1) Other [activated enabled]
        """
        XCTAssertFalse(SystemExtensionParser.proxyBridgeIsEnabled(in: mixedRows))
    }

    func testRejectsCorrectBundleWithWrongTeam() {
        let output = "* * WRONGTEAM com.interceptsuite.ProxyBridge.extension (4.1.0/1) ProxyBridge [activated enabled]"
        XCTAssertFalse(SystemExtensionParser.proxyBridgeIsEnabled(in: output))
    }
}
