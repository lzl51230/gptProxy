import Combine
import Foundation
import OSLog

struct AutoSwitchOperations: Sendable {
    var snapshot: @Sendable (UInt16) async throws -> ClashSnapshot
    var makeConnection: @Sendable (UInt16) -> any CodexConnection
    var resolver: @Sendable () async throws -> NodeOriginResolver
    var delay: @Sendable (String, String) async throws -> Int
    var select: @Sendable (String, String) async throws -> Void
    var connections: @Sendable (String, String) async throws -> [String]
    var close: @Sendable (String, String) async throws -> Void
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let live = AutoSwitchOperations(
        snapshot: { try await ClashControllerClient().snapshot(port: $0) },
        makeConnection: { CodexConnectionSession(port: $0) },
        resolver: { try await Task.detached(priority: .utility) { try NodeOriginResolver() }.value },
        delay: { try await ClashControllerClient().delay(socket: $0, name: $1) },
        select: { try await ClashControllerClient().select(socket: $0, name: $1) },
        connections: { try await ClashControllerClient().oldConnections(socket: $0, node: $1) },
        close: { try await ClashControllerClient().close(socket: $0, id: $1) }
    )
}

public struct MonitorRegionPreference: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public var isEnabled: Bool
    public var id: String { code }
    public var name: String {
        Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
    }
}

public enum MonitorPhase: String, Sendable {
    case connecting, maintaining, testing, validating, retrying, paused, stopped
}

private struct MonitorContext: Equatable {
    let socket: String
    let mode: String
    let selection: [String: String]
    let nodes: [String]?
    let configuration: Data?

    init(_ snapshot: ClashSnapshot, signature: Data?) {
        socket = snapshot.socket; mode = snapshot.mode
        selection = snapshot.selectionSignature
        nodes = snapshot.proxies["GLOBAL"]?.all
        configuration = signature
    }
}

private struct MonitorContextChanged: Error {}

@MainActor
public final class AutoSwitchMonitor: ObservableObject {
    @Published public private(set) var status = "等待监控"
    @Published public private(set) var currentNode = "未知"
    @Published public private(set) var latency: Int?
    @Published public private(set) var phase: MonitorPhase = .stopped
    @Published public private(set) var connectionSeconds: Double = 0
    @Published public private(set) var consecutiveFailures = 0
    @Published public private(set) var disconnectReason: String?
    @Published public private(set) var retrySeconds: Int?
    @Published public private(set) var lastSwitch = "尚未切换"
    @Published public private(set) var paused: Bool
    @Published public private(set) var regions: [MonitorRegionPreference]
    @Published public private(set) var regionNodeCounts: [String: Int] = [:]
    @Published public private(set) var regionCatalogStatus: String?
    @Published public private(set) var isRefreshingRegions = false
    private let defaults: UserDefaults
    private static let regionsKey = "monitorRegionPreferences"
    private var preferenceRevision = 0
    private var lifecycleRevision = 0
    private var task: Task<Void, Never>?
    private var port: UInt16 = 7890
    private var pendingStop: Task<Void, Never>?
    private var connection: (any CodexConnection)?
    private var context: MonitorContext?
    private var ticking = false
    private var recoveryPending = false
    private var failedNode: String?
    private var recoveryRound = 0
    private var recoveryAttempt = 0
    private var retryAt: ContinuousClock.Instant?
    private var nextDelay: Duration = .seconds(2)
    private let operations: AutoSwitchOperations
    private let writesLog: Bool
    private var cooldownUntil: ContinuousClock.Instant?
    private var activity: NSObjectProtocol?
    private let logger = Logger(subsystem: "local.alex.chatgpt-proxy", category: "Monitor")
    public static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ChatGPT Proxy/monitor.jsonl")

    public convenience init() { self.init(operations: .live, writesLog: true) }

    init(operations: AutoSwitchOperations, writesLog: Bool = false, defaults: UserDefaults = .standard) {
        self.writesLog = writesLog
        self.operations = operations
        self.defaults = defaults
        paused = defaults.bool(forKey: "monitorPaused")
        let saved = defaults.data(forKey: Self.regionsKey)
            .flatMap { try? JSONDecoder().decode([MonitorRegionPreference].self, from: $0) } ?? []
        var seen = Set<String>()
        regions = saved.filter { seen.insert($0.code).inserted }
    }

