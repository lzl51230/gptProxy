import Foundation
import XCTest
@testable import ChatGPTProxyCore

final class ProxyBridgeProfileInstallerTests: XCTestCase {
    func testMergeActivatesProfileAndPreservesUnrelatedPreferences() throws {
        let existing = try plistData([
            "profiles": ["Default", "Work", "ChatGPT Only", "ChatGPT Only"],
            "activeProfile": "Work",
            "profile.Work.secret": "preserve-me",
            "unrelated": 42,
        ])

        let merged = try ProxyBridgeProfileInstaller.mergedPreferences(
            existingPreferences: existing,
            profile: try profileData()
        )
        let preferences = try plistDictionary(merged)

        XCTAssertEqual(preferences["profiles"] as? [String], ["Default", "Work", "ChatGPT Only"])
        XCTAssertEqual(preferences["activeProfile"] as? String, "ChatGPT Only")
        XCTAssertEqual(preferences["profile.Work.secret"] as? String, "preserve-me")
        XCTAssertEqual(preferences["unrelated"] as? Int, 42)
        XCTAssertTrue(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: merged))
    }

    func testMergeIsIdempotent() throws {
        let initial = try plistData(["profiles": ["Default"]])
        let profile = try profileData()
        let first = try ProxyBridgeProfileInstaller.mergedPreferences(
            existingPreferences: initial,
            profile: profile
        )
        let second = try ProxyBridgeProfileInstaller.mergedPreferences(
            existingPreferences: first,
            profile: profile
        )

        XCTAssertEqual(try plistDictionary(first) as NSDictionary, try plistDictionary(second) as NSDictionary)
    }

    func testInstallAcceptsBundledProfileAndPreservesUnrelatedPreferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try plistData([
            "profiles": ["Default", "Work"],
            "activeProfile": "Work",
            "profile.Work.secret": "preserve-me",
            "unrelated": 42,
        ])
        try original.write(to: preferencesURL)

        _ = try ProxyBridgeProfileInstaller.install(
            profile: try Data(contentsOf: bundledProfileURL()),
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory
        )
        let persisted = try Data(contentsOf: preferencesURL)
        let preferences = try plistDictionary(persisted)

        XCTAssertTrue(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: persisted))
        XCTAssertEqual(preferences["profile.Work.secret"] as? String, "preserve-me")
        XCTAssertEqual(preferences["unrelated"] as? Int, 42)
    }

    func testMergeRejectsUnexpectedProfileContent() throws {
        var profile = try plistDictionary(try profileData())
        profile["name"] = "Unexpected"

        XCTAssertThrowsError(
            try ProxyBridgeProfileInstaller.mergedPreferences(
                existingPreferences: try plistData([:]),
                profile: try plistData(profile)
            )
        )
    }

    func testInstallCreatesPrivateBackupAndRestoreRecoversOriginalPreferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try plistData(["profiles": ["Default"], "sentinel": "original"])
        try original.write(to: preferencesURL)

        let receipt = try ProxyBridgeProfileInstaller.install(
            profile: try profileData(),
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.backupURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let preferencesPermissions = try FileManager.default.attributesOfItem(atPath: preferencesURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(preferencesPermissions?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: backupDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        XCTAssertTrue(
            ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(
                in: try Data(contentsOf: preferencesURL)
            )
        )

        try ProxyBridgeProfileInstaller.restore(receipt)

        XCTAssertEqual(
            try plistDictionary(Data(contentsOf: preferencesURL)) as NSDictionary,
            try plistDictionary(original) as NSDictionary
        )
    }

    func testInstallDoesNotCreateBackupWhenPreferencesAreMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("Missing.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try ProxyBridgeProfileInstaller.install(
                profile: try profileData(),
                preferencesURL: preferencesURL,
                backupDirectory: backupDirectory
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectory.path))
    }

    func testInstallKeepsOnlyRecentBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try plistData(["profiles": ["Default"]]).write(to: preferencesURL)
        for index in 0...ProxyBridgeProfileInstaller.backupRetentionCount {
            let backupURL = backupDirectory.appendingPathComponent("ProxyBridge Preferences \(index).plist")
            try Data("backup-\(index)".utf8).write(to: backupURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: backupURL.path
            )
        }

        let receipt = try ProxyBridgeProfileInstaller.install(
            profile: try profileData(),
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ProxyBridge Preferences ") }

        XCTAssertEqual(backups.count, ProxyBridgeProfileInstaller.backupRetentionCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("ProxyBridge Preferences 0.plist").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("ProxyBridge Preferences 1.plist").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("ProxyBridge Preferences 2.plist").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("ProxyBridge Preferences 10.plist").path
            )
        )
    }

    func testInstallDoesNotWritePreferencesOrBackupWhenPruningFails() throws {
        enum TestError: Error { case pruningFailed }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try plistData(["profiles": ["Default"], "sentinel": "original"])
        try original.write(to: preferencesURL)
        let historicalBackup = backupDirectory.appendingPathComponent("ProxyBridge Preferences 1.plist")
        try Data("historical".utf8).write(to: historicalBackup)
        var writerWasCalled = false

        XCTAssertThrowsError(
            try ProxyBridgeProfileInstaller.install(
                profile: try profileData(),
                preferencesURL: preferencesURL,
                backupDirectory: backupDirectory,
                fileManager: .default,
                operations: .init(
                    backupPruner: { _, _, _ in throw TestError.pruningFailed },
                    backupWriter: { _, _, _ in writerWasCalled = true },
                    preferencesWriter: { _, _, _ in writerWasCalled = true }
                )
            )
        ) { error in
            guard case ProxyBridgeProfileInstallError.writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
        }

        XCTAssertFalse(writerWasCalled)
        XCTAssertEqual(try Data(contentsOf: preferencesURL), original)
        let retainedBackupPaths = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).map { $0.standardizedFileURL.path }
        XCTAssertEqual(retainedBackupPaths, [historicalBackup.standardizedFileURL.path])
    }

    func testInstallUsesSynchronizedWriterForLivePreferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try plistData(["profiles": ["Default"]]).write(to: preferencesURL)
        var backupWriterDestinations: [URL] = []
        var preferencesWriterDestinations: [URL] = []

        _ = try ProxyBridgeProfileInstaller.install(
            profile: try profileData(),
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory,
            fileManager: .default,
            operations: .init(
                backupPruner: { _, _, _ in },
                backupWriter: { data, destination, fileManager in
                    backupWriterDestinations.append(destination)
                    try data.write(to: destination, options: .atomic)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: destination.path
                    )
                },
                preferencesWriter: { data, destination, fileManager in
                    preferencesWriterDestinations.append(destination)
                    try data.write(to: destination, options: .atomic)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: destination.path
                    )
                }
            )
        )

        XCTAssertEqual(backupWriterDestinations.count, 1)
        XCTAssertEqual(backupWriterDestinations.first?.deletingLastPathComponent(), backupDirectory)
        XCTAssertEqual(preferencesWriterDestinations, [preferencesURL])
    }

    func testInstallAndRestoreStayVisibleToCachedPreferencesDomain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        let domain = preferencesURL.deletingPathExtension().path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            _ = try? runDefaults(["delete", domain])
            try? FileManager.default.removeItem(at: directory)
        }

        let original = try plistData([
            "profiles": ["Default"],
            "activeProfile": "Default",
            "sentinel": "original",
        ])
        _ = try runDefaults(["import", domain, "-"], standardInput: original)
        _ = try runDefaults(["read", domain])

        let receipt = try ProxyBridgeProfileInstaller.install(
            profile: try profileData(),
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory
        )
        let installed = try runDefaults(["export", domain, "-"])
        XCTAssertTrue(ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: installed))

        try ProxyBridgeProfileInstaller.restore(receipt)
        let restored = try runDefaults(["export", domain, "-"])
        XCTAssertEqual(
            try plistDictionary(restored) as NSDictionary,
            try plistDictionary(original) as NSDictionary
        )
    }

    func testInstallReportsRetainedBackupWhenRollbackValidationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let preferencesURL = directory.appendingPathComponent("ProxyBridge.plist")
        let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try plistData(["profiles": ["Default"], "sentinel": "original"])
        try original.write(to: preferencesURL)
        var preferencesWriteCount = 0

        do {
            _ = try ProxyBridgeProfileInstaller.install(
                profile: try profileData(),
                preferencesURL: preferencesURL,
                backupDirectory: backupDirectory,
                fileManager: .default,
                operations: .init(
                    backupPruner: { _, _, _ in },
                    backupWriter: { data, destination, fileManager in
                        try data.write(to: destination, options: .atomic)
                        try fileManager.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: destination.path
                        )
                    },
                    preferencesWriter: { data, destination, fileManager in
                        preferencesWriteCount += 1
                        if preferencesWriteCount == 1 {
                            throw NSError(domain: "installWriteFailed", code: 1)
                        }
                        try Data("corrupt rollback".utf8).write(to: destination, options: .atomic)
                        try fileManager.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: destination.path
                        )
                    }
                )
            )
            XCTFail("Expected rollback failure")
        } catch let error as ProxyBridgeProfileInstallError {
            guard case let .rollbackFailed(backupURL, installError, rollbackError) = error else {
                return XCTFail("Expected rollbackFailed, got \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertTrue(installError.contains("installWriteFailed"))
            XCTAssertTrue(rollbackError.contains("恢复后的配置与原配置不一致"))
        }
    }

    private func profileData() throws -> Data {
        try plistData(profileDictionary())
    }

    private func profileDictionary() -> [String: Any] {
        [
            "name": "ChatGPT Only",
            "proxyConfigs": [[
                "id": "chatgpt-proxy-relay",
                "name": "ChatGPT Proxy Relay",
                "type": "socks5",
                "host": "127.0.0.1",
                "port": 17_890,
            ]],
            "proxyRules": [
                [
                    "localId": "chatgpt-local-direct",
                    "name": "ChatGPT Local Direct",
                    "processNames": "com.openai.*;com.openai.chat;ChatGPT",
                    "targetHosts": "localhost;127.0.0.1;::1;192.168.*.*;192.168.100.81",
                    "targetPorts": "*",
                    "protocol": "TCP",
                    "action": "DIRECT",
                    "enabled": true,
                ],
                [
                    "localId": "chatgpt-only-proxy",
                    "name": "ChatGPT Proxy",
                    "processNames": "com.openai.*;com.openai.chat;ChatGPT",
                    "targetHosts": "*",
                    "targetPorts": "*",
                    "protocol": "BOTH",
                    "action": "chatgpt-proxy-relay",
                    "enabled": true,
                ],
            ],
            "closeToMenuBar": true,
            "runAtStartup": false,
            "trafficLoggingEnabled": false,
        ]
    }

    private func bundledProfileURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ChatGPT-Only.pbprofile")
    }

    private func plistData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func plistDictionary(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func runDefaults(_ arguments: [String], standardInput: Data? = nil) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        if let standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: standardInput)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "defaults failed"
            throw NSError(
                domain: "ProxyBridgeProfileInstallerTests.defaults",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
