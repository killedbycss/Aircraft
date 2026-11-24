import SwiftUI
import AppKit

/// Цвета групп вкладок.
enum GroupPalette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal]
    static let names = ["Синий", "Фиолетовый", "Розовый", "Красный", "Оранжевый", "Жёлтый", "Зелёный", "Бирюзовый"]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }

    /// Цвет для текста и значков: в тёмной теме чуть светлее, в светлой — темнее (жёлтый
    /// и бирюзовый на светлой панели почти не видны).
    static func readable(_ index: Int, scheme: ColorScheme) -> Color {
        let base = NSColor(color(index)).usingColorSpace(.sRGB) ?? .gray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if scheme == .dark {
            return Color(hue: hue, saturation: saturation * 0.8, brightness: min(1, max(brightness, 0.85)))
        }
        return Color(hue: hue, saturation: min(1, saturation * 1.1), brightness: min(brightness, 0.72))
    }
}

/// Пункт меню с цветным кружком (в меню macOS SF-символы одноцветные, поэтому — картинка).
struct ColorMenuLabel: View {
    let index: Int
    var checked = false

    var body: some View {
        Label {
            Text(checked ? GroupPalette.names[index] + "  ✓" : GroupPalette.names[index])
        } icon: {
            Image(nsImage: MenuIcons.swatch(GroupPalette.color(index)))
        }
    }
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
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: style == .mobile ? 6 : 2) {
            if !tabManager.tree.pinned.isEmpty {
                // Без заголовка «Закреплённые»: зону отделяет только линия, как в Arc.
                // Тонкая полоска сверху принимает вкладку, которую хотят закрепить.
                ZoneDropArea(zone: .pinned, height: 4)
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

/// Пустое место под списком: бросить сюда — в конец обычных вкладок.
private struct ZoneDropArea: View {
    let zone: SidebarZone
    var height: CGFloat = 10
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(targeted ? Color.accentColor.opacity(0.5) : Color.clear)
            .frame(height: targeted ? max(3, height) : height)
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
                        .padding(.leading, CGFloat(depth) * BrowserDesign.Space.treeIndent + 3)
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
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @State private var targeted = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
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
                Image(systemName: folder.folderColor == nil && folder.isExpanded ? "folder" : "folder.fill")
                    .font(.system(size: 11 * tabScale))
                    .foregroundStyle(folder.folderColor.map { AnyShapeStyle(GroupPalette.readable($0, scheme: colorScheme)) } ?? AnyShapeStyle(.secondary))
            }
            if isRenaming {
                TextField("Название", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(BrowserDesign.TypeRole.title(scale: tabScale, large: style == .mobile, emphasized: true))
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
                    .font(BrowserDesign.TypeRole.title(scale: tabScale, large: style == .mobile, emphasized: true))
                    .lineLimit(1)
                    .foregroundStyle(titleColor)
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
        .padding(.leading, CGFloat(depth) * BrowserDesign.Space.treeIndent + 8)
        .padding(.trailing, 10)
        .frame(height: (style == .mobile ? 36 : 26) * tabScale)
        .background(headerFill, in: BrowserDesign.Shape.row)
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

    /// Название — обычным цветом текста: цветной текст на тонированной панели (и в тёмной
    /// теме) плохо читался. Цвет папки — у значка и у подложки.
    private var titleColor: Color {
        if folder.kind == .group { return GroupPalette.readable(folder.colorIndex, scheme: colorScheme) }
        return .primary
    }

    private var headerFill: Color {
        if targeted { return BrowserDesign.Surface.selection }
        if folder.kind == .folder, let color = folder.folderColor {
            return GroupPalette.color(color).opacity(colorScheme == .dark ? 0.22 : 0.14)
        }
        return .clear
    }

    @ViewBuilder
    private var menu: some View {
        Button("Переименовать") { tabManager.renamingFolderID = folder.id }
        if folder.kind == .folder {
            Button("Новая папка внутри") { tabManager.createFolder(in: folder.id) }
                .disabled(!tabManager.tree.canCreateFolder(in: container))
            Menu("Цвет папки") {
                Button("Без цвета") { tabManager.setFolderColor(folder.id, colorIndex: nil) }
                Divider()
                ForEach(GroupPalette.colors.indices, id: \.self) { index in
                    Button {
                        tabManager.setFolderColor(folder.id, colorIndex: index)
                    } label: {
                        ColorMenuLabel(index: index, checked: folder.folderColor == index)
                    }
                }
            }
        } else {
            Menu("Цвет") {
                ForEach(GroupPalette.colors.indices, id: \.self) { index in
                    Button { tabManager.setGroupColor(folder.id, colorIndex: index) } label: {
                        ColorMenuLabel(index: index, checked: folder.colorIndex == index)
                    }
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
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @State private var hovering = false
    @State private var targeted = false
    @State private var copied = false

    private var isActive: Bool { tab.id == tabManager.activeTabID }
    private var isSelected: Bool { tabManager.selectedTabIDs.contains(tab.id) }
    private var mobile: Bool { style == .mobile }

    var body: some View {
        HStack(spacing: mobile ? 12 : BrowserDesign.Space.iconGap) {
            TabFavicon(tab: tab, copied: copied, size: (mobile ? 18 : 14) * tabScale)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Новая вкладка" : tab.title)
                    .font(BrowserDesign.TypeRole.title(scale: tabScale, large: mobile, emphasized: isActive))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if tab.url != nil {
                    Text(subtitle)
                        .font(BrowserDesign.TypeRole.detail(scale: tabScale))
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
        .padding(.leading, CGFloat(depth) * BrowserDesign.Space.treeIndent + (mobile ? 12 : BrowserDesign.Space.rowInset))
        .padding(.trailing, mobile ? 12 : BrowserDesign.Space.rowInset)
        .frame(height: mobile ? 48 * tabScale : nil)
        .background(background, in: BrowserDesign.Shape.row)
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
        BrowserDesign.Surface.tab(active: isActive, hovered: hovering, selected: isSelected)
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
            } else if tab.url != nil {
                FaviconImage(url: tab.url, image: tab.favicon, size: size)
            } else {
                Image(systemName: "plus.magnifyingglass").resizable().scaledToFit().foregroundStyle(.secondary)
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
            if tabManager.splitTabID != nil, tab.id == tabManager.splitPrimaryTabID || tab.id == tabManager.splitTabID {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .help("Открыта в Split View")
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
        if tabManager.tree.zone(of: tab.id) != .favorites {
            Button("Добавить в плитки") { tabManager.addToFavorites(tab.id) }
                .disabled(tab.url == nil)
        } else {
            Button("Убрать из плиток") { tabManager.dropNode(tab.id, toEndOf: .pinned) }
        }
        Button("Убрать в новую папку") { tabManager.moveToNewFolder([tab.id]) }
        if let url = tab.url {
            Button(tabManager.bookmarks.contains(url) ? "Уже в закладках" : "Добавить в закладки") {
                tabManager.bookmarks.add(title: tab.title, url: url)
            }
            .disabled(tabManager.bookmarks.contains(url))
            if tabManager.modCapabilities.contains("sources") {
                Button("Сохранить в источники") {
                    tabManager.selectTab(id: tab.id)
                    SourceCapture.save(from: tabManager)
                }
            }
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("tabScale") private var tabScale: Double = 1.0
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
                        Button { tabManager.setGroupColor(folder.id, colorIndex: index) } label: {
                            ColorMenuLabel(index: index, checked: folder.colorIndex == index)
                        }
                    }
                }
                Button("Переименовать…") { renameWithAlert() }
                Button("Разгруппировать") { tabManager.dissolveFolder(folder.id) }
            } else {
                Menu("Цвет папки") {
                    Button("Без цвета") { tabManager.setFolderColor(folder.id, colorIndex: nil) }
                    Divider()
                    ForEach(GroupPalette.colors.indices, id: \.self) { index in
                        Button { tabManager.setFolderColor(folder.id, colorIndex: index) } label: {
                            ColorMenuLabel(index: index, checked: folder.folderColor == index)
                        }
                    }
                }
            }
            Button("Закрыть все вкладки") { tabManager.closeFolder(folder.id) }
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: folder.kind == .group ? "circle.fill" : "folder.fill")
                .font(.system(size: (folder.kind == .group ? 7 : 10) * tabScale))
                .foregroundStyle(folder.kind == .folder ? AnyShapeStyle(folder.folderColor.map { GroupPalette.readable($0, scheme: colorScheme) } ?? Color.secondary) : AnyShapeStyle(chipForeground))
            Text(folder.title).lineLimit(1)
            if folder.kind == .folder || !folder.isExpanded {
                Text("\(SidebarNode.folder(folder).tabIDs.count)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11 * tabScale, weight: .semibold))
        .foregroundStyle(chipForeground)
        .padding(.horizontal, 10 * tabScale)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(chipTint.opacity(targeted ? 0.3 : (colorScheme == .dark ? 0.2 : 0.12)))
        )
    }

    private var chipTint: Color {
        if folder.kind == .group { return GroupPalette.color(folder.colorIndex) }
        return folder.folderColor.map(GroupPalette.color) ?? .primary
    }

    private var chipForeground: Color {
        if folder.kind == .group { return GroupPalette.readable(folder.colorIndex, scheme: colorScheme) }
        return .primary
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

/// Узлы верхнего уровня для горизонтальной полосы: плитки (одной папкой), вкладки,
/// группы (с вкладками, если раскрыты) и папки.
enum TopBarItem: Identifiable {
    case tab(TabModel, groupColor: Color?)
    case folder(TabFolder)
    /// Все плитки одной «папкой» в начале полосы.
    case tiles([TabModel])

    static let tilesID = UUID(uuidString: "7E1E5000-0000-4000-8000-000000000001")!
    static let tilesAsFolderKey = "topBarTilesAsFolder"

    var id: UUID {
        switch self {
        case .tab(let tab, _): tab.id
        case .folder(let folder): folder.id
        case .tiles: Self.tilesID
        }
    }

    @MainActor
    static func items(for manager: TabManager) -> [TopBarItem] {
        var result: [TopBarItem] = []
        let byID = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0) })
        let tilesAsFolder = UserDefaults.standard.object(forKey: tilesAsFolderKey) as? Bool ?? true
        var nodes = manager.tree.pinned + manager.tree.regular
        if tilesAsFolder {
            let tiles = manager.tree.favorites.flatMap(\.tabIDs).compactMap { byID[$0] }
            if !tiles.isEmpty { result.append(.tiles(tiles)) }
        } else {
            nodes = manager.tree.favorites + nodes
        }
        for node in nodes {
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

/// Плитки в верхней полосе — одной кнопкой: значки первых плиток, по клику — меню всех плиток.
/// Если сейчас открыта плитка, кнопка подсвечена и показывает её значок первым.
struct TopBarTilesChip: View {
    let tiles: [TabModel]
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @State private var targeted = false

    private var activeTile: TabModel? { tiles.first { $0.id == tabManager.activeTabID } }

    var body: some View {
        Menu {
            ForEach(tiles) { tile in
                Button {
                    tabManager.selectTab(id: tile.id)
                } label: {
                    if let image = MenuIcons.favicon(for: tile) {
                        Label { Text(menuTitle(tile)) } icon: { Image(nsImage: image) }
                    } else {
                        Text(menuTitle(tile))
                    }
                }
            }
            Divider()
            Button("Показывать плитки по одной") {
                UserDefaults.standard.set(false, forKey: TopBarItem.tilesAsFolderKey)
            }
        } label: {
            HStack(spacing: -3 * tabScale) {
                ForEach(previewTiles) { tile in
                    FaviconImage(url: tile.url ?? tile.pinnedURL, image: tile.favicon, size: 14 * tabScale)
                        .padding(1.5)
                }
                if tiles.count > previewTiles.count {
                    Text("+\(tiles.count - previewTiles.count)")
                        .font(.system(size: 9 * tabScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6 * tabScale)
                }
            }
            .padding(.horizontal, 8 * tabScale)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(activeTile != nil ? 0.12 : (targeted ? 0.18 : 0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(activeTile != nil ? 0.6 : 0), lineWidth: 1.2)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 7 * tabScale)
        .help(activeTile.map { "Плитки · сейчас: \(menuTitle($0))" } ?? "Плитки (\(tiles.count))")
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, toEndOf: .favorites)
        } isTargeted: { targeted = $0 }
    }

    /// Открытая плитка — первой, дальше по порядку; всего не больше трёх значков.
    private var previewTiles: [TabModel] {
        var ordered = tiles
        if let activeTile, let index = ordered.firstIndex(where: { $0.id == activeTile.id }) {
            ordered.remove(at: index)
            ordered.insert(activeTile, at: 0)
        }
        return Array(ordered.prefix(3))
    }

    private func menuTitle(_ tile: TabModel) -> String {
        if !tile.title.isEmpty { return tile.title }
        return (tile.pinnedURL ?? tile.url)?.host ?? "Плитка"
    }
}

/// Цветные картинки для пунктов меню: в NSMenu символы SF рисуются шаблоном (одним цветом),
/// поэтому кружки цветов и значки сайтов готовим как обычные NSImage.
@MainActor
enum MenuIcons {
    static func swatch(_ color: Color, diameter: CGFloat = 12) -> NSImage {
        let nsColor = NSColor(color)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 0.5
            ring.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func favicon(for tab: TabModel, side: CGFloat = 16) -> NSImage? {
        guard let source = tab.favicon ?? FaviconCache.shared.image(for: tab.url ?? tab.pinnedURL) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * FaviconImage.cornerRatio, yRadius: side * FaviconImage.cornerRatio).addClip()
            source.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}
