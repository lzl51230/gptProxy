import Foundation

/// Swift lifetime/async adapter; all sockets and forwarding live in the shared Rust core.
public final class TCPRelay: @unchecked Sendable {
    private let core = RustCore()
    private let requestedPort: UInt16
    private let upstreamPort: UInt16
    private let lock = NSLock()
    private var started = false
    private var stopping = false
    private var port: UInt16 = 0
    public init(listenPort: UInt16, upstreamPort: UInt16) {
        requestedPort = listenPort; self.upstreamPort = upstreamPort
    }
    public var boundPort: UInt16 { lock.withLock { port } }
    public var isReady: Bool { lock.withLock { port != 0 && !stopping } }
    public func start() async throws {
        try await Task.detached { [self] in
            try lock.withLock {
                guard !started, !stopping else { throw RelayError.alreadyStarted }
                started = true
                port = try core.call(["op":"relayStart", "listenPort":requestedPort, "upstreamPort":upstreamPort])
            }
        }.value
    }
    public func stop() {
        lock.withLock {
            stopping = true; port = 0
            let _: Int? = try? core.nullable(["op":"relayStop"])
        }
    }
    public func stopAndWait() async { await Task.detached { [self] in stop() }.value }
}
public enum RelayError: LocalizedError {
    case alreadyStarted, missingBoundPort, cancelledBeforeReady
    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "中继实例已启动或停止，请创建新实例。"
        case .missingBoundPort: "中继已启动，但系统没有返回监听端口。"
        case .cancelledBeforeReady: "中继在开始监听前已停止。"
        }
    }
}
