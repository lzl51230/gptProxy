import XCTest
@testable import ChatGPTProxyCore

private actor RegionFixture {
    var current = "日本旧"
    var values = ["日本旧": 900, "日本快": 801, "香港一": 120, "香港二": 90, "美国一": 1,
                  "美国其他订阅": 1, "未知节点": 1, "日本DIRECT": 1, "香港组": 1]
    var tested: [String] = []
    var selected: [String] = []
    var closed: [String] = []
    var probeValue = 900
    var mode = "global"
    var manualChange = false
    var changeConfiguration = false
    var snapshots = 0
    var held = false
    var release: CheckedContinuation<Void, Never>?
    var blockTests = false
    var failRefresh = false
    var origins: [String: String] {
        values.mapValues { _ in "one" }.merging(["美国其他订阅": "two"]) { _, new in new }
    }
    func snapshot() throws -> ClashSnapshot {
        if failRefresh { throw MonitorError.message("控制接口不可用") }
        snapshots += 1
        var proxies: [String: [String: Any]] = [:]
        for name in values.keys { proxies[name] = ["name": name, "type": name == "日本DIRECT" ? "Direct" : "Shadowsocks"] }
        proxies["香港组"] = ["name": "香港组", "type": "Selector", "now": "香港一", "all": ["香港一"]]
        let selection = manualChange && snapshots > 2 ? "美国其他订阅" : current
        let names = values.keys.sorted().filter { !(changeConfiguration && snapshots > 2 && $0 == "美国一") }
        proxies["GLOBAL"] = ["name": "GLOBAL", "type": "Selector", "now": selection, "all": names]
        return ClashSnapshot(socket: "/fixture", mode: mode,
            proxies: try JSONDecoder().decode([String: ClashProxy].self, from: JSONSerialization.data(withJSONObject: proxies)))
    }
    func delay(_ name: String) async throws -> Int {
        tested.append(name)
        if blockTests && !held {
            held = true
            await withCheckedContinuation { release = $0 }
        }
        guard let value = values[name], value != -1 else { throw MonitorError.message("timeout") }
        return value
    }
    func resume() { release?.resume(); release = nil }
    func select(_ name: String) { selected.append(name); current = name }
    func close(_ id: String) { closed.append(id) }
    func set(_ name: String, _ value: Int?) { values[name] = value }
    func configure(healthy: Bool = false, block: Bool = false, manual: Bool = false, changed: Bool = false,
                   failure: Bool = false, rule: Bool = false) {
        probeValue = healthy ? 800 : 900; blockTests = block; manualChange = manual
        changeConfiguration = changed; failRefresh = failure; mode = rule ? "rule" : "global"
    }
    func probe() -> Int { probeValue }
}

