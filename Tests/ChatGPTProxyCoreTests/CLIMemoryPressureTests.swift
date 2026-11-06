import Darwin
import Foundation
import XCTest
@testable import ChatGPTProxyCore

@MainActor
final class CLIMemoryPressureTests: XCTestCase {
    func testBusyMainActorDoesNotRetainRawCLIOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-cli")
        try """
        #!/bin/sh
        cd "$(dirname "$0")"
        cat >/dev/null
        trap 'exit 0' TERM INT
        printf 'ProxyBridge CLI 4.1.1\\nProfile "ChatGPT Only": 1 proxies, 3 rules applied\\nDNS proxy: off (host name rules and send hostname do not work)\\nRedirecting traffic. Press Ctrl+C to stop.\\n'
        while [ ! -f go ]; do sleep 0.01; done
        awk 'BEGIN { line=sprintf("%4095s", ""); gsub(/ /, "x", line); for(i=0;i<16384;i++) print line; }'
        touch done
        while :; do sleep 0.1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/ChatGPT-Only.pbprofile")
        let controller = ProxyBridgeCLIController(executableURL: script, timeout: 3, logURL: root.appendingPathComponent("log"))
        try await controller.ensureRunning(profileData: Data(contentsOf: profile))
        try await Task.sleep(for: .milliseconds(50))
        let before = Self.memory()
        FileManager.default.createFile(atPath: root.appendingPathComponent("go").path, contents: nil)
        // Deliberately occupy MainActor while the real pipe callbacks receive 64 MiB.
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path),
              ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        usleep(50_000)
        let after = Self.memory()
        let completed = FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path)
        await controller.stopAndWait()
        XCTAssertTrue(completed, "The producer must finish while MainActor is occupied")
        XCTAssertLessThan(Int64(after.heap) - Int64(before.heap), 16 * 1024 * 1024, "Raw output must not accumulate in queued tasks")
        XCTAssertLessThan(Int64(after.rss) - Int64(before.rss), 16 * 1024 * 1024, "RSS must stay within the burst envelope")
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.processIdentifier)
    }

    private static func memory() -> (heap: UInt64, rss: UInt64) {
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        return (UInt64(heap.size_in_use), info.pti_resident_size)
    }
}
