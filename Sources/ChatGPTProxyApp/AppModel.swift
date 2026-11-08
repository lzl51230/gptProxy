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
        case waiting(String)
        case paused
        case launching
        case configuringProfile
        case preparingClashDNS
        case clashDNSReady
        case repairing(String)
        case failed(String)

        var message: String {
            switch self {
            case .idle:
                "等待检测"
            case .checking:
                "正在检测本地代理..."
            case .ready:
                "代理与 DNS 保护正常"
            case let .waiting(message): message
            case .paused: "DNS 保护已暂停，使用原 DNS"
            case .launching:
                "正在启动 ChatGPT..."
            case .configuringProfile:
                "正在配置 ProxyBridge..."
            case .clashDNSReady:
                "Clash DNS 已就绪"
            case .preparingClashDNS:
                "正在验证保护期间的加密 DNS 配置…"
            case let .repairing(message): message
            case let .failed(message):
                message
            }
        }
    }

    let monitor = AutoSwitchMonitor()
    let cli = ProxyBridgeCLIController()
    let repairService = ProxyBridgeRepairService()
    let dns = DNSProtectionController()
    let gpt = GPTProcessMonitor()
    let recovery = ProtectionSupervisor()
    private var maintenance: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []
    private var shuttingDown = false
    private var summaryScheduled = false
    private var pendingPortChange = false
    private var operationPort: Int?
    private var nextInstallationCheck: TimeInterval = 0
    @Published private(set) var protectionPaused: Bool
    private var dnsObservation: AnyCancellable?
    private var clashDNSObservation: AnyCancellable?
    private var repairObservation: AnyCancellable?
    private var cliObservation: AnyCancellable?


    @Published var proxyPort: Int {
        didSet {
            guard proxyPort != oldValue else { return }
            pendingPortChange = true
            operationCancelled = true
            recovery.reset()
            dns.resetClashCheck()
            proxyReachable = false
            codexLatencyMilliseconds = nil
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
    @Published private(set) var codexLatencyMilliseconds: Int?
    @Published private(set) var profileInstallRequiresManualFallback = false
    @Published private(set) var applyingProtection = false
    @Published var showingSetup = false

    private let defaults: UserDefaults
    private let protectedLauncher: (@MainActor () async throws -> Void)?
    private let profileConfigurator: (@MainActor () async throws -> Void)?
    private let refreshAfterProfileConfiguration: (@MainActor () async -> Void)?
    private let relayLifecycle = RelayLifecycle()
    @Published private var activeOperation: UUID?
    private var operationCancelled = false

    static let chatGPTURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    static let proxyBridgeURL = URL(fileURLWithPath: "/Applications/ProxyBridge.app", isDirectory: true)

    init(
        profileConfigurator: (@MainActor () async throws -> Void)? = nil,
        refreshAfterProfileConfiguration: (@MainActor () async -> Void)? = nil,
        defaults: UserDefaults = .standard,
        protectedLauncher: (@MainActor () async throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.protectedLauncher = protectedLauncher
        protectionPaused = defaults.bool(forKey: "dnsProtectionPaused")
        self.profileConfigurator = profileConfigurator
        self.refreshAfterProfileConfiguration = refreshAfterProfileConfiguration
        let stored = defaults.integer(forKey: "proxyPort")
        proxyPort = stored > 0 ? stored : Int(ProxyConfiguration.defaultProxyPort)
        clashDNSObservation = dns.$clashCheck.sink { [weak self] _ in self?.scheduleSummary() }
        dnsObservation = dns.$status.sink { [weak self] _ in self?.scheduleSummary() }
        cliObservation = cli.$state.sink { [weak self] _ in self?.scheduleSummary() }
        monitor.objectWillChange.sink { [weak self] _ in self?.scheduleSummary() }.store(in: &observations)
        gpt.objectWillChange.sink { [weak self] _ in self?.scheduleSummary() }.store(in: &observations)
        repairObservation = repairService.$stage.sink { [weak self] stage in
            guard stage != .idle else { return }
            self?.phase = .repairing(stage.rawValue)
        }
        if profileConfigurator == nil {
            updateInstalledApps()
            if let port = UInt16(exactly: proxyPort), port > 0 { monitor.start(port: port) }
            gpt.start()
            dns.startMonitoring()
            maintenance = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.maintainProtection()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    private func scheduleSummary() {
        guard !summaryScheduled else { return }
        summaryScheduled = true
        // Combine publishes before assigning the new value.
        Task { @MainActor [weak self] in
            self?.summaryScheduled = false
            self?.updateSummary()
        }
    }

    func resumeAfterWake() {
        recovery.reset()
        nextInstallationCheck = 0
        gpt.refresh()
        if let port = UInt16(exactly: proxyPort), port > 0 { monitor.start(port: port) }
        Task { await maintainProtection() }
    }

    private func maintainProtection() async {
        guard !shuttingDown, activeOperation == nil else { return }
        if ProcessInfo.processInfo.systemUptime >= nextInstallationCheck {
            updateInstalledApps()
            extensionEnabled = await SystemExtensionChecker.proxyBridgeIsEnabled()
            nextInstallationCheck = ProcessInfo.processInfo.systemUptime + 30
        }
        guard !shuttingDown, activeOperation == nil else { return }
        let enabled = dns.status.isEnabled && cli.isReady && extensionEnabled && !pendingPortChange
        if protectionPaused && (dns.status.phase != .disabled || !cli.isReady || pendingPortChange) && recovery.retrySeconds == 0 {
            guard let operation = beginOperation(phase: .configuringProfile) else { return }
            await recovery.tick(enabled: false, paused: false, prepare: {
                if self.dns.status.phase != .disabled { try await self.dns.restore() }
                try self.checkOperationCancellation()
                guard self.extensionEnabled else { throw AppError.extensionDisabled }
                if !self.cli.isReady || self.pendingPortChange { try await self.configureBundledProxyBridgeProfile() }
            }, activate: {})
            endOperation(operation)
        } else if !protectionPaused && !enabled && recovery.retrySeconds == 0 {
            guard let operation = beginOperation(phase: .checking) else { return }
            await recovery.tick(enabled: false, paused: false, prepare: {
                try self.checkOperationCancellation()
                if self.dns.status.phase != .disabled { try await self.dns.restore() }
                try self.checkOperationCancellation()
                guard self.extensionEnabled else { throw AppError.extensionDisabled }
                try await self.configureBundledProxyBridgeProfile()
                _ = try await self.dns.requireClashDNS(port: self.proxyPort)
                try await self.dns.requireInstalledHelper()
                try self.checkOperationCancellation()
            }, activate: {
                try await self.activateProtection(launchGPT: false, allowAuthorization: false)
            })
            endOperation(operation)
        } else if enabled || (protectionPaused && dns.status.phase == .disabled && cli.isReady && !pendingPortChange) {
            await recovery.tick(enabled: enabled, paused: protectionPaused, prepare: {}, activate: {})
        }
        updateSummary()
    }

    private func updateSummary() {
        objectWillChange.send()
        guard profileConfigurator == nil, activeOperation == nil, !shuttingDown else { return }
        proxyBridgeProfileReady = cli.isReady
        if !monitor.paused {
            proxyReachable = monitor.phase == .maintaining && monitor.latency != nil
            codexLatencyMilliseconds = proxyReachable ? monitor.latency : nil
        }
        if protectionPaused {
            phase = dns.status.phase == .disabled ? .paused
                : .failed("暂停保护尚未完成：\(dns.status.detail)")
        } else if !proxyBridgeInstalled {
            phase = .failed("ProxyBridge 需要修复：\(proxyBridgeStatus.detail)")
        } else if !extensionEnabled {
            phase = .failed("ProxyBridge 网络扩展尚未启用，请在系统设置中批准。")
        } else if dns.status.isEnabled && cli.isReady {
            phase = proxyReachable ? .ready : .waiting("DNS 已保护，正在恢复代理连接…")
        } else {
            let reason = recovery.lastError ?? dns.status.detail
            let delay = recovery.retrySeconds > 0 ? "（\(recovery.retrySeconds) 秒后重试）" : ""
            let prefix = proxyReachable && dns.status.phase == .disabled
                ? "联网已恢复，DNS 保护待恢复" : "DNS 保护待恢复"
            phase = .waiting("\(prefix)：\(reason)\(delay)")
        }
        ProtectionDiagnostics.record(phase: phase.message, dns: dns.status,
            pids: gpt.processIdentifiers, paused: protectionPaused, retry: recovery.failures,
            proxyReady: proxyReachable, cliReady: cli.isReady)
    }

    var isBusy: Bool {
        activeOperation != nil
    }

    var protectionReady: Bool { dns.status.isEnabled && cli.isReady && !applyingProtection }
    var protectionDetail: String {
        applyingProtection ? "正在应用 DNS 与 IPv4 策略，重建网络连接" : dns.status.detail
    }

    var chatGPTInstalled: Bool {
        chatGPTStatus == .supported
    }

    var chatGPTNeedsUpdate: Bool {
        chatGPTStatus == .requiresUpdate
    }

    var localProxyReady: Bool {
        proxyReachable
    }

    func refreshStatus() async {
        guard let operation = beginOperation(phase: .checking) else { return }
        defer { endOperation(operation); updateSummary() }
        await dns.refresh()
        _ = try? await dns.checkClash(port: proxyPort)

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
            codexLatencyMilliseconds = health.codexLatencyMilliseconds
            if chatGPTNeedsUpdate {
                phase = .failed(AppError.chatGPTUpdateRequired.localizedDescription)
            } else if !chatGPTInstalled {
                phase = .failed(AppError.chatGPTMissing.localizedDescription)
            } else if !extensionEnabled {
                phase = .failed("ProxyBridge 网络扩展尚未启用。")
            } else if !proxyBridgeProfileReady {
                phase = .failed("代理尚未运行，请启用代理。")
            } else if !dns.clashCheck.isReady {
                phase = .failed(dns.clashCheck.detail)
            } else if !dns.status.isEnabled {
                phase = .failed(dns.status.detail)
            } else {
                phase = .ready
            }
        } catch {
            proxyReachable = false
            supportsUDP = false
            codexLatencyMilliseconds = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func launchChatGPT() async {
        guard let operation = beginOperation(phase: .launching) else { return }
        defer { endOperation(operation) }

        do {
            try await guardedRestartChatGPT()
            setProtectionPaused(false)
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
        phase != .preparingClashDNS && (!repairService.isBusy || repairService.canCancel)
    }
    func cancelProxyStartup() async {
        operationCancelled = true
        setProtectionPaused(true)
        recovery.reset()
        if repairService.isBusy { repairService.cancel() }
        if !repairService.isBusy || repairService.stage == .activating { await cli.stopAndWait() }
        while activeOperation != nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await dns.restore()
        updateSummary()
    }

    func shutdown() async {
        shuttingDown = true
        operationCancelled = true
        recovery.reset()
        maintenance?.cancel()
        if !repairService.isBusy { await cli.stopAndWait() }
        if repairService.canCancel { repairService.cancel() }
        while activeOperation != nil { try? await Task.sleep(for: .milliseconds(100)) }
        await maintenance?.value
        maintenance = nil
        gpt.stop()
        dns.stopMonitoring()
        do { try await dns.restore() }
        catch { phase = .failed(error.localizedDescription) }
        if repairService.stage == .activating { await cli.stopAndWait() }
        await repairService.finishOrCancel()
        await monitor.stopAndWait()
        await cli.stopAndWait()
        await relayLifecycle.stopAndWait()
    }

    func enableDNSProtection() async {
        guard let operation = beginOperation(phase: .configuringProfile) else { return }
        setProtectionPaused(false)
        recovery.reset()
        defer { endOperation(operation) }
        do {
            _ = try await dns.requireClashDNS(port: proxyPort)
            try await configureBundledProxyBridgeProfile()
            try checkOperationCancellation()
            try await activateProtection(launchGPT: false)
            phase = .ready
        } catch { phase = .failed(error.localizedDescription) }
    }

    func restoreDNSProtection() async {
        setProtectionPaused(true)
        recovery.reset()
        operationCancelled = true
        while activeOperation != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let operation = beginOperation(phase: .checking) else { return }
        defer { endOperation(operation) }
        do { try await dns.restore(); phase = .paused }
        catch { phase = .failed(error.localizedDescription) }
    }

    private func setProtectionPaused(_ paused: Bool) {
        protectionPaused = paused
        defaults.set(paused, forKey: "dnsProtectionPaused")
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
                    try await self.dns.restore()
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

    func repairClashDNS() async {
        guard let operation = beginOperation(phase: .preparingClashDNS) else { return }
        defer { endOperation(operation) }
        do {
            _ = try await dns.checkClash(port: proxyPort, prepareRepair: true)
            phase = .clashDNSReady
        } catch { phase = .failed(error.localizedDescription) }
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
            phase = dns.status.isEnabled ? .ready : .idle
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
        let port = try validatedPort()
        if pendingPortChange {
            try await dns.restore()
            await cli.stopAndWait()
            await relayLifecycle.stopAndWait()
            try checkOperationCancellation()
            pendingPortChange = false
            defaults.set(Int(port), forKey: "proxyPort")
            monitor.start(port: port)
        }
        updateInstalledApps()
        guard proxyBridgeInstalled else { throw AppError.launchStepFailed("ProxyBridge 需要修复", proxyBridgeStatus.detail) }
        guard let url = Bundle.main.url(forResource: "ChatGPT-Only", withExtension: "pbprofile") else { throw AppError.profileResourceMissing }
        let profile: Data
        do { profile = try Data(contentsOf: url) }
        catch { throw AppError.launchStepFailed("读取内置规则", error.localizedDescription) }
        let health = try await ProxyHealthChecker.check(port: port)
        proxyReachable = true
        supportsUDP = health.supportsUDP
        codexLatencyMilliseconds = health.codexLatencyMilliseconds
        try checkOperationCancellation()
        try Task.checkCancellation()
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
        recovery.reset()
        if let protectedLauncher { try await protectedLauncher(); return }
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
        _ = try await dns.requireClashDNS(port: Int(port))

        let health = try await ProxyHealthChecker.check(port: port)
        proxyReachable = true
        supportsUDP = health.supportsUDP
        codexLatencyMilliseconds = health.codexLatencyMilliseconds

        try await configureBundledProxyBridgeProfile()
        try checkOperationCancellation()

        try await activateProtection(launchGPT: true)
    }

    private func activateProtection(launchGPT: Bool, allowAuthorization: Bool = true) async throws {
        let port = try validatedPort()
        applyingProtection = true
        await monitor.stopAndWait()
        defer { applyingProtection = false; monitor.start(port: port) }
        try await ProtectionActivation.run(launchGPT: launchGPT,
            isGPTRunning: { !self.runningChatGPTApplications().isEmpty },
            enable: { try await self.dns.enable(port: port, allowAuthorization: allowAuthorization, beforeActivation: { try self.checkOperationCancellation() }) },
            restartGPT: { try await self.restartChatGPT() }, restore: { try await self.dns.restore() },
            checkCancellation: { try self.checkOperationCancellation() })
    }

    private func beginOperation(phase newPhase: Phase) -> UUID? {
        guard activeOperation == nil, !shuttingDown else { return nil }
        let operation = UUID()
        activeOperation = operation
        operationCancelled = false
        operationPort = proxyPort
        phase = newPhase
        return operation
    }

    private func checkOperationCancellation() throws {
        try Task.checkCancellation()
        if operationCancelled || shuttingDown || (operationPort != nil && operationPort != proxyPort) { throw CancellationError() }
    }

    private func endOperation(_ operation: UUID) {
        guard activeOperation == operation else { return }
        activeOperation = nil
        operationPort = nil
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
        try await GPTApplicationLifecycle.restart(
            requestTermination: { self.runningChatGPTApplications().forEach { $0.terminate() } },
            isRunning: { !self.runningChatGPTApplications().isEmpty },
            launch: { try await self.openApplication(at: Self.chatGPTURL, activates: true) },
            checkCancellation: { try self.checkOperationCancellation() })
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
            configuration.environment = ChatGPTApplicationCompatibility.proxyLaunchEnvironment(
                inheriting: ProcessInfo.processInfo.environment
            )
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
            "现有 ChatGPT 未能在 \(Int(GPTApplicationLifecycle.terminationTimeout)) 秒内退出，已中止启动。请手动退出后重试。"
        case let .unsupportedProxyBridgeVersion(version):
            "自动配置仅支持 ProxyBridge \(ProxyBridgeCLIController.supportedVersion)，当前版本为 \(version ?? "未知")。请通过命令行安装器升级。"
        case .profileResourceMissing:
            "ChatGPT Only 配置资源缺失，请重新安装启动器。"
        }
    }
}
