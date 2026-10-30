import Foundation
import Darwin
import Yams
import CryptoKit

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

    func run(_ arguments: [String]) throws -> Data {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["--disable", "--silent", "--noproxy", "*", "--max-time", "2"] + arguments
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
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
    public static let testURL = "https://www.google.com/"

    public static func run(_ arguments: [String]) async throws -> Data {
        let runner = CurlProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try runner.run(arguments) }.value
        } onCancel: { runner.cancel() }
    }

    public static func probe(port: UInt16) async throws -> Int {
        let data = try await run([
            "--noproxy", "", "--proxy", "socks5h://127.0.0.1:\(port)",
            "--head", "--output", "/dev/null", "--max-time", "0.8",
            "--header", "Cache-Control: no-cache", "--header", "Connection: close",
            "--write-out", "%{http_code} %{time_total}", testURL,
        ])
        let parts = String(decoding: data, as: UTF8.self).split(separator: " ")
        guard parts.count == 2, parts[0] == "200", let seconds = Double(parts[1]) else {
            throw MonitorError.message("Google HEAD 未返回 HTTP 200")
        }
        // Round upward so a request above the limit is never rounded into health.
        return Int(ceil(seconds * 1000))
    }
}

public struct ClashProxy: Decodable, Sendable {
    public let name: String
    public let type: String
    public let now: String?
    public let all: [String]?
}

public struct ClashSnapshot: Sendable {
    public let socket: String
    public let mode: String
    public let proxies: [String: ClashProxy]

    public var current: String? {
        var name = "GLOBAL"
        var visited = Set<String>()
        while visited.insert(name).inserted, let proxy = proxies[name] {
            if proxy.all == nil { return name }
            guard let next = proxy.now else { return nil }
            name = next
        }
        return nil
    }

    public var selectionSignature: [String: String] {
        var result: [String: String] = [:]
        var name = "GLOBAL"
        while result[name] == nil, let next = proxies[name]?.now {
            result[name] = next; name = next
        }
        return result
    }
}

