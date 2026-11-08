import Foundation
import Combine
import CryptoKit
import Darwin
import ChatGPTProxyCore

enum ClashDNSCheck: Equatable {
    case unchecked, ready, prepared
    case needsRepair(String), unavailable(String)

    var detail: String {
        switch self {
        case .unchecked: "等待检测"
        case .ready: "已配置加密 DNS"
        case .prepared: "已就绪 · 启动保护时应用"
        case let .needsRepair(reason), let .unavailable(reason): reason
        }
    }

    var isReady: Bool { self == .ready || self == .prepared }
    var canRepair: Bool { if case .needsRepair = self { true } else { false } }
}

struct ClashDNSConfiguration {
    let source: URL
    let generation: String
    let socket: String
    let yaml: String
    let general: Data
    let saved: String?

    static func load(port: UInt16) async throws -> Self {
        let client = ClashControllerClient()
        let snapshot = try await client.snapshot(port: port)
        guard snapshot.mode.lowercased() == "global", let node = snapshot.current,
              !["DIRECT", "REJECT", "PASS"].contains(node.uppercased()) else {
            throw MonitorError.message("请在 Clash Party 中使用全局模式并选择代理节点")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/mihomo-party")
        let source = directory.appendingPathComponent("work/config.yaml")
        let generation = try DNSProtectionConfiguration.sourceGeneration(at: source)
        let yaml = try String(contentsOf: source, encoding: .utf8)
        let saved = directory.appendingPathComponent("mihomo.yaml")
        let savedYAML = (try? DNSProtectionConfiguration.sourceGeneration(at: saved)).flatMap { _ in
            try? String(contentsOf: saved, encoding: .utf8)
        }
        let general = try await client.request(socket: snapshot.socket, path: "/configs")
        return Self(source: source, generation: generation, socket: snapshot.socket, yaml: yaml,
                    general: general, saved: savedYAML)
    }
}

@MainActor
final class DNSProtectionController: ObservableObject {
    @Published private(set) var status = DNSProtectionStatus(phase: .disabled, detail: "DNS 保护已关闭")
    private var polling: Task<Void, Never>?
    private var observationGeneration = 0
    private var observationBoundary: TimeInterval = 0
    private var pollingID = UUID()
    private var mutating = false
    private var activity: NSObjectProtocol?
    private let requestIPC: @Sendable (DNSProtectionRequest) async throws -> DNSProtectionStatus
    @Published private(set) var clashCheck: ClashDNSCheck = .unchecked
    private let defaults: UserDefaults
    private let loadConfiguration: (UInt16) async throws -> ClashDNSConfiguration
    private static let repairPreference = "repairClashDNSDuringProtection"

    init(defaults: UserDefaults = .standard,
         loadConfiguration: @escaping (UInt16) async throws -> ClashDNSConfiguration = ClashDNSConfiguration.load,
         requestIPC: @escaping @Sendable (DNSProtectionRequest) async throws -> DNSProtectionStatus = DNSProtectionIPC.request) {
        self.defaults = defaults
        self.loadConfiguration = loadConfiguration
        self.requestIPC = requestIPC
    }

    func resetClashCheck() { clashCheck = .unchecked }

    // Preview the exact protected configuration. Only activation sends it to the helper.
    @discardableResult
    func checkClash(port: Int, prepareRepair: Bool = false) async throws -> DNSProtectionRequest {
        do {
            let port = try ProxyConfiguration.validatedPort(String(port))
            let config = try await loadConfiguration(port)
            let runtime = try DNSProtectionConfiguration.runtimeYAML(config.yaml, general: config.general)
            let inspection = try DNSProtectionConfiguration.inspectBootstrap(runtime, saved: config.saved)
            _ = try DNSProtectionConfiguration.protectedYAML(runtime, bootstrapRepair: inspection.replacements)
            guard try DNSProtectionConfiguration.sourceGeneration(at: config.source) == config.generation else {
                throw MonitorError.message("Clash 配置已更改，请重新检测")
            }

            var request = DNSProtectionRequest(command: .enable, port: port, socket: config.socket,
                                               yaml: config.yaml, sourceGeneration: config.generation)
            if inspection.replacements.isEmpty {
                clashCheck = .ready
            } else if prepareRepair || defaults.bool(forKey: Self.repairPreference) {
                if prepareRepair { defaults.set(true, forKey: Self.repairPreference) }
                request.bootstrapRepair = inspection.replacements
                clashCheck = .prepared
            } else {
                clashCheck = .needsRepair(inspection.plaintext ? "正在使用明文 DNS" : "引导或节点 DNS 配置不符合要求")
            }
            return request
        } catch {
            clashCheck = .unavailable(error.localizedDescription)
            throw error
        }
    }

    func requireClashDNS(port: Int) async throws -> DNSProtectionRequest {
        let request = try await checkClash(port: port)
        guard clashCheck.isReady else {
            throw MonitorError.message("请点击「Clash DNS」右侧的「修复」")
        }
        return request
    }

    func refresh() async {
        let generation = observationGeneration
        do {
            // The helper only renews the lease for its owning PID. A transient UI
            // failure must not turn the next heartbeat into a non-renewing status read.
            let response = try await requestIPC(.init(command: .heartbeat))
            accept(response, generation: generation)
        } catch { acceptFailure(generation: generation) }
    }

    private func accept(_ response: DNSProtectionStatus, generation: Int) {
        guard generation == observationGeneration, !mutating else { return }
        let next = response.isEnabled && response.version != DNSProtectionConfiguration.version
            ? DNSProtectionStatus(phase: .failed, detail: "辅助服务需要升级，请重新启用 DNS / IPv4 保护") : response
        if next != status { status = next }
    }

