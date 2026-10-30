import XCTest
@testable import ChatGPTProxyCore

private actor MonitorFixture {
    var current = "日本旧"
    var mode = "global"
    var probeDelay = 801
    var delays = ["日本旧": 900, "日本快": 100, "日本另一订阅": 1, "香港快": 1]
    var tested: [String] = []
    var selected: [String] = []
    var closed: [String] = []
    var manualChange = false
    var snapshotCount = 0
    func snapshot() throws -> ClashSnapshot {
        snapshotCount += 1
        if manualChange && snapshotCount > 1 { current = "日本另一订阅" }
        let data = try JSONSerialization.data(withJSONObject: [
            "GLOBAL": ["name": "GLOBAL", "type": "Selector", "now": current, "all": Array(delays.keys).sorted()],
            "日本旧": ["name": "日本旧", "type": "Shadowsocks"],
            "日本快": ["name": "日本快", "type": "Shadowsocks"],
            "日本另一订阅": ["name": "日本另一订阅", "type": "Shadowsocks"],
            "香港快": ["name": "香港快", "type": "Shadowsocks"],
        ])
        return ClashSnapshot(socket: "/fixture", mode: mode, proxies: try JSONDecoder().decode([String: ClashProxy].self, from: data))
    }
    func probe() -> Int { probeDelay }
    func delay(_ name: String) -> Int { tested.append(name); return delays[name]! }
    func select(_ name: String) { selected.append(name); current = name }
    func close(_ id: String) { closed.append(id) }
    func configure(probe: Int? = nil, mode: String? = nil, allSlow: Bool = false, manual: Bool = false) {
        if let probe { probeDelay = probe }
        if let mode { self.mode = mode }
        if allSlow { delays["日本快"] = 801 }
        manualChange = manual
    }
}

@MainActor
final class AutoSwitchMonitorTests: XCTestCase {
    private let defaultsSuite = "AutoSwitchMonitorTests.\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: defaultsSuite)!
    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }
    private func monitor(_ fixture: MonitorFixture, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> AutoSwitchMonitor {
        AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await fixture.snapshot() }, probe: { _ in await fixture.probe() },
            resolver: { NodeOriginResolver(origins: ["日本旧": "one", "日本快": "one", "香港快": "one", "日本另一订阅": "two"]) },
            delay: { _, name in await fixture.delay(name) }, select: { _, name in await fixture.select(name) },
            connections: { _, _ in ["old-connection"] }, close: { _, id in await fixture.close(id) }, now: now
        ), defaults: defaults)
    }

    func testSlowProbeSwitchesOnlyWithinSubscriptionAndRegionAndClosesOldConnections() async {
        let f = MonitorFixture(); let m = monitor(f)
        await m.tick()
        let selected = await f.selected; let tested = await f.tested; let closed = await f.closed
        XCTAssertEqual(selected, ["日本快"])
        XCTAssertEqual(Set(tested), ["日本旧", "日本快"])
        XCTAssertEqual(closed, ["old-connection"])
        await m.tick()
        let after = await f.tested
        XCTAssertEqual(after.count, 2, "Cooldown must suppress another round")
    }

    func testExactly800IsHealthy() async {
        let f = MonitorFixture(); await f.configure(probe: 800)
        await monitor(f).tick()
        let tested = await f.tested; XCTAssertTrue(tested.isEmpty)
    }

    func testNoEligibleNodeDoesNotCoolDown() async {
        let f = MonitorFixture(); await f.configure(allSlow: true)
        let m = monitor(f); await m.tick(); await m.tick()
        let selected = await f.selected; let tested = await f.tested
        XCTAssertTrue(selected.isEmpty); XCTAssertEqual(tested.count, 4)
    }

    func testManualSelectionDuringTestingIsPreserved() async {
        let f = MonitorFixture(); await f.configure(manual: true)
        await monitor(f).tick()
        let selected = await f.selected; XCTAssertTrue(selected.isEmpty)
    }

    func testRuleModeNeverSwitches() async {
        let f = MonitorFixture(); await f.configure(mode: "rule")
        await monitor(f).tick()
        let tested = await f.tested; XCTAssertTrue(tested.isEmpty)
    }

    func testPolicyBoundariesAndTiePreference() {
        XCTAssertEqual(AutoSwitchPolicy.winner(["a": 801, "b": 800, "c": 0], current: "a"), "b")
        XCTAssertEqual(AutoSwitchPolicy.winner(["a": 100, "b": 100], current: "b"), "b")
        XCTAssertNil(AutoSwitchPolicy.winner(["a": 801], current: "a"))
    }

    func testRegionNamesOverrideFlagsAndAmbiguityIsRejected() {
        XCTAssertEqual(NodeOriginResolver.region("HDAC | 🇨🇳台湾专线"), "TW")
        XCTAssertEqual(NodeOriginResolver.region("🇯🇵 02"), "JP")
        XCTAssertNil(NodeOriginResolver.region("日本转美国"))
        XCTAssertNil(NodeOriginResolver.region("套餐到期"))
    }
}

