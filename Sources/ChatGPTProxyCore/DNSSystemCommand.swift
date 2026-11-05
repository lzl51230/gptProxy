import Foundation

public enum DNSSystemCommand {
    public static func run(_ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 15) async throws -> String {
        try await Task.detached(priority: .utility) {
            let child = Process(), output = Pipe(), stdin = Pipe()
            child.executableURL = URL(fileURLWithPath: path)
            child.arguments = arguments
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            child.standardOutput = output; child.standardError = output
            child.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
            try child.run()
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            if let input {
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch { child.terminate() }
                try? stdin.fileHandleForWriting.close()
            }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0 else {
                let detail = String(decoding: bytes.prefix(1500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw MonitorError.message("\(URL(fileURLWithPath: path).lastPathComponent) 执行失败（\(child.terminationStatus)）：\(detail)")
            }
            return String(decoding: bytes, as: UTF8.self)
        }.value
    }
}
