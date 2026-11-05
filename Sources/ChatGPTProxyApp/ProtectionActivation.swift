import Foundation
import ChatGPTProxyCore

/// One transaction owns both the network policy and the application's old connections.
@MainActor
enum ProtectionActivation {
    static func run(launchGPT: Bool, isGPTRunning: () -> Bool,
                    enable: () async throws -> Void, restartGPT: () async throws -> Void,
                    restore: () async throws -> Void, checkCancellation: () throws -> Void) async throws {
        let restart = launchGPT || isGPTRunning()
        do {
            try checkCancellation()
            try await enable()
            try checkCancellation()
            if restart { try await restartGPT() }
            try checkCancellation()
        } catch {
            let failure = error
            do { try await restore() }
            catch {
                throw MonitorError.message("\(failure.localizedDescription)；恢复未完成：\(error.localizedDescription)")
            }
            throw failure
        }
    }
}
