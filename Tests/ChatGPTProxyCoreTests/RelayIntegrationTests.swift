import Foundation
import Network
import XCTest
@testable import ChatGPTProxyCore

final class RelayIntegrationTests: XCTestCase {
    func testRelayForwardsBytesInBothDirections() async throws {
        let upstream = try EchoServer()
        try await upstream.start()
        defer { upstream.stop() }

        let relay = TCPRelay(listenPort: 0, upstreamPort: upstream.port)
        try await relay.start()
        defer { relay.stop() }

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: relay.boundPort)!,
            using: .tcp
        )
        client.start(queue: DispatchQueue.global())
        defer { client.cancel() }

        try await client.waitUntilReady()
        try await client.send(Data("ping".utf8))
        let response = try await client.receiveExactly(4)
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "ping")
    }

    func testRelayReturnsUpstreamResponseAfterClientHalfClosesWriteSide() async throws {
        let upstream = try HalfCloseResponseServer(response: Data("pong".utf8))
        try await upstream.start()
        defer { upstream.stop() }

        let relay = TCPRelay(listenPort: 0, upstreamPort: upstream.port)
        try await relay.start()
        defer { relay.stop() }

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: relay.boundPort)!,
            using: .tcp
        )
        client.start(queue: DispatchQueue.global())
        defer { client.cancel() }

        try await client.waitUntilReady()
        try await client.send(Data("request".utf8), isComplete: true)
        let response = try await client.receiveExactly(4, timeout: 2)

        XCTAssertEqual(String(decoding: response, as: UTF8.self), "pong")
    }
}

private final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.echo-server")

    var port: UInt16 {
        listener.port!.rawValue
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            self.echo(connection)
        }
        listener.start(queue: queue)
        try await listener.waitUntilReady()
    }

    func stop() {
        listener.cancel()
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in
                    self.echo(connection)
                })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.echo(connection)
            }
        }
    }
}

private final class HalfCloseResponseServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private let queue = DispatchQueue(label: "test.half-close-response-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    var port: UInt16 {
        listener.port!.rawValue
    }

    init(response: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.response = response
    }

    func start() async throws {
        listener.newConnectionHandler = { connection in
            self.lock.withLock {
                self.connections.append(connection)
            }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection)
        }
        listener.start(queue: queue)
        try await listener.waitUntilReady()
    }

    func stop() {
        listener.cancel()
        let currentConnections = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        currentConnections.forEach { $0.cancel() }
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if error != nil {
                connection.cancel()
            } else if complete {
                connection.send(
                    content: self.response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { sendError in
                        if sendError != nil {
                            connection.cancel()
                        }
                    }
                )
            } else if data != nil {
                self.receiveRequest(on: connection)
            }
        }
    }
}

private extension NWListener {
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = TestContinuation(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.resume(returning: ())
                case let .failed(error):
                    completion.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }
}

private extension NWConnection {
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = TestContinuation(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.resume(returning: ())
                case let .failed(error):
                    completion.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }

    func send(_ data: Data, isComplete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func receiveExactly(_ length: Int, timeout: TimeInterval? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    self.cancel()
                }
            }
            receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}

private final class TestContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        finish(with: .success(value))
    }

    func resume(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Value, Error>) {
        let current = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { continuation = nil }
            return continuation
        }
        current?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
