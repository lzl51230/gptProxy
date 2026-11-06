import Foundation

/// Lifetime adapter for the shared, dual-stack Rust DNS frontend.
public final class DNSForwarder: @unchecked Sendable {
    private let core = RustCore()
    private let lock = NSLock()
    private let listenPort: UInt16, upstreamPort: UInt16
    private var port: UInt16 = 0
    public var boundPort: UInt16 { lock.withLock { port } }
    public init(listenPort: UInt16 = 53, upstreamPort: UInt16 = 17853) {
        self.listenPort = listenPort; self.upstreamPort = upstreamPort
    }
    public func start() async throws {
        try lock.withLock {
            port = try core.call(["op":"dnsStart", "listenPort":listenPort, "upstreamPort":upstreamPort])
        }
    }
    public func stop() async {
        lock.withLock {
            let _: Bool? = try? core.call(["op":"dnsStop"])
            port = 0
        }
    }
}
