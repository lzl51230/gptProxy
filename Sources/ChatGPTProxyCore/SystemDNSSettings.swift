import Foundation
import SystemConfiguration

public struct SystemDNSSnapshot: Codable, Equatable, Sendable {
    public let serviceID: String
    public let original: Data?
    public init(serviceID: String, original: Data?) { self.serviceID = serviceID; self.original = original }
}

public enum SystemDNSSettings {
    public static let loopback = ["127.0.0.1", "::1"]

    static func restoration(current: [String: Any], original: [String: Any]?) -> (apply: Bool, configuration: [String: Any]?) {
        guard current["ServerAddresses"] as? [String] == loopback else { return (false, nil) }
        var updated = current
        updated["ServerAddresses"] = original?["ServerAddresses"]
        return (true, updated.isEmpty && original == nil ? nil : updated)
    }

    private static func preferences() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "ChatGPT Proxy DNS" as CFString, nil) else {
            throw MonitorError.message("无法读取系统网络配置")
        }
        return prefs
    }

    private static func physicalServices(_ prefs: SCPreferences) -> [SCNetworkService] {
        let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
        return services.filter {
            guard SCNetworkServiceGetEnabled($0), let interface = SCNetworkServiceGetInterface($0),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { return false }
            return type == kSCNetworkInterfaceTypeEthernet || type == kSCNetworkInterfaceTypeIEEE80211
        }
    }

    public static func snapshots() throws -> [SystemDNSSnapshot] {
        let prefs = try preferences()
        return try physicalServices(prefs).compactMap { service in
            guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
            let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
            let dict = proto.flatMap { SCNetworkProtocolGetConfiguration($0) }
            let data = try dict.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            return SystemDNSSnapshot(serviceID: id, original: data)
        }
    }

    public static func apply(_ snapshots: [SystemDNSSnapshot], restoring: Bool) throws {
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, true) else { throw MonitorError.message("无法锁定系统 DNS 配置") }
        defer { SCPreferencesUnlock(prefs) }
        for snapshot in snapshots {
            guard let service = SCNetworkServiceCopy(prefs, snapshot.serviceID as CFString) else { continue }
            if SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) == nil {
                guard !restoring, SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeDNS) else { continue }
            }
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
                throw MonitorError.message("无法访问网络服务 DNS 设置")
            }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let original = try snapshot.original.map {
                try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] ?? [:]
            }
            let target: [String: Any]?
            if restoring {
                // Do not overwrite DNS servers explicitly changed by the user or another app.
                let decision = restoration(current: current, original: original)
                guard decision.apply else { continue }
                target = decision.configuration
            } else {
                var updated = current
                updated["ServerAddresses"] = loopback
                target = updated
            }
            guard SCNetworkProtocolSetConfiguration(proto, target as CFDictionary?) else {
                throw MonitorError.message("更新系统 DNS 失败")
            }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw MonitorError.message("应用系统 DNS 配置失败，恢复记录已保留")
        }
    }

    public static func assertLoopbackResolvers(_ output: String) throws {
        let servers = output.split(separator: "\n").filter { $0.contains("nameserver[") }.compactMap { line in
            line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        guard !servers.isEmpty, servers.allSatisfy({ loopback.contains($0) }) else {
            throw MonitorError.message("检测到 VPN 或其他 DNS 配置覆盖，已停止 DNS 保护")
        }
    }
}
