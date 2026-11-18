import Foundation

@MainActor
final class ProtectionSupervisor {
    private static let failureLimit = 3
    private var previousFailureReason: String?
    private var consecutiveFailures = 0
    private var lastFailure: Error?
    var lastError: String? { lastFailure?.localizedDescription }
    var authorizationIssue: DNSHelperAuthorizationError? { lastFailure as? DNSHelperAuthorizationError }
    private(set) var retryAt: TimeInterval = 0
    private(set) var failures = 0
    private(set) var healthyChecks = 0
    private(set) var busy = false
    private var revision = 0
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var retriesStopped: Bool { consecutiveFailures >= Self.failureLimit }
    var retryDue: Bool { !retriesStopped && now() >= retryAt }

    var stoppedMessage: String? {
        guard retriesStopped, let lastError else { return nil }
        return "\(lastError)（同一错误已连续出现 \(Self.failureLimit) 次，已停止自动重试）"
    }

    func recheckAfterWake() {
        revision += 1
        healthyChecks = 0
    }

    func reset() {
        revision += 1
        lastFailure = nil
        previousFailureReason = nil
        consecutiveFailures = 0
        retryAt = 0
        failures = 0
        healthyChecks = 0
    }

    var retrySeconds: Int { max(0, Int(ceil(retryAt - now()))) }

    func tick(enabled: Bool, paused: Bool, limitRepeatedFailures: Bool = true, prepare: () async throws -> Void,
              activate: () async throws -> Void) async {
        guard !busy else { return }
        if paused || enabled { reset(); return }
        guard retryDue else { return }
        busy = true
        defer { busy = false }
        let generation = revision
        do {
            try await prepare()
            guard generation == revision, !Task.isCancelled else { return }
            if authorizationIssue != nil { lastFailure = nil }
            healthyChecks += 1
            if healthyChecks >= 2 {
                try await activate()
                guard generation == revision, !Task.isCancelled else { return }
                reset()
            }
        } catch {
            guard generation == revision, !Task.isCancelled else { return }
            recordFailure(error, limitRepeatedFailures: limitRepeatedFailures)
        }
    }

    func recordFailure(_ error: Error, limitRepeatedFailures: Bool = true) {
        let reason = error.localizedDescription
        if limitRepeatedFailures {
            consecutiveFailures = reason == previousFailureReason ? consecutiveFailures + 1 : 1
            previousFailureReason = reason
        }
        healthyChecks = 0
        // A silent recheck cannot change the outcome of the last authorization dialog.
        if authorizationIssue != .cancelled || (error as? DNSHelperAuthorizationError) != .required {
            lastFailure = error
        }
        let delays: [TimeInterval] = [2, 5, 10, 30, 60]
        retryAt = retriesStopped ? 0 : now() + delays[min(failures, delays.count - 1)]
        failures += 1
    }
}