final class NodeOriginResolverTests: XCTestCase {
    func testRenamedRuntimeNodeMatchesConnectionIdentityAndConfigChangesInvalidateSignature() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        func write(_ file: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        try write("profile.yaml", "items:\n  - id: first\n  - id: second\ncurrent: second\n")
        try write("profiles/first.yaml", "proxies:\n  - {name: 日本01, type: ss, server: first.example, port: 443, password: example}\n")
        try write("profiles/second.yaml", "\u{FEFF}proxies:\n  - {name: 日本01, type: ss, server: second.example, port: 443, password: example}\n")
        try write("work/config.yaml", "proxies:\n  - {name: 'renamed | 🇯🇵日本01', type: ss, server: first.example, port: 443, password: example}\n")
        let before = try NodeOriginResolver(directory: root)
        XCTAssertEqual(before.origins["renamed | 🇯🇵日本01"], "first")
        XCTAssertNil(before.origins["日本01"], "Duplicate names cannot establish ownership")
        try write("work/config.yaml", "proxies:\n  - {name: 'renamed | 🇯🇵日本01', type: ss, server: unknown.example, port: 443, password: example}\n")
        let after = try NodeOriginResolver(directory: root)
        XCTAssertNil(after.origins["renamed | 🇯🇵日本01"])
        XCTAssertNotEqual(before.signature, after.signature)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ duration: Duration) { lock.lock(); instant = instant.advanced(by: duration); lock.unlock() }
}

extension AutoSwitchMonitorTests {
    func testCooldownExpiresAtFiveSeconds() async {
        let f = MonitorFixture(); let clock = TestClock()
        let m = monitor(f, now: { clock.now() })
        await m.tick()
        await f.configure(allSlow: true)
        clock.advance(.milliseconds(4999)); await m.tick()
        let before = await f.tested.count; XCTAssertEqual(before, 2)
        clock.advance(.milliseconds(1)); await m.tick()
        let after = await f.tested.count; XCTAssertEqual(after, 4)
    }

    func testFailedProbeTriggersRecovery() async {
        let f = MonitorFixture()
        var ops = AutoSwitchOperations(
            snapshot: { _ in try await f.snapshot() }, probe: { _ in throw MonitorError.message("timeout") },
            resolver: { NodeOriginResolver(origins: ["日本旧": "one", "日本快": "one"]) },
            delay: { _, name in await f.delay(name) }, select: { _, name in await f.select(name) },
            connections: { _, _ in [] }, close: { _, _ in }
        )
        let m = AutoSwitchMonitor(operations: ops, defaults: defaults); await m.tick()
        let selected = await f.selected; XCTAssertEqual(selected, ["日本快"])
        ops.resolver = { NodeOriginResolver(origins: [:]) }
        let unknown = AutoSwitchMonitor(operations: ops, defaults: defaults); await unknown.tick()
        let after = await f.selected; XCTAssertEqual(after.count, 1)
    }
}

final class ClashControllerTransportTests: XCTestCase, @unchecked Sendable {
    func testRealUnixTransportEncodesNamesAndUsesGoogleHeadDelayTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("api.sock").path
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-u", "-c", #"""
import socket,sys,json,urllib.parse
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen()
for _ in range(3):
 c,_=s.accept(); data=b''
 while b'\r\n\r\n' not in data: data+=c.recv(4096)
 method,target,_=data.split(b'\r\n',1)[0].decode().split(' ')
 u=urllib.parse.urlsplit(target); q=urllib.parse.parse_qs(u.query)
 if method=='GET' and u.path.endswith('/delay'):
  assert urllib.parse.unquote(u.path)=='/proxies/日本 / A?x/delay'
  assert q['url']==['https://www.google.com/'] and q['expected']==['200'] and q['timeout']==['800']
  body=b'{"delay":47}'
 elif method=='GET':
  body=json.dumps({'connections':[{'id':'old','chains':['GLOBAL','old-node']},{'id':'unrelated','chains':['other','old-node']}]}).encode()
 else:
  assert method=='PUT' and u.path=='/proxies/GLOBAL'; body=b''
 c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body); c.close()
s.close()
"""#, socket]
        try python.run(); defer { if python.isRunning { python.terminate() } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: socket) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let client = ClashControllerClient()
        let delay = try await client.delay(socket: socket, name: "日本 / A?x")
        XCTAssertEqual(delay, 47)
        let ids = try await client.oldConnections(socket: socket, node: "old-node")
        XCTAssertEqual(ids, ["old"])
        try await client.select(socket: socket, name: "日本 / A?x")
        python.waitUntilExit(); XCTAssertEqual(python.terminationStatus, 0)
    }
}

extension AutoSwitchMonitorTests {
    func testCancellationDuringProbeDoesNotStartRecovery() async throws {
        let f = MonitorFixture()
        let m = AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await f.snapshot() },
            probe: { _ in try await Task.sleep(for: .seconds(30)); return 900 },
            resolver: { NodeOriginResolver(origins: ["日本旧": "one", "日本快": "one"]) },
            delay: { _, name in await f.delay(name) }, select: { _, name in await f.select(name) },
            connections: { _, _ in [] }, close: { _, _ in }
        ), defaults: defaults)
        let task = Task { await m.tick() }
        try await Task.sleep(for: .milliseconds(20)); task.cancel(); await task.value
        let selected = await f.selected; let tested = await f.tested
        XCTAssertTrue(selected.isEmpty); XCTAssertTrue(tested.isEmpty)
    }

    func testSelectionFailureDoesNotStartCooldown() async {
        let f = MonitorFixture()
        let m = AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await f.snapshot() }, probe: { _ in await f.probe() },
            resolver: { NodeOriginResolver(origins: ["日本旧": "one", "日本快": "one"]) },
            delay: { _, name in await f.delay(name) }, select: { _, _ in throw MonitorError.message("failed") },
            connections: { _, _ in [] }, close: { _, _ in }
        ), defaults: defaults)
        await m.tick(); await m.tick()
        let tested = await f.tested; XCTAssertEqual(tested.count, 4)
    }
}
