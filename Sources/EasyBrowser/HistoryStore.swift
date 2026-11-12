import Foundation
import Observation

public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var url: URL
    public var title: String
    public var host: String
    public var visitCount: Int
    public var lastVisit: Date
}

/// История профиля в SQLite с полнотекстовым поиском (FTS5).
@MainActor
@Observable
public final class HistoryStore {
    @ObservationIgnored private let db: SQLiteDatabase?
    /// Меняется при любой записи, чтобы окно истории перерисовалось.
    public private(set) var revision = 0

    init(url: URL?) {
        db = SQLiteDatabase(url: url)
        db?.execute("""
        CREATE TABLE IF NOT EXISTS pages(
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            host TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 0,
            typed_count INTEGER NOT NULL DEFAULT 0,
            last_visit REAL NOT NULL DEFAULT 0)
        """)
        db?.execute("CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, page_id INTEGER NOT NULL, visited_at REAL NOT NULL)")
        db?.execute("CREATE INDEX IF NOT EXISTS visits_time ON visits(visited_at)")
        db?.execute("CREATE INDEX IF NOT EXISTS pages_host ON pages(host)")
        db?.execute("CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(title, url, content='pages', content_rowid='id', tokenize='unicode61')")
        db?.execute("CREATE TRIGGER IF NOT EXISTS pages_ai AFTER INSERT ON pages BEGIN INSERT INTO pages_fts(rowid, title, url) VALUES (new.id, new.title, new.url); END")
        db?.execute("CREATE TRIGGER IF NOT EXISTS pages_ad AFTER DELETE ON pages BEGIN INSERT INTO pages_fts(pages_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url); END")
        db?.execute("CREATE TRIGGER IF NOT EXISTS pages_au AFTER UPDATE OF title, url ON pages BEGIN INSERT INTO pages_fts(pages_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url); INSERT INTO pages_fts(rowid, title, url) VALUES (new.id, new.title, new.url); END")
    }

    // MARK: Запись

    public func recordVisit(url: URL, title: String, typed: Bool = false, at date: Date = Date()) {
        guard let db, Self.isRecordable(url) else { return }
        let key = url.absoluteString
        let host = Self.displayHost(url)
        db.execute("""
        INSERT INTO pages(url, title, host, visit_count, typed_count, last_visit) VALUES (?, ?, ?, 1, ?, ?)
        ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, typed_count = typed_count + excluded.typed_count,
            last_visit = excluded.last_visit, title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
        """, [.text(key), .text(title), .text(host), .int(typed ? 1 : 0), .double(date.timeIntervalSince1970)])
        db.query("SELECT id FROM pages WHERE url = ?", [.text(key)]) { row in
            db.execute("INSERT INTO visits(page_id, visited_at) VALUES (?, ?)", [.int(row.int(0)), .double(date.timeIntervalSince1970)])
        }
        revision += 1
    }

    public func updateTitle(url: URL, title: String) {
        guard let db, !title.isEmpty, Self.isRecordable(url) else { return }
        db.execute("UPDATE pages SET title = ? WHERE url = ? AND title != ?", [.text(title), .text(url.absoluteString), .text(title)])
    }

    /// Импорт из другого браузера: добавляет страницу, не трогая уже известные.
    func importPage(url: URL, title: String, visitCount: Int, lastVisit: Date) {
        guard let db, Self.isRecordable(url) else { return }
        db.execute("""
        INSERT INTO pages(url, title, host, visit_count, last_visit) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET visit_count = max(visit_count, excluded.visit_count),
            last_visit = max(last_visit, excluded.last_visit)
        """, [.text(url.absoluteString), .text(title), .text(Self.displayHost(url)), .int(Int64(max(visitCount, 1))),
              .double(lastVisit.timeIntervalSince1970)])
    }

    func beginBatch() { db?.execute("BEGIN") }
    func endBatch() {
        db?.execute("COMMIT")
        revision += 1
    }

    // MARK: Чтение

