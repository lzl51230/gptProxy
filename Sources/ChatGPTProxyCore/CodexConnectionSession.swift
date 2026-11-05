import CCodexTransport
import Foundation

public struct CodexHeartbeat: Sendable, Equatable {
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

/// The worker owns libcurl; cancellation only shuts down its socket under a lock.
/// A session can open exactly one socket, so libcurl cannot silently reconnect.
public final class CodexConnectionSession: CodexConnection, @unchecked Sendable {
    public static let targetURL = "https://chatgpt.com/backend-api/codex/models"
    private let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.codex-connection", qos: .utility)
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var cancelled = false
    private var firstHeartbeat: ContinuousClock.Instant?
    private var lastHeartbeat: ContinuousClock.Instant?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let proxy: String
    private let target: String
    private let caFile: String?

    public convenience init(port: UInt16) {
        self.init(port: port, target: Self.targetURL)
    }

    init(port: UInt16, target: String, caFile: String? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        proxy = "socks5h://127.0.0.1:\(port)"
        self.target = target
        self.caFile = caFile
        self.now = now
    }

    deinit { if let handle { cgp_codex_destroy(handle) } }

    public func heartbeat() async throws -> CodexHeartbeat {
        try Task.checkCancellation()
        let heartbeat: CodexHeartbeat = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.performHeartbeat()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
        return heartbeat
    }

    private func performHeartbeat() throws -> CodexHeartbeat {
        let remaining = lastHeartbeat.map { $0.advanced(by: .seconds(10)) - now() } ?? .seconds(10)
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        if remaining <= .zero {
            lock.unlock()
            return failed("连续 10 秒未收到有效心跳")
        }
        if handle == nil { handle = cgp_codex_create(proxy, target, caFile) }
        let connection = handle
        lock.unlock()
        guard let connection else { return failed("无法创建 Codex 检测连接") }
        let result = cgp_codex_heartbeat(connection, max(1, Int(remaining.seconds * 1000)))
        if result == 2 { throw CancellationError() }
        if result != 0 { return failed(String(cString: cgp_codex_error(connection))) }
        let instant = now()
        firstHeartbeat = firstHeartbeat ?? instant
        lastHeartbeat = instant
        return CodexHeartbeat(isHealthy: true, latencyMilliseconds: Int(cgp_codex_latency_ms(connection)),
                              connectionSeconds: (instant - firstHeartbeat!).seconds)
    }

    private func failed(_ reason: String) -> CodexHeartbeat {
        let seconds = firstHeartbeat.flatMap { first in lastHeartbeat.map { ($0 - first).seconds } } ?? 0
        disposeHandle()
        firstHeartbeat = nil
        lastHeartbeat = nil
        return CodexHeartbeat(isHealthy: false, connectionSeconds: seconds, failureReason: reason)
    }

    private func disposeHandle() {
        lock.lock()
        if let handle { cgp_codex_destroy(handle); self.handle = nil }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        if let handle { cgp_codex_cancel(handle) }
        lock.unlock()
    }

    public func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { self.disposeHandle(); continuation.resume() }
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
