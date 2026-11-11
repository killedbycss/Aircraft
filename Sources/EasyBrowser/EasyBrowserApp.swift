import SwiftUI
import AppKit

@MainActor
final class AircraftAppDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    private var modifierMonitor: Any?
    private var commandShiftArmed = false
    private var additionalWindows: [NSWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = ""
        }
        // ⌘⇧ (без других клавиш) — Spotlight с URL текущей вкладки.
        // Срабатывает при отпускании, если между нажатием и отпусканием не было
        // другой клавиши, чтобы не мешать сочетаниям вроде ⌘⇧N.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.command, .shift] {
                self.commandShiftArmed = true
            } else if modifiers.isEmpty || modifiers == [.command] || modifiers == [.shift] {
                // Отпущена одна из клавиш ⌘/⇧ — сочетание завершено.
                if self.commandShiftArmed {
                    self.commandShiftArmed = false
                    NotificationCenter.default.post(name: .toggleCurrentURLSpotlight, object: NSApp.keyWindow)
                }
            } else {
                self.commandShiftArmed = false
            }
            return event
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.commandShiftArmed = false
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let target = NSApp.keyWindow

            if key == "w", modifiers == [.command] {
                NotificationCenter.default.post(name: .closeActiveTab, object: target)
                return nil
            }
            // ⌘1…⌘8 — вкладка по номеру, ⌘9 — последняя вкладка.
            if modifiers == [.command], let key, key.count == 1, let number = Int(key), (1...9).contains(number) {
                NotificationCenter.default.post(name: .selectTabByNumber, object: target, userInfo: ["number": number])
                return nil
            }
            // ⌘T — новая пустая вкладка с открытым Spotlight.
            // keyCode 17 — физическая клавиша T, чтобы работало и в русской раскладке.
            if key == "t" || event.keyCode == 17, modifiers == [.command] {
                NotificationCenter.default.post(name: .createHomeTab, object: target)
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
            // F12 (keyCode 111) или ⌥⌘I — Web Inspector. Работает в любой раскладке.
            let inspectorModifiers = modifiers.subtracting([.function, .numericPad])
            if (event.keyCode == 111 && inspectorModifiers.isEmpty)
                || (event.keyCode == 34 && inspectorModifiers == [.command, .option]) {
                NotificationCenter.default.post(name: .toggleWebInspector, object: target)
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
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
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

                Divider()

                Button("Инструменты разработчика (F12)") {
                    NotificationCenter.default.post(name: .toggleWebInspector, object: NSApp.keyWindow)
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
    static let modStorageDidChange = Notification.Name("ModStorageDidChange")
    static let selectTabByNumber = Notification.Name("SelectTabByNumber")
    static let toggleCurrentURLSpotlight = Notification.Name("ToggleCurrentURLSpotlight")
    static let showEmptySpotlight = Notification.Name("ShowEmptySpotlight")
    static let createHomeTab = Notification.Name("CreateHomeTab")
    static let createHomeTabWithoutSpotlight = Notification.Name("CreateHomeTabWithoutSpotlight")
    static let resetResources = Notification.Name("ResetResources")
    static let reloadActiveTab = Notification.Name("ReloadActiveTab")
    static let goBack = Notification.Name("GoBack")
    static let goForward = Notification.Name("GoForward")
}
    static let toggleWebInspector = Notification.Name("ToggleWebInspector")
