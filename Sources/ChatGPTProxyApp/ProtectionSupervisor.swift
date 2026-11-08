import Foundation

@MainActor
final class ProtectionSupervisor {
    private(set) var lastError: String?
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
        lastError = nil
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
            healthyChecks += 1
            if healthyChecks >= 2 {
                try await activate()
                guard generation == revision, !Task.isCancelled else { return }
                reset()
            }
        } catch {
            guard generation == revision, !Task.isCancelled else { return }
            healthyChecks = 0
            lastError = error.localizedDescription
            let delays: [TimeInterval] = [2, 5, 10, 30, 60]
            retryAt = now() + delays[min(failures, delays.count - 1)]
            failures += 1
        }
    }
}
