import Foundation
import Network

public final class TCPRelay: @unchecked Sendable {
    private let requestedPort: NWEndpoint.Port
    private let upstreamPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "local.chatgpt-proxy.relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pairs: [UUID: RelayPair] = [:]
    private var storedBoundPort: UInt16 = 0
    private var stopping = false
    private var started = false
    private let cancellation = DispatchGroup()

    public var isReady: Bool {
        lock.withLock { storedBoundPort != 0 && !stopping }
    }

    public var boundPort: UInt16 {
        lock.withLock { storedBoundPort }
    }

    public init(listenPort: UInt16, upstreamPort: UInt16) {
        requestedPort = NWEndpoint.Port(rawValue: listenPort)!
        self.upstreamPort = NWEndpoint.Port(rawValue: upstreamPort)!
    }

    public func start() async throws {
        let cancellation = self.cancellation
        let mayStart = lock.withLock { () -> Bool in
            guard !started, !stopping else { return false }
            started = true
            cancellation.enter()
            return true
        }
        guard mayStart else { throw RelayError.alreadyStarted }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
        let newListener: NWListener
        do { newListener = try NWListener(using: parameters) }
        catch { cancellation.leave(); throw error }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = OneShotContinuation(continuation)
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = newListener.port else {
                        completion.fail(RelayError.missingBoundPort)
                        return
                    }
                    let ready = self.lock.withLock { () -> Bool in
                        guard !self.stopping else { return false }
                        self.storedBoundPort = port.rawValue
                        return true
                    }
                    if ready { completion.succeed() }
                    else { completion.fail(RelayError.cancelledBeforeReady) }
                case let .failed(error):
                    self?.lock.withLock { self?.storedBoundPort = 0 }
                    newListener.cancel()
                    completion.fail(error)
                case .cancelled:
                    self?.lock.withLock { self?.storedBoundPort = 0 }
                    newListener.stateUpdateHandler = nil
                    cancellation.leave()
                    completion.fail(RelayError.cancelledBeforeReady)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                if let self { self.accept(connection) }
                else { connection.cancel() }
            }
            let shouldCancel = lock.withLock { () -> Bool in
                listener = newListener
                return stopping
            }
            newListener.start(queue: queue)
            if shouldCancel { newListener.cancel() }
        }
    }

    public func stop() {
        let state = lock.withLock { () -> (NWListener?, [RelayPair]) in
            stopping = true
            let currentListener = listener
            listener = nil
            storedBoundPort = 0
            let currentPairs = Array(pairs.values)
            pairs.removeAll()
            return (currentListener, currentPairs)
        }
        state.0?.cancel()
        state.1.forEach { $0.stop() }
    }

    /// Returns only after the listener and all accepted sockets have cancelled.
    public func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            cancellation.notify(queue: .global()) { continuation.resume() }
        }
    }

    private func accept(_ client: NWConnection) {
        let identifier = UUID()
        let upstream = NWConnection(host: "127.0.0.1", port: upstreamPort, using: .tcp)
        let pair = RelayPair(client: client, upstream: upstream, queue: queue, cancellation: cancellation) { [weak self] in
            _ = self?.lock.withLock {
                self?.pairs.removeValue(forKey: identifier)
            }
        }
        lock.withLock {
            guard !stopping else { client.cancel(); return }
            pairs[identifier] = pair
            pair.start()
        }
    }
}

public enum RelayError: LocalizedError {
    case alreadyStarted
    case missingBoundPort
    case cancelledBeforeReady

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "中继实例已启动或停止，请创建新实例。"
        case .missingBoundPort:
            "中继已启动，但系统没有返回监听端口。"
        case .cancelledBeforeReady:
            "中继在开始监听前已停止。"
        }
    }
}

private final class OneShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        finish(with: .success(()))
    }

    func fail(_ error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        let current = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        current?.resume(with: result)
    }
}

private final class RelayPair: @unchecked Sendable {
    private enum Direction: Hashable {
        case clientToUpstream
        case upstreamToClient
    }

    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let onStop: @Sendable () -> Void
    private let cancellation: DispatchGroup
    private let lock = NSLock()
    private var stopped = false
    private var completedDirections: Set<Direction> = []

    init(
        client: NWConnection,
        upstream: NWConnection,
        queue: DispatchQueue,
        cancellation: DispatchGroup,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
        self.onStop = onStop
        self.cancellation = cancellation
    }

    func start() {
        let cancellation = self.cancellation
        cancellation.enter()
        cancellation.enter()
        client.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { cancellation.leave() }
            self?.handle(state)
        }
        upstream.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { cancellation.leave() }
            guard let self else { return }
            switch state {
            case .ready:
                self.forward(from: self.client, to: self.upstream, direction: .clientToUpstream)
                self.forward(from: self.upstream, to: self.client, direction: .upstreamToClient)
            case .failed, .cancelled:
                self.stop()
            default:
                break
            }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        client.cancel()
        upstream.cancel()
        onStop()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            stop()
        default:
            break
        }
    }

    private func forward(
        from source: NWConnection,
        to destination: NWConnection,
        direction: Direction
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil {
                self.stop()
                return
            }

            guard complete || data?.isEmpty == false else {
                self.forward(from: source, to: destination, direction: direction)
                return
            }

            destination.send(
                content: data,
                contentContext: complete ? .finalMessage : .defaultStream,
                isComplete: complete,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil {
                        self.stop()
                    } else if complete {
                        self.complete(direction)
                    } else {
                        self.forward(from: source, to: destination, direction: direction)
                    }
                }
            )
        }
    }

    private func complete(_ direction: Direction) {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            completedDirections.insert(direction)
            return completedDirections.count == 2
        }
        if shouldStop {
            stop()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
