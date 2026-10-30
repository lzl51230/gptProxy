import Foundation

public struct ProxyBridgeProfileInstallationReceipt: Sendable {
    public let preferencesURL: URL
    public let backupURL: URL
}

public enum ProxyBridgeProfileInstallError: LocalizedError {
    case preferencesMissing
    case invalidPreferences
    case invalidProfile
    case writeFailed(String)
    case rollbackFailed(backupURL: URL, installError: String, rollbackError: String)

    public var errorDescription: String? {
        switch self {
        case .preferencesMissing:
            "ProxyBridge 尚未生成配置文件，请先打开一次 ProxyBridge。"
        case .invalidPreferences:
            "现有 ProxyBridge 配置无法读取，未进行修改。"
        case .invalidProfile:
            "内置 ChatGPT Only 配置无效，未进行修改。"
        case let .writeFailed(message):
            "无法更新 ProxyBridge 配置：\(message)"
        case let .rollbackFailed(backupURL, installError, rollbackError):
            "更新 ProxyBridge 配置失败（\(installError)），且无法恢复原配置（\(rollbackError)）。原配置备份保留在：\(backupURL.path)"
        }
    }
}

public enum ProxyBridgeProfileInstaller {
    typealias BackupPruner = (URL, Int, FileManager) throws -> Void
    typealias PrivateWriter = (Data, URL, FileManager) throws -> Void

    struct InstallOperations {
        let backupPruner: BackupPruner
        let backupWriter: PrivateWriter
        let preferencesWriter: PrivateWriter
    }

    public static let supportedVersion = "4.0.0"
    public static let profileName = "ChatGPT Only"
    static let backupRetentionCount = 10

