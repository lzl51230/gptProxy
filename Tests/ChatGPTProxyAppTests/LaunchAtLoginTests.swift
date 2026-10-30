import XCTest
import ServiceManagement
import AppKit
import CoreServices
@testable import ChatGPTProxyApp

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    final class Service {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var removals = 0
        var opened = 0
        var fail = false
        var needsApproval = false
        var operations: LaunchAtLoginController.Operations {
            .init(status: { self.status }, register: {
                self.registrations += 1
                if self.fail { throw NSError(domain: "test", code: 1) }
                self.status = self.needsApproval ? .requiresApproval : .enabled
            }, unregister: { self.removals += 1; self.status = .notRegistered },
            openSettings: { self.opened += 1 })
        }
    }
    func testToggleRegistersAndUnregistersSystemService() async {
        let service = Service(); let model = LaunchAtLoginController(operations: service.operations)
        XCTAssertFalse(model.isEnabled)
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled); XCTAssertFalse(model.isWorking)
        await model.setEnabled(true)
        XCTAssertEqual(service.registrations, 1)
        await model.setEnabled(false)
        XCTAssertFalse(model.isEnabled); XCTAssertEqual(service.removals, 1)
        await model.setEnabled(false)
        XCTAssertEqual(service.removals, 1)
    }
    func testSystemApprovalIsNotReportedAsEnabled() async {
        let service = Service(); service.needsApproval = true
        let model = LaunchAtLoginController(operations: service.operations)
        await model.setEnabled(true)
        XCTAssertEqual(model.status, .requiresApproval); XCTAssertFalse(model.isEnabled)
        await model.setEnabled(true)
        XCTAssertEqual(service.opened, 1); XCTAssertEqual(service.registrations, 1)
    }
    func testFailureRestoresRealStatusAndAllowsRetry() async {
        let service = Service(); service.fail = true
        let model = LaunchAtLoginController(operations: service.operations)
        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled); XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.isWorking)
        service.fail = false; await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled); XCTAssertNil(model.errorMessage)
    }
    func testRefreshReflectsChangesInSystemSettings() {
        let service = Service(); let model = LaunchAtLoginController(operations: service.operations)
        service.status = .enabled; model.refresh(); XCTAssertTrue(model.isEnabled)
        service.status = .requiresApproval; model.refresh(); XCTAssertFalse(model.isEnabled)
        service.status = .notRegistered; model.refresh(); XCTAssertEqual(model.status, .notRegistered)
    }
    func testMissingSystemRecordCanBeRegisteredAgain() async {
        let service = Service(); service.status = .notFound
        let model = LaunchAtLoginController(operations: service.operations)
        XCTAssertFalse(model.isEnabled); XCTAssertTrue(model.statusText.contains("未开启"))
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled); XCTAssertEqual(service.registrations, 1)
    }
    func testLoginEventVersusManualLaunch() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunchContext.isLoginLaunch(nil))
        XCTAssertFalse(LoginLaunchContext.isLoginLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertTrue(LoginLaunchContext.isLoginLaunch(event))
    }
}
