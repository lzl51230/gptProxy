import Foundation
import Darwin
import Yams

public enum DNSProtectionConfiguration {
    public static let version = "2"
    public static let label = "local.alex.chatgpt-proxy.dns"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let socketPath = "/var/run/\(label).sock"
    public static let stateDirectory = "/Library/Application Support/ChatGPT Proxy DNS"
    public static let clashDNSPort: UInt16 = 17853
    public static let nameServers = ["https://1.1.1.1/dns-query#GLOBAL", "https://8.8.8.8/dns-query#GLOBAL"]
    public static let anchor = "com.apple/local.alex.chatgpt-proxy.dns"
    public static func assertDNSPortAvailable() throws {
        for transport in [SOCK_DGRAM, SOCK_STREAM] {
            let fd = socket(AF_INET, transport, 0)
            guard fd >= 0 else { throw MonitorError.message("无法检查本地 DNS 端口") }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = clashDNSPort.bigEndian; inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw MonitorError.message("本地 DNS 端口 17853 已被占用，未修改系统设置") }
        }
    }
    public static func bootSession() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else {
            throw MonitorError.message("无法确认当前系统启动会话")
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw MonitorError.message("无法读取当前系统启动会话")
        }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public static let firewallRules = """
    block drop out quick on ! lo0 inet proto { tcp udp } from any to any port 53 label "gptproxy-dns"
    block drop out quick on ! lo0 inet6 proto { tcp udp } from any to any port 53 label "gptproxy-dns"
    """ + "\n"

    public static func sourceGeneration(at url: URL, ownerUID: uid_t = getuid()) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID,
              info.st_size <= DNSProtectionIPC.maximumMessageSize else {
            throw MonitorError.message("Clash 工作配置必须是当前用户拥有的普通文件，且不超过 4 MB")
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    public static func protectedYAML(_ source: String) throws -> String {
        guard var config = try Yams.load(yaml: source.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))) as? [String: Any],
              var dns = config["dns"] as? [String: Any] else {
            throw MonitorError.message("Clash 配置缺少 DNS 设置")
        }
        guard (config["mode"] as? String)?.lowercased() == "global",
              (config["tun"] as? [String: Any])?["enable"] as? Bool != true else {
            throw MonitorError.message("DNS 保护要求 Clash Party 全局模式，并关闭 TUN，避免重复接管")
        }
        let bootstrap = dns["default-nameserver"] as? [String] ?? []
        let proxyDNS = dns["proxy-server-nameserver"] as? [String] ?? []
        guard !bootstrap.isEmpty, !proxyDNS.isEmpty,
              bootstrap.allSatisfy({ isEncryptedResolver($0, requiresIP: true) }),
              proxyDNS.allSatisfy({ isEncryptedResolver($0, requiresIP: false) }) else {
            throw MonitorError.message("Clash 的 default-nameserver 和 proxy-server-nameserver 必须使用独立加密解析，且引导服务器须为 IPv4 地址；不支持 IPv6 引导地址")
        }
        config["ipv6"] = false
        if var proxies = config["proxies"] as? [[String: Any]] {
            for index in proxies.indices { proxies[index]["ip-version"] = "ipv4" }
            config["proxies"] = proxies
        }
        if var providers = config["proxy-providers"] as? [String: [String: Any]] {
            for name in Array(providers.keys) {
                var override = providers[name]?["override"] as? [String: Any] ?? [:]
                override["ip-version"] = "ipv4"
                providers[name]?["override"] = override
            }
            config["proxy-providers"] = providers
        }
        dns["enable"] = true
        dns["ipv6"] = false
        dns["listen"] = "127.0.0.1:\(clashDNSPort)"
        dns["enhanced-mode"] = "redir-host"
        dns["prefer-h3"] = false
        dns["respect-rules"] = false
        dns["nameserver"] = nameServers
        dns["direct-nameserver"] = nameServers
        dns["nameserver-policy"] = [String: String]()
        dns["proxy-server-nameserver-policy"] = [String: String]()
        dns["fallback"] = [String]()
        config["dns"] = dns
        return try Yams.dump(object: config)
    }

    static func isEncryptedResolver(_ value: String, requiresIP: Bool) -> Bool {
        guard let url = URL(string: value), ["https", "tls"].contains(url.scheme),
              let host = url.host, url.fragment == nil, url.user == nil, url.password == nil else { return false }
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr(), v6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &v6) != 1 else { return false }
        if !requiresIP { return !["localhost", "127.0.0.1"].contains(host.lowercased()) }
        return inet_pton(AF_INET, literal, &v4) == 1
    }

    public static func runtimeYAML(_ source: String, general: Data) throws -> String {
        guard var config = try Yams.load(yaml: source) as? [String: Any],
              let live = try Yams.load(yaml: String(decoding: general, as: UTF8.self)) as? [String: Any] else {
            throw MonitorError.message("无法读取 Clash 当前配置")
        }
        // Preserve live settings changed through the controller since the file was generated.
        for key in ["mode", "log-level", "ipv6", "allow-lan", "bind-address", "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "tun"] {
            if let value = live[key], !(value is NSNull) { config[key] = value }
        }
        return try Yams.dump(object: config)
    }

    public static func runtimeIPv6(_ general: Data) throws -> Bool {
        guard let values = try Yams.load(yaml: String(decoding: general, as: UTF8.self)) as? [String: Any],
              let enabled = values["ipv6"] as? Bool else { throw MonitorError.message("无法确认 Clash 的 IPv6 设置") }
        return enabled
    }

    public static func restoredYAML(_ source: String, general: Data, originalIPv6: Bool?,
                                    ipv4PolicyApplied: Bool, sourceChanged: Bool) throws -> String {
        let merged = try runtimeYAML(source, general: general)
        guard ipv4PolicyApplied else { return merged } // Version 1 recovery journals.
        guard var config = try Yams.load(yaml: merged) as? [String: Any],
              let baseline = try Yams.load(yaml: source) as? [String: Any] else {
            throw MonitorError.message("无法恢复 Clash IPv6 设置")
        }
        if sourceChanged {
            // A new source owns the policy, including an omitted key (Mihomo's default).
            config["ipv6"] = baseline["ipv6"]
        } else if try !runtimeIPv6(general), let originalIPv6 {
            // Only undo our false value. Preserve an explicit later true value.
            config["ipv6"] = originalIPv6
        }
        return try Yams.dump(object: config)
    }
}

public struct DNSProtectionStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case disabled, enabling, enabled, restoring, failed }
    public var phase: Phase
    public var detail: String
    public var version: String = DNSProtectionConfiguration.version
    public var isEnabled: Bool { phase == .enabled }
    public init(phase: Phase, detail: String) { self.phase = phase; self.detail = detail }
}

public struct DNSProtectionRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable { case enable, status, heartbeat, restore }
    public var command: Command
    public var port: UInt16?
    public var socket: String?
    public var yaml: String?
    public var sourceGeneration: String?
    public init(command: Command, port: UInt16? = nil, socket: String? = nil, yaml: String? = nil, sourceGeneration: String? = nil) {
        self.command = command; self.port = port; self.socket = socket; self.yaml = yaml
        self.sourceGeneration = sourceGeneration
    }
}
