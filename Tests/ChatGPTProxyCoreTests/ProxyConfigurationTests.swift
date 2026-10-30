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

    func testNativeBackendUsesRelayWithRemoteDNSRegardlessOfInheritedProxySettings() {
        let proxyKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
        let inheritedProxies = Dictionary(uniqueKeysWithValues: proxyKeys.map {
            ($0, "http://old-proxy.example:8080")
        })

        for inherited in [[:], inheritedProxies] {
            var base = inherited
            base["PATH"] = "/usr/bin:/bin"
            base["CUSTOM_SETTING"] = "preserved"
            let environment = ChatGPTApplicationCompatibility.proxyLaunchEnvironment(inheriting: base)

            for key in proxyKeys {
                XCTAssertEqual(environment[key], "socks5h://127.0.0.1:17890", key)
            }
            XCTAssertEqual(environment["PATH"], base["PATH"])
            XCTAssertEqual(environment["CUSTOM_SETTING"], base["CUSTOM_SETTING"])
        }
    }

    func testNativeProxyBypassesOnlyLocalDestinationsRegardlessOfInheritedNoProxy() {
        for inherited in [[:], ["NO_PROXY": "*", "no_proxy": "chatgpt.com"]] {
            let environment = ChatGPTApplicationCompatibility.proxyLaunchEnvironment(inheriting: inherited)

            for key in ["NO_PROXY", "no_proxy"] {
                XCTAssertEqual(environment[key], "localhost,127.0.0.1,::1,192.168.0.0/16", key)
            }
        }
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
