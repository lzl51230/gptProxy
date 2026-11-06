import Foundation

public struct ProxyHealthResult: Sendable, Equatable {
    public let supportsUDP: Bool
    public let codexLatencyMilliseconds: Int

    public init(supportsUDP: Bool, codexLatencyMilliseconds: Int) {
        self.supportsUDP = supportsUDP
        self.codexLatencyMilliseconds = codexLatencyMilliseconds
    }
}

public enum ProxyHealthChecker {
    public static func check(port: UInt16) async throws -> ProxyHealthResult {
        try await check(port: port, connection: CodexConnectionSession(port: port))
    }

    static func check(port: UInt16, connection: any CodexConnection) async throws -> ProxyHealthResult {
        let supportsUDP = try await Task.detached(priority: .userInitiated) {
            try SOCKS5Probe.probe(port: port)
        }.value
        try Task.checkCancellation()
        do {
            let heartbeat = try await connection.heartbeat()
            await connection.close()
            guard heartbeat.isHealthy, let latency = heartbeat.latencyMilliseconds else {
                throw MonitorError.message(heartbeat.failureReason ?? "无法通过代理连接 Codex")
            }
            return ProxyHealthResult(supportsUDP: supportsUDP, codexLatencyMilliseconds: latency)
        } catch {
            await connection.close()
            throw error
        }
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
        }
    }
}

private enum SOCKS5Probe {
    static func probe(port: UInt16) throws -> Bool {
        try RustCore().call(["op":"probeUDP", "port":port])
    }
}
