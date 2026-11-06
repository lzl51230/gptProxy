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
    private let policyCore = RustCore()
    private let defaults: UserDefaults
    private static let regionsKey = "monitorRegionPreferences"
    private var preferenceRevision = 0
    private var lifecycleRevision = 0
    private var task: Task<Void, Never>?
    private var port: UInt16 = 7890
    private var pendingStop: Task<Void, Never>?
    private var connection: (any CodexConnection)?
    private var ticking = false
    private var nextDelay: Duration = .seconds(2)
    private let operations: AutoSwitchOperations
    private let clockOrigin: ContinuousClock.Instant
    private let writesLog: Bool
    private var activity: NSObjectProtocol?
    private let logger = Logger(subsystem: "local.alex.chatgpt-proxy", category: "Monitor")
    public static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ChatGPT Proxy/monitor.jsonl")

    public convenience init() { self.init(operations: .live, writesLog: true) }

    init(operations: AutoSwitchOperations, writesLog: Bool = false, defaults: UserDefaults = .standard) {
        clockOrigin = operations.now()
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
        guard let current = snapshot.current else { throw MonitorError.message("无法解析当前节点") }
        let proxies = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.proxies))
        return try policyCore.call(["op":"monitorCandidates", "current":current, "origins":resolver.origins,
                                    "names":snapshot.proxies["GLOBAL"]?.all ?? [], "proxies":proxies])
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
        connectionSeconds = 0; latency = nil; consecutiveFailures = 0
        disconnectReason = nil; retrySeconds = nil
        _ = try? policyCore.object(["op":"monitorWorkflow", "action":"reset"])
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

    private func publish(_ value: [String:Any]) {
        status = value["status"] as? String ?? status
        phase = MonitorPhase(rawValue: value["phase"] as? String ?? "") ?? .retrying
        currentNode = value["currentNode"] as? String ?? "未知"
        latency = value["latency"] as? Int
        connectionSeconds = value["connectionSeconds"] as? Double ?? 0
        consecutiveFailures = value["consecutiveFailures"] as? Int ?? 0
        disconnectReason = value["disconnectReason"] as? String
        retrySeconds = value["retrySeconds"] as? Int
        lastSwitch = value["lastSwitch"] as? String ?? lastSwitch
        nextDelay = .seconds(value["nextDelay"] as? Double ?? 2)
        if let candidates = value["candidates"] as? [String:[String]], !candidates.isEmpty { updateRegionCatalog(candidates) }
    }

    // This adapter only performs requested I/O. Ordering, context checks, retry,
    // recovery and candidate acceptance are owned by the shared Rust workflow.
    private func perform(_ effect: [String:Any]) async throws -> Any {
        let args = effect["args"] as? [String:Any] ?? [:]
        switch effect["op"] as? String {
        case "snapshot":
            let snapshot = try await operations.snapshot(port)
            let resolver = try? await operations.resolver()
            return ["socket":snapshot.socket, "mode":snapshot.mode,
                    "current":snapshot.current as Any? ?? NSNull(), "selection":snapshot.selectionSignature,
                    "proxies":try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.proxies)),
                    "signature":resolver.map { Array($0.signature) } as Any? ?? NSNull(),
                    "origins":resolver?.origins ?? [:]] as [String:Any]
        case "heartbeat":
            if connection == nil { connection = operations.makeConnection(port) }
            let result = try await connection!.heartbeat()
            record("heartbeat", ["node":currentNode, "seconds":String(result.connectionSeconds),
                                 "delay":result.latencyMilliseconds.map(String.init) ?? "failed", "reason":result.failureReason ?? ""])
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        case "closeConnection": await closeConnection(); return NSNull()
        case "sleep": try await operations.sleep(.seconds(effect["args"] as? Double ?? 0)); return NSNull()
        case "delays":
            let names = args["names"] as? [String] ?? [], socket = args["socket"] as? String ?? ""
            let measure = operations.delay
            return await withTaskGroup(of: (String,Int?).self) { group in
                for name in names { group.addTask { (name, try? await measure(socket,name)) } }
                var results: [String:Int] = [:]
                for await (name,delay) in group { if let delay { results[name] = delay } }
                return results
            }
        case "connections": return try await operations.connections(args["socket"] as? String ?? "", args["node"] as? String ?? "")
        case "select": try await operations.select(args["socket"] as? String ?? "", args["name"] as? String ?? ""); return NSNull()
        case "close": try await operations.close(args["socket"] as? String ?? "", args["id"] as? String ?? ""); return NSNull()
        default: throw MonitorError.message("Unknown shared monitor effect")
        }
    }

    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let revision = preferenceRevision, lifecycle = lifecycleRevision
        do {
            let preferences = try JSONSerialization.jsonObject(with: JSONEncoder().encode(regions))
            var request: [String:Any] = ["op":"monitorWorkflow", "action":"begin", "regions":preferences]
            while true {
                try requireCurrent(revision,lifecycle)
                request["now"] = (operations.now() - clockOrigin).seconds
                guard let response = try policyCore.object(request) as? [String:Any],
                      let state = response["state"] as? [String:Any] else { throw MonitorError.message("Invalid shared monitor response") }
                publish(state)
                if response["done"] as? Bool == true { break }
                guard let effect = response["effect"] as? [String:Any], let id = effect["id"] else { throw MonitorError.message("Missing shared monitor effect") }
                request = ["op":"monitorWorkflow", "action":"complete", "id":id]
                do { request["value"] = try await perform(effect) }
                catch is CancellationError { throw CancellationError() }
                catch { request["error"] = error.localizedDescription }
            }
        } catch {
            guard lifecycle == lifecycleRevision else { return }
            await closeConnection()
            guard lifecycle == lifecycleRevision else { return }
            clearObservation()
            phase = .connecting
            status = error is CancellationError ? "Codex 监控已取消，等待重新连接" : error.localizedDescription
        }
    }
}
