import Foundation
import AppKit

/// Действия с папками и группами в панели вкладок.
extension TabManager {
    /// Узел перетащили на другой узел: вкладка встаёт перед ним, на заголовок папки — внутрь папки.
    @discardableResult
    public func dropNode(_ id: UUID, onto targetID: UUID, intoFolder: Bool) -> Bool {
        guard id != targetID else { return false }
        let moved: Bool
        if intoFolder, let folder = tree.folder(targetID) {
            let container = SidebarContainer(zone: tree.location(of: targetID)?.container.zone ?? .regular, folderID: folder.id)
            moved = tree.move(id, to: container)
            if moved { tree.updateFolder(targetID) { $0.isExpanded = true } }
        } else {
            moved = tree.move(id, before: targetID)
        }
        guard moved else {
            NSSound.beep()
            return false
        }
        finishTreeChange()
        return true
    }

    /// Перенос в конец зоны (корень закреплённых или обычных).
    @discardableResult
    public func dropNode(_ id: UUID, toEndOf zone: SidebarZone) -> Bool {
        guard tree.move(id, to: zone == .pinned ? .pinnedRoot : .regularRoot) else {
            NSSound.beep()
            return false
        }
        finishTreeChange()
        return true
    }

    /// Новая пустая папка; появляется в режиме переименования.
    public func createFolder(in parentID: UUID? = nil, zone: SidebarZone = .regular) {
        let container = SidebarContainer(zone: parentID.flatMap { tree.location(of: $0)?.container.zone } ?? zone, folderID: parentID)
        guard tree.canCreateFolder(in: container) else {
            NSSound.beep()
            return
        }
        let folder = TabFolder(title: "Новая папка", kind: .folder)
        tree.insert(.folder(folder), into: container, at: parentID == nil ? nil : 0)
        if let parentID { tree.updateFolder(parentID) { $0.isExpanded = true } }
        renamingFolderID = folder.id
        finishTreeChange()
    }

    /// Выбранные вкладки (или одна вкладка) — в новую папку или группу.
    public func moveToNewFolder(_ ids: [UUID], kind: FolderKind = .folder) {
        let ordered = tree.orderedTabIDs.filter(ids.contains)
        guard !ordered.isEmpty else { return }
        let title = kind == .group
            ? (tabs.first(where: { $0.id == ordered[0] })?.url.map(HistoryStore.displayHost) ?? "Группа")
            : "Новая папка"
        guard let id = tree.createFolder(title: title, kind: kind, containing: ordered) else {
            NSSound.beep()
            return
        }
        selectedTabIDs = []
        renamingFolderID = id
        finishTreeChange()
    }

    public func renameFolder(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { tree.updateFolder(id) { $0.title = clean } }
        if renamingFolderID == id { renamingFolderID = nil }
        saveSession()
    }

    public func toggleFolderExpanded(_ id: UUID) {
        tree.updateFolder(id) { $0.isExpanded.toggle() }
        saveSession()
    }

    public func setGroupColor(_ id: UUID, colorIndex: Int) {
        tree.updateFolder(id) { $0.colorIndex = colorIndex }
        saveSession()
    }

    /// Убрать папку или группу, оставив вкладки на месте.
    public func dissolveFolder(_ id: UUID) {
        tree.dissolve(id)
        finishTreeChange()
    }

    public func convertGroupToFolder(_ id: UUID) {
        tree.updateFolder(id) { $0.kind = .folder }
        saveSession()
    }

    /// Закрыть все вкладки папки. Больше пяти вкладок — с подтверждением.
    public func closeFolder(_ id: UUID) {
        guard let folder = tree.folder(id) else { return }
        let ids = SidebarNode.folder(folder).tabIDs
        if ids.count > 5 {
            let alert = NSAlert()
            alert.messageText = "Закрыть «\(folder.title)»?"
            alert.informativeText = "В папке \(ids.count) вкладок. Их можно будет вернуть через ⌘⇧T."
            alert.addButton(withTitle: "Закрыть")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for tabID in ids { closeTab(id: tabID) }
        tree.removeNode(id)
        finishTreeChange()
    }

    /// ⌘-клик по вкладке в панели — выделение нескольких вкладок.
    public func toggleSelection(_ id: UUID) {
        if selectedTabIDs.isEmpty, let active = activeTabID, active != id { selectedTabIDs.insert(active) }
        if selectedTabIDs.contains(id) { selectedTabIDs.remove(id) } else { selectedTabIDs.insert(id) }
    }

    func finishTreeChange() {
        tree.dissolveSmallGroups()
        syncPinnedFlags()
        syncTabOrder()
        saveSession()
    }
}
