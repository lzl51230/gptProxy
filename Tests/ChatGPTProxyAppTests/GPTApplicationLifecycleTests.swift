import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class GPTApplicationLifecycleTests: XCTestCase {
    func testGracefulExitLongerThanThreeSecondsCompletesBeforeRelaunch() async throws {
        var time: TimeInterval = 0, terminationRequests = 0, launches = 0
        try await GPTApplicationLifecycle.restart(
            requestTermination: { terminationRequests += 1 }, isRunning: { time < 4.5 },
            launch: { XCTAssertGreaterThanOrEqual(time, 4.5); launches += 1 }, checkCancellation: {},
            now: { time }, pause: { time += 0.25 })
        XCTAssertEqual(terminationRequests, 1)
        XCTAssertEqual(launches, 1)
    }

    func testStuckGPTTimesOutAndRestoresProtectionWithoutLaunching() async {
        var time: TimeInterval = 0, restored = false, launches = 0
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { true }, enable: {},
                restartGPT: {
                    try await GPTApplicationLifecycle.restart(requestTermination: {}, isRunning: { true },
                        launch: { launches += 1 }, checkCancellation: {}, now: { time }, pause: { time += 1 })
                }, restore: { restored = true }, checkCancellation: {})
            XCTFail("A running old process must prevent relaunch")
        } catch { XCTAssertEqual(error as? AppError, .chatGPTDidNotTerminate) }
        XCTAssertEqual(time, GPTApplicationLifecycle.terminationTimeout)
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(restored)
    }

    func testCancellationDuringTerminationWaitRestoresAndDoesNotLaunch() async {
        var time: TimeInterval = 0, restored = false, launches = 0
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { true }, enable: {},
                restartGPT: {
                    try await GPTApplicationLifecycle.restart(requestTermination: {}, isRunning: { true },
                        launch: { launches += 1 }, checkCancellation: {}, now: { time },
                        pause: { time += 1; if time == 2 { throw CancellationError() } })
                }, restore: { restored = true }, checkCancellation: {})
            XCTFail("Cancellation must stop relaunch")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(time, 2)
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(restored)
    }

    func testCancellationAfterOldProcessExitsStillPreventsLaunch() async {
        var running = true, cancelled = false, launches = 0
        do {
            try await GPTApplicationLifecycle.restart(requestTermination: {}, isRunning: { running },
                launch: { launches += 1 }, checkCancellation: { if cancelled { throw CancellationError() } },
                pause: { running = false; cancelled = true })
            XCTFail("Cancellation before launch must be observed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(launches, 0)
    }
}
