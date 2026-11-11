import Foundation
import Darwin
import ChatGPTProxyCore
import CDNSFirewall

struct RecoveryJournal: Codable, Sendable {
    var ownerUID: uid_t
    var ownerPID: Int32
    var corePID: Int32
    var socket: String
    var proxyPort: UInt16
    var originalYAML: String
    var sourceGeneration: String
    var bootSession: String?
    var services: [SystemDNSSnapshot]
    var firewallToken: String?
    var clashChanged: Bool? = false
    var pfWasEnabled: Bool?
    var originalIPv6: Bool?
    var ipv4PolicyApplied: Bool?
}

actor MacDNSPlatform {
    private let ownerUID: uid_t
    private let stateURL: URL
    private let client = ClashControllerClient()
    private var journal: RecoveryJournal?
    private var frontend: DNSFrontend?
    private var busy = false
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var failures = 0
    private var selection: [String: String] = [:]
    private var selectionSignature: [String: String] = [:]
    private(set) var status = DNSProtectionStatus(phase: .disabled, detail: "DNS 保护已关闭")

    init(ownerUID: uid_t) throws {
        self.ownerUID = ownerUID
        guard getpwuid(ownerUID) != nil else { throw MonitorError.message("安装用户不存在") }
        let directory = URL(fileURLWithPath: DNSProtectionConfiguration.stateDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 else {
            throw MonitorError.message("DNS 恢复目录身份验证失败")
        }
        guard chmod(directory.path, 0o700) == 0, chown(directory.path, 0, 0) == 0 else {
            throw MonitorError.message("无法保护 DNS 恢复记录目录")
        }
        stateURL = directory.appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            guard lstat(stateURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0,
                  info.st_size <= DNSProtectionConfiguration.maximumRecoverySize else { throw MonitorError.message("DNS 恢复文件身份验证失败") }
            let bytes = try Data(contentsOf: stateURL)
            if let object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any], object["version"] != nil {
                throw MonitorError.message("未知旧版 DNS 恢复格式，已保留记录")
            }
            journal = try JSONDecoder().decode(RecoveryJournal.self, from: bytes)
            status = .init(phase: .restoring, detail: "正在恢复上次 DNS 设置")
        }
    }

    func persist() throws {
        guard let journal else { return }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= DNSProtectionConfiguration.maximumRecoverySize else { throw MonitorError.message("DNS 恢复记录过大") }
        // Atomic replacement in a root-only directory; crash recovery never reads a partial write.
        try data.write(to: stateURL, options: .atomic)
        guard chmod(stateURL.path, 0o600) == 0 else { throw MonitorError.message("无法保护 DNS 恢复记录") }
        let fd = open(stateURL.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
        let directory = open(stateURL.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    func sourceURL(uid: uid_t) throws -> URL {
        guard let user = getpwuid(uid) else { throw MonitorError.message("原安装用户不存在") }
        return URL(fileURLWithPath: String(cString: user.pointee.pw_dir))
            .appendingPathComponent("Library/Application Support/mihomo-party/work/config.yaml")
    }

    func generation(uid: uid_t? = nil) throws -> String {
        let uid = uid ?? ownerUID
        return try DNSProtectionConfiguration.sourceGeneration(at: sourceURL(uid: uid), ownerUID: uid)
    }

    func latestSource(uid: uid_t) throws -> String {
        try DNSProtectionConfiguration.readSource(at: sourceURL(uid: uid), ownerUID: uid)
    }

    func validateSocket(_ path: String, uid: uid_t? = nil) throws {
        let uid = uid ?? ownerUID
        let name = (path as NSString).lastPathComponent
        guard (path as NSString).deletingLastPathComponent == "/tmp",
              name.hasPrefix("mihomo-party-\(uid)-"), name.hasSuffix(".sock") else {
            throw MonitorError.message("Clash 控制接口地址无效")
        }
        var info = stat()
        // Clash Party's privileged core creates root-owned controller sockets
        // even though their names are scoped to the installing user's UID.
        guard lstat(path, &info) == 0, (info.st_uid == uid || info.st_uid == 0),
              info.st_mode & S_IFMT == S_IFSOCK else { throw MonitorError.message("Clash 控制接口身份验证失败") }
    }

    func corePID(socket path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MonitorError.message("无法检查 Clash 进程") }
        defer { close(descriptor) }
        var address = try DNSProtectionIPC.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var pid: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard connected == 0, getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
            throw MonitorError.message("无法确认 Clash 进程身份")
        }
        return pid
    }

    func assertIPv4Policy(socket: String) async throws {
        guard try !DNSProtectionConfiguration.runtimeIPv6(await client.request(socket: socket, path: "/configs")) else {
            throw MonitorError.message("Clash 的 IPv6 设置被覆盖，IPv4 保护已停止")
        }
        try await Task.detached { try DNSPacket.probeIPv4Only(port: 53) }.value
    }

    func probe(port: UInt16, tcp: Bool = false) async throws {
        do { try await Task.detached { try DNSPacket.probe(port: port, tcp: tcp) }.value }
        catch { throw MonitorError.message("本地 DNS \(port)/\(tcp ? "TCP" : "UDP")：\(error.localizedDescription)") }
    }

    func waitForDNS(port: UInt16, tcp: Bool = false) async throws {
        // The vendor DNS proxy is disabled asynchronously, and Mihomo starts
        // its DNS listener asynchronously after accepting a configuration.
        for attempt in 0..<4 {
            do {
                try await Task.detached { try DNSPacket.probe(port: port, timeout: 1, tcp: tcp) }.value
                return
            } catch {
                if attempt == 3 { throw MonitorError.message("本地 DNS \(port)/\(tcp ? "TCP" : "UDP") 未就绪：\(error.localizedDescription)") }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func clearExistingDNSStates() throws {
        guard cgp_clear_dns_states() == 0 else {
            throw MonitorError.message("无法精确清理已有明文 DNS 连接，已停止启用")
        }
    }

    func stop() async throws {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        busy = true
        defer { busy = false }
        try await restore(reason: "DNS 保护已关闭，原配置已恢复")
    }

    func assertSystemResolvers() async throws {
        try SystemDNSSettings.assertLoopbackResolvers(await DNSSystemCommand.run("/usr/sbin/scutil", ["--dns"]))
    }

    func assertFirewall() async throws {
        // A fresh query must reach our block rule and must not get a public DNS response.
        let answered = await Task.detached { (try? DNSPacket.probe(port: 53, timeout: 1, host: "1.1.1.1")) != nil }.value
        let labels = try await DNSSystemCommand.run("/sbin/pfctl", ["-a", DNSProtectionConfiguration.anchor, "-s", "labels"])
        let blocked = labels.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "gptproxy-dns" && fields.count > 2 && (UInt64(fields[2]) ?? 0) > 0
        }
        guard !answered, blocked else { throw MonitorError.message("明文 DNS 阻断验证失败") }
    }

    func flushSystemCache() async {
        _ = try? await DNSSystemCommand.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try? await DNSSystemCommand.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    func restore(reason: String) async throws {
        guard let saved = journal else {
            status = .init(phase: .disabled, detail: reason)
            return
        }
        status = .init(phase: .restoring, detail: "正在恢复系统 DNS")
        let boot = try DNSProtectionConfiguration.bootSession()
        let sameBoot = saved.bootSession == nil || saved.bootSession == boot
        let actions = DNSRecoveryActions(
            firewall: {
                if sameBoot { _ = try await DNSSystemCommand.run("/sbin/pfctl", ["-a", DNSProtectionConfiguration.anchor, "-F", "rules"]) }
            },
            systemDNS: { try SystemDNSSettings.apply(saved.services, restoring: true) },
            reference: { try await self.releaseReference(saved.firewallToken, sameBoot: sameBoot) },
            clash: { if sameBoot { try await self.restoreClash(saved) } },
            frontend: { await self.stopFrontend() },
            cache: { await self.flushSystemCache() })
        let errors = await actions.perform()
        guard errors.isEmpty else {
            try persist()
            throw MonitorError.message(errors.joined(separator: "；"))
        }
        try FileManager.default.removeItem(at: stateURL)
        journal = nil
        failures = 0
        status = .init(phase: .disabled, detail: reason)
    }

    func releaseReference(_ token: String?, sameBoot: Bool) async throws {
        if sameBoot, let token {
            let references = try await DNSSystemCommand.run("/sbin/pfctl", ["-s", "References"])
            // A previous recovery may have released the reference just before a
            // crash. Releasing it twice must not strand the recovery journal.
            if try DNSFirewallState.containsReference(token, output: references) {
                _ = try await DNSSystemCommand.run("/sbin/pfctl", ["-X", token])
            }
            if journal?.pfWasEnabled == true,
               !DNSFirewallState.isEnabled(try await DNSSystemCommand.run("/sbin/pfctl", ["-s", "info"])) {
                _ = try await DNSSystemCommand.run("/sbin/pfctl", ["-e"])
            }
        }
        journal?.firewallToken = nil
        try persist()
    }

    func stopFrontend() async { await frontend?.stop(); frontend = nil }

    func restoreClash(_ saved: RecoveryJournal) async throws {
        guard saved.clashChanged != false else { return }
        guard kill(saved.corePID, 0) == 0 else { return }
        try validateSocket(saved.socket, uid: saved.ownerUID)
        guard try corePID(socket: saved.socket) == saved.corePID else { return }
        let general = try await client.request(socket: saved.socket, path: "/configs")
        let currentSelection = try await client.selection(socket: saved.socket)
        let sourceChanged = try generation(uid: saved.ownerUID) != saved.sourceGeneration
        let base = try sourceChanged ? latestSource(uid: saved.ownerUID) : saved.originalYAML
        let original = try DNSProtectionConfiguration.restoredYAML(base, general: general,
            originalIPv6: saved.originalIPv6, ipv4PolicyApplied: saved.ipv4PolicyApplied == true, sourceChanged: sourceChanged)
        try await client.reload(socket: saved.socket, yaml: original)
        try await client.restoreSelection(socket: saved.socket, selection: currentSelection)
        try await client.flushDNS(socket: saved.socket)
        journal?.clashChanged = false
        journal?.ipv4PolicyApplied = false
        try persist()
    }

}
