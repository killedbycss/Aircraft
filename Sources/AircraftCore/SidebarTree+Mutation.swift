import Foundation

extension SidebarTree {
    // MARK: Изменение

    @discardableResult
    public mutating func removeNode(_ id: UUID) -> SidebarNode? {
        func remove(from nodes: inout [SidebarNode]) -> SidebarNode? {
            if let index = nodes.firstIndex(where: { $0.id == id }) { return nodes.remove(at: index) }
            for index in nodes.indices {
                guard case .folder(var folder) = nodes[index] else { continue }
                if let removed = remove(from: &folder.children) {
                    nodes[index] = .folder(folder)
                    return removed
                }
            }
            return nil
        }
        return remove(from: &favorites) ?? remove(from: &pinned) ?? remove(from: &regular)
    }

    /// Вставка в контейнер; `index == nil` — в конец. Возвращает false, если нарушается лимит.
    @discardableResult
    public mutating func insert(_ node: SidebarNode, into container: SidebarContainer, at index: Int? = nil) -> Bool {
        guard canInsert(node, into: container) else { return false }
        return modifyNodes(in: container) { nodes in
            let position = min(max(index ?? nodes.count, 0), nodes.count)
            nodes.insert(node, at: position)
        }
    }

    /// Переносит узел в контейнер. Если перенос невозможен — дерево не меняется.
    @discardableResult
    public mutating func move(_ id: UUID, to container: SidebarContainer, at index: Int? = nil) -> Bool {
        guard let source = location(of: id) else { return false }
        var copy = self
        guard let node = copy.removeNode(id), copy.canInsert(node, into: container) else { return false }
        var target = index
        // Перенос внутри одного контейнера ниже по списку: индекс сдвигается после удаления.
        if let value = index, source.container == container, source.index < value { target = value - 1 }
        guard copy.insert(node, into: container, at: target) else { return false }
        self = copy
        return true
    }

    /// Ставит узел перед другим узлом (в его контейнер).
    @discardableResult
    public mutating func move(_ id: UUID, before targetID: UUID) -> Bool {
        guard id != targetID, let target = location(of: targetID) else { return false }
        return move(id, to: target.container, at: target.index)
    }

    /// Ставит узел после другого узла.
    @discardableResult
    public mutating func move(_ id: UUID, after targetID: UUID) -> Bool {
        guard id != targetID, let target = location(of: targetID) else { return false }
        return move(id, to: target.container, at: target.index + 1)
    }

    /// Новая вкладка сразу после `anchor` в том же контейнере (или в конец обычной зоны).
    /// Рядом с плиткой или закреплённой вкладкой новая вкладка не встаёт: она уходит
    /// в начало обычных вкладок, иначе ссылка из другого приложения превращалась в плитку.
    public mutating func insertTab(_ id: UUID, after anchor: UUID?) {
        if let anchor, let location = location(of: anchor) {
            if location.container.zone == .regular {
                insert(.tab(id), into: location.container, at: location.index + 1)
            } else {
                regular.insert(.tab(id), at: 0)
            }
        } else {
            regular.append(.tab(id))
        }
    }

    public mutating func appendTab(_ id: UUID, zone: SidebarZone = .regular) {
        switch zone {
        case .favorites: favorites.append(.tab(id))
        case .pinned: pinned.append(.tab(id))
        case .regular: regular.append(.tab(id))
        }
    }

    func rootNodes(_ zone: SidebarZone) -> [SidebarNode] {
        switch zone {
        case .favorites: favorites
        case .pinned: pinned
        case .regular: regular
        }
    }

    /// Вкладка открыта со страницы `opener`. Если родитель лежит в корне обычной зоны,
    /// создаётся группа из родителя и новой вкладки; в группе или папке вкладка встаёт
    /// после `anchor` (родителя или последней открытой им вкладки). Возвращает id новой группы.
    @discardableResult
    public mutating func insertOpenedTab(_ id: UUID, opener: UUID, anchor: UUID, grouping: Bool,
                                         groupTitle: String) -> UUID? {
        guard let location = location(of: opener) else {
            regular.append(.tab(id))
            return nil
        }
        if location.container.zone != .regular {
            // Из закреплённой вкладки — в начало обычной зоны, подряд за уже открытыми.
            if let anchorLocation = self.location(of: anchor), anchor != opener, anchorLocation.container.zone == .regular {
                insert(.tab(id), into: anchorLocation.container, at: anchorLocation.index + 1)
            } else {
                regular.insert(.tab(id), at: 0)
            }
            return nil
        }
        if location.container.folderID == nil, grouping {
            let group = TabFolder(title: groupTitle, kind: .group, colorIndex: nextGroupColor(),
                                  children: [.tab(opener), .tab(id)])
            regular[location.index] = .folder(group)
            return group.id
        }
        insertTab(id, after: anchor)
        return nil
    }