    public func setRegionEnabled(_ code: String, enabled: Bool) {
        guard let index = regions.firstIndex(where: { $0.code == code }), regions[index].isEnabled != enabled else { return }
        regions[index].isEnabled = enabled
        preferenceRevision += 1
        saveRegions()
        restartAfterPreferenceChange()
    }

    public func moveRegion(_ code: String, offset: Int) {
        guard offset == -1 || offset == 1,
              let index = regions.firstIndex(where: { $0.code == code }),
              regions.indices.contains(index + offset) else { return }
        regions.swapAt(index, index + offset)
        preferenceRevision += 1
        saveRegions()
        restartAfterPreferenceChange()
    }

    private func saveRegions() {
        if let data = try? JSONEncoder().encode(regions) { defaults.set(data, forKey: Self.regionsKey) }
    }

    private func candidatesByRegion(_ snapshot: ClashSnapshot, resolver: NodeOriginResolver) throws -> [String: [String]] {
        guard let current = snapshot.current, let source = resolver.origins[current],
              NodeOriginResolver.region(current) != nil else {
            throw MonitorError.message("节点订阅或地区不明确，保持原节点")
        }
        let excluded = Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"])
        var result: [String: [String]] = [:]
        for name in Set(snapshot.proxies["GLOBAL"]?.all ?? []).sorted() {
            guard let proxy = snapshot.proxies[name], proxy.all == nil,
                  !excluded.contains(proxy.type.uppercased()), resolver.origins[name] == source,
                  let region = NodeOriginResolver.region(name) else { continue }
            result[region, default: []].append(name)
        }
        return result
    }

    private func updateRegionCatalog(_ candidates: [String: [String]]) {
        regionNodeCounts = candidates.mapValues(\.count)
        let known = Set(regions.map(\.code))
        let additions = candidates.keys.filter { !known.contains($0) }.sorted()
        if !additions.isEmpty {
            regions += additions.map { MonitorRegionPreference(code: $0, isEnabled: false) }
            saveRegions()
        }
        regionCatalogStatus = nil
    }

    public func refreshRegions() async {
        guard !isRefreshingRegions else { return }
        isRefreshingRegions = true
        defer { isRefreshingRegions = false }
        let refreshPort = port
        do {
            let snapshot = try await operations.snapshot(refreshPort)
            let resolver = try await operations.resolver()
            try Task.checkCancellation()
            guard port == refreshPort else { return }
            updateRegionCatalog(try candidatesByRegion(snapshot, resolver: resolver))
        } catch is CancellationError { }
        catch {
            guard port == refreshPort else { return }
            regionNodeCounts = [:]
            regionCatalogStatus = error.localizedDescription
        }
    }

    private func restartAfterPreferenceChange() {
        if task != nil { start(port: port) }
        else {
            lifecycleRevision += 1
            let old = connection; connection = nil; old?.cancel()
            let previous = pendingStop
            pendingStop = Task { await previous?.value; await old?.close() }
            clearObservation()
        }
    }

    public func start(port: UInt16) {
        stop()
        self.port = port
        guard !paused else { phase = .paused; status = "监控已暂停"; return }
        let lifecycle = lifecycleRevision
        let stopping = pendingStop
        phase = .connecting
        status = "正在建立 Codex 长连接"
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Codex 长连接监控")
        task = Task { [weak self] in
            await stopping?.value
            while let self, !Task.isCancelled, lifecycle == self.lifecycleRevision {
                await self.tick()
                guard !Task.isCancelled, lifecycle == self.lifecycleRevision else { break }
                do { try await self.operations.sleep(self.nextDelay) }
                catch { break }
            }
        }
    }

