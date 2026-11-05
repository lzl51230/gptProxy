import Foundation
import Network
import Darwin
import ChatGPTProxyCore

final class DNSFrontend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.dns-tcp")
    private let cancellation = DispatchGroup()
    private let udp: DNSUDPFrontend
    private let upstreamPort: UInt16
    private var listener: NWListener?
    private var flows: [UUID: Flow] = [:]
    private var timer: DispatchSourceTimer?
    private var stopping = false
    var boundPort: UInt16 { udp.boundPort }
    private struct Flow {
        let client: NWConnection
        let upstream: NWConnection
        var lastActivity: Date
        var finishedDirections = 0
    }
    private final class Startup: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ error: Error? = nil) {
            lock.lock(); let current = continuation; continuation = nil; lock.unlock()
            if let error { current?.resume(throwing: error) } else { current?.resume() }
        }
    }

    init(listenPort: UInt16 = 53, upstreamPort: UInt16 = DNSProtectionConfiguration.clashDNSPort) {
        udp = DNSUDPFrontend(listenPort: listenPort, upstreamPort: upstreamPort)
        self.upstreamPort = upstreamPort
    }

    func start() async throws {
        do {
            try udp.start()
            // NWListener owns a dual-stack port. Restrict it to the loopback
            // interface and validate peers instead of making competing listeners.
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: "::", port: NWEndpoint.Port(rawValue: udp.boundPort)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionLimit = 256
            cancellation.enter()
            listener.newConnectionHandler = { [weak self] connection in
                if let self { self.accept(connection) } else { connection.cancel() }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let startup = Startup(continuation), cancellation = self.cancellation
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: startup.finish()
                    case .failed(let error): startup.finish(error); listener.cancel()
                    case .cancelled: listener.stateUpdateHandler = nil; startup.finish(CancellationError()); cancellation.leave()
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                for (id, flow) in self.flows where Date().timeIntervalSince(flow.lastActivity) >= 30 { self.finish(id) }
            }
            self.timer = timer; timer.resume()
        } catch { await stop(); throw error }
    }

    func stop() async {
        await udp.stop()
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopping = true
                self.timer?.cancel(); self.timer = nil
                self.listener?.cancel(); self.listener = nil
                for id in Array(self.flows.keys) { self.finish(id) }
                self.cancellation.notify(queue: self.queue) { continuation.resume() }
            }
        }
    }

    private func accept(_ client: NWConnection) {
        guard !stopping, flows.count < 256, case .hostPort(let host, _) = client.endpoint,
              Self.isLoopback(host) else { client.cancel(); return }
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        let id = UUID(), cancellation = self.cancellation
        cancellation.enter(); cancellation.enter()
        flows[id] = Flow(client: client, upstream: upstream, lastActivity: .now)
        client.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { client.stateUpdateHandler = nil; cancellation.leave() }
            if case .failed = state { self?.finish(id) }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { upstream.stateUpdateHandler = nil; cancellation.leave() }
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(id, source: client, destination: upstream)
                self.pump(id, source: upstream, destination: client)
            case .failed, .cancelled: self.finish(id)
            default: break
            }
        }
        client.start(queue: queue); upstream.start(queue: queue)
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address):
            return address == IPv6Address.loopback
                || address.rawValue.prefix(12) == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255]) && address.rawValue[12] == 127
        default: return false
        }
    }

    private func pump(_ id: UUID, source: NWConnection, destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.flows[id] != nil else { return }
            guard error == nil else { self.finish(id); return }
            self.flows[id]?.lastActivity = .now
            guard complete || data?.isEmpty == false else { self.pump(id, source: source, destination: destination); return }
            destination.send(content: data, contentContext: complete ? .finalMessage : .defaultStream,
                             isComplete: complete, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(id) }
                else if complete {
                    self.flows[id]?.finishedDirections += 1
                    if self.flows[id]?.finishedDirections == 2 { self.finish(id) }
                } else { self.pump(id, source: source, destination: destination) }
            })
        }
    }

    private func finish(_ id: UUID) {
        guard let flow = flows.removeValue(forKey: id) else { return }
        flow.client.cancel(); flow.upstream.cancel()
    }
}

/// UDP sockets are connectionless. A short-lived upstream socket per request
/// isolates transaction IDs and avoids NWConnection retaining an ICMP failure
/// when macOS immediately reuses a DNS client's ephemeral port.
private final class DNSUDPFrontend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.dns-udp")
    private let cancellation = DispatchGroup()
    private let requestedPort: UInt16, upstreamPort: UInt16
    private var listeners: [DispatchSourceRead] = []
    private var pending: [Int32: (source: DispatchSourceRead, deadline: Date)] = [:]
    private var timer: DispatchSourceTimer?
    private(set) var boundPort: UInt16 = 0

    init(listenPort: UInt16, upstreamPort: UInt16) { requestedPort = listenPort; self.upstreamPort = upstreamPort }

    func start() throws {
        for ipv6 in [false, true] {
            let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw MonitorError.message("无法创建 DNS UDP 入口") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var result: Int32
            let port = boundPort == 0 ? requestedPort : boundPort
            if ipv6 {
                var only: Int32 = 1
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_port = port.bigEndian; inet_pton(AF_INET6, "::1", &address.sin6_addr)
                result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            } else {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_port = port.bigEndian; inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
                result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                if result == 0 {
                    var actual = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
                    _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
                    boundPort = UInt16(bigEndian: actual.sin_port)
                }
            }
            guard result == 0 else { close(fd); throw MonitorError.message("DNS 53 端口已被其他服务占用") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            cancellation.enter()
            let cancellation = self.cancellation
            source.setCancelHandler { close(fd); cancellation.leave() }
            source.setEventHandler { [weak self] in self?.receive(on: fd) }
            listeners.append(source); source.resume()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (fd, request) in self.pending where request.deadline <= .now { self.finish(fd) }
        }
        self.timer = timer; timer.resume()
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer?.cancel(); self.timer = nil
                self.listeners.forEach { $0.cancel() }; self.listeners.removeAll()
                for fd in Array(self.pending.keys) { self.finish(fd) }
                self.cancellation.notify(queue: self.queue) { self.boundPort = 0; continuation.resume() }
            }
        }
    }

    private func receive(on listener: Int32) {
        while true {
            var bytes = [UInt8](repeating: 0, count: 65535), sender = sockaddr_storage()
            var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(listener, &bytes, bytes.count, 0, $0, &size) } }
            guard count > 0 else { return }
            guard count >= 12, pending.count < 256 else { continue }
            forward(Data(bytes.prefix(count)), sender: sender, senderSize: size, listener: listener)
        }
    }

    private func forward(_ query: Data, sender: sockaddr_storage, senderSize: socklen_t, listener: Int32) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = upstreamPort.bigEndian; inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { close(fd); return }
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress!, query.count, 0) }
        guard sent == query.count else { close(fd); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        cancellation.enter()
        let cancellation = self.cancellation
        source.setCancelHandler { close(fd); cancellation.leave() }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65535)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count >= 12, buffer[0] == query[0], buffer[1] == query[1] {
                var destination = sender
                _ = withUnsafePointer(to: &destination) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(listener, buffer, count, 0, $0, senderSize) } }
            }
            self.finish(fd)
        }
        pending[fd] = (source, .now.addingTimeInterval(5))
        source.resume()
    }

    private func finish(_ fd: Int32) { pending.removeValue(forKey: fd)?.source.cancel() }
}
