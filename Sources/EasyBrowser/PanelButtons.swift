import SwiftUI
import AppKit

// MARK: - Кнопки панели вкладок

/// Кнопки, которые пользователь сам выбирает и расставляет в панели вкладок.
/// Порядок панели одинаков слева, справа и сверху: вкладки → «Новая вкладка» →
/// эти кнопки → профиль.
enum PanelButton: String, CaseIterable, Identifiable, Sendable {
    case togglePanel
    case navigation
    case reload
    case history
    case downloads
    case createMenu
    case splitView
    case sources
    case bookmark
    case readerMode
    case copyURL
    case newWindow
    case incognitoWindow
    case settings
    case devtools
    case historyPanel

    static let storageKey = "panelButtons"
    /// Раньше в панели всегда были «закрепить/скрыть», разделение экрана, источники, история,
    /// загрузки и «+», а в верхней полосе — настройки. По умолчанию оставляем тот же набор.
    static let defaults: [PanelButton] = [.togglePanel, .splitView, .sources, .history, .downloads, .createMenu, .settings]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "Закрепить / скрыть панель"
        case .navigation: "Назад и вперёд"
        case .reload: "Обновить страницу"
        case .history: "История и аккаунты"
        case .downloads: "Загрузки"
        case .createMenu: "Создать: папку, окно…"
        case .splitView: "Разделить экран"
        case .sources: "Источники"
        case .bookmark: "Закладка на страницу"
        case .readerMode: "Режим чтения"
        case .copyURL: "Скопировать адрес"
        case .newWindow: "Новое окно"
        case .incognitoWindow: "Окно инкогнито"
        case .settings: "Настройки"
        case .devtools: "Web Inspector"
        case .historyPanel: "Панель истории (мод)"
        }
    }

    var symbol: String {
        switch self {
        case .togglePanel: "sidebar.left"
        case .navigation: "arrow.left.arrow.right"
        case .reload: "arrow.clockwise"
        case .history: "clock.arrow.circlepath"
        case .downloads: "arrow.down.circle"
        case .createMenu: "plus"
        case .splitView: "rectangle.split.2x1"
        case .sources: "books.vertical"
        case .bookmark: "bookmark"
        case .readerMode: "doc.plaintext"
        case .copyURL: "doc.on.doc"
        case .newWindow: "macwindow.badge.plus"
        case .incognitoWindow: "eyeglasses"
        case .settings: "gearshape"
        case .devtools: "ladybug"
        case .historyPanel: "sidebar.squares.left"
        }
    }

    /// Возможность мода, без которой кнопка не показывается.
    var requiredCapability: String? {
        switch self {
        case .splitView: "splitView"
        case .sources: "sources"
        case .devtools: "devtools"
        case .historyPanel: "historyAccounts"
        default: nil
        }
    }

    /// Строка из настроек → список кнопок: неизвестные и повторы отбрасываем.
    static func decode(_ value: String?) -> [PanelButton] {
        guard let value else { return defaults }
        var seen = Set<PanelButton>()
        return value.split(separator: ",").compactMap { PanelButton(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ buttons: [PanelButton]) -> String {
        buttons.map(\.rawValue).joined(separator: ",")
    }
}

/// Видна ли панель вкладок. Источник один — настройка «Скрывать панель»: «Никогда» — панель
/// закреплена, «Всегда» — скрыта, «Только в оконном режиме» — видна в полноэкранном режиме.
/// Кнопка «Закрепить / скрыть» (⌃⌥S) меняет эту же настройку.
enum PanelVisibility {
    static let modeKey = "topBarHideMode"

    static func isShown(mode: String, fullScreen: Bool) -> Bool {
        mode == "never" || (mode == "windowed" && fullScreen)
    }

    /// Открепить → «Скрывать всегда», закрепить → «Скрывать никогда».
    static func toggled(mode: String, fullScreen: Bool) -> String {
        isShown(mode: mode, fullScreen: fullScreen) ? "always" : "never"
    }
}

/// Ряд выбранных кнопок, затем — профиль. `compactProfile` — только аватар (для полосы сверху).
struct PanelButtonsRow: View {
    var compactProfile = false
    @AppStorage(PanelButton.storageKey) private var stored = PanelButton.encode(PanelButton.defaults)
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleButtons) { button in
                PanelButtonView(button: button, fontSize: 11 * tabScale)
            }
            if !compactProfile { Spacer(minLength: 4) }
            ProfileSwitcher(compact: compactProfile)
                .padding(.leading, compactProfile ? 4 : 0)
        }
        .foregroundStyle(.secondary)
    }

    private var visibleButtons: [PanelButton] {
        PanelButton.decode(stored).filter { button in
            button.requiredCapability.map { tabManager.modCapabilities.contains($0) } ?? true
        }
    }
}

/// Одна кнопка панели.
struct PanelButtonView: View {
    let button: PanelButton
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage(PanelVisibility.modeKey) private var panelHideMode = "always"
    @AppStorage("tabPosition") private var tabPosition = "left"
    @State private var copied = false
    private var downloads: DownloadStore { .shared }

