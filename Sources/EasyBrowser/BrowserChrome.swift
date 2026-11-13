import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Команды браузера

/// Команды из меню и сочетаний клавиш для конкретного окна.
@MainActor
enum BrowserCommands {
    static func perform(_ command: String, in manager: TabManager, presentSpotlight: (String) -> Void) {
        switch command {
        case "find": manager.showFindBar()
        case "findNext", "findPrevious":
            if manager.findBar.isVisible { manager.find(forward: command == "findNext") } else { manager.showFindBar() }
        case "reopenClosedTab": manager.reopenClosedTab()
        case "zoomIn": manager.zoom(by: 1)
        case "zoomOut": manager.zoom(by: -1)
        case "zoomReset": manager.resetZoom()
        case "copyURL": manager.copyActiveURL()
        case "toggleMute": manager.toggleMute()
        case "pictureInPicture": manager.togglePictureInPicture()
        case "addBookmark":
            if manager.activeTab?.url != nil { manager.bookmarkEditorVisible.toggle() } else { NSSound.beep() }
        case "showBookmarks": LibraryWindow.show(.bookmarks, for: manager)
        case "showHistory": LibraryWindow.show(.history, for: manager)
        case "showArchive": LibraryWindow.show(.archive, for: manager)
        case "showAccounts": LibraryWindow.show(.accounts, for: manager)
        case "showDownloads": LibraryWindow.show(.downloads, for: manager)
        case "stopLoading": if manager.activeTab?.isLoading == true { manager.reloadActiveTab() }
        case "previousTab": manager.selectAdjacentTab(offset: -1)
        case "nextTab": manager.selectAdjacentTab(offset: 1)
        case "openFile": openFilePanel(for: manager)
        case "toggleReader": manager.toggleReaderMode()
        case "newFolder": manager.createFolder()
        case "addToDock": WebAppMaker.addActiveTab(of: manager)
        default:
            if command.hasPrefix("profile"), let number = Int(command.dropFirst("profile".count)) {
                let profiles = ProfileStore.shared.profiles
                guard profiles.indices.contains(number - 1), !manager.isIncognito else {
                    NSSound.beep()
                    return
                }
                manager.switchProfile(to: profiles[number - 1].id)
            }
        }
    }

    static func openFilePanel(for manager: TabManager) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .html, .plainText, .image, .svg,
                                     UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            manager.openFiles(panel.urls)
        }
        if let window = manager.hostWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    static func openDroppedFiles(_ providers: [NSItemProvider], in manager: TabManager) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in manager.openFiles([url]) }
            }
        }
    }
}

// MARK: - Содержимое вкладки

/// Страница, PDF-просмотрщик или Markdown (Markdown рисуется в WebView).
struct PageContent: View {
    let tab: TabModel
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        switch tab.content {
        case .pdf(let file):
            PDFViewerView(file: file, tabID: tab.id, sourceURL: tab.url)
        default:
            WebContainerView(activeWebView: tabManager.webView(for: tab.id))
        }
    }
}

/// Поиск, запросы разрешений, уведомления и поповер закладки поверх страницы.
struct PageOverlays: View {
    let tab: TabModel
    @Environment(TabManager.self) private var tabManager: TabManager

    private var isActive: Bool { tab.id == tabManager.activeTabID }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(tabManager.permissionRequests.filter { $0.tabID == tab.id }) { request in
                PermissionBanner(request: request)
            }
            if let offer = tabManager.appLinkOffers[tab.id] {
                AppLinkBanner(offer: offer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(alignment: .top) {
                Spacer()
                if isActive, tabManager.bookmarkEditorVisible, let url = tab.url {
                    BookmarkEditor(url: url, title: tab.title)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if isActive, tabManager.findBar.isVisible {
                    FindBarView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.trailing, 14)
            .padding(.top, 8)
            if isActive, let toast = tabManager.toast {
                ToastView(message: toast)
                    .id(toast.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.18), value: tabManager.findBar.isVisible)
        .animation(.easeOut(duration: 0.18), value: tabManager.appLinkOffers[tab.id])
        .animation(.easeOut(duration: 0.18), value: tabManager.toast?.id)
        .animation(.easeOut(duration: 0.18), value: tabManager.bookmarkEditorVisible)
    }
}

// MARK: - Поиск на странице

struct FindBarView: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @FocusState private var focused: Bool
    @State private var query = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Найти на странице", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit {
                    let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                    tabManager.find(forward: !backwards)
                    focused = true
                }
                .onExitCommand { tabManager.closeFindBar() }
                .onChange(of: query) { _, value in tabManager.updateFind(query: value) }
            Text(counter)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(tabManager.findBar.total == 0 && !query.isEmpty ? Color.red : .secondary)
                .frame(minWidth: 52, alignment: .trailing)
            Divider().frame(height: 14)
            Button { tabManager.find(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Предыдущее (⌘⇧G)")
            Button { tabManager.find(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Следующее (⌘G)")
            Button { tabManager.closeFindBar() } label: { Image(systemName: "xmark") }
                .help("Закрыть (Esc)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .glassOr(RoundedRectangle(cornerRadius: 9), interactive: true) { Rectangle().fill(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 9)) }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .onAppear {
            query = tabManager.findBar.query
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: tabManager.findBar.focusToken) { _, _ in focused = true }
    }

    private var counter: String {
        guard !query.isEmpty else { return "" }
        let state = tabManager.findBar
        if state.total == 0 { return "Нет" }
        return state.current > 0 ? "\(state.current) из \(state.total)" : "\(state.total)"
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        Label(message.text, systemImage: message.symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassOr(Capsule(), interactive: true) { Rectangle().fill(.regularMaterial).clipShape(Capsule()) }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            .allowsHitTesting(false)
    }
}

// MARK: - Профили в панели вкладок

/// Переключатель профилей внизу панели вкладок (⌃1…⌃9). В инкогнито — пометка окна.
struct ProfileBar: View {
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        SidebarFooter()
            .background(tabManager.isIncognito ? Color.purple.opacity(0.14) : Color.clear)
    }

    static func createProfile(in tabManager: TabManager) {
        let store = ProfileStore.shared
        let alert = NSAlert()
        alert.messageText = "Новый профиль"
        alert.informativeText = "У профиля свои cookie, история, закладки и вкладки."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Работа"
        alert.accessoryView = field
        alert.addButton(withTitle: "Создать")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let profile = store.create(name: name.isEmpty ? "Профиль \(store.profiles.count + 1)" : name)
        tabManager.switchProfile(to: profile.id)
    }
}
