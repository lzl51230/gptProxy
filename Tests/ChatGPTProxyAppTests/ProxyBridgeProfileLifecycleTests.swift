import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProfileConfigurationModelTests: XCTestCase {
    private enum TestError: LocalizedError {
        case expected

        var errorDescription: String? { "profile setup failed" }
    }

    func testFailedLaunchPreservesPausedProtectionUntilAnExplicitLaunchSucceeds() async throws {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defer { defaults.removePersistentDomain(forName: id) }
        defaults.set(true, forKey: "dnsProtectionPaused")
        let failed = AppModel(profileConfigurator: {}, defaults: defaults,
                              protectedLauncher: { throw TestError.expected })
        await failed.launchChatGPT()
        XCTAssertEqual(failed.phase, .failed(TestError.expected.localizedDescription))
        XCTAssertTrue(failed.protectionPaused)
        XCTAssertTrue(defaults.bool(forKey: "dnsProtectionPaused"))
        let succeeded = AppModel(profileConfigurator: {}, defaults: defaults, protectedLauncher: {})
        XCTAssertTrue(succeeded.protectionPaused)
        await succeeded.launchChatGPT()
        XCTAssertFalse(succeeded.protectionPaused)
        XCTAssertFalse(defaults.bool(forKey: "dnsProtectionPaused"))
    }

    func testSuccessfulProfileConfigurationDoesNotClaimReadyBeforeDNSProtection() async {
        var refreshed = false
        let model = AppModel(
            profileConfigurator: {},
            refreshAfterProfileConfiguration: { refreshed = true }
        )

        await model.installAndActivateBundledProfile()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.profileInstallRequiresManualFallback)
        XCTAssertTrue(refreshed)
    }

    func testFailedProfileConfigurationEnablesFallbackAndReportsFailure() async {
        var refreshed = false
        let model = AppModel(
            profileConfigurator: { throw TestError.expected },
            refreshAfterProfileConfiguration: { refreshed = true }
        )

        await model.installAndActivateBundledProfile()

        XCTAssertEqual(model.phase, .failed(TestError.expected.localizedDescription))
        XCTAssertFalse(model.profileInstallRequiresManualFallback)
        XCTAssertFalse(refreshed)
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [String] = []

    var terminationCount: Int {
        events.filter { $0 == "terminate" }.count
    }

    func append(_ event: String) {
        events.append(event)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