    var body: some View {
        switch button {
        case .togglePanel:
            ChromeIconButton(symbol: togglePanelSymbol,
                             help: (panelShown ? "Открепить и скрыть панель вкладок" : "Закрепить панель вкладок") + " (⌃⌥S)",
                             fontSize: fontSize) {
                NotificationCenter.default.post(name: .toggleSidebar, object: tabManager.hostWindow ?? NSApp.keyWindow)
            }
        case .navigation:
            NavigationArrows(fontSize: fontSize)
        case .reload:
            let loading = tabManager.activeTab?.isLoading == true
            icon(loading ? "xmark" : "arrow.clockwise", loading ? "Остановить (⌘.)" : "Обновить страницу (⌘R)",
                 enabled: tabManager.activeTab?.url != nil) { tabManager.reloadActiveTab() }
        case .history:
            icon(button.symbol, "История и аккаунты (⌘Y)") { LibraryWindow.show(.history, for: tabManager) }
        case .downloads:
            ChromeIconButton(symbol: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                             help: "Загрузки (⌥⌘L)", fontSize: fontSize, active: downloads.activeCount > 0) {
                LibraryWindow.show(.downloads, for: tabManager)
            }
        case .createMenu:
            NewItemMenu(fontSize: fontSize)
        case .splitView:
            icon(button.symbol, "Разделить экран", enabled: tabManager.activeTab?.url != nil) { tabManager.startSplitView() }
        case .sources:
            icon(button.symbol, "Источники · ⌘⇧S — сохранить страницу") { SourcesWindow.show(for: tabManager) }
        case .bookmark:
            let saved = tabManager.activeTab?.url.map { tabManager.bookmarks.contains($0) } ?? false
            icon(saved ? "bookmark.fill" : "bookmark", "Закладка (⌘D)", enabled: tabManager.activeTab?.url != nil) {
                tabManager.bookmarkEditorVisible.toggle()
            }
        case .readerMode:
            let tab = tabManager.activeTab
            icon(tab?.isReaderActive == true ? "doc.plaintext.fill" : "doc.plaintext", "Режим чтения (⌘⇧R)",
                 enabled: tab?.isReaderable == true || tab?.isReaderActive == true) { tabManager.toggleReaderMode() }
        case .copyURL:
            icon(copied ? "checkmark" : "doc.on.doc", "Скопировать адрес (⌘⇧C)", enabled: tabManager.activeTab?.url != nil) {
                guard let value = tabManager.activeTab?.url?.absoluteString else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
        case .newWindow:
            icon(button.symbol, "Новое окно (⇧⌘N)") { (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow() }
        case .incognitoWindow:
            icon(button.symbol, "Окно инкогнито (⇧⌘P)") {
                (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow(incognito: true)
            }
        case .settings:
            icon(button.symbol, "Настройки (⌘,)") {
                NotificationCenter.default.post(name: .openSettings, object: tabManager.hostWindow ?? NSApp.keyWindow)
            }
        case .devtools:
            icon(button.symbol, "Web Inspector") { tabManager.toggleModPanel("devtools") }
        case .historyPanel:
            icon(button.symbol, "Панель «История и аккаунты»") { tabManager.toggleModPanel("historyAccounts") }
        }
    }

    private var panelShown: Bool {
        PanelVisibility.isShown(mode: panelHideMode, fullScreen: tabManager.hostWindow?.styleMask.contains(.fullScreen) ?? false)
    }

    private var togglePanelSymbol: String {
        guard panelShown else { return "pin" }
        switch tabPosition {
        case "right": return "sidebar.right"
        case "top": return "rectangle.topthird.inset.filled"
        default: return "sidebar.left"
        }
    }

    private func icon(_ symbol: String, _ help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        ChromeIconButton(symbol: symbol, help: help, fontSize: fontSize, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Настройка в «Вкладках»

/// Список кнопок панели: добавить, убрать, переставить (перетаскиванием или стрелками).
struct PanelButtonsEditor: View {
    @AppStorage(PanelButton.storageKey) private var stored = PanelButton.encode(PanelButton.defaults)

    private var buttons: [PanelButton] { PanelButton.decode(stored) }
    private var available: [PanelButton] { PanelButton.allCases.filter { !buttons.contains($0) } }

    var body: some View {
        if buttons.isEmpty {
            Text("Кнопок нет — в панели останутся вкладки, «Новая вкладка» и профиль.")
                .foregroundStyle(.secondary)
        }
        ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                Image(systemName: button.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(button.title)
                    if let capability = button.requiredCapability {
                        Text("Видна, когда включён мод «\(capability)»")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { move(from: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Выше")
                Button { move(from: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == buttons.count - 1)
                    .help("Ниже")
                Button { remove(button) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .help("Убрать")
            }
            .buttonStyle(.borderless)
        }
        .onMove { source, destination in
            var list = buttons
            list.move(fromOffsets: source, toOffset: destination)
            stored = PanelButton.encode(list)
        }
        HStack {
            Menu {
                ForEach(available) { button in
                    Button { stored = PanelButton.encode(buttons + [button]) } label: {
                        Label(button.title, systemImage: button.symbol)
                    }
                }
            } label: {
                Label("Добавить кнопку", systemImage: "plus")
            }
            .fixedSize()
            .disabled(available.isEmpty)
            Spacer()
            Button("Как было по умолчанию") { stored = PanelButton.encode(PanelButton.defaults) }
                .disabled(buttons == PanelButton.defaults)
        }
    }

    private func move(from index: Int, by offset: Int) {
        var list = buttons
        let target = index + offset
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        stored = PanelButton.encode(list)
    }

    private func remove(_ button: PanelButton) {
        stored = PanelButton.encode(buttons.filter { $0 != button })
    }
}
