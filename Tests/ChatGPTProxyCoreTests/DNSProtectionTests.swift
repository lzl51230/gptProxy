import XCTest
import Yams
import Darwin
@testable import ChatGPTProxyCore

final class DNSProtectionTests: XCTestCase {
    private let fixture = """
    mode: global
    mixed-port: 7890
    tun: {enable: false}
    proxies: [{name: node, type: ss, server: proxy.example, port: 443, cipher: aes-128-gcm, password: fixture}]
    proxy-groups: [{name: GROUP, type: select, proxies: [node]}]
    rules: [MATCH,GROUP]
    dns:
      enable: true
      default-nameserver: [tls://223.5.5.5]
      proxy-server-nameserver: [https://dns.alidns.com/dns-query]
      enhanced-mode: fake-ip
      nameserver: [223.5.5.5]
      nameserver-policy: {"+.example.com": 114.114.114.114}
      proxy-server-nameserver-policy: {proxy.example: 114.114.114.114}
      direct-nameserver: [system]
      fallback: [8.8.8.8]
    """

    func testConfigurationSizeBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        // Sparse files exercise the byte boundary without committing a large fixture.
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for size in [10 * 1024 * 1024, 32 * 1024 * 1024] {
            try handle.truncate(atOffset: UInt64(size))
            XCTAssertNoThrow(try DNSProtectionConfiguration.sourceGeneration(at: file))
            XCTAssertEqual(try DNSProtectionConfiguration.readSource(at: file).utf8.count, size)
        }
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: file, ownerUID: getuid() + 1))
        try handle.truncate(atOffset: UInt64(32 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: file))
        XCTAssertThrowsError(try DNSProtectionConfiguration.sourceGeneration(at: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
        }
    }

    func testLargeConfigurationConversionAndRecoveryReload() throws {
        let payload = String(repeating: "中文 \"quoted\" \\ path\n", count: 240_000)
        let source = fixture + "\nx-payload: " + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self) + "\n"
        XCTAssertGreaterThan(source.utf8.count, 4 * 1024 * 1024)
        let general = Data(#"{"ipv6":true}"#.utf8)
        let runtime = try DNSProtectionConfiguration.runtimeYAML(source, general: general)
        _ = try DNSProtectionConfiguration.inspectBootstrap(runtime, saved: source)
        let protected = try DNSProtectionConfiguration.protectedYAML(runtime)
        let parsed = try XCTUnwrap(Yams.load(yaml: protected) as? [String: Any])
        XCTAssertEqual(parsed["x-payload"] as? String, payload)
        let journal: [String: Any] = ["version": 1, "source": source, "originalYAML": runtime]
        let bytes = try JSONSerialization.data(withJSONObject: journal)
        XCTAssertGreaterThan(bytes.count, 8 * 1024 * 1024)
        XCTAssertLessThan(bytes.count, DNSProtectionConfiguration.maximumRecoverySize)
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        let result = try RustCore().object(["op": "protection", "action": "load", "journal": decoded])
        XCTAssertEqual((result as? [String: Any])?["phase"] as? String, "restoring")
        let restored = try DNSProtectionConfiguration.restoredYAML(runtime, general: general,
            originalIPv6: true, ipv4PolicyApplied: true, sourceChanged: false)
        XCTAssertEqual((try Yams.load(yaml: restored) as? [String: Any])?["x-payload"] as? String, payload)
    }

    func testSourceRejectsDirectoryMissingFileAndInvalidUTF8() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: directory))
        let file = directory.appendingPathComponent("config.yaml")
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: file))
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: file))
    }

    func testEveryOrdinaryResolutionPathUsesGlobalDoHWithoutChangingNodesOrRules() throws {
        let original = try XCTUnwrap(Yams.load(yaml: fixture) as? [String: Any])
        let result = try XCTUnwrap(Yams.load(yaml: DNSProtectionConfiguration.protectedYAML(fixture)) as? [String: Any])
        let dns = try XCTUnwrap(result["dns"] as? [String: Any])
        XCTAssertEqual(dns["nameserver"] as? [String], DNSProtectionConfiguration.nameServers)
        XCTAssertEqual(dns["direct-nameserver"] as? [String], DNSProtectionConfiguration.nameServers)
        XCTAssertEqual(dns["enhanced-mode"] as? String, "redir-host")
        XCTAssertEqual(dns["listen"] as? String, "127.0.0.1:17853")
        XCTAssertEqual((dns["fallback"] as? [String])?.count, 0)
        XCTAssertEqual((dns["nameserver-policy"] as? [String: Any])?.count, 0)
        XCTAssertEqual((dns["proxy-server-nameserver-policy"] as? [String: Any])?.count, 0)
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["https://dns.alidns.com/dns-query"])
        XCTAssertEqual(result["ipv6"] as? Bool, false)
        XCTAssertEqual(dns["ipv6"] as? Bool, false)
        var node = try XCTUnwrap((result["proxies"] as? [[String: Any]])?.first)
        XCTAssertEqual(node.removeValue(forKey: "ip-version") as? String, "ipv4")
        XCTAssertEqual(NSDictionary(dictionary: node), NSDictionary(dictionary: (original["proxies"] as! [[String: Any]])[0]))
        for key in ["proxy-groups", "rules", "tun"] {
            XCTAssertEqual(NSDictionary(dictionary: [key: result[key]!]), NSDictionary(dictionary: [key: original[key]!]))
        }
    }

    func testRejectsPlaintextOrCircularBootstrapAndUnsupportedModes() {
        for source in [
            fixture.replacingOccurrences(of: "tls://223.5.5.5", with: "223.5.5.5"),
            fixture.replacingOccurrences(of: "tls://223.5.5.5", with: "tls://bootstrap.example"),
            fixture.replacingOccurrences(of: "tls://223.5.5.5", with: "tls://[2606:4700:4700::1111]"),
            fixture.replacingOccurrences(of: "https://dns.alidns.com/dns-query", with: "https://[2606:4700:4700::1111]/dns-query"),
            fixture.replacingOccurrences(of: "https://dns.alidns.com/dns-query", with: "system"),
            fixture.replacingOccurrences(of: "https://dns.alidns.com/dns-query", with: "https://1.1.1.1/dns-query#GLOBAL"),
            fixture.replacingOccurrences(of: "mode: global", with: "mode: rule"),
            fixture.replacingOccurrences(of: "tun: {enable: false}", with: "tun: {enable: true}"),
        ] { XCTAssertThrowsError(try DNSProtectionConfiguration.protectedYAML(source)) }
    }

    func testRuntimeReloadPreservesLiveSettingsAndRestoresOriginalDNS() throws {
        let live = try JSONSerialization.data(withJSONObject: ["mode": "rule", "mixed-port": 8890, "ipv6": true])
        let restored = try XCTUnwrap(Yams.load(yaml: DNSProtectionConfiguration.runtimeYAML(fixture, general: live)) as? [String: Any])
        XCTAssertEqual(restored["mode"] as? String, "rule")
        XCTAssertEqual(restored["mixed-port"] as? Int, 8890)
        XCTAssertEqual(restored["ipv6"] as? Bool, true)
        XCTAssertEqual((restored["dns"] as? [String: Any])?["nameserver"] as? [String], ["223.5.5.5"])
    }

    func testIPv4PolicyOverridesAllNodesAndProvidersWithoutDroppingOtherOptions() throws {
        let source = fixture + """

        ipv6: true
        proxy-providers:
          existing:
            type: inline
            payload: []
            override: {ip-version: ipv6, udp: true, tfo: true}
          fresh: {type: inline, payload: []}
        """
        let result = try XCTUnwrap(Yams.load(yaml: DNSProtectionConfiguration.protectedYAML(source)) as? [String: Any])
        let providers = try XCTUnwrap(result["proxy-providers"] as? [String: [String: Any]])
        for provider in providers.values { XCTAssertEqual((provider["override"] as? [String: Any])?["ip-version"] as? String, "ipv4") }
        let override = providers["existing"]?["override"] as? [String: Any]
        XCTAssertEqual(override?["udp"] as? Bool, true)
        XCTAssertEqual(override?["tfo"] as? Bool, true)
        XCTAssertEqual(result["ipv6"] as? Bool, false)
    }

    func testRecoveryRestoresOwnedIPv6AndPreservesLaterUserChanges() throws {
        for (original, current, expected) in [(true, false, true), (false, false, false), (false, true, true)] {
            let general = try JSONSerialization.data(withJSONObject: ["ipv6": current, "mode": "rule"])
            let yaml = try DNSProtectionConfiguration.restoredYAML(fixture, general: general, originalIPv6: original,
                ipv4PolicyApplied: true, sourceChanged: false)
            let result = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
            XCTAssertEqual(result["ipv6"] as? Bool, expected)
            XCTAssertEqual(result["mode"] as? String, "rule")
            XCTAssertNil((result["proxies"] as? [[String: Any]])?.first?["ip-version"])
        }
    }

    func testRecoveryUsesNewSourceIPv6PolicyIncludingOmittedDefault() throws {
        let general = Data(#"{"ipv6":false,"mixed-port":8890}"#.utf8)
        for suffix in ["\nipv6: true\n", "\nipv6: false\n", ""] {
            let source = fixture + suffix
            let yaml = try DNSProtectionConfiguration.restoredYAML(source, general: general, originalIPv6: true,
                ipv4PolicyApplied: true, sourceChanged: true)
            let result = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
            let original = try XCTUnwrap(Yams.load(yaml: source) as? [String: Any])
            XCTAssertEqual(result["ipv6"] as? Bool, original["ipv6"] as? Bool)
            XCTAssertEqual(result["mixed-port"] as? Int, 8890)
        }
    }

    func testLegacyRecoveryDoesNotApplyAnIPv4BaselineItNeverOwned() throws {
        let yaml = try DNSProtectionConfiguration.restoredYAML(fixture, general: Data(#"{"ipv6":true}"#.utf8),
            originalIPv6: nil, ipv4PolicyApplied: false, sourceChanged: false)
        XCTAssertEqual((try Yams.load(yaml: yaml) as? [String: Any])?["ipv6"] as? Bool, true)
    }

    func testIPv4ProbeRejectsAAAAAnswersAndFailedOrEmptyAResolution() throws {
        let aQuery = DNSPacket.query(name: "one.one.one.one", id: 1)
        let aaaaQuery = DNSPacket.query(name: "one.one.one.one", type: 28, id: 2)
        var a = aQuery, aaaa = aaaaQuery
        a[2] = 0x81; a[3] = 0x80; a[7] = 1
        a.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 1, 1, 1])
        aaaa[2] = 0x81; aaaa[3] = 0x80
        XCTAssertNoThrow(try DNSPacket.assertIPv4Responses(a: a, aQuery: aQuery, aaaa: aaaa, aaaaQuery: aaaaQuery))
        var bad = aaaa; bad[7] = 1
        XCTAssertThrowsError(try DNSPacket.assertIPv4Responses(a: a, aQuery: aQuery, aaaa: bad, aaaaQuery: aaaaQuery))
        bad = aaaa; bad[3] = 0x83
        XCTAssertThrowsError(try DNSPacket.assertIPv4Responses(a: a, aQuery: aQuery, aaaa: bad, aaaaQuery: aaaaQuery))
        a[7] = 0
        XCTAssertThrowsError(try DNSPacket.assertIPv4Responses(a: a, aQuery: aQuery, aaaa: aaaa, aaaaQuery: aaaaQuery))
    }

    func testRestoresDHCPWithoutWritingOldDHCPAddressesAsStaticServers() {
        let restored = SystemDNSSettings.restoration(current: ["ServerAddresses": SystemDNSSettings.loopback], original: nil)
        XCTAssertTrue(restored.apply)
        XCTAssertNil(restored.configuration)
    }

    func testRestoresManualIPv4AndIPv6ServersAndKeepsNewSearchDomains() {
        let restored = SystemDNSSettings.restoration(
            current: ["ServerAddresses": SystemDNSSettings.loopback, "SearchDomains": ["new.example"]],
            original: ["ServerAddresses": ["10.0.0.1", "2001:db8::1"], "SearchDomains": ["old.example"]])
        XCTAssertTrue(restored.apply)
        XCTAssertEqual(restored.configuration?["ServerAddresses"] as? [String], ["10.0.0.1", "2001:db8::1"])
        XCTAssertEqual(restored.configuration?["SearchDomains"] as? [String], ["new.example"])
    }

    func testDoesNotOverwriteDNSChangedByAnotherApplication() {
        XCTAssertFalse(SystemDNSSettings.restoration(current: ["ServerAddresses": ["9.9.9.9"]],
                                                     original: ["ServerAddresses": ["1.0.0.1"]]).apply)
    }

    func testDetectsScopedVPNResolverConflictsAndAcceptsIPv6Loopback() throws {
        try SystemDNSSettings.assertLoopbackResolvers("nameserver[0] : 127.0.0.1\nnameserver[1] : ::1\n")
        XCTAssertThrowsError(try SystemDNSSettings.assertLoopbackResolvers("nameserver[0] : 127.0.0.1\nnameserver[0] : 10.0.0.53\n"))
    }

    func testRejectsMismatchedTruncatedAndServerFailureDNSReplies() {
        let query = DNSPacket.query(name: "example.com", id: 42)
        var response = query
        response[2] = 0x81; response[3] = 0x83
        XCTAssertTrue(DNSPacket.isValidResponse(response, to: query))
        response[0] = 1
        XCTAssertFalse(DNSPacket.isValidResponse(response, to: query))
        response[0] = 0; response[2] = 0x83
        XCTAssertFalse(DNSPacket.isValidResponse(response, to: query))
        response[2] = 0x81; response[3] = 0x82
        XCTAssertFalse(DNSPacket.isValidResponse(response, to: query))
        XCTAssertFalse(DNSPacket.isValidResponse(Data([1, 2]), to: query))
    }

    func testIPCOversizedMessageIsRejectedBeforeWriting() throws {
        let payload = String(repeating: "x", count: DNSProtectionIPC.maximumMessageSize)
        XCTAssertThrowsError(try DNSProtectionIPC.send(payload, descriptor: -1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("128 MiB"))
        }
    }

    func testIPCFramingAndLargeConfigurationPayload() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        let read = descriptors[0], write = descriptors[1]
        let sent = expectation(description: "request sent")
        let payload = String(repeating: "中文 \"quoted\" \\ path\n", count: 300_000)
        DispatchQueue.global().async {
            defer { sent.fulfill() }
            do { try DNSProtectionIPC.send(DNSProtectionRequest(command: .enable, yaml: payload), descriptor: write) }
            catch { XCTFail("IPC send failed: \(error)"); shutdown(write, SHUT_WR) }
        }
        let request = try DNSProtectionIPC.receive(DNSProtectionRequest.self, descriptor: read)
        XCTAssertEqual(request.yaml, payload)
        wait(for: [sent], timeout: 10)
    }

    func testGenerationRejectsSymlinkAndDetectsSameSizeRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.yaml"), link = directory.appendingPathComponent("link")
        try Data("aaaa".utf8).write(to: file)
        let before = try DNSProtectionConfiguration.sourceGeneration(at: file)
        try Data("bbbb".utf8).write(to: file)
        XCTAssertNotEqual(before, try DNSProtectionConfiguration.sourceGeneration(at: file))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try DNSProtectionConfiguration.sourceGeneration(at: link))
        XCTAssertThrowsError(try DNSProtectionConfiguration.readSource(at: link))
    }

    func testPFReferenceRecoveryDistinguishesAlreadyReleasedAndOtherOwners() throws {
        let table = "PID Process Name TOKEN TIMESTAMP\n100 pfctl 123456 0 days 00:00:01\n200 vpn 1234567 0 days 00:00:02\n"
        XCTAssertTrue(try DNSFirewallState.containsReference("123456", output: table))
        XCTAssertFalse(try DNSFirewallState.containsReference("12345", output: table))
        XCTAssertFalse(try DNSFirewallState.containsReference("123456", output: "No pf_enabled references"))
        XCTAssertThrowsError(try DNSFirewallState.containsReference("-d", output: table))
        XCTAssertTrue(DNSFirewallState.isEnabled("Status: Enabled for 0 days 00:00:01\n"))
        XCTAssertFalse(DNSFirewallState.isEnabled("Status: Disabled\n"))
    }
}
