import XCTest
@testable import ChatGPTProxyCore

private actor MonitorFixture {
    var current = "日本旧"
    var mode = "global"
    var failures = 2
    var failNodes: Set<String> = []
    var failAfter: [String: Double] = [:]
    var delays = ["日本旧": 50, "日本快": 100, "日本另一订阅": 1, "香港快": 1]
    var tested: [String] = []
    var selected: [String] = []
    var closed: [String] = []
    var heartbeatCount = 0
    var writes: [ContinuousClock.Instant] = []
    var manualChange = false
    var selectionFails = false
    var controllerFails = false
    var snapshots = 0
    func snapshot() throws -> ClashSnapshot {
        if controllerFails { throw MonitorError.message("offline controller") }
        snapshots += 1
        if manualChange && snapshots > 1 { current = "日本另一订阅" }
        let data = try JSONSerialization.data(withJSONObject: [
            "GLOBAL": ["name": "GLOBAL", "type": "Selector", "now": current, "all": Array(delays.keys).sorted()],
            "日本旧": ["name": "日本旧", "type": "Shadowsocks"],
            "日本快": ["name": "日本快", "type": "Shadowsocks"],
            "日本另一订阅": ["name": "日本另一订阅", "type": "Shadowsocks"],
            "香港快": ["name": "香港快", "type": "Shadowsocks"],
        ])
        return ClashSnapshot(socket: "/fixture", mode: mode, proxies: try JSONDecoder().decode([String: ClashProxy].self, from: data))
    }
    func heartbeat(age: Double = 0) -> Bool {
        heartbeatCount += 1
        if failures > 0 { failures -= 1; return false }
        return !failNodes.contains(current) && age < (failAfter[current] ?? .infinity)
    }
    func delay(_ name: String) -> Int { tested.append(name); return delays[name]! }
    func select(_ name: String, at instant: ContinuousClock.Instant) throws {
        if selectionFails { throw MonitorError.message("selection failed") }
        selected.append(name); writes.append(instant); current = name
    }
    func close(_ id: String) { closed.append(id) }
    func setDelay(_ name: String, _ delay: Int) { delays[name] = delay }
    func fail(_ name: String, after seconds: Double) { failAfter[name] = seconds }
    func changeCurrent(_ name: String) { current = name }
    func configure(failures: Int? = nil, mode: String? = nil, allSlow: Bool = false, manual: Bool = false,
                   selectionFails: Bool = false, controllerFails: Bool = false) {
        if let failures { self.failures = failures }
        if let mode { self.mode = mode }
        if allSlow { delays["日本快"] = 801; delays["日本旧"] = 801 }
        manualChange = manual
        self.selectionFails = selectionFails; self.controllerFails = controllerFails
    }
}

