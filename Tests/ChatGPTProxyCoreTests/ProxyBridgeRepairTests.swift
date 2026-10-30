import Foundation
import XCTest
@testable import ChatGPTProxyCore

private enum Failure: Error { case expected }
private final class RepairFixture: @unchecked Sendable {
    let lock = NSLock()
    var status: ProxyBridgeInstallationStatus = .missing
    var events: [String] = []
    var package: URL?
    var failure: String?
    var updatesVersion = true
    func inspect() -> ProxyBridgeInstallationStatus { lock.lock(); defer { lock.unlock() }; return status }
    func record(_ event: String) throws {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if failure == event { throw Failure.expected }
    }
    var operations: ProxyBridgeRepairOperations {
        .init(inspect: { self.inspect() }, download: { url, port in
            XCTAssertEqual(port, 7890)
            self.package = url
            try self.record("download")
            try await Task.sleep(for: .milliseconds(50))
            try Data("package".utf8).write(to: url)
        }, validate: { _ in try self.record("validate") }, install: { _ in
            try self.record("install")
            if self.updatesVersion { self.status = .ready }
        })
    }
}

@MainActor
final class ProxyBridgeRepairTests: XCTestCase {
    func testRepairOrderAndTemporaryCleanup() async throws {
        let f = RepairFixture(), service: ProxyBridgeRepairService
        service = ProxyBridgeRepairService(operations: f.operations)
        try await service.repair(proxyPort: 7890, beforeInstall: {
            XCTAssertEqual(service.stage, .installing)
            XCTAssertFalse(service.canCancel)
            service.cancel()
            try f.record("stop")
        }, activate: { try f.record("activate") })
        XCTAssertEqual(f.events, ["download", "validate", "stop", "install", "activate"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(f.package).path))
        XCTAssertEqual(service.stage, .idle)
        XCTAssertFalse(service.isBusy)
    }
    func testHealthyInstallationSkipsDownloadAndElevation() async throws {
        let f = RepairFixture(); f.status = .ready
        let service = ProxyBridgeRepairService(operations: f.operations)
        try await service.repair(proxyPort: 7890, beforeInstall: { try f.record("stop") }, activate: { try f.record("activate") })
        XCTAssertEqual(f.events, ["activate"])
    }
    func testFailureDoesNotAdvanceAndCanRetry() async throws {
        for step in ["download", "validate", "install"] {
            let f = RepairFixture(); f.failure = step
            let service = ProxyBridgeRepairService(operations: f.operations)
            do {
                try await service.repair(proxyPort: 7890, beforeInstall: { try f.record("stop") }, activate: { try f.record("activate") })
                XCTFail("Expected failure")
            } catch {}
            XCTAssertFalse(f.events.contains("activate"))
            if step != "install" { XCTAssertFalse(f.events.contains("install")) }
            XCTAssertFalse(service.isBusy)
            XCTAssertEqual(service.stage, .idle)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(f.package).path))
            f.failure = nil
            try await service.repair(proxyPort: 7890, beforeInstall: {}, activate: { try f.record("activate") })
            XCTAssertEqual(f.events.last, "activate")
        }
    }
    func testWrongPostInstallVersionDoesNotActivate() async {
        let f = RepairFixture(); f.updatesVersion = false
        let service = ProxyBridgeRepairService(operations: f.operations)
        do { try await service.repair(proxyPort: 7890, beforeInstall: {}, activate: { try f.record("activate") }); XCTFail() } catch {}
        XCTAssertFalse(f.events.contains("activate"))
    }
    func testRepeatedCallsShareOneRepair() async throws {
        let f = RepairFixture(); let service = ProxyBridgeRepairService(operations: f.operations)
        async let first: Void = service.repair(proxyPort: 7890, beforeInstall: {}, activate: {})
        async let second: Void = service.repair(proxyPort: 7890, beforeInstall: {}, activate: {})
        try await first; try await second
        XCTAssertEqual(f.events.filter { $0 == "install" }.count, 1)
        XCTAssertEqual(f.events.filter { $0 == "download" }.count, 1)
    }
    func testCancelDownloadDoesNotInstall() async throws {
        let f = RepairFixture()
        var ops = f.operations
        ops.download = { url, _ in f.package = url; try f.record("download"); try await Task.sleep(for: .seconds(10)) }
        let service = ProxyBridgeRepairService(operations: ops)
        let task = Task { try await service.repair(proxyPort: 7890, beforeInstall: {}, activate: {}) }
        while service.stage != .downloading { await Task.yield() }
        service.cancel()
        do { try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(f.events.contains("install"))
        XCTAssertFalse(service.isBusy)
    }
    func testCorruptInstallerRejectedBeforeSignatureOrElevation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an installer".utf8).write(to: url)
        do { try await ProxyBridgeRepairOperations.live.validate(url); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256")) }
    }
    func testShutdownWaitsForInstallerAndSkipsActivation() async throws {
        let f = RepairFixture()
        var ops = f.operations
        ops.install = { _ in
            try await Task.detached { try await Task.sleep(for: .milliseconds(100)) }.value
            try f.record("install")
            f.status = .ready
        }
        let service = ProxyBridgeRepairService(operations: ops)
        let task = Task {
            try await service.repair(proxyPort: 7890, beforeInstall: {}, activate: { try f.record("activate") })
        }
        while service.stage != .installing { await Task.yield() }
        await service.finishOrCancel()
        do { try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(f.events.contains("install"))
        XCTAssertFalse(f.events.contains("activate"))
        XCTAssertEqual(f.inspect(), .ready)
        XCTAssertFalse(service.isBusy)
    }
}

final class ProxyBridgeInstallationTests: XCTestCase {
    func testFreshReadDetectsMissingOldCorrectAndDamagedInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ProxyBridgeInstallationStatus.inspect(at: root), .missing)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = root.appendingPathComponent("Contents/Info.plist")
        func version(_ value: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.interceptsuite.ProxyBridge", "CFBundleShortVersionString": value], format: .xml, options: 0)
            try data.write(to: info)
        }
        try version("4.0.0")
        XCTAssertEqual(ProxyBridgeInstallationStatus.inspect(at: root), .incompatible("4.0.0"))
        try version("4.1.0")
        guard case .unusable = ProxyBridgeInstallationStatus.inspect(at: root) else { return XCTFail() }
        let binary = root.appendingPathComponent("Contents/MacOS/ProxyBridge")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(ProxyBridgeInstallationStatus.inspect(at: root), .ready)
        try version("5.0.0")
        XCTAssertEqual(ProxyBridgeInstallationStatus.inspect(at: root), .incompatible("5.0.0"))
        try Data("bad plist".utf8).write(to: info)
        guard case .unusable = ProxyBridgeInstallationStatus.inspect(at: root) else { return XCTFail() }
    }
}