    /// Создаёт папку из выбранных узлов. Папка встаёт на место первого из них.
    @discardableResult
    public mutating func createFolder(title: String, kind: FolderKind = .folder, containing ids: [UUID],
                                      in container: SidebarContainer? = nil) -> UUID? {
        let target: SidebarContainer
        var position: Int?
        if let first = ids.first, let location = location(of: first) {
            target = container ?? location.container
            position = container == nil ? location.index : nil
        } else {
            target = container ?? .regularRoot
        }
        guard canCreateFolder(in: target) else { return nil }
        var folder = TabFolder(title: title, kind: kind, colorIndex: kind == .group ? nextGroupColor() : 0)
        let insertionDepth = depth(of: target) + 1
        var copy = self
        for id in ids {
            guard let node = copy.removeNode(id) else { continue }
            if kind == .group, case .folder = node { return nil }
            guard insertionDepth + node.folderHeight <= Self.maxFolderDepth else { return nil }
            folder.children.append(node)
        }
        // После удаления узлов позиция могла сдвинуться.
        if let index = position {
            let removedBefore = ids.compactMap { location(of: $0) }
                .filter { $0.container == target && $0.index < index }.count
            position = index - removedBefore
        }
        guard copy.insert(.folder(folder), into: target, at: position) else { return nil }
        self = copy
        return folder.id
    }

    /// Убирает папку или группу, оставляя её содержимое на её месте.
    public mutating func dissolve(_ folderID: UUID) {
        guard let location = location(of: folderID), let folder = folder(folderID) else { return }
        modifyNodes(in: location.container) { nodes in
            nodes.remove(at: location.index)
            nodes.insert(contentsOf: folder.children, at: location.index)
        }
    }

    public mutating func updateFolder(_ id: UUID, _ change: (inout TabFolder) -> Void) {
        func update(_ nodes: inout [SidebarNode]) -> Bool {
            for index in nodes.indices {
                guard case .folder(var folder) = nodes[index] else { continue }
                if folder.id == id {
                    change(&folder)
                    nodes[index] = .folder(folder)
                    return true
                }
                if update(&folder.children) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
            return false
        }
        if !update(&pinned) { update(&regular) }
    }

    /// Группы из одной вкладки или пустые — распускаются. Пустые папки остаются.
    public mutating func dissolveSmallGroups() {
        func clean(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.flatMap { node -> [SidebarNode] in
                guard case .folder(var folder) = node else { return [node] }
                folder.children = clean(folder.children)
                if folder.kind == .group, folder.children.count < 2 { return folder.children }
                return [.folder(folder)]
            }
        }
        pinned = clean(pinned)
        regular = clean(regular)
    }

    /// Убирает вкладки, которых больше нет, и добавляет в конец те, что не попали в дерево.
    public mutating func reconcile(with tabIDs: [UUID], pinnedIDs: Set<UUID> = []) {
        favorites = favorites.filter { if case .tab = $0 { return true } else { return false } }
        let valid = Set(tabIDs)
        func clean(_ nodes: [SidebarNode], seen: inout Set<UUID>) -> [SidebarNode] {
            nodes.compactMap { node in
                switch node {
                case .tab(let id):
                    guard valid.contains(id), seen.insert(id).inserted else { return nil }
                    return node
                case .folder(var folder):
                    folder.children = clean(folder.children, seen: &seen)
                    return .folder(folder)
                }
            }
        }
        var seen = Set<UUID>()
        favorites = clean(favorites, seen: &seen)
        pinned = clean(pinned, seen: &seen)
        regular = clean(regular, seen: &seen)
        for id in tabIDs where !seen.contains(id) {
            appendTab(id, zone: pinnedIDs.contains(id) ? .pinned : .regular)
        }
        dissolveSmallGroups()
    }

    /// Раскрывает все папки на пути к вкладке.
    public mutating func reveal(_ id: UUID) {
        guard let location = location(of: id) else { return }
        for folderID in location.ancestors {
            updateFolder(folderID) { $0.isExpanded = true }
        }
    }

    /// Вкладки, видимые в списке (без содержимого свёрнутых папок).
    public var visibleTabIDs: [UUID] {
        func visible(_ nodes: [SidebarNode]) -> [UUID] {
            nodes.flatMap { node -> [UUID] in
                switch node {
                case .tab(let id): [id]
                case .folder(let folder): folder.isExpanded ? visible(folder.children) : []
                }
            }
        }
        return visible(favorites) + visible(pinned) + visible(regular)
    }

    func nextGroupColor() -> Int {
        var used: [Int: Int] = [:]
        func count(_ nodes: [SidebarNode]) {
            for case .folder(let folder) in nodes {
                if folder.kind == .group { used[folder.colorIndex, default: 0] += 1 }
                count(folder.children)
            }
        }
        count(regular)
        return (0..<Self.groupColorCount).min { used[$0, default: 0] < used[$1, default: 0] } ?? 0
    }

    @discardableResult
    private mutating func modifyNodes(in container: SidebarContainer, _ body: (inout [SidebarNode]) -> Void) -> Bool {
        guard let folderID = container.folderID else {
            switch container.zone {
            case .favorites: body(&favorites)
            case .pinned: body(&pinned)
            case .regular: body(&regular)
            }
            return true
        }
        var found = false
        updateFolder(folderID) { folder in
            body(&folder.children)
            found = true
        }
        return found
    }
}

extension SidebarNode {
    func contains(folder id: UUID) -> Bool {
        guard case .folder(let folder) = self else { return false }
        return folder.children.contains { $0.id == id || $0.contains(folder: id) }
    }
}
