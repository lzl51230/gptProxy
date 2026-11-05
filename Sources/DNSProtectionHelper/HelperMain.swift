import Foundation
import Darwin
import ChatGPTProxyCore

@main
enum HelperMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--version"] { print(DNSProtectionConfiguration.version); return }
        guard geteuid() == 0 else { fputs("DNS helper requires administrator privileges.\n", stderr); exit(1) }
        do {
            if args == ["--restore"] || args == ["--uninstall"] {
                // The daemon owns the live transaction; never race a second engine against it.
                if FileManager.default.fileExists(atPath: DNSProtectionConfiguration.socketPath) {
                    let result = try await DNSProtectionIPC.request(.init(command: .restore))
                    guard result.phase == .disabled else { throw MonitorError.message(result.detail) }
                } else {
                    let lock = try acquireLock()
                    defer { close(lock) }
                    let engine = try ProtectionEngine(ownerUID: 0)
                    try await engine.recoverAtStartup()
                }
                if args == ["--uninstall"] {
                    _ = try? await DNSSystemCommand.run("/bin/launchctl", ["bootout", "system/\(DNSProtectionConfiguration.label)"])
                    for path in ["/Library/LaunchDaemons/\(DNSProtectionConfiguration.label).plist", DNSProtectionConfiguration.helperPath] {
                        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                    }
                }
                print("Original DNS configuration restored.")
                return
            }
            guard args.count == 3, args[0] == "--daemon", args[1] == "--owner-uid",
                  let uid = uid_t(args[2]), uid > 0 else { throw MonitorError.message("Invalid helper arguments") }
            let lock = try acquireLock()
            defer { close(lock) }
            let engine = try ProtectionEngine(ownerUID: uid)
            // A failed Clash recovery leaves a readable status and is retried by the watchdog.
            try? await engine.recoverAtStartup()
            for number in [SIGTERM, SIGINT] { signal(number, SIG_IGN) }
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in
                    Task {
                        do { try await engine.stop(); exit(0) }
                        catch { exit(1) }
                    }
                }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }
            let watchdog = HelperEvents.watchdog { await engine.tick() }
            defer { watchdog.cancel() }
            try await serve(engine: engine, ownerUID: uid)
        } catch {
            fputs("DNS helper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func acquireLock() throws -> Int32 {
        let fd = open("/var/run/\(DNSProtectionConfiguration.label).lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MonitorError.message("无法创建 DNS 事务锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw MonitorError.message("DNS 辅助服务已在运行") }
        return fd
    }

    private static func serve(engine: ProtectionEngine, ownerUID: uid_t) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MonitorError.message("无法创建 DNS 控制接口") }
        defer { close(fd); unlink(DNSProtectionConfiguration.socketPath) }
        unlink(DNSProtectionConfiguration.socketPath)
        var address = try DNSProtectionIPC.address(DNSProtectionConfiguration.socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0,
              chown(DNSProtectionConfiguration.socketPath, ownerUID, 0) == 0,
              chmod(DNSProtectionConfiguration.socketPath, 0o600) == 0,
              listen(fd, 8) == 0 else { throw MonitorError.message("无法启用 DNS 控制接口") }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let peer = accept(fd, nil, nil)
                    if peer < 0 { break }
                    DNSProtectionIPC.configure(peer, seconds: 5)
                    var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    guard getpeereid(peer, &uid, &gid) == 0, uid == ownerUID || uid == 0,
                          getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
                        close(peer); continue
                    }
                    do {
                        let request = try DNSProtectionIPC.receive(DNSProtectionRequest.self, descriptor: peer)
                        let done = DispatchSemaphore(value: 0)
                        Task {
                            let result = await engine.handle(request, peerPID: pid)
                            try? DNSProtectionIPC.send(result, descriptor: peer)
                            close(peer)
                            done.signal()
                        }
                        done.wait()
                    } catch { close(peer) }
                }
                continuation.resume()
            }
        }
    }
}
