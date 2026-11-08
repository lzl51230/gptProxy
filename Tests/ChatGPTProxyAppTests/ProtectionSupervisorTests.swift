import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProtectionSupervisorTests: XCTestCase {
    private enum Failure: LocalizedError {
        case offline
        var errorDescription: String? { "fixture offline" }
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

    func testBackoffIsBoundedAndPauseDoesNotReactivate() async {
        var time: TimeInterval = 0
        let supervisor = ProtectionSupervisor(now: { time })
        for delay in [2, 5, 10, 30, 60, 60] {
            await supervisor.tick(enabled: false, paused: false,
                                  prepare: { throw Failure.offline }, activate: { XCTFail("offline") })
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
