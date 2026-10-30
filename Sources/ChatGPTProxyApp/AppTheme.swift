import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "appearanceTheme"

    case system
    case darkModern
    case lightModern
    case monokai
    case solarizedDark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .darkModern: "Dark Modern · 现代深色"
        case .lightModern: "Light Modern · 现代浅色"
        case .monokai: "Monokai"
        case .solarizedDark: "Solarized Dark · 深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .lightModern: .light
        case .darkModern, .monokai, .solarizedDark: .dark
        }
    }

    // Based on the workbench colors in microsoft/vscode's built-in themes.
    var background: Color {
        switch self {
        case .system: Color(nsColor: .windowBackgroundColor)
        case .darkModern: Color(rgb: 0x1F1F1F)
        case .lightModern: Color(rgb: 0xFFFFFF)
        case .monokai: Color(rgb: 0x272822)
        case .solarizedDark: Color(rgb: 0x002B36)
        }
    }

    var foreground: Color {
        switch self {
        case .system: .primary
        case .darkModern: Color(rgb: 0xCCCCCC)
        case .lightModern: Color(rgb: 0x3B3B3B)
        case .monokai: Color(rgb: 0xF8F8F2)
        case .solarizedDark: Color(rgb: 0x93A1A1)
        }
    }

    var accent: Color {
        switch self {
        case .system: Color(nsColor: .controlAccentColor)
        case .darkModern: Color(rgb: 0x0078D4)
        case .lightModern: Color(rgb: 0x005FB8)
        case .monokai: Color(rgb: 0x75715E)
        case .solarizedDark: Color(rgb: 0x268BD2)
        }
    }

    var secondary: Color {
        switch self {
        case .system: .secondary
        case .darkModern: Color(rgb: 0x9D9D9D)
        case .lightModern: Color(rgb: 0x616161)
        case .monokai: Color(rgb: 0xB5B5AB)
        case .solarizedDark: Color(rgb: 0x93A1A1)
        }
    }

    var titleBar: NSColor {
        switch self {
        case .system: .windowBackgroundColor
        case .darkModern: NSColor(Color(rgb: 0x181818))
        case .lightModern: NSColor(Color(rgb: 0xF8F8F8))
        case .monokai: NSColor(Color(rgb: 0x1E1F1C))
        case .solarizedDark: NSColor(Color(rgb: 0x00212B))
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

private struct AppThemeModifier: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    func body(content: Content) -> some View {
        content
            .environment(\.selectedAppTheme, theme)
            .foregroundStyle(theme.foreground)
            .tint(theme.accent)
            .accentColor(theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.background.ignoresSafeArea())
            .background(ThemeWindowAppearance(theme: theme))
            .preferredColorScheme(theme.colorScheme)
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.system
}

extension EnvironmentValues {
    var selectedAppTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    func appTheme() -> some View { modifier(AppThemeModifier()) }
}

// NSHostingController owns the main window, so update AppKit appearance too.
// Applying this per window leaves the menu bar under macOS appearance control.
struct ThemeWindowAppearance: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> AppearanceView { AppearanceView(theme: theme) }

    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.theme = theme
        nsView.applyAppearance()
    }

    final class AppearanceView: NSView {
        var theme: AppTheme

        init(theme: AppTheme) {
            self.theme = theme
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            guard let window else { return }
            switch theme.colorScheme {
            case .dark: window.appearance = NSAppearance(named: .darkAqua)
            case .light: window.appearance = NSAppearance(named: .aqua)
            default: window.appearance = nil
            }
            window.titlebarAppearsTransparent = theme != .system
            window.backgroundColor = theme.titleBar
        }
    }
}
