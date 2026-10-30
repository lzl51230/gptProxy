import Foundation

enum RemediationAction: Equatable {
    case downloadChatGPT
    case installProxyBridge
    case openNetworkExtensionSettings
    case installProfile
    case revealProfile
    case refreshStatus
}

enum StatusIssue: Identifiable, Equatable {
    case chatGPT(requiresUpdate: Bool)
    case proxyBridge
    case networkExtension
    case dedicatedProfile(manualFallback: Bool)
    case localProxy(port: Int, egressLocation: String?)

    var id: String {
        switch self {
        case .chatGPT: "chatgpt"
        case .proxyBridge: "proxybridge"
        case .networkExtension: "network-extension"
        case .dedicatedProfile: "dedicated-profile"
        case .localProxy: "local-proxy"
        }
    }

    var title: String {
        switch self {
        case let .chatGPT(requiresUpdate):
            requiresUpdate ? "ChatGPT 需要更新" : "尚未安装 ChatGPT"
        case .proxyBridge: "尚未安装 ProxyBridge"
        case .networkExtension: "网络扩展未启用"
        case .dedicatedProfile: "专用配置未启用"
        case let .localProxy(_, egressLocation):
            egressLocation == "CN" ? "代理出口地区不可用" : "本地代理不可用"
        }
    }

    var message: String {
        switch self {
        case let .chatGPT(requiresUpdate):
            if requiresUpdate {
                "当前安装的是不支持 Codex API Key 的旧版 ChatGPT。请更新为最新官方客户端，然后重新检测。"
            } else {
                "请下载并安装官方 ChatGPT 桌面版，然后重新检测。"
            }
        case .proxyBridge:
            "请运行应用随附的 ProxyBridge 安装包，完成安装后重新检测。"
        case .networkExtension:
            "请在系统设置的“网络扩展”中启用 ProxyBridge，完成后返回并重新检测。"
        case .dedicatedProfile:
            "由启动器加载内置规则并运行 ProxyBridge CLI；无需导入或选中第三方 profile。失败时请查看代理日志。"
        case let .localProxy(port, egressLocation):
            if egressLocation == "CN" {
                "代理已连接，但出口仍位于 CN。请在代理客户端切换到支持地区的节点。"
            } else {
                "请确认代理客户端正在监听 127.0.0.1:\(port)，并检查“设置 → 代理”中的端口是否一致。"
            }
        }
    }

    var actionTitle: String {
        switch self {
        case let .chatGPT(requiresUpdate): requiresUpdate ? "更新 ChatGPT" : "下载 ChatGPT"
        case .proxyBridge: "命令行安装／升级"
        case .networkExtension: "打开网络扩展设置"
        case let .dedicatedProfile(manualFallback):
            manualFallback ? "启用代理" : "启用代理"
        case .localProxy: "重新检测"
        }
    }

    var action: RemediationAction {
        switch self {
        case .chatGPT: .downloadChatGPT
        case .proxyBridge: .installProxyBridge
        case .networkExtension: .openNetworkExtensionSettings
        case let .dedicatedProfile(manualFallback):
            manualFallback ? .installProfile : .installProfile
        case .localProxy: .refreshStatus
        }
    }

    static func localProxyIsReady(reachable: Bool, egressLocation: String?) -> Bool {
        reachable && egressLocation != "CN"
    }
}

enum SystemSettingsDestination {
    static func networkExtensionsURL(macOSMajorVersion: Int) -> URL? {
        let value = macOSMajorVersion >= 15
            ? "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points"
            : "x-apple.systempreferences:com.apple.preference.security"
        return URL(string: value)
    }
}
