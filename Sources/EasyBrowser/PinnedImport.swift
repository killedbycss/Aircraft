import Foundation
import AppKit

/// Закрепы из других браузеров. В Arc закреплённые вкладки и «избранное» хранятся
/// не в закладках (файл `Bookmarks` у Arc почти всегда пуст), а в `StorableSidebar.json`, —
/// поэтому раньше из Arc приходила только история.
indirect enum PinnedImportNode: Equatable {
    case tab(title: String, url: URL)
    case folder(title: String, children: [PinnedImportNode])

    var tabCount: Int {
        switch self {
        case .tab: 1
        case .folder(_, let children): children.map(\.tabCount).reduce(0, +)
        }
    }
}

struct PinnedImportResult: Equatable {
    var favorites: [PinnedImportNode] = []
    var pinned: [PinnedImportNode] = []
    var count: Int { (favorites + pinned).map(\.tabCount).reduce(0, +) }
}

extension BrowserImport {
    static var arcSidebarFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    /// Закрепы: в Arc — закреплённые вкладки пространств и избранное (плитки);
    /// в остальных браузерах — панель закладок (её и называют «закрепами»).
    static func readPinned(_ source: Source) throws -> PinnedImportResult {
        if source == .arc {
            guard let data = try? Data(contentsOf: arcSidebarFile) else {
                throw ImportError(message: "Не найден файл боковой панели Arc (StorableSidebar.json).")
            }
            return try parseArcSidebar(data)
        }
        let bookmarks = try readBookmarks(source)
        guard let bar = bookmarks.children.first else { return PinnedImportResult() }
        return PinnedImportResult(pinned: bar.children.compactMap(pinnedNode))
    }

    private static func pinnedNode(_ item: BookmarkItem) -> PinnedImportNode? {
        if let url = item.url { return .tab(title: item.title, url: url) }
        let children = item.children.compactMap(pinnedNode)
        return children.isEmpty ? nil : .folder(title: item.title.isEmpty ? "Папка" : item.title, children: children)
    }

    static func parseArcSidebar(_ data: Data) throws -> PinnedImportResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["items"] != nil }) else {
            throw ImportError(message: "Не удалось разобрать боковую панель Arc.")
        }
        // В массивах Arc чередуются id-строки и объекты; нужны объекты.
        let items = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var byID: [String: [String: Any]] = [:]
        for item in items { if let id = item["id"] as? String { byID[id] = item } }

        func node(_ id: String, depth: Int) -> PinnedImportNode? {
            guard depth < 8, let item = byID[id], let data = item["data"] as? [String: Any] else { return nil }
            if let tab = data["tab"] as? [String: Any] {
                guard let raw = tab["savedURL"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
                let title = (item["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url.host ?? raw
                return .tab(title: title, url: url)
            }
            let children = (item["childrenIds"] as? [String] ?? []).compactMap { node($0, depth: depth + 1) }
            guard !children.isEmpty else { return nil }
            if data["list"] != nil {
                return .folder(title: (item["title"] as? String) ?? "Папка", children: children)
            }
            // Прочие контейнеры — просто их содержимое.
            return .folder(title: (item["title"] as? String) ?? "", children: children)
        }

        func children(of id: String) -> [PinnedImportNode] {
            let ids = byID[id]?["childrenIds"] as? [String] ?? []
            return ids.compactMap { node($0, depth: 1) }.flatMap { child -> [PinnedImportNode] in
                if case .folder(let title, let nested) = child, title.isEmpty { return nested }
                return [child]
            }
        }

        var result = PinnedImportResult()
        let topApps = (main["topAppsContainerIDs"] as? [Any] ?? []).compactMap { $0 as? String }
        for id in topApps { result.favorites += children(of: id).flatMap(flattenTabs) }

        let spaces = (main["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var perSpace: [(String, [PinnedImportNode])] = []
        for space in spaces {
            let ids = space["containerIDs"] as? [Any] ?? []
            guard let marker = ids.firstIndex(where: { ($0 as? String) == "pinned" }), marker + 1 < ids.count,
                  let pinnedID = ids[marker + 1] as? String else { continue }
            let nodes = children(of: pinnedID)
            if !nodes.isEmpty { perSpace.append(((space["title"] as? String) ?? "Пространство", nodes)) }
        }
        // Одно пространство — закрепы в корень; несколько — по папке на пространство.
        if perSpace.count == 1 {
            result.pinned = perSpace[0].1
        } else {
            result.pinned = perSpace.map { .folder(title: $0.0, children: $0.1) }
        }
        return result
    }

    private static func flattenTabs(_ node: PinnedImportNode) -> [PinnedImportNode] {
        switch node {
        case .tab: [node]
        case .folder(_, let children): children.flatMap(flattenTabs)
        }
    }
}

extension TabManager {
    /// Добавляет импортированные закрепы как усыплённые закреплённые вкладки и плитки.
    /// Уже закреплённые адреса пропускаются. Возвращает число добавленных вкладок.
    @discardableResult
    func importPinned(_ result: PinnedImportResult) -> Int {
        var known = Set(tabs.filter(\.isPinned).compactMap { ($0.pinnedURL ?? $0.url).map(BookmarkStore.key) })
        var added: [TabModel] = []
        func build(_ nodes: [PinnedImportNode], depth: Int) -> [SidebarNode] {
            nodes.compactMap { node in
                switch node {
                case .tab(let title, let url):
                    guard known.insert(BookmarkStore.key(url)).inserted else { return nil }
                    let tab = TabModel(id: UUID(), title: title, url: url, isHibernated: true, isPinned: true,
                                       pinnedURL: url, favicon: FaviconCache.shared.image(for: url))
                    added.append(tab)
                    return .tab(tab.id)
                case .folder(let title, let children):
                    // Глубже лимита — вкладки поднимаются на уровень выше.
                    let built = build(children, depth: depth + 1)
                    guard !built.isEmpty else { return nil }
                    if depth >= SidebarTree.maxFolderDepth - 1 {
                        return .folder(TabFolder(title: title, kind: .folder, isExpanded: false, children: built.flatMap(\.tabIDs).map(SidebarNode.tab)))
                    }
                    return .folder(TabFolder(title: title, kind: .folder, isExpanded: false, children: built))
                }
            }
        }
        let favorites = build(result.favorites, depth: 1).flatMap(\.tabIDs).map(SidebarNode.tab)
        let pinned = build(result.pinned, depth: 0)
        guard !added.isEmpty else { return 0 }
        tabs.append(contentsOf: added)
        tree.favorites += favorites
        tree.pinned += pinned
        finishTreeChange()
        for tab in added { FaviconCache.shared.fetchIfNeeded(for: tab.url) }
        return added.count
    }
}
