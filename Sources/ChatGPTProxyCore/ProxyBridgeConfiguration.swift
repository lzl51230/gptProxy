import Foundation

public enum ProxyBridgeConfigurationParser {
    public static func isBundledProfileValid(_ data: Data) -> Bool {
        guard let profile = try? JSONSerialization.jsonObject(with: data) else { return false }
        return (try? RustCore().call(["op":"validateProxyProfile", "platform":"macos", "profile":profile])) ?? false
    }

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
        guard let configsData = configs as? Data,
              let configs = try? JSONSerialization.jsonObject(with: configsData),
              let rules else { return false }
        return (try? RustCore().call(["op":"validateProxyProfile", "platform":"macos", "profile":[
            "name":"ChatGPT Only", "dnsEnabled":false, "proxyConfigs":configs, "proxyRules":rules
        ]])) ?? false
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
