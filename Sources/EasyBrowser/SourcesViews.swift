import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Окно «Источники»: коллекции слева, таблица источников, карточка выбранного справа.
@MainActor
final class SourcesWindow: NSObject, NSWindowDelegate {
    private static let shared = SourcesWindow()
    private var window: NSWindow?
    private let state = SourcesWindowState()

    static func show(for manager: TabManager?, select id: UUID? = nil) {
        shared.state.manager = manager
        if let id { shared.state.selection = [id] }
        let window = shared.window ?? shared.makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Источники"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 420)
        window.contentViewController = NSHostingController(rootView: SourcesView(state: state))
        window.center()
        window.setFrameAutosaveName("AircraftSourcesWindow")
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
final class SourcesWindowState {
    var manager: TabManager?
    var selection: Set<UUID> = []
    /// nil — все источники.
    var collection: UUID?
    var search = ""
    var style: Citation.Style = .gost
}

private struct SourcesView: View {
    @Bindable var state: SourcesWindowState
    private var store: SourcesStore { .shared }

    private var visible: [SourceItem] {
        store.items.filter { item in
            (state.collection.map { item.collectionIDs.contains($0) } ?? true)
                && (state.search.isEmpty || item.matches(state.search))
        }
    }

    private var selectedItems: [SourceItem] { visible.filter { state.selection.contains($0.id) } }

    var body: some View {
        HSplitView {
            collectionsList
                .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)
            VStack(spacing: 0) {
                toolbar
                Divider()
                if visible.isEmpty {
                    ContentUnavailableView(store.items.isEmpty ? "Источников пока нет" : "Ничего не найдено",
                                           systemImage: "books.vertical",
                                           description: Text(store.items.isEmpty
                                               ? "Откройте статью или страницу и нажмите «Сохранить в источники» (⌘⇧S). Авторы, журнал, DOI и PDF подтянутся сами."
                                               : "Измените запрос или выберите другую коллекцию."))
                } else {
                    table
                }
            }
            .frame(minWidth: 380)
            detail
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
    }

    // MARK: Коллекции

    private var collectionsList: some View {
        List(selection: Binding<UUID?>(get: { state.collection ?? Self.allID },
                                       set: { state.collection = ($0 == nil || $0 == Self.allID) ? nil : $0 })) {
            Label("Все источники", systemImage: "books.vertical")
                .badge(store.items.count)
                .tag(Self.allID)
            Section("Коллекции") {
                ForEach(store.collections) { collection in
                    Label(collection.name, systemImage: "folder")
                        .badge(store.items.filter { $0.collectionIDs.contains(collection.id) }.count)
                        .tag(collection.id)
                        .dropDestination(for: String.self) { ids, _ in
                            let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
                            store.setCollection(collection.id, for: uuids, included: true)
                            return !uuids.isEmpty
                        }
                        .contextMenu {
                            Button("Переименовать…") { rename(collection) }
                            Button("Экспорт в BibTeX…") { export(store.items.filter { $0.collectionIDs.contains(collection.id) }, as: .bibtex) }
                            Divider()
                            Button("Удалить коллекцию") {
                                if state.collection == collection.id { state.collection = nil }
                                store.deleteCollection(collection.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                if let name = Self.ask("Новая коллекция", value: "") { state.collection = store.createCollection(named: name) }
            } label: {
                Label("Новая коллекция", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private static let allID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!

    // MARK: Таблица

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск: название, автор, журнал, тег, DOI", text: $state.search)
                .textFieldStyle(.plain)
            Spacer()
            Button {
                if let manager = state.manager ?? AgentBrowser.frontmostManager(includingIncognito: true) {
                    SourceCapture.save(from: manager)
                }
            } label: { Label("Сохранить страницу", systemImage: "plus.circle") }
            .help("Сохранить открытую во вкладке страницу (⌘⇧S)")
            Menu {
                Button("BibTeX (.bib)…") { export(exportItems, as: .bibtex) }
                Button("RIS (.ris)…") { export(exportItems, as: .ris) }
                Button("Список литературы — \(state.style.title) (.txt)…") { export(exportItems, as: .bibliography) }
            } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
            .fixedSize()
            .help("Выбранные источники, а если ничего не выбрано — все показанные")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private var exportItems: [SourceItem] { selectedItems.isEmpty ? visible : selectedItems }

    private var table: some View {
        Table(visible, selection: $state.selection) {
            TableColumn("Название") { item in
                Label { Text(item.title).lineLimit(1) } icon: {
                    Image(systemName: item.type.symbol).foregroundStyle(.secondary)
                }
                .draggable(item.id.uuidString)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Авторы", value: \.authorsShort)
                .width(min: 80, ideal: 140)
            TableColumn("Год", value: \.year)
                .width(44)
            TableColumn("Издание", value: \.container)
                .width(min: 80, ideal: 140)
            TableColumn("") { item in
                HStack(spacing: 4) {
                    if item.pdfFile != nil { Image(systemName: "doc.richtext").help("PDF") }
                    if item.snapshotFile != nil { Image(systemName: "camera.viewfinder").help("Снимок страницы") }
                }
                .foregroundStyle(.secondary)
            }
            .width(36)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            itemMenu(ids)
        } primaryAction: { ids in
            if let item = ids.first.flatMap(store.item) { open(item) }
        }
        .onDeleteCommand { store.delete(state.selection); state.selection = [] }
    }

    @ViewBuilder
    private func itemMenu(_ ids: Set<UUID>) -> some View {
        let items = store.items.filter { ids.contains($0.id) }
        if let item = items.first, items.count == 1 {
            Button("Открыть страницу") { open(item) }
            if item.pdfFile != nil { Button("Открыть PDF") { openAttachment(item.pdfFile) } }
            if item.snapshotFile != nil { Button("Открыть снимок страницы") { openAttachment(item.snapshotFile) } }
            Divider()
        }
        Button("Скопировать ссылку — ГОСТ") { copy(items.map { Citation.format($0, style: .gost) }.joined(separator: "\n")) }
        Button("Скопировать ссылку — APA") { copy(items.map { Citation.format($0, style: .apa) }.joined(separator: "\n")) }
        Button("Скопировать BibTeX") { copy(Citation.bibtex(items)) }
        if !store.collections.isEmpty {
            Menu("Коллекции") {
                ForEach(store.collections) { collection in
                    let inside = items.allSatisfy { $0.collectionIDs.contains(collection.id) }
                    Button(inside ? "✓ \(collection.name)" : collection.name) {
                        store.setCollection(collection.id, for: ids, included: !inside)
                    }
                }
            }
        }
        Divider()
        Button("Удалить", role: .destructive) {
            store.delete(ids)
            state.selection.subtract(ids)
        }
    }

    // MARK: Карточка

    @ViewBuilder
    private var detail: some View {
        if selectedItems.count == 1, let item = selectedItems.first {
            SourceDetail(item: item, style: $state.style) { open($0) } openAttachment: { openAttachment($0) }
                .id(item.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.book.closed").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(selectedItems.isEmpty ? "Выберите источник" : "Выбрано: \(selectedItems.count)")
                    .foregroundStyle(.secondary)
                if selectedItems.count > 1 {
                    Button("Скопировать список — \(state.style.title)") {
                        copy(selectedItems.enumerated().map { "\($0.offset + 1). " + Citation.format($0.element, style: state.style) }
                            .joined(separator: "\n"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Действия

    private func open(_ item: SourceItem) {
        guard let url = URL(string: item.url) else { return }
        if let manager = state.manager ?? AgentBrowser.frontmostManager(includingIncognito: false) {
            manager.createNewTab(url: url, selectNewTab: true, afterTabID: manager.activeTabID)
            manager.hostWindow?.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAttachment(_ name: String?) {
        guard let url = store.attachmentURL(name) else { return }
        if url.pathExtension == "pdf", let manager = state.manager ?? AgentBrowser.frontmostManager(includingIncognito: false) {
            manager.openFiles([url])
            manager.hostWindow?.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private enum ExportFormat { case bibtex, ris, bibliography }

    private func export(_ items: [SourceItem], as format: ExportFormat) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let text: String
        switch format {
        case .bibtex:
            panel.nameFieldStringValue = "sources.bib"
            text = Citation.bibtex(items)
        case .ris:
            panel.nameFieldStringValue = "sources.ris"
            text = Citation.ris(items)
        case .bibliography:
            panel.nameFieldStringValue = "Список литературы.txt"
            panel.allowedContentTypes = [.plainText]
            let sorted = items.sorted { ($0.creators.first?.lastName ?? $0.title) < ($1.creators.first?.lastName ?? $1.title) }
            text = sorted.enumerated().map { "\($0.offset + 1). " + Citation.format($0.element, style: state.style) }
                .joined(separator: "\n") + "\n"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
    }

    private func rename(_ collection: SourceCollection) {
        if let name = Self.ask("Название коллекции", value: collection.name) { store.renameCollection(collection.id, to: name) }
    }

    static func ask(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "Готово")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Карточка источника: поля редактируются на месте и сразу сохраняются.
private struct SourceDetail: View {
    @State var item: SourceItem
    @Binding var style: Citation.Style
    let open: (SourceItem) -> Void
    let openAttachment: (String?) -> Void
    @State private var copied = false
    private var store: SourcesStore { .shared }

    var body: some View {
        Form {
            Section {
                Picker("Тип", selection: $item.type) {
                    ForEach(SourceType.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                TextField("Название", text: $item.title, axis: .vertical).lineLimit(1...4)
                TextField("Авторы", text: $item.authorsText, prompt: Text("Фамилия, Имя; Фамилия, Имя"), axis: .vertical)
                    .lineLimit(1...4)
                TextField(containerLabel, text: $item.container)
                TextField("Дата", text: $item.date, prompt: Text("2024 или 2024-05-14"))
                if [.article, .conference, .preprint].contains(item.type) {
                    HStack {
                        TextField("Том", text: $item.volume)
                        TextField("№", text: $item.issue)
                    }
                }
                if item.type != .webpage && item.type != .video {
                    TextField("Страницы", text: $item.pages)
                    TextField(item.type == .thesis ? "Организация" : "Издательство", text: $item.publisher)
                    TextField("Город", text: $item.place)
                }
                TextField("DOI", text: $item.doi)
                if [.book, .chapter].contains(item.type) { TextField("ISBN", text: $item.isbn) }
                TextField("Адрес", text: $item.url)
            }
            Section("Теги и заметка") {
                TextField("Теги", text: $item.tagsText, prompt: Text("через запятую"))
                TextField("Заметка", text: $item.note, axis: .vertical).lineLimit(3...10)
            }
            if !item.abstract.isEmpty {
                Section("Аннотация") {
                    Text(item.abstract).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                Picker("Стиль", selection: $style) {
                    ForEach(Citation.Style.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Citation.format(item, style: style))
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                HStack {
                    Button(copied ? "Скопировано" : "Скопировать ссылку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Citation.format(item, style: style), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    Button("BibTeX") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Citation.bibtex([item]), forType: .string)
                    }
                }
            } header: {
                Text("Цитирование")
            }
            Section("Вложения") {
                Button { open(item) } label: { Label("Открыть страницу", systemImage: "safari") }
                    .disabled(URL(string: item.url) == nil)
                if item.pdfFile != nil {
                    Button { openAttachment(item.pdfFile) } label: { Label("PDF", systemImage: "doc.richtext") }
                }
                if item.snapshotFile != nil {
                    Button { openAttachment(item.snapshotFile) } label: { Label("Снимок страницы", systemImage: "camera.viewfinder") }
                }
                LabeledContent("Добавлено", value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
        .onChange(of: item) { _, value in
            // Снимок и PDF могли докачаться, пока карточка открыта, — не затираем их.
            var merged = value
            if let saved = store.item(value.id) {
                merged.snapshotFile = merged.snapshotFile ?? saved.snapshotFile
                merged.pdfFile = merged.pdfFile ?? saved.pdfFile
            }
            store.update(merged)
        }
    }

    private var containerLabel: String {
        switch item.type {
        case .article: "Журнал"
        case .conference: "Конференция"
        case .chapter: "Книга"
        case .webpage, .video: "Сайт"
        case .preprint: "Репозиторий"
        default: "Серия"
        }
    }
}
