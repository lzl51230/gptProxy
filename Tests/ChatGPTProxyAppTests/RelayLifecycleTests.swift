import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class RelayLifecycleTests: XCTestCase {
    func testRepeatedLaunchReusesReadyRelay() async throws {
        let relay = FakeRelay()
        var creations = 0
        let lifecycle = RelayLifecycle { _ in creations += 1; return relay }
        for _ in 0..<1_000 { try await lifecycle.ensureRunning(upstreamPort: 7890) }
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(relay.starts, 1)
        XCTAssertEqual(relay.stops, 0)
    }

    func testConcurrentStartupSharesThePendingTask() async throws {
        let relay = FakeRelay()
        relay.delayStart = true
        let lifecycle = RelayLifecycle { _ in relay }
        let initial = Task { try await lifecycle.ensureRunning(upstreamPort: 7890) }
        while relay.starts == 0 { await Task.yield() }
        let launch = Task { try await lifecycle.ensureRunning(upstreamPort: 7890) }
        await Task.yield()
        relay.finishStart()
        try await initial.value
        try await launch.value
        XCTAssertEqual(relay.starts, 1)
        XCTAssertEqual(relay.stops, 0)
    }

    func testChangingPortWaitsForOldRelayToStop() async throws {
        let old = FakeRelay()
        let next = FakeRelay()
        let lifecycle = RelayLifecycle { $0 == 7890 ? old : next }
        try await lifecycle.ensureRunning(upstreamPort: 7890)
        old.delayStop = true
        let change = Task { try await lifecycle.ensureRunning(upstreamPort: 7891) }
        while old.stops == 0 { await Task.yield() }
        XCTAssertEqual(next.starts, 0)
        old.finishStop()
        try await change.value
        XCTAssertEqual(next.starts, 1)
        XCTAssertFalse(old.isReady)
    }

    func testFailedStartupIsCleanedUpAndCanBeRetried() async throws {
        let failed = FakeRelay()
        failed.failStart = true
        let working = FakeRelay()
        var attempts = 0
        let lifecycle = RelayLifecycle { _ in
            attempts += 1
            return attempts == 1 ? failed : working
        }
        do {
            try await lifecycle.ensureRunning(upstreamPort: 7890)
            XCTFail("Expected startup failure")
        } catch {}
        XCTAssertEqual(failed.stops, 1)
        try await lifecycle.ensureRunning(upstreamPort: 7890)
        XCTAssertEqual(working.starts, 1)
    }

    func testUnhealthyRelayIsReplacedEvenWithSamePort() async throws {
        let old = FakeRelay()
        let next = FakeRelay()
        var attempts = 0
        let lifecycle = RelayLifecycle { _ in
            attempts += 1
            return attempts == 1 ? old : next
        }
        try await lifecycle.ensureRunning(upstreamPort: 7890)
        old.isReady = false
        try await lifecycle.ensureRunning(upstreamPort: 7890)
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(next.starts, 1)
    }
}

@MainActor
private final class FakeRelay: ManagedRelay {
    var isReady = false
    var starts = 0
    var stops = 0
    var delayStart = false
    var delayStop = false
    var failStart = false
    private var starting: CheckedContinuation<Void, Never>?
    private var stopping: CheckedContinuation<Void, Never>?

    func start() async throws {
        starts += 1
        if delayStart { await withCheckedContinuation { starting = $0 } }
        if failStart { throw NSError(domain: "RelayTest", code: 48) }
        isReady = true
    }
    func stopAndWait() async {
        stops += 1
        if delayStop { await withCheckedContinuation { stopping = $0 } }
        isReady = false
    }
    func finishStart() { starting?.resume(); starting = nil }
    func finishStop() { stopping?.resume(); stopping = nil }
}
