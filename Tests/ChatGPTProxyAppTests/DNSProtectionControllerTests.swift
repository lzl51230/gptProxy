import XCTest
import ChatGPTProxyCore
@testable import ChatGPTProxyApp

private actor HelperFixture {
    var commands: [DNSProtectionRequest.Command] = []
    private let thirdHeartbeat: DispatchSemaphore?
    init(thirdHeartbeat: DispatchSemaphore? = nil) { self.thirdHeartbeat = thirdHeartbeat }
    func request(_ request: DNSProtectionRequest) throws -> DNSProtectionStatus {
        commands.append(request.command)
        if commands.count == 3 { thirdHeartbeat?.signal() }
        if commands.count == 2 { throw MonitorError.message("temporary IPC timeout") }
        return .init(phase: .enabled, detail: "protected")
    }
}

@MainActor
final class DNSProtectionControllerTests: XCTestCase {
    func testObservationFailureDoesNotStopRenewingLeaseAndSuccessClearsFailure() async {
        let helper = HelperFixture()
        let controller = DNSProtectionController(requestIPC: { try await helper.request($0) })
        await controller.refresh()
        XCTAssertTrue(controller.status.isEnabled)
        await controller.refresh()
        XCTAssertEqual(controller.status.phase, .failed)
        await controller.refresh()
        XCTAssertTrue(controller.status.isEnabled)
        let commands = await helper.commands
        XCTAssertEqual(commands, [.heartbeat, .heartbeat, .heartbeat])
    }

    func testHeartbeatContinuesWhileMainActorIsOccupied() async {
        let received = DispatchSemaphore(value: 0)
        let helper = HelperFixture(thirdHeartbeat: received)
        let controller = DNSProtectionController(requestIPC: { try await helper.request($0) })
        controller.startMonitoring(interval: .milliseconds(10))
        // The main actor cannot process callbacks until the background heartbeat signals.
        let result = blockMainActor(until: received)
        controller.stopMonitoring()
        XCTAssertEqual(result, .success)
        let commands = await helper.commands
        XCTAssertGreaterThanOrEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy { $0 == .heartbeat })
    }

    private func blockMainActor(until semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 5)
    }

    func testVersionThreeStatusStillDecodesWithoutDiagnosticFields() throws {
        let data = Data(#"{"phase":"disabled","detail":"restored","version":"3"}"#.utf8)
        let status = try JSONDecoder().decode(DNSProtectionStatus.self, from: data)
        XCTAssertNil(status.lastStopReason)
        XCTAssertNil(status.lastStopAt)
        XCTAssertNil(status.recoveryResult)
    }
}
