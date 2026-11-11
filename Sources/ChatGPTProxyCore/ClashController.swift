import Foundation
import Darwin

public enum MonitorError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}

// Process owns its pipes and drains stdout before waiting. Cancellation also handles
// the race where the task is cancelled before Process.run().
private final class CurlProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func run(_ arguments: [String], timeout: Int, input: Data?) throws -> Data {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["--disable", "--silent", "--noproxy", "*", "--max-time", String(timeout)] + arguments
        let output = Pipe()
        let stdin = Pipe()
        child.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        if let input {
            // Configuration payloads contain credentials; never put them in argv.
            do { try stdin.fileHandleForWriting.write(contentsOf: input) }
            catch { child.terminate() }
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            throw MonitorError.message("请求失败或超时（curl \(child.terminationStatus)）")
        }
        return data
    }
}

public enum MonitorHTTP {
    public static let testURL = CodexConnectionSession.targetURL

    public static func run(_ arguments: [String], timeout: Int = 2, input: Data? = nil) async throws -> Data {
        let runner = CurlProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try runner.run(arguments, timeout: timeout, input: input) }.value
        } onCancel: { runner.cancel() }
    }
}

public struct ClashProxy: Codable, Sendable {
    public let name: String
    public let type: String
    public let now: String?
    public let all: [String]?
}

public struct ClashSnapshot: Sendable {
    public let socket: String
    public let mode: String
    public let proxies: [String: ClashProxy]

    private struct Resolution: Decodable { let current: String?; let selection: [String:String] }
    private var resolution: Resolution {
        let values = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(proxies))
        return try! RustCore().call(["op":"clashSnapshot", "proxies":values])
    }
    public var current: String? { resolution.current }
    public var selectionSignature: [String:String] { resolution.selection }

}

public struct ClashControllerClient: Sendable {
    public init() {}
    public func request(socket: String, path: String, method: String = "GET", body: Data? = nil, timeout: Int = 2) async throws -> Data {
        var args = ["--unix-socket", socket, "--request", method, "--write-out", "\n%{http_code}", "http://localhost" + path]
        if body != nil { args += ["--header", "Content-Type: application/json", "--data-binary", "@-"] }
        let response = try await MonitorHTTP.run(args, timeout: timeout, input: body)
        guard let split = response.lastIndex(of: 10),
              let status = Int(String(decoding: response[response.index(after: split)...], as: UTF8.self)),
              (200..<300).contains(status) else { throw MonitorError.message("Clash 控制接口请求失败") }
        return Data(response[..<split])
    }

