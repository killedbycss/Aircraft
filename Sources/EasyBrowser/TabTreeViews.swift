import SwiftUI
import AppKit

/// Цвета групп вкладок.
enum GroupPalette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]
    static let names = ["Синий", "Фиолетовый", "Розовый", "Красный", "Оранжевый", "Жёлтый", "Зелёный", "Бирюзовый"]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// Перетаскиваемый узел панели вкладок.
enum TabDragPayload {
    static let prefix = "aircraft-node:"
    static func encode(_ id: UUID) -> String { prefix + id.uuidString }
    static func decode(_ value: String) -> UUID? {
        guard value.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(prefix.count)))
    }
}

enum TabListStyle {
    case sidebar, mobile
}

// MARK: - Список вкладок с папками

/// Закреплённые вкладки, папки, группы и обычные вкладки. Используется в боковой панели
/// и в узком режиме.
struct TabTreeList: View {
    let style: TabListStyle
    var side: String = "left"
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9

    var body: some View {
        VStack(alignment: .leading, spacing: style == .mobile ? 6 : 2) {
            if !tabManager.tree.pinned.isEmpty {
                ZoneHeader(title: "Закреплённые", zone: .pinned)
                ForEach(tabManager.tree.pinned) { node in
                    TabTreeNodeView(node: node, depth: 0, style: style, side: side)
                }
                Divider().padding(.vertical, 4)
            }
            ForEach(tabManager.tree.regular) { node in
                TabTreeNodeView(node: node, depth: 0, style: style, side: side)
            }
            ZoneDropArea(zone: .regular)
        }
        .animation(.tabList, value: tabManager.tree)
    }
}

/// Заголовок зоны: на него можно бросить вкладку, чтобы закрепить её.
private struct ZoneHeader: View {
    let title: String
    let zone: SidebarZone
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var targeted = false

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9 * tabScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .frame(height: 18 * tabScale)
        .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, toEndOf: zone)
        } isTargeted: { targeted = $0 }
    }
}

/// Пустое место под списком: бросить сюда — в конец обычных вкладок.
private struct ZoneDropArea: View {
    let zone: SidebarZone
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(targeted ? Color.accentColor.opacity(0.5) : Color.clear)
            .frame(height: targeted ? 3 : 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
                return tabManager.dropNode(id, toEndOf: zone)
            } isTargeted: { targeted = $0 }
    }
}

