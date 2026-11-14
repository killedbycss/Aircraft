import Foundation
import AppKit
import WebKit
import Observation

/// Что делает ⌘⇧R. По умолчанию — принудительная перезагрузка без кэша, как в Chrome.
enum CommandShiftRAction: String, CaseIterable, Identifiable {
    case hardReload, reader, saveSource, none

    static let storageKey = "commandShiftRAction"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardReload: "Обновить без кэша"
        case .reader: "Режим чтения"
        case .saveSource: "Сохранить в «Источники»"
        case .none: "Ничего"
        }
    }

    /// Команда `BrowserCommands`.
    var command: String? {
        switch self {
        case .hardReload: "hardReload"
        case .reader: "toggleReader"
        case .saveSource: "saveSource"
        case .none: nil
        }
    }

    static var current: CommandShiftRAction {
        UserDefaults.standard.string(forKey: storageKey).flatMap(CommandShiftRAction.init(rawValue:)) ?? .hardReload
    }
}

// MARK: - Модель

/// Автор (или редактор) источника.
struct SourceCreator: Codable, Hashable, Sendable {
    var lastName: String
    var firstName: String = ""

    /// «Фамилия, Имя» или «Имя Фамилия».
    init(parsing name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = clean.firstIndex(of: ",") {
            lastName = clean[..<comma].trimmingCharacters(in: .whitespaces)
            firstName = clean[clean.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return
        }
        var parts = clean.split(separator: " ").map(String.init)
        guard parts.count > 1 else {
            lastName = clean
            return
        }
        lastName = parts.removeLast()
        firstName = parts.joined(separator: " ")
    }

    init(lastName: String, firstName: String = "") {
        self.lastName = lastName
        self.firstName = firstName
    }

    /// «И. П.» из «Иван Петрович», «Ж.-П.» из «Жан-Поль».
    var initials: String {
        firstName.split(separator: " ").map { word in
            word.split(separator: "-").compactMap { $0.first.map { "\($0)." } }.joined(separator: "-")
        }.joined(separator: " ")
    }

    var display: String { firstName.isEmpty ? lastName : "\(lastName), \(firstName)" }
}

enum SourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case article, conference, book, chapter, thesis, report, preprint, webpage, video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .article: "Статья в журнале"
        case .conference: "Доклад конференции"
        case .book: "Книга"
        case .chapter: "Глава книги"
        case .thesis: "Диссертация"
        case .report: "Отчёт"
        case .preprint: "Препринт"
        case .webpage: "Веб-страница"
        case .video: "Видео"
        }
    }

    var symbol: String {
        switch self {
        case .article: "doc.text"
        case .conference: "person.3"
        case .book: "book.closed"
        case .chapter: "book"
        case .thesis: "graduationcap"
        case .report: "doc.plaintext"
        case .preprint: "doc.badge.clock"
        case .webpage: "globe"
        case .video: "play.rectangle"
        }
    }
}

