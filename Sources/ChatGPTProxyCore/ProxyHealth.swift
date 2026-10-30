import Darwin
import Foundation

public struct ProxyHealthResult: Sendable, Equatable {
    public let supportsUDP: Bool
    public let egressLocation: String

    public init(supportsUDP: Bool, egressLocation: String) {
        self.supportsUDP = supportsUDP
        self.egressLocation = egressLocation
    }
}

public enum ProxyHealthChecker {
    public static func check(port: UInt16) async throws -> ProxyHealthResult {
        try await Task.detached(priority: .userInitiated) {
            let supportsUDP = try SOCKS5Probe.probe(port: port)
            let trace = try CurlRunner.cloudflareTrace(port: port)
            let location = try EgressLocationParser.location(from: trace)
            return ProxyHealthResult(supportsUDP: supportsUDP, egressLocation: location)
        }.value
    }
}

public enum EgressLocationParser {
    public static func location(from trace: String) throws -> String {
        for line in trace.split(whereSeparator: \Character.isNewline) {
            guard line.hasPrefix("loc=") else { continue }
            let value = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { break }
            return value.uppercased()
        }
        throw ProxyHealthError.missingEgressLocation
    }
}

public enum SystemExtensionParser {
    public static func proxyBridgeIsEnabled(in output: String) -> Bool {
        output.split(whereSeparator: \Character.isNewline).contains { row in
            let fields = row.split(whereSeparator: \Character.isWhitespace)
            return fields.contains("L4HJT32Z59")
                && fields.contains("com.interceptsuite.ProxyBridge.extension")
                && fields.contains(where: { $0.hasPrefix("(\(ProxyBridgeRelease.version)/") })
                && row.localizedCaseInsensitiveContains("[activated enabled]")
        }
    }
}

public enum ProxyHealthError: LocalizedError {
    case socketCreationFailed
    case connectionFailed
    case writeFailed
    case unexpectedSOCKS5Reply
    case udpAssociateRejected(UInt8)
    case curlFailed(String)
    case missingEgressLocation
    case unsupportedRegion(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            "无法创建代理检测连接。"
        case .connectionFailed:
            "无法连接本地代理，请确认代理程序正在运行。"
        case .writeFailed:
            "向本地代理发送检测数据失败。"
        case .unexpectedSOCKS5Reply:
            "该端口没有返回有效的 SOCKS5 响应。"
        case let .udpAssociateRejected(code):
            "本地代理不支持 UDP Associate（错误码 \(code)）。"
        case let .curlFailed(message):
            "无法通过代理检测出口：\(message)"
        case .missingEgressLocation:
            "代理响应中没有出口地区信息。"
        case let .unsupportedRegion(region):
            "代理出口仍位于不支持的地区（\(region)）。"
        }
    }
}

private enum SOCKS5Probe {
    static func probe(port: UInt16) throws -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyHealthError.socketCreationFailed }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ProxyHealthError.connectionFailed }

        try writeAll([0x05, 0x01, 0x00], to: descriptor)
        let greeting = try readExactly(2, from: descriptor)
        guard greeting == [0x05, 0x00] else { throw ProxyHealthError.unexpectedSOCKS5Reply }

        try writeAll([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0], to: descriptor)
        let response = try readExactly(4, from: descriptor)
        guard response[0] == 0x05 else { throw ProxyHealthError.unexpectedSOCKS5Reply }
        guard response[1] == 0x00 else { throw ProxyHealthError.udpAssociateRejected(response[1]) }
        return true
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            guard count > 0 else { throw ProxyHealthError.writeFailed }
            sent += count
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let current = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: received), count - received, 0)
            }
            guard current > 0 else { throw ProxyHealthError.unexpectedSOCKS5Reply }
            received += current
        }
        return bytes
    }
}

private enum CurlRunner {
    static func cloudflareTrace(port: UInt16) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--disable",
            "--silent",
            "--show-error",
            "--fail",
            "--max-time", "10",
            "--proxy", "socks5h://127.0.0.1:\(port)",
            "https://www.cloudflare.com/cdn-cgi/trace",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProxyHealthError.curlFailed(message.isEmpty ? "curl 退出码 \(process.terminationStatus)" : message)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