struct TabTreeNodeView: View {
    let node: SidebarNode
    let depth: Int
    let style: TabListStyle
    let side: String
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        switch node {
        case .tab(let id):
            if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                TabRow(tab: tab, depth: depth, style: style, groupColor: groupColor)
                    .transition(.tabClose(edge: side == "right" ? .trailing : .leading))
            }
        case .folder(let folder):
            VStack(alignment: .leading, spacing: style == .mobile ? 6 : 2) {
                FolderHeader(folder: folder, depth: depth, style: style)
                if folder.isExpanded {
                    ForEach(folder.children) { child in
                        TabTreeNodeView(node: child, depth: depth + 1, style: style, side: side)
                    }
                }
            }
            .padding(.bottom, folder.kind == .group && folder.isExpanded ? 3 : 0)
            .overlay(alignment: .leading) {
                if folder.kind == .group, folder.isExpanded {
                    // Цветная линия вдоль группы.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(GroupPalette.color(folder.colorIndex))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(depth) * 12 + 3)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var groupColor: Color? { nil }
}

// MARK: - Заголовок папки или группы

private struct FolderHeader: View {
    let folder: TabFolder
    let depth: Int
    let style: TabListStyle
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var targeted = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    private var isRenaming: Bool { tabManager.renamingFolderID == folder.id }
    private var tabCount: Int { SidebarNode.folder(folder).tabIDs.count }
    private var container: SidebarContainer {
        SidebarContainer(zone: tabManager.tree.zone(of: folder.id) ?? .regular, folderID: folder.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8 * tabScale, weight: .bold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            if folder.kind == .group {
                Circle().fill(GroupPalette.color(folder.colorIndex)).frame(width: 9 * tabScale, height: 9 * tabScale)
            } else {
                Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                    .font(.system(size: 11 * tabScale))
                    .foregroundStyle(.secondary)
            }
            if isRenaming {
                TextField("Название", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: (style == .mobile ? 13 : 12) * tabScale, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { tabManager.renameFolder(folder.id, to: draftTitle) }
                    .onExitCommand { tabManager.renamingFolderID = nil }
                    .onAppear {
                        draftTitle = folder.title
                        DispatchQueue.main.async { titleFocused = true }
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, isRenaming { tabManager.renameFolder(folder.id, to: draftTitle) }
                    }
            } else {
                Text(folder.title)
                    .font(.system(size: (style == .mobile ? 13 : 12) * tabScale, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(folder.kind == .group ? GroupPalette.color(folder.colorIndex) : .primary)
            }
            Spacer(minLength: 4)
            if !folder.isExpanded {
                Text("\(tabCount)")
                    .font(.system(size: 9 * tabScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .padding(.trailing, 10)
        .frame(height: (style == .mobile ? 36 : 26) * tabScale)
        .background(targeted ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { tabManager.toggleFolderExpanded(folder.id) } }
        .draggable(TabDragPayload.encode(folder.id)) {
            Label(folder.title, systemImage: folder.kind == .group ? "circle.fill" : "folder.fill")
                .padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, onto: folder.id, intoFolder: true)
        } isTargeted: { targeted = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Переименовать") { tabManager.renamingFolderID = folder.id }
        if folder.kind == .folder {
            Button("Новая папка внутри") { tabManager.createFolder(in: folder.id) }
                .disabled(!tabManager.tree.canCreateFolder(in: container))
        } else {
            Menu("Цвет") {
                ForEach(GroupPalette.colors.indices, id: \.self) { index in
                    Button(GroupPalette.names[index]) { tabManager.setGroupColor(folder.id, colorIndex: index) }
                }
            }
            Button("Превратить в папку") { tabManager.convertGroupToFolder(folder.id) }
        }
        Button(folder.isExpanded ? "Свернуть" : "Развернуть") { tabManager.toggleFolderExpanded(folder.id) }
        Divider()
        Button(folder.kind == .group ? "Разгруппировать" : "Убрать папку, оставить вкладки") {
            tabManager.dissolveFolder(folder.id)
        }
        Button("Закрыть все вкладки") { tabManager.closeFolder(folder.id) }
    }
}

// MARK: - Строка вкладки

struct TabRow: View {
    let tab: TabModel
    let depth: Int
    let style: TabListStyle
    var groupColor: Color?
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var hovering = false
    @State private var targeted = false
    @State private var copied = false

    private var isActive: Bool { tab.id == tabManager.activeTabID }
    private var isSelected: Bool { tabManager.selectedTabIDs.contains(tab.id) }
    private var mobile: Bool { style == .mobile }

    var body: some View {
        HStack(spacing: mobile ? 12 : 8) {
            TabFavicon(tab: tab, copied: copied, size: (mobile ? 18 : 14) * tabScale)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Новая вкладка" : tab.title)
                    .font(.system(size: (mobile ? 14 : 12) * tabScale, weight: mobile ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundColor(isActive || mobile ? .primary : .secondary)
                if !mobile || tab.url != nil {
                    Text(subtitle)
                        .font(.system(size: (mobile ? 10 : 9) * tabScale))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            TabStatusIcons(tab: tab, fontSize: (mobile ? 10 : 9) * tabScale)
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8 * tabScale))
                    .foregroundColor(.secondary)
            }
            if mobile || hovering || isActive {
                Button { tabManager.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: (mobile ? 9 : 8) * tabScale, weight: .semibold))
                        .frame(width: (mobile ? 24 : 20) * tabScale, height: (mobile ? 24 : 20) * tabScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Закрыть вкладку")
            }
        }
        .padding(.vertical, (mobile ? 0 : 7) * tabScale)
        .padding(.leading, CGFloat(depth) * 12 + (mobile ? 12 : 10))
        .padding(.trailing, mobile ? 12 : 10)
        .frame(height: mobile ? 48 * tabScale : nil)
        .background(background, in: RoundedRectangle(cornerRadius: mobile ? 12 : 6))
        .overlay(alignment: .top) {
            if targeted {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6).offset(y: -1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { handleTap() }
        .draggable(TabDragPayload.encode(tab.id)) {
            HStack {
                TabFavicon(tab: tab, copied: false, size: 14)
                Text(tab.title).lineLimit(1)
            }
            .padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, onto: tab.id, intoFolder: false)
        } isTargeted: { targeted = $0 }
        .contextMenu { TabContextMenu(tab: tab) }
    }

    private var subtitle: String {
        let place: String
        if let host = tab.url?.host, !host.isEmpty { place = host }
        else if tab.url?.isFileURL == true { place = "Файл" }
        else { return "Новая вкладка" }
        return tab.isHibernated && !mobile ? place + " · выгружена" : place
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isActive { return Color.primary.opacity(mobile ? 0.08 : 0.12) }
        return Color.primary.opacity(hovering ? 0.04 : 0)
    }

    private func handleTap() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            tabManager.toggleSelection(tab.id)
            return
        }
        tabManager.selectedTabIDs = []
        if isActive { copyURL() } else { tabManager.selectTab(id: tab.id) }
    }

    private func copyURL() {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((AdBlocker.cleanedURL(url) ?? url).absoluteString, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct TabFavicon: View {
    let tab: TabModel
    let copied: Bool
    let size: CGFloat

    var body: some View {
        Group {
            if copied {
                Image(systemName: "checkmark").foregroundStyle(.green)
            } else if case .pdf = tab.content {
                Image(systemName: "doc.richtext.fill").resizable().scaledToFit().foregroundStyle(.red)
            } else if case .markdown = tab.content {
                Image(systemName: "doc.text.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.22))
            }
        }
        .frame(width: size, height: size)
        .opacity(tab.isHibernated ? 0.55 : 1)
    }
}

/// Значки состояния: звук (клик — выключить), запись камеры/микрофона, картинка в картинке.
struct TabStatusIcons: View {
    let tab: TabModel
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        HStack(spacing: 4) {
            if tab.isCapturingMedia {
                Button { tabManager.stopMediaCapture(id: tab.id) } label: {
                    Circle().fill(Color.red).frame(width: fontSize * 0.8, height: fontSize * 0.8)
                }
                .buttonStyle(.plain)
                .help("Сайт использует камеру или микрофон. Нажмите, чтобы остановить")
            }
            if tab.isInPictureInPicture {
                Image(systemName: "pip.fill")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
            if tab.isPlayingAudio || tab.isMuted {
                Button { tabManager.toggleMute(id: tab.id) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: fontSize))
                        .foregroundStyle(tab.isMuted ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(tab.isMuted ? "Включить звук (⌘⇧M)" : "Выключить звук (⌘⇧M)")
            }
        }
    }
}

/// Контекстное меню вкладки — одно для всех видов панели.
struct TabContextMenu: View {
    let tab: TabModel
    @Environment(TabManager.self) private var tabManager: TabManager

    private var selection: [UUID] {
        tabManager.selectedTabIDs.contains(tab.id) ? Array(tabManager.selectedTabIDs) : [tab.id]
    }

    var body: some View {
        if selection.count > 1 {
            Button("Убрать \(selection.count) вкладки в папку") { tabManager.moveToNewFolder(selection) }
            Button("Сгруппировать \(selection.count) вкладки") { tabManager.moveToNewFolder(selection, kind: .group) }
            Button("Архивировать \(selection.count) вкладки") {
                tabManager.archiveTabs(selection)
                tabManager.selectedTabIDs = []
            }
            .disabled(tabManager.isIncognito)
            Divider()
        }
        Button(tab.isPinned ? "Открепить" : "Закрепить") { tabManager.togglePinTab(id: tab.id) }
        Button("Убрать в новую папку") { tabManager.moveToNewFolder([tab.id]) }
        if let url = tab.url {
            Button(tabManager.bookmarks.contains(url) ? "Уже в закладках" : "Добавить в закладки") {
                tabManager.bookmarks.add(title: tab.title, url: url)
            }
            .disabled(tabManager.bookmarks.contains(url))
            Button("Скопировать ссылку") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((AdBlocker.cleanedURL(url) ?? url).absoluteString, forType: .string)
            }
        }
        if tab.isPlayingAudio || tab.isMuted {
            Button(tab.isMuted ? "Включить звук" : "Выключить звук") { tabManager.toggleMute(id: tab.id) }
        }
        Button("Выключить звук остальных вкладок") { tabManager.muteOtherTabs(except: tab.id) }
        if tab.webView != nil, tab.content == .web {
            Button("Картинка в картинке") { tabManager.togglePictureInPicture(id: tab.id) }
        }
        Divider()
        Button("Выгрузить из памяти") { tabManager.hibernateTab(id: tab.id) }
            .disabled(tab.isHibernated || tab.url == nil)
        if !tabManager.isIncognito {
            Button("Архивировать") { tabManager.archiveTabs([tab.id]) }
                .disabled(tab.url == nil)
        }
        if tabManager.modCapabilities.contains("splitView") {
            Button("Разделить экран") { tabManager.activateSplit(with: tab.id) }
        }
        Divider()
        Button("Закрыть") { tabManager.closeTab(id: tab.id) }
    }
}

// MARK: - Верхняя полоса вкладок

/// Группа или папка в верхней полосе: цветная «таблетка». Группа раскрывается на месте,
/// папка показывает свои вкладки меню.
struct TopBarFolderChip: View {
    let folder: TabFolder
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var targeted = false

    var body: some View {
        Group {
            if folder.kind == .group {
                Button { tabManager.toggleFolderExpanded(folder.id) } label: { chipLabel }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    folderMenu(folder.children)
                    Divider()
                    Button("Переименовать…") { renameWithAlert() }
                    Button("Убрать папку, оставить вкладки") { tabManager.dissolveFolder(folder.id) }
                } label: { chipLabel }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 7 * tabScale)
        .draggable(TabDragPayload.encode(folder.id))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, onto: folder.id, intoFolder: true)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if folder.kind == .group {
                Menu("Цвет") {
                    ForEach(GroupPalette.colors.indices, id: \.self) { index in
                        Button(GroupPalette.names[index]) { tabManager.setGroupColor(folder.id, colorIndex: index) }
                    }
                }
                Button("Переименовать…") { renameWithAlert() }
                Button("Разгруппировать") { tabManager.dissolveFolder(folder.id) }
            }
            Button("Закрыть все вкладки") { tabManager.closeFolder(folder.id) }
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: folder.kind == .group ? "circle.fill" : "folder.fill")
                .font(.system(size: (folder.kind == .group ? 7 : 10) * tabScale))
            Text(folder.title).lineLimit(1)
            if folder.kind == .folder || !folder.isExpanded {
                Text("\(SidebarNode.folder(folder).tabIDs.count)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11 * tabScale, weight: .semibold))
        .foregroundStyle(folder.kind == .group ? GroupPalette.color(folder.colorIndex) : .primary)
        .padding(.horizontal, 10 * tabScale)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((folder.kind == .group ? GroupPalette.color(folder.colorIndex) : Color.primary).opacity(targeted ? 0.3 : 0.12))
        )
    }

    @ViewBuilder
    private func folderMenu(_ nodes: [SidebarNode]) -> some View {
        ForEach(nodes) { node in
            switch node {
            case .tab(let id):
                if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                    Button(tab.title.isEmpty ? "Новая вкладка" : tab.title) { tabManager.selectTab(id: id) }
                }
            case .folder(let sub):
                Menu(sub.title) { AnyView(folderMenu(sub.children)) }
            }
        }
    }

    private func renameWithAlert() {
        let alert = NSAlert()
        alert.messageText = folder.kind == .group ? "Название группы" : "Название папки"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = folder.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Готово")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { tabManager.renameFolder(folder.id, to: field.stringValue) }
    }
}

/// Узлы верхнего уровня для горизонтальной полосы: вкладки, группы (с вкладками, если раскрыты) и папки.
enum TopBarItem: Identifiable {
    case tab(TabModel, groupColor: Color?)
    case folder(TabFolder)

    var id: UUID {
        switch self {
        case .tab(let tab, _): tab.id
        case .folder(let folder): folder.id
        }
    }

    @MainActor
    static func items(for manager: TabManager) -> [TopBarItem] {
        var result: [TopBarItem] = []
        let byID = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0) })
        for node in manager.tree.pinned + manager.tree.regular {
            switch node {
            case .tab(let id):
                if let tab = byID[id] { result.append(.tab(tab, groupColor: nil)) }
            case .folder(let folder):
                result.append(.folder(folder))
                if folder.kind == .group, folder.isExpanded {
                    for id in SidebarNode.folder(folder).tabIDs {
                        if let tab = byID[id] { result.append(.tab(tab, groupColor: GroupPalette.color(folder.colorIndex))) }
                    }
                }
            }
        }
        return result
    }
}
