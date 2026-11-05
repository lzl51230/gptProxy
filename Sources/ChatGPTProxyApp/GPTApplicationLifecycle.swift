import Foundation

@MainActor
enum GPTApplicationLifecycle {
    nonisolated static let terminationTimeout: TimeInterval = 15

    static func restart(requestTermination: () -> Void, isRunning: () -> Bool,
                        launch: () async throws -> Void, checkCancellation: () throws -> Void,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) async throws {
        try checkCancellation()
        requestTermination()
        let deadline = now() + terminationTimeout
        while isRunning() {
            try checkCancellation()
            guard now() < deadline else { throw AppError.chatGPTDidNotTerminate }
            try await pause()
        }
        try checkCancellation()
        try await launch()
    }
}