/// Источник в библиотеке: метаданные, теги, заметка, коллекции и вложения
/// (снимок страницы `.webarchive` и PDF).
struct SourceItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var type: SourceType = .webpage
    var title = ""
    var creators: [SourceCreator] = []
    /// Журнал, сборник, книга или сайт.
    var container = ""
    /// Дата публикации как на сайте: «2023», «2023-05-14».
    var date = ""
    var publisher = ""
    var place = ""
    var volume = ""
    var issue = ""
    var pages = ""
    var doi = ""
    var isbn = ""
    var url = ""
    var pdfURL = ""
    var abstract = ""
    var language = ""
    var tags: [String] = []
    var note = ""
    var collectionIDs: [UUID] = []
    var addedAt = Date()
    var accessedAt = Date()
    /// Имена файлов в папке вложений.
    var snapshotFile: String?
    var pdfFile: String?

    var year: String {
        let digits = date.split(whereSeparator: { !$0.isNumber }).first { $0.count == 4 }
        return digits.map { String($0) } ?? ""
    }

    var authorsShort: String {
        switch creators.count {
        case 0: ""
        case 1: creators[0].lastName
        case 2: "\(creators[0].lastName), \(creators[1].lastName)"
        default: "\(creators[0].lastName) и др."
        }
    }

    var authorsText: String {
        get { creators.map(\.display).joined(separator: "; ") }
        set {
            creators = newValue.split(separator: ";")
                .map { SourceCreator(parsing: String($0)) }
                .filter { !$0.lastName.isEmpty }
        }
    }

    var tagsText: String {
        get { tags.joined(separator: ", ") }
        set { tags = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    /// Ключ для поиска дублей: DOI, иначе адрес без схемы и «www.».
    var identity: String {
        if !doi.isEmpty { return "doi:" + doi.lowercased() }
        return SpotlightSuggestionEngine.shortURL(URL(string: url) ?? URL(fileURLWithPath: "/")).lowercased()
    }

    func matches(_ query: String) -> Bool {
        let haystack = [title, authorsText, container, date, doi, url, tagsText, note, abstract].joined(separator: " ").lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

struct SourceCollection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
}

// MARK: - Хранилище

/// Библиотека источников — общая для всех профилей, лежит в `aircraft/Sources`.
@MainActor
@Observable
final class SourcesStore {
    static let shared = SourcesStore()

    private(set) var items: [SourceItem] = []
    private(set) var collections: [SourceCollection] = []

    private struct Snapshot: Codable {
        var items: [SourceItem]
        var collections: [SourceCollection]
    }

    static var folder: URL { AircraftPaths.ensure(AircraftPaths.root.appendingPathComponent("Sources", isDirectory: true)) }
    static var attachments: URL { AircraftPaths.ensure(folder.appendingPathComponent("Attachments", isDirectory: true)) }
    private static var file: URL { folder.appendingPathComponent("sources.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            items = snapshot.items
            collections = snapshot.collections
        }
    }

    private func save() {
        let snapshot = Snapshot(items: items, collections: collections)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let target = Self.file
        Task.detached(priority: .utility) { try? data.write(to: target, options: .atomic) }
    }

    func item(_ id: UUID) -> SourceItem? { items.first { $0.id == id } }

    func existing(like item: SourceItem) -> SourceItem? {
        items.first { $0.identity == item.identity }
    }

    /// Добавляет источник; если такой уже есть (тот же DOI или адрес) — обновляет
    /// метаданные, сохраняя теги, заметку и коллекции. Возвращает id и признак «уже был».
    @discardableResult
    func add(_ item: SourceItem, into collection: UUID? = nil) -> (id: UUID, existed: Bool) {
        if let index = items.firstIndex(where: { $0.identity == item.identity }) {
            var merged = item
            merged.id = items[index].id
            merged.tags = items[index].tags
            merged.note = items[index].note
            merged.addedAt = items[index].addedAt
            merged.collectionIDs = items[index].collectionIDs
            if let collection, !merged.collectionIDs.contains(collection) { merged.collectionIDs.append(collection) }
            merged.snapshotFile = item.snapshotFile ?? items[index].snapshotFile
            merged.pdfFile = item.pdfFile ?? items[index].pdfFile
            items[index] = merged
            save()
            return (merged.id, true)
        }
        var new = item
        if let collection { new.collectionIDs = [collection] }
        items.insert(new, at: 0)
        save()
        return (new.id, false)
    }

    func update(_ item: SourceItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] != item else { return }
        items[index] = item
        save()
    }

    func attach(_ id: UUID, snapshot: String? = nil, pdf: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let snapshot { items[index].snapshotFile = snapshot }
        if let pdf { items[index].pdfFile = pdf }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            for name in [item.snapshotFile, item.pdfFile].compactMap({ $0 }) {
                try? FileManager.default.trashItem(at: Self.attachments.appendingPathComponent(name), resultingItemURL: nil)
            }
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    @discardableResult
    func createCollection(named name: String) -> UUID {
        let collection = SourceCollection(name: name.isEmpty ? "Новая коллекция" : name)
        collections.append(collection)
        save()
        return collection.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[index].name = name
        save()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        for index in items.indices { items[index].collectionIDs.removeAll { $0 == id } }
        save()
    }

    func setCollection(_ collection: UUID, for ids: Set<UUID>, included: Bool) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].collectionIDs.removeAll { $0 == collection }
            if included { items[index].collectionIDs.append(collection) }
        }
        save()
    }

    func attachmentURL(_ name: String?) -> URL? {
        name.map { Self.attachments.appendingPathComponent($0) }
    }
}

