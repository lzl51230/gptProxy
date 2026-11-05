import Foundation
@testable import ChatGPTProxyCore

final class MonitorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ duration: Duration) { lock.lock(); instant = instant.advanced(by: duration); lock.unlock() }
}

final class TestCodexConnection: CodexConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var cancelled = false
    private let clock: MonitorTestClock
    private let action: @Sendable (Double) async throws -> Bool
    private let delay: Int

    init(clock: MonitorTestClock, delay: Int = 1500, action: @escaping @Sendable (Double) async throws -> Bool) {
        self.clock = clock; self.delay = delay; self.action = action
    }

    func heartbeat() async throws -> CodexHeartbeat {
        let elapsed = elapsed()
        let healthy = try await action(elapsed)
        try Task.checkCancellation()
        return try finish(healthy)
    }

    private func elapsed() -> Double {
        lock.lock(); defer { lock.unlock() }
        return first.map { (clock.now() - $0).seconds } ?? 0
    }

    private func finish(_ healthy: Bool) throws -> CodexHeartbeat {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if healthy { first = first ?? clock.now(); last = clock.now() }
        let age = first.flatMap { first in last.map { ($0 - first).seconds } } ?? 0
        return .init(isHealthy: healthy, latencyMilliseconds: healthy ? delay : nil,
                     connectionSeconds: age, failureReason: healthy ? nil : "fixture disconnected")
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func close() async { cancel() }
}
