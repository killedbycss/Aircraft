import SwiftUI
import AppKit

/// Окно «Библиотека»: история (⌘Y), аккаунты, загрузки (⌥⌘L), закладки (⌘⇧B), архив и недавно закрытые вкладки.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case history, accounts, downloads, bookmarks, archive, closed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: "История"
            case .accounts: "Аккаунты"
            case .downloads: "Загрузки"
            case .bookmarks: "Закладки"
            case .archive: "Архив"
            case .closed: "Недавно закрытые"
            }
        }
        var symbol: String {
            switch self {
            case .history: "clock"
            case .accounts: "person.crop.circle"
            case .downloads: "arrow.down.circle"
            case .bookmarks: "bookmark"
            case .archive: "archivebox"
            case .closed: "arrow.uturn.backward"
            }
        }
    }

    private static let shared = LibraryWindow()
    private var window: NSWindow?
    private let state = LibraryState()

    static func show(_ section: Section, for manager: TabManager) {
        shared.present(section, manager: manager)
    }

    private func present(_ section: Section, manager: TabManager) {
        state.section = section
        state.manager = manager
        let window = self.window ?? makeWindow()
        window.title = manager.isIncognito ? "Библиотека — инкогнито" : "Библиотека — \(manager.profile.name)"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 380)
        window.contentViewController = NSHostingController(rootView: LibraryView(state: state))
        window.center()
        window.setFrameAutosaveName("AircraftLibraryWindow")
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        state.manager = nil
    }
}

@MainActor
@Observable
final class LibraryState {
    var section: LibraryWindow.Section = .history
    var manager: TabManager?
}

