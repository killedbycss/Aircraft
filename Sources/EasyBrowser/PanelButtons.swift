import AircraftLanguage
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
        case .togglePanel: L10n("Pin / hide panel")
        case .navigation: L10n("Back and forward")
        case .reload: L10n("Reload page")
        case .history: L10n("History and accounts")
        case .downloads: L10n("Downloads")
        case .createMenu: L10n("New folder or window…")
        case .splitView: L10n("Split screen")
        case .sources: L10n("Sources")
        case .bookmark: L10n("Bookmark page")
        case .readerMode: L10n("Reader Mode")
        case .copyURL: L10n("Copy address")
        case .newWindow: L10n("New Window")
        case .incognitoWindow: L10n("Incognito window")
        case .settings: L10n("Settings")
        case .devtools: "Web Inspector"
        case .historyPanel: L10n("History panel (mod)")
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
                             help: (panelShown ? L10n("Unpin and hide tab bar") : L10n("Pin tab bar")) + " (⌃⌥S)",
                             fontSize: fontSize) {
                NotificationCenter.default.post(name: .toggleSidebar, object: tabManager.hostWindow ?? NSApp.keyWindow)
            }
        case .navigation:
            NavigationArrows(fontSize: fontSize)
        case .reload:
            let loading = tabManager.activeTab?.isLoading == true
            icon(loading ? "xmark" : "arrow.clockwise", loading ? L10n("Stop (⌘.)") : L10n("Reload page (⌘R)"),
                 enabled: tabManager.activeTab?.url != nil) { tabManager.reloadActiveTab() }
        case .history:
            icon(button.symbol, L10n("History and accounts (⌘Y)")) { LibraryWindow.show(.history, for: tabManager) }
        case .downloads:
            ChromeIconButton(symbol: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                             help: L10n("Downloads (⌥⌘L)"), fontSize: fontSize, active: downloads.activeCount > 0) {
                LibraryWindow.show(.downloads, for: tabManager)
            }
        case .createMenu:
            NewItemMenu(fontSize: fontSize)
        case .splitView:
            icon(button.symbol, L10n("Split screen"), enabled: tabManager.activeTab?.url != nil) { tabManager.startSplitView() }
        case .sources:
            icon(button.symbol, L10n("Sources · ⌘⇧S to save page")) { SourcesWindow.show(for: tabManager) }
        case .bookmark:
            let saved = tabManager.activeTab?.url.map { tabManager.bookmarks.contains($0) } ?? false
            icon(saved ? "bookmark.fill" : "bookmark", L10n("Bookmark (⌘D)"), enabled: tabManager.activeTab?.url != nil) {
                tabManager.bookmarkEditorVisible.toggle()
            }
        case .readerMode:
            let tab = tabManager.activeTab
            icon(tab?.isReaderActive == true ? "doc.plaintext.fill" : "doc.plaintext", L10n("Reader mode (⌘⇧R)"),
                 enabled: tab?.isReaderable == true || tab?.isReaderActive == true) { tabManager.toggleReaderMode() }
        case .copyURL:
            icon(copied ? "checkmark" : "doc.on.doc", L10n("Copy address (⌘⇧C)"), enabled: tabManager.activeTab?.url != nil) {
                guard let value = tabManager.activeTab?.url?.absoluteString else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
        case .newWindow:
            icon(button.symbol, L10n("New window (⌘N)")) { (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow() }
        case .incognitoWindow:
            icon(button.symbol, L10n("Incognito window (⇧⌘N)")) {
                (NSApp.delegate as? AircraftAppDelegate)?.openNewBrowserWindow(incognito: true)
            }
        case .settings:
            icon(button.symbol, L10n("Settings (⌘,)")) {
                NotificationCenter.default.post(name: .openSettings, object: tabManager.hostWindow ?? NSApp.keyWindow)
            }
        case .devtools:
            icon(button.symbol, "Web Inspector") { tabManager.toggleModPanel("devtools") }
        case .historyPanel:
            icon(button.symbol, L10n("History and accounts panel")) { tabManager.toggleModPanel("historyAccounts") }
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
            Text(L10n("Only tabs, New Tab and the profile switcher remain."))
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
                        Text(L10n("Requires the %1$@ mod", "\(capability)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { move(from: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help(L10n("Move up"))
                Button { move(from: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == buttons.count - 1)
                    .help(L10n("Move down"))
                Button { remove(button) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .help(L10n("Remove"))
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
                Label(L10n("Add button"), systemImage: "plus")
            }
            .fixedSize()
            .disabled(available.isEmpty)
            Spacer()
            Button(L10n("Restore defaults")) { stored = PanelButton.encode(PanelButton.defaults) }
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
