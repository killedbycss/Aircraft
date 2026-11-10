import SwiftUI
import AppKit

@MainActor
final class AircraftAppDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    private var additionalWindows: [NSWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = ""
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let target = NSApp.keyWindow

            if key == "w", modifiers == [.command] {
                NotificationCenter.default.post(name: .closeActiveTab, object: target)
                return nil
            }
            if key == "t", modifiers == [.command] {
                NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: target)
                return nil
            }
            if key == "r", modifiers == [.command] {
                NotificationCenter.default.post(name: .reloadActiveTab, object: target)
                return nil
            }
            if key == "[", modifiers == [.command] {
                NotificationCenter.default.post(name: .goBack, object: target)
                return nil
            }
            if key == "]", modifiers == [.command] {
                NotificationCenter.default.post(name: .goForward, object: target)
                return nil
            }
            if key == "n", modifiers == [.command, .shift] {
                self?.openNewBrowserWindow()
                return nil
            }
            if key == "s", modifiers == [.control, .option] {
                NotificationCenter.default.post(name: .toggleSidebar, object: target)
                return nil
            }
            if self?.matchesResourceReset(key: key, modifiers: modifiers) == true {
                NotificationCenter.default.post(name: .resetResources, object: target)
                return nil
            }
            return event
        }
        DispatchQueue.main.async { [weak self] in
            self?.removeSystemCloseWindowShortcut()
        }
    }

    func applicationDidUpdate(_ notification: Notification) {
        removeSystemCloseWindowShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }

    private func matchesResourceReset(key: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard key == "r" else { return false }
        switch UserDefaults.standard.string(forKey: "resourceResetShortcut") ?? "control-option-r" {
        case "control-option-shift-r": return modifiers == [.control, .option, .shift]
        case "command-option-shift-r": return modifiers == [.command, .option, .shift]
        default: return modifiers == [.control, .option]
        }
    }

    private func removeSystemCloseWindowShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        clearCommandW(in: mainMenu)
    }

    private func clearCommandW(in menu: NSMenu) {
        for item in menu.items {
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            if item.keyEquivalent.lowercased() == "w", modifiers == [.command] {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
            if let submenu = item.submenu { clearCommandW(in: submenu) }
        }
    }

    private func openNewBrowserWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: BrowserWindowRoot())
        window.center()
        let controller = NSWindowController(window: window)
        additionalWindows.append(controller)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

struct BrowserWindowRoot: View {
    @State private var tabManager = TabManager()

    var body: some View {
        BrowserShellView()
            .environment(tabManager)
    }
}

/// Точка входа в macOS WebKit Browser MVP
@main
struct EasyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AircraftAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserWindowRoot()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая вкладка") {
                    NotificationCenter.default.post(name: .createHomeTab, object: NSApp.keyWindow)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") {
                    NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .toolbar) {
                Button("Адрес или поиск") {
                    NotificationCenter.default.post(name: .focusLocation, object: NSApp.keyWindow)
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Показать/скрыть вкладки") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: NSApp.keyWindow)
                }
                .keyboardShortcut("s", modifiers: [.control, .option])
            }

            CommandMenu("Вкладки") {
                Button("Spotlight текущей вкладки") {
                    NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: NSApp.keyWindow)
                }

                Button("Новая вкладка") {
                    NotificationCenter.default.post(name: .createHomeTab, object: NSApp.keyWindow)
                }

                Button("Закрыть вкладку") {
                    NotificationCenter.default.post(name: .closeActiveTab, object: NSApp.keyWindow)
                }

                Button("Обновить вкладку") {
                    NotificationCenter.default.post(name: .reloadActiveTab, object: NSApp.keyWindow)
                }

                Divider()

                Button("Назад") {
                    NotificationCenter.default.post(name: .goBack, object: NSApp.keyWindow)
                }

                Button("Вперёд") {
                    NotificationCenter.default.post(name: .goForward, object: NSApp.keyWindow)
                }
            }
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("OpenSettings")
    static let focusLocation = Notification.Name("FocusLocation")
    static let toggleSidebar = Notification.Name("ToggleSidebar")
    static let showWorkspace = Notification.Name("ShowWorkspace")
    static let closeActiveTab = Notification.Name("CloseActiveTab")
    static let showCurrentURLSpotlight = Notification.Name("ShowCurrentURLSpotlight")
    static let showEmptySpotlight = Notification.Name("ShowEmptySpotlight")
    static let createHomeTab = Notification.Name("CreateHomeTab")
    static let createHomeTabWithoutSpotlight = Notification.Name("CreateHomeTabWithoutSpotlight")
    static let resetResources = Notification.Name("ResetResources")
    static let reloadActiveTab = Notification.Name("ReloadActiveTab")
    static let goBack = Notification.Name("GoBack")
    static let goForward = Notification.Name("GoForward")
}
