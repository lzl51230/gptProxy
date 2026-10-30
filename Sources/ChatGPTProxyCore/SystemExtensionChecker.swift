import Foundation

public enum SystemExtensionChecker {
    public static func proxyBridgeIsEnabled() async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
            process.arguments = ["list"]
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return SystemExtensionParser.proxyBridgeIsEnabled(in: String(decoding: data, as: UTF8.self))
            } catch {
                return false
            }
        }.value
    }
}
