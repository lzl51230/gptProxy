import Foundation
import XCTest
@testable import ChatGPTProxyCore

final class ProxyBridgeCLIOutputTests: XCTestCase {
    func testRequiresVersionFullProfileAndReadiness() {
        var output = ProxyBridgeCLIOutput()
        output.consume("Redirecting traffic. Press Ctrl+C to stop.")
        XCTAssertFalse(output.isReady)
        output.consume("ProxyBridge CLI 4.1.1")
        output.consume("Profile \"ChatGPT Only\": 1 proxies, 2 rules applied")
        XCTAssertFalse(output.isReady)
        output.consume("Profile \"ChatGPT Only\": 1 proxies, 3 rules applied")
        XCTAssertFalse(output.isReady)
        output.consume("DNS proxy: off (host name rules and send hostname do not work)")
        XCTAssertTrue(output.isReady)
        output.consume("warning: 1 rule(s) were rejected by the extension (invalid fields)")
        XCTAssertFalse(output.isReady)
    }
    func testBundledProfileValidatorRejectsWrongScopeAndMissingData() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ChatGPT-Only.pbprofile")
        let data = try Data(contentsOf: url)
        XCTAssertTrue(ProxyBridgeConfigurationParser.isBundledProfileValid(data))
        XCTAssertFalse(ProxyBridgeConfigurationParser.isBundledProfileValid(Data()))
        let narrowed = String(decoding: data, as: UTF8.self).replacingOccurrences(of: ";org.sparkle-project.*", with: "")
        XCTAssertFalse(ProxyBridgeConfigurationParser.isBundledProfileValid(Data(narrowed.utf8)))
        let withDNS = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"dnsEnabled\" : false", with: "\"dnsEnabled\" : true")
        XCTAssertFalse(ProxyBridgeConfigurationParser.isBundledProfileValid(Data(withDNS.utf8)))
    }

    func testApprovalAndConflict() {
        var output = ProxyBridgeCLIOutput()
        output.consume("Extension: waiting for your approval.")
        XCTAssertTrue(output.waitingForApproval)
        output.consume("ERROR: Another ProxyBridge CLI is already running.")
        XCTAssertNotNil(output.failure)
    }

    func testFailureToDisableVendorDNSWithdrawsReadiness() {
        var output = ProxyBridgeCLIOutput()
        for line in ["ProxyBridge CLI 4.1.1", "DNS proxy: off (host name rules and send hostname do not work)",
                     "Profile \"ChatGPT Only\": 1 proxies, 3 rules applied", "Redirecting traffic. Press Ctrl+C to stop."] {
            output.consume(line)
        }
        XCTAssertTrue(output.isReady)
        output.consume("warning: Could not switch the DNS proxy off: denied")
        XCTAssertFalse(output.isReady)
    }
}