public struct ClashControllerClient: Sendable {
    public init() {}
    public func request(socket: String, path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var args = ["--unix-socket", socket, "--request", method, "--write-out", "\n%{http_code}", "http://localhost" + path]
        if let body { args += ["--header", "Content-Type: application/json", "--data-binary", String(decoding: body, as: UTF8.self)] }
        let response = try await MonitorHTTP.run(args)
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

    private func encoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    public func delay(socket: String, name: String) async throws -> Int {
        let url = MonitorHTTP.testURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let data = try await request(socket: socket, path: "/proxies/\(encoded(name))/delay?url=\(url)&timeout=800&expected=200")
        struct Result: Decodable { let delay: Int }
        return try JSONDecoder().decode(Result.self, from: data).delay
    }

    public func select(socket: String, name: String) async throws {
        _ = try await request(socket: socket, path: "/proxies/GLOBAL", method: "PUT", body: JSONEncoder().encode(["name": name]))
    }

    public func oldConnections(socket: String, node: String) async throws -> [String] {
        struct Connection: Decodable { let id: String; let chains: [String] }
        struct Response: Decodable { let connections: [Connection]? }
        let data = try await request(socket: socket, path: "/connections")
        return try JSONDecoder().decode(Response.self, from: data).connections.orEmpty
            .filter { $0.chains.contains("GLOBAL") && $0.chains.contains(node) }.map(\.id)
    }

    public func close(socket: String, id: String) async throws {
        _ = try await request(socket: socket, path: "/connections/" + encoded(id), method: "DELETE")
    }
}

private extension Optional where Wrapped: RangeReplaceableCollection {
    var orEmpty: Wrapped { self ?? Wrapped() }
}

public struct NodeOriginResolver: Sendable {
    public let origins: [String: String]
    public let signature: Data

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/mihomo-party")) throws {
        var configuration = Data()
        func load(_ url: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: url)
            configuration.append(data)
            var yaml = String(decoding: data, as: UTF8.self)
            // Foundation file reads strip a UTF-8 BOM; String(decoding:) preserves it.
            // Normalize it before Yams, which can misparse BOM-prefixed documents.
            if yaml.first == "\u{FEFF}" { yaml.removeFirst() }
            do { return try Yams.load(yaml: yaml) as? [String: Any] ?? [:] }
            catch let error as YamlError {
                let reason: String
                switch error {
                case let .reader(problem, _, _, _): reason = problem
                case let .scanner(_, problem, mark, _), let .parser(_, problem, mark, _), let .composer(_, problem, mark, _): reason = "\(problem) at \(mark.line):\(mark.column)"
                default: reason = "YAML 结构不受支持"
                }
                throw MonitorError.message("配置解析失败（\(url.lastPathComponent)）：\(reason)")
            }
        }
        func identity(_ node: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: node.filter { $0.key != "name" }, options: [.sortedKeys])
        }
        let profiles = try load(directory.appendingPathComponent("profile.yaml"))["items"] as? [[String: Any]] ?? []
        var byName: [String: Set<String>] = [:]
        var byIdentity: [Data: Set<String>] = [:]
        for profile in profiles {
            guard let id = profile["id"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { continue }
            let nodes = try load(directory.appendingPathComponent("profiles/\(id).yaml"))["proxies"] as? [[String: Any]] ?? []
            for node in nodes {
                if let name = node["name"] as? String { byName[name, default: []].insert(id) }
                byIdentity[try identity(node), default: []].insert(id)
            }
        }
        var result: [String: String] = [:]
        for (name, ids) in byName where ids.count == 1 { result[name] = ids.first! }
        let runtime = try load(directory.appendingPathComponent("work/config.yaml"))["proxies"] as? [[String: Any]] ?? []
        for node in runtime {
            guard let name = node["name"] as? String else { continue }
            let ids = byIdentity[try identity(node)] ?? []
            // Runtime identity takes precedence over a potentially misleading name.
            result[name] = ids.count == 1 ? ids.first : nil
        }
        origins = result
        signature = Data(SHA256.hash(data: configuration))
    }

    init(origins: [String: String]) {
        self.origins = origins
        self.signature = Data()
    }

    public static func region(_ name: String) -> String? {
        let aliases: [(String, [String])] = [
            ("TW", ["台湾", "台灣", "taiwan"]), ("HK", ["香港", "hong kong", "hongkong"]),
            ("MO", ["澳门", "澳門", "macau", "macao"]), ("JP", ["日本", "japan"]),
            ("SG", ["新加坡", "singapore"]), ("US", ["美国", "美國", "united states", "usa"]),
            ("GB", ["英国", "英國", "united kingdom", "britain"]), ("KR", ["韩国", "韓國", "korea"]),
            ("DE", ["德国", "德國", "germany"]), ("FR", ["法国", "法國", "france"]),
            ("CA", ["加拿大", "canada"]), ("AU", ["澳大利亚", "澳洲", "australia"]),
            ("CN", ["中国", "中國", "china"]), ("IN", ["印度", "india"]),
            ("NL", ["荷兰", "荷蘭", "netherlands"]), ("RU", ["俄罗斯", "俄羅斯", "russia"]),
        ]
        let lower = name.lowercased()
        let matches = aliases.filter { $0.1.contains(where: { lower.contains($0) }) }.map(\.0)
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }
        var flags = Set<String>()
        for char in name {
            let scalars = Array(char.unicodeScalars)
            if scalars.count == 2 && scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
                flags.insert(String(String.UnicodeScalarView(scalars.map { UnicodeScalar($0.value - 0x1F1E6 + 65)! })))
            }
        }
        return flags.count == 1 ? flags.first : nil
    }
}

public enum AutoSwitchPolicy {
    public static let threshold = 800
    public static func winner(_ delays: [String: Int], current: String) -> String? {
        delays.filter { (1...threshold).contains($0.value) }.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            if $0.key == current { return true }
            if $1.key == current { return false }
            return $0.key < $1.key
        }.first?.key
    }
}
