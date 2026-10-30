import ChatGPTProxyCore
import Foundation

@MainActor
protocol ManagedRelay: AnyObject, Sendable {
    var isReady: Bool { get }
    func start() async throws
    func stopAndWait() async
}

extension TCPRelay: ManagedRelay {}

/// Serializes startup across the initial background task and launch button.
@MainActor
final class RelayLifecycle {
    private let makeRelay: (UInt16) -> any ManagedRelay
    private var relay: (instance: any ManagedRelay, upstreamPort: UInt16)?
    private var startup: (task: Task<Void, Error>, upstreamPort: UInt16)?

    init(makeRelay: @escaping (UInt16) -> any ManagedRelay = {
        TCPRelay(listenPort: ProxyConfiguration.relayPort, upstreamPort: $0)
    }) {
        self.makeRelay = makeRelay
    }

    func ensureRunning(upstreamPort: UInt16) async throws {
        while let pending = startup {
            if pending.upstreamPort == upstreamPort {
                try await pending.task.value
                return
            }
            _ = try? await pending.task.value
        }
        if let relay, relay.upstreamPort == upstreamPort, relay.instance.isReady { return }

        let task = Task { @MainActor in
            defer { startup = nil }
            if let previous = relay {
                await previous.instance.stopAndWait()
                relay = nil
            }
            let instance = makeRelay(upstreamPort)
            do {
                try await instance.start()
                relay = (instance, upstreamPort)
            } catch {
                await instance.stopAndWait()
                throw error
            }
        }
        startup = (task, upstreamPort)
        try await task.value
    }
}
