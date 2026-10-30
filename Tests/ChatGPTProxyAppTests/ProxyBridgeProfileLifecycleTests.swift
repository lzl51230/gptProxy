import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProxyBridgeProfileLifecycleTests: XCTestCase {
    private enum TestError: LocalizedError {
        case expected

        var errorDescription: String? { "expected failure" }
    }

    func testSuccessWaitsForLaunchThenTerminatesValidatesAndReopens() async throws {
        let eventRecorder = EventRecorder()
        let lifecycle = makeLifecycle(eventRecorder: eventRecorder)

        try await lifecycle.run()

        XCTAssertEqual(
            eventRecorder.events,
            ["install", "open", "wait-for-launch", "terminate", "validate-installed", "open"]
        )
    }

    func testInstallFailureDoesNotAttemptRollbackOrLaunch() async {
        let eventRecorder = EventRecorder()
        let lifecycle = makeLifecycle(eventRecorder: eventRecorder, installFails: true)

        await XCTAssertThrowsErrorAsync(try await lifecycle.run()) { error in
            XCTAssertEqual(error.localizedDescription, TestError.expected.localizedDescription)
        }
        XCTAssertEqual(eventRecorder.events, ["install"])
    }

    func testVerificationFailureTerminatesRestoresValidatesAndRelaunches() async {
        let eventRecorder = EventRecorder()
        let lifecycle = makeLifecycle(
            eventRecorder: eventRecorder,
            installedProfileIsValid: false
        )

        await XCTAssertThrowsErrorAsync(try await lifecycle.run()) { error in
            XCTAssertEqual(error as? AppError, .profileVerificationFailed)
        }
        XCTAssertEqual(
            eventRecorder.events,
            [
                "install", "open", "wait-for-launch", "terminate", "validate-installed",
                "terminate", "restore", "open",
            ]
        )
    }

    func testRollbackStopsBeforeRestoreWhenProxyBridgeCannotTerminate() async {
        let eventRecorder = EventRecorder()
        let lifecycle = makeLifecycle(
            eventRecorder: eventRecorder,
            installedProfileIsValid: false,
            rollbackTerminationFails: true
        )

        await XCTAssertThrowsErrorAsync(try await lifecycle.run()) { error in
            guard case let AppError.profileRollbackFailed(message)? = error as? AppError else {
                return XCTFail("Expected profileRollbackFailed, got \(error)")
            }
            XCTAssertEqual(message, TestError.expected.localizedDescription)
        }
        XCTAssertEqual(
            eventRecorder.events,
            [
                "install", "open", "wait-for-launch", "terminate", "validate-installed",
                "terminate",
            ]
        )
    }

    func testRollbackDoesNotReopenWhenRestoreFails() async {
        let eventRecorder = EventRecorder()
        let lifecycle = makeLifecycle(
            eventRecorder: eventRecorder,
            installedProfileIsValid: false,
            restoreFails: true
        )

        await XCTAssertThrowsErrorAsync(try await lifecycle.run()) { error in
            guard case let AppError.profileRollbackFailed(message)? = error as? AppError else {
                return XCTFail("Expected profileRollbackFailed, got \(error)")
            }
            XCTAssertEqual(message, TestError.expected.localizedDescription)
        }
        XCTAssertEqual(
            eventRecorder.events,
            [
                "install", "open", "wait-for-launch", "terminate", "validate-installed",
                "terminate", "restore",
            ]
        )
    }

    private func makeLifecycle(
        eventRecorder: EventRecorder,
        installFails: Bool = false,
        installedProfileIsValid: Bool = true,
        rollbackTerminationFails: Bool = false,
        restoreFails: Bool = false
    ) -> ProxyBridgeProfileLifecycle<String> {
        return ProxyBridgeProfileLifecycle(
            operations: .init(
                install: {
                    eventRecorder.append("install")
                    if installFails { throw TestError.expected }
                    return "receipt"
                },
                openProxyBridge: {
                    eventRecorder.append("open")
                },
                waitUntilProxyBridgeFinishesLaunching: {
                    eventRecorder.append("wait-for-launch")
                    return true
                },
                terminateProxyBridge: {
                    eventRecorder.append("terminate")
                    if rollbackTerminationFails, eventRecorder.terminationCount == 2 {
                        throw TestError.expected
                    }
                },
                installedProfileIsValid: { receipt in
                    XCTAssertEqual(receipt, "receipt")
                    eventRecorder.append("validate-installed")
                    return installedProfileIsValid
                },
                restore: { receipt in
                    XCTAssertEqual(receipt, "receipt")
                    eventRecorder.append("restore")
                    if restoreFails { throw TestError.expected }
                }
            )
        )
    }
}

@MainActor
final class ProfileConfigurationModelTests: XCTestCase {
    private enum TestError: LocalizedError {
        case expected

        var errorDescription: String? { "profile setup failed" }
    }

    func testSuccessfulProfileConfigurationClearsFallbackAndEndsReady() async {
        var refreshed = false
        let model = AppModel(
            profileConfigurator: {},
            refreshAfterProfileConfiguration: { refreshed = true }
        )

        await model.installAndActivateBundledProfile()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.profileInstallRequiresManualFallback)
        XCTAssertTrue(refreshed)
    }

    func testFailedProfileConfigurationEnablesFallbackAndReportsFailure() async {
        var refreshed = false
        let model = AppModel(
            profileConfigurator: { throw TestError.expected },
            refreshAfterProfileConfiguration: { refreshed = true }
        )

        await model.installAndActivateBundledProfile()

        XCTAssertEqual(model.phase, .failed(TestError.expected.localizedDescription))
        XCTAssertTrue(model.profileInstallRequiresManualFallback)
        XCTAssertFalse(refreshed)
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [String] = []

    var terminationCount: Int {
        events.filter { $0 == "terminate" }.count
    }

    func append(_ event: String) {
        events.append(event)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