@MainActor
final class ProxyBridgeCLIControllerTests: XCTestCase {
    private func fixture(_ body: String) throws -> (URL, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-cli")
        try ("#!/bin/sh\ncat >/dev/null\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ChatGPT-Only.pbprofile")
        return (script, try Data(contentsOf: profile))
    }
    func testConcurrentStartupDrainsFragmentedOutputAndStops() async throws {
        let (script, data) = try fixture("""
        trap 'exit 0' TERM INT
        printf 'ProxyBridge CLI 4.1.1\\nProfile "ChatGPT Only": 1 proxies, '
        sleep 0.1
        printf '3 rules applied\\nDNS proxy: off (host name rules and send hostname do not work)\\nRedirecting traffic. Press Ctrl+C to stop.\\n'
        while :; do sleep 0.1; done
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let controller = ProxyBridgeCLIController(executableURL: script, timeout: 2, logURL: script.deletingLastPathComponent().appendingPathComponent("log"))
        async let first: Void = controller.ensureRunning(profileData: data)
        async let second: Void = controller.ensureRunning(profileData: data)
        try await first; try await second
        XCTAssertTrue(controller.isReady)
        let pid = controller.processIdentifier
        try await controller.ensureRunning(profileData: data)
        XCTAssertEqual(controller.processIdentifier, pid)
        await controller.stopAndWait()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.processIdentifier)
    }
    func testCancellationAndUnexpectedExitWithdrawReadiness() async throws {
        let (script, data) = try fixture("trap 'exit 0' TERM; while :; do sleep 0.1; done")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let controller = ProxyBridgeCLIController(executableURL: script, timeout: 2, logURL: script.deletingLastPathComponent().appendingPathComponent("log"))
        let task = Task { try await controller.ensureRunning(profileData: data) }
        try await Task.sleep(for: .milliseconds(80))
        await controller.stopAndWait()
        _ = try? await task.value
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.processIdentifier)

        let (exiting, profile) = try fixture("echo 'ProxyBridge CLI 4.1.1'; echo 'Profile \"ChatGPT Only\": 1 proxies, 3 rules applied'; echo 'DNS proxy: off (host name rules and send hostname do not work)'; echo 'Redirecting traffic. Press Ctrl+C to stop.'; sleep 0.2")
        defer { try? FileManager.default.removeItem(at: exiting.deletingLastPathComponent()) }
        let short = ProxyBridgeCLIController(executableURL: exiting, timeout: 2, logURL: exiting.deletingLastPathComponent().appendingPathComponent("log"))
        try await short.ensureRunning(profileData: profile)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(short.isReady)
        guard case .failed = short.state else { return XCTFail("Exited CLI must report failure") }
        await short.stopAndWait()
    }

    func testTimeoutAndConflictReleaseProcess() async throws {
        for body in ["sleep 0.5", "echo 'ERROR: Another ProxyBridge CLI is already running.' >&2; exit 1"] {
            let (script, data) = try fixture(body)
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            let controller = ProxyBridgeCLIController(executableURL: script, timeout: 0.1, logURL: script.deletingLastPathComponent().appendingPathComponent("log"))
            do { try await controller.ensureRunning(profileData: data); XCTFail("Expected failure") } catch {}
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.processIdentifier)
        }
    }

    func testLateFailureWithdrawsReadinessAndNextGenerationStartsCleanly() async throws {
        let (script, data) = try fixture("""
        trap 'exit 0' TERM INT
        printf 'ProxyBridge CLI 4.1.1\\nProfile "ChatGPT Only": 1 proxies, 3 rules applied\\nDNS proxy: off (host name rules and send hostname do not work)\\nRedirecting traffic. Press Ctrl+C to stop.\\n'
        sleep 0.2
        echo 'ERROR: late failure' >&2
        while :; do sleep 0.1; done
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let controller = ProxyBridgeCLIController(executableURL: script, timeout: 2,
            logURL: script.deletingLastPathComponent().appendingPathComponent("log"))
        for _ in 0..<3 {
            try await controller.ensureRunning(profileData: data)
            XCTAssertTrue(controller.isReady)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(controller.state, .failed("ERROR: late failure"))
            XCTAssertFalse(controller.isReady)
            await controller.stopAndWait()
            XCTAssertEqual(controller.state, .stopped)
        }
    }

    func testCancellationDuringContinuousOutputReleasesChild() async throws {
        let (script, data) = try fixture("""
        exec /usr/bin/awk 'BEGIN { while (1) print "waiting for your approval"; }'
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let controller = ProxyBridgeCLIController(executableURL: script, timeout: 5,
            logURL: script.deletingLastPathComponent().appendingPathComponent("log"))
        let startup = Task { try await controller.ensureRunning(profileData: data) }
        try await Task.sleep(for: .milliseconds(100))
        let pid = controller.processIdentifier
        await controller.stopAndWait()
        _ = try? await startup.value
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.processIdentifier)
        if let pid { XCTAssertEqual(kill(pid, 0), -1) }
        else { XCTFail("Fixture must have started before cancellation") }
    }
}
