import Foundation
import AppKit

/// Импорт закладок и истории из других браузеров.
enum BrowserImport {
    enum Source: String, CaseIterable, Identifiable {
        case safari, chrome, arc, brave, edge, vivaldi, chromium
        var id: String { rawValue }

        var title: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Google Chrome"
            case .arc: "Arc"
            case .brave: "Brave"
            case .edge: "Microsoft Edge"
            case .vivaldi: "Vivaldi"
            case .chromium: "Chromium"
            }
        }

        /// Папка профиля Chromium-браузера.
        var chromiumProfile: URL? {
            let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            let path: String
            switch self {
            case .safari: return nil
            case .chrome: path = "Google/Chrome/Default"
            case .arc: path = "Arc/User Data/Default"
            case .brave: path = "BraveSoftware/Brave-Browser/Default"
            case .edge: path = "Microsoft Edge/Default"
            case .vivaldi: path = "Vivaldi/Default"
            case .chromium: path = "Chromium/Default"
            }
            return support.appendingPathComponent(path, isDirectory: true)
        }

        var isInstalled: Bool {
            if self == .safari { return true }
            return chromiumProfile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    struct Result {
        var bookmarks = 0
        var pages = 0
        var errors: [String] = []
        var needsFullDiskAccess = false
    }

    // MARK: Запуск

    @MainActor
    static func run(_ source: Source, bookmarks bookmarkStore: BookmarkStore?, history: HistoryStore?) -> Result {
        var result = Result()
        if let bookmarkStore {
            do {
                let folder = try readBookmarks(source)
                result.bookmarks = countBookmarks(folder)
                if result.bookmarks > 0 { bookmarkStore.addImported(folder) }
            } catch let error as ImportError {
                result.errors.append(error.message)
                if error.needsFullDiskAccess { result.needsFullDiskAccess = true }
            } catch {
                result.errors.append(error.localizedDescription)
            }
        }
        if let history {
            do {
                let pages = try readHistory(source)
                history.beginBatch()
                for page in pages { history.importPage(url: page.url, title: page.title, visitCount: page.visits, lastVisit: page.lastVisit) }
                history.endBatch()
                result.pages = pages.count
            } catch let error as ImportError {
                result.errors.append(error.message)
                if error.needsFullDiskAccess { result.needsFullDiskAccess = true }
            } catch {
                result.errors.append(error.localizedDescription)
            }
        }
        return result
    }

    /// HTML-файл закладок (формат Netscape) — его экспортирует любой браузер.
    @MainActor
    static func importHTML(_ url: URL, into store: BookmarkStore) throws -> Int {
        let html = try String(contentsOf: url, encoding: .utf8)
        var folder = parseNetscape(html)
        folder.title = "Импорт · \(url.deletingPathExtension().lastPathComponent)"
        let count = countBookmarks(folder)
        if count > 0 { store.addImported(folder) }
        return count
    }

    struct ImportError: Error {
        var message: String
        var needsFullDiskAccess = false
    }

    struct ImportedPage {
        var url: URL
        var title: String
        var visits: Int
        var lastVisit: Date
    }

    static func countBookmarks(_ item: BookmarkItem) -> Int {
        item.isFolder ? item.children.map(countBookmarks).reduce(0, +) : 1
    }

    // MARK: Закладки

    static func readBookmarks(_ source: Source) throws -> BookmarkItem {
        if source == .safari {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw ImportError(message: "Нет доступа к закладкам Safari. Дайте Aircraft полный доступ к диску.", needsFullDiskAccess: true)
            }
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw ImportError(message: "Не удалось прочитать закладки Safari.")
            }
            var root = parseSafari(plist) ?? BookmarkItem(title: "", url: nil)
            root.title = "Импорт из Safari"
            return root
        }
        guard let profile = source.chromiumProfile else { throw ImportError(message: "Профиль не найден.") }
        let file = profile.appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: file),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else {
            throw ImportError(message: "В \(source.title) не найдено закладок.")
        }
        var folder = BookmarkItem(title: "Импорт из \(source.title)", url: nil)
        let names = ["bookmark_bar": "Панель закладок", "other": "Другие закладки", "synced": "Мобильные закладки"]
        for key in ["bookmark_bar", "other", "synced"] {
            guard let node = roots[key] as? [String: Any], var item = parseChromium(node) else { continue }
            guard !item.children.isEmpty else { continue }
            item.title = names[key] ?? item.title
            folder.children.append(item)
        }
        return folder
    }

    private static func parseChromium(_ node: [String: Any]) -> BookmarkItem? {
        let name = node["name"] as? String ?? ""
        if node["type"] as? String == "url" {
            guard let raw = node["url"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
            return BookmarkItem(title: name, url: url)
        }
        let children = (node["children"] as? [[String: Any]] ?? []).compactMap(parseChromium)
        return BookmarkItem(title: name, url: nil, children: children)
    }

    private static func parseSafari(_ node: [String: Any]) -> BookmarkItem? {
        let type = node["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf" {
            guard let raw = node["URLString"] as? String, let url = URL(string: raw) else { return nil }
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url.host ?? raw
            return BookmarkItem(title: title, url: url)
        }
        guard type == "WebBookmarkTypeList" else { return nil }
        var title = node["Title"] as? String ?? ""
        switch title {
        case "BookmarksBar": title = "Избранное"
        case "BookmarksMenu": title = "Меню закладок"
        case "com.apple.ReadingList": title = "Список для чтения"
        default: break
        }
        let children = (node["Children"] as? [[String: Any]] ?? []).compactMap(parseSafari)
        if children.isEmpty, !title.isEmpty { return nil }
        return BookmarkItem(title: title, url: nil, children: children)
    }

    /// Простой разбор формата Netscape: `<H3>` — папка, `<DL>` — её содержимое, `<A HREF>` — закладка.
    static func parseNetscape(_ html: String) -> BookmarkItem {
        var stack: [BookmarkItem] = [BookmarkItem(title: "Импорт", url: nil)]
        var pendingFolder: String?
        var seenFirstList = false
        let pattern = try! NSRegularExpression(
            pattern: #"<(/?)(dl|h3|a)\b([^>]*)>(?:([^<]*)</(?:h3|a)>)?"#, options: [.caseInsensitive])
        let ns = html as NSString
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let tag = ns.substring(with: match.range(at: 2)).lowercased()
            let attributes = ns.substring(with: match.range(at: 3))
            let text = match.range(at: 4).location == NSNotFound ? "" : decodeEntities(ns.substring(with: match.range(at: 4)))
            switch (tag, closing) {
            case ("h3", false):
                pendingFolder = text
            case ("dl", false):
                if !seenFirstList {
                    seenFirstList = true
                } else {
                    stack.append(BookmarkItem(title: pendingFolder ?? "Папка", url: nil))
                }
                pendingFolder = nil
            case ("dl", true):
                if stack.count > 1 {
                    let finished = stack.removeLast()
                    stack[stack.count - 1].children.append(finished)
                }
            case ("a", false):
                guard let href = attribute("href", in: attributes), let url = URL(string: href),
                      url.scheme?.hasPrefix("http") == true else { continue }
                stack[stack.count - 1].children.append(BookmarkItem(title: text.isEmpty ? (url.host ?? href) : text, url: url))
            default:
                break
            }
        }
        while stack.count > 1 {
            let finished = stack.removeLast()
            stack[stack.count - 1].children.append(finished)
        }
        return stack[0]
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#, options: [.caseInsensitive])
        let ns = attributes as NSString
        guard let match = pattern.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return decodeEntities(ns.substring(with: match.range(at: 1)))
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: История

    static func readHistory(_ source: Source, limit: Int = 20_000) throws -> [ImportedPage] {
        let original: URL
        if source == .safari {
            original = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")
        } else {
            guard let profile = source.chromiumProfile else { return [] }
            original = profile.appendingPathComponent("History")
        }
        // Браузер держит базу открытой — читаем копию.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("aircraft-import-\(UUID().uuidString).db")
        do {
            try FileManager.default.copyItem(at: original, to: copy)
        } catch {
            if source == .safari {
                throw ImportError(message: "Нет доступа к истории Safari. Дайте Aircraft полный доступ к диску.", needsFullDiskAccess: true)
            }
            throw ImportError(message: "В \(source.title) не найдено истории.")
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        guard let db = SQLiteDatabase(readOnly: copy) else { throw ImportError(message: "Не удалось открыть историю \(source.title).") }
        var pages: [ImportedPage] = []
        if source == .safari {
            // Время в секундах от 2001-01-01.
            db.query("""
            SELECT i.url, coalesce((SELECT title FROM history_visits WHERE history_item = i.id AND title IS NOT NULL ORDER BY visit_time DESC LIMIT 1), ''),
                   i.visit_count, max(v.visit_time)
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY max(v.visit_time) DESC LIMIT ?
            """, [.int(Int64(limit))]) { row in
                guard let url = URL(string: row.text(0)) else { return }
                pages.append(ImportedPage(url: url, title: row.text(1), visits: Int(row.int(2)),
                                          lastVisit: Date(timeIntervalSinceReferenceDate: row.double(3))))
            }
        } else {
            // Время в микросекундах от 1601-01-01.
            db.query("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?",
                     [.int(Int64(limit))]) { row in
                guard let url = URL(string: row.text(0)) else { return }
                let seconds = Double(row.int(3)) / 1_000_000 - 11_644_473_600
                pages.append(ImportedPage(url: url, title: row.text(1), visits: Int(row.int(2)),
                                          lastVisit: Date(timeIntervalSince1970: seconds)))
            }
        }
        return pages
    }
}
