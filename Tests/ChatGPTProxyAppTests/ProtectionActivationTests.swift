import XCTest
import ChatGPTProxyCore
@testable import ChatGPTProxyApp

@MainActor
final class ProtectionActivationTests: XCTestCase {
    private enum Failure: Error { case expected }

    func testClashRepairIsRememberedButRechecksTheCurrentSubscription() async throws {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        defer { defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: file) }
        let plain = "mode: global\ndns:\n  default-nameserver: [223.5.5.5]\n  proxy-server-nameserver: [223.5.5.5]"
        try plain.write(to: file, atomically: true, encoding: .utf8)
        let load: (UInt16) async throws -> ClashDNSConfiguration = { _ in
            try ClashDNSConfiguration(source: file, generation: DNSProtectionConfiguration.sourceGeneration(at: file),
                                      socket: "fixture", yaml: String(contentsOf: file, encoding: .utf8),
                                      general: Data("mode: global".utf8), saved: nil)
        }
        let controller = DNSProtectionController(defaults: defaults, loadConfiguration: load)
        do {
            _ = try await controller.requireClashDNS(port: 7890)
            XCTFail("A plaintext subscription must offer repair before launch")
        } catch { XCTAssertEqual(controller.clashCheck, .needsRepair("正在使用明文 DNS")) }
        let prepared = try await controller.checkClash(port: 7890, prepareRepair: true)
        XCTAssertEqual(controller.clashCheck, .prepared)
        XCTAssertEqual(prepared.yaml, plain)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), plain)

        let reopened = DNSProtectionController(defaults: defaults, loadConfiguration: load)
        let retry = try await reopened.requireClashDNS(port: 7890)
        XCTAssertFalse(try XCTUnwrap(retry.bootstrapRepair).isEmpty)
        let valid = plain.replacingOccurrences(of: "223.5.5.5", with: "tls://223.5.5.5")
        try valid.write(to: file, atomically: true, encoding: .utf8)
        let latest = try await reopened.requireClashDNS(port: 7890)
        XCTAssertEqual(reopened.clashCheck, .ready)
        XCTAssertNil(latest.bootstrapRepair)
        XCTAssertEqual(latest.yaml, valid)
        try FileManager.default.removeItem(at: file)
        do {
            _ = try await reopened.requireClashDNS(port: 7890)
            XCTFail("Missing configuration must invalidate a previous successful check")
        } catch {
            XCTAssertFalse(reopened.clashCheck.isReady)
            XCTAssertFalse(reopened.clashCheck.canRepair)
        }
    }

    func testNetworkProtectionNeverRestartsAnExistingGPTOrStartsAnAbsentApp() async throws {
        for running in [true, false] {
            var events: [String] = []
            try await ProtectionActivation.run(launchGPT: false, isGPTRunning: { running },
                enable: { events.append("protect") }, restartGPT: { events.append("restart") },
                restore: { events.append("restore") }, checkCancellation: {})
            XCTAssertEqual(events, ["protect"])
        }
    }

    func testLaunchActionStartsGPTAfterProtectionEvenWhenItWasNotRunning() async throws {
        var events: [String] = []
        try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
            enable: { events.append("protect") }, restartGPT: { events.append("restart") },
            restore: { events.append("restore") }, checkCancellation: {})
        XCTAssertEqual(events, ["protect", "restart"])
    }

    func testRestartFailureRestoresPolicyInsteadOfCompletingActivation() async {
        var events: [String] = []
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { true },
                enable: { events.append("protect") },
                restartGPT: { events.append("restart"); throw Failure.expected },
                restore: { events.append("restore") }, checkCancellation: {})
            XCTFail("Activation must fail")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(events, ["protect", "restart", "restore"])
    }

    func testCancellationAfterEnableRestoresWithoutStartingGPT() async {
        var enabled = false, events: [String] = []
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
                enable: { enabled = true; events.append("protect") }, restartGPT: { events.append("restart") },
                restore: { events.append("restore") },
                checkCancellation: { if enabled { throw CancellationError() } })
            XCTFail("Cancellation must fail activation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["protect", "restore"])
    }

    func testEnableAndRecoveryFailuresRemainVisible() async {
        do {
            try await ProtectionActivation.run(launchGPT: true, isGPTRunning: { false },
                enable: { throw Failure.expected }, restartGPT: { XCTFail("Must not launch") },
                restore: { throw Failure.expected }, checkCancellation: {})
            XCTFail("Activation must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("恢复未完成")) }
    }
}
