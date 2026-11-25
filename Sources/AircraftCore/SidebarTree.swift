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
    /// Цвет папки (индекс палитры); nil — без цвета. У групп цвет — `colorIndex`.
    public var folderColor: Int?
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

    public var tabIDs: [UUID] {
        switch self {
        case .tab(let id): [id]
        case .folder(let folder): folder.children.flatMap(\.tabIDs)
        }
    }
}

public enum SidebarZone: String, Codable, Sendable {
    /// Плитки избранных сайтов над списком (как в Arc). Только вкладки, без папок.
    case favorites
    case pinned, regular
}

/// Контейнер в дереве: корень зоны или папка.
public struct SidebarContainer: Equatable, Sendable {
    public var zone: SidebarZone
    public var folderID: UUID?

    public init(zone: SidebarZone, folderID: UUID?) {
        self.zone = zone
        self.folderID = folderID
    }

    public static let regularRoot = SidebarContainer(zone: .regular, folderID: nil)
    public static let pinnedRoot = SidebarContainer(zone: .pinned, folderID: nil)
    public static let favoritesRoot = SidebarContainer(zone: .favorites, folderID: nil)
}

/// Порядок вкладок, папки и группы одного окна. Сами вкладки хранятся в `TabManager.tabs`,
/// дерево задаёт только их место.
public struct SidebarTree: Codable, Equatable, Sendable {
    /// Папка → подпапка → подподпапка. Глубже нельзя.
    public static let maxFolderDepth = 3
    public static let groupColorCount = 8

    public var favorites: [SidebarNode] = []
    public var pinned: [SidebarNode] = []
    public var regular: [SidebarNode] = []

    public init(favorites: [SidebarNode] = [], pinned: [SidebarNode] = [], regular: [SidebarNode] = []) {
        self.favorites = favorites
        self.pinned = pinned
        self.regular = regular
    }

    private enum CodingKeys: String, CodingKey { case favorites, pinned, regular }

    /// Сессии до появления плиток не знают о `favorites`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try container.decodeIfPresent([SidebarNode].self, forKey: .favorites) ?? []
        pinned = try container.decodeIfPresent([SidebarNode].self, forKey: .pinned) ?? []
        regular = try container.decodeIfPresent([SidebarNode].self, forKey: .regular) ?? []
    }

    // MARK: Чтение

    /// Все вкладки в порядке отображения (включая свёрнутые папки).
    public var orderedTabIDs: [UUID] { (favorites + pinned + regular).flatMap(\.tabIDs) }

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
        return find(favorites, zone: .favorites, parent: nil, path: [])
            ?? find(pinned, zone: .pinned, parent: nil, path: [])
            ?? find(regular, zone: .regular, parent: nil, path: [])
    }

    /// Глубина контейнера: 0 — корень, 1 — папка в корне и так далее.
    public func depth(of container: SidebarContainer) -> Int {
        guard let folderID = container.folderID, let location = location(of: folderID) else { return 0 }
        return location.ancestors.count + 1
    }

    public func nodes(in container: SidebarContainer) -> [SidebarNode] {
        guard let folderID = container.folderID else { return rootNodes(container.zone) }
        return folder(folderID)?.children ?? []
    }

    /// Можно ли положить узел в контейнер: лимит глубины, в группе — только вкладки,
    /// папку нельзя положить в саму себя.
    public func canInsert(_ node: SidebarNode, into container: SidebarContainer) -> Bool {
        if container.zone == .favorites, case .folder = node { return false }
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
        if container.zone == .favorites { return false }
        if let folderID = container.folderID, folder(folderID)?.kind == .group { return false }
        return depth(of: container) < Self.maxFolderDepth
    }
}