// MARK: - Захват со страницы

/// Сохраняет открытую страницу в «Источники»: читает метатеги Highwire (`citation_*`,
/// их же читает Google Scholar), Dublin Core, Open Graph и JSON-LD, снимает копию
/// страницы (`.webarchive`) и скачивает PDF статьи с cookie вкладки — поэтому
/// работают и страницы за логином (LMS, библиотеки, издательства).
@MainActor
enum SourceCapture {
    struct Page {
        var title = ""
        var language = ""
        var meta: [String: [String]] = [:]
        var linkedData: [String: Any] = [:]
        var doiLink: String?
    }

    static func save(from manager: TabManager) {
        guard manager.modCapabilities.contains("sources") else {
            manager.showToast("Включите мод «Источники»: Настройки → Модификации", symbol: "books.vertical")
            return
        }
        guard let tab = manager.activeTab, let pageURL = tab.webView?.url ?? tab.url,
              pageURL.scheme == "http" || pageURL.scheme == "https" || pageURL.isFileURL else {
            manager.showToast("Эту страницу нельзя сохранить", symbol: "exclamationmark.triangle")
            return
        }
        let store = SourcesStore.shared
        // PDF во встроенном просмотрщике: файл уже скачан — кладём его как вложение.
        if case .pdf(let file) = tab.content {
            var item = SourceItem(type: .article, title: tab.title.isEmpty ? file.deletingPathExtension().lastPathComponent : tab.title,
                                  url: pageURL.absoluteString, pdfURL: pageURL.absoluteString)
            item.container = pageURL.host ?? ""
            let result = store.add(item)
            if let name = copyAttachment(file, id: result.id, ext: "pdf") { store.attach(result.id, pdf: name) }
            manager.showToast(result.existed ? "Уже в источниках — обновлено" : "PDF сохранён в источники", symbol: "books.vertical.fill")
            return
        }
        guard let webView = tab.webView else { return }
        Task { @MainActor in
            let page = await collect(from: webView) ?? Page(title: tab.title)
            let item = makeItem(page, url: pageURL)
            let result = store.add(item)
            manager.showToast(result.existed ? "Уже в источниках — обновлено" : "Сохранено в источники: \(item.type.title.lowercased())",
                              symbol: "books.vertical.fill")
            if let archive = try? await webView.webArchiveData(),
               let name = writeAttachment(archive, id: result.id, ext: "webarchive") {
                store.attach(result.id, snapshot: name)
            }
            if !item.pdfURL.isEmpty, let pdf = URL(string: item.pdfURL),
               let name = await downloadPDF(pdf, cookiesFrom: webView, id: result.id) {
                store.attach(result.id, pdf: name)
            }
        }
    }

    // MARK: Метаданные

