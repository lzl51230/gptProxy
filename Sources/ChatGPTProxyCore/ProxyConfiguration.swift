import Foundation

public enum ProxyConfiguration {
    public static let defaultProxyPort: UInt16 = 7890
    public static let relayPort: UInt16 = 17890

    public static func validatedPort(_ value: String) throws -> UInt16 {
        guard let port = UInt16(value), port > 0, port != relayPort else {
            throw ProxyConfigurationError.invalidPort
        }
        return port
    }
}

public enum ProxyConfigurationError: LocalizedError {
    case invalidPort

    public var errorDescription: String? {
        "端口必须是 1 到 65535 之间的数字，且不能使用内部端口 \(ProxyConfiguration.relayPort)。"
    }
}

public enum AppPaths {
    public static func codexDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
}

public enum ChatGPTApplicationStatus: Equatable {
    case notInstalled
    case supported
    case requiresUpdate
}

public enum ChatGPTApplicationCompatibility {
    public static let supportedBundleIdentifier = "com.openai.codex"
    public static let legacyBundleIdentifier = "com.openai.chat"
    public static let proxyBridgeProcessNames = "com.openai.*;\(legacyBundleIdentifier);ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*"
    // Chromium SOCKS5 resolves HTTP(S)/WebSocket destinations at the proxy.
    // Keep the same local TCP exceptions as the transparent proxy profile.
    public static let proxyLaunchArguments = [
        "--proxy-server=socks5://127.0.0.1:\(ProxyConfiguration.relayPort)",
        "--proxy-bypass-list=localhost;127.0.0.1;[::1];192.168.0.0/16",
    ]
    public static let runningBundleIdentifiers = [
        supportedBundleIdentifier,
        legacyBundleIdentifier,
    ]

    public static func proxyLaunchEnvironment(inheriting environment: [String: String]) -> [String: String] {
        var environment = environment
        // Chromium's proxy arguments do not configure the native Codex backend.
        // socks5h also keeps its destination DNS resolution at the proxy.
        let proxy = "socks5h://127.0.0.1:\(ProxyConfiguration.relayPort)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            environment[key] = proxy
        }
        for key in ["NO_PROXY", "no_proxy"] {
            environment[key] = "localhost,127.0.0.1,::1,192.168.0.0/16"
        }
        return environment
    }

    public static func classify(
        applicationExists: Bool,
        bundleIdentifier: String?
    ) -> ChatGPTApplicationStatus {
        guard applicationExists else { return .notInstalled }
        return bundleIdentifier == supportedBundleIdentifier ? .supported : .requiresUpdate
    }

    public static func inspect(
        applicationURL: URL,
        fileManager: FileManager = .default
    ) -> ChatGPTApplicationStatus {
        classify(
            applicationExists: fileManager.fileExists(atPath: applicationURL.path),
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        )
    }
}
