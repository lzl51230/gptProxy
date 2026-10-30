import XCTest
@testable import ChatGPTProxyCore

final class ProxyConfigurationTests: XCTestCase {
    func testDefaultAndReservedPorts() {
        XCTAssertEqual(ProxyConfiguration.defaultProxyPort, 7890)
        XCTAssertEqual(ProxyConfiguration.relayPort, 17890)
    }

    func testAcceptsValidPort() throws {
        XCTAssertEqual(try ProxyConfiguration.validatedPort("7891"), 7891)
    }

    func testRejectsInvalidAndReservedPorts() {
        for value in ["", "0", "65536", "abc", "17890"] {
            XCTAssertThrowsError(try ProxyConfiguration.validatedPort(value), value)
        }
    }

    func testCodexDirectoryUsesProvidedHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            AppPaths.codexDirectory(homeDirectory: home).path,
            "/Users/example/.codex"
        )
    }

    func testChatGPTApplicationCompatibilityRequiresTheCodexDesktopClient() {
        XCTAssertEqual(
            ChatGPTApplicationCompatibility.classify(
                applicationExists: true,
                bundleIdentifier: "com.openai.codex"
            ),
            .supported
        )
        XCTAssertEqual(
            ChatGPTApplicationCompatibility.classify(
                applicationExists: true,
                bundleIdentifier: "com.openai.chat"
            ),
            .requiresUpdate
        )
        XCTAssertEqual(
            ChatGPTApplicationCompatibility.classify(
                applicationExists: false,
                bundleIdentifier: nil
            ),
            .notInstalled
        )
    }
}
