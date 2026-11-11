import Foundation

/// Папка — постоянная, создаётся вручную и может вкладываться в другие папки.
/// Группа — набор вкладок, который появляется сам, когда ссылку открывают в новой вкладке.
public enum FolderKind: String, Codable, Sendable {
    case folder, group
}

public struct TabFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: FolderKind
    public var colorIndex: Int
    public var isExpanded: Bool
    public var children: [SidebarNode]

    public init(id: UUID = UUID(), title: String, kind: FolderKind, colorIndex: Int = 0,
                isExpanded: Bool = true, children: [SidebarNode] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.colorIndex = colorIndex
        self.isExpanded = isExpanded
        self.children = children
    }
}

public enum SidebarNode: Codable, Equatable, Identifiable, Sendable {
    case tab(UUID)
    case folder(TabFolder)

    public var id: UUID {
        switch self {
        case .tab(let id): id
        case .folder(let folder): folder.id
        }
    }

    var folder: TabFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    /// Сколько уровней папок внутри узла, включая его самого (у вкладки — 0).
    var folderHeight: Int {
        guard case .folder(let folder) = self else { return 0 }
        return 1 + (folder.children.map(\.folderHeight).max() ?? 0)
    }

    var tabIDs: [UUID] {
        switch self {
        case .tab(let id): [id]
        case .folder(let folder): folder.children.flatMap(\.tabIDs)
        }
    }
}

public enum SidebarZone: String, Codable, Sendable {
    case pinned, regular
}

/// Контейнер в дереве: корень зоны или папка.
public struct SidebarContainer: Equatable, Sendable {
    public var zone: SidebarZone
    public var folderID: UUID?

    public static let regularRoot = SidebarContainer(zone: .regular, folderID: nil)
    public static let pinnedRoot = SidebarContainer(zone: .pinned, folderID: nil)
}

/// Порядок вкладок, папки и группы одного окна. Сами вкладки хранятся в `TabManager.tabs`,
/// дерево задаёт только их место.
public struct SidebarTree: Codable, Equatable, Sendable {
    /// Папка → подпапка → подподпапка. Глубже нельзя.
    public static let maxFolderDepth = 3
    public static let groupColorCount = 8

    public var pinned: [SidebarNode] = []
    public var regular: [SidebarNode] = []

    public init(pinned: [SidebarNode] = [], regular: [SidebarNode] = []) {
        self.pinned = pinned
        self.regular = regular
    }

    // MARK: Чтение

    /// Все вкладки в порядке отображения (включая свёрнутые папки).
    public var orderedTabIDs: [UUID] { (pinned + regular).flatMap(\.tabIDs) }

    public func contains(tab id: UUID) -> Bool { location(of: id) != nil }

    public func zone(of id: UUID) -> SidebarZone? { location(of: id)?.container.zone }

    public func folder(_ id: UUID) -> TabFolder? {
        func find(_ nodes: [SidebarNode]) -> TabFolder? {
            for node in nodes {
                guard case .folder(let folder) = node else { continue }
                if folder.id == id { return folder }
                if let found = find(folder.children) { return found }
            }
            return nil
        }
        return find(pinned) ?? find(regular)
    }

    public struct Location: Equatable {
        public var container: SidebarContainer
        public var index: Int
        /// Папки от корня до узла (не включая сам узел).
        public var ancestors: [UUID]
    }

    /// Где лежит узел (вкладка или папка).
    public func location(of id: UUID) -> Location? {
        func find(_ nodes: [SidebarNode], zone: SidebarZone, parent: UUID?, path: [UUID]) -> Location? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return Location(container: .init(zone: zone, folderID: parent), index: index, ancestors: path) }
                if case .folder(let folder) = node,
                   let found = find(folder.children, zone: zone, parent: folder.id, path: path + [folder.id]) {
                    return found
                }
            }
            return nil
        }
        return find(pinned, zone: .pinned, parent: nil, path: []) ?? find(regular, zone: .regular, parent: nil, path: [])
    }

    /// Глубина контейнера: 0 — корень, 1 — папка в корне и так далее.
    public func depth(of container: SidebarContainer) -> Int {
        guard let folderID = container.folderID, let location = location(of: folderID) else { return 0 }
        return location.ancestors.count + 1
    }

    public func nodes(in container: SidebarContainer) -> [SidebarNode] {
        guard let folderID = container.folderID else { return container.zone == .pinned ? pinned : regular }
        return folder(folderID)?.children ?? []
    }

    /// Можно ли положить узел в контейнер: лимит глубины, в группе — только вкладки,
    /// папку нельзя положить в саму себя.
    public func canInsert(_ node: SidebarNode, into container: SidebarContainer) -> Bool {
        if let folderID = container.folderID {
            guard let target = folder(folderID) else { return false }
            if target.kind == .group, case .folder = node { return false }
            if node.id == folderID { return false }
            if case .folder(let moving) = node, SidebarNode.folder(moving).contains(folder: folderID) { return false }
        }
        return depth(of: container) + node.folderHeight <= Self.maxFolderDepth
    }

    /// Можно ли создать новую папку внутри контейнера.
    public func canCreateFolder(in container: SidebarContainer) -> Bool {
        if let folderID = container.folderID, folder(folderID)?.kind == .group { return false }
        return depth(of: container) < Self.maxFolderDepth
    }

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
        return remove(from: &pinned) ?? remove(from: &regular)
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
    public mutating func insertTab(_ id: UUID, after anchor: UUID?) {
        if let anchor, let location = location(of: anchor) {
            insert(.tab(id), into: location.container, at: location.index + 1)
        } else {
            regular.append(.tab(id))
        }
    }

    public mutating func appendTab(_ id: UUID, zone: SidebarZone = .regular) {
        if zone == .pinned { pinned.append(.tab(id)) } else { regular.append(.tab(id)) }
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
        if location.container.zone == .pinned {
            // Из закреплённой вкладки — в начало обычной зоны, подряд за уже открытыми.
            if let anchorLocation = self.location(of: anchor), anchor != opener {
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
        return visible(pinned) + visible(regular)
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
            if container.zone == .pinned { body(&pinned) } else { body(&regular) }
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