    public func snapshot(port: UInt16) async throws -> ClashSnapshot {
        let paths = try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .filter { $0.hasPrefix("mihomo-party-\(getuid())-") && $0.hasSuffix(".sock") }.sorted()
        var matches: [ClashSnapshot] = []
        for path in paths {
            try Task.checkCancellation()
            let socket = "/tmp/" + path
            do {
                let version = try await request(socket: socket, path: "/version")
                guard (try JSONSerialization.jsonObject(with: version) as? [String: Any])?["meta"] as? Bool == true else { continue }
                let data = try await request(socket: socket, path: "/configs")
                guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ["mixed-port", "socks-port"].contains(where: { config[$0] as? Int == Int(port) }) else { continue }
                struct Response: Decodable { let proxies: [String: ClashProxy] }
                let proxies = try JSONDecoder().decode(Response.self, from: await request(socket: socket, path: "/proxies"))
                matches.append(.init(socket: socket, mode: config["mode"] as? String ?? "", proxies: proxies.proxies))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        guard matches.count == 1, let match = matches.first else {
            throw MonitorError.message(matches.isEmpty ? "等待 Clash Party 控制接口" : "多个 Clash 控制接口匹配，已暂停切换")
        }
        return match
    }

    public func snapshot(socket: String, port: UInt16) async throws -> ClashSnapshot {
        let general = try await request(socket: socket, path: "/configs")
        guard let config = try JSONSerialization.jsonObject(with: general) as? [String: Any],
              ["mixed-port", "socks-port"].contains(where: { config[$0] as? Int == Int(port) }) else {
            throw MonitorError.message("Clash 代理端口已更改")
        }
        struct Response: Decodable { let proxies: [String: ClashProxy] }
        let proxies = try JSONDecoder().decode(Response.self, from: await request(socket: socket, path: "/proxies"))
        return .init(socket: socket, mode: config["mode"] as? String ?? "", proxies: proxies.proxies)
    }

    private func command(socket: String, _ name: String, _ arguments: [String:String] = [:]) async throws -> Data {
        struct Request: Decodable { let method: String; let path: String; let body: [String:String]?; let timeout: Int }
        var request: [String:Any] = arguments; request["op"] = "clashRequest"; request["command"] = name
        let description: Request = try RustCore().call(request)
        return try await self.request(socket:socket,path:description.path,method:description.method,
                                      body:try description.body.map { try JSONEncoder().encode($0) },timeout:description.timeout)
    }
    public func delay(socket: String, name: String) async throws -> Int {
        struct Result: Decodable { let delay: Int }
        return try JSONDecoder().decode(Result.self,from:await command(socket:socket,"delay",["name":name])).delay
    }
    public func select(socket: String, name: String) async throws { _ = try await command(socket:socket,"select",["name":name]) }
    private func connectionIDs(socket: String, node: String? = nil, dns: Bool = false) async throws -> [String] {
        let object = try JSONSerialization.jsonObject(with:await command(socket:socket,"connections")) as? [String:Any]
        return try RustCore().call(["op":"clashConnectionIds", "connections":object?["connections"] ?? [], "node":node as Any? ?? NSNull(), "dns":dns])
    }
    public func oldConnections(socket: String, node: String) async throws -> [String] { try await connectionIDs(socket:socket,node:node) }
    public func close(socket: String, id: String) async throws { _ = try await command(socket:socket,"close",["id":id]) }
    public func reload(socket: String, yaml: String) async throws { _ = try await command(socket:socket,"reload",["yaml":yaml]) }
    public func selection(socket: String) async throws -> [String:String] {
        let object = try JSONSerialization.jsonObject(with:await command(socket:socket,"proxies")) as? [String:Any]
        return try RustCore().call(["op":"clashSelections", "proxies":object?["proxies"] ?? [:]])
    }
    public func restoreSelection(socket: String, selection: [String:String]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while true {
            let object = try JSONSerialization.jsonObject(with: await command(socket:socket,"proxies")) as? [String:Any]
            let ready: Bool = try RustCore().call(["op":"clashSelectionsReady", "selection":selection, "proxies":object?["proxies"] ?? [:]])
            if ready { break }
            guard ContinuousClock.now < deadline else { throw MonitorError.message("Clash 订阅节点尚未加载，无法恢复原节点选择") }
            try await Task.sleep(for: .milliseconds(200))
        }
        for (group,name) in selection.sorted(by: {$0.key < $1.key}) { _ = try await command(socket:socket,"select",["group":group,"name":name]) }
    }
    public func flushDNS(socket: String) async throws { _ = try await command(socket:socket,"flushDNS") }
    public func closeAllConnections(socket: String) async throws { _ = try await command(socket:socket,"closeAll") }
    public func closeDNSConnections(socket: String) async throws {
        for id in try await connectionIDs(socket:socket,dns:true) { try await close(socket:socket,id:id) }
    }

}

public struct NodeOriginResolver: Sendable {
    public let origins: [String: String]
    public let activeProfileId: String?
    public let signature: Data

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/mihomo-party")) throws {
        struct Result: Decodable { let activeProfileId: String?; let origins: [String:String]; let signature: [UInt8] }
        let result: Result = try RustCore().call(["op":"nodeOrigins", "directory":directory.path])
        activeProfileId = result.activeProfileId
        origins = result.origins
        signature = Data(result.signature)
    }

    init(origins: [String: String], activeProfileId: String? = nil) {
        self.activeProfileId = activeProfileId
        self.origins = origins
        self.signature = Data()
    }

    public static func region(_ name: String) -> String? {
        try! RustCore().nullable(["op": "region", "name": name])
    }
}

public enum AutoSwitchPolicy {
    public static let threshold = 800
    public static func winner(_ delays: [String: Int], current: String) -> String? {
        try! RustCore().nullable(["op": "winner", "delays": delays, "current": current])
    }
}