@MainActor
final class AutoSwitchMonitorTests: XCTestCase {
    private let defaultsSuite = "AutoSwitchMonitorTests.\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: defaultsSuite)!
    private let clock = MonitorTestClock()
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try await super.tearDown()
    }
    private func monitor(_ fixture: MonitorFixture, sleep: (@Sendable (Duration) async throws -> Void)? = nil) -> AutoSwitchMonitor {
        let clock = self.clock
        return AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await fixture.snapshot() },
            makeConnection: { _ in TestCodexConnection(clock: clock) { age in await fixture.heartbeat(age: age) } },
            resolver: { NodeOriginResolver(origins: ["日本旧": "one", "日本快": "one", "香港快": "one", "日本另一订阅": "two"]) },
            delay: { _, name in await fixture.delay(name) }, select: { _, name in try await fixture.select(name, at: clock.now()) },
            connections: { _, _ in ["old-connection"] }, close: { _, id in await fixture.close(id) },
            now: { clock.now() }, sleep: sleep ?? { clock.advance($0) }
        ), defaults: defaults)
    }

    func testTwoShortConnectionsRecoverWithinSubscriptionAndAcceptOnlyAtTenSeconds() async {
        let f = MonitorFixture(); let m = monitor(f)
        await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 1)
        let firstSelection = await f.selected; XCTAssertTrue(firstSelection.isEmpty)
        await m.tick()
        let selected = await f.selected; let tested = await f.tested; let closed = await f.closed
        XCTAssertEqual(selected, ["日本快"])
        XCTAssertEqual(tested, ["日本快"], "First round skips the triggering node")
        XCTAssertEqual(closed, ["old-connection"])
        XCTAssertEqual(m.connectionSeconds, 10)
        XCTAssertEqual(m.phase, .maintaining)
        clock.advance(.seconds(2)); await m.tick()
        XCTAssertEqual(m.connectionSeconds, 12, "Accepted connection is retained")
        let after = await f.tested; XCTAssertEqual(after.count, 1)
    }

    func testHighHeartbeatLatencyDoesNotTriggerRecovery() async {
        let f = MonitorFixture(); await f.configure(failures: 0)
        let m = monitor(f); await m.tick()
        XCTAssertEqual(m.latency, 1500)
        let tested = await f.tested; XCTAssertTrue(tested.isEmpty)
    }

    func testFailureCountResetsOnlyAfterSixtySecondsAndStableDisconnectStartsAtZero() async {
        let f = MonitorFixture(); await f.configure(failures: 1)
        let m = monitor(f); await m.tick(); await m.tick()
        clock.advance(.milliseconds(59999)); await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 1)
        clock.advance(.milliseconds(1)); await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 0)
        await f.configure(failures: 1); await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 0)
        await f.configure(failures: 1); await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 1)
    }

    func testAllSlowNodesBackOffAndLaterRoundIncludesOriginalNode() async {
        let f = MonitorFixture(); await f.configure(allSlow: true)
        let m = monitor(f); await m.tick(); await m.tick()
        XCTAssertEqual(m.retrySeconds, 2)
        await m.tick()
        let before = await f.tested; XCTAssertEqual(before, ["日本快"])
        for seconds in [2, 4, 8, 16, 30, 30] {
            clock.advance(.seconds(seconds)); await m.tick()
        }
        XCTAssertEqual(m.retrySeconds, 30)
        let tested = await f.tested
        XCTAssertTrue(tested.contains("日本旧"))
        let selected = await f.selected; XCTAssertTrue(selected.isEmpty)
    }

    func testManualSelectionDuringHeartbeatDiscardsObservation() async {
        let f = MonitorFixture(); await f.configure(manual: true)
        let m = monitor(f); await m.tick()
        XCTAssertEqual(m.consecutiveFailures, 0)
        XCTAssertTrue(m.status.contains("变化"))
        let selected = await f.selected; XCTAssertTrue(selected.isEmpty)
    }

    func testRuleModeAndUnavailableControllerStillObserveWithoutSwitching() async {
        for controllerFails in [false, true] {
            let f = MonitorFixture(); await f.configure(failures: 0, mode: "rule", controllerFails: controllerFails)
            let m = monitor(f); await m.tick()
            XCTAssertEqual(m.phase, .maintaining)
            let heartbeats = await f.heartbeatCount; XCTAssertEqual(heartbeats, 1)
            let tested = await f.tested; XCTAssertTrue(tested.isEmpty)
        }
    }

    func testSelectionFailureDoesNotClaimSuccess() async {
        let f = MonitorFixture(); await f.configure(selectionFails: true)
        let m = monitor(f); await m.tick(); await m.tick()
        XCTAssertEqual(m.lastSwitch, "尚未切换")
        XCTAssertNotEqual(m.phase, .maintaining)
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

    func testCandidateExactly800PassesAnd801IsExcludedWithoutRetest() async {
        for delay in [800, 801] {
            let f = MonitorFixture(); await f.setDelay("日本快", delay)
            let m = monitor(f); await m.tick(); await m.tick()
            let selected = await f.selected; let tested = await f.tested
            XCTAssertEqual(tested, ["日本快"])
            XCTAssertEqual(selected, delay == 800 ? ["日本快"] : [])
        }
    }

    func testCandidateFailureTriesBackupAndRespectsFiveSecondWriteInterval() async {
        let f = MonitorFixture(); await f.fail("日本快", after: 4)
        let m = monitor(f); await m.refreshRegions(); m.setRegionEnabled("HK", enabled: true)
        await m.tick(); await m.tick()
        let selected = await f.selected; let writes = await f.writes; let closed = await f.closed
        XCTAssertEqual(selected, ["日本快", "香港快"])
        XCTAssertGreaterThanOrEqual((writes[1] - writes[0]).seconds, 5)
        XCTAssertEqual(closed.count, 2)
        XCTAssertEqual(m.currentNode, "香港快")
        XCTAssertEqual(m.connectionSeconds, 10)
    }

    func testCandidateNeedsValidHeartbeatAtTenSeconds() async throws {
        let f = MonitorFixture(); let gate = CandidateBoundaryGate(clock: clock)
        let m = monitor(f, sleep: { try await gate.sleep($0) })
        await m.tick()
        let running = Task { await m.tick() }
        try await gate.waitUntilHeld()
        XCTAssertEqual(m.connectionSeconds, 9.999, accuracy: 0.000001)
        XCTAssertEqual(m.phase, .validating)
        XCTAssertEqual(m.lastSwitch, "尚未切换")
        clock.advance(.milliseconds(1)); await gate.resume(); await running.value
        XCTAssertEqual(m.phase, .maintaining)
        XCTAssertEqual(m.connectionSeconds, 10, accuracy: 0.000001)
    }

    func testManualChangeOrStopDuringCandidateValidationDiscardsSuccess() async throws {
        for stop in [false, true] {
            let f = MonitorFixture(); let gate = CandidateBoundaryGate(clock: clock)
            let m = monitor(f, sleep: { try await gate.sleep($0) })
            await m.tick()
            let running = Task { await m.tick() }
            try await gate.waitUntilHeld()
            if stop { m.stop() } else { await f.changeCurrent("日本另一订阅") }
            clock.advance(.milliseconds(1)); await gate.resume(); await running.value
            XCTAssertEqual(m.lastSwitch, "尚未切换")
            XCTAssertEqual(m.connectionSeconds, 0)
            XCTAssertNotEqual(m.phase, .maintaining)
            await m.stopAndWait()
        }
    }

    func testFailureAfterSilenceDoesNotCountUnconfirmedTimeTowardSixtySeconds() async {
        let f = MonitorFixture(); await f.configure(failures: 1)
        let m = monitor(f); await m.tick(); await m.tick()
        clock.advance(.seconds(58)); await m.tick()
        clock.advance(.seconds(10)); await f.configure(failures: 1); await m.tick()
        let selected = await f.selected
        XCTAssertEqual(selected, ["日本快"], "A timeout after 60 seconds cannot turn 58 confirmed seconds into success")
    }

    func testCancellationDuringHeartbeatDoesNotStartRecovery() async throws {
        let f = MonitorFixture()
        let clock = self.clock
        let m = AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await f.snapshot() },
            makeConnection: { _ in TestCodexConnection(clock: clock) { _ in
                try await Task.sleep(for: .seconds(30)); return false
            } },
            resolver: { NodeOriginResolver(origins: [:]) },
            delay: { _, name in await f.delay(name) }, select: { _, name in try await f.select(name, at: clock.now()) },
            connections: { _, _ in [] }, close: { _, _ in }
        ), defaults: defaults)
        let task = Task { await m.tick() }
        try await Task.sleep(for: .milliseconds(20)); task.cancel(); await task.value
        XCTAssertEqual(m.consecutiveFailures, 0)
        let selected = await f.selected; XCTAssertTrue(selected.isEmpty)
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

final class ClashControllerTransportTests: XCTestCase, @unchecked Sendable {
    func testRealUnixTransportEncodesNamesAndUsesCodexDelayTarget() async throws {
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
  assert q['url']==['https://chatgpt.com/backend-api/codex/models'] and q['expected']==['401'] and q['timeout']==['10000']
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


private actor CandidateBoundaryGate {
    let clock: MonitorTestClock
    private var calls = 0
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(clock: MonitorTestClock) { self.clock = clock }
    func sleep(_ duration: Duration) async throws {
        calls += 1
        if calls == 1 { clock.advance(.milliseconds(9999)) }
        else if calls == 2 {
            held = true
            await withCheckedContinuation { continuation = $0 }
        } else { clock.advance(duration) }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func waitUntilHeld() async throws {
        for _ in 0..<200 {
            if held { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MonitorError.message("Candidate never reached the boundary")
    }
}
