import SwiftUI
import AppKit
import WebKit

// MARK: - Назад / вперёд

/// Стрелки «назад» и «вперёд». Клик — переход, долгое нажатие или правый клик —
/// список страниц, как в Safari и Dia. Подсказка показывает сочетание клавиш.
struct NavigationArrows: View {
    var fontSize: CGFloat = 12
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        HStack(spacing: 2) {
            arrow(back: true)
            arrow(back: false)
        }
    }

    private func arrow(back: Bool) -> some View {
        let enabled = back ? tabManager.canGoBack : tabManager.canGoForward
        let items = historyItems(back: back)
        return Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    tabManager.activeTab?.webView?.go(to: item)
                } label: {
                    Text(item.title?.isEmpty == false ? item.title! : item.url.absoluteString)
                }
            }
            if items.isEmpty { Text("История пуста") }
        } label: {
            Image(systemName: back ? "arrow.left" : "arrow.right")
                .font(.system(size: fontSize, weight: .semibold))
        } primaryAction: {
            if back { tabManager.goBackActiveTab() } else { tabManager.goForwardActiveTab() }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: fontSize * 2.2, height: fontSize * 2.2)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(back ? "Назад (⌘[) · удерживайте — список страниц" : "Вперёд (⌘]) · удерживайте — список страниц")
    }

    private func historyItems(back: Bool) -> [WKBackForwardListItem] {
        guard let list = tabManager.activeTab?.webView?.backForwardList else { return [] }
        return Array((back ? list.backList.reversed() : list.forwardList).prefix(15))
    }
}

/// Кнопка-значок с подсказкой и сочетанием клавиш.
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    var fontSize: CGFloat = 12
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: fontSize * 2.2, height: fontSize * 2.2)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Карточка адреса

