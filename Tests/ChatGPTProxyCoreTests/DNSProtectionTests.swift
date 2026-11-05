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
        for key in ["proxies", "proxy-groups", "rules", "tun"] {
            XCTAssertEqual(NSDictionary(dictionary: [key: result[key]!]), NSDictionary(dictionary: [key: original[key]!]))
        }
    }

    func testRejectsPlaintextOrCircularBootstrapAndUnsupportedModes() {
        for source in [
            fixture.replacingOccurrences(of: "tls://223.5.5.5", with: "223.5.5.5"),
            fixture.replacingOccurrences(of: "tls://223.5.5.5", with: "tls://bootstrap.example"),
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

    func testIPCFramingAndLargeConfigurationPayload() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        let read = descriptors[0], write = descriptors[1]
        let sent = expectation(description: "request sent")
        let payload = String(repeating: "configuration", count: 20_000)
        DispatchQueue.global().async {
            defer { sent.fulfill() }
            try? DNSProtectionIPC.send(DNSProtectionRequest(command: .enable, yaml: payload), descriptor: write)
        }
        let request = try DNSProtectionIPC.receive(DNSProtectionRequest.self, descriptor: read)
        XCTAssertEqual(request.yaml, payload)
        wait(for: [sent], timeout: 2)
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
