import Combine
import Foundation
import OSLog

struct AutoSwitchOperations: Sendable {
    var snapshot: @Sendable (UInt16) async throws -> ClashSnapshot
    var probe: @Sendable (UInt16) async throws -> Int
    var resolver: @Sendable () async throws -> NodeOriginResolver
    var delay: @Sendable (String, String) async throws -> Int
    var select: @Sendable (String, String) async throws -> Void
    var connections: @Sendable (String, String) async throws -> [String]
    var close: @Sendable (String, String) async throws -> Void
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    static let live = AutoSwitchOperations(
        snapshot: { try await ClashControllerClient().snapshot(port: $0) },
        probe: { try await MonitorHTTP.probe(port: $0) },
        resolver: { try await Task.detached(priority: .utility) { try NodeOriginResolver() }.value },
        delay: { try await ClashControllerClient().delay(socket: $0, name: $1) },
        select: { try await ClashControllerClient().select(socket: $0, name: $1) },
        connections: { try await ClashControllerClient().oldConnections(socket: $0, node: $1) },
        close: { try await ClashControllerClient().close(socket: $0, id: $1) }
    )
}

@MainActor
public final class AutoSwitchMonitor: ObservableObject {
    @Published public private(set) var status = "等待监控"
    @Published public private(set) var currentNode = "未知"
    @Published public private(set) var latency: Int?
    @Published public private(set) var lastSwitch = "尚未切换"
    @Published public private(set) var paused: Bool
    private var task: Task<Void, Never>?
    private var port: UInt16 = 7890
    private let operations: AutoSwitchOperations
    private let writesLog: Bool
    private var cooldownUntil: ContinuousClock.Instant?
    private var activity: NSObjectProtocol?
    private let logger = Logger(subsystem: "local.alex.chatgpt-proxy", category: "Monitor")
    public static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ChatGPT Proxy/monitor.jsonl")

    public convenience init() { self.init(operations: .live, writesLog: true) }

    init(operations: AutoSwitchOperations, writesLog: Bool = false) {
        self.writesLog = writesLog
        self.operations = operations
        paused = UserDefaults.standard.bool(forKey: "monitorPaused")
    }

    public func start(port: UInt16) {
        stop()
        self.port = port
        guard !paused else { status = "监控已暂停"; return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "代理健康监控")
        task = Task { [weak self] in
            while !Task.isCancelled {
                let began = ContinuousClock.now
                await self?.tick()
                do { try await ContinuousClock().sleep(until: max(began.advanced(by: .seconds(1)), .now)) }
                catch { break }
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    public func togglePaused() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "monitorPaused")
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

    func tick() async {
        do {
            let snapshot = try await operations.snapshot(port)
            try Task.checkCancellation()
            currentNode = snapshot.current ?? "未知"
            let delay: Int?
            do { delay = try await operations.probe(port) }
            catch is CancellationError { throw CancellationError() }
            catch { delay = nil }
            try Task.checkCancellation()
            latency = delay
            record("probe", ["node": currentNode, "delay": delay.map(String.init) ?? "failed", "mode": snapshot.mode])
            guard snapshot.mode == "global" else { status = "仅全局模式支持自动切换"; return }
            if let until = cooldownUntil, operations.now() < until {
                status = "切换后冷却中（5 秒）"; return
            }
            if let delay, delay <= AutoSwitchPolicy.threshold { status = "Google 连通正常"; return }
            try await recover(snapshot)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            status = error.localizedDescription
            record("error", ["message": status])
        }
    }

    private func recover(_ original: ClashSnapshot) async throws {
        guard let current = original.current else { status = "无法解析当前节点"; return }
        let resolver = try await operations.resolver()
        try Task.checkCancellation()
        guard let source = resolver.origins[current], let region = NodeOriginResolver.region(current) else {
            status = "节点订阅或地区不明确，保持原节点"; return
        }
        let excluded = Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"])
        let candidates = (original.proxies["GLOBAL"]?.all ?? []).filter {
            guard let proxy = original.proxies[$0], proxy.all == nil, !excluded.contains(proxy.type.uppercased()) else { return false }
            return resolver.origins[$0] == source && NodeOriginResolver.region($0) == region
        }.sorted()
        status = "正在测速 \(region) · \(candidates.count) 个节点"
        record("testing", ["node": current, "region": region, "count": String(candidates.count)])
        var delays: [String: Int] = [:]
        // Bounded batches keep repeated failures from spawning unbounded processes.
        for offset in stride(from: 0, to: candidates.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(candidates[offset..<min(offset + 4, candidates.count)])
            let results = await withTaskGroup(of: (String, Int?).self) { group in
                for name in batch {
                    let delayOperation = self.operations.delay
                    group.addTask { (name, try? await delayOperation(original.socket, name)) }
                }
                var values: [(String, Int?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (name, delay) in results {
                if let delay { delays[name] = delay }
                record("nodeTest", ["node": name, "delay": delay.map(String.init) ?? "failed"])
            }
        }
        try Task.checkCancellation()
        guard let winner = AutoSwitchPolicy.winner(delays, current: current) else {
            status = "同订阅同地区没有 ≤800ms 的节点，保持原节点"; return
        }
        guard winner != current else { status = "当前节点已恢复且最快"; return }
        let latest = try await operations.snapshot(port)
        let freshResolver = try await operations.resolver()
        guard latest.socket == original.socket, latest.mode == "global",
              latest.selectionSignature == original.selectionSignature,
              latest.proxies["GLOBAL"]?.all == original.proxies["GLOBAL"]?.all,
              freshResolver.signature == resolver.signature else {
            status = "选择或配置已变化，放弃本轮切换"; return
        }
        let ids = (try? await operations.connections(original.socket, current)) ?? []
        try Task.checkCancellation()
        try await operations.select(original.socket, winner)
        // A successful PUT is already a change. Start cooldown even if readback fails,
        // avoiding a second PUT when the controller drops its response.
        cooldownUntil = operations.now().advanced(by: .seconds(5))
        let confirmed = try await operations.snapshot(port)
        guard confirmed.current == winner else { status = "节点切换未能确认"; return }
        cooldownUntil = operations.now().advanced(by: .seconds(5))
        currentNode = winner
        lastSwitch = "\(current) → \(winner)（\(delays[winner]!)ms）"
        status = "切换成功，冷却 5 秒"
        record("switched", ["from": current, "to": winner, "delay": String(delays[winner]!)])
        for id in ids {
            try Task.checkCancellation()
            do { try await operations.close(original.socket, id) }
            catch { record("connectionCleanupFailed"); status = "已切换，部分旧连接清理失败" }
        }
    }
}
