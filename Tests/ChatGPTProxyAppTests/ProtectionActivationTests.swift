import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProtectionActivationTests: XCTestCase {
    private enum Failure: Error { case expected }

    func testRestartsExistingGPTOnlyAfterProtectionAndDoesNotStartAnAbsentApp() async throws {
        for running in [true, false] {
            var events: [String] = []
            try await ProtectionActivation.run(launchGPT: false, isGPTRunning: { running },
                enable: { events.append("protect") }, restartGPT: { events.append("restart") },
                restore: { events.append("restore") }, checkCancellation: {})
            XCTAssertEqual(events, running ? ["protect", "restart"] : ["protect"])
        }
    }

    func testLaunchActionStartsGPTAfterProtectionEvenWhenItWasNotRunning() async throws {
        var events: [String] = []
        try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
            enable: { events.append("protect") }, restartGPT: { events.append("restart") },
            restore: { events.append("restore") }, checkCancellation: {})
        XCTAssertEqual(events, ["protect", "restart"])
    }

    func testRestartFailureRestoresPolicyInsteadOfCompletingActivation() async {
        var events: [String] = []
        do {
            try await ProtectionActivation.run(launchGPT: false, isGPTRunning: { true },
                enable: { events.append("protect") },
                restartGPT: { events.append("restart"); throw Failure.expected },
                restore: { events.append("restore") }, checkCancellation: {})
            XCTFail("Activation must fail")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(events, ["protect", "restart", "restore"])
    }

    func testCancellationAfterEnableRestoresWithoutStartingGPT() async {
        var enabled = false, events: [String] = []
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
                enable: { enabled = true; events.append("protect") }, restartGPT: { events.append("restart") },
                restore: { events.append("restore") },
                checkCancellation: { if enabled { throw CancellationError() } })
            XCTFail("Cancellation must fail activation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["protect", "restore"])
    }

    func testEnableAndRecoveryFailuresRemainVisible() async {
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
                enable: { throw Failure.expected }, restartGPT: { XCTFail("Must not launch") },
                restore: { throw Failure.expected }, checkCancellation: {})
            XCTFail("Activation must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("恢复未完成")) }
    }
}
