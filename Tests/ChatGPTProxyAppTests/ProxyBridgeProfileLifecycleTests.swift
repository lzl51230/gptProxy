import XCTest
@testable import ChatGPTProxyApp

@MainActor
final class ProfileConfigurationModelTests: XCTestCase {
    private enum TestError: LocalizedError {
        case expected

        var errorDescription: String? { "profile setup failed" }
    }

    func testSuccessfulProfileConfigurationClearsFallbackAndEndsReady() async {
        var refreshed = false
        let model = AppModel(
            profileConfigurator: {},
            refreshAfterProfileConfiguration: { refreshed = true }
        )

        await model.installAndActivateBundledProfile()

        XCTAssertEqual(model.phase, .ready)
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
