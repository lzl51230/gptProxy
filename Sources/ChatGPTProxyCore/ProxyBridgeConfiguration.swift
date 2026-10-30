import Foundation

public enum ProxyBridgeConfigurationChecker {
    public static let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Containers/com.interceptsuite.ProxyBridge/Data/Library/Preferences/com.interceptsuite.ProxyBridge.plist"
        )

    public static func isChatGPTOnlyProfileActive(at url: URL = preferencesURL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return false }
            return ProxyBridgeConfigurationParser.isChatGPTOnlyProfileActive(in: data)
        }.value
    }
}

public enum ProxyBridgeConfigurationParser {
    public static func isChatGPTOnlyProfileActive(in propertyListData: Data) -> Bool {
        guard
            let propertyList = try? PropertyListSerialization.propertyList(from: propertyListData, format: nil),
            let preferences = propertyList as? [String: Any],
            let activeProfile = preferences["activeProfile"] as? String,
            activeProfile == "ChatGPT Only",
            let profiles = preferences["profiles"] as? [String],
            profiles.contains(activeProfile),
            matchesExpected(
                configs: preferences["proxyConfigs"],
                rules: preferences["proxyRules"]
            ),
            matchesExpected(
                configs: preferences["profile.\(activeProfile).proxyConfigs"],
                rules: preferences["profile.\(activeProfile).proxyRules"]
            )
        else {
            return false
        }

        // ProxyBridge runs the live keys while the named profile is their persisted snapshot.
        // Requiring both prevents a stale or edited working set from passing the launch gate.
        return true
    }

    private static func matchesExpected(configs: Any?, rules: Any?) -> Bool {
        guard
            let configsData = configs as? Data,
            let decodedConfigs = try? JSONDecoder().decode([ProxyConfig].self, from: configsData),
            let decodedRules = decodeRules(from: rules)
        else {
            return false
        }
        return decodedConfigs == [.chatGPTRelay] && decodedRules == [.localDirect, .externalProxy]
    }

    private static func decodeRules(from value: Any?) -> [ProxyRule]? {
        guard
            let dictionaries = value as? [[String: Any]],
            JSONSerialization.isValidJSONObject(dictionaries),
            let data = try? JSONSerialization.data(withJSONObject: dictionaries)
        else {
            return nil
        }
        return try? JSONDecoder().decode([ProxyRule].self, from: data)
    }
}

public enum CollisionSafeDestination {
    public static func availableURL(for requestedURL: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: requestedURL.path) else { return requestedURL }

        let directory = requestedURL.deletingLastPathComponent()
        let fileExtension = requestedURL.pathExtension
        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let candidateName = fileExtension.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

private struct ProxyConfig: Decodable, Equatable {
    let id: String
    let type: String
    let host: String
    let port: Int
    let username: String?
    let password: String?

    static let chatGPTRelay = ProxyConfig(
        id: "chatgpt-proxy-relay",
        type: "socks5",
        host: "127.0.0.1",
        port: Int(ProxyConfiguration.relayPort),
        username: nil,
        password: nil
    )
}

private struct ProxyRule: Decodable, Equatable {
    let processNames: String
    let targetHosts: String
    let targetPorts: String
    let ruleProtocol: String
    let action: String
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case processNames
        case targetHosts
        case targetPorts
        case ruleProtocol = "protocol"
        case action
        case enabled
    }

    static let localDirect = ProxyRule(
        processNames: ChatGPTApplicationCompatibility.proxyBridgeProcessNames,
        targetHosts: "localhost;127.0.0.1;::1;192.168.*.*;192.168.100.81",
        targetPorts: "*",
        ruleProtocol: "TCP",
        action: "DIRECT",
        enabled: true
    )

    static let externalProxy = ProxyRule(
        processNames: ChatGPTApplicationCompatibility.proxyBridgeProcessNames,
        targetHosts: "*",
        targetPorts: "*",
        ruleProtocol: "BOTH",
        action: "chatgpt-proxy-relay",
        enabled: true
    )
}
