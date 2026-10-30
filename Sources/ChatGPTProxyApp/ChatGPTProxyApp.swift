import SwiftUI

@main
struct ChatGPTProxyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 520)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
                .frame(width: 420)
                .padding(20)
        }
    }
}
