import Foundation

public enum DNSFirewallState {
    public static func isEnabled(_ output: String) -> Bool {
        output.range(of: #"(?m)^Status:\s+Enabled\b"#, options: .regularExpression) != nil
    }

    public static func containsReference(_ token: String, output: String) throws -> Bool {
        guard let value = UInt64(token), value != 0 else { throw MonitorError.message("DNS 恢复记录中的 PF 引用无效") }
        return output.split(whereSeparator: \.isWhitespace).contains(Substring(token))
    }
}