@MainActor
final class RegionFailoverTests: XCTestCase {
    private var suites: [String] = []
    private func storage() -> UserDefaults {
        let suite = "RegionFailoverTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }
    private func monitor(_ f: RegionFixture, defaults: UserDefaults? = nil) -> AutoSwitchMonitor {
        AutoSwitchMonitor(operations: .init(
            snapshot: { _ in try await f.snapshot() }, probe: { _ in await f.probe() },
            resolver: { NodeOriginResolver(origins: await f.origins) },
            delay: { _, name in try await f.delay(name) }, select: { _, name in await f.select(name) },
            connections: { _, _ in ["old"] }, close: { _, id in await f.close(id) }
        ), defaults: defaults ?? storage())
    }
    private func prepare(_ m: AutoSwitchMonitor, enabled: [String] = ["HK", "US"]) async {
        await m.refreshRegions()
        for code in enabled { m.setRegionEnabled(code, enabled: true) }
    }

    func testCurrentRegionFirstThenFirstEligibleRegionAndFastestNode() async {
        let f = RegionFixture(); let m = monitor(f)
        await prepare(m, enabled: ["JP", "HK", "US"])
        await m.tick()
        let tested = await f.tested; let selected = await f.selected; let closed = await f.closed
        XCTAssertEqual(Set(tested.prefix(2)), ["日本旧", "日本快"])
        XCTAssertEqual(Set(tested), ["日本旧", "日本快", "香港一", "香港二"])
        XCTAssertEqual(tested.count, 4)
        XCTAssertEqual(selected, ["香港二"]); XCTAssertEqual(closed, ["old"])
    }

    func testPriorityButtonsChangeFallbackOrder() async {
        let f = RegionFixture(); let m = monitor(f)
        await prepare(m)
        m.moveRegion("US", offset: -1); m.moveRegion("US", offset: -1)
        await m.tick()
        let tested = await f.tested; let selected = await f.selected
        XCTAssertEqual(selected, ["美国一"])
        XCTAssertEqual(Set(tested), ["日本旧", "日本快", "美国一"])
    }

    func testUsableCurrentRegionAndHealthyProbeDoNotTestBackups() async {
        let f = RegionFixture(); let m = monitor(f)
        await prepare(m); await f.set("日本快", 800); await m.tick()
        let selected = await f.selected; let tested = await f.tested
        XCTAssertEqual(selected, ["日本快"])
        XCTAssertEqual(Set(tested), ["日本旧", "日本快"])
        let healthy = RegionFixture(); let healthyMonitor = monitor(healthy)
        await prepare(healthyMonitor); await healthy.configure(healthy: true); await healthyMonitor.tick()
        let healthyTests = await healthy.tested
        XCTAssertTrue(healthyTests.isEmpty)
    }

    func testAllFailedIncludesTimeoutsAndRetriesWithoutSwitching() async {
        let f = RegionFixture(); let m = monitor(f)
        await prepare(m)
        await f.set("香港一", -1); await f.set("香港二", 0); await f.set("美国一", 801)
        await m.tick(); await m.tick()
        let selected = await f.selected; let tested = await f.tested
        XCTAssertTrue(selected.isEmpty); XCTAssertEqual(tested.count, 10)
        XCTAssertTrue(m.status.contains("均无"))
    }

    func testFailedFirstBackupFallsThroughAndRefreshWorksWhilePaused() async {
        let f = RegionFixture(); let defaults = storage()
        defaults.set(true, forKey: "monitorPaused")
        let m = monitor(f, defaults: defaults)
        await prepare(m)
        XCTAssertTrue(m.paused)
        XCTAssertEqual(m.regionNodeCounts["HK"], 2)
        await f.set("香港一", -1); await f.set("香港二", 801)
        // Exercise a single recovery without starting the background loop.
        await m.tick()
        let selected = await f.selected; let tested = await f.tested
        XCTAssertEqual(selected, ["美国一"])
        XCTAssertEqual(Set(tested), ["日本旧", "日本快", "香港一", "香港二", "美国一"])
    }

    func testUncheckedBackupsNeverTested() async {
        let f = RegionFixture(); let m = monitor(f)
        await prepare(m, enabled: [])
        XCTAssertEqual(m.regions.map(\.code), ["HK", "JP", "US"])
        XCTAssertTrue(m.regions.allSatisfy { !$0.isEnabled })
        await m.tick()
        let tested = await f.tested; let selected = await f.selected
        XCTAssertEqual(Set(tested), ["日本旧", "日本快"]); XCTAssertTrue(selected.isEmpty)
    }

    func testPersistenceRetainsMissingRegionsAndAppendsNewRegionsUnchecked() async {
        let f = RegionFixture(); let defaults = storage(); let m = monitor(f, defaults: defaults)
        await prepare(m); m.moveRegion("US", offset: -1)
        m.moveRegion("HK", offset: -1) // Boundary no-op.
        let expected = m.regions
        let restored = monitor(f, defaults: defaults)
        XCTAssertEqual(restored.regions, expected)
        await f.set("香港一", nil); await f.set("香港二", nil); await f.set("香港组", nil)
        await f.set("新加坡一", 50); await restored.refreshRegions()
        XCTAssertEqual(Array(restored.regions.prefix(3)), expected)
        XCTAssertEqual(restored.regions.last?.code, "SG")
        XCTAssertEqual(restored.regions.last?.isEnabled, false)
        XCTAssertNil(restored.regionNodeCounts["HK"])
        await restored.tick()
        let selected = await f.selected
        XCTAssertEqual(selected, ["美国一"])
        await f.configure(failure: true); await restored.refreshRegions()
        XCTAssertNotNil(restored.regionCatalogStatus)
        XCTAssertTrue(restored.regions.contains { $0.code == "HK" && $0.isEnabled })
    }

    func testSettingsChangesAndStopDuringTestingDiscardResults() async throws {
        for action in 0..<3 {
            let f = RegionFixture(); let m = monitor(f)
            await prepare(m); await f.configure(block: true)
            let task = Task { await m.tick() }
            for _ in 0..<200 {
                if await f.held { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let held = await f.held; XCTAssertTrue(held)
            if action == 0 { m.setRegionEnabled("HK", enabled: false) }
            if action == 1 { m.moveRegion("US", offset: -1) }
            if action == 2 { m.stop() }
            await f.resume(); await task.value
            let selected = await f.selected
            XCTAssertTrue(selected.isEmpty)
        }
    }

    func testManualSelectionConfigurationChangeAndRuleModePreventSwitch() async {
        for action in 0..<3 {
            let f = RegionFixture(); let m = monitor(f)
            await prepare(m)
            await f.configure(manual: action == 0, changed: action == 1, rule: action == 2)
            await m.tick()
            let selected = await f.selected
            XCTAssertTrue(selected.isEmpty)
        }
    }
}
