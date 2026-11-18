import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProtectionSupervisorTests: XCTestCase {
    private enum Failure: LocalizedError {
        case offline, dnsOverride
        var errorDescription: String? {
            switch self {
            case .offline: "fixture offline"
            case .dnsOverride: "verify: 检测到 VPN 或其他 DNS 配置覆盖，已停止 DNS 保护"
            }
        }
    }

    func testTemporaryFailureRetriesAndClearsErrorOnlyAfterProtectionReturns() async {
        var time: TimeInterval = 0, attempts = 0, enabled = false, online = false
        let supervisor = ProtectionSupervisor(now: { time })
        func tick() async {
            await supervisor.tick(enabled: enabled, paused: false, prepare: {
                attempts += 1
                if !online { throw Failure.offline }
            }, activate: { enabled = true })
        }
        await tick()
        XCTAssertEqual(supervisor.retrySeconds, 2)
        XCTAssertEqual(supervisor.lastError, "fixture offline")
        online = true
        await tick()
        XCTAssertEqual(attempts, 1)
        time = 2
        await tick()
        XCTAssertFalse(enabled)
        await tick()
        XCTAssertTrue(enabled)
        XCTAssertNil(supervisor.lastError)
        enabled = false // A later helper rollback must start another recovery cycle.
        await tick(); await tick()
        XCTAssertTrue(enabled)
    }

    func testAuthorizationRemainsActionableDuringBackoffAndAfterCancellation() async {
        var time: TimeInterval = 0
        let supervisor = ProtectionSupervisor(now: { time })
        func silentCheck() async {
            await supervisor.tick(enabled: false, paused: false, prepare: {
                throw DNSHelperAuthorizationError.required
            }, activate: { XCTFail("Missing helper") })
        }

        await silentCheck()
        XCTAssertEqual(supervisor.authorizationIssue, .required)
        XCTAssertGreaterThan(supervisor.retrySeconds, 0)
        supervisor.reset() // A manual attempt bypasses the retry delay.
        supervisor.recordFailure(DNSHelperAuthorizationError.cancelled)
        time += Double(supervisor.retrySeconds)
        await silentCheck()
        XCTAssertEqual(supervisor.authorizationIssue, .cancelled)
        time += Double(supervisor.retrySeconds)
        await supervisor.tick(enabled: false, paused: false, prepare: {}, activate: {})
        XCTAssertNil(supervisor.authorizationIssue)
    }

    func testOtherFailureAndPauseClearAuthorizationAction() async {
        let supervisor = ProtectionSupervisor()
        supervisor.recordFailure(DNSHelperAuthorizationError.required)
        supervisor.recordFailure(Failure.offline)
        XCTAssertNil(supervisor.authorizationIssue)
        XCTAssertEqual(supervisor.lastError, "fixture offline")
        supervisor.recordFailure(DNSHelperAuthorizationError.required)
        await supervisor.tick(enabled: false, paused: true, prepare: {}, activate: {})
        XCTAssertNil(supervisor.authorizationIssue)
    }

    func testThirdVerifyFailureRollsBackAndStopsRecovery() async {
        var time: TimeInterval = 0
        var prepared = 0, activated = 0, restored = 0
        let supervisor = ProtectionSupervisor(now: { time })
        func tick() async {
            await supervisor.tick(enabled: false, paused: false, prepare: { prepared += 1 }, activate: {
                try await ProtectionActivation.run(launchGPT: false, isGPTRunning: { false }, enable: {
                    activated += 1
                    throw Failure.dnsOverride
                }, restartGPT: { XCTFail("Unexpected launch") }, restore: { restored += 1 }, checkCancellation: {})
            })
        }

        for delay in [2, 5, 0] {
            await tick()
            await tick()
            XCTAssertEqual(supervisor.retrySeconds, delay)
            time += Double(delay)
        }
        supervisor.recheckAfterWake()
        XCTAssertFalse(supervisor.retryDue)
        XCTAssertEqual(supervisor.stoppedMessage, "verify: 检测到 VPN 或其他 DNS 配置覆盖，已停止 DNS 保护（同一错误已连续出现 3 次，已停止自动重试）")
        XCTAssertTrue(ProtectionSupervisor(now: { time }).retryDue)
        time += 3600
        await tick()
        await tick()
        XCTAssertEqual(prepared, 6)
        XCTAssertEqual(activated, 3)
        XCTAssertEqual(restored, 3)
        XCTAssertEqual(supervisor.lastError, Failure.dnsOverride.localizedDescription)

        supervisor.reset() // Manual enable starts a new cycle.
        await tick()
        await tick()
        XCTAssertEqual(activated, 4)
        XCTAssertEqual(supervisor.retrySeconds, 2)
    }

    func testDifferentFailuresDoNotAccumulateTowardSameErrorLimit() async {
        var time: TimeInterval = 0
        let supervisor = ProtectionSupervisor(now: { time })
        let errors: [Failure] = [.offline, .offline, .dnsOverride, .offline, .offline, .offline]
        for (error, delay) in zip(errors, [2, 5, 10, 30, 60, 0]) {
            await supervisor.tick(enabled: false, paused: false,
                                  prepare: { throw error }, activate: { XCTFail("unavailable") })
            XCTAssertEqual(supervisor.retrySeconds, delay)
            time += Double(delay)
        }
        await supervisor.tick(enabled: false, paused: true,
                              prepare: { XCTFail("paused") }, activate: { XCTFail("paused") })
        XCTAssertNil(supervisor.lastError)
    }

    func testDuplicateEventsAndInvalidationCannotActivateAnOldAttempt() async {
        let supervisor = ProtectionSupervisor()
        var continuation: CheckedContinuation<Void, Never>?, prepared = 0, activated = 0
        let first = Task {
            await supervisor.tick(enabled: false, paused: false, prepare: {
                prepared += 1
                await withCheckedContinuation { continuation = $0 }
            }, activate: { activated += 1 })
        }
        while continuation == nil { await Task.yield() }
        await supervisor.tick(enabled: false, paused: false,
                              prepare: { prepared += 1 }, activate: { activated += 1 })
        supervisor.reset() // pause, port change, or shutdown
        continuation?.resume()
        await first.value
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(activated, 0)
        XCTAssertEqual(supervisor.healthyChecks, 0)
    }

    func testProcessSnapshotTracksAlreadyRunningGPTAndIgnoresWindowVisibility() {
        var pids: [pid_t] = [41, 41, 42]
        let monitor = GPTProcessMonitor(scan: { pids })
        monitor.refresh()
        XCTAssertEqual(monitor.processIdentifiers, [41, 42])
        XCTAssertTrue(monitor.isRunning)
        monitor.refresh() // No window event changes a still-running process.
        XCTAssertTrue(monitor.isRunning)
        pids = []; monitor.refresh()
        XCTAssertFalse(monitor.isRunning)
        pids = [43]; monitor.refresh()
        XCTAssertEqual(monitor.processIdentifiers, [43])
    }
}
