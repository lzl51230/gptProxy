import Foundation

enum HelperEvents {
    // Keep Dispatch callbacks outside main()'s implicit MainActor isolation.
    // LaunchDaemon callbacks run on a background queue, including when idle.
    nonisolated static func watchdog(interval: TimeInterval = 5,
                                    action: @escaping @Sendable () async -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { @Sendable in Task { await action() } }
        timer.resume()
        return timer
    }
}
