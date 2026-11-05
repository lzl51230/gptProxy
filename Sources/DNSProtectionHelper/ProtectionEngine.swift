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

actor ProtectionEngine {
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
                  info.st_size <= 2 * DNSProtectionIPC.maximumMessageSize else { throw MonitorError.message("DNS 恢复文件身份验证失败") }
            journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: stateURL))
            status = .init(phase: .restoring, detail: "正在恢复上次 DNS 设置")
        }
    }

    private func persist() throws {
        guard let journal else { return }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 2 * DNSProtectionIPC.maximumMessageSize else { throw MonitorError.message("DNS 恢复记录过大") }
        // Atomic replacement in a root-only directory; crash recovery never reads a partial write.
        try data.write(to: stateURL, options: .atomic)
        guard chmod(stateURL.path, 0o600) == 0 else { throw MonitorError.message("无法保护 DNS 恢复记录") }
        let fd = open(stateURL.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
        let directory = open(stateURL.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    private func sourceURL(uid: uid_t) throws -> URL {
        guard let user = getpwuid(uid) else { throw MonitorError.message("原安装用户不存在") }
        return URL(fileURLWithPath: String(cString: user.pointee.pw_dir))
            .appendingPathComponent("Library/Application Support/mihomo-party/work/config.yaml")
    }

    private func generation(uid: uid_t? = nil) throws -> String {
        let uid = uid ?? ownerUID
        return try DNSProtectionConfiguration.sourceGeneration(at: sourceURL(uid: uid), ownerUID: uid)
    }

    private func latestSource(uid: uid_t) throws -> String {
        let url = try sourceURL(uid: uid)
        _ = try generation(uid: uid)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw MonitorError.message("无法读取当前 Clash 配置") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= DNSProtectionIPC.maximumMessageSize else { throw MonitorError.message("当前 Clash 配置身份验证失败") }
        guard let bytes = try handle.read(upToCount: DNSProtectionIPC.maximumMessageSize),
              let yaml = String(data: bytes, encoding: .utf8) else { throw MonitorError.message("当前 Clash 配置不是有效 UTF-8") }
        return yaml
    }

    private func validateSocket(_ path: String, uid: uid_t? = nil) throws {
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

    private func corePID(socket path: String) throws -> Int32 {
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

    func handle(_ request: DNSProtectionRequest, peerPID: Int32) async -> DNSProtectionStatus {
        if request.command == .status { return status }
        if request.command == .heartbeat {
            if journal?.ownerPID == peerPID { lastHeartbeat = ProcessInfo.processInfo.systemUptime }
            return status
        }
        // A watchdog probe must not make an explicit restore fail spuriously.
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        defer { busy = false }
        do {
            if request.command == .restore {
                try await restore(reason: "DNS 保护已关闭，原配置已恢复")
            } else {
                guard let port = request.port, port != 0, port != DNSProtectionConfiguration.clashDNSPort,
                      let socket = request.socket, let yaml = request.yaml, let sourceGeneration = request.sourceGeneration else {
                    throw MonitorError.message("DNS 启用参数不完整")
                }
                if status.isEnabled, journal?.ownerPID == peerPID, journal?.proxyPort == port,
                   journal?.sourceGeneration == sourceGeneration {
                    try await assertSystemResolvers()
                    try await assertFirewall()
                    try await probe(port: 53)
                    try await assertIPv4Policy(socket: socket)
                    return status
                }
                if journal != nil { try await restore(reason: "已恢复原配置") }
                guard try generation() == sourceGeneration else { throw MonitorError.message("Clash 配置已更改，请重试") }
                try await enable(port: port, socket: socket, yaml: yaml, ownerPID: peerPID)
            }
        } catch {
            let reason = error.localizedDescription
            do {
                try await restore(reason: "DNS 保护已关闭：\(reason)")
                status = .init(phase: .failed, detail: "DNS 保护已关闭：\(reason)")
            } catch {
                status = .init(phase: .failed, detail: "DNS 恢复未完成，请使用恢复命令重试：\(error.localizedDescription)")
            }
        }
        return status
    }

    func recoverAtStartup() async throws {
        if journal != nil { try await restore(reason: "已恢复上次 DNS 设置，保护已关闭") }
    }

    private func enable(port: UInt16, socket: String, yaml: String, ownerPID: Int32) async throws {
        guard cgp_dns_firewall_supported() == 1 else {
            throw MonitorError.message("当前系统版本尚未验证 DNS 防火墙状态清理，未修改 DNS")
        }
        try validateSocket(socket)
        let initial = try await client.snapshot(socket: socket, port: port)
        guard initial.mode.lowercased() == "global", let node = initial.current,
              !["DIRECT", "REJECT", "PASS"].contains(node.uppercased()) else {
            throw MonitorError.message("DNS 保护要求 Clash Party 全局模式并选择代理节点")
        }
        let general = try await client.request(socket: socket, path: "/configs")
        let originalIPv6 = try DNSProtectionConfiguration.runtimeIPv6(general)
        let original = try DNSProtectionConfiguration.runtimeYAML(yaml, general: general)
        let protected = try DNSProtectionConfiguration.protectedYAML(original)
        try DNSProtectionConfiguration.assertDNSPortAvailable()
        let services = try SystemDNSSettings.snapshots()
        guard !services.isEmpty else { throw MonitorError.message("没有可接管的物理网络服务") }
        let rootRules = try await DNSSystemCommand.run("/sbin/pfctl", ["-sr"])
        guard rootRules.contains("anchor \"com.apple/*\"") else {
            throw MonitorError.message("当前 PF 配置没有可用的系统 anchor，未修改 DNS")
        }
        let pfWasEnabled = DNSFirewallState.isEnabled(try await DNSSystemCommand.run("/sbin/pfctl", ["-s", "info"]))
        status = .init(phase: .enabling, detail: "正在启用系统 DNS 保护")
        journal = .init(ownerUID: ownerUID, ownerPID: ownerPID, corePID: try corePID(socket: socket), socket: socket, proxyPort: port, originalYAML: original,
                        sourceGeneration: try generation(), bootSession: try DNSProtectionConfiguration.bootSession(), services: services,
                        pfWasEnabled: pfWasEnabled, originalIPv6: originalIPv6, ipv4PolicyApplied: false)
        try persist()
        let frontend = DNSFrontend()
        self.frontend = frontend
        try await frontend.start()
        selection = try await client.selection(socket: socket)
        selectionSignature = initial.selectionSignature
        journal?.clashChanged = true
        journal?.ipv4PolicyApplied = true
        try persist()
        try await client.reload(socket: socket, yaml: protected)
        try await client.restoreSelection(socket: socket, selection: selection)
        // Reloading a policy does not close existing IPv6 transports or UDP associations.
        try await client.closeAllConnections(socket: socket)
        try await client.flushDNS(socket: socket)
        try await waitForDNS(port: DNSProtectionConfiguration.clashDNSPort)
        try await waitForDNS(port: 53, tcp: true)
        try SystemDNSSettings.apply(services, restoring: false)
        let tokenOutput = try await DNSSystemCommand.run("/sbin/pfctl", ["-E"])
        guard let token = tokenOutput.range(of: #"Token\s*:\s*(\d+)"#, options: .regularExpression) else {
            throw MonitorError.message("无法取得 PF 启用引用")
        }
        journal?.firewallToken = tokenOutput[token].split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist()
        _ = try await DNSSystemCommand.run("/sbin/pfctl", ["-a", DNSProtectionConfiguration.anchor, "-f", "-"],
                                         input: Data(DNSProtectionConfiguration.firewallRules.utf8))
        try clearExistingDNSStates()
        await flushSystemCache()
        try await assertSystemResolvers()
        try await assertFirewall()
        try await probe(port: 53)
        try await assertIPv4Policy(socket: socket)
        guard try generation() == journal?.sourceGeneration else { throw MonitorError.message("Clash 配置在启用期间发生变化") }
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        failures = 0
        status = .init(phase: .enabled, detail: "DNS 已保护 · 本机代理使用 IPv4；明文 DNS 已阻断")
    }

    private func assertIPv4Policy(socket: String) async throws {
        guard try !DNSProtectionConfiguration.runtimeIPv6(await client.request(socket: socket, path: "/configs")) else {
            throw MonitorError.message("Clash 的 IPv6 设置被覆盖，IPv4 保护已停止")
        }
        try await Task.detached { try DNSPacket.probeIPv4Only(port: 53) }.value
    }

    private func probe(port: UInt16, tcp: Bool = false) async throws {
        do { try await Task.detached { try DNSPacket.probe(port: port, tcp: tcp) }.value }
        catch { throw MonitorError.message("本地 DNS \(port)/\(tcp ? "TCP" : "UDP")：\(error.localizedDescription)") }
    }

    private func waitForDNS(port: UInt16, tcp: Bool = false) async throws {
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

    private func clearExistingDNSStates() throws {
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

    private func assertSystemResolvers() async throws {
        try SystemDNSSettings.assertLoopbackResolvers(await DNSSystemCommand.run("/usr/sbin/scutil", ["--dns"]))
    }

    private func assertFirewall() async throws {
        // A fresh query must reach our block rule and must not get a public DNS response.
        let answered = await Task.detached { (try? DNSPacket.probe(port: 53, timeout: 1, host: "1.1.1.1")) != nil }.value
        let labels = try await DNSSystemCommand.run("/sbin/pfctl", ["-a", DNSProtectionConfiguration.anchor, "-s", "labels"])
        let blocked = labels.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "gptproxy-dns" && fields.count > 2 && (UInt64(fields[2]) ?? 0) > 0
        }
        guard !answered, blocked else { throw MonitorError.message("明文 DNS 阻断验证失败") }
    }

    private func flushSystemCache() async {
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

    private func releaseReference(_ token: String?, sameBoot: Bool) async throws {
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

    private func stopFrontend() async { await frontend?.stop(); frontend = nil }

    private func restoreClash(_ saved: RecoveryJournal) async throws {
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

    func tick() async {
        guard !busy, let saved = journal else { return }
        busy = true
        defer { busy = false }
        if !status.isEnabled {
            do { try await restore(reason: "原配置已恢复，DNS 保护已关闭") }
            catch { status = .init(phase: .failed, detail: "DNS 恢复未完成：\(error.localizedDescription)") }
            return
        }
        do {
            guard kill(saved.ownerPID, 0) == 0,
                  ProcessInfo.processInfo.systemUptime - lastHeartbeat < 15 else {
                throw MonitorError.message("启动器已退出或失去响应")
            }
            guard try generation() == saved.sourceGeneration else { throw MonitorError.message("Clash 配置已重新加载") }
            let live = try await client.snapshot(socket: saved.socket, port: saved.proxyPort)
            guard live.mode.lowercased() == "global", let node = live.current,
                  !["DIRECT", "REJECT", "PASS"].contains(node.uppercased()) else {
                throw MonitorError.message("Clash 已离开受保护的全局代理模式")
            }
            if live.selectionSignature != selectionSignature {
                try await client.closeDNSConnections(socket: saved.socket)
                try await client.flushDNS(socket: saved.socket)
                selection = try await client.selection(socket: saved.socket)
                selectionSignature = live.selectionSignature
            }
            let newServices = try SystemDNSSettings.snapshots().filter { current in !saved.services.contains(where: { $0.serviceID == current.serviceID }) }
            if !newServices.isEmpty {
                journal?.services.append(contentsOf: newServices)
                try persist()
                try SystemDNSSettings.apply(newServices, restoring: false)
            }
            try await assertSystemResolvers()
            try await assertFirewall()
            try await probe(port: 53)
            try await assertIPv4Policy(socket: saved.socket)
            failures = 0
        } catch {
            let immediate = kill(saved.ownerPID, 0) != 0 || ProcessInfo.processInfo.systemUptime - lastHeartbeat >= 15
                || (try? generation()) != saved.sourceGeneration
            failures += 1
            if immediate || failures >= 2 {
                do { try await restore(reason: "DNS 保护已关闭，已自动恢复：\(error.localizedDescription)") }
                catch { status = .init(phase: .failed, detail: "DNS 恢复未完成：\(error.localizedDescription)") }
            }
        }
    }
}
