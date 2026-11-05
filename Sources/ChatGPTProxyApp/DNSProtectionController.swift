import Foundation
import Combine
import CryptoKit
import Darwin
import ChatGPTProxyCore

@MainActor
final class DNSProtectionController: ObservableObject {
    @Published private(set) var status = DNSProtectionStatus(phase: .disabled, detail: "DNS 保护已关闭")
    private var polling: Task<Void, Never>?
    private let client = ClashControllerClient()

    func refresh() async {
        do { status = try await DNSProtectionIPC.request(.init(command: status.isEnabled ? .heartbeat : .status)) }
        catch {
            if status.isEnabled { status = .init(phase: .failed, detail: "DNS 辅助服务失去响应，正在自动恢复") }
        }
    }

    func enable(port: UInt16, beforeActivation: () throws -> Void = {}) async throws {
        status = .init(phase: .enabling, detail: "正在启用系统 DNS 保护")
        do {
            let snapshot = try await client.snapshot(port: port)
            guard snapshot.mode.lowercased() == "global", let node = snapshot.current,
                  !["DIRECT", "REJECT", "PASS"].contains(node.uppercased()) else {
                throw MonitorError.message("DNS 保护要求 Clash Party 全局模式并选择代理节点")
            }
            let source = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/mihomo-party/work/config.yaml")
            let generation = try DNSProtectionConfiguration.sourceGeneration(at: source)
            let yaml = try String(contentsOf: source, encoding: .utf8)
            _ = try DNSProtectionConfiguration.protectedYAML(
                DNSProtectionConfiguration.runtimeYAML(yaml, general: await client.request(socket: snapshot.socket, path: "/configs")))
            try await installIfNeeded()
            try Task.checkCancellation()
            try beforeActivation()
            guard try DNSProtectionConfiguration.sourceGeneration(at: source) == generation else {
                throw MonitorError.message("Clash 配置已更改，请重新启用 DNS 保护")
            }
            status = try await DNSProtectionIPC.request(.init(command: .enable, port: port, socket: snapshot.socket, yaml: yaml, sourceGeneration: generation))
            guard status.isEnabled else { throw MonitorError.message(status.detail) }
            startPolling()
        } catch {
            status = .init(phase: .failed, detail: "DNS 保护未启用：\(error.localizedDescription)")
            throw error
        }
    }

    func restore() async throws {
        polling?.cancel(); polling = nil
        // No installed service and no active transaction is an ordinary first-run state.
        guard FileManager.default.fileExists(atPath: DNSProtectionConfiguration.helperPath) else {
            status = .init(phase: .disabled, detail: "DNS 保护已关闭")
            return
        }
        status = try await DNSProtectionIPC.request(.init(command: .restore))
        guard status.phase == .disabled else {
            startPolling()
            throw MonitorError.message(status.detail)
        }
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                if self.status.phase == .disabled { return }
            }
        }
    }

    private func installIfNeeded() async throws {
        guard let bundled = Bundle.main.url(forResource: "DNSProtectionHelper", withExtension: nil) else {
            throw MonitorError.message("DNS 辅助服务资源缺失，请安装完整应用")
        }
        let installed = URL(fileURLWithPath: DNSProtectionConfiguration.helperPath)
        if let existing = try? Data(contentsOf: installed),
           SHA256.hash(data: existing) == SHA256.hash(data: try Data(contentsOf: bundled)),
           let response = try? await DNSProtectionIPC.request(.init(command: .status)),
           response.version == DNSProtectionConfiguration.version { return }

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
