import XCTest
import ChatGPTProxyCore
@testable import DNSProtectionHelper

final class DNSRecoveryTests: XCTestCase, @unchecked Sendable {
    func testVersionOneJournalDecodesWithoutIPv4PolicyAndNewJournalRetainsBaseline() throws {
        let journal = RecoveryJournal(ownerUID: 501, ownerPID: 10, corePID: 11, socket: "/tmp/fixture.sock", proxyPort: 7890,
            originalYAML: "ipv6: true", sourceGeneration: "fixture", services: [], originalIPv6: true, ipv4PolicyApplied: true)
        let encoded = try JSONEncoder().encode(journal)
        let restored = try JSONDecoder().decode(RecoveryJournal.self, from: encoded)
        XCTAssertEqual(restored.originalIPv6, true)
        XCTAssertEqual(restored.ipv4PolicyApplied, true)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "originalIPv6"); old.removeValue(forKey: "ipv4PolicyApplied")
        let legacy = try JSONDecoder().decode(RecoveryJournal.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.originalIPv6)
        XCTAssertNil(legacy.ipv4PolicyApplied)
    }
    func testFirewallAndClashFailuresStillRestoreSystemDNSAndStopFrontend() async {
        let recorder = Recorder()
        let actions = DNSRecoveryActions(
            firewall: { await recorder.add("firewall"); throw Failure.expected },
            systemDNS: { await recorder.add("systemDNS") },
            reference: { await recorder.add("reference") },
            clash: { await recorder.add("clash"); throw Failure.expected },
            frontend: { await recorder.add("frontend") }, cache: { await recorder.add("cache") })
        let errors = await actions.perform()
        let events = await recorder.events
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(events, ["firewall", "systemDNS", "reference", "clash", "frontend", "cache"])
    }

    func testFailedSystemDNSRestoreDoesNotLeaveFirewallEnabled() async {
        let recorder = Recorder()
        let actions = DNSRecoveryActions(
            firewall: { await recorder.add("firewall") },
            systemDNS: { throw Failure.expected },
            reference: { await recorder.add("releasePF") },
            clash: { await recorder.add("clash") },
            frontend: { await recorder.add("stop") }, cache: {})
        let errors = await actions.perform()
        let events = await recorder.events
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(events, ["firewall", "releasePF", "clash", "stop"])
    }
}

private enum Failure: Error { case expected }
private actor Recorder {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
}