    public func stop() {
        lifecycleRevision += 1
        let running = task; task = nil; running?.cancel()
        let old = connection; connection = nil; old?.cancel()
        let previous = pendingStop
        pendingStop = Task { await previous?.value; await running?.value; await old?.close() }
        clearObservation()
        phase = paused ? .paused : .stopped
        status = paused ? "监控已暂停" : "监控已停止"
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    public func stopAndWait() async {
        stop()
        await pendingStop?.value
    }

    private func clearObservation() {
        context = nil
        connectionSeconds = 0; latency = nil; consecutiveFailures = 0
        disconnectReason = nil; retrySeconds = nil; retryAt = nil
        recoveryPending = false; failedNode = nil; recoveryRound = 0; recoveryAttempt = 0
    }

    private func closeConnection() async {
        let old = connection; connection = nil
        await old?.close()
    }

    public func togglePaused() {
        paused.toggle()
        defaults.set(paused, forKey: "monitorPaused")
        start(port: port)
        record("pause", ["paused": String(paused)])
    }

    private func record(_ event: String, _ fields: [String: String] = [:]) {
        guard writesLog else { return }
        var row = fields
        row["event"] = event
        row["time"] = ISO8601DateFormatter().string(from: Date())
        logger.info("\(event, privacy: .public)")
        do {
            let directory = Self.logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = try? Self.logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
                let previous = directory.appendingPathComponent("monitor.previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: Self.logURL, to: previous)
            }
            var data = try JSONEncoder().encode(row); data.append(10)
            if !FileManager.default.fileExists(atPath: Self.logURL.path) {
                FileManager.default.createFile(atPath: Self.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: Self.logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { logger.error("无法写入监控日志") }
    }

    private func requireCurrent(_ revision: Int, _ lifecycle: Int) throws {
        try Task.checkCancellation()
        guard revision == preferenceRevision, lifecycle == lifecycleRevision else { throw CancellationError() }
    }

    private func signature() async throws -> Data? {
        do { return try await operations.resolver().signature }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func checkedSnapshot(_ expected: ClashSnapshot, signature: Data?, revision: Int, lifecycle: Int) async throws -> ClashSnapshot {
        try requireCurrent(revision, lifecycle)
        let fresh = try await operations.snapshot(port)
        let freshSignature = try await self.signature()
        try requireCurrent(revision, lifecycle)
        guard MonitorContext(fresh, signature: freshSignature) == MonitorContext(expected, signature: signature) else {
            throw MonitorContextChanged()
        }
        return fresh
    }

    private func publish(_ heartbeat: CodexHeartbeat) {
        latency = heartbeat.latencyMilliseconds
        connectionSeconds = heartbeat.connectionSeconds
        if !heartbeat.isHealthy { disconnectReason = heartbeat.failureReason ?? "连接失败" }
        record("heartbeat", ["node": currentNode, "seconds": String(connectionSeconds),
                             "delay": latency.map(String.init) ?? "failed", "reason": heartbeat.failureReason ?? ""])
    }

    private func scheduleRetry() {
        let seconds = min(30, 1 << min(5, recoveryAttempt + 1))
        recoveryAttempt += 1
        retrySeconds = seconds
        retryAt = operations.now().advanced(by: .seconds(seconds))
        nextDelay = .seconds(seconds)
        phase = .retrying
        status = "全部候选暂不可用，\(seconds) 秒后重试"
        record("recoveryRetry", ["seconds": String(seconds)])
    }

    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let revision = preferenceRevision, lifecycle = lifecycleRevision
        nextDelay = .seconds(2)
        do {
            let snapshot: ClashSnapshot?
            do { snapshot = try await operations.snapshot(port) }
            catch is CancellationError { throw CancellationError() }
            catch { snapshot = nil; record("controllerUnavailable", ["message": error.localizedDescription]) }
            let sourceSignature = snapshot == nil ? nil : try await signature()
            try requireCurrent(revision, lifecycle)
            let latestContext = snapshot.map { MonitorContext($0, signature: sourceSignature) }
            if context != latestContext {
                await closeConnection()
                try requireCurrent(revision, lifecycle)
                clearObservation()
                context = latestContext
            }
            currentNode = snapshot?.current ?? "未知"
            // A missing controller or rule/direct mode must not prevent network observation.
            if recoveryPending && (snapshot?.mode != "global" || sourceSignature == nil) {
                recoveryPending = false
            }
            if !recoveryPending {
                if connection == nil { connection = operations.makeConnection(port) }
                let heartbeat = try await connection!.heartbeat()
                try requireCurrent(revision, lifecycle)
                if let snapshot {
                    _ = try await checkedSnapshot(snapshot, signature: sourceSignature, revision: revision, lifecycle: lifecycle)
                }
                publish(heartbeat)
                if heartbeat.isHealthy {
                    if heartbeat.connectionSeconds >= 60 { consecutiveFailures = 0 }
                    phase = .maintaining
                    status = snapshot?.mode == "global" ? "Codex 长连接正常" : "Codex 长连接正常；仅全局模式支持自动切换"
                    return
                }
                await closeConnection()
                try requireCurrent(revision, lifecycle)
                consecutiveFailures = heartbeat.connectionSeconds >= 60 ? 0 : min(2, consecutiveFailures + 1)
                phase = .connecting
                status = "Codex 连接断开（未满 60 秒失败 \(consecutiveFailures)/2）"
                nextDelay = .seconds(1)
                guard consecutiveFailures >= 2 else { return }
                recoveryPending = true
                failedNode = snapshot?.current
                recoveryRound = 0; recoveryAttempt = 0
            }
            guard let snapshot, snapshot.mode == "global", sourceSignature != nil else {
                phase = .retrying
                status = "Codex 连接不可用；等待 Clash Party 全局模式及订阅配置"
                return
            }
            if let retryAt, operations.now() < retryAt {
                nextDelay = retryAt - operations.now()
                return
            }
            retrySeconds = nil; retryAt = nil
            try await recover(snapshot, revision: revision, lifecycle: lifecycle)
            try requireCurrent(revision, lifecycle)
            if recoveryPending { scheduleRetry() }
        } catch is CancellationError {
            guard lifecycle == lifecycleRevision else { return }
            await closeConnection()
            guard lifecycle == lifecycleRevision else { return }
            clearObservation()
            phase = .connecting
            status = "Codex 监控已取消，等待重新连接"
        }
        catch is MonitorContextChanged {
            guard lifecycle == lifecycleRevision else { return }
            await closeConnection()
            guard lifecycle == lifecycleRevision else { return }
            clearObservation()
            phase = .connecting
            status = "节点或配置已变化，重新建立 Codex 长连接"
            record("contextChanged")
        } catch {
            guard lifecycle == lifecycleRevision, !Task.isCancelled else { return }
            await closeConnection()
            guard lifecycle == lifecycleRevision else { return }
            latency = nil
            status = error.localizedDescription
            phase = .retrying
            record("error", ["message": status])
            if recoveryPending { scheduleRetry() }
        }
    }

    private func recover(_ original: ClashSnapshot, revision: Int, lifecycle: Int) async throws {
        guard let current = original.current else { throw MonitorError.message("无法解析当前节点") }
        let resolver = try await operations.resolver()
        try requireCurrent(revision, lifecycle)
        guard context == MonitorContext(original, signature: resolver.signature) else { throw MonitorContextChanged() }
        let candidates: [String: [String]]
        do { candidates = try candidatesByRegion(original, resolver: resolver) }
        catch { recoveryPending = false; throw error }
        updateRegionCatalog(candidates)
        guard let region = NodeOriginResolver.region(current) else { return }
        let order = [region] + regions.filter { $0.isEnabled && $0.code != region }.map(\.code)
        recoveryRound += 1
        var expected = original
        for targetRegion in order {
            let nodes = (candidates[targetRegion] ?? []).filter { recoveryRound > 1 || $0 != failedNode }
            phase = .testing
            status = "Codex 测速 \(targetRegion) · \(nodes.count) 个节点（≤800 ms）"
            record("testing", ["region": targetRegion, "count": String(nodes.count)])
            var delays: [String: Int] = [:]
            for offset in stride(from: 0, to: nodes.count, by: 4) {
                try requireCurrent(revision, lifecycle)
                let batch = Array(nodes[offset..<min(offset + 4, nodes.count)])
                let measure = operations.delay
                let results = await withTaskGroup(of: (String, Int?).self) { group in
                    for name in batch { group.addTask { (name, try? await measure(original.socket, name)) } }
                    var values: [(String, Int?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                try requireCurrent(revision, lifecycle)
                for (name, delay) in results {
                    if let delay, (1...AutoSwitchPolicy.threshold).contains(delay) { delays[name] = delay }
                    record("nodeTest", ["node": name, "delay": delay.map(String.init) ?? "failed"])
                }
            }
            let ranked = delays.keys.sorted {
                delays[$0] == delays[$1] ? $0 < $1 : delays[$0]! < delays[$1]!
            }
            for candidate in ranked {
                var before = try await checkedSnapshot(expected, signature: resolver.signature, revision: revision, lifecycle: lifecycle)
                if before.current != candidate {
                    if let until = cooldownUntil, operations.now() < until {
                        status = "等待节点切换冷却（5 秒）"
                        try await operations.sleep(until - operations.now())
                        before = try await checkedSnapshot(expected, signature: resolver.signature, revision: revision, lifecycle: lifecycle)
                    }
                    await closeConnection()
                    let ids = (try? await operations.connections(before.socket, before.current ?? "")) ?? []
                    _ = try await checkedSnapshot(before, signature: resolver.signature, revision: revision, lifecycle: lifecycle)
                    // A failed response may still mean the PUT took effect. Always read back,
                    // and reserve cooldown before submitting so a lost response cannot cause a rapid retry.
                    cooldownUntil = operations.now().advanced(by: .seconds(5))
                    do { try await operations.select(before.socket, candidate) }
                    catch is CancellationError { throw CancellationError() }
                    catch { record("selectionResponseFailed", ["message": error.localizedDescription]) }
                    let confirmed = try await operations.snapshot(port)
                    let freshSignature = try await signature()
                    try requireCurrent(revision, lifecycle)
                    guard confirmed.socket == before.socket, confirmed.mode == "global",
                          confirmed.proxies["GLOBAL"]?.all == before.proxies["GLOBAL"]?.all,
                          freshSignature == resolver.signature, confirmed.current == candidate else {
                        throw MonitorContextChanged()
                    }
                    expected = confirmed
                    context = MonitorContext(confirmed, signature: resolver.signature)
                    currentNode = candidate
                    for id in ids {
                        try requireCurrent(revision, lifecycle)
                        do { try await operations.close(before.socket, id) }
                        catch is CancellationError { throw CancellationError() }
                        catch { record("connectionCleanupFailed", ["id": id]) }
                    }
                    record("candidateSelected", ["node": candidate])
                }
                await closeConnection()
                try requireCurrent(revision, lifecycle)
                let candidateConnection = operations.makeConnection(port)
                connection = candidateConnection
                connectionSeconds = 0; latency = nil
                phase = .validating
                status = "验证 \(candidate) · 需保持 10 秒 Codex 长连接"
                while true {
                    try requireCurrent(revision, lifecycle)
                    let heartbeat = try await candidateConnection.heartbeat()
                    try requireCurrent(revision, lifecycle)
                    _ = try await checkedSnapshot(expected, signature: resolver.signature, revision: revision, lifecycle: lifecycle)
                    publish(heartbeat)
                    if !heartbeat.isHealthy { break }
                    if heartbeat.connectionSeconds >= 10 {
                        consecutiveFailures = 0; recoveryPending = false
                        recoveryRound = 0; recoveryAttempt = 0; retryAt = nil; retrySeconds = nil
                        phase = .maintaining
                        status = "Codex 长连接验收通过"
                        lastSwitch = "\(current) → \(candidate)（\(delays[candidate]!)ms）"
                        record("switched", ["from": current, "to": candidate, "delay": String(delays[candidate]!)])
                        return
                    }
                    try await operations.sleep(.seconds(2))
                }
                record("candidateFailed", ["node": candidate, "reason": disconnectReason ?? ""])
                await closeConnection()
            }
            record("regionUnavailable", ["region": targetRegion])
        }
        await closeConnection()
    }
}