    private func acceptFailure(generation: Int) {
        guard generation == observationGeneration, !mutating else { return }
        let next = DNSProtectionStatus(phase: .failed, detail: "DNS 辅助服务未响应，等待恢复联网后重试")
        if next != status { status = next }
    }

    private func beginMutation() throws {
        guard !mutating else { throw MonitorError.message("DNS 操作正在进行") }
        observationGeneration += 1
        observationBoundary = ProcessInfo.processInfo.systemUptime
        mutating = true
    }

    private func endMutation() {
        mutating = false
        observationGeneration += 1
        observationBoundary = ProcessInfo.processInfo.systemUptime
    }

    func enable(port: UInt16, allowAuthorization: Bool = true,
                beforeActivation: () throws -> Void = {}) async throws {
        try beginMutation()
        defer { endMutation() }
        status = .init(phase: .enabling, detail: "正在启用系统 DNS 保护")
        do {
            let request = try await requireClashDNS(port: Int(port))
            try await installIfNeeded(allowAuthorization: allowAuthorization)
            try Task.checkCancellation()
            try beforeActivation()
            status = try await requestIPC(request)
            guard status.isEnabled, status.version == DNSProtectionConfiguration.version else { throw MonitorError.message(status.detail) }
            startMonitoring()
        } catch {
            status = .init(phase: .failed, detail: "DNS 保护未启用：\(error.localizedDescription)")
            throw error
        }
    }

    func restore() async throws {
        try beginMutation()
        defer { endMutation() }
        guard FileManager.default.fileExists(atPath: DNSProtectionConfiguration.helperPath) else {
            status = .init(phase: .disabled, detail: "DNS 保护已关闭")
            return
        }
        status = try await requestIPC(.init(command: .restore))
        guard status.phase == .disabled else { throw MonitorError.message(status.detail) }
    }

    func startMonitoring(interval: Duration = .seconds(2)) {
        guard polling == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "维护 DNS 保护心跳")
        let request = requestIPC
        let id = UUID(); pollingID = id
        polling = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    let response = try await request(.init(command: .heartbeat))
                    guard !Task.isCancelled else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.pollingID == id, began >= self.observationBoundary else { return }
                        self.accept(response, generation: self.observationGeneration)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.pollingID == id, began >= self.observationBoundary else { return }
                        self.acceptFailure(generation: self.observationGeneration)
                    }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stopMonitoring() {
        observationGeneration += 1
        pollingID = UUID()
        observationBoundary = ProcessInfo.processInfo.systemUptime
        polling?.cancel(); polling = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    func requireInstalledHelper() async throws {
        try await installIfNeeded(allowAuthorization: false)
    }

    private func installIfNeeded(allowAuthorization: Bool) async throws {
        guard let bundled = Bundle.main.url(forResource: "DNSProtectionHelper", withExtension: nil) else {
            throw MonitorError.message("DNS 辅助服务资源缺失，请安装完整应用")
        }
        let installed = URL(fileURLWithPath: DNSProtectionConfiguration.helperPath)
        if let existing = try? Data(contentsOf: installed),
           SHA256.hash(data: existing) == SHA256.hash(data: try Data(contentsOf: bundled)),
           let response = try? await DNSProtectionIPC.request(.init(command: .status)),
           response.version == DNSProtectionConfiguration.version { return }

        guard allowAuthorization else {
            throw MonitorError.message("DNS 辅助服务需要安装或更新，请点击「启用 DNS / IPv4 保护」完成系统授权")
        }

        // Administrator authorization installs a root-owned copy. The daemon never
        // executes a binary or script from the user's application directory.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("gptproxy-dns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let plist = stage.appendingPathComponent("daemon.plist")
        let label = DNSProtectionConfiguration.label
        let definition: [String: Any] = [
            "Label": label,
            "ProgramArguments": [DNSProtectionConfiguration.helperPath, "--daemon", "--owner-uid", String(getuid())],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5,
            "StandardOutPath": "/var/log/\(label).log", "StandardErrorPath": "/var/log/\(label).log"
        ]
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0).write(to: plist)
        let script = """
        on run argv
          set helperSource to quoted form of item 1 of argv
          set plistSource to quoted form of item 2 of argv
          set helperTarget to quoted form of item 3 of argv
          set plistTarget to quoted form of item 4 of argv
          set serviceLabel to quoted form of item 5 of argv
          do shell script "set -eu; if test -x " & helperTarget & "; then " & helperTarget & " --restore; fi; /bin/launchctl bootout system/" & serviceLabel & " >/dev/null 2>&1 || true; /bin/mkdir -p /Library/PrivilegedHelperTools; /usr/bin/install -o root -g wheel -m 755 " & helperSource & " " & helperTarget & "; /usr/bin/install -o root -g wheel -m 644 " & plistSource & " " & plistTarget & "; /bin/launchctl bootstrap system " & plistTarget with administrator privileges
        end run
        """
        _ = try await DNSSystemCommand.run("/usr/bin/osascript", ["-e", script, bundled.path, plist.path,
            installed.path, "/Library/LaunchDaemons/\(label).plist", label], timeout: 300)
        for _ in 0..<20 {
            if let response = try? await DNSProtectionIPC.request(.init(command: .status)),
               response.version == DNSProtectionConfiguration.version { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MonitorError.message("DNS 辅助服务启动失败")
    }
}
