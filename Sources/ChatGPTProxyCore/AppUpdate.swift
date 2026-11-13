import Foundation
import CryptoKit

public struct AppUpdateRelease: Codable, Sendable {
    public let version: String
    public let url: String
    public let digest: String?
    public let checksums: String?
    public let size: Int64
    public let name: String
}
public enum AppUpdate {
    public static let endpoint = "https://api.github.com/repos/lzl51230/gptProxy/releases/latest"
    public static var cache: URL {
#if DEBUG
        if let root = ProcessInfo.processInfo.environment["GPTPROXY_UPDATE_QA"] {
            return URL(fileURLWithPath: root).appendingPathComponent("Updates")
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ChatGPT Proxy/Updates")
    }
    public static func run(_ executable: String, _ args: [String], observe: (@Sendable () -> Void)? = nil) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        p.standardOutput = handle; p.standardError = FileHandle.nullDevice
        try p.run()
        var observation = Date.distantPast
        while p.isRunning {
            if Date().timeIntervalSince(observation) >= 1 { observe?(); observation = Date() }
            if Task.isCancelled { p.terminate(); p.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit(); let data = try Data(contentsOf: output)
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "更新命令失败：\(executable)"]) }
        return String(decoding: data, as: UTF8.self)
    }
    public static func download(_ address: String, to file: URL, port: Int, maximumSize: Int = 536870912, progress: (@Sendable (Int64) -> Void)? = nil) throws {
        guard (1...65535).contains(port), URL(string: address)?.scheme == "https" else { throw CocoaError(.fileReadUnsupportedScheme) }
        try Task.checkCancellation()
#if DEBUG
        if let root = ProcessInfo.processInfo.environment["GPTPROXY_UPDATE_QA"] {
            let source: String
            if address == endpoint { source = "release.json" }
            else if address == "https://github.com/lzl51230/gptProxy/releases/download/v2.4.0/ChatGPT-Proxy-2.4.0-Universal.zip" { source = "new.zip" }
            else { throw CocoaError(.fileReadUnsupportedScheme) }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: root).appendingPathComponent(source), to: file)
            return
        }
#endif
        _ = try run("/usr/bin/curl", ["--disable","--fail","--location","--max-redirs","5","--silent","--show-error","--connect-timeout","15","--max-time","600","--speed-limit","1","--speed-time","60","--proto","=https","--proto-redir","=https","--noproxy","","--proxy","socks5h://127.0.0.1:\(port)","--user-agent","ChatGPTProxy-Updater","--max-filesize",String(maximumSize),"--output",file.path,address], observe: {
            if let size = (try? FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? NSNumber { progress?(size.int64Value) }
        })
        try Task.checkCancellation()
    }
    public static func check(current: String, port: Int) throws -> AppUpdateRelease? {
        let dir = cache.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("release.json"); try download(endpoint, to: file, port: port, maximumSize: 4*1024*1024)
        let data = try Data(contentsOf: file); guard data.count < 4*1024*1024 else { throw CocoaError(.fileReadTooLarge) }
        return try RustCore().nullable(["op":"updateRelease","current":current,"platform":"macos","release":JSONSerialization.jsonObject(with: data)], as: AppUpdateRelease.self)
    }
    public static func stage(_ release: AppUpdateRelease, port: Int, progress: (@Sendable (Int64) -> Void)? = nil) throws -> URL {
        let work = cache.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let zip = work.appendingPathComponent("download.zip")
            var digest = release.digest
            if digest == nil, let url = release.checksums {
                let sums = work.appendingPathComponent("checksums"); try download(url, to: sums, port: port, maximumSize: 4*1024*1024)
                let line = try String(contentsOf: sums, encoding: .utf8).split(separator: "\n").first { $0.split(whereSeparator: \.isWhitespace).last == Substring(release.name) }
                digest = line?.split(whereSeparator: \.isWhitespace).first.map { "sha256:" + $0 }
            }
            guard let digest, digest.range(of: "^sha256:[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
            try download(release.url, to: zip, port: port, progress: progress)
            let handle = try FileHandle(forReadingFrom: zip); defer { try? handle.close() }
            var hash = SHA256(); var size: Int64 = 0
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk); size += Int64(chunk.count); try Task.checkCancellation() }
            guard size == release.size, "sha256:" + hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest.lowercased() else { throw CocoaError(.fileReadCorruptFile) }
            let names = try run("/usr/bin/unzip", ["-Z1",zip.path]).split(separator: "\n")
            guard !names.isEmpty, names.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") }) else { throw CocoaError(.fileReadCorruptFile) }
            let listing = try run("/usr/bin/unzip", ["-Z","-l",zip.path])
            guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try run("/usr/bin/ditto", ["-x","-k",zip.path,work.path])
            let app = work.appendingPathComponent("ChatGPT Proxy.app")
            try validate(app, version: release.version)
            return app
        } catch { try? FileManager.default.removeItem(at: work); throw error }
    }
    public static func validate(_ app: URL, version: String) throws {
        let manifestData = try Data(contentsOf: app.appendingPathComponent("Contents/Resources/update-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String:Any],
              manifest["format"] as? Int == 1, manifest["version"] as? String == version,
              manifest["platform"] as? String == "macos-universal",
              let files = manifest["files"] as? [String], !files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for path in files {
            guard !path.hasPrefix("/"), !path.split(separator:"/").contains(".."),
                  FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let info = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String:Any]
        guard plist?["CFBundleIdentifier"] as? String == "local.alex.chatgpt-proxy", plist?["CFBundleShortVersionString"] as? String == version else { throw CocoaError(.fileReadCorruptFile) }
        _ = try run("/usr/bin/codesign", ["--verify","--deep","--strict",app.path])
        let arch = try run("/usr/bin/lipo", ["-archs",app.appendingPathComponent("Contents/MacOS/ChatGPTProxyLauncher").path])
        guard arch.contains("arm64"), arch.contains("x86_64"), FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/AppUpdater").path) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
