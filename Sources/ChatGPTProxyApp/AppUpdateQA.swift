#if DEBUG
import AppKit
import Foundation
import ChatGPTProxyCore

/// Opt-in desktop acceptance harness. Absent from release builds.
@MainActor
enum AppUpdateQA {
    static var root: URL? { ProcessInfo.processInfo.environment["GPTPROXY_UPDATE_QA"].map { URL(fileURLWithPath: $0) } }
    static var enabled: Bool { root != nil }
    static var scenario: String { ProcessInfo.processInfo.environment["GPTPROXY_UPDATE_QA_CASE"] ?? "running" }
    static func configure() {
        guard enabled else { return }
        // Argument-domain overrides are process-local and survive the updater restart
        // through this harness, without editing the user's saved preferences.
        UserDefaults.standard.setVolatileDomain([
            "monitorPaused": true, "dnsProtectionPaused": scenario != "running",
            "repairClashDNSDuringProtection": true
        ], forName: UserDefaults.argumentDomain)
    }
    static func processes() -> [[String: Any]] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .sorted { $0.processIdentifier < $1.processIdentifier }
            .map { ["pid": Int($0.processIdentifier), "start": $0.launchDate?.timeIntervalSince1970 ?? 0] }
    }
    static func settings() -> String {
        let domain = UserDefaults.standard.persistentDomain(forName: "local.alex.chatgpt-proxy") ?? [:]
        return (try? PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0).base64EncodedString()) ?? ""
    }
    static func write(_ name: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root!.appendingPathComponent(name), options: .atomic)
    }
    static func capture(_ name: String) {
        guard let view = NSApp.windows.first(where: { $0.title == "ChatGPT Proxy" })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: root!.appendingPathComponent(name + ".png"))
    }
    static func wait(seconds: Int, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while !condition() {
            guard Date() < deadline else { throw MonitorError.message("Desktop QA timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    static func run(updates: AppUpdates, model: AppModel) async {
        guard let root else { return }
        do {
            if scenario == "running", !CommandLine.arguments.contains("--update-restart") {
                try await wait(seconds: 90) { !model.isBusy }
                await model.enableDNSProtection()
            }
            try await wait(seconds: 90) {
                !model.isBusy && (scenario == "running" ? model.cli.isReady && model.dns.status.isEnabled : model.dns.status.phase == .disabled)
            }
            guard model.monitor.paused else { throw MonitorError.message("Monitor pause was not preserved") }
            let restarted = CommandLine.arguments.contains("--update-restart")
            if !restarted {
                if scenario == "running", processes().isEmpty { throw MonitorError.message("Open ChatGPT before running acceptance") }
                try write("before.json", ["processes": processes(), "settings": settings(), "protected": model.dns.status.isEnabled])
                updates.check(port: model.proxyPort)
                try await wait(seconds: 30) { !updates.busy }
                guard updates.release?.version == "2.4.0" else { throw MonitorError.message(updates.status) }
                capture("before")
                updates.install(model: model)
                try await wait(seconds: 360) { !updates.busy }
                guard scenario == "cancel", AppUpdates.version == "2.3.9",
                      updates.status.hasPrefix("更新未完成") else { throw MonitorError.message("Did not restart: " + updates.status) }
            } else if AppUpdates.version != "2.4.0" { throw MonitorError.message("Wrong version after restart") }
            let before = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("before.json"))) as! [String: Any]
            guard NSArray(array: processes()).isEqual(to: before["processes"] as! [Any]) else { throw MonitorError.message("ChatGPT process identity changed") }
            let saved = try PropertyListSerialization.propertyList(from: Data(base64Encoded: before["settings"] as! String)!, format: nil) as! NSDictionary
            let current = UserDefaults.standard.persistentDomain(forName: "local.alex.chatgpt-proxy") ?? [:]
            guard saved.isEqual(to: current) else { throw MonitorError.message("Saved preferences changed") }
            capture("after")
            try write("result.json", ["success": true, "version": AppUpdates.version, "uid": Int(getuid()),
                                      "protected": model.dns.status.isEnabled, "monitorPaused": model.monitor.paused,
                                      "processes": processes(), "status": updates.status])
        } catch { try? write("result.json", ["success": false, "error": String(describing: error), "phase": model.phase.message, "update": updates.status]) }
        // Normal termination exercises DNS/Clash restoration and stops the test adapter.
        try? await Task.sleep(for: .seconds(3))
        await model.shutdown()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
#endif
