import Foundation

public struct CodexHeartbeat: Codable, Sendable, Equatable {
    public let isHealthy: Bool
    public let latencyMilliseconds: Int?
    /// Time between the first and most recent valid heartbeat on this physical connection.
    public let connectionSeconds: Double
    public let failureReason: String?

    public init(isHealthy: Bool, latencyMilliseconds: Int? = nil, connectionSeconds: Double = 0, failureReason: String? = nil) {
        self.isHealthy = isHealthy
        self.latencyMilliseconds = latencyMilliseconds
        self.connectionSeconds = connectionSeconds
        self.failureReason = failureReason
    }
}

protocol CodexConnection: Sendable {
    func heartbeat() async throws -> CodexHeartbeat
    func cancel()
    func close() async
}

/// Native lifetime adapter; the Rust core owns SOCKS, TLS, HTTP and observation timing.
public final class CodexConnectionSession: CodexConnection, @unchecked Sendable {
    public static let targetURL = "https://chatgpt.com/backend-api/codex/models"
    private let core = RustCore()
    private let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.codex-connection", qos: .utility)
    private let lock = NSLock()
    private var opened = false
    private var cancelled = false
    private let now: (@Sendable () -> ContinuousClock.Instant)?
    private let origin: ContinuousClock.Instant?
    private let port: UInt16
    private let target: String
    private let caFile: String?

    public convenience init(port: UInt16) { self.init(port: port, target: Self.targetURL) }
    init(port: UInt16, target: String, caFile: String? = nil, now: (@Sendable () -> ContinuousClock.Instant)? = nil) {
        self.port = port; self.target = target; self.caFile = caFile; self.now = now; origin = now?()
    }
    public func heartbeat() async throws -> CodexHeartbeat {
        try Task.checkCancellation()
        let result: CodexHeartbeat = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try self.lock.withLock {
                            guard !self.cancelled else { throw CancellationError() }
                            if !self.opened {
                                var request: [String: Any] = ["op":"heartbeatOpen", "port":self.port, "target":self.target]
                                if let caFile = self.caFile { request["caFile"] = caFile }
                                let _: Bool = try self.core.call(request)
                                self.opened = true
                            }
                        }
                        var request: [String:Any] = ["op":"heartbeat"]
                        if let now = self.now, let origin = self.origin { request["nowSeconds"] = (now() - origin).seconds }
                        let heartbeat: CodexHeartbeat = try self.core.call(request)
                        continuation.resume(returning: heartbeat)
                    } catch {
                        if self.lock.withLock({ self.cancelled }) { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
        return result
    }
    public func cancel() {
        lock.withLock {
            cancelled = true
            let _: Bool? = try? core.call(["op":"heartbeatCancel"])
        }
    }
    public func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                let _: Bool? = try? self.core.call(["op":"heartbeatClose"])
                continuation.resume()
            }
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
