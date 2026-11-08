import AppKit
import SwiftUI
import ChatGPTProxyCore

struct MonitorMenu: View {
    @ObservedObject var monitor: AutoSwitchMonitor
    let showMainWindow: () -> Void
    @Environment(\.openSettings) private var openSettings
    @State private var panelWindow = MonitorPanelWindow()

    var body: some View {
        MonitorMenuContent(
            snapshot: MonitorMenuSnapshot(monitor),
            showMainWindow: { panelWindow.dismiss(); showMainWindow() },
            showSettings: { panelWindow.dismiss(); openSettings(); NSApp.activate(ignoringOtherApps: true) },
            togglePaused: monitor.togglePaused,
            quit: { panelWindow.dismiss(); monitor.stop(); NSApp.terminate(nil) }
        )
        .appTheme()
        .frame(width: 440, height: 346)
        .background(MonitorPanelWindowReader(panel: panelWindow))
        .onExitCommand { panelWindow.dismiss() }
    }
}

struct MonitorMenuSnapshot {
    var status: String
    var currentNode: String
    var latency: Int?
    var connectionSeconds: Double
    var consecutiveFailures: Int
    var phase: MonitorPhase
    var disconnectReason: String?
    var lastSwitch: String
    var paused: Bool
}

extension MonitorMenuSnapshot {
    @MainActor
    init(_ monitor: AutoSwitchMonitor) {
        self.init(status: monitor.status, currentNode: monitor.currentNode, latency: monitor.latency,
                  connectionSeconds: monitor.connectionSeconds, consecutiveFailures: monitor.consecutiveFailures,
                  phase: monitor.phase, disconnectReason: monitor.disconnectReason,
                  lastSwitch: monitor.lastSwitch, paused: monitor.paused)
    }
}

struct MonitorMenuContent: View {
    let snapshot: MonitorMenuSnapshot
    let showMainWindow: () -> Void
    let showSettings: () -> Void
    let togglePaused: () -> Void
    let quit: () -> Void
    @Environment(\.selectedAppTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                statusRow(snapshot.status, prominent: true)
                statusRow(snapshot.currentNode)
                statusRow("Codex 心跳：" + (snapshot.latency.map { "\($0)ms" } ?? "—"))
                statusRow("已验证 \(Int(snapshot.connectionSeconds)) 秒 · 未满 60 秒失败 \(snapshot.consecutiveFailures)/2")
                statusRow(snapshot.phase == .validating
                          ? "候选长连接验收：\(Int(snapshot.connectionSeconds))/10 秒" : "候选长连接验收：—")
                statusRow("上次断线：" + (snapshot.disconnectReason ?? "无"))
                statusRow("上次切换：" + snapshot.lastSwitch)
            }
            Divider()
            VStack(spacing: 2) {
                action("打开主窗口", id: "monitor.open", perform: showMainWindow)
                action("设置…", id: "monitor.settings", perform: showSettings)
                action(snapshot.paused ? "恢复监控" : "暂停监控", id: "monitor.pause", perform: togglePaused)
                action("退出", id: "monitor.quit", perform: quit)
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private func statusRow(_ text: String, prominent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? theme.foreground : theme.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
            .help(text)
    }

    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title) }
            .buttonStyle(MonitorMenuButtonStyle())
            .accessibilityIdentifier(id)
    }
}

private struct MonitorMenuButtonStyle: ButtonStyle {
    @Environment(\.selectedAppTheme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .background(theme.accent.opacity(configuration.isPressed ? 0.4 : hovering ? 0.22 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

@MainActor
private final class MonitorPanelWindow {
    weak var window: NSWindow?
    func dismiss() { window?.orderOut(nil) }
}

private struct MonitorPanelWindowReader: NSViewRepresentable {
    let panel: MonitorPanelWindow
    func makeNSView(context: Context) -> ReaderView { ReaderView(panel: panel) }
    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let panel: MonitorPanelWindow
        init(panel: MonitorPanelWindow) { self.panel = panel; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            panel.window = window
        }
    }
}
