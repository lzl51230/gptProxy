import SwiftUI
import AppKit
import CoreServices
import ChatGPTProxyCore

@MainActor
final class MainWindowController {
    private var window: NSWindow?
    let model: AppModel
    init(model: AppModel) { self.model = model }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let controller = NSHostingController(rootView: ContentView(model: model).appTheme())
            let window = NSWindow(contentViewController: controller)
            window.title = "ChatGPT Proxy"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 580, height: 680))
            window.contentMinSize = NSSize(width: 520, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum LoginLaunchContext {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
            || event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let login = LaunchAtLoginController()
    private lazy var mainWindow = MainWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LoginLaunchContext.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) {
            NSApp.setActivationPolicy(.accessory)
        } else { showMainWindow() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { login.refresh() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return true
    }
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func showMainWindow() { mainWindow.show() }
}

@main
struct ChatGPTProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let menuBarIcon: NSImage = {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = false
        return icon
    }()

    var body: some Scene {
        MenuBarExtra {
            MonitorMenu(monitor: delegate.model.monitor, showMainWindow: delegate.showMainWindow)
        } label: {
            Image(nsImage: menuBarIcon)
                .renderingMode(.original)
                .accessibilityLabel("ChatGPT Proxy")
        }
        Settings {
            SettingsView(model: delegate.model, login: delegate.login)
                .padding(20)
                .appTheme()
                .frame(width: 480, height: 680)
        }
        .windowResizability(.contentSize)
    }
}

private struct MonitorMenu: View {
    @ObservedObject var monitor: AutoSwitchMonitor
    let showMainWindow: () -> Void
    var body: some View {
        Text(monitor.status)
        Text(monitor.currentNode)
        if let latency = monitor.latency { Text("Google HEAD：\(latency)ms") }
        Text(monitor.lastSwitch)
        Divider()
        Button("打开主窗口", action: showMainWindow)
        SettingsLink { Text("设置…") }
        Button(monitor.paused ? "恢复监控" : "暂停监控") { monitor.togglePaused() }
        Button("退出") { monitor.stop(); NSApp.terminate(nil) }
    }
}
