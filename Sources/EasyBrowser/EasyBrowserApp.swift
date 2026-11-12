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

            // В окне настроек браузерные сочетания не действуют, ⌘W закрывает окно.
            if let target, target === SettingsWindowController.shared.window {
                if key == "w", modifiers == [.command] {
                    target.performClose(nil)
                    return nil
                }
                return event
            }
            if key == "w", modifiers == [.command] {
                NotificationCenter.default.post(name: .closeActiveTab, object: target)
                return nil
            }
            if let command = self?.browserCommand(for: event, modifiers: modifiers, window: target) {
                if command == "newIncognitoWindow" {
                    self?.openNewBrowserWindow(incognito: true)
                } else {
                    NotificationCenter.default.post(name: .browserCommand, object: target, userInfo: ["command": command])
                }
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
            if event.keyCode == 45, modifiers == [.command, .shift] {
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
        AgentServer.shared.applySettings()
        try? FileManager.default.removeItem(at: AircraftPaths.viewerCache)
        // Остальные окна прошлой сессии (первое уже открыл WindowGroup).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            for id in SessionStore.shared.unclaimedWindowIDs {
                self?.openNewBrowserWindow(restoreID: id)
            }
            self?.openPendingURLs()
        }
        TabArchiver.shared.start()
    }

    private var pendingURLs: [URL] = []
    private var launched = false

    /// Ссылки и файлы из других приложений и Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        if launched { openPendingURLs() }
    }

    private func openPendingURLs() {
        launched = true
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        let manager = AgentBrowser.frontmostManager(includingIncognito: false)
        guard let manager else { return }
        manager.openFiles(urls)
        manager.hostWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewBrowserWindow(restoreID: SessionStore.shared.unclaimedWindowIDs.first) }
        return false
    }

    /// Команды браузера по физическим клавишам (работают в любой раскладке).
    private func browserCommand(for event: NSEvent, modifiers: NSEvent.ModifierFlags, window: NSWindow?) -> String? {
        let mods = modifiers.subtracting([.function, .numericPad, .capsLock])
        let code = event.keyCode
        switch (code, mods) {
        case (3, [.command]): return "find"                       // ⌘F
        case (5, [.command]): return "findNext"                   // ⌘G
        case (5, [.command, .shift]): return "findPrevious"       // ⌘⇧G
        case (17, [.command, .shift]): return "reopenClosedTab"   // ⌘⇧T
        case (24, [.command]), (24, [.command, .shift]), (69, [.command]): return "zoomIn"   // ⌘= / ⌘+
        case (27, [.command]), (78, [.command]): return "zoomOut"  // ⌘−
        case (29, [.command]), (82, [.command]): return "zoomReset" // ⌘0
        case (8, [.command, .shift]): return "copyURL"            // ⌘⇧C
        case (46, [.command, .shift]): return "toggleMute"        // ⌘⇧M
        case (2, [.command]): return "addBookmark"                // ⌘D
        case (11, [.command, .shift]): return "showBookmarks"     // ⌘⇧B
        case (16, [.command]): return "showHistory"               // ⌘Y
        case (35, [.command, .shift]): return "newIncognitoWindow" // ⌘⇧P
        case (31, [.command]): return "openFile"                  // ⌘O
        case (15, [.command, .shift]): return "toggleReader"      // ⌘⇧R
        case (123, [.option]), (124, [.option]):
            guard !Self.isEditingText(in: window) else { return nil }
            return code == 123 ? "previousTab" : "nextTab"
        default:
            break
        }
        // ⌃1…⌃9 — профиль по номеру.
        if mods == [.control], let characters = event.charactersIgnoringModifiers, let number = Int(characters), (1...9).contains(number) {
            return "profile\(number)"
        }
        if mods == [.control], let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: Int(code)) {
            return "profile\(index + 1)"
        }
        return nil
    }

    /// Курсор стоит в поле ввода (Spotlight, поле на странице) — ⌥← / ⌥→ двигают его по словам.
    private static func isEditingText(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window.firstResponder is NSText { return true }
        guard let manager = AgentBrowser.manager(for: window) else { return false }
        return manager.activePageHasEditableFocus
    }

    func applicationDidUpdate(_ notification: Notification) {
        removeSystemCloseWindowShortcut()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionStore.shared.isTerminating = true
        SessionStore.shared.flush()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.isTerminating = true
        SessionStore.shared.flush()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        AgentServer.shared.stop()
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

    /// Новое окно: пустое, восстановленное из сессии или инкогнито.
    func openNewBrowserWindow(restoreID: UUID? = nil, incognito: Bool = false, profileID: UUID? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let profile = profileID ?? (incognito ? nil : AgentBrowser.frontmostManager(includingIncognito: false)?.profileID)
        window.contentViewController = NSHostingController(rootView: BrowserWindowRoot(
            mode: restoreID.map { .restore($0) } ?? (incognito ? .incognito : .fresh(profile))))
        if incognito { window.title = "Инкогнито" }
        window.center()
        if let key = NSApp.keyWindow, key !== SettingsWindowController.shared.window {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
        }
        let controller = NSWindowController(window: window)
        additionalWindows.append(controller)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.additionalWindows.removeAll { $0.window === window }
            }
        }
    }
}

