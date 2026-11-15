import Foundation
import XCTest
import ChatGPTProxyCore
@testable import DNSProtectionHelper

final class DomainResolverTests: XCTestCase, @unchecked Sendable {
    private let journal: [String: Any] = [
        "dnsTransaction": UUID().uuidString, "domains": ["chatgpt.com", "challenges.cloudflare.com"]
    ]

    func testSystemResolverRoutesToDistinctUpstreams() async throws {
        guard ProcessInfo.processInfo.environment["GPTPROXY_SYSTEM_DNS_QA"] == "1" else {
            throw XCTSkip("Set GPTPROXY_SYSTEM_DNS_QA=1 in a privileged macOS test session")
        }
        let suffix = UUID().uuidString.lowercased() + ".test"
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: state) }
        let domains = ["chatgpt.com.", "challenges.cloudflare.com."].map { $0 + suffix }
        let owned = try DomainResolvers(journal: ["dnsTransaction": UUID().uuidString, "domains": domains], state: state)
        defer { try? owned.restore() }
        try owned.checkFiles()
        try owned.install()
        var baseline: [URL] = []
        defer { for file in baseline { try? FileManager.default.removeItem(at: file) } }
        for host in ["www.cloudflare.com.", "example.org.", "cn.", "internal."] {
            let file = URL(fileURLWithPath: "/etc/resolver/" + host + suffix)
            try Data("nameserver 127.0.0.1\nport 17854\n".utf8).write(to: file, options: .withoutOverwriting)
            baseline.append(file)
        }
        for attempt in 0..<20 {
            let output = try await DNSSystemCommand.run("/usr/sbin/scutil", ["--dns"])
            if (try? owned.checkEffective(output, installed: true)) != nil,
               baseline.allSatisfy({ output.contains($0.lastPathComponent) }) { break }
            if attempt == 19 { XCTFail("System resolver did not load the test domains"); return }
            try await Task.sleep(for: .milliseconds(250))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try await DNSSystemCommand.run("/usr/bin/python3", [root.appendingPathComponent("scripts/qa-split-dns.py").path, "--mac-suffix", suffix])
    }

    func testPartialInstallAndRepeatedRestorePreserveForeignFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("resolver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let rules = try DomainResolvers(journal: journal, directory: directory, state: root)
        let foreign = directory.appendingPathComponent("challenges.cloudflare.com")
        let contents = Data("nameserver 192.0.2.1\n".utf8)
        try contents.write(to: foreign)
        XCTAssertThrowsError(try rules.checkFiles())
        XCTAssertThrowsError(try rules.install())
        try rules.restore()
        try rules.restore()
        XCTAssertEqual(try Data(contentsOf: foreign), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chatgpt.com").path))
        try FileManager.default.removeItem(at: foreign)
        try rules.install()
        try rules.verifyFiles()
        try contents.write(to: foreign)
        XCTAssertThrowsError(try rules.verifyFiles())
        try rules.restore()
        XCTAssertEqual(try Data(contentsOf: foreign), contents)
    }

    func testEffectiveResolversRespectDomainBoundariesAndDetectVPNOverrides() throws {
        let rules = try DomainResolvers(journal: journal)
        let original = "resolver #1\n nameserver[0] : 192.0.2.1\nresolver #2\n domain : chatgpt.com.example.org\n nameserver[0] : 192.0.2.2"
        let protected = "\nresolver #3\n domain : CHATGPT.COM.\n nameserver[0] : 127.0.0.1\n port : 17853\nresolver #4\n domain : challenges.cloudflare.com\n port : 17853\n nameserver[0] : 127.0.0.1"
        XCTAssertNoThrow(try rules.checkEffective(original, installed: false))
        XCTAssertNoThrow(try rules.checkEffective(original + protected, installed: true))
        XCTAssertThrowsError(try rules.checkEffective(original, installed: true))
        XCTAssertThrowsError(try rules.checkEffective(original + protected + "\nresolver #5\n domain : login.chatgpt.com\n nameserver[0] : ::1", installed: true))
        XCTAssertThrowsError(try rules.checkEffective(original + "\nresolver #6\n domain : cloudflare.com", installed: false))
    }
}
