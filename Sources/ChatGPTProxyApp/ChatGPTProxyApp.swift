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
            window.setContentSize(NSSize(width: 620, height: 740))
            window.contentMinSize = NSSize(width: 600, height: 700)
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
    let model: AppModel = {
#if DEBUG
        AppUpdateQA.configure()
#endif
        return AppModel()
    }()
    let login = LaunchAtLoginController()
    private lazy var mainWindow = MainWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.updates.start(model: model)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.resumeAfterWake()
            }
        }
        if LoginLaunchContext.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) {
            NSApp.setActivationPolicy(.accessory)
        } else { showMainWindow() }
    }
    private var wakeObserver: NSObjectProtocol?

    func applicationDidBecomeActive(_ notification: Notification) { login.refresh() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(); return true
    }
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Update preparation already restored the system and stopped its workers.
        // Starting another async shutdown inside terminate's nested loop can stall.
        if model.terminationReady { return .terminateNow }
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
            VStack {
                MonitorMenu(monitor: delegate.model.monitor, showMainWindow: delegate.showMainWindow)
                Button("检查更新") { delegate.showMainWindow(); delegate.model.updates.check(port: delegate.model.proxyPort) }
            }
        } label: {
            Image(nsImage: menuBarIcon)
                .renderingMode(.original)
                .accessibilityLabel("ChatGPT Proxy")
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView(model: delegate.model, login: delegate.login)
                .padding(20)
                .appTheme()
                .frame(width: 480, height: 680)
        }
        .windowResizability(.contentSize)
    }
}