/// Как открыть окно браузера.
enum BrowserWindowMode {
    /// Первое окно приложения: берёт окно из прошлой сессии.
    case launch
    case restore(UUID)
    case fresh(UUID?)
    case incognito
}

/// TabManager создаётся лениво один раз: SwiftUI может пересоздавать структуру окна.
@MainActor
final class BrowserWindowModel {
    let mode: BrowserWindowMode
    init(mode: BrowserWindowMode) { self.mode = mode }

    lazy var manager: TabManager = {
        switch mode {
        case .launch:
            return TabManager(window: SessionStore.shared.claimWindow(), incognito: false)
        case .restore(let id):
            return TabManager(window: SessionStore.shared.claimWindow(id: id), incognito: false)
        case .fresh(let profileID):
            return TabManager(window: nil, incognito: false, profileID: profileID)
        case .incognito:
            return TabManager(window: nil, incognito: true)
        }
    }()
}

struct BrowserWindowRoot: View {
    @State private var model: BrowserWindowModel

    init(mode: BrowserWindowMode = .launch) {
        _model = State(initialValue: BrowserWindowModel(mode: mode))
    }

    var body: some View {
        BrowserShellView()
            .environment(model.manager)
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
                Button("Новое окно") { (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Новое окно инкогнито") { (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow(incognito: true) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Открыть файл…") { browserCommand("openFile") }
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("История") {
                Button("Показать историю") { browserCommand("showHistory") }
                    .keyboardShortcut("y", modifiers: [.command])
                Button("Вернуть закрытую вкладку") { browserCommand("reopenClosedTab") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Архив вкладок") { browserCommand("showArchive") }
            }

            CommandMenu("Закладки") {
                Button("Добавить в закладки…") { browserCommand("addBookmark") }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("Показать закладки") { browserCommand("showBookmarks") }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Добавить сайт в Dock…") { browserCommand("addToDock") }
            }

            CommandGroup(after: .textEditing) {
                Button("Найти на странице…") { browserCommand("find") }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Найти следующее") { browserCommand("findNext") }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Найти предыдущее") { browserCommand("findPrevious") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") {
                    SettingsWindowController.shared.show()
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
                Divider()
                Button("Увеличить") { browserCommand("zoomIn") }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("Уменьшить") { browserCommand("zoomOut") }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Реальный размер") { browserCommand("zoomReset") }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
                Button("Режим чтения") { browserCommand("toggleReader") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
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

                Button("Скопировать ссылку") { browserCommand("copyURL") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Выключить/включить звук") { browserCommand("toggleMute") }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Картинка в картинке") { browserCommand("pictureInPicture") }
                Button("Новая папка") { browserCommand("newFolder") }

                Divider()

                Button("Предыдущая вкладка") { browserCommand("previousTab") }
                Button("Следующая вкладка") { browserCommand("nextTab") }

                Divider()

                Button("Назад") {
                    NotificationCenter.default.post(name: .goBack, object: NSApp.keyWindow)
                }

                Button("Вперёд") {
                    NotificationCenter.default.post(name: .goForward, object: NSApp.keyWindow)
                }

                Divider()

                Button("Инструменты разработчика (F12)") {
                    NotificationCenter.default.post(name: .toggleWebInspector, object: NSApp.keyWindow)
                }

                Button("Скрыть элемент на странице…") {
                    if NSApp.keyWindow === SettingsWindowController.shared.window {
                        ElementPicker.startInFrontmostWindow()
                    } else {
                        NotificationCenter.default.post(name: .startElementPicker, object: NSApp.keyWindow)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }
        }
    }
}

/// Команда для окна, которое сейчас впереди.
@MainActor
func browserCommand(_ command: String) {
    NotificationCenter.default.post(name: .browserCommand, object: NSApp.keyWindow, userInfo: ["command": command])
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
    static let toggleWebInspector = Notification.Name("ToggleWebInspector")
    static let startElementPicker = Notification.Name("StartElementPicker")
    /// Команда браузера для окна: userInfo["command"].
    static let browserCommand = Notification.Name("AircraftBrowserCommand")
}