    private static let collectScript = """
    const meta = {};
    for (const el of document.querySelectorAll('meta[name], meta[property]')) {
      const key = (el.getAttribute('name') || el.getAttribute('property') || '').toLowerCase();
      const value = el.getAttribute('content');
      if (!key || !value) continue;
      (meta[key] = meta[key] || []).push(value.trim());
    }
    const wanted = ['ScholarlyArticle','Article','NewsArticle','BlogPosting','Book','Chapter','Thesis','Report','VideoObject','TechArticle'];
    let linked = null;
    const visit = (node) => {
      if (!node || linked) return;
      if (Array.isArray(node)) { node.forEach(visit); return; }
      if (typeof node !== 'object') return;
      const type = [].concat(node['@type'] || []);
      if (type.some(t => wanted.includes(t))) { linked = node; return; }
      if (node['@graph']) visit(node['@graph']);
    };
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      try { visit(JSON.parse(script.textContent)); } catch (e) {}
    }
    const names = (value) => [].concat(value || []).map(a => typeof a === 'string' ? a : (a && a.name) || '').filter(Boolean);
    const name = (value) => { const v = [].concat(value || [])[0]; return typeof v === 'string' ? v : (v && v.name) || ''; };
    const ld = linked ? {
      type: [].concat(linked['@type'] || [])[0] || '',
      title: linked.headline || linked.name || '',
      authors: names(linked.author),
      date: linked.datePublished || linked.uploadDate || '',
      publisher: name(linked.publisher),
      container: name(linked.isPartOf),
      description: linked.description || ''
    } : {};
    const doiLink = [...document.querySelectorAll('a[href*="doi.org/10."]')].map(a => a.href)[0] || null;
    return { title: document.title || '', language: document.documentElement.lang || '', meta, ld, doiLink };
    """

