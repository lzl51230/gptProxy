import XCTest
import Darwin
import ChatGPTProxyCore
@testable import DNSProtectionHelper

final class DNSFrontendTests: XCTestCase, @unchecked Sendable {
    func testTCPAndUDPReachTheSameUpstreamAndRebindAfterStop() async throws {
        let fixture = try DNSFixture()
        defer { fixture.stop() }
        let relay = DNSFrontend(listenPort: 0, upstreamPort: fixture.port)
        try await relay.start()
        let port = relay.boundPort
        try await Task.detached {
            try DNSPacket.probe(port: port)
            try DNSPacket.probe(port: port, tcp: true)
            try DNSPacket.probe(port: port, host: "::1")
            try DNSPacket.probe(port: port, tcp: true, host: "::1")
        }.value
        await relay.stop()
        let replacement = DNSFrontend(listenPort: port, upstreamPort: fixture.port)
        try await replacement.start()
        try await Task.detached { try DNSPacket.probe(port: port) }.value
        await replacement.stop()
    }

    func testUDPClientsWithIdenticalIDsReceiveOnlyTheirOwnAnswers() async throws {
        let fixture = try DNSFixture()
        defer { fixture.stop() }
        let relay = DNSFrontend(listenPort: 0, upstreamPort: fixture.port)
        try await relay.start()
        let port = relay.boundPort
        do { try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let query = DNSPacket.query(name: "client-\(index).example.com", id: 42)
                    // Blocking recv on 20 cooperative-executor threads starves
                    // Network.framework's callbacks; run fixture I/O on Dispatch.
                    let response: Data = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            do { continuation.resume(returning: try exchange(query, port: port)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                    XCTAssertTrue(DNSPacket.isValidResponse(response, to: query))
                }
            }
            try await group.waitForAll()
        } } catch {
            await relay.stop()
            throw error
        }
        await relay.stop()
    }

    func testLargePipelinedTCPResponsesPreserveFraming() async throws {
        let fixture = try DNSFixture()
        defer { fixture.stop() }
        let relay = DNSFrontend(listenPort: 0, upstreamPort: fixture.port)
        try await relay.start()
        let port = relay.boundPort
        let queries = [Data(repeating: 1, count: 60_000), DNSPacket.query(name: "example.com", id: 8)]
        try await Task.detached {
            let replies = try tcpExchange(queries, port: port)
            XCTAssertEqual(replies.count, queries.count)
            for (reply, query) in zip(replies, queries) {
                XCTAssertEqual(reply.count, query.count)
                XCTAssertEqual(reply.suffix(from: 4), query.suffix(from: 4))
            }
        }.value
        await relay.stop()
    }

    func testClientHalfCloseStillReceivesDNSAnswer() async throws {
        let fixture = try DNSFixture(halfClose: true)
        defer { fixture.stop() }
        let relay = DNSFrontend(listenPort: 0, upstreamPort: fixture.port)
        try await relay.start()
        let port = relay.boundPort
        try await Task.detached {
            let query = DNSPacket.query(name: "example.com", id: 11)
            let replies = try tcpExchange([query], port: port, halfClose: true)
            XCTAssertTrue(DNSPacket.isValidResponse(replies[0], to: query))
        }.value
        await relay.stop()
    }
}

private enum FixtureError: Error { case io }

private func connection(port: UInt16, tcp: Bool) throws -> Int32 {
    let fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
    guard fd >= 0 else { throw FixtureError.io }
    DNSProtectionIPC.configure(fd, seconds: 5)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { close(fd); throw FixtureError.io }
    return fd
}

private func exchange(_ query: Data, port: UInt16) throws -> Data {
    let fd = try connection(port: port, tcp: false)
    defer { close(fd) }
    let sent = query.withUnsafeBytes { send(fd, $0.baseAddress!, query.count, 0) }
    guard sent == query.count else { throw FixtureError.io }
    var buffer = [UInt8](repeating: 0, count: 65535)
    let size = recv(fd, &buffer, buffer.count, 0)
    guard size > 0 else { throw FixtureError.io }
    return Data(buffer.prefix(size))
}

private func tcpExchange(_ queries: [Data], port: UInt16, halfClose: Bool = false) throws -> [Data] {
    let fd = try connection(port: port, tcp: true)
    defer { close(fd) }
    var payload = Data()
    for query in queries { payload.append(contentsOf: [UInt8(query.count >> 8), UInt8(query.count & 255)]); payload.append(query) }
    var offset = 0
    while offset < payload.count {
        let count = payload.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), payload.count - offset, 0) }
        guard count > 0 else { throw FixtureError.io }
        offset += count
    }
    if halfClose { shutdown(fd, SHUT_WR) }
    func read(_ size: Int) throws -> Data {
        var result = Data()
        while result.count < size {
            var buffer = [UInt8](repeating: 0, count: size - result.count)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw FixtureError.io }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    return try queries.map { _ in
        let size = try read(2)
        return try read(Int(size[0]) << 8 | Int(size[1]))
    }
}

private final class DNSFixture {
    let process = Process()
    let port: UInt16
    init(halfClose: Bool = false) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, halfClose ? "half" : "normal"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard let value = byte.first else { process.terminate(); throw FixtureError.io }
            if value == 10 { break }
            line.append(value)
        }
        guard let port = UInt16(String(decoding: line, as: UTF8.self)) else { process.terminate(); throw FixtureError.io }
        self.port = port
    }
    func stop() {
        // Foundation's waitUntilExit can wait on a different thread's run loop
        // in async XCTest. Reap this fixture directly instead.
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(process.processIdentifier, &status, 0)
        }
    }
    static let script = #"""
import socket, struct, threading, sys
t=socket.socket(); t.bind(('127.0.0.1',0)); t.listen()
port=t.getsockname()[1]
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.bind(('127.0.0.1',port))
print(port,flush=True)
def answer(q):
 b=bytearray(q); b[2]=0x81; b[3]=0x83; return bytes(b)
def udp():
 while True:
  q,a=u.recvfrom(65535); u.sendto(answer(q),a)
def read(c,n):
 b=b''
 while len(b)<n:
  x=c.recv(n-len(b))
  if not x: return None
  b+=x
 return b
def tcp(c):
 try:
  while True:
   n=read(c,2)
   if not n: return
   q=read(c,struct.unpack('!H',n)[0])
   if q is None: return
   if sys.argv[1]=='half':
    while c.recv(1024): pass
   q=answer(q); c.sendall(struct.pack('!H',len(q))+q)
   if sys.argv[1]=='half': return
 finally: c.close()
threading.Thread(target=udp,daemon=True).start()
while True:
 c,_=t.accept(); threading.Thread(target=tcp,args=(c,),daemon=True).start()
"""#
}
