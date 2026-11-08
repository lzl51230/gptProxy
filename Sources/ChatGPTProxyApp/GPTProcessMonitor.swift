import AppKit
import Combine
import ChatGPTProxyCore

@MainActor
final class GPTProcessMonitor: ObservableObject {
    @Published private(set) var processIdentifiers: [pid_t] = []
    var isRunning: Bool { !processIdentifiers.isEmpty }
    private let scan: () -> [pid_t]
    private var observers: [NSObjectProtocol] = []
    private var polling: Task<Void, Never>?

    init(scan: @escaping () -> [pid_t] = {
        ChatGPTApplicationCompatibility.runningBundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { !$0.isTerminated }.map(\.processIdentifier)
        }
    }) { self.scan = scan }

    func refresh() {
        let current = Array(Set(scan())).sorted()
        if current != processIdentifiers { processIdentifiers = current }
    }

    func start() {
        stop()
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        polling?.cancel(); polling = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
}
