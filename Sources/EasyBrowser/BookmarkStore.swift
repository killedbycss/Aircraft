import Foundation
import Observation

/// Закладка или папка закладок (у папки нет адреса).
public struct BookmarkItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var children: [BookmarkItem]
    public var added: Date

    public var isFolder: Bool { url == nil }

    public init(id: UUID = UUID(), title: String, url: URL?, children: [BookmarkItem] = [], added: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
        self.added = added
    }

    /// Сколько уровней папок внутри, включая саму папку.
    var folderHeight: Int {
        guard isFolder else { return 0 }
        return 1 + (children.map(\.folderHeight).max() ?? 0)
    }
}

/// Закладка с путём папок — для поиска и Spotlight.
public struct BookmarkMatch: Identifiable, Equatable {
    public var item: BookmarkItem
    public var path: [String]
    public var id: UUID { item.id }
}

@MainActor
@Observable
public final class BookmarkStore {
    /// Тот же лимит, что у папок вкладок.
    public static let maxFolderDepth = SidebarTree.maxFolderDepth

    public private(set) var items: [BookmarkItem] = []
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var urlIndex: Set<String> = []

    init(url: URL?) {
        self.url = url
        if let url { items = JSONFile.load([BookmarkItem].self, from: url) ?? [] }
        rebuildIndex()
    }

    // MARK: Чтение

    public func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return urlIndex.contains(Self.key(url))
    }

    public func bookmark(for url: URL?) -> BookmarkItem? {
        guard let url else { return nil }
        let key = Self.key(url)
        return all.first { $0.item.url.map(Self.key) == key }?.item
    }

    /// Все закладки (без папок) с путями.
    public var all: [BookmarkMatch] {
        var result: [BookmarkMatch] = []
        func walk(_ nodes: [BookmarkItem], path: [String]) {
            for node in nodes {
                if node.isFolder { walk(node.children, path: path + [node.title]) }
                else { result.append(BookmarkMatch(item: node, path: path)) }
            }
        }
        walk(items, path: [])
        return result
    }

    /// Все папки с путями и глубиной — для выбора папки при добавлении.
    public var folders: [(item: BookmarkItem, depth: Int)] {
        var result: [(BookmarkItem, Int)] = []
        func walk(_ nodes: [BookmarkItem], depth: Int) {
            for node in nodes where node.isFolder {
                result.append((node, depth))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(items, depth: 1)
        return result
    }

    public func search(_ query: String, limit: Int = 6) -> [BookmarkMatch] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return all.filter { match in
            let haystack = (match.item.title + " " + (match.item.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        .prefix(limit).map { $0 }
    }

    public func depth(ofFolder id: UUID?) -> Int {
        guard let id else { return 0 }
        return folders.first { $0.item.id == id }?.depth ?? 0
    }

    // MARK: Изменение

    @discardableResult
    public func add(title: String, url: URL, to folderID: UUID? = nil) -> BookmarkItem {
        let item = BookmarkItem(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url)
        insert(item, into: folderID)
        return item
    }

    @discardableResult
    public func addFolder(title: String, in parentID: UUID? = nil) -> BookmarkItem? {
        guard depth(ofFolder: parentID) < Self.maxFolderDepth else { return nil }
        let folder = BookmarkItem(title: title, url: nil)
        insert(folder, into: parentID)
        return folder
    }

    /// Импорт: папка с содержимым; слишком глубокие уровни сплющиваются до лимита.
    public func addImported(_ folder: BookmarkItem) {
        insert(Self.clamp(folder, depth: 1), into: nil)
    }

    public func remove(_ id: UUID) {
        _ = Self.remove(id, from: &items)
        changed()
    }

    public func update(_ id: UUID, title: String, url: URL?) {
        Self.update(id, in: &items) { item in
            item.title = title
            if !item.isFolder, let url { item.url = url }
        }
        changed()
    }

    /// Переносит закладку или папку в другую папку (nil — корень).
    @discardableResult
    public func move(_ id: UUID, to folderID: UUID?, at index: Int? = nil) -> Bool {
        if id == folderID { return false }
        var copy = items
        guard let node = Self.remove(id, from: &copy) else { return false }
        if node.isFolder, let folderID, Self.find(folderID, in: node.children) != nil { return false }
        let targetDepth = depthIn(copy, folderID)
        guard targetDepth + node.folderHeight <= Self.maxFolderDepth else { return false }
        guard Self.insert(node, into: folderID, at: index, in: &copy) else { return false }
        items = copy
        changed()
        return true
    }

    private func insert(_ item: BookmarkItem, into folderID: UUID?) {
        _ = Self.insert(item, into: folderID, at: nil, in: &items)
        changed()
    }

    private func depthIn(_ nodes: [BookmarkItem], _ folderID: UUID?) -> Int {
        guard let folderID else { return 0 }
        func walk(_ nodes: [BookmarkItem], depth: Int) -> Int? {
            for node in nodes where node.isFolder {
                if node.id == folderID { return depth }
                if let found = walk(node.children, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(nodes, depth: 1) ?? 0
    }

    private func changed() {
        rebuildIndex()
        if let url { JSONFile.save(items, to: url) }
    }

    private func rebuildIndex() {
        urlIndex = Set(all.compactMap { $0.item.url.map(Self.key) })
    }

    // MARK: Дерево

    static func key(_ url: URL) -> String {
        var value = url.absoluteString
        if value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }

    private static func clamp(_ item: BookmarkItem, depth: Int) -> BookmarkItem {
        guard item.isFolder else { return item }
        var copy = item
        if depth >= maxFolderDepth {
            // На последнем уровне вложенные папки разворачиваются в плоский список.
            func flatten(_ nodes: [BookmarkItem]) -> [BookmarkItem] {
                nodes.flatMap { $0.isFolder ? flatten($0.children) : [$0] }
            }
            copy.children = flatten(item.children)
        } else {
            copy.children = item.children.map { clamp($0, depth: depth + 1) }
        }
        return copy
    }

    private static func find(_ id: UUID, in nodes: [BookmarkItem]) -> BookmarkItem? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }

    private static func remove(_ id: UUID, from nodes: inout [BookmarkItem]) -> BookmarkItem? {
        if let index = nodes.firstIndex(where: { $0.id == id }) { return nodes.remove(at: index) }
        for index in nodes.indices {
            if let removed = remove(id, from: &nodes[index].children) { return removed }
        }
        return nil
    }

    @discardableResult
    private static func update(_ id: UUID, in nodes: inout [BookmarkItem], _ change: (inout BookmarkItem) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                change(&nodes[index])
                return true
            }
            if update(id, in: &nodes[index].children, change) { return true }
        }
        return false
    }

    private static func insert(_ item: BookmarkItem, into folderID: UUID?, at index: Int?, in nodes: inout [BookmarkItem]) -> Bool {
        guard let folderID else {
            nodes.insert(item, at: min(index ?? nodes.count, nodes.count))
            return true
        }
        return update(folderID, in: &nodes) { folder in
            folder.children.insert(item, at: min(index ?? folder.children.count, folder.children.count))
        }
    }
}
