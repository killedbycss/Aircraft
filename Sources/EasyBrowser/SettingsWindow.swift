import AppKit
import SwiftUI

/// Настройки в отдельном окне (одно на всё приложение). Работают с вкладками того окна
/// браузера, которое было впереди, когда настройки открыли.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow?
    private weak var boundManager: TabManager?

    /// Открыть настройки на нужном разделе.
    func show(pane: SettingsPane) {
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .selectSettingsPane, object: nil, userInfo: ["pane": pane.rawValue])
        }
    }

    func show() {
        let manager = AgentBrowser.frontmostManager
        let window = self.window ?? makeWindow()
        // Привязываемся к текущему окну браузера; если оно то же — не сбрасываем открытый раздел.
        if window.contentViewController == nil || manager !== boundManager {
            boundManager = manager
            window.contentViewController = NSHostingController(rootView: SettingsWindowRoot(manager: manager) { [weak window] in
                window?.performClose(nil)
            })
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("AircraftSettingsWindow")
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Не держим ссылку на вкладки закрытого окна браузера.
        window?.contentViewController = nil
        boundManager = nil
    }
}

private struct SettingsWindowRoot: View {
    let manager: TabManager?
    let close: () -> Void
    @AppStorage("browserTheme") private var browserTheme: String = "system"

    var body: some View {
        SettingsView(onClose: close)
            .environment(manager)
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 720, minHeight: 480)
            .fontWeight(.medium)
            .preferredColorScheme(browserTheme == "dark" ? .dark : (browserTheme == "light" ? .light : nil))
    }
}

extension Notification.Name {
    static let selectSettingsPane = Notification.Name("AircraftSelectSettingsPane")
}