    private static func collect(from webView: WKWebView) async -> Page? {
        let value = try? await webView.callAsyncJavaScript(collectScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let result = value as? [String: Any] else { return nil }
        return Page(title: result["title"] as? String ?? "",
                    language: result["language"] as? String ?? "",
                    meta: result["meta"] as? [String: [String]] ?? [:],
                    linkedData: result["ld"] as? [String: Any] ?? [:],
                    doiLink: result["doiLink"] as? String)
    }

    /// Запись по метаданным страницы. Без них — «Веб-страница» с названием и сайтом.
    nonisolated static func makeItem(_ page: Page, url: URL, now: Date = Date()) -> SourceItem {
        func first(_ keys: String...) -> String? {
            for key in keys {
                if let value = page.meta[key]?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
            }
            return nil
        }
        func ld(_ key: String) -> String? {
            (page.linkedData[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var item = SourceItem()
        item.url = first("citation_abstract_html_url") ?? url.absoluteString
        item.accessedAt = now
        item.addedAt = now
        item.title = first("citation_title", "dc.title", "og:title") ?? ld("title") ?? page.title
        var authors = page.meta["citation_author"] ?? page.meta["dc.creator"] ?? []
        if authors.isEmpty { authors = page.linkedData["authors"] as? [String] ?? [] }
        if authors.isEmpty, let author = first("author", "article:author"), !author.hasPrefix("http") { authors = [author] }
        item.creators = authors.map(SourceCreator.init(parsing:)).filter { !$0.lastName.isEmpty }
        item.date = first("citation_publication_date", "citation_date", "citation_online_date", "dc.date",
                          "article:published_time") ?? ld("date") ?? ""
        if item.date.count > 10, item.date.contains("T") { item.date = String(item.date.prefix(10)) }
        item.volume = first("citation_volume") ?? ""
        item.issue = first("citation_issue") ?? ""
        if let firstPage = first("citation_firstpage") {
            item.pages = first("citation_lastpage").map { "\(firstPage)–\($0)" } ?? firstPage
        }
        item.publisher = first("citation_publisher", "dc.publisher") ?? ld("publisher") ?? ""
        item.isbn = first("citation_isbn") ?? ""
        item.abstract = first("citation_abstract", "dc.description", "description", "og:description") ?? ld("description") ?? ""
        item.language = first("citation_language", "dc.language") ?? page.language
        item.pdfURL = first("citation_pdf_url").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL.absoluteString } ?? ""
        item.tags = (page.meta["citation_keywords"] ?? [])
            .flatMap { $0.split(whereSeparator: { $0 == ";" || $0 == "," }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let doiSource = first("citation_doi", "dc.identifier", "prism.doi") ?? page.doiLink ?? url.absoluteString
        item.doi = extractDOI(doiSource) ?? ""

        let ldType = ld("type") ?? ""
        if let journal = first("citation_journal_title", "prism.publicationname") {
            item.type = .article
            item.container = journal
        } else if let conference = first("citation_conference_title") {
            item.type = .conference
            item.container = conference
        } else if let institution = first("citation_dissertation_institution") {
            item.type = .thesis
            item.publisher = institution
        } else if let institution = first("citation_technical_report_institution") {
            item.type = .report
            item.publisher = institution
        } else if let book = first("citation_inbook_title") {
            item.type = .chapter
            item.container = book
        } else if !item.isbn.isEmpty || ldType == "Book" {
            item.type = .book
        } else if first("citation_title") != nil || ldType == "ScholarlyArticle" {
            item.type = .preprint
            item.container = first("citation_publisher") ?? first("og:site_name") ?? url.host ?? ""
        } else if ldType == "VideoObject" || first("og:type")?.hasPrefix("video") == true {
            item.type = .video
            item.container = first("og:site_name") ?? url.host ?? ""
        } else {
            item.type = .webpage
            item.container = first("og:site_name", "application-name") ?? ld("container") ?? url.host ?? ""
        }
        if item.title.isEmpty { item.title = url.host ?? url.absoluteString }
        return item
    }

    nonisolated static func extractDOI(_ text: String) -> String? {
        guard let range = text.range(of: #"10\.\d{4,9}/[^\s"<>?#]+"#, options: .regularExpression) else { return nil }
        var doi = String(text[range])
        while let last = doi.last, ".,;)".contains(last) { doi.removeLast() }
        return doi.removingPercentEncoding ?? doi
    }

    // MARK: Вложения

    private static func writeAttachment(_ data: Data, id: UUID, ext: String) -> String? {
        let name = "\(id.uuidString).\(ext)"
        do {
            try data.write(to: SourcesStore.attachments.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private static func copyAttachment(_ file: URL, id: UUID, ext: String) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return writeAttachment(data, id: id, ext: ext)
    }

    private static func downloadPDF(_ url: URL, cookiesFrom webView: WKWebView, id: UUID) async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var request = URLRequest(url: url, timeoutInterval: 60)
        let matching = cookies.filter { cookie in
            guard let host = url.host?.lowercased() else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: field) }
        if let agent = webView.customUserAgent, !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
              data.starts(with: Array("%PDF".utf8)) else { return nil }
        return writeAttachment(data, id: id, ext: "pdf")
    }
}

private extension WKWebView {
    func webArchiveData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            createWebArchiveData { result in continuation.resume(with: result) }
        }
    }
}

// MARK: - Цитирование и экспорт

/// Библиографические ссылки: ГОСТ Р 7.0.100–2018 (упрощённо), APA 7, BibTeX и RIS.
enum Citation {
    enum Style: String, CaseIterable, Identifiable {
        case gost, apa
        var id: String { rawValue }
        var title: String { self == .gost ? "ГОСТ Р 7.0.100" : "APA 7" }
    }

    static func format(_ item: SourceItem, style: Style, accessed: Date? = nil) -> String {
        style == .gost ? gost(item, accessed: accessed ?? item.accessedAt) : apa(item)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: date)
    }

    /// Иванов, И. И. Заглавие / И. И. Иванов, П. П. Петров // Журнал. — 2023. — Т. 5, № 2. — С. 10–20. — DOI 10.…
    static func gost(_ item: SourceItem, accessed: Date) -> String {
        var parts: [String] = []
        let names = item.creators.map { creator in
            creator.initials.isEmpty ? creator.lastName : "\(creator.initials) \(creator.lastName)"
        }
        var head = ""
        if let first = item.creators.first, item.creators.count <= 3 {
            head = first.initials.isEmpty ? "\(first.lastName). " : "\(first.lastName), \(first.initials) "
        }
        head += item.title
        if !names.isEmpty {
            let shown = names.count > 3 ? names.prefix(3).joined(separator: ", ") + " [и др.]" : names.joined(separator: ", ")
            head += " / \(shown)"
        }
        let online = item.type == .webpage || item.type == .video || (item.doi.isEmpty && item.type != .book)
        if online { head += ". — Текст : электронный" }
        switch item.type {
        case .article, .conference, .chapter, .preprint:
            if !item.container.isEmpty { head += " // \(item.container)" }
            parts.append(head)
            if !item.year.isEmpty { parts.append(item.year) }
            var issue: [String] = []
            if !item.volume.isEmpty { issue.append("Т. \(item.volume)") }
            if !item.issue.isEmpty { issue.append("№ \(item.issue)") }
            if !issue.isEmpty { parts.append(issue.joined(separator: ", ")) }
            if !item.pages.isEmpty { parts.append("С. \(item.pages)") }
        case .book, .thesis, .report:
            parts.append(head)
            let imprint = [item.place.isEmpty ? nil : item.place, item.publisher.isEmpty ? nil : item.publisher]
                .compactMap { $0 }.joined(separator: " : ")
            parts.append([imprint, item.year].filter { !$0.isEmpty }.joined(separator: ", "))
            if !item.isbn.isEmpty { parts.append("ISBN \(item.isbn)") }
        case .webpage, .video:
            if !item.container.isEmpty { head += " // \(item.container) : [сайт]" }
            parts.append(head)
            if !item.year.isEmpty { parts.append(item.year) }
        }
        if !item.doi.isEmpty { parts.append("DOI \(item.doi)") }
        if online, !item.url.isEmpty { parts.append("URL: \(item.url) (дата обращения: \(dayString(accessed)))") }
        return parts.filter { !$0.isEmpty }.joined(separator: ". — ") + "."
    }

    /// Lastname, F. M., & Lastname, F. (2023). Title. Journal, 5(2), 10–20. https://doi.org/…
    static func apa(_ item: SourceItem) -> String {
        let names = item.creators.map { creator in
            creator.initials.isEmpty ? creator.lastName : "\(creator.lastName), \(creator.initials)"
        }
        var authors: String
        switch names.count {
        case 0: authors = ""
        case 1: authors = names[0]
        case 2...20: authors = names.dropLast().joined(separator: ", ") + ", & " + names.last!
        default: authors = names.prefix(19).joined(separator: ", ") + ", … " + names.last!
        }
        let year = item.year.isEmpty ? "n.d." : item.year
        var text = authors.isEmpty ? "\(item.title). (\(year))." : "\(authors) (\(year)). \(item.title)."
        switch item.type {
        case .article, .conference, .preprint:
            if !item.container.isEmpty {
                text += " \(item.container)"
                if !item.volume.isEmpty { text += ", \(item.volume)" }
                if !item.issue.isEmpty { text += "(\(item.issue))" }
                if !item.pages.isEmpty { text += ", \(item.pages)" }
                text += "."
            }
        case .chapter:
            if !item.container.isEmpty { text += " In \(item.container)" + (item.pages.isEmpty ? "." : " (pp. \(item.pages)).") }
            if !item.publisher.isEmpty { text += " \(item.publisher)." }
        case .book, .thesis, .report:
            if !item.publisher.isEmpty { text += " \(item.publisher)." }
        case .webpage, .video:
            if !item.container.isEmpty { text += " \(item.container)." }
        }
        if !item.doi.isEmpty { text += " https://doi.org/\(item.doi)" }
        else if !item.url.isEmpty { text += " \(item.url)" }
        return text
    }

    // MARK: BibTeX

    static func bibtexKey(_ item: SourceItem) -> String {
        let author = item.creators.first?.lastName ?? "source"
        let word = item.title.split(separator: " ").first { $0.count > 3 }.map(String.init) ?? ""
        let raw = (author + item.year + word).applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? author
        return raw.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    static func bibtex(_ items: [SourceItem]) -> String {
        var usedKeys: [String: Int] = [:]
        return items.map { item in
            var key = bibtexKey(item)
            if let count = usedKeys[key] {
                usedKeys[key] = count + 1
                key += String(Character(Unicode.Scalar(UInt8(96 + min(count + 1, 26)))))
            } else {
                usedKeys[key] = 1
            }
            let type: String
            var fields: [(String, String)] = []
            switch item.type {
            case .article: type = "article"; fields.append(("journal", item.container))
            case .conference: type = "inproceedings"; fields.append(("booktitle", item.container))
            case .book: type = "book"
            case .chapter: type = "incollection"; fields.append(("booktitle", item.container))
            case .thesis: type = "phdthesis"; fields.append(("school", item.publisher))
            case .report: type = "techreport"; fields.append(("institution", item.publisher))
            case .preprint, .webpage, .video: type = "misc"; fields.append(("howpublished", item.container))
            }
            fields.insert(("title", "{\(escape(item.title))}"), at: 0)
            fields.insert(("author", item.creators.map { $0.firstName.isEmpty ? $0.lastName : "\($0.lastName), \($0.firstName)" }
                .joined(separator: " and ")), at: 0)
            fields += [("year", item.year), ("volume", item.volume), ("number", item.issue),
                       ("pages", item.pages.replacingOccurrences(of: "–", with: "--")),
                       ("publisher", [.thesis, .report].contains(item.type) ? "" : item.publisher),
                       ("address", item.place), ("isbn", item.isbn), ("doi", item.doi), ("url", item.url),
                       ("urldate", isoDay(item.accessedAt)), ("langid", item.language),
                       ("keywords", item.tags.joined(separator: ", ")), ("abstract", item.abstract)]
            let body = fields.filter { !$0.1.isEmpty }
                .map { "  \($0.0) = {\($0.0 == "title" ? $0.1 : escape($0.1))}" }
                .joined(separator: ",\n")
            return "@\(type){\(key),\n\(body)\n}"
        }.joined(separator: "\n\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "&", with: "\\&").replacingOccurrences(of: "%", with: "\\%")
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: RIS

    static func ris(_ items: [SourceItem]) -> String {
        items.map { item in
            let type: String = switch item.type {
            case .article: "JOUR"
            case .conference: "CPAPER"
            case .book: "BOOK"
            case .chapter: "CHAP"
            case .thesis: "THES"
            case .report: "RPRT"
            case .preprint: "UNPB"
            case .webpage: "ELEC"
            case .video: "VIDEO"
            }
            var lines = ["TY  - \(type)", "TI  - \(item.title)"]
            lines += item.creators.map { "AU  - \($0.display)" }
            let pages = item.pages.split(whereSeparator: { $0 == "–" || $0 == "-" }).map(String.init)
            let fields: [(String, String)] = [
                ("PY", item.year), ("DA", item.date), ("T2", item.container), ("VL", item.volume), ("IS", item.issue),
                ("SP", pages.first ?? ""), ("EP", pages.count > 1 ? pages[1] : ""), ("PB", item.publisher),
                ("CY", item.place), ("SN", item.isbn), ("DO", item.doi), ("UR", item.url), ("LA", item.language),
                ("AB", item.abstract), ("N1", item.note), ("Y2", isoDay(item.accessedAt))
            ]
            lines += fields.filter { !$0.1.isEmpty }.map { "\($0.0)  - \($0.1)" }
            lines += item.tags.map { "KW  - \($0)" }
            lines.append("ER  - ")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }
}