    public static func mergedPreferences(
        existingPreferences: Data,
        profile: Data
    ) throws -> Data {
        guard
            let existing = try? PropertyListSerialization.propertyList(
                from: existingPreferences,
                format: nil
            ) as? [String: Any]
        else {
            throw ProxyBridgeProfileInstallError.invalidPreferences
        }
        guard
            let imported = profileDictionary(from: profile),
            imported["name"] as? String == profileName,
            let proxyConfigs = imported["proxyConfigs"] as? [[String: Any]],
            let proxyRules = imported["proxyRules"] as? [[String: Any]],
            let closeToMenuBar = imported["closeToMenuBar"] as? Bool,
            let runAtStartup = imported["runAtStartup"] as? Bool,
            let trafficLoggingEnabled = imported["trafficLoggingEnabled"] as? Bool,
            JSONSerialization.isValidJSONObject(proxyConfigs),
            JSONSerialization.isValidJSONObject(proxyRules),
            let proxyConfigsData = try? JSONSerialization.data(
                withJSONObject: proxyConfigs,
                options: [.sortedKeys]
            )
        else {
            throw ProxyBridgeProfileInstallError.invalidProfile
        }

        var preferences = existing
        var profiles = (preferences["profiles"] as? [String] ?? []).filter { $0 != profileName }
        profiles.append(profileName)

        preferences["profiles"] = profiles
        preferences["activeProfile"] = profileName
        preferences["profile.\(profileName).proxyConfigs"] = proxyConfigsData
        preferences["profile.\(profileName).proxyRules"] = proxyRules
        preferences["profile.\(profileName).closeToMenuBar"] = closeToMenuBar
        preferences["profile.\(profileName).runAtStartup"] = runAtStartup
        preferences["profile.\(profileName).trafficLoggingEnabled"] = trafficLoggingEnabled
        preferences["proxyConfigs"] = proxyConfigsData
        preferences["proxyRules"] = proxyRules
        preferences["closeToMenuBar"] = closeToMenuBar
        preferences["runAtStartup"] = runAtStartup
        preferences["trafficLoggingEnabled"] = trafficLoggingEnabled

        guard
            let result = try? PropertyListSerialization.data(
                fromPropertyList: preferences,
                format: .binary,
                options: 0
            ),
            ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: result)
        else {
            throw ProxyBridgeProfileInstallError.invalidProfile
        }
        return result
    }

    public static func install(
        profile: Data,
        preferencesURL: URL,
        backupDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ProxyBridgeProfileInstallationReceipt {
        try install(
            profile: profile,
            preferencesURL: preferencesURL,
            backupDirectory: backupDirectory,
            fileManager: fileManager,
            operations: InstallOperations(
                backupPruner: pruneBackups,
                backupWriter: writePrivate,
                preferencesWriter: writePreferences
            )
        )
    }

    static func install(
        profile: Data,
        preferencesURL: URL,
        backupDirectory: URL,
        fileManager: FileManager,
        operations: InstallOperations
    ) throws -> ProxyBridgeProfileInstallationReceipt {
        let original: Data
        do {
            original = try Data(contentsOf: preferencesURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ProxyBridgeProfileInstallError.preferencesMissing
        } catch {
            throw ProxyBridgeProfileInstallError.invalidPreferences
        }
        let updated = try mergedPreferences(existingPreferences: original, profile: profile)

        do {
            try fileManager.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: backupDirectory.path
            )
            try operations.backupPruner(backupDirectory, backupRetentionCount - 1, fileManager)
        } catch {
            throw mappedWriteError(error)
        }

        let requestedBackup = backupDirectory.appendingPathComponent(
            "ProxyBridge Preferences \(Int(Date().timeIntervalSince1970)).plist"
        )
        let backupURL = CollisionSafeDestination.availableURL(
            for: requestedBackup,
            fileManager: fileManager
        )
        do {
            try operations.backupWriter(original, backupURL, fileManager)
        } catch {
            throw mappedWriteError(error)
        }

        do {
            try operations.preferencesWriter(updated, preferencesURL, fileManager)

            let persisted = try Data(contentsOf: preferencesURL)
            guard ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: persisted) else {
                throw ProxyBridgeProfileInstallError.writeFailed("写入后的配置校验失败。")
            }
            return ProxyBridgeProfileInstallationReceipt(
                preferencesURL: preferencesURL,
                backupURL: backupURL
            )
        } catch let installError {
            do {
                try operations.preferencesWriter(original, preferencesURL, fileManager)
                let restored = try Data(contentsOf: preferencesURL)
                guard propertyListsAreEqual(restored, original) else {
                    throw ProxyBridgeProfileInstallError.writeFailed("恢复后的配置与原配置不一致。")
                }
            } catch let rollbackError {
                throw ProxyBridgeProfileInstallError.rollbackFailed(
                    backupURL: backupURL,
                    installError: failureDescription(installError),
                    rollbackError: failureDescription(rollbackError)
                )
            }
            throw mappedWriteError(installError)
        }
    }

    public static func restore(
        _ receipt: ProxyBridgeProfileInstallationReceipt,
        fileManager: FileManager = .default
    ) throws {
        try restore(receipt, fileManager: fileManager, writer: writePreferences)
    }

    static func restore(
        _ receipt: ProxyBridgeProfileInstallationReceipt,
        fileManager: FileManager,
        writer: PrivateWriter
    ) throws {
        let backup = try Data(contentsOf: receipt.backupURL)
        do {
            try writer(backup, receipt.preferencesURL, fileManager)
            let restored = try Data(contentsOf: receipt.preferencesURL)
            guard propertyListsAreEqual(restored, backup) else {
                throw ProxyBridgeProfileInstallError.writeFailed("恢复后的配置与备份不一致。")
            }
        } catch {
            throw mappedWriteError(error)
        }
    }

    private static func writePrivate(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writePreferences(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let domain = url.deletingPathExtension().path
        let deleteProcess = Process()
        deleteProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        deleteProcess.arguments = ["delete", domain]
        deleteProcess.standardOutput = FileHandle.nullDevice
        deleteProcess.standardError = FileHandle.nullDevice
        try deleteProcess.run()
        deleteProcess.waitUntilExit()

        let process = Process()
        let standardInput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["import", domain, "-"]
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: data)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failureMessage = if let message, !message.isEmpty {
                message
            } else {
                "defaults import 失败。"
            }
            throw ProxyBridgeProfileInstallError.writeFailed(failureMessage)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func pruneBackups(
        in directory: URL,
        retainingAtMost retainedCount: Int,
        fileManager: FileManager
    ) throws {
        let backupURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (url: URL, modificationDate: Date)? in
            guard url.lastPathComponent.hasPrefix("ProxyBridge Preferences ") else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        let historicalBackups = backupURLs.sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }

        for expiredBackup in historicalBackups.dropFirst(retainedCount) {
            try fileManager.removeItem(at: expiredBackup.url)
        }
    }

    private static func mappedWriteError(_ error: Error) -> ProxyBridgeProfileInstallError {
        if let installError = error as? ProxyBridgeProfileInstallError {
            return installError
        }
        return .writeFailed(error.localizedDescription)
    }

    private static func failureDescription(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func propertyListsAreEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard
            let lhsValue = try? PropertyListSerialization.propertyList(from: lhs, format: nil),
            let rhsValue = try? PropertyListSerialization.propertyList(from: rhs, format: nil),
            let lhsDictionary = lhsValue as? NSDictionary,
            let rhsDictionary = rhsValue as? NSDictionary
        else {
            return false
        }
        return lhsDictionary.isEqual(rhsDictionary)
    }

    private static func profileDictionary(from data: Data) -> [String: Any]? {
        if let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            return propertyList as? [String: Any]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
