import Foundation

/// Roll back independent resources even if one is temporarily unavailable.
/// The caller retains its journal until all throwing steps have succeeded.
struct DNSRecoveryActions: Sendable {
    var firewall: @Sendable () async throws -> Void
    var systemDNS: @Sendable () async throws -> Void
    var reference: @Sendable () async throws -> Void
    var clash: @Sendable () async throws -> Void
    var frontend: @Sendable () async -> Void
    var cache: @Sendable () async -> Void

    func perform() async -> [String] {
        var errors: [String] = []
        for step in [firewall, systemDNS, reference, clash] {
            do { try await step() }
            catch { errors.append(error.localizedDescription) }
        }
        await frontend()
        await cache()
        return errors
    }
}
