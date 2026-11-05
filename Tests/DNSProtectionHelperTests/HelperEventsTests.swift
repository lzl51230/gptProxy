import XCTest
@testable import DNSProtectionHelper

final class HelperEventsTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testWatchdogCreatedFromMainActorFiresRepeatedlyOnBackgroundQueue() async {
        let fired = expectation(description: "independent watchdog ticks")
        fired.expectedFulfillmentCount = 2
        let timer = HelperEvents.watchdog(interval: 0.02) { fired.fulfill() }
        defer { timer.cancel() }
        await fulfillment(of: [fired], timeout: 2)
    }
}
