import AppKit
import ChatGPTProxyCore
import Foundation

@MainActor
struct ProxyBridgeProfileLifecycle<Receipt: Sendable> {
    struct Operations {
        let install: @MainActor () async throws -> Receipt
        let openProxyBridge: @MainActor () async throws -> Void
        let waitUntilProxyBridgeFinishesLaunching: @MainActor () async -> Bool
        let terminateProxyBridge: @MainActor () async throws -> Void
        let installedProfileIsValid: @MainActor (Receipt) async -> Bool
        let restore: @MainActor (Receipt) async throws -> Void
    }

    let operations: Operations

    func run() async throws {
        let receipt = try await operations.install()

        do {
            try await operations.openProxyBridge()
            guard await operations.waitUntilProxyBridgeFinishesLaunching() else {
                throw AppError.profileVerificationFailed
            }
            try await operations.terminateProxyBridge()
            guard await operations.installedProfileIsValid(receipt) else {
                throw AppError.profileVerificationFailed
            }
            try await operations.openProxyBridge()
        } catch {
            let configurationError = error
            do {
                try await operations.terminateProxyBridge()
            } catch {
                throw AppError.profileRollbackFailed(error.localizedDescription)
            }

            do {
                try await operations.restore(receipt)
                try await operations.openProxyBridge()
            } catch let rollbackError as AppError {
                throw rollbackError
            } catch {
                throw AppError.profileRollbackFailed(error.localizedDescription)
            }
            throw configurationError
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case ready
        case launching
        case configuringProfile
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
            case let .failed(message):
                message
            }
        }
    }

    let monitor = AutoSwitchMonitor()

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
        if profileConfigurator == nil, let port = UInt16(exactly: proxyPort), port > 0 {
            monitor.start(port: port)
            Task {
                do { try await ensureRelay(upstreamPort: port) }
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
        if proxyBridgeInstalled {
            proxyBridgeProfileReady = await ProxyBridgeConfigurationChecker.isChatGPTOnlyProfileActive()
            if proxyBridgeProfileReady {
                profileInstallRequiresManualFallback = false
            }
        } else {
            proxyBridgeProfileReady = false
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
            } else if !proxyBridgeInstalled {
                phase = .failed("尚未安装 ProxyBridge。")
            } else if !extensionEnabled {
                phase = .failed("ProxyBridge 网络扩展尚未启用。")
            } else if !proxyBridgeProfileReady {
                phase = .failed("ProxyBridge 当前配置不是 ChatGPT 专用配置，请重新导入并选中该配置。")
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
        updateInstalledApps()
        guard proxyBridgeInstalled else {
            showingSetup = true
            return
        }
        NSWorkspace.shared.open(Self.proxyBridgeURL)
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

    func openBundledProxyBridgeInstaller() {
        guard let url = Bundle.main.url(
            forResource: "ProxyBridge-v4.0.0-Universal-Installer",
            withExtension: "pkg"
        ) else {
            phase = .failed("安装包资源缺失。")
            return
        }
        NSWorkspace.shared.open(url)
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
            profileInstallRequiresManualFallback = true
            phase = .failed(error.localizedDescription)
            endOperation(operation)
        }
    }

    private func validatedPort() throws -> UInt16 {
        try ProxyConfiguration.validatedPort(String(proxyPort))
    }

    private func updateInstalledApps() {
        chatGPTStatus = ChatGPTApplicationCompatibility.inspect(applicationURL: Self.chatGPTURL)
        proxyBridgeInstalled = FileManager.default.fileExists(atPath: Self.proxyBridgeURL.path)
    }

    private func configureBundledProxyBridgeProfile() async throws {
        updateInstalledApps()
        guard proxyBridgeInstalled else { throw AppError.proxyBridgeMissing }

        let installedVersion = Bundle(url: Self.proxyBridgeURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard installedVersion == ProxyBridgeProfileInstaller.supportedVersion else {
            throw AppError.unsupportedProxyBridgeVersion(installedVersion)
        }
        guard let profileURL = Bundle.main.url(forResource: "ChatGPT-Only", withExtension: "pbprofile") else {
            throw AppError.profileResourceMissing
        }

        try await ensureProxyBridgePreferencesExist()
        try await terminateProxyBridge()

        let profile = try Data(contentsOf: profileURL)
        let preferencesURL = ProxyBridgeConfigurationChecker.preferencesURL
        let backupDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("ChatGPT Proxy", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("ProxyBridge", isDirectory: true)

        let lifecycle = ProxyBridgeProfileLifecycle(
            operations: .init(
                install: {
                    try await Task.detached(priority: .utility) {
                        try ProxyBridgeProfileInstaller.install(
                            profile: profile,
                            preferencesURL: preferencesURL,
                            backupDirectory: backupDirectory
                        )
                    }.value
                },
                openProxyBridge: {
                    try await self.openApplication(at: Self.proxyBridgeURL, activates: false)
                },
                waitUntilProxyBridgeFinishesLaunching: {
                    await self.waitForProxyBridgeToFinishLaunching()
                },
                terminateProxyBridge: {
                    try await self.terminateProxyBridge()
                },
                installedProfileIsValid: { _ in
                    await ProxyBridgeConfigurationChecker.isChatGPTOnlyProfileActive()
                },
                restore: { receipt in
                    try await Task.detached(priority: .utility) {
                        try ProxyBridgeProfileInstaller.restore(receipt)
                    }.value
                }
            )
        )
        try await lifecycle.run()
    }

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
        guard proxyBridgeInstalled else { throw AppError.proxyBridgeMissing }
        proxyBridgeProfileReady = await ProxyBridgeConfigurationChecker.isChatGPTOnlyProfileActive()
        guard proxyBridgeProfileReady else { throw AppError.invalidProxyBridgeProfile }

        let health = try await ProxyHealthChecker.check(port: port)
        guard health.egressLocation != "CN" else {
            throw ProxyHealthError.unsupportedRegion(health.egressLocation)
        }
        proxyReachable = true
        supportsUDP = health.supportsUDP
        egressLocation = health.egressLocation

        try await ensureRelay(upstreamPort: port)
        try await openApplication(at: Self.proxyBridgeURL, activates: false)
        extensionEnabled = await waitForProxyBridgeExtension()
        guard extensionEnabled else { throw AppError.extensionDisabled }
        proxyBridgeProfileReady = await ProxyBridgeConfigurationChecker.isChatGPTOnlyProfileActive()
        guard proxyBridgeProfileReady else { throw AppError.invalidProxyBridgeProfile }

        try await restartChatGPT()
    }

    private func ensureProxyBridgePreferencesExist() async throws {
        let preferencesURL = ProxyBridgeConfigurationChecker.preferencesURL
        guard !FileManager.default.fileExists(atPath: preferencesURL.path) else { return }

        try await openApplication(at: Self.proxyBridgeURL, activates: false)
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw ProxyBridgeProfileInstallError.preferencesMissing
    }

    private func terminateProxyBridge() async throws {
        let bundleIdentifier = "com.interceptsuite.ProxyBridge"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .forEach { $0.terminate() }
        for _ in 0..<30 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw AppError.proxyBridgeDidNotTerminate
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

    private func waitForProxyBridgeExtension() async -> Bool {
        for _ in 0..<20 {
            if await SystemExtensionChecker.proxyBridgeIsEnabled() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func waitForProxyBridgeToFinishLaunching() async -> Bool {
        let bundleIdentifier = "com.interceptsuite.ProxyBridge"
        for _ in 0..<30 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains(where: { $0.isFinishedLaunching })
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
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
    case invalidProxyBridgeProfile
    case chatGPTDidNotTerminate
    case unsupportedProxyBridgeVersion(String?)
    case profileResourceMissing
    case proxyBridgeDidNotTerminate
    case profileVerificationFailed
    case profileRollbackFailed(String)

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
        case .invalidProxyBridgeProfile:
            "ProxyBridge 当前配置不符合 ChatGPT 专用规则，请重新导入并选中随附配置。"
        case .chatGPTDidNotTerminate:
            "现有 ChatGPT 未能在 3 秒内退出，已中止启动。请手动退出后重试。"
        case let .unsupportedProxyBridgeVersion(version):
            "自动配置仅支持 ProxyBridge \(ProxyBridgeProfileInstaller.supportedVersion)，当前版本为 \(version ?? "未知")。请改用手动导入。"
        case .profileResourceMissing:
            "ChatGPT Only 配置资源缺失，请重新安装启动器。"
        case .proxyBridgeDidNotTerminate:
            "ProxyBridge 未能在 3 秒内退出，配置未修改。请手动退出后重试。"
        case .profileVerificationFailed:
            "ProxyBridge 未加载新配置，已恢复原配置。请改用手动导入。"
        case let .profileRollbackFailed(message):
            "自动配置失败，并且无法恢复备份：\(message)"
        }
    }
}
