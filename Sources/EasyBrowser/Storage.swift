import Foundation
import SQLite3

/// Папки с данными Aircraft: `~/Library/Application Support/aircraft/…`.
enum AircraftPaths {
    static var root: URL {
        // Отдельная папка данных для тестов и отладки.
        if let custom = ProcessInfo.processInfo.environment["AIRCRAFT_DATA_DIR"], !custom.isEmpty {
            return ensure(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ensure(support.appendingPathComponent("aircraft", isDirectory: true))
    }

    static var profilesRoot: URL { ensure(root.appendingPathComponent("Profiles", isDirectory: true)) }

    static func profileDirectory(_ id: UUID) -> URL {
        ensure(profilesRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Временные файлы просмотрщиков (PDF): чистятся при запуске.
    static var viewerCache: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent("aircraft-viewer", isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Небольшие JSON-файлы: чтение и атомарная запись.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Тонкая обёртка над системным SQLite, без зависимостей.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL?) {
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
    }

    /// Открывает чужую базу только на чтение (импорт из других браузеров).
    init?(readOnly url: URL) {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
    }

    deinit { sqlite3_close(handle) }

    enum Value {
        case int(Int64), double(Double), text(String), null
    }

    @discardableResult
    func execute(_ sql: String, _ arguments: [Value] = []) -> Bool {
        guard let statement = prepare(sql, arguments) else { return false }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        return result == SQLITE_DONE
    }

    func query(_ sql: String, _ arguments: [Value] = [], row: (Row) -> Void) {
        guard let statement = prepare(sql, arguments) else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(Row(statement: statement)) }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    struct Row {
        let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }
    }
}
