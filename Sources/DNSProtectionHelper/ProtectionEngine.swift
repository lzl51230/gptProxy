import Foundation
import Darwin
import ChatGPTProxyCore
import CDNSFirewall

/// Privileged macOS effects for the shared recovery transaction. The platform
/// adapter also retains the old journal reader solely for upgrade recovery.
actor ProtectionEngine {
    private let ownerUID: uid_t
    private let platform: MacDNSPlatform
    private let core = RustCore()
    private let client = ClashControllerClient()
    private let stateURL: URL
    private var journal: [String:Any]?
    private var request: DNSProtectionRequest?
    private var peerPID: Int32 = 0
    private var busy = false
    private var selectionSignature: [String:String] = [:]
    private(set) var status = DNSProtectionStatus(phase: .disabled, detail: "DNS 保护已关闭")
    init(ownerUID: uid_t) throws {
        self.ownerUID = ownerUID
        platform = try MacDNSPlatform(ownerUID: ownerUID)
        stateURL = URL(fileURLWithPath: DNSProtectionConfiguration.stateDirectory).appendingPathComponent("recovery-v3.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            var info = stat()
            guard lstat(stateURL.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= 2 * DNSProtectionIPC.maximumMessageSize else { throw MonitorError.message("DNS 恢复文件身份验证失败") }
            journal = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String:Any]
            guard journal != nil else { throw MonitorError.message("DNS 恢复记录无效，已保留") }
        }
        _ = try core.object(["op":"protection", "action":"load", "journal":journal as Any? ?? NSNull()])
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    func recoverAtStartup() async throws {
        // The previous helper is asked to restore before replacement. This path
        // also handles an interrupted upgrade with a retained legacy journal.
        try await platform.restore(reason: "已恢复旧版 DNS 设置")
        if journal != nil { try await transaction(["action":"restore"]) }
    }
    func handle(_ request: DNSProtectionRequest, peerPID: Int32) async -> DNSProtectionStatus {
        if request.command == .status { return status }
        if request.command == .heartbeat {
            if (journal?["ownerPID"] as? Int32) == peerPID || self.peerPID == peerPID {
                _ = try? core.object(["op":"protection", "action":"heartbeat", "now":now])
            }
            return status
        }
        while busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true; defer { busy = false }
        do {
            if request.command == .restore { try await transaction(["action":"restore"]) }
            else {
                if journal != nil { try await transaction(["action":"restore"]) }
                self.request = request; self.peerPID = peerPID
                try await transaction(["action":"enable", "now":now])
            }
        } catch { status = .init(phase: .failed, detail: error.localizedDescription) }
        return status
    }
    func stop() async throws {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        busy = true; defer { busy = false }
        try await transaction(["action":"restore"])
    }
    func tick() async {
        guard !busy, journal != nil else { return }
        busy = true; defer { busy = false }
        let pid = (journal?["ownerPID"] as? NSNumber)?.int32Value ?? 0
        do { try await transaction(["action":"watchdog", "now":now, "ownerAlive":pid > 0 && kill(pid,0) == 0]) }
        catch { status = .init(phase: .failed, detail: "DNS 恢复未完成：\(error.localizedDescription)") }
    }
    private func transaction(_ command: [String:Any]) async throws {
        var command = command; command["op"] = "protection"
        var result = try core.object(command) as! [String:Any]
        while result["done"] as? Bool != true {
            guard let effect = result["effect"] as? [String:Any], let id = effect["id"] else { throw MonitorError.message("DNS 事务响应无效") }
            var completion: [String:Any] = ["op":"protection", "action":"complete", "id":id, "now":now]
            do { completion["value"] = try await execute(effect) }
            catch { completion["error"] = error.localizedDescription }
            if let token = journal?["firewallToken"] as? String { completion["nativeState"] = ["firewallToken":token] }
            result = try core.object(completion) as! [String:Any]
        }
        let phase = DNSProtectionStatus.Phase(rawValue: result["phase"] as? String ?? "failed") ?? .failed
        let errors = result["errors"] as? [String] ?? []
        let detail = errors.isEmpty ? (phase == .enabled ? "DNS 已保护 · 本机代理使用 IPv4；明文 DNS 已阻断" : "DNS 保护已关闭，原配置已恢复") : errors.joined(separator: "；")
        status = .init(phase: phase, detail: detail)
        if phase == .failed { throw MonitorError.message(detail) }
    }
    private func persist(_ value: [String:Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 2 * DNSProtectionIPC.maximumMessageSize else { throw MonitorError.message("DNS 恢复记录过大") }
        try data.write(to: stateURL, options: .atomic)
        guard chmod(stateURL.path, 0o600) == 0 else { throw MonitorError.message("无法保护 DNS 恢复记录") }
        for path in [stateURL.path,stateURL.deletingLastPathComponent().path] { let fd = open(path,O_RDONLY); if fd >= 0 { _ = fsync(fd); close(fd) } }
        journal = value
    }
    private func execute(_ effect: [String:Any]) async throws -> Any {
        let saved = effect["journal"] as? [String:Any] ?? [:]
        let socket = saved["socket"] as? String ?? ""
        let services: [SystemDNSSnapshot] = (try? JSONDecoder().decode([SystemDNSSnapshot].self, from: JSONSerialization.data(withJSONObject: saved["services"] ?? []))) ?? []
        let sameBoot = saved["bootSession"] as? String == (try DNSProtectionConfiguration.bootSession())
        switch effect["op"] as? String {
        case "preflight":
            guard cgp_dns_firewall_supported() == 1, let request, let port = request.port, let socket = request.socket,
                  let yaml = request.yaml, let generation = request.sourceGeneration else { throw MonitorError.message("DNS 启用参数不完整或系统不受支持") }
            guard try await platform.generation() == generation else { throw MonitorError.message("Clash 配置已更改，请重试") }
            try await platform.validateSocket(socket)
            let snapshot = try await client.snapshot(socket: socket, port: port)
            let general = try await client.request(socket: socket, path: "/configs")
            try DNSProtectionConfiguration.assertDNSPortAvailable()
            let services = try SystemDNSSettings.snapshots()
            let rules = try await DNSSystemCommand.run("/sbin/pfctl", ["-sr"])
            guard rules.contains("anchor \"com.apple/*\"") else { throw MonitorError.message("当前 PF 配置没有可用的系统 anchor") }
            let pf = DNSFirewallState.isEnabled(try await DNSSystemCommand.run("/sbin/pfctl", ["-s","info"]))
            return ["platform":"macos", "ownerUID":ownerUID, "ownerPID":peerPID, "corePID":try await platform.corePID(socket: socket),
                    "socket":socket, "proxyPort":port, "source":yaml, "general":String(decoding:general,as:UTF8.self),
                    "sourceGeneration":generation, "bootSession":try DNSProtectionConfiguration.bootSession(),
                    "services":try JSONSerialization.jsonObject(with:JSONEncoder().encode(services)), "pfWasEnabled":pf,
                    "selection":try await client.selection(socket: socket),
                    "snapshot":["mode":snapshot.mode, "current":snapshot.current as Any? ?? NSNull()]] as [String:Any]
        case "persist": try persist(saved); return NSNull()
        case "frontendStart": let _: UInt16 = try core.call(["op":"dnsStart", "listenPort":53, "upstreamPort":17853]); return NSNull()
        case "frontendStop": let _: Bool = try core.call(["op":"dnsStop"]); return NSNull()
        case "clashApply":
            try await client.reload(socket:socket,yaml:effect["protectedYAML"] as! String)
            try await client.restoreSelection(socket:socket,selection:saved["selection"] as? [String:String] ?? [:])
            try await client.closeAllConnections(socket:socket); try await client.flushDNS(socket:socket); return NSNull()
        case "dnsReady": try await platform.waitForDNS(port:17853); try await platform.waitForDNS(port:53,tcp:true); return NSNull()
        case "systemDNSApply": try SystemDNSSettings.apply(services,restoring:false); return NSNull()
        case "systemDNSRestore": try SystemDNSSettings.apply(services,restoring:true); return NSNull()
        case "firewallEnable":
            let text = try await DNSSystemCommand.run("/sbin/pfctl",["-E"])
            guard let range = text.range(of:#"Token\s*:\s*(\d+)"#,options:.regularExpression),let token = text[range].split(separator:":").last?.trimmingCharacters(in:.whitespacesAndNewlines) else { throw MonitorError.message("无法取得 PF 启用引用") }
            // Persist the acquired native token before installing any filter.
            var updated = saved; updated["firewallToken"] = token; try persist(updated)
            _ = try await DNSSystemCommand.run("/sbin/pfctl",["-a",DNSProtectionConfiguration.anchor,"-f","-"],input:Data(DNSProtectionConfiguration.firewallRules.utf8))
            try await platform.clearExistingDNSStates(); return ["firewallToken":token]
        case "firewallDisable":
            if sameBoot {
                _ = try await DNSSystemCommand.run("/sbin/pfctl",["-a",DNSProtectionConfiguration.anchor,"-F","rules"])
                if let token = journal?["firewallToken"] as? String {
                    let references = try await DNSSystemCommand.run("/sbin/pfctl",["-s","References"])
                    if try DNSFirewallState.containsReference(token,output:references) { _ = try await DNSSystemCommand.run("/sbin/pfctl",["-X",token]) }
                }
                if saved["pfWasEnabled"] as? Bool == true, !DNSFirewallState.isEnabled(try await DNSSystemCommand.run("/sbin/pfctl",["-s","info"])) { _ = try await DNSSystemCommand.run("/sbin/pfctl",["-e"]) }
            }
            return NSNull()
        case "cacheFlush": await platform.flushSystemCache(); return NSNull()
        case "verify":
            guard try await platform.generation() == saved["sourceGeneration"] as? String else { throw MonitorError.message("Clash 配置已重新加载") }
            let live = try await client.snapshot(socket:socket,port:(saved["proxyPort"] as? NSNumber)?.uint16Value ?? 0)
            guard live.mode == "global",let node = live.current, !["DIRECT","REJECT","PASS"].contains(node.uppercased()) else { throw MonitorError.message("Clash 已离开受保护的全局代理模式") }
            if live.selectionSignature != selectionSignature {
                try await client.closeDNSConnections(socket:socket); try await client.flushDNS(socket:socket)
                selectionSignature = live.selectionSignature
            }
            let additions = try SystemDNSSettings.snapshots().filter { current in !services.contains { $0.serviceID == current.serviceID } }
            if !additions.isEmpty { return ["newServices":try JSONSerialization.jsonObject(with:JSONEncoder().encode(additions))] }
            try await platform.assertSystemResolvers(); try await platform.assertFirewall(); try await platform.probe(port:53); try await platform.assertIPv4Policy(socket:socket)
            return NSNull()
        case "clashRestorePrepare":
            let pid = (saved["corePID"] as? NSNumber)?.int32Value ?? 0
            guard sameBoot, pid > 0, kill(pid,0) == 0 else { return NSNull() }
            let uid = (saved["ownerUID"] as? NSNumber)?.uint32Value ?? ownerUID
            try await platform.validateSocket(socket,uid:uid)
            guard try await platform.corePID(socket:socket) == pid else { return NSNull() }
            let general = try await client.request(socket:socket,path:"/configs")
            let restoreSelection = try await client.selection(socket:socket)
            let changed = try await platform.generation(uid:uid) != saved["sourceGeneration"] as? String
            return ["general":String(decoding:general,as:UTF8.self),"sourceChanged":changed,"source":try await platform.latestSource(uid:uid),"selection":restoreSelection] as [String:Any]
        case "clashRestoreApply":
            try await client.reload(socket:socket,yaml:effect["restoreYAML"] as! String)
            try await client.restoreSelection(socket:socket,selection:effect["restoreSelection"] as? [String:String] ?? [:]); try await client.flushDNS(socket:socket); return NSNull()
        case "removeJournal": try FileManager.default.removeItem(at:stateURL);journal = nil;return NSNull()
        case "enabled", "finishRestore": return NSNull()
        default: throw MonitorError.message("Unknown DNS platform effect")
        }
    }
}
