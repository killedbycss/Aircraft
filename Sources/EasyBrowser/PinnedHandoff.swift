import Foundation

/// Закреплённые вкладки и плитки не должны пропадать, когда закрывают одно из окон.
/// Раньше окно при закрытии (пока открыты другие) удалялось из сессии вместе со всеми
/// своими закрепами.
extension TabManager {
    /// Закреплённые вкладки и плитки закрывающегося окна переходят в это окно.
    /// Дубликаты (тот же адрес) пропускаются, папки сохраняются.
    func adoptPinned(from other: TabManager) {
        if other.profileID == profileID {
            var known = Set(tabs.compactMap { ($0.pinnedURL ?? $0.url).map(BookmarkStore.key) })
            var added: [TabModel] = []
            let favorites = Self.copyPinned(other.tree.favorites, tabs: other.tabs, known: &known, added: &added)
            let pinned = Self.copyPinned(other.tree.pinned, tabs: other.tabs, known: &known, added: &added)
            guard !added.isEmpty else { return }
            tabs.append(contentsOf: added)
            tree.favorites += favorites
            tree.pinned += pinned
            finishTreeChange()
        } else {
            // Окно сейчас показывает другой профиль — дописываем в сохранённые вкладки того профиля.
            let key = other.profileID.uuidString
            var set = otherSets[key] ?? SavedTabSet()
            var known = Set(set.tabs.compactMap { ($0.pinnedURL ?? $0.url).map(BookmarkStore.key) })
            var added: [TabModel] = []
            let favorites = Self.copyPinned(other.tree.favorites, tabs: other.tabs, known: &known, added: &added)
            let pinned = Self.copyPinned(other.tree.pinned, tabs: other.tabs, known: &known, added: &added)
            guard !added.isEmpty else { return }
            set.tabs += added.map {
                SavedTab(id: $0.id, title: $0.title, url: $0.url, isPinned: true, pinnedURL: $0.pinnedURL,
                         lastActiveAt: $0.lastActiveAt, interactionState: nil)
            }
            set.tree.favorites += favorites
            set.tree.pinned += pinned
            otherSets[key] = set
            saveSession()
        }
    }

    private static func copyPinned(_ nodes: [SidebarNode], tabs: [TabModel], known: inout Set<String>,
                                   added: inout [TabModel]) -> [SidebarNode] {
        nodes.compactMap { node -> SidebarNode? in
            switch node {
            case .tab(let id):
                guard let tab = tabs.first(where: { $0.id == id }), let url = tab.pinnedURL ?? tab.url,
                      known.insert(BookmarkStore.key(url)).inserted else { return nil }
                let copy = TabModel(id: UUID(), title: tab.title, url: url, isHibernated: true, isPinned: true,
                                    pinnedURL: url, favicon: tab.favicon)
                added.append(copy)
                return .tab(copy.id)
            case .folder(var folder):
                folder.id = UUID()
                folder.children = copyPinned(folder.children, tabs: tabs, known: &known, added: &added)
                return folder.children.isEmpty ? nil : .folder(folder)
            }
        }
    }
}
