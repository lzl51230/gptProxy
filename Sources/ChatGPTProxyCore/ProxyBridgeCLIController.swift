import Foundation
import Combine
import Darwin

public enum ProxyBridgeCLIState: Equatable, Sendable {
    case stopped, starting, waitingForApproval, running, failed(String)
}

public struct ProxyBridgeCLIOutput: Codable, Sendable, Equatable {
    public private(set) var versionMatches = false
    public private(set) var profileApplied = false
    public private(set) var redirecting = false
    public private(set) var dnsDisabled = false
    public private(set) var waitingForApproval = false
    public private(set) var failure: String?
    public var isReady: Bool { (try? lifecycle(alive:true,elapsed:0,timeout:330).ready) ?? false }
    struct Lifecycle: Decodable { let phase: String; let ready: Bool; let failure: String? }
    func lifecycle(alive: Bool, elapsed: Double, timeout: Double, exitCode: Int32 = -1) throws -> Lifecycle {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        return try RustCore().call(["op":"cliStatus", "platform":"macos", "state":value, "alive":alive, "elapsed":elapsed, "timeout":timeout, "exitCode":exitCode])
    }
    public init() {}
    public mutating func consume(_ line: String) {
        let state = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        self = try! RustCore().call(["op":"cliConsume", "state":state, "line":line, "platform":"macos"])
    }
}

@MainActor
public final class ProxyBridgeCLIController: ObservableObject {
    nonisolated public static let supportedVersion = ProxyBridgeRelease.version
    nonisolated public static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ChatGPT Proxy/proxybridge.log")
    @Published public private(set) var state: ProxyBridgeCLIState = .stopped
    private let executableURL: URL
    private let timeout: TimeInterval
    private let logURL: URL
    private var process: Process?
    private var pipes: [Pipe] = []
    private var generation = UUID()
    private var output = ProxyBridgeCLIOutput()
    private var reader: CLIOutputReader?
    private var loadedProfile: Data?
    private var startup: Task<Void, Error>?
    public var processIdentifier: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }
    public var isReady: Bool { state == .running && process?.isRunning == true }

    public init(executableURL: URL = URL(fileURLWithPath: "/Applications/ProxyBridge.app/Contents/MacOS/ProxyBridge"), timeout: TimeInterval = 330, logURL: URL = ProxyBridgeCLIController.logURL) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.logURL = logURL
    }

    public func ensureRunning(profileData: Data) async throws {
        guard ProxyBridgeConfigurationParser.isBundledProfileValid(profileData) else {
            throw CLIError.message("内置代理规则无效，请重新安装启动器。")
        }
        if let startup { return try await startup.value }
        if isReady && loadedProfile == profileData { return }
        let task = Task { try await self.start(profileData) }
        startup = task
        do { try await task.value; startup = nil }
        catch {
            startup = nil
            await terminate()
            state = error is CancellationError ? .stopped : .failed(error.localizedDescription)
            throw error
        }
    }

    private func start(_ data: Data) async throws {
        await terminate()
        try Task.checkCancellation()
        state = .starting
        output = ProxyBridgeCLIOutput()
        let id = UUID(); generation = id
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--cli", "--profile", "-", "--verbose", "1"]
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        pipes = [input, stdout, stderr]
        child.standardInput = input; child.standardOutput = stdout; child.standardError = stderr
        reader = try CLIOutputReader(handles: [stdout, stderr].map(\.fileHandleForReading), logURL: logURL) { [weak self] value in
            guard let self, self.generation == id else { return }
            self.output = value
            if self.state == .running, let failure = value.failure { self.state = .failed(failure) }
        }
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                if self.state == .running { self.state = .failed("ProxyBridge CLI 已退出（\(status)），请重新启用代理。") }
            }
        }
        process = child
        try child.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let began = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let alive = child.isRunning
            let lifecycle = try output.lifecycle(alive:alive, elapsed:(ContinuousClock.now - began).seconds,
                                                 timeout:timeout, exitCode:alive ? -1 : child.terminationStatus)
            if let failure = lifecycle.failure { throw CLIError.message(failure) }
            if lifecycle.ready { loadedProfile = data; state = .running; return }
            if lifecycle.phase == "waitingForApproval" { state = .waitingForApproval }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    public func stopAndWait() async {
        let pending = startup
        pending?.cancel()
        _ = try? await pending?.value
        startup = nil
        await terminate()
        state = .stopped
    }

    private func cleanupPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }

    private func terminate() async {
        generation = UUID()
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(6)
            while process.isRunning && Date() < deadline { await cleanupPause() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { await cleanupPause() }
        }
        process?.terminationHandler = nil
        process = nil
        await reader?.stopAndWait()
        reader = nil
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        pipes = []; loadedProfile = nil
    }
}

private enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
