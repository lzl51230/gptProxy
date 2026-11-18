import Foundation

@MainActor
final class ProtectionSupervisor {
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

    func reset() {
        revision += 1
        lastFailure = nil
        retryAt = 0
        failures = 0
        healthyChecks = 0
    }

    var retrySeconds: Int { max(0, Int(ceil(retryAt - now()))) }

    func tick(enabled: Bool, paused: Bool, prepare: () async throws -> Void,
              activate: () async throws -> Void) async {
        guard !busy else { return }
        if paused || enabled { reset(); return }
        guard now() >= retryAt else { return }
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
            recordFailure(error)
        }
    }

    func recordFailure(_ error: Error) {
        healthyChecks = 0
        // A silent recheck cannot change the outcome of the last authorization dialog.
        if authorizationIssue != .cancelled || (error as? DNSHelperAuthorizationError) != .required {
            lastFailure = error
        }
        let delays: [TimeInterval] = [2, 5, 10, 30, 60]
        retryAt = now() + delays[min(failures, delays.count - 1)]
        failures += 1
    }
}
