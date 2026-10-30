import Foundation
import CryptoKit
import Combine

public enum ProxyBridgeRelease {
    public static let version = "4.1.0"
    public static let downloadURL = URL(string: "https://github.com/InterceptSuite/ProxyBridge/releases/download/v4.1.0_MacOS/ProxyBridge-v4.1.0-Universal-Installer.pkg")!
    public static let sha256 = "c375fff53349f009e7bedacb47528642041776f859f58972bfad02b190ef7dec"
    public static let teamIdentifier = "L4HJT32Z59"
    public static let applicationURL = URL(fileURLWithPath: "/Applications/ProxyBridge.app")
}

public enum ProxyBridgeInstallationStatus: Equatable, Sendable {
    case missing, incompatible(String?), unusable(String), ready
    public var requiresRepair: Bool { self != .ready }
    public var detail: String {
        switch self {
        case .missing: "未安装 · 需要 \(ProxyBridgeRelease.version)"
        case let .incompatible(version): "当前 \(version ?? "未知") · 需要 \(ProxyBridgeRelease.version)"
        case .unusable: "安装损坏或无法验证"
        case .ready: "已安装 \(ProxyBridgeRelease.version)"
        }
    }
    public static func inspect(at url: URL = ProxyBridgeRelease.applicationURL) -> Self {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["CFBundleIdentifier"] as? String == "com.interceptsuite.ProxyBridge" else {
                return .unusable("应用标识无法验证")
            }
            let version = plist["CFBundleShortVersionString"] as? String
            guard version == ProxyBridgeRelease.version else { return .incompatible(version) }
            guard fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/ProxyBridge").path) else {
                return .unusable("CLI 文件缺失或不可执行")
            }
            return .ready
        } catch { return .unusable(error.localizedDescription) }
    }
}

public enum ProxyBridgeRepairStage: String, Sendable {
    case idle = "", downloading = "正在下载 ProxyBridge…", verifying = "正在校验安装包…"
    case installing = "正在安装 ProxyBridge…", activating = "正在启用代理…"
}

public struct ProxyBridgeRepairOperations: Sendable {
    public var inspect: @Sendable () -> ProxyBridgeInstallationStatus
    public var download: @Sendable (URL, UInt16) async throws -> Void
    public var validate: @Sendable (URL) async throws -> Void
    public var install: @Sendable (URL) async throws -> Void
    public init(inspect: @escaping @Sendable () -> ProxyBridgeInstallationStatus,
                download: @escaping @Sendable (URL, UInt16) async throws -> Void,
                validate: @escaping @Sendable (URL) async throws -> Void,
                install: @escaping @Sendable (URL) async throws -> Void) {
        self.inspect = inspect; self.download = download; self.validate = validate; self.install = install
    }
    public static let live = Self(inspect: { .inspect() }, download: { destination, port in
        _ = try await RepairCommand.run("/usr/bin/curl", ["--disable", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "120", "--proto", "=https", "--proto-redir", "=https", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:\(port)", "--output", destination.path, ProxyBridgeRelease.downloadURL.absoluteString], cancellable: true)
    }, validate: { package in
        let data = try Data(contentsOf: package)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == ProxyBridgeRelease.sha256 else { throw RepairError.message("安装包 SHA-256 不匹配，已拒绝安装。") }
        let signature = try await RepairCommand.run("/usr/sbin/pkgutil", ["--check-signature", package.path], cancellable: true)
        guard signature.contains("Developer ID Installer:"), signature.contains("(\(ProxyBridgeRelease.teamIdentifier))") else {
            throw RepairError.message("安装包签名团队不匹配，已拒绝安装。")
        }
    }, install: { package in
        _ = try await RepairCommand.run("/usr/bin/osascript", ["-e", "on run argv\n do shell script (\"/usr/sbin/installer -pkg \" & quoted form of (item 1 of argv) & \" -target /\") with administrator privileges\nend run", package.path], cancellable: false)
    })
}

@MainActor
public final class ProxyBridgeRepairService: ObservableObject {
    @Published public private(set) var stage: ProxyBridgeRepairStage = .idle
    private var task: Task<Void, Error>?
    private let operations: ProxyBridgeRepairOperations
    public var isBusy: Bool { task != nil }
    public var canCancel: Bool { stage == .downloading || stage == .verifying || stage == .activating }
    public init(operations: ProxyBridgeRepairOperations = .live) { self.operations = operations }

    public func cancel() { if canCancel { task?.cancel() } }
    public func finishOrCancel() async {
        // Let an in-flight installer finish, but never start the CLI while quitting.
        task?.cancel()
        _ = try? await task?.value
    }
    public func repair(proxyPort: UInt16, beforeInstall: @escaping @MainActor () async throws -> Void,
                       activate: @escaping @MainActor () async throws -> Void) async throws {
        if let task { return try await task.value }
        let operation = Task {
            defer { stage = .idle }
            if operations.inspect().requiresRepair {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-proxy-repair-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let package = directory.appendingPathComponent("ProxyBridge.pkg")
                stage = .downloading
                do { try await operations.download(package, proxyPort) }
                catch is CancellationError { throw CancellationError() }
                catch { throw RepairError.message("下载 ProxyBridge 失败，请检查本地代理端口和网络：\(error.localizedDescription)") }
                try Task.checkCancellation()
                stage = .verifying
                try await operations.validate(package)
                try Task.checkCancellation()
                stage = .installing
                try await beforeInstall()
                try await operations.install(package)
                let status = operations.inspect()
                guard status == .ready else { throw RepairError.message("安装后验证未通过：\(status.detail)") }
            }
            try Task.checkCancellation()
            stage = .activating
            try await activate()
        }
        task = operation
        defer { task = nil }
        try await operation.value
    }
}

private enum RepairError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

private final class RepairCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }
    private func execute(_ executable: String, _ arguments: [String]) throws -> String {
        let child = Process(), output = Pipe()
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"; child.environment = environment
        child.standardOutput = output; child.standardError = output
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard child.terminationStatus == 0 else {
            if message.contains("(-128)") { throw CancellationError() }
            throw RepairError.message(message.isEmpty ? "命令退出码 \(child.terminationStatus)" : message)
        }
        return message
    }
    static func run(_ executable: String, _ arguments: [String], cancellable: Bool) async throws -> String {
        let command = RepairCommand()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try command.execute(executable, arguments) }.value
        } onCancel: { if cancellable { command.cancel() } }
    }
}