/// Карточка адреса в боковой панели: значок, заголовок страницы и адрес.
/// Клик открывает Spotlight с адресом, как в Arc.
struct AddressCard: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        let tab = tabManager.activeTab
        HStack(spacing: 8 * tabScale) {
            if tab?.url != nil {
                FaviconImage(url: tab?.url, image: tab?.favicon, size: 16 * tabScale)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12 * tabScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16 * tabScale)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title(tab))
                    .font(.system(size: 12 * tabScale, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let address = address(tab) {
                    HStack(spacing: 3) {
                        if tab?.url?.scheme == "https" {
                            Image(systemName: "lock.fill").font(.system(size: 7 * tabScale))
                        }
                        Text(address).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 10 * tabScale))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            if hovering, tab?.url != nil {
                Button { copyURL() } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 10 * tabScale, weight: .semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Скопировать ссылку (⌘⇧C)")
            }
            AppLinkAddressButton(fontSize: 11 * tabScale)
            PageActionButtons(fontSize: 11 * tabScale)
        }
        .padding(.horizontal, 10 * tabScale)
        .padding(.vertical, 7 * tabScale)
        .background(Color.primary.opacity(hovering ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture {
            NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: tabManager.hostWindow ?? NSApp.keyWindow)
        }
        .help("Адрес или поиск (⌘L)")
        .contextMenu {
            Button("Скопировать ссылку") { copyURL() }.disabled(tab?.url == nil)
            Button("Обновить (⌘R)") { tabManager.reloadActiveTab() }.disabled(tab?.url == nil)
        }
    }

    private func title(_ tab: TabModel?) -> String {
        guard let tab, tab.url != nil else { return "Поиск или адрес" }
        return tab.title.isEmpty ? (tab.url?.host ?? "Страница") : tab.title
    }

    private func address(_ tab: TabModel?) -> String? {
        guard let url = tab?.url else { return nil }
        if url.isFileURL { return url.path }
        var value = url.absoluteString
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func copyURL() {
        tabManager.copyActiveURL()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// Режим чтения и закладка текущей страницы.
struct PageActionButtons: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        if let tab = tabManager.activeTab, tab.url != nil {
            HStack(spacing: 8) {
                if tab.isReaderable || tab.isReaderActive {
                    Button { tabManager.toggleReaderMode() } label: {
                        Image(systemName: tab.isReaderActive ? "doc.plaintext.fill" : "doc.plaintext")
                            .font(.system(size: fontSize, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Режим чтения (⌘⇧R)")
                }
                Button { tabManager.bookmarkEditorVisible.toggle() } label: {
                    Image(systemName: tabManager.bookmarks.contains(tab.url) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: fontSize, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Закладка (⌘D)")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Плитки избранных

/// Плитки закреплённых приложений над списком вкладок, как в Arc:
/// значок сайта в рамке цвета значка. Клик — открыть, правый клик — меню.
struct FavoritesGrid: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var targeted = false

    var body: some View {
        let ids = tabManager.tree.favorites.compactMap { node -> TabModel? in
            guard case .tab(let id) = node else { return nil }
            return tabManager.tabs.first { $0.id == id }
        }
        if !ids.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44 * tabScale, maximum: 80 * tabScale), spacing: 6 * tabScale)],
                      spacing: 6 * tabScale) {
                ForEach(ids) { tab in
                    FavoriteTile(tab: tab)
                }
            }
            .padding(4)
            .background(targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
                return tabManager.dropNode(id, toEndOf: .favorites)
            } isTargeted: { targeted = $0 }
        }
    }
}

private struct FavoriteTile: View {
    let tab: TabModel
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var hovering = false
    private var cache: FaviconCache { .shared }

    private var isActive: Bool { tab.id == tabManager.activeTabID }

    var body: some View {
        let _ = cache.revision
        let tint = cache.dominantColor(for: tab.url ?? tab.pinnedURL, image: tab.favicon) ?? .secondary
        FaviconImage(url: tab.url ?? tab.pinnedURL, image: tab.favicon, size: 18 * tabScale)
            .opacity(tab.isHibernated && !isActive ? 0.75 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 40 * tabScale)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? tint.opacity(0.22) : Color.primary.opacity(hovering ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(isActive ? 0.9 : 0.45), lineWidth: isActive ? 2 : 1.2)
            )
            .overlay(alignment: .topTrailing) {
                TabStatusIcons(tab: tab, fontSize: 7 * tabScale).padding(3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
            .onTapGesture { tabManager.selectTab(id: tab.id) }
            .help(tab.title.isEmpty ? (tab.url?.host ?? "") : tab.title)
            .draggable(TabDragPayload.encode(tab.id))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
                return tabManager.dropNode(id, onto: tab.id, intoFolder: false)
            }
            .contextMenu {
                Button("Вернуть к закреплённому адресу") {
                    tabManager.selectTab(id: tab.id)
                    tabManager.closeActiveTabFromShortcut()
                }
                Button("Убрать из плиток") { tabManager.dropNode(tab.id, toEndOf: .pinned) }
                Button("Открепить") { tabManager.togglePinTab(id: tab.id) }
                Divider()
                Button("Закрыть") { tabManager.closeTab(id: tab.id) }
            }
    }
}

// MARK: - Низ боковой панели

/// История и аккаунты, загрузки и профили — в конце боковой панели.
struct SidebarFooter: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    private var downloads: DownloadStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ProfileSwitcher()
                Spacer(minLength: 4)
                if tabManager.modCapabilities.contains("splitView") {
                    ChromeIconButton(symbol: "rectangle.split.2x1", help: "Разделить экран", fontSize: 11 * tabScale) {
                        tabManager.startSplitView()
                    }
                }
                ChromeIconButton(symbol: "clock.arrow.circlepath", help: "История и аккаунты (⌘Y)", fontSize: 11 * tabScale) {
                    LibraryWindow.show(.history, for: tabManager)
                }
                ChromeIconButton(symbol: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                                 help: "Загрузки (⌥⌘L)", fontSize: 11 * tabScale, active: downloads.activeCount > 0) {
                    LibraryWindow.show(.downloads, for: tabManager)
                }
                ChromeIconButton(symbol: "plus", help: "Новая вкладка (⌘T)", fontSize: 11 * tabScale) {
                    NotificationCenter.default.post(name: .createHomeTab, object: tabManager.hostWindow ?? NSApp.keyWindow)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38 * tabScale)
        }
    }
}

/// Значок профиля внизу панели: аватар текущего профиля, меню со всеми профилями;
/// остальные профили — маленькими точками рядом, для быстрого переключения.
struct ProfileSwitcher: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    private var store: ProfileStore { .shared }

    var body: some View {
        if tabManager.isIncognito {
            Label("Инкогнито", systemImage: "eyeglasses")
                .font(.system(size: 11 * tabScale, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
        } else {
            HStack(spacing: 6) {
                Menu {
                    ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                        Button {
                            tabManager.switchProfile(to: profile.id)
                        } label: {
                            if profile.id == tabManager.profileID {
                                Label(profile.name + (index < 9 ? "  ⌃\(index + 1)" : ""), systemImage: "checkmark")
                            } else {
                                Text(profile.name + (index < 9 ? "  ⌃\(index + 1)" : ""))
                            }
                        }
                    }
                    Divider()
                    Button("Новый профиль…") { ProfileBar.createProfile(in: tabManager) }
                    Button("Окно инкогнито (⌘⇧P)") {
                        (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow(incognito: true)
                    }
                    Divider()
                    Button("Настроить профили…") { SettingsWindowController.shared.show(pane: .profiles) }
                } label: {
                    HStack(spacing: 6) {
                        avatar(tabManager.profile, size: 22 * tabScale, current: true)
                        Text(tabManager.profile.name)
                            .font(.system(size: 11 * tabScale, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Профиль: \(tabManager.profile.name)")
                ForEach(Array(store.profiles.enumerated()).filter { $0.element.id != tabManager.profileID }, id: \.element.id) { index, profile in
                    Button { tabManager.switchProfile(to: profile.id) } label: {
                        avatar(profile, size: 16 * tabScale, current: false)
                    }
                    .buttonStyle(.plain)
                    .help(index < 9 ? "\(profile.name) (⌃\(index + 1))" : profile.name)
                }
            }
        }
    }

    private func avatar(_ profile: Profile, size: CGFloat, current: Bool) -> some View {
        Image(systemName: profile.symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(current ? Color.white : profile.color)
            .frame(width: size, height: size)
            .background(Circle().fill(current ? AnyShapeStyle(profile.color.gradient) : AnyShapeStyle(profile.color.opacity(0.18))))
            .overlay(Circle().strokeBorder(Color.white.opacity(current ? 0.35 : 0), lineWidth: 1))
    }
}

/// Размеры боковой панели: уже 190 pt не помещаются кнопки окна, стрелки и адрес.
enum SidebarMetrics {
    static let minWidth: Double = 190
    static let maxWidth: Double = 420
    static let defaultWidth: Double = 240
    static func clamp(_ width: Double) -> Double { min(max(width, minWidth), maxWidth) }
}
