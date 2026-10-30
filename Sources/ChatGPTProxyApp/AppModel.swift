import AppKit
import ChatGPTProxyCore
import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case ready
        case launching
        case configuringProfile
        case repairing(String)
        case failed(String)

        var message: String {
            switch self {
            case .idle:
                "等待检测"
            case .checking:
                "正在检测本地代理..."
            case .ready:
                "可以安全启动 ChatGPT"
            case .launching:
                "正在启动 ChatGPT..."
            case .configuringProfile:
                "正在配置 ProxyBridge..."
            case let .repairing(message): message
            case let .failed(message):
                message
            }
        }
    }

    let monitor = AutoSwitchMonitor()
    let cli = ProxyBridgeCLIController()
    let repairService = ProxyBridgeRepairService()
    private var repairObservation: AnyCancellable?
    private var cliObservation: AnyCancellable?


    @Published var proxyPort: Int {
        didSet {
            guard proxyPort != oldValue else { return }
            guard activeOperation == nil else { return }
            if let port = UInt16(exactly: proxyPort), port > 0 { monitor.start(port: port) }
            phase = .idle
            proxyReachable = false
            egressLocation = nil
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var chatGPTStatus: ChatGPTApplicationStatus = .notInstalled
    @Published private(set) var proxyBridgeInstalled = false
    @Published private(set) var proxyBridgeStatus: ProxyBridgeInstallationStatus = .missing
    @Published private(set) var extensionEnabled = false
    @Published private(set) var proxyBridgeProfileReady = false
    @Published private(set) var proxyReachable = false
    @Published private(set) var supportsUDP = false
    @Published private(set) var egressLocation: String?
    @Published private(set) var profileInstallRequiresManualFallback = false
    @Published var showingSetup = false

    private let defaults = UserDefaults.standard
    private let profileConfigurator: (@MainActor () async throws -> Void)?
    private let refreshAfterProfileConfiguration: (@MainActor () async -> Void)?
    private let relayLifecycle = RelayLifecycle()
    @Published private var activeOperation: UUID?

    static let chatGPTURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let proxyBridgeURL = URL(fileURLWithPath: "/Applications/ProxyBridge.app", isDirectory: true)

    init(
        profileConfigurator: (@MainActor () async throws -> Void)? = nil,
        refreshAfterProfileConfiguration: (@MainActor () async -> Void)? = nil
    ) {
        self.profileConfigurator = profileConfigurator
        self.refreshAfterProfileConfiguration = refreshAfterProfileConfiguration
        let stored = defaults.integer(forKey: "proxyPort")
        proxyPort = stored > 0 ? stored : Int(ProxyConfiguration.defaultProxyPort)
        cliObservation = cli.$state.sink { [weak self] state in
            guard let self else { return }
            self.proxyBridgeProfileReady = state == .running
            switch state {
            case .waitingForApproval: self.phase = .failed("等待 macOS 批准网络扩展，请打开网络扩展设置；可取消启用。")
            case let .failed(message): self.phase = .failed(message)
            default: break
            }
        }
        repairObservation = repairService.$stage.sink { [weak self] stage in
            guard stage != .idle else { return }
            self?.phase = .repairing(stage.rawValue)
        }
        if profileConfigurator == nil, let port = UInt16(exactly: proxyPort), port > 0 {
            monitor.start(port: port)
            Task {
                do { try await configureBundledProxyBridgeProfile(); await refreshStatus() }
                catch { phase = .failed(error.localizedDescription) }
            }
        }
    }

    var isBusy: Bool {
        activeOperation != nil
    }

    var chatGPTInstalled: Bool {
        chatGPTStatus == .supported
    }

    var chatGPTNeedsUpdate: Bool {
        chatGPTStatus == .requiresUpdate
    }

    var localProxyReady: Bool {
        StatusIssue.localProxyIsReady(
            reachable: proxyReachable,
            egressLocation: egressLocation
        )
    }

    func refreshStatus() async {
        guard let operation = beginOperation(phase: .checking) else { return }
        defer { endOperation(operation) }

        updateInstalledApps()
        extensionEnabled = await SystemExtensionChecker.proxyBridgeIsEnabled()
        proxyBridgeProfileReady = cli.isReady
        guard proxyBridgeInstalled else {
            phase = .failed("ProxyBridge 需要修复：\(proxyBridgeStatus.detail)")
            return
        }

        do {
            let port = try validatedPort()
            let health = try await ProxyHealthChecker.check(port: port)
            proxyReachable = true
            supportsUDP = health.supportsUDP
            egressLocation = health.egressLocation
            if health.egressLocation == "CN" {
                phase = .failed("代理出口仍位于 CN，请切换节点。")
            } else if chatGPTNeedsUpdate {
                phase = .failed(AppError.chatGPTUpdateRequired.localizedDescription)
            } else if !chatGPTInstalled {
                phase = .failed(AppError.chatGPTMissing.localizedDescription)
            } else if !extensionEnabled {
                phase = .failed("ProxyBridge 网络扩展尚未启用。")
            } else if !proxyBridgeProfileReady {
                phase = .failed("代理尚未运行，请启用代理。")
            } else {
                phase = .ready
            }
        } catch {
            proxyReachable = false
            supportsUDP = false
            egressLocation = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func launchChatGPT() async {
        guard let operation = beginOperation(phase: .launching) else { return }
        defer { endOperation(operation) }

        do {
            try await guardedRestartChatGPT()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func openCodexDirectory() {
        let url = AppPaths.codexDirectory()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            phase = .failed("无法打开 .codex：\(error.localizedDescription)")
        }
    }

    func openProxyBridge() {
        let url = ProxyBridgeCLIController.logURL
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { phase = .failed("尚无代理日志，请先启用代理。") }
    }

    var canCancelOperation: Bool {
        !repairService.isBusy || repairService.canCancel
    }
    func cancelProxyStartup() async {
        if repairService.isBusy { repairService.cancel() }
        if !repairService.isBusy || repairService.stage == .activating { await cli.stopAndWait() }
    }

    func shutdown() async {
        if repairService.stage == .activating { await cli.stopAndWait() }
        await repairService.finishOrCancel()
        monitor.stop()
        await cli.stopAndWait()
        await relayLifecycle.stopAndWait()
    }

    func openNetworkExtensionSettings() {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if
            let url = SystemSettingsDestination.networkExtensionsURL(macOSMajorVersion: majorVersion),
            NSWorkspace.shared.open(url)
        {
            return
        }

        let systemSettings = URL(
            fileURLWithPath: "/System/Applications/System Settings.app",
            isDirectory: true
        )
        if !NSWorkspace.shared.open(systemSettings) {
            phase = .failed("无法打开系统设置，请手动前往网络扩展设置。")
        }
    }

    func openChatGPTDownload() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download/")!)
    }

    func repairProxyBridge() {
        Task {
            guard let operation = beginOperation(phase: .repairing("正在检查 ProxyBridge…")) else { return }
            defer { endOperation(operation) }
            do {
                let port = try validatedPort()
                try await repairService.repair(proxyPort: port, beforeInstall: {
                    await self.cli.stopAndWait()
                    await self.relayLifecycle.stopAndWait()
                }, activate: {
                    try await self.configureBundledProxyBridgeProfile()
                })
                endOperation(operation)
                await refreshStatus()
            } catch is CancellationError {
                updateInstalledApps()
                phase = .idle
            } catch {
                updateInstalledApps()
                proxyBridgeProfileReady = cli.isReady
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func revealBundledProfile() {
        guard let source = Bundle.main.url(forResource: "ChatGPT-Only", withExtension: "pbprofile") else {
            phase = .failed("ProxyBridge 配置文件缺失。")
            return
        }
        let requestedDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatGPT-Only.pbprofile")
        let destination = CollisionSafeDestination.availableURL(for: requestedDestination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            phase = .failed("无法导出配置文件：\(error.localizedDescription)")
        }
    }

    func installAndActivateBundledProfile() async {
        guard let operation = beginOperation(phase: .configuringProfile) else { return }

        do {
            if let profileConfigurator {
                try await profileConfigurator()
            } else {
                try await configureBundledProxyBridgeProfile()
            }
            profileInstallRequiresManualFallback = false
            phase = .ready
            endOperation(operation)
            if let refreshAfterProfileConfiguration {
                await refreshAfterProfileConfiguration()
            } else {
                await refreshStatus()
            }
        } catch {
            profileInstallRequiresManualFallback = false
            phase = .failed(error.localizedDescription)
            endOperation(operation)
        }
    }

    private func validatedPort() throws -> UInt16 {
        try ProxyConfiguration.validatedPort(String(proxyPort))
    }

    private func updateInstalledApps() {
        chatGPTStatus = ChatGPTApplicationCompatibility.inspect(applicationURL: Self.chatGPTURL)
        proxyBridgeStatus = .inspect(at: Self.proxyBridgeURL)
        proxyBridgeInstalled = !proxyBridgeStatus.requiresRepair
    }

    private func configureBundledProxyBridgeProfile() async throws {
        updateInstalledApps()
        guard proxyBridgeInstalled else { throw AppError.launchStepFailed("ProxyBridge 需要修复", proxyBridgeStatus.detail) }
        guard let url = Bundle.main.url(forResource: "ChatGPT-Only", withExtension: "pbprofile") else { throw AppError.profileResourceMissing }
        let profile: Data
        do { profile = try Data(contentsOf: url) }
        catch { throw AppError.launchStepFailed("读取内置规则", error.localizedDescription) }
        let port = try validatedPort()
        let health = try await ProxyHealthChecker.check(port: port)
        try Task.checkCancellation()
        guard health.egressLocation != "CN" else { throw ProxyHealthError.unsupportedRegion(health.egressLocation) }
        try await ensureRelay(upstreamPort: port)
        // The upstream CLI distinguishes another CLI from its GUI and reports conflicts.
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.interceptsuite.ProxyBridge")
        for app in applications where app.processIdentifier != cliProcessIdentifier {
            if app.activationPolicy != .prohibited {
                let inspection = Process()
                let output = Pipe()
                defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
                inspection.executableURL = URL(fileURLWithPath: "/bin/ps")
                inspection.arguments = ["-p", String(app.processIdentifier), "-o", "args="]
                inspection.standardOutput = output
                inspection.standardError = FileHandle.nullDevice
                try inspection.run()
                let arguments = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                inspection.waitUntilExit()
                if inspection.terminationStatus == 0 && !arguments.contains("--") { app.terminate() }
            }
        }
        if !applications.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        try Task.checkCancellation()
        try await cli.ensureRunning(profileData: profile)
        extensionEnabled = await SystemExtensionChecker.proxyBridgeIsEnabled()
        guard extensionEnabled else { await cli.stopAndWait(); throw AppError.extensionDisabled }
        proxyBridgeProfileReady = cli.isReady
    }

    private var cliProcessIdentifier: pid_t { cli.processIdentifier ?? -1 }

    private func guardedRestartChatGPT() async throws {
        let port = try validatedPort()
        defaults.set(Int(port), forKey: "proxyPort")
        updateInstalledApps()
        guard chatGPTInstalled else {
            if chatGPTNeedsUpdate {
                throw AppError.chatGPTUpdateRequired
            }
            throw AppError.chatGPTMissing
        }
        guard proxyBridgeInstalled else { throw AppError.launchStepFailed("ProxyBridge 需要修复", proxyBridgeStatus.detail) }


        let health = try await ProxyHealthChecker.check(port: port)
        guard health.egressLocation != "CN" else {
            throw ProxyHealthError.unsupportedRegion(health.egressLocation)
        }
        proxyReachable = true
        supportsUDP = health.supportsUDP
        egressLocation = health.egressLocation

        try await configureBundledProxyBridgeProfile()

        try await restartChatGPT()
    }

    private func beginOperation(phase newPhase: Phase) -> UUID? {
        guard activeOperation == nil else { return nil }
        let operation = UUID()
        activeOperation = operation
        phase = newPhase
        return operation
    }

    private func endOperation(_ operation: UUID) {
        guard activeOperation == operation else { return }
        activeOperation = nil
    }

    private func ensureRelay(upstreamPort: UInt16) async throws {
        do {
            try await relayLifecycle.ensureRunning(upstreamPort: upstreamPort)
        } catch {
            let underlying = error as NSError
            throw AppError.launchStepFailed(
                "启动中继 127.0.0.1:\(ProxyConfiguration.relayPort)",
                "\(error.localizedDescription) [\(underlying.domain):\(underlying.code)]"
            )
        }
    }

    private func restartChatGPT() async throws {
        runningChatGPTApplications().forEach { $0.terminate() }
        for _ in 0..<30 {
            if runningChatGPTApplications().isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard runningChatGPTApplications().isEmpty else {
            throw AppError.chatGPTDidNotTerminate
        }
        try await openApplication(at: Self.chatGPTURL, activates: true)
    }

    private func runningChatGPTApplications() -> [NSRunningApplication] {
        ChatGPTApplicationCompatibility.runningBundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    }

    private func openApplication(at url: URL, activates: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        if url == Self.chatGPTURL {
            configuration.arguments = ChatGPTApplicationCompatibility.proxyLaunchArguments
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw AppError.launchStepFailed("打开 \(url.deletingPathExtension().lastPathComponent)", error.localizedDescription)
        }
    }
}

enum AppError: LocalizedError, Equatable {
    case launchStepFailed(String, String)
    case chatGPTMissing
    case chatGPTUpdateRequired
    case proxyBridgeMissing
    case extensionDisabled
    case chatGPTDidNotTerminate
    case unsupportedProxyBridgeVersion(String?)
    case profileResourceMissing

    var errorDescription: String? {
        switch self {
        case let .launchStepFailed(step, detail):
            "\(step)失败：\(detail)"
        case .chatGPTMissing:
            "尚未安装官方 ChatGPT。"
        case .chatGPTUpdateRequired:
            "当前 ChatGPT 版本不支持 Codex API Key，请更新官方客户端。"
        case .proxyBridgeMissing:
            "尚未安装 ProxyBridge，请先完成首次配置。"
        case .extensionDisabled:
            "请在系统设置中允许 ProxyBridge 网络扩展，然后重试。"
        case .chatGPTDidNotTerminate:
            "现有 ChatGPT 未能在 3 秒内退出，已中止启动。请手动退出后重试。"
        case let .unsupportedProxyBridgeVersion(version):
            "自动配置仅支持 ProxyBridge \(ProxyBridgeCLIController.supportedVersion)，当前版本为 \(version ?? "未知")。请通过命令行安装器升级。"
        case .profileResourceMissing:
            "ChatGPT Only 配置资源缺失，请重新安装启动器。"
        }
    }
}
