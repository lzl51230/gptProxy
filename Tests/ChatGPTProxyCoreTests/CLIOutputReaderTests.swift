import Foundation
import XCTest
@testable import ChatGPTProxyCore

final class CLIOutputLinesTests: XCTestCase {
    func testFragmentedUTF8AndUnterminatedFinalLine() {
        var lines = CLIOutputLines()
        var result: [String] = []
        let data = Data("  中文日志\r\nfinal".utf8)
        for byte in data {
            lines.consume(Data([byte])) { result.append($0) }
            XCTAssertLessThanOrEqual(lines.bufferedByteCount, CLIOutputLines.maximumBytes)
        }
        lines.finish { result.append($0) }
        XCTAssertEqual(result, ["中文日志", "final"])
        XCTAssertEqual(lines.bufferedByteCount, 0)
    }

    func testOversizedCompleteAndFragmentedLinesDiscardSuffix() {
        for fragmented in [false, true] {
            var lines = CLIOutputLines()
            var result: [String] = []
            let data = Data((String(repeating: "x", count: 65_537) + "Redirecting traffic. Press Ctrl+C to stop.\nnext\n").utf8)
            let stride = fragmented ? 1024 : data.count
            for start in Swift.stride(from: 0, to: data.count, by: stride) {
                lines.consume(data[start..<min(start + stride, data.count)]) { result.append($0) }
                XCTAssertLessThanOrEqual(lines.bufferedByteCount, CLIOutputLines.maximumBytes)
            }
            lines.finish { result.append($0) }
            XCTAssertEqual(result, ["ERROR: CLI 输出行过长。", "next"])
        }
    }

    func testExactLimitAndOversizedEOF() {
        var lines = CLIOutputLines()
        var result: [String] = []
        lines.consume(Data((String(repeating: "x", count: 65_536) + "\n").utf8)) { result.append($0) }
        XCTAssertEqual(result.first?.utf8.count, 65_536)
        result.removeAll()
        lines.consume(Data(repeating: 120, count: 65_537)) { result.append($0) }
        lines.finish { result.append($0) }
        XCTAssertEqual(result, ["ERROR: CLI 输出行过长。"])
    }
}

@MainActor
final class CLIOutputMailboxTests: XCTestCase {
    func testBurstSchedulesOneDeliveryWithCumulativeReadinessAndFailure() {
        let scheduler = DeliveryScheduler()
        var received: [ProxyBridgeCLIOutput] = []
        let mailbox = CLIOutputMailbox(schedule: scheduler.schedule) { received.append($0) }
        var output = ProxyBridgeCLIOutput()
        for line in readyLines { output.consume(line); mailbox.publish(output) }
        for _ in 0..<10_000 { mailbox.publish(output) }
        output.consume("ERROR: failed after ready")
        mailbox.publish(output)
        XCTAssertEqual(scheduler.count, 1)
        XCTAssertTrue(received.isEmpty)
        scheduler.run()
        XCTAssertEqual(received, [output])
        XCTAssertTrue(received[0].versionMatches)
        XCTAssertTrue(received[0].profileApplied)
        XCTAssertTrue(received[0].dnsDisabled)
        XCTAssertFalse(received[0].isReady)
        mailbox.publish(output)
        XCTAssertEqual(scheduler.count, 1)
        scheduler.run()
        XCTAssertEqual(received.count, 2)
    }

    func testInvalidationDropsPendingAndFutureUpdatesAndReleasesMailbox() {
        let scheduler = DeliveryScheduler()
        var received = 0
        var mailbox: CLIOutputMailbox? = CLIOutputMailbox(schedule: scheduler.schedule) { _ in received += 1 }
        weak var weakMailbox: CLIOutputMailbox?
        weakMailbox = mailbox
        mailbox?.publish(ProxyBridgeCLIOutput())
        mailbox?.invalidate()
        mailbox?.publish(ProxyBridgeCLIOutput())
        XCTAssertEqual(scheduler.count, 1)
        mailbox = nil
        XCTAssertNil(weakMailbox)
        scheduler.run()
        XCTAssertEqual(received, 0)
    }
}

@MainActor
final class CLIOutputReaderTests: XCTestCase {
    func testBothStreamsEOFAndStopReleaseReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stdout = Pipe(), stderr = Pipe()
        var received: [ProxyBridgeCLIOutput] = []
        var reader: CLIOutputReader? = try CLIOutputReader(handles: [stdout.fileHandleForReading, stderr.fileHandleForReading],
                                                         logURL: root.appendingPathComponent("log")) { received.append($0) }
        weak var weakReader: CLIOutputReader?
        weakReader = reader
        // Neither stream ends with a newline; readiness requires both EOF tails.
        try stdout.fileHandleForWriting.write(contentsOf: Data(readyLines.prefix(2).joined(separator: "\n").utf8))
        try stderr.fileHandleForWriting.write(contentsOf: Data(readyLines.suffix(2).joined(separator: "\n").utf8))
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        for _ in 0..<100 {
            if received.last?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(received.last?.isReady, true)
        await reader?.stopAndWait()
        reader = nil
        XCTAssertNil(weakReader)
        let logged = try String(contentsOf: root.appendingPathComponent("log"), encoding: .utf8)
        for line in readyLines { XCTAssertTrue(logged.contains(line)) }
        try stdout.fileHandleForReading.close()
        try stderr.fileHandleForReading.close()
    }

    func testRotationAndUnwritableLogDoNotLoseState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log")
        try Data(repeating: 120, count: 5_000_000).write(to: url)
        let log = CLIOutputLog(url: url)
        log.write("new generation")
        log.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new generation\n")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("1")).count, 5_000_000)
        let pipe = Pipe()
        var ready = false
        // The parent is a regular file, so writes fail without affecting parsing.
        let reader = try CLIOutputReader(handles: [pipe.fileHandleForReading], logURL: url.appendingPathComponent("invalid")) { ready = $0.isReady }
        try pipe.fileHandleForWriting.write(contentsOf: Data((readyLines.joined(separator: "\n") + "\n").utf8))
        for _ in 0..<100 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await reader.stopAndWait()
        XCTAssertTrue(ready)
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.close()
    }
}

private let readyLines = ["ProxyBridge CLI 4.1.1", "Profile \"ChatGPT Only\": 1 proxies, 3 rules applied",
                          "DNS proxy: off (host name rules and send hostname do not work)", "Redirecting traffic. Press Ctrl+C to stop."]

private final class DeliveryScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []
    var count: Int { lock.withLock { actions.count } }
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions.append(action) } }
    @MainActor func run() {
        let pending = lock.withLock { let pending = actions; actions = []; return pending }
        pending.forEach { $0() }
    }
}
