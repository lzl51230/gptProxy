import Foundation
import XCTest
@testable import ChatGPTProxyCore

final class CodexConnectionTests: XCTestCase, @unchecked Sendable {
    func testSamePhysicalTLSConnectionReusedWithoutCredentialsAndCloseReleasesIt() async throws {
        let f = try CodexProbeFixture(); let clock = MonitorTestClock(); let session = f.session(clock: clock)
        for step in [0, 2, 8, 8, 8, 8, 8, 8, 8, 2] {
            clock.advance(.seconds(step))
            let result = try await session.heartbeat()
            XCTAssertTrue(result.isHealthy, result.failureReason ?? "")
        }
        let result = try await session.heartbeat(); XCTAssertEqual(result.connectionSeconds, 60)
        await session.close()
        let rows = try await f.waitForRows(13)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "connected" }.count, 1)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "closed" }.count, 1)
        let requests = rows.compactMap { $0["request"] as? String }
        XCTAssertEqual(requests.count, 11)
        for request in requests {
            XCTAssertTrue(request.hasPrefix("GET /test HTTP/1.1"))
            XCTAssertFalse(request.lowercased().contains("authorization:"))
            XCTAssertFalse(request.lowercased().contains("cookie:"))
        }
        XCTAssertEqual(rows.first?["host"] as? String, "probe.invalid", "SOCKS must resolve the hostname")
    }

    func testUnexpectedStatusesFailWithoutFollowingRedirects() async throws {
        for status in [200, 302, 403, 429, 503] {
            let f = try CodexProbeFixture(status: status); let session = f.session()
            let result = try await session.heartbeat()
            XCTAssertFalse(result.isHealthy)
            XCTAssertTrue(result.failureReason?.contains(String(status)) == true)
            await session.close()
            let rows = try await f.waitForRows(3)
            XCTAssertEqual(rows.filter { $0["request"] != nil }.count, 1)
        }
    }

    func testUntrustedCertificateIsRejected() async throws {
        let f = try CodexProbeFixture()
        let session = CodexConnectionSession(port: f.port, target: f.target)
        let result = try await session.heartbeat(); XCTAssertFalse(result.isHealthy)
        await session.close()
        XCTAssertTrue(f.rows.compactMap { $0["request"] }.isEmpty)
    }

    func testTransparentReconnectFailsAndNewSessionRestartsAge() async throws {
        let f = try CodexProbeFixture(mode: "drop"); let clock = MonitorTestClock(); let session = f.session(clock: clock)
        let first = try await session.heartbeat(); XCTAssertTrue(first.isHealthy)
        clock.advance(.seconds(2))
        let second = try await session.heartbeat()
        XCTAssertFalse(second.isHealthy); XCTAssertEqual(second.connectionSeconds, 0)
        let third = try await session.heartbeat()
        XCTAssertTrue(third.isHealthy); XCTAssertEqual(third.connectionSeconds, 0)
        await session.close()
        let rows = try await f.waitForRows(6)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "connected" }.count, 2)
    }

    func testConnectionCloseAndOversizedOrIncompleteBodiesAreFailures() async throws {
        for mode in ["close", "large", "partial"] {
            let f = try CodexProbeFixture(mode: mode); let session = f.session()
            let result = try await session.heartbeat(); XCTAssertFalse(result.isHealthy, mode)
            await session.close()
        }
    }

    func testSilentResponseTimesOutAfterTenSeconds() async throws {
        let f = try CodexProbeFixture(mode: "silent"); let session = f.session(); let start = ContinuousClock.now
        let result = try await session.heartbeat(); XCTAssertFalse(result.isHealthy)
        XCTAssertGreaterThanOrEqual((ContinuousClock.now - start).seconds, 9.8)
        XCTAssertLessThan((ContinuousClock.now - start).seconds, 12)
        await session.close()
    }

    func testCancellationClosesInFlightSocketPromptly() async throws {
        let f = try CodexProbeFixture(mode: "silent"); let session = f.session()
        let task = Task { try await session.heartbeat() }; _ = try await f.waitForRows(2)
        let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        await session.close()
        XCTAssertLessThan((ContinuousClock.now - start).seconds, 2)
        _ = try await f.waitForRows(3)
    }

    func testSilenceDeadlineUsesLastValidHeartbeat() async throws {
        let f = try CodexProbeFixture(); let clock = MonitorTestClock(); let session = f.session(clock: clock)
        _ = try await session.heartbeat(); clock.advance(.seconds(10))
        let result = try await session.heartbeat()
        XCTAssertFalse(result.isHealthy); XCTAssertTrue(result.failureReason?.contains("10 秒") == true)
        let next = try await session.heartbeat(); XCTAssertTrue(next.isHealthy); XCTAssertEqual(next.connectionSeconds, 0)
        await session.close()
    }

    func testStartupRequiresBothUDPAndOneCodexHeartbeat() async throws {
        let f = try CodexProbeFixture()
        let health = try await ProxyHealthChecker.check(port: f.port, connection: f.session())
        XCTAssertTrue(health.supportsUDP); XCTAssertGreaterThan(health.codexLatencyMilliseconds, 0)
        let rows = try await f.waitForRows(4)
        XCTAssertEqual(rows.filter { $0["request"] != nil }.count, 1)
        let rejected = try CodexProbeFixture(status: 403)
        do {
            _ = try await ProxyHealthChecker.check(port: rejected.port, connection: rejected.session())
            XCTFail("Unexpected Codex response must block startup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
    }

    func testUDPRejectionStillBlocksStartup() async throws {
        let f = try CodexProbeFixture(mode: "no-udp")
        do {
            _ = try await ProxyHealthChecker.check(port: f.port, connection: f.session())
            XCTFail("UDP rejection must still block startup")
        } catch { XCTAssertTrue(error.localizedDescription.contains("UDP")) }
        XCTAssertTrue(f.rows.compactMap { $0["request"] }.isEmpty)
    }
}

private final class CodexProbeFixture: @unchecked Sendable {
    let root: URL
    let process: Process
    let port: UInt16
    let target = "https://probe.invalid/test"
    var rows: [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    init(status: Int = 401, mode: String = "normal") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=ext
        prompt=no
        [dn]
        CN=probe.invalid
        [ext]
        subjectAltName=DNS:probe.invalid
        basicConstraints=critical,CA:TRUE
        keyUsage=critical,digitalSignature,keyCertSign,keyEncipherment
        extendedKeyUsage=serverAuth
        """.write(to: config, atomically: true, encoding: .utf8)
        let openssl = Process(); openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", config.path,
                             "-keyout", root.appendingPathComponent("key.pem").path, "-out", root.appendingPathComponent("cert.pem").path]
        openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
        try openssl.run(); openssl.waitUntilExit()
        guard openssl.terminationStatus == 0 else { throw MonitorError.message("Test certificate generation failed") }
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.server, root.path, String(status), mode]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        var bound: UInt16?
        for _ in 0..<400 {
            if let text = try? String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8), let value = UInt16(text) { bound = value; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let bound else { process.terminate(); throw MonitorError.message("Test SOCKS server did not bind") }
        port = bound
    }
    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    func session(clock: MonitorTestClock = MonitorTestClock()) -> CodexConnectionSession {
        CodexConnectionSession(port: port, target: target, caFile: root.appendingPathComponent("cert.pem").path, now: { clock.now() })
    }
    func waitForRows(_ count: Int) async throws -> [[String: Any]] {
        for _ in 0..<400 {
            if rows.count >= count { return rows }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MonitorError.message("Expected \(count) fixture events, got \(rows.count)")
    }
    private static let server = #"""
import socket,ssl,sys,json,pathlib,threading
root=pathlib.Path(sys.argv[1]); status=int(sys.argv[2]); mode=sys.argv[3]
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(str(root/'cert.pem'),str(root/'key.pem'))
lock=threading.Lock()
def event(**row):
 with lock:
  with (root/'events').open('a') as f: f.write(json.dumps(row)+'\n')
def exact(c,n):
 data=b''
 while len(data)<n:
  chunk=c.recv(n-len(data))
  if not chunk: raise EOFError()
  data+=chunk
 return data
def handle(c):
 connected=False
 try:
  version,count=exact(c,2); exact(c,count); c.sendall(b'\x05\x00')
  version,cmd,_,atyp=exact(c,4)
  host=exact(c,exact(c,1)[0]).decode() if atyp==3 else socket.inet_ntoa(exact(c,4))
  exact(c,2)
  if cmd==3:
   c.sendall(bytes([5,7 if mode=='no-udp' else 0,0,1,127,0,0,1,0,1])); event(event='udp'); return
  assert cmd==1 and host=='probe.invalid'
  c.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
  c=ctx.wrap_socket(c,server_side=True); connected=True; event(event='connected',host=host)
  while True:
   data=b''
   while b'\r\n\r\n' not in data: data+=exact(c,1)
   event(event='request',request=data.decode())
   if mode=='silent':
    while c.recv(1024): pass
    return
   body=b'x'*65537 if mode=='large' else b'{}'
   headers=f'HTTP/1.1 {status} Probe\r\nContent-Length: {len(body)}\r\nLocation: https://redirect.invalid/\r\n'
   if mode=='close': headers+='Connection: close\r\n'
   c.sendall(headers.encode()+b'\r\n'+(body[:1] if mode=='partial' else body))
   if mode in ['drop','close','partial']: return
 except (OSError,EOFError,ssl.SSLError): pass
 finally:
  c.close()
  if connected: event(event='closed')
s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); (root/'port').write_text(str(s.getsockname()[1]))
while True:
 c,_=s.accept(); threading.Thread(target=handle,args=(c,),daemon=True).start()
"""#
}
