// Compiled against the actual package objects by qa-cli-memory.py.
import Darwin
import Foundation
import ChatGPTProxyCore

@main struct CLIMemoryProbe {
    static func memory() -> [String: UInt64] {
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        let fdBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        // The size-only call includes spare slots, not just open descriptors.
        var descriptors = Data(count: Int(max(0, fdBytes)))
        let used = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, fdBytes)
        }
        return ["heap": UInt64(heap.size_in_use), "rss": info.pti_resident_size,
                "fds": UInt64(max(0, used)) / UInt64(MemoryLayout<proc_fdinfo>.size)]
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let profile = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let duration = Double(CommandLine.arguments[3])!
        let log = root.appendingPathComponent("log")
        let controller = ProxyBridgeCLIController(executableURL: root.appendingPathComponent("fake-cli"), timeout: 5, logURL: log)
        let started = ProcessInfo.processInfo.systemUptime
        var round = 0
        var failures: [String] = []
        var warmBaseline: [String: UInt64]?
        var initialFDs: UInt64?
        var maximumHeap: UInt64 = 0, maximumRSS: UInt64 = 0
        var maximumBurstHeap: Int64 = 0, maximumBurstRSS: Int64 = 0
        let samples = try FileHandle(forWritingTo: root.appendingPathComponent("samples.jsonl"))
        defer { try? samples.close() }
        repeat {
            let roundStarted = ProcessInfo.processInfo.systemUptime
            for name in ["go", "done"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
            try String(round).write(to: root.appendingPathComponent("round"), atomically: true, encoding: .utf8)
            try await controller.ensureRunning(profileData: profile)
            let child = controller.processIdentifier!
            try await Task.sleep(for: .milliseconds(50))
            let before = memory()
            FileManager.default.createFile(atPath: root.appendingPathComponent("go").path, contents: nil)
            // The same occupied-MainActor scenario that fails on the old reader.
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path),
                  ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            let peak = memory()
            let heapGrowth = Int64(peak["heap"]!) - Int64(before["heap"]!)
            let rssGrowth = Int64(peak["rss"]!) - Int64(before["rss"]!)
            maximumBurstHeap = max(maximumBurstHeap, heapGrowth)
            maximumBurstRSS = max(maximumBurstRSS, rssGrowth)
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path) { failures.append("producer timed out at round \(round)") }
            if heapGrowth >= 16 * 1024 * 1024 || rssGrowth >= 16 * 1024 * 1024 { failures.append("unbounded burst at round \(round)") }
            // Let the final pipe block reach the log before shutdown.
            var drained = false
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(10))
                drained = try autoreleasepool {
                    let handle = try FileHandle(forReadingFrom: log)
                    defer { try? handle.close() }
                    let end = try handle.seekToEnd()
                    try handle.seek(toOffset: end > 256 ? end - 256 : 0)
                    let tail = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
                    return tail.contains("DRAINED_\(round)")
                }
                if drained { break }
            }
            if !drained { failures.append("log did not drain at round \(round)") }
            await controller.stopAndWait()
            try await Task.sleep(for: .milliseconds(50))
            let idle = memory()
            initialFDs = initialFDs ?? idle["fds"]
            if idle["fds"]! > initialFDs! + 2 { failures.append("descriptor growth at round \(round)") }
            if controller.processIdentifier != nil || kill(child, 0) == 0 { failures.append("child survived stop at round \(round)") }
            maximumHeap = max(maximumHeap, peak["heap"]!, idle["heap"]!)
            maximumRSS = max(maximumRSS, peak["rss"]!, idle["rss"]!)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= min(300, duration / 3), warmBaseline == nil { warmBaseline = idle }
            if let baseline = warmBaseline, idle["heap"]! > baseline["heap"]! + 16 * 1024 * 1024 {
                failures.append("heap grew after warmup at round \(round)")
            }
            let sample: [String: Any] = ["round": round, "elapsed": elapsed, "before": before, "peak": peak, "idle": idle]
            try samples.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) + Data([10]))
            let summary: [String: Any] = ["elapsed": elapsed, "rounds": round + 1, "emittedBytes": (round + 1) * 64 * 1024 * 1024,
                "maximumHeap": maximumHeap, "maximumRSS": maximumRSS, "maximumBurstHeap": maximumBurstHeap,
                "maximumBurstRSS": maximumBurstRSS, "warmBaseline": warmBaseline ?? [:], "lastIdle": idle,
                "failures": failures, "complete": elapsed >= duration, "passed": elapsed >= duration && failures.isEmpty]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("summary.json"), options: .atomic)
            if !failures.isEmpty { print(failures.joined(separator: "\n")); exit(1) }
            round += 1
            if elapsed < duration {
                let pause = min(max(0, 10 - (ProcessInfo.processInfo.systemUptime - roundStarted)), duration - elapsed)
                if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
            }
        } while ProcessInfo.processInfo.systemUptime - started < duration
        // Include the final idle interval in the completed observation duration.
        var summary = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("summary.json"))) as! [String: Any]
        summary["elapsed"] = ProcessInfo.processInfo.systemUptime - started
        summary["complete"] = true
        summary["passed"] = failures.isEmpty
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary.json"), options: .atomic)
        print("PASS: \(round) bursts, \(Int(ProcessInfo.processInfo.systemUptime - started)) seconds; no heap, descriptor or child-process growth")
    }
}
