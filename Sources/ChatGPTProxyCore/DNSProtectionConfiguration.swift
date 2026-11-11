import Foundation
import Darwin

public enum DNSProtectionConfiguration {
    public static let version = "4"
    public static let maximumConfigurationSize = 32 * 1024 * 1024
    // Recovery journals include both source and runtime YAML, JSON-escaped.
    public static let maximumRecoverySize = 256 * 1024 * 1024
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
        guard lstat(url.path, &info) == 0 else {
            throw MonitorError.message("无法访问 Clash 工作配置")
        }
        try validateSource(info, ownerUID: ownerUID)
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func validateSource(_ info: stat, ownerUID: uid_t) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == ownerUID else {
            throw MonitorError.message("Clash 工作配置必须是当前用户拥有的普通文件，且不能是符号链接")
        }
        try validateSourceSize(info.st_size)
    }

    private static func validateSourceSize(_ size: Int64) throws {
        guard size >= 0, size <= maximumConfigurationSize else {
            let actual = String(format: "%.2f", Double(size) / 1024 / 1024)
            throw MonitorError.message("Clash 工作配置大小为 \(actual) MiB（\(size) 字节），超过 32 MiB 上限")
        }
    }

    public static func readSource(at url: URL, ownerUID: uid_t = getuid()) throws -> String {
        _ = try sourceGeneration(at: url, ownerUID: ownerUID)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw MonitorError.message("无法读取 Clash 工作配置") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw MonitorError.message("无法检查 Clash 工作配置") }
        try validateSource(info, ownerUID: ownerUID)
        var bytes = Data()
        while bytes.count <= maximumConfigurationSize {
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumConfigurationSize + 1 - bytes.count)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        try validateSourceSize(Int64(bytes.count))
        guard fstat(fd, &info) == 0 else { throw MonitorError.message("无法检查 Clash 工作配置") }
        try validateSource(info, ownerUID: ownerUID)
        guard let yaml = String(data: bytes, encoding: .utf8) else {
            throw MonitorError.message("Clash 工作配置不是有效 UTF-8")
        }
        return yaml
    }

    public struct BootstrapInspection: Decodable, Sendable {
        public let replacements: [String: [String]]
        public let plaintext: Bool
    }
    public static func inspectBootstrap(_ source: String, saved: String?) throws -> BootstrapInspection {
        try RustCore().call(["op": "bootstrapRepair", "source": source, "saved": saved ?? ""])
    }
    public static func protectedYAML(_ source: String, bootstrapRepair: [String: [String]] = [:]) throws -> String {
        try RustCore().call(["op":"protectedYAML", "source":source, "bootstrapRepair":bootstrapRepair])
    }
    static func isEncryptedResolver(_ value: String, requiresIP: Bool) -> Bool {
        try! RustCore().call(["op":"encryptedResolver", "value":value, "requiresIP":requiresIP])
    }
    public static func runtimeYAML(_ source: String, general: Data) throws -> String {
        try RustCore().call(["op":"runtimeYAML", "source":source, "general":String(decoding:general, as:UTF8.self)])
    }
    public static func runtimeIPv6(_ general: Data) throws -> Bool {
        try RustCore().call(["op":"runtimeIPv6", "general":String(decoding:general, as:UTF8.self)])
    }
    public static func restoredYAML(_ source: String, general: Data, originalIPv6: Bool?,
                                    ipv4PolicyApplied: Bool, sourceChanged: Bool) throws -> String {
        var request: [String:Any] = ["op":"restoredYAML", "source":source, "general":String(decoding:general, as:UTF8.self),
                                    "ipv4PolicyApplied":ipv4PolicyApplied, "sourceChanged":sourceChanged]
        if let originalIPv6 { request["originalIPv6"] = originalIPv6 }
        return try RustCore().call(request)
    }

}

public struct DNSProtectionStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case disabled, enabling, enabled, restoring, failed }
    public var phase: Phase
    public var detail: String
    public var version: String = DNSProtectionConfiguration.version
    public var lastStopReason: String?
    public var lastStopAt: String?
    public var recoveryResult: String?
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
    public var bootstrapRepair: [String: [String]]?
    public init(command: Command, port: UInt16? = nil, socket: String? = nil, yaml: String? = nil, sourceGeneration: String? = nil) {
        self.command = command; self.port = port; self.socket = socket; self.yaml = yaml
        self.sourceGeneration = sourceGeneration
    }
}