private struct LibraryView: View {
    @Bindable var state: LibraryState
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(LibraryWindow.Section.allCases, selection: Binding(
                get: { state.section },
                set: { if let value = $0 { state.section = value } })) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            if let manager = state.manager {
                Group {
                    switch state.section {
                    case .history: HistoryList(manager: manager, search: search)
                    case .accounts: AccountsList(manager: manager, search: search)
                    case .downloads: DownloadsList(search: search)
                    case .bookmarks: BookmarkList(manager: manager, search: search)
                    case .archive: ArchiveList(manager: manager, search: search)
                    case .closed: ClosedList(manager: manager)
                    }
                }
                .searchable(text: $search, placement: .toolbar, prompt: "Поиск")
                .environment(manager)
            } else {
                Text("Окно браузера закрыто").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - История

private struct HistoryList: View {
    let manager: TabManager
    let search: String

    var body: some View {
        if let history = manager.history {
            let _ = history.revision
            let entries = history.recent(matching: search)
            VStack(spacing: 0) {
                if entries.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "История пуста" : "Ничего не найдено", systemImage: "clock")
                } else {
                    List {
                        ForEach(groupedByDay(entries), id: \.0) { day, items in
                            Section(day) {
                                ForEach(items) { entry in
                                    LibraryRow(title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                               subtitle: entry.host,
                                               trailing: entry.lastVisit.formatted(date: .omitted, time: .shortened)) {
                                        open(entry.url)
                                    }
                                    .contextMenu {
                                        Button("Открыть в новой вкладке") { open(entry.url) }
                                        Button("Скопировать ссылку") { copy(entry.url) }
                                        Divider()
                                        Button("Удалить из истории") { history.delete(entry) }
                                        Button("Удалить все посещения \(entry.host)") { history.deleteHost(entry.host) }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Menu("Очистить историю") {
                        Button("За последний час") { history.delete(since: Date().addingTimeInterval(-3600)) }
                        Button("За сегодня") { history.delete(since: Calendar.current.startOfDay(for: Date())) }
                        Button("За неделю") { history.delete(since: Date().addingTimeInterval(-7 * 86400)) }
                        Divider()
                        Button("Всю историю", role: .destructive) { history.clearAll() }
                    }
                    .fixedSize()
                    Spacer()
                    Text("Показаны последние \(entries.count)").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(10)
            }
        } else {
            ContentUnavailableView("В инкогнито история не ведётся", systemImage: "eyeglasses")
        }
    }

    private func groupedByDay(_ entries: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(String, [HistoryEntry])] = []
        for entry in entries {
            let label: String
            if calendar.isDateInToday(entry.lastVisit) { label = "Сегодня" }
            else if calendar.isDateInYesterday(entry.lastVisit) { label = "Вчера" }
            else { label = entry.lastVisit.formatted(date: .complete, time: .omitted) }
            if result.last?.0 == label { result[result.count - 1].1.append(entry) } else { result.append((label, [entry])) }
        }
        return result
    }

    private func open(_ url: URL) {
        manager.createNewTab(url: url, selectNewTab: true, afterTabID: manager.activeTabID)
        manager.hostWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Закладки

private struct BookmarkList: View {
    let manager: TabManager
    let search: String
    @State private var selection: UUID?

    private var store: BookmarkStore { manager.bookmarks }

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("Закладок нет", systemImage: "bookmark")
                } description: {
                    Text("⌘D добавляет страницу в закладки. Закладки из других браузеров — в Настройки → Браузер → Импорт.")
                }
            } else if !search.isEmpty {
                List(store.search(search, limit: 200)) { match in
                    bookmarkRow(match.item, path: match.path)
                }
            } else {
                List(selection: $selection) {
                    OutlineGroup(store.items, children: \.optionalChildren) { item in
                        if item.isFolder {
                            Label(item.title, systemImage: "folder")
                                .contextMenu { folderMenu(item) }
                                .dropDestination(for: String.self) { ids, _ in
                                    ids.compactMap(UUID.init(uuidString:)).forEach { _ = store.move($0, to: item.id) }
                                    return true
                                }
                                .draggable(item.id.uuidString)
                        } else {
                            bookmarkRow(item, path: [])
                                .draggable(item.id.uuidString)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Новая папка") {
                    let parent = selection.flatMap { id in store.folders.first { $0.item.id == id }?.item.id }
                    if store.addFolder(title: "Новая папка", in: parent) == nil { NSSound.beep() }
                }
                Spacer()
                Text("Вложенность папок — до \(BookmarkStore.maxFolderDepth) уровней").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(10)
        }
    }

    private func bookmarkRow(_ item: BookmarkItem, path: [String]) -> some View {
        LibraryRow(title: item.title, subtitle: ([item.url?.host ?? ""] + path).filter { !$0.isEmpty }.joined(separator: " · "),
                   trailing: nil) {
            if let url = item.url { open(url) }
        }
        .contextMenu {
            if let url = item.url {
                Button("Открыть в новой вкладке") { open(url) }
                Button("Скопировать ссылку") { copy(url) }
            }
            Button("Переименовать…") { rename(item) }
            Menu("Переместить в") {
                Button("Корень") { store.move(item.id, to: nil) }
                ForEach(store.folders, id: \.item.id) { folder in
                    Button(String(repeating: "  ", count: folder.depth - 1) + folder.item.title) {
                        if !store.move(item.id, to: folder.item.id) { NSSound.beep() }
                    }
                }
            }
            Divider()
            Button("Удалить", role: .destructive) { store.remove(item.id) }
        }
    }

    @ViewBuilder
    private func folderMenu(_ item: BookmarkItem) -> some View {
        Button("Открыть все во вкладках") {
            for child in item.children where !child.isFolder { if let url = child.url { open(url) } }
        }
        Button("Новая папка внутри") {
            if store.addFolder(title: "Новая папка", in: item.id) == nil { NSSound.beep() }
        }
        Button("Переименовать…") { rename(item) }
        Divider()
        Button("Удалить папку", role: .destructive) { store.remove(item.id) }
    }

    private func rename(_ item: BookmarkItem) {
        let alert = NSAlert()
        alert.messageText = item.isFolder ? "Название папки" : "Закладка"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: item.isFolder ? 24 : 54))
        stack.orientation = .vertical
        let title = NSTextField(string: item.title)
        let address = NSTextField(string: item.url?.absoluteString ?? "")
        stack.addArrangedSubview(title)
        if !item.isFolder { stack.addArrangedSubview(address) }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = title
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.update(item.id, title: title.stringValue, url: URL(string: address.stringValue))
    }

    private func open(_ url: URL) {
        manager.createNewTab(url: url, selectNewTab: true, afterTabID: manager.activeTabID)
        manager.hostWindow?.makeKeyAndOrderFront(nil)
    }
}

extension BookmarkItem {
    var optionalChildren: [BookmarkItem]? { isFolder ? children : nil }
}

// MARK: - Архив и закрытые

private struct ArchiveList: View {
    let manager: TabManager
    let search: String

    var body: some View {
        if let archive = manager.archive {
            let entries = search.isEmpty ? archive.entries : archive.search(search, limit: 200)
            VStack(spacing: 0) {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Архив пуст", systemImage: "archivebox")
                    } description: {
                        Text("Сюда уходят вкладки, которые давно не открывали. Срок — в Настройки → Вкладки.")
                    }
                } else {
                    List(entries) { entry in
                        LibraryRow(title: entry.tab.title, subtitle: entry.tab.url?.host ?? "",
                                   trailing: entry.closedAt.formatted(date: .abbreviated, time: .shortened)) {
                            manager.restoreFromArchive(entry)
                            manager.hostWindow?.makeKeyAndOrderFront(nil)
                        }
                        .contextMenu {
                            Button("Вернуть вкладку") { manager.restoreFromArchive(entry) }
                            Button("Удалить из архива", role: .destructive) { archive.remove(entry.id) }
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Очистить архив", role: .destructive) { archive.clear() }.disabled(archive.entries.isEmpty)
                    Spacer()
                    Text("Хранится до \(TabArchive.limit) вкладок").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(10)
            }
        } else {
            ContentUnavailableView("В инкогнито архива нет", systemImage: "eyeglasses")
        }
    }
}

private struct ClosedList: View {
    let manager: TabManager

    var body: some View {
        if manager.closedTabs.isEmpty {
            ContentUnavailableView("Закрытых вкладок нет", systemImage: "arrow.uturn.backward")
        } else {
            List(manager.closedTabs.reversed()) { entry in
                LibraryRow(title: entry.tab.title, subtitle: entry.tab.url?.host ?? "",
                           trailing: entry.closedAt.formatted(date: .omitted, time: .shortened)) {
                    manager.reopenClosedTab(entry.id)
                    manager.hostWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

private struct LibraryRow: View {
    let title: String
    let subtitle: String
    let trailing: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: action)
        .help("Двойной клик — открыть")
    }
}

private func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

// MARK: - ⌘D

/// Поповер «Добавить в закладки»: название и папка; повторный ⌘D закрывает.
struct BookmarkEditor: View {
    let url: URL
    let title: String
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var name = ""
    @State private var folderID: UUID?
    @State private var existing: BookmarkItem?
    @FocusState private var focused: Bool

    private var store: BookmarkStore { tabManager.bookmarks }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(existing == nil ? "Добавить в закладки" : "Закладка", systemImage: existing == nil ? "bookmark" : "bookmark.fill")
                .font(.system(size: 12, weight: .semibold))
            TextField("Название", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if existing == nil {
                Picker("Папка", selection: $folderID) {
                    Text("Закладки").tag(UUID?.none)
                    ForEach(store.folders, id: \.item.id) { folder in
                        Text(String(repeating: "   ", count: folder.depth - 1) + folder.item.title).tag(Optional(folder.item.id))
                    }
                }
            }
            HStack {
                if let existing {
                    Button("Удалить", role: .destructive) {
                        store.remove(existing.id)
                        tabManager.bookmarkEditorVisible = false
                    }
                }
                Spacer()
                Button("Отмена") { tabManager.bookmarkEditorVisible = false }
                    .keyboardShortcut(.cancelAction)
                Button("Готово", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .onAppear {
            existing = store.bookmark(for: url)
            name = existing?.title ?? title
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        if let existing {
            store.update(existing.id, title: name, url: nil)
        } else {
            store.add(title: name, url: url, to: folderID)
            tabManager.showToast("Добавлено в закладки", symbol: "bookmark.fill")
        }
        tabManager.bookmarkEditorVisible = false
    }
}
