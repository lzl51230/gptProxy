import Darwin
import Foundation

/// Raw bytes never cross onto MainActor. Dispatch coalesces readable events;
/// slow parsing or disk IO applies pipe backpressure instead of queuing Data.
final class CLIOutputReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.alex.chatgpt-proxy.cli-output", qos: .utility)
    private let cancelled = DispatchGroup()
    private let sources: [DispatchSourceRead]
    private var lines: [CLIOutputLines]
    private var output = ProxyBridgeCLIOutput()
    private let log: CLIOutputLog
    private let mailbox: CLIOutputMailbox

    init(handles: [FileHandle], logURL: URL,
         deliver: @escaping @MainActor @Sendable (ProxyBridgeCLIOutput) -> Void) throws {
        log = CLIOutputLog(url: logURL)
        mailbox = CLIOutputMailbox(deliver: deliver)
        lines = handles.map { _ in CLIOutputLines() }
        var descriptors: [Int32] = []
        do {
            for handle in handles {
                let fd = dup(handle.fileDescriptor)
                guard fd >= 0 else { throw POSIXError(.EMFILE) }
                descriptors.append(fd)
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0,
                      fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else { throw POSIXError(.EIO) }
            }
        } catch {
            descriptors.forEach { Darwin.close($0) }
            throw error
        }
        let outputQueue = queue
        sources = descriptors.map { DispatchSource.makeReadSource(fileDescriptor: $0, queue: outputQueue) }
        for (index, source) in sources.enumerated() {
            let fd = descriptors[index], group = cancelled
            group.enter()
            source.setEventHandler { [weak self] in self?.read(fd, stream: index) }
            source.setCancelHandler { Darwin.close(fd); group.leave() }
        }
        sources.forEach { $0.resume() }
    }

    deinit {
        mailbox.invalidate()
        sources.forEach { $0.cancel() }
    }

    private func read(_ fd: Int32, stream: Int) {
        // Limit each turn so stderr and cancellation cannot be starved by stdout.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var remaining = 65_536
        while remaining > 0, !sources[stream].isCancelled {
            let count = Darwin.read(fd, &bytes, min(bytes.count, remaining))
            if count > 0 {
                remaining -= count
                autoreleasepool {
                    lines[stream].consume(Data(bytes.prefix(count))) { consume($0) }
                }
            } else if count == 0 {
                autoreleasepool { lines[stream].finish { consume($0) } }
                sources[stream].cancel()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                consume("ERROR: CLI 输出读取失败。")
                sources[stream].cancel()
                return
            }
        }
    }

    private func consume(_ line: String) {
        let previous = output
        output.consume(line)
        log.write(line)
        if output != previous { mailbox.publish(output) }
    }

    func stopAndWait() async {
        mailbox.invalidate()
        sources.forEach { $0.cancel() }
        await withCheckedContinuation { continuation in
            cancelled.notify(queue: queue) { [weak self] in
                self?.lines.removeAll()
                self?.log.close()
                continuation.resume()
            }
        }
    }
}

/// One bounded partial line per stream; discard the whole oversized line,
/// including its suffix, so a truncated diagnostic cannot become a ready marker.
struct CLIOutputLines {
    static let maximumBytes = 65_536
    private let core = RustCore()
    private(set) var bufferedByteCount = 0
    private struct Decoded: Decodable { let lines: [String]; let bufferedBytes: Int }
    mutating func consume(_ data: Data, emit: (String) -> Void) {
        for offset in stride(from: 0, to: data.count, by: Self.maximumBytes) {
            decode(Array(data.dropFirst(offset).prefix(Self.maximumBytes)), finish: false, emit: emit)
        }
    }
    mutating func finish(emit: (String) -> Void) { decode([], finish: true, emit: emit) }
    private mutating func decode(_ bytes: [UInt8], finish: Bool, emit: (String) -> Void) {
        do {
            let result: Decoded = try core.call(["op":"lineChunk", "bytes":bytes, "finish":finish])
            bufferedByteCount = result.bufferedBytes
            result.lines.forEach(emit)
        } catch { emit("ERROR: CLI 输出读取失败。") }
    }
}

/// Only this mailbox is shared between the output queue and MainActor.
/// Scheduled work holds no snapshot or raw bytes and cannot retain the reader.
final class CLIOutputMailbox: @unchecked Sendable {
    typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var latest: ProxyBridgeCLIOutput?
    private var scheduled = false
    private var active = true
    private let schedule: Schedule
    private let deliver: @MainActor @Sendable (ProxyBridgeCLIOutput) -> Void

    init(schedule: @escaping Schedule = { action in Task { @MainActor in action() } },
         deliver: @escaping @MainActor @Sendable (ProxyBridgeCLIOutput) -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func publish(_ value: ProxyBridgeCLIOutput) {
        let needsDelivery = lock.withLock {
            guard active else { return false }
            latest = value
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if needsDelivery { schedule { [weak self] in self?.drain() } }
    }

    @MainActor private func drain() {
        let value = lock.withLock {
            let value = active ? latest : nil
            latest = nil
            scheduled = false
            return value
        }
        if let value { deliver(value) }
    }

    func invalidate() {
        lock.withLock { active = false; latest = nil }
    }
}

/// Confined to the reader queue. Keep one handle open and rotate before the
/// next line once the existing 5 MB threshold has been reached.
final class CLIOutputLog {
    private let url: URL
    private var handle: FileHandle?
    private var size: UInt64 = 0
    init(url: URL) { self.url = url }
    deinit { close() }

    func write(_ line: String) {
        do {
            try open()
            if size >= 5_000_000 {
                close()
                let backup = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: url, to: backup)
                try open()
            }
            let data = Data((line + "\n").utf8)
            try handle?.write(contentsOf: data)
            size += UInt64(data.count)
        } catch { close() } // Diagnostic logging must not affect routing.
    }

    private func open() throws {
        guard handle == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try FileHandle(forWritingTo: url)
        size = try handle!.seekToEnd()
    }

    func close() { try? handle?.close(); handle = nil }
}