    /// Поиск для Spotlight: совпадения по началу слов в заголовке и адресе, сортировка по частоте и давности.
    public func search(_ query: String, limit: Int = 8) -> [HistoryEntry] {
        guard let db, let match = Self.ftsQuery(query) else { return [] }
        var result: [HistoryEntry] = []
        let now = Date().timeIntervalSince1970
        db.query("""
        SELECT p.id, p.url, p.title, p.host, p.visit_count, p.last_visit,
               (p.visit_count + p.typed_count * 2) * (100.0 / (1.0 + (? - p.last_visit) / 86400.0)) AS score
        FROM pages_fts f JOIN pages p ON p.id = f.rowid
        WHERE pages_fts MATCH ?
        ORDER BY score DESC LIMIT ?
        """, [.double(now), .text(match), .int(Int64(limit))]) { row in
            if let entry = Self.entry(row) { result.append(entry) }
        }
        return result
    }

    /// Самый посещаемый адрес, начинающийся с введённого текста: «git» → «github.com».
    public func autocompleteHost(_ prefix: String) -> String? {
        let value = prefix.lowercased().trimmingCharacters(in: .whitespaces)
        guard let db, value.count >= 2, !value.contains(" ") else { return nil }
        var best: String?
        db.query("""
        SELECT host, sum(visit_count + typed_count * 2) AS score FROM pages
        WHERE host LIKE ? ESCAPE '\\' GROUP BY host ORDER BY score DESC LIMIT 1
        """, [.text(Self.likeEscaped(value) + "%")]) { row in best = row.text(0) }
        return best
    }

    /// Последние посещения для окна истории.
    public func recent(matching filter: String = "", limit: Int = 300) -> [HistoryEntry] {
        guard let db else { return [] }
        var result: [HistoryEntry] = []
        if let match = Self.ftsQuery(filter) {
            db.query("""
            SELECT p.id, p.url, p.title, p.host, p.visit_count, p.last_visit FROM pages_fts f JOIN pages p ON p.id = f.rowid
            WHERE pages_fts MATCH ? ORDER BY p.last_visit DESC LIMIT ?
            """, [.text(match), .int(Int64(limit))]) { row in
                if let entry = Self.entry(row) { result.append(entry) }
            }
        } else {
            db.query("SELECT id, url, title, host, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ?",
                     [.int(Int64(limit))]) { row in
                if let entry = Self.entry(row) { result.append(entry) }
            }
        }
        return result
    }

    public var isEmpty: Bool {
        var count: Int64 = 0
        db?.query("SELECT count(*) FROM pages") { count = $0.int(0) }
        return count == 0
    }

    // MARK: Удаление

    public func delete(_ entry: HistoryEntry) {
        db?.execute("DELETE FROM visits WHERE page_id = ?", [.int(entry.id)])
        db?.execute("DELETE FROM pages WHERE id = ?", [.int(entry.id)])
        revision += 1
    }

    public func deleteHost(_ host: String) {
        db?.execute("DELETE FROM visits WHERE page_id IN (SELECT id FROM pages WHERE host = ?)", [.text(host)])
        db?.execute("DELETE FROM pages WHERE host = ?", [.text(host)])
        revision += 1
    }

    /// Удаляет посещения начиная с даты; страницы без оставшихся посещений тоже.
    public func delete(since date: Date) {
        guard let db else { return }
        let time = date.timeIntervalSince1970
        db.execute("DELETE FROM visits WHERE visited_at >= ?", [.double(time)])
        db.execute("DELETE FROM pages WHERE last_visit >= ? AND id NOT IN (SELECT DISTINCT page_id FROM visits)", [.double(time)])
        db.execute("""
        UPDATE pages SET last_visit = (SELECT max(visited_at) FROM visits WHERE page_id = pages.id),
            visit_count = (SELECT count(*) FROM visits WHERE page_id = pages.id)
        WHERE last_visit >= ?
        """, [.double(time)])
        revision += 1
    }

    public func clearAll() {
        db?.execute("DELETE FROM visits")
        db?.execute("DELETE FROM pages")
        db?.execute("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild')")
        revision += 1
    }

    // MARK: Вспомогательное

    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    static func displayHost(_ url: URL) -> String {
        guard let host = url.host?.lowercased() else { return url.isFileURL ? "Файлы" : "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Каждое слово запроса — поиск по началу слова: `"git"* "hub"*`.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    private static func likeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func entry(_ row: SQLiteDatabase.Row) -> HistoryEntry? {
        guard let url = URL(string: row.text(1)) else { return nil }
        return HistoryEntry(id: row.int(0), url: url, title: row.text(2), host: row.text(3),
                            visitCount: Int(row.int(4)), lastVisit: Date(timeIntervalSince1970: row.double(5)))
    }
}
