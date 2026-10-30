import Foundation
import Combine
import Darwin

public enum ProxyBridgeCLIState: Equatable, Sendable {
    case stopped, starting, waitingForApproval, running, failed(String)
}

public struct ProxyBridgeCLIOutput: Sendable {
    public private(set) var versionMatches = false
    public private(set) var profileApplied = false
    public private(set) var redirecting = false
    public private(set) var waitingForApproval = false
    public private(set) var failure: String?
    public var isReady: Bool { versionMatches && profileApplied && redirecting && failure == nil }
    public init() {}
    public mutating func consume(_ line: String) {
        if line == "ProxyBridge CLI \(ProxyBridgeRelease.version)" { versionMatches = true }
        if line == "Profile \"ChatGPT Only\": 1 proxies, 2 rules applied" { profileApplied = true }
        if line == "Redirecting traffic. Press Ctrl+C to stop." { redirecting = true }
        if line.contains("waiting for your approval") { waitingForApproval = true }
        if line.hasPrefix("ERROR:") || line.contains("rule(s) were rejected") || line.contains("will go direct") {
            failure = line
        }
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
    private var buffers: [Int: Data] = [:]
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
        for (index, pipe) in [stdout, stderr].enumerated() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil }
                Task { @MainActor [weak self] in self?.receive(bytes, stream: index, generation: id) }
            }
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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let failure = output.failure { throw CLIError.message(failure) }
            if !child.isRunning { throw CLIError.message("ProxyBridge CLI 启动失败（\(child.terminationStatus)）。请查看代理日志。") }
            if output.isReady {
                loadedProfile = data
                state = .running
                return
            }
            if output.waitingForApproval { state = .waitingForApproval }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CLIError.message("ProxyBridge CLI 启动超时，请检查网络扩展授权。")
    }

    private func receive(_ data: Data, stream: Int, generation id: UUID) {
        guard generation == id else { return }
        buffers[stream, default: Data()].append(data)
        while let end = buffers[stream]?.firstIndex(of: 10) {
            let line = String(decoding: buffers[stream]![..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffers[stream]!.removeSubrange(...end)
            output.consume(line)
            writeLog(line)
        }
        if buffers[stream, default: Data()].count > 65_536 {
            output.failureFromOversizedLine()
            buffers[stream] = Data()
        }
    }

    private func writeLog(_ line: String) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber, size.intValue >= 5_000_000 {
                let backup = logURL.appendingPathExtension("1")
                try? fm.removeItem(at: backup)
                try fm.moveItem(at: logURL, to: backup)
            }
            if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch { /* Diagnostic logging must not affect routing. */ }
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
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        pipes = []; buffers = [:]; loadedProfile = nil
    }
}

private extension ProxyBridgeCLIOutput {
    mutating func failureFromOversizedLine() { consume("ERROR: CLI 输出行过长。") }
}
private enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
