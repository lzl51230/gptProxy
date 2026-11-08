import Foundation
import ChatGPTProxyCore

@MainActor
enum ProtectionDiagnostics {
    private static var previous: Data?
    private static let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.protection-log", qos: .utility)

    static func record(phase: String, dns: DNSProtectionStatus, pids: [pid_t], paused: Bool,
                       retry: Int, proxyReady: Bool, cliReady: Bool) {
        let fields: [String: Any] = ["summary": scrub(phase), "dnsPhase": dns.phase.rawValue,
            "dnsDetail": scrub(dns.detail), "lastStopReason": scrub(dns.lastStopReason ?? ""),
            "lastStopAt": dns.lastStopAt ?? "", "recoveryResult": dns.recoveryResult ?? "",
            "gptPIDs": pids, "paused": paused, "retryCount": retry,
            "proxyReady": proxyReady, "cliReady": cliReady]
        guard let key = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys), key != previous else { return }
        previous = key
        var row = fields
        row["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return }
        queue.async {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/ChatGPT Proxy")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let snapshot = directory.appendingPathComponent("runtime-status.json")
                try data.write(to: snapshot, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
                let log = directory.appendingPathComponent("protection.jsonl")
                if let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
                    let previous = directory.appendingPathComponent("protection.previous.jsonl")
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: log, to: previous)
                }
                if !FileManager.default.fileExists(atPath: log.path) {
                    FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data([10]))
            } catch {}
        }
    }

    private static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(https?|socks5h?)://[^\s]+"#, with: "<URL>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|secret|password|authorization)\s*[:=]\s*\S+"#,
                                  with: "$1=<REDACTED>", options: .regularExpression)
    }
}
