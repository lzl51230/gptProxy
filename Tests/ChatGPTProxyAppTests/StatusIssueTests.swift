import XCTest
@testable import ChatGPTProxyApp

final class StatusIssueTests: XCTestCase {
    func testEachStatusIssueProvidesTheExpectedAction() {
        XCTAssertEqual(StatusIssue.chatGPT(requiresUpdate: false).action, .downloadChatGPT)
        XCTAssertEqual(StatusIssue.proxyBridge.action, .installProxyBridge)
        XCTAssertEqual(StatusIssue.networkExtension.action, .openNetworkExtensionSettings)
        XCTAssertEqual(StatusIssue.dedicatedProfile(manualFallback: false).action, .installProfile)
        XCTAssertEqual(StatusIssue.dedicatedProfile(manualFallback: true).action, .installProfile)
        XCTAssertEqual(
            StatusIssue.localProxy(port: 7_890).action,
            .refreshStatus
        )
    }

    func testLegacyChatGPTIssueExplainsThatAnUpdateIsRequired() {
        let issue = StatusIssue.chatGPT(requiresUpdate: true)

        XCTAssertEqual(issue.title, "ChatGPT 需要更新")
        XCTAssertEqual(issue.actionTitle, "更新 ChatGPT")
        XCTAssertTrue(issue.message.contains("Codex API Key"))
    }

    func testDedicatedProfileFallsBackToManualExportAfterAutomaticFailure() {
        let issue = StatusIssue.dedicatedProfile(manualFallback: true)

        XCTAssertEqual(issue.actionTitle, "启用代理")
        XCTAssertTrue(issue.message.contains("CLI"))
    }

    func testLocalProxyIssueIncludesTheConfiguredPortWhenUnreachable() {
        let issue = StatusIssue.localProxy(port: 7_890)

        XCTAssertEqual(issue.title, "Codex 连通检查未通过")
        XCTAssertTrue(issue.message.contains("127.0.0.1:7890"))
        XCTAssertEqual(issue.actionTitle, "重新检测")
    }

    func testLocalProxyIssueExplainsCredentialFreeCodexCheck() {
        let issue = StatusIssue.localProxy(port: 12345)
        XCTAssertTrue(issue.message.contains("Codex"))
        XCTAssertTrue(issue.message.contains("无需登录凭据"))
        XCTAssertTrue(issue.message.contains("12345"))
    }

    func testNetworkExtensionSettingsURLUsesTheVersionAppropriatePane() {
        XCTAssertEqual(
            SystemSettingsDestination.networkExtensionsURL(macOSMajorVersion: 14)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security"
        )
        XCTAssertEqual(
            SystemSettingsDestination.networkExtensionsURL(macOSMajorVersion: 15)?.absoluteString,
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"
        )
        XCTAssertEqual(
            SystemSettingsDestination.networkExtensionsURL(macOSMajorVersion: 26)?.absoluteString,
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"
        )
    }
}
