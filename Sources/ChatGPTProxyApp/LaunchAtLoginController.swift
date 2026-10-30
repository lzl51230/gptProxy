import AppKit
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    struct Operations {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () async throws -> Void
        var openSettings: () -> Void

        static var live: Self {
            .init(status: { SMAppService.mainApp.status },
                  register: { try SMAppService.mainApp.register() },
                  unregister: { try await SMAppService.mainApp.unregister() },
                  openSettings: { SMAppService.openSystemSettingsLoginItems() })
        }
    }

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    private let operations: Operations

    init(operations: Operations = .live) {
        self.operations = operations
        refresh()
    }

    var isEnabled: Bool { status == .enabled }
    var statusText: String {
        switch status {
        case .enabled: "已开启，登录后在菜单栏运行"
        case .requiresApproval: "需要在系统设置中允许登录启动"
        case .notRegistered: "未开启"
        case .notFound: "未开启（系统尚无可用登录项）"
        @unknown default: "无法确认系统登录项状态"
        }
    }

    func refresh() { status = operations.status() }

    func setEnabled(_ enabled: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { refresh(); isWorking = false }
        refresh()
        do {
            if enabled {
                if status == .requiresApproval { operations.openSettings() }
                else if status != .enabled { try operations.register() }
            } else if status != .notRegistered {
                try await operations.unregister()
            }
        } catch { errorMessage = "无法更新登录项：\(error.localizedDescription)" }
    }

    func openSystemSettings() { operations.openSettings() }
}
