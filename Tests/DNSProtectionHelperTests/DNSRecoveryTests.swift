import XCTest
@testable import DNSProtectionHelper

final class DNSRecoveryTests: XCTestCase, @unchecked Sendable {
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
