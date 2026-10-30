import Foundation
import XCTest
@testable import ChatGPTProxyCore

final class ProxyBridgeConfigurationTests: XCTestCase {
    func testAcceptsExactActiveChatGPTOnlyConfiguration() throws {
        let data = try makePreferences()

        XCTAssertTrue(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testRejectsExtraRule() throws {
        var rules = expectedRules
        rules.append([
            "processNames": "*",
            "targetHosts": "*",
            "targetPorts": "*",
            "protocol": "BOTH",
            "action": "DIRECT",
            "enabled": true,
        ])

        let data = try makePreferences(rules: rules)

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testRejectsConfigurationWhoseProfileIsNotRegisteredAsActive() throws {
        let data = try makePreferences(activeProfile: "Missing", profiles: ["ChatGPT Only"])

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testRejectsMatchingRulesWhenActiveProfileIsNotChatGPTOnly() throws {
        let data = try makePreferences(activeProfile: "Default", profiles: ["Default"])

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testRejectsStaleActiveProfileSnapshot() throws {
        let data = try makePreferences(snapshotRules: [])

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testExpectedRulesIncludeOpenAICodexAndSparkleProcesses() {
        for rule in expectedRules {
            XCTAssertEqual(
                rule["processNames"] as? String,
                "com.openai.*;com.openai.chat;ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*"
            )
        }
    }

    func testRejectsNarrowCodexProcessRules() throws {
        let narrowRules = expectedRules.map { rule in
            var narrowRule = rule
            narrowRule["processNames"] = "com.openai.codex;com.openai.codex.helper;ChatGPT"
            return narrowRule
        }
        let data = try makePreferences(rules: narrowRules)

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testRejectsPreviousProcessCoverageInLiveRulesOrProfileSnapshot() throws {
        let previousRules = expectedRules.map { rule in
            var previousRule = rule
            previousRule["processNames"] = "com.openai.*;com.openai.chat;ChatGPT"
            return previousRule
        }

        for data in [
            try makePreferences(rules: previousRules, snapshotRules: expectedRules),
            try makePreferences(snapshotRules: previousRules),
        ] {
            XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
        }
    }

    func testRejectsLocalDirectRuleThatWouldBypassUDPProxying() throws {
        var rules = expectedRules
        rules[0]["protocol"] = "BOTH"

        XCTAssertFalse(
            ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(
                in: try makePreferences(rules: rules)
            )
        )
    }

    func testRejectsProxyWithCredentials() throws {
        var configs = expectedConfigs
        configs[0]["username"] = "unexpected"
        let data = try makePreferences(configs: configs)

        XCTAssertFalse(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data))
    }

    func testCollisionSafeDestinationPreservesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let requested = directory.appendingPathComponent("ChatGPT-Only.pbprofile")
        let second = directory.appendingPathComponent("ChatGPT-Only (2).pbprofile")
        XCTAssertTrue(FileManager.default.createFile(atPath: requested.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))

        XCTAssertEqual(
            CollisionSafeDestination.availableURL(for: requested),
            directory.appendingPathComponent("ChatGPT-Only (3).pbprofile")
        )
    }

    private func makePreferences(
        activeProfile: String = "ChatGPT Only",
        profiles: [String] = ["Default", "ChatGPT Only"],
        configs: [[String: Any]]? = nil,
        rules: [[String: Any]]? = nil,
        snapshotRules: [[String: Any]]? = nil
    ) throws -> Data {
        let configsData = try JSONSerialization.data(withJSONObject: configs ?? expectedConfigs)
        let snapshotConfigsData = try JSONSerialization.data(withJSONObject: configs ?? expectedConfigs)
        let preferences: [String: Any] = [
            "activeProfile": activeProfile,
            "profiles": profiles,
            "proxyConfigs": configsData,
            "proxyRules": rules ?? expectedRules,
            "profile.\(activeProfile).proxyConfigs": snapshotConfigsData,
            "profile.\(activeProfile).proxyRules": snapshotRules ?? rules ?? expectedRules,
        ]
        return try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
    }

    private var expectedConfigs: [[String: Any]] {
        [[
            "id": "chatgpt-proxy-relay",
            "name": "ChatGPT Proxy Relay",
            "type": "socks5",
            "host": "127.0.0.1",
            "port": 17_890,
        ]]
    }

    private var expectedRules: [[String: Any]] {
        [
            [
                "localId": "chatgpt-local-direct",
                "name": "ChatGPT Local Direct",
                "processNames": "com.openai.*;com.openai.chat;ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*",
                "targetHosts": "localhost;127.0.0.1;::1;192.168.*.*;192.168.100.81",
                "targetPorts": "*",
                "protocol": "TCP",
                "action": "DIRECT",
                "enabled": true,
            ],
            [
                "localId": "chatgpt-only-proxy",
                "name": "ChatGPT Proxy",
                "processNames": "com.openai.*;com.openai.chat;ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*",
                "targetHosts": "*",
                "targetPorts": "*",
                "protocol": "BOTH",
                "action": "chatgpt-proxy-relay",
                "enabled": true,
            ],
        ]
    }
}
