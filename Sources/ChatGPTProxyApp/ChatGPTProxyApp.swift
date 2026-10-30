import SwiftUI
import AppKit
import ChatGPTProxyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}


@main
struct ChatGPTProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ChatGPT Proxy", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 520)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("ChatGPT Proxy", systemImage: "network") {
            MonitorMenu(monitor: model.monitor)
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 420)
                .padding(20)
        }
    }
}

private struct MonitorMenu: View {
    @ObservedObject var monitor: AutoSwitchMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(monitor.status)
        Text(monitor.currentNode)
        if let latency = monitor.latency { Text("Google HEAD：\(latency)ms") }
        Text(monitor.lastSwitch)
        Divider()
        Button("打开主窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(monitor.paused ? "恢复监控" : "暂停监控") { monitor.togglePaused() }
        Button("退出") { monitor.stop(); NSApp.terminate(nil) }
    }
}
