import AircraftLanguage
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Darwin.Mach
import Combine

public enum ViewState: String, Codable {
    case home, settings, workspace
}

public struct BrowserShellView: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var currentState: ViewState = .workspace
    /// Закреплена ли панель вкладок — это настройка «Скрывать панель» в положении «Никогда».
    /// ⌃⌥S и кнопка «Закрепить / скрыть» переключают её между «Никогда» и «Всегда».
    @AppStorage(PanelVisibility.modeKey) private var panelHideMode: String = "always"
    @State private var showSearchModal: Bool = false
    @State private var spotlightSeed: String = ""
    @State private var spotlightRequestID = UUID()
    @State private var windowNumber: Int?

    // AppStorage States
    @AppStorage("tabGroupsEnabled") private var tabGroupsEnabled: Bool = false
    @AppStorage("tabPosition") private var tabPosition: String = "left"
    @AppStorage("browserTheme") private var browserTheme: String = "system"
    @AppStorage("resourceMonitoring") private var resourceMonitoring: Bool = false
    @AppStorage("resourceLimitAlert") private var resourceLimitAlert: String = "none"
    @AppStorage("resourceLimitMB") private var resourceLimitMB: Double = 512
    @AppStorage("resourceResetScope") private var resourceResetScope: String = "backgroundTabs"
    @AppStorage("resourceResetShortcut") private var resourceResetShortcut: String = "control-option-r"
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = SidebarMetrics.defaultWidth
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @AppStorage(AircraftTheme.liquidGlassKey) private var liquidGlass = false
    @State private var windowWidth: CGFloat = 1000

    public init() {}

    public var body: some View {
        featureHandlers(moreHandlers(styledContent
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { notification in
            guard isTargetWindow(notification) else { return }
            showSearchModal = false
            SettingsWindowController.shared.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLocation)) { notification in
            guard isTargetWindow(notification) else { return }
            currentState = .workspace
            presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { notification in
            guard isTargetWindow(notification) else { return }
            let fullScreen = (notification.object as? NSWindow)?.styleMask.contains(.fullScreen) ?? false
            panelHideMode = PanelVisibility.toggled(mode: panelHideMode, fullScreen: fullScreen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWorkspace)) { notification in
            guard isTargetWindow(notification) else { return }
            currentState = .workspace
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeActiveTab)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.closeActiveTabFromShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCurrentURLSpotlight)) { notification in
            guard isTargetWindow(notification) else { return }
            currentState = .workspace
            presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTabByNumber)) { notification in
            selectTabByNumber(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCurrentURLSpotlight)) { notification in
            toggleCurrentURLSpotlight(notification)
        }))
    }

    /// Окно, команды браузера (⌘F, ⌘⇧T, ⌘D…), профили, перетаскивание файлов.
    private func featureHandlers<V: View>(_ view: V) -> some View {
        view
        .onChange(of: windowNumber) { _, number in
            guard let number, let window = NSApp.window(withWindowNumber: number) else { return }
            tabManager.hostWindow = window
            if tabManager.isIncognito { window.title = L10n("Incognito") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow, window.windowNumber == windowNumber else { return }
            if !tabManager.isIncognito { SessionStore.shared.windowClosed(tabManager) }
            for tab in tabManager.tabs { tab.webView?.stopLoading() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserCommand)) { notification in
            guard isTargetWindow(notification), let command = notification.userInfo?["command"] as? String else { return }
            BrowserCommands.perform(command, in: tabManager, presentSpotlight: { presentSpotlight(query: $0) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDeleted)) { notification in
            guard let id = notification.userInfo?["id"] as? UUID else { return }
            tabManager.profileWasDeleted(id)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            BrowserCommands.openDroppedFiles(providers, in: tabManager)
            return true
        }
    }

    /// Окно с общим оформлением (размер, фон, тема).
    private var styledContent: some View {
        windowContent
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .onChange(of: tabManager.activeTabID) { _, _ in refreshSpotlightForActiveTab() }
            .onChange(of: showSearchModal) { _, shown in if !shown { keepSpotlightOnEmptyTab() } }
            .onChange(of: currentState) { _, _ in keepSpotlightOnEmptyTab() }
            .onAppear { keepSpotlightOnEmptyTab() }
            .frame(minWidth: 360, minHeight: 520)
            .ignoresSafeArea(.container, edges: .top)
            .background(glassActive ? Color.clear : Color(NSColor.windowBackgroundColor))
            .background(WindowTabbingDisabler(windowNumber: $windowNumber))
            .background(GlassWindowConfigurator(enabled: glassActive))
            .fontWeight(.medium)
            .preferredColorScheme(tabManager.isIncognito ? .dark : (browserTheme == "dark" ? .dark : (browserTheme == "light" ? .light : nil)))
    }

    private var glassActive: Bool { liquidGlass && !tabManager.isIncognito }

    private func toggleCurrentURLSpotlight(_ notification: Notification) {
        guard isTargetWindow(notification) else { return }
        if showSearchModal {
            showSearchModal = false
        } else {
            currentState = .workspace
            presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
        }
    }

    private var windowContent: some View {
        ZStack {
            Group {
                switch currentState {
                case .home:
                    HomeView(currentState: $currentState, showSearchModal: $showSearchModal)
                case .workspace, .settings:
                    WorkspaceView(
                        sidebarVisible: Binding(get: { panelHideMode == "never" },
                                                set: { panelHideMode = $0 ? "never" : "always" }),
                        showSearchModal: $showSearchModal,
                        tabGroupsEnabled: tabGroupsEnabled,
                        tabPosition: tabPosition,
                        resourceMonitoring: resourceMonitoring,
                        resourceLimitAlert: resourceLimitAlert,
                        resourceLimitMB: resourceLimitMB,
                        sidebarWidth: $sidebarWidth
                    )
                }
            }

            // Верхний край окна: за него всегда можно потянуть окно, какая бы панель там ни была.
            WindowDragArea()
                .frame(height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()

            if showSearchModal {
                // Spotlight не перекрывает панель вкладок, чтобы по ним можно было кликать.
                SearchModalView(isPresented: $showSearchModal, currentState: $currentState, initialQuery: spotlightSeed)
                    .id(spotlightRequestID)
                    .padding(spotlightTabInsets)
                    .zIndex(100)
            }
        }
    }

    /// Остальные обработчики команд — отдельно, чтобы компилятору было проще.
    private func moreHandlers<V: View>(_ view: V) -> some View {
        view
        .onReceive(NotificationCenter.default.publisher(for: .showEmptySpotlight)) { notification in
            guard isTargetWindow(notification) else { return }
            currentState = .workspace
            presentSpotlight(query: "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetResources)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.resetResources(scope: UserDefaults.standard.string(forKey: "resourceResetScope") ?? "backgroundTabs")
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadActiveTab)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.reloadActiveTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .goBack)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.goBackActiveTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleWebInspector)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.toggleWebInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startElementPicker)) { notification in
            guard isTargetWindow(notification), let webView = tabManager.activeWebView else { return }
            Task { await ElementPicker.start(in: webView) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goForward)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.goForwardActiveTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createHomeTab)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.createNewTab()
            currentState = .workspace
            presentSpotlight(query: "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .createHomeTabWithoutSpotlight)) { notification in
            guard isTargetWindow(notification) else { return }
            tabManager.createNewTab()
            currentState = .workspace
            showSearchModal = false
        }
    }

    /// ⌘1…⌘8 — вкладка по номеру, ⌘9 — последняя.
    private func selectTabByNumber(_ notification: Notification) {
        guard isTargetWindow(notification),
              let number = notification.userInfo?["number"] as? Int,
              !tabManager.tabs.isEmpty else { return }
        let index = number == 9 ? tabManager.tabs.count - 1 : number - 1
        guard tabManager.tabs.indices.contains(index) else { return }
        currentState = .workspace
        tabManager.selectTab(id: tabManager.tabs[index].id)
    }

    /// При переключении вкладки в открытом Spotlight подставляем её URL;
    /// на пустую вкладку Spotlight открывается сам.
    private func refreshSpotlightForActiveTab() {
        if showSearchModal {
            presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
        } else {
            keepSpotlightOnEmptyTab()
        }
    }

    /// Пустая новая вкладка (без адреса) — на ней всегда открыт Spotlight.
    private var activeTabIsEmpty: Bool {
        guard let tab = tabManager.activeTab else { return false }
        return tab.url == nil
    }

    private func keepSpotlightOnEmptyTab() {
        guard currentState == .workspace, activeTabIsEmpty, !showSearchModal else { return }
        // Следующий цикл: даём закрыться текущему Spotlight и смениться вкладке.
        DispatchQueue.main.async {
            guard currentState == .workspace, activeTabIsEmpty, !showSearchModal else { return }
            presentSpotlight(query: "")
        }
    }

    /// Место, которое занимает панель вкладок; Spotlight его не закрывает.
    private var spotlightTabInsets: EdgeInsets {
        guard currentState == .workspace, tabGroupsEnabled, windowWidth >= 600 else { return EdgeInsets() }
        let sidebar = SidebarMetrics.clamp(sidebarWidth)
        let bar = 42 * tabScale
        switch tabPosition {
        case "top": return EdgeInsets(top: bar, leading: 0, bottom: 0, trailing: 0)
        case "right": return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: sidebar)
        default: return EdgeInsets(top: 0, leading: sidebar, bottom: 0, trailing: 0)
        }
    }

    private func presentSpotlight(query: String) {
        spotlightSeed = query
        spotlightRequestID = UUID()
        showSearchModal = true
    }

    private func isTargetWindow(_ notification: Notification) -> Bool {
        guard let target = notification.object as? NSWindow else { return true }
        return target.windowNumber == windowNumber
    }
}

// MARK: - Home View

public struct HomeView: View {
    @Binding public var currentState: ViewState
    @Binding public var showSearchModal: Bool
    @State private var searchInput: String = ""
    @State private var urlSystemActive = false
    @State private var selectedURLSystem = 0
    @FocusState private var searchFocused: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("customURLPrefixesJSON") private var customURLPrefixesJSON: String = "[]"

    private var urlPrefixes: [String] {
        URLSystemStore.prefixes(json: customURLPrefixesJSON, legacyPrefix: customURLPrefix)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: urlSystemActive ? "link" : "magnifyingglass")
                            .foregroundStyle(urlSystemActive ? Color.accentColor : .secondary)
                        TextField(urlSystemActive ? selectedPrefixLabel : L10n("Search or URL · Tab for URL shortcuts"), text: $searchInput)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onKeyPress(.tab) {
                                urlSystemActive.toggle()
                                selectedURLSystem = 0
                                return .handled
                            }
                            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                                guard urlSystemActive, !urlPrefixes.isEmpty else { return .ignored }
                                let delta = press.key == .downArrow ? 1 : -1
                                selectedURLSystem = (selectedURLSystem + delta + urlPrefixes.count) % urlPrefixes.count
                                return .handled
                            }
                            .onSubmit { processNavigation() }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 450, minHeight: 44)
                    .background(Color(NSColor.controlBackgroundColor))

                    if urlSystemActive {
                        URLSystemSuggestions(query: searchInput, prefixes: urlPrefixes, selectedIndex: selectedURLSystem) { target in
                            tabManager.navigateActiveTab(to: target)
                            currentState = .workspace
                        }
                    }
                }
                .frame(maxWidth: 450)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.06), radius: 8, y: 2)
            }
            .padding(.horizontal, 20)

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
            }) {
                Text(L10n("Set up →"))
                    .foregroundColor(.gray)
                    .font(.system(size: 13))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { searchFocused = true }
    }

    private func processNavigation() {
        var target = searchInput
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if (urlSystemActive || flags.contains(.option)), !urlPrefixes.isEmpty,
           let prefixed = URLRouter.prefixedTarget(query: searchInput, prefix: urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)]) {
            target = prefixed
        }
        if !target.isEmpty {
            tabManager.navigateActiveTab(to: target)
        }
        currentState = .workspace
    }

    private var selectedPrefixLabel: String {
        guard !urlPrefixes.isEmpty else { return L10n("No URL shortcuts") }
        return urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)] + "/…"
    }
}

// MARK: - Settings View

public struct SettingsView: View {
    /// Закрыть окно настроек.
    var onClose: () -> Void = {}
    /// Вкладки окна браузера, из которого открыты настройки (может не быть).
    @Environment(TabManager.self) private var tabManager: TabManager?
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("tabGroupsEnabled") private var tabGroupsEnabled: Bool = false
    @AppStorage("tabPosition") private var tabPosition: String = "left"
    @AppStorage("browserTheme") private var browserTheme: String = "system"
    @AppStorage(AircraftTheme.liquidGlassKey) private var liquidGlass = false
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @AppStorage("topBarHideMode") private var topBarHideMode: String = "always"
    @AppStorage("resourceMonitoring") private var resourceMonitoring: Bool = false
    @AppStorage("resourceLimitAlert") private var resourceLimitAlert: String = "none"
    @AppStorage("resourceLimitMB") private var resourceLimitMB: Double = 512
    @AppStorage("resourceResetScope") private var resourceResetScope: String = "backgroundTabs"
    @AppStorage("resourceResetShortcut") private var resourceResetShortcut: String = "control-option-r"
    @AppStorage("downloadFolderPath") private var downloadFolderPath: String = ""
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("customURLPrefixesJSON") private var customURLPrefixesJSON: String = "[]"
    @AppStorage("searchEngine") private var searchEngine: String = "duckduckgo"
    @AppStorage("customSearchURL") private var customSearchURL: String = ""
    @AppStorage(CommandShiftRAction.storageKey) private var commandShiftR: String = CommandShiftRAction.hardReload.rawValue
    @AppStorage(TopBarItem.tilesAsFolderKey) private var topBarTilesAsFolder = true
    @AppStorage(SiteIdentity.storageKey) private var siteIdentity: String = SiteIdentity.safari.rawValue
    @AppStorage(LocalDevelopment.storageKey) private var localDevTools = true

    @State private var customScripts: [String] = []
    @State private var editableURLPrefix: String = ""
    @State private var editingURLPrefixIndex: Int?
    @State private var urlValidationMessage: String?
    @State private var searchURLValidationMessage: String?
    @State private var searchTemplatePreset: String = "duckduckgo"

    private var urlPrefixes: [String] {
        URLSystemStore.prefixes(json: customURLPrefixesJSON, legacyPrefix: customURLPrefix)
    }

    @AppStorage(InterfaceLanguage.preferenceKey) private var language = "system"
    @State private var selectedSection: SettingsPane = .general

    public var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                settingsHeader
                paneContent
                    .frame(maxWidth: 680, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(liquidGlass ? Color.clear : Color(NSColor.windowBackgroundColor))
        }
        .background { if liquidGlass { GlassWindowBackground() } }
        .background(GlassWindowConfigurator(enabled: liquidGlass))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { onClose() }
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsPane)) { notification in
            if let raw = notification.userInfo?["pane"] as? String, let pane = SettingsPane(rawValue: raw) {
                selectedSection = pane
            }
        }
        .onAppear {
            loadCustomModifications()
            editableURLPrefix = ""
            if customURLPrefixesJSON == "[]", !customURLPrefix.isEmpty {
                customURLPrefixesJSON = URLSystemStore.json(for: urlPrefixes)
            }
            if searchEngine == "custom" {
                searchTemplatePreset = "custom"
            } else {
                searchTemplatePreset = searchEngine
                customSearchURL = SearchEngineOption.queryTemplate(for: searchEngine, customURL: customSearchURL)
            }
        }
    }

    // MARK: Каркас

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Место под кнопки управления окном.
            Color.clear.frame(height: 44)
            Text(L10n("Settings"))
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsGroup(L10n("Interface"), [.general, .tabs, .search, .shortcuts])
                    settingsGroup(L10n("Data"), [.profiles, .transfer, .privacy, .adblock])
                    settingsGroup(L10n("Tools"), [.resources, .mods, .agents, .browser])
                }
            }
            Spacer()
            Text("Aircraft \(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    private func settingsGroup(_ title: String, _ panes: [SettingsPane]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(panes) { pane in
                SettingsSidebarRow(pane: pane, isSelected: selectedSection == pane) {
                    selectedSection = pane
                }
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            Text(selectedSection.title)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button(L10n("Done")) { onClose() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedSection {
        case .browser: browserPane
        case .transfer: transferPane
        case .general: generalPane
        case .tabs: tabsPane
        case .search: searchPane
        case .resources: resourcesPane
        case .adblock: AdBlockSettingsPane(currentSiteHost: currentSiteHost)
        case .mods: modsPane
        case .agents: AgentSettingsPane()
        case .shortcuts: shortcutsPane
        case .profiles: ProfilesSettingsPane()
        case .privacy: PrivacySettingsPane(manager: tabManager)
        }
    }

    private var appVersion: String { AppInfo.displayVersion }

    /// Моды подключаются во всех окнах браузера, а не только в одном.
    private func reloadModsEverywhere() {
        AgentBrowser.allManagers.forEach { $0.reloadCustomModifications() }
    }

    // MARK: Браузер

    @State private var isDefaultBrowser = false

    private var browserPane: some View {
        Form {
            Section {
                Picker(L10n("Identify as"), selection: $siteIdentity) {
                    ForEach(SiteIdentity.allCases) { identity in
                        Text(identity.title).tag(identity.rawValue)
                    }
                }
                Toggle(L10n("Localhost tools"), isOn: $localDevTools)
            } header: {
                Text(L10n("Sites"))
            } footer: {
                Text(L10n("Safari works with most sign-ins. Chrome can enable Chromium-specific pages. Localhost tools show ports, bypass the cache, keep tabs awake and accept local certificates."))
                    .foregroundStyle(.secondary)
            }

            AppLinksSettingsSection()
            WebAppsSettingsSection()
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aircraft")
                            .font(.system(size: 22, weight: .bold))
                        Text(L10n("Version %1$@ (build %2$@)", "\(AppInfo.displayVersion)", "\(AppInfo.build)"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section(L10n("About")) {
                LabeledContent(L10n("Engine"), value: "WebKit \(AppInfo.webKitVersion)")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent(L10n("Mod SDK"), value: "Aircraft Mod SDK 0.2")
                LabeledContent(L10n("Identifier"), value: Bundle.main.bundleIdentifier ?? "—")
            }

            Section(L10n("Data")) {
                HStack {
                    Text(L10n("Mods and settings are stored on this Mac."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n("Open folder")) { openDataFolder() }
                }
                HStack {
                    Spacer()
                    Link(L10n("GitHub project"), destination: URL(string: "https://github.com/killedbycss/Aircraft")!)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func refreshDefaultBrowserState() {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            isDefaultBrowser = false
            return
        }
        isDefaultBrowser = handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefaultBrowser() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { _ in
                Task { @MainActor in refreshDefaultBrowserState() }
            }
        }
    }

    private func openDataFolder() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("aircraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private var transferPane: some View {
        Form {
            Section(L10n("Downloads")) {
                LabeledContent(L10n("Download folder")) {
                    HStack(spacing: 8) {
                        Text(downloadFolderPath.isEmpty ? L10n("Downloads") : URL(fileURLWithPath: downloadFolderPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(L10n("Choose…")) { chooseDownloadFolder() }
                    }
                }
            }
            ImportSettingsSection(manager: tabManager)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Основные

    private var generalPane: some View {
        Form {
            Section {
                Picker(L10n("Interface language"), selection: $language) {
                    Text(L10n("System default")).tag("system")
                    Text(verbatim: "Русский").tag("ru")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: language) { _, choice in InterfaceLanguage.save(choice) }
            } footer: {
                Text(L10n("Restart Aircraft to apply the language."))
            }
            Section {
                LabeledContent(L10n("Default browser")) {
                    if isDefaultBrowser {
                        Label("Aircraft", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L10n("Set as default")) { makeDefaultBrowser() }
                    }
                }
            }

            Section(L10n("Appearance")) {
                Picker(L10n("Theme"), selection: $browserTheme) {
                    Text(L10n("theme.system")).tag("system")
                    Text(L10n("Light")).tag("light")
                    Text(L10n("Dark")).tag("dark")
                }
                .pickerStyle(.segmented)
                LiquidGlassToggle()
            }
            Section {
                ThemePicker()
            } header: {
                Text(L10n("Window color"))
            } footer: {
                Text(L10n("Tints the tab bar and page frame outside incognito windows."))
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { refreshDefaultBrowserState() }
    }

    // MARK: Вкладки

    private var tabsPane: some View {
        Form {
            Section {
                Toggle(L10n("Tab bar"), isOn: $tabGroupsEnabled)
            } footer: {
                Text(L10n("Turn off to show only the current tab."))
                    .foregroundStyle(.secondary)
            }
            Section(L10n("Position")) {
                Picker(L10n("Tab bar position"), selection: $tabPosition) {
                    Text(L10n("Left")).tag("left")
                    Text(L10n("Right")).tag("right")
                    Text(L10n("Top")).tag("top")
                }
                .pickerStyle(.segmented)
                Toggle(L10n("Group favorite tiles"), isOn: $topBarTilesAsFolder)
                    .disabled(tabPosition != "top")
                    .help(L10n("Show favorites in one menu on the horizontal tab bar."))
                LabeledContent(L10n("Panel size")) {
                    HStack(spacing: 10) {
                        Slider(value: $tabScale, in: 0.8...1.5, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int(tabScale * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .disabled(!tabGroupsEnabled)
            Section {
                PanelButtonsEditor()
            } header: {
                Text(L10n("Panel buttons"))
            } footer: {
                Text(L10n("Drag a row or use the arrows to reorder buttons."))
                    .foregroundStyle(.secondary)
            }
            .disabled(!tabGroupsEnabled)
            Section(L10n("Auto-hide")) {
                Picker(L10n("Hide tab bar"), selection: $topBarHideMode) {
                    Text(L10n("Always")).tag("always")
                    Text(L10n("In windowed mode")).tag("windowed")
                    Text(L10n("Never")).tag("never")
                }
                LabeledContent(L10n("Toggle visibility"), value: "⌃⌥S")
                Text(L10n("Move the pointer to the window edge to reveal the bar. It stays visible while Spotlight is open."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .disabled(!tabGroupsEnabled)
            TabBehaviorSettings()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Поиск и URL

    private var searchPane: some View {
        Form {
            Section {
                Picker(L10n("Search engine"), selection: $searchTemplatePreset) {
                    ForEach(SearchEngineOption.popular) { engine in
                        Text(engine.title).tag(engine.id)
                    }
                    Divider()
                    Text(L10n("Custom template")).tag("custom")
                }
                .onChange(of: searchTemplatePreset) { _, preset in
                    guard let engine = SearchEngineOption.popular.first(where: { $0.id == preset }) else { return }
                    customSearchURL = engine.queryURL
                    searchEngine = engine.id
                    searchURLValidationMessage = nil
                }
                HStack(spacing: 8) {
                    TextField(L10n("Template"), text: $customSearchURL, prompt: Text("https://search.example/?q={query}"))
                        .onSubmit { selectCustomSearch() }
                    Button(L10n("Save")) { selectCustomSearch() }
                }
                if let searchURLValidationMessage {
                    Text(searchURLValidationMessage).foregroundStyle(.red).font(.system(size: 12))
                }
            } header: {
                Text(L10n("Search"))
            } footer: {
                Text(L10n("Use {query}, %s or %@ for the search term."))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField(L10n("Domain"), text: $editableURLPrefix, prompt: Text(L10n("e.g. github.io")))
                        .onSubmit { saveURLPrefix() }
                    Button(editingURLPrefixIndex == nil ? L10n("Add") : L10n("Save")) { saveURLPrefix() }
                    if editingURLPrefixIndex != nil {
                        Button(L10n("Cancel")) { cancelURLPrefixEditing() }
                    }
                }
                if let urlValidationMessage {
                    Text(urlValidationMessage).foregroundStyle(.red).font(.system(size: 12))
                }
                ForEach(Array(urlPrefixes.enumerated()), id: \.offset) { index, prefix in
                    HStack {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text(prefix).lineLimit(1)
                        Spacer()
                        Button { beginEditingURLPrefix(at: index) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help(L10n("shortcut.edit"))
                        Button { removeURLPrefix(at: index) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(L10n("Delete"))
                    }
                }
            } header: {
                Text(L10n("URL shortcuts"))
            } footer: {
                Text(L10n("Press Tab in Spotlight to use a URL shortcut."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Ресурсы

    private var resourcesPane: some View {
        Form {
            Section(L10n("Monitoring")) {
                Toggle(L10n("Show memory usage"), isOn: $resourceMonitoring)
                Picker(L10n("Notify"), selection: $resourceLimitAlert) {
                    Text(L10n("Never")).tag("none")
                    Text(L10n("When over the limit")).tag("limit")
                }
                LabeledContent(L10n("Memory limit")) {
                    HStack(spacing: 10) {
                        Slider(value: $resourceLimitMB, in: 128...2048, step: 64)
                            .frame(width: 180)
                        Text(L10n("%1$@ MB", "\(Int(resourceLimitMB))"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(resourceLimitAlert != "limit")
            }
            Section(L10n("Free up resources")) {
                Picker(L10n("Clear"), selection: $resourceResetScope) {
                    Text(L10n("Background tabs")).tag("backgroundTabs")
                    Text(L10n("All tabs from memory")).tag("allTabs")
                    Text(L10n("Web cache and site data")).tag("webCache")
                }
                Picker(L10n("Keyboard shortcut"), selection: $resourceResetShortcut) {
                    Text("⌃⌥R").tag("control-option-r")
                    Text("⌃⌥⇧R").tag("control-option-shift-r")
                    Text("⌘⌥⇧R").tag("command-option-shift-r")
                }
                HStack {
                    Spacer()
                    Button(L10n("Clear now")) { tabManager?.resetResources(scope: resourceResetScope) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Модификации

    private var currentSiteHost: String? {
        guard let url = tabManager?.activeTab?.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return AdBlocker.normalizedHost(url.host)
    }

    private var modsPane: some View {
        Form {
            Section {
                ForEach(BundledMod.all) { mod in
                    let installedFile = customScripts.first { ModCatalog.family(for: $0) == mod.id }
                    HStack(spacing: 12) {
                        Image(systemName: mod.icon)
                            .modifier(SettingsSymbolStyle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.title)
                            Text(mod.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let installedFile {
                            Button(L10n("Delete"), role: .destructive) { removeModification(named: installedFile) }
                        } else {
                            Button(L10n("Install")) { installBundledModification(named: mod.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(L10n("Built-in mods"))
            } footer: {
                Text(L10n("These optional tools use additional resources."))
                    .foregroundStyle(.secondary)
            }

            Section {
                let ownScripts = customScripts.filter { ModCatalog.family(for: $0) == nil }
                if ownScripts.isEmpty {
                    Text(L10n("No custom mods."))
                        .foregroundStyle(.secondary)
                }
                ForEach(ownScripts, id: \.self) { script in
                    HStack {
                        Image(systemName: script.hasSuffix(".css") ? "paintbrush" : "curlybraces")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(script).lineLimit(1)
                        Spacer()
                        Button { removeModification(named: script) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(L10n("Move to Trash"))
                    }
                }
                HStack {
                    Button(L10n("Add file…")) { openScriptPanel() }
                    Spacer()
                    Button(L10n("SDK guide")) { openModGuide() }
                    Button(L10n("Open folder")) { openModsFolder() }
                }
            } header: {
                Text(L10n("Custom mods"))
            } footer: {
                Text(L10n("JavaScript and CSS files run on every page."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Сочетания клавиш

    private var shortcutsPane: some View {
        Form {
            Section(L10n("Tabs")) {
                LabeledContent(L10n("New Tab"), value: "⌘T")
                LabeledContent(L10n("Close tab"), value: "⌘W")
                LabeledContent(L10n("Reopen closed tab"), value: "⌘⇧T")
                LabeledContent(L10n("Previous / next tab"), value: "⌥←  ·  ⌥→")
                LabeledContent(L10n("Tab by number"), value: "⌘1 … ⌘8")
                LabeledContent(L10n("Last tab"), value: "⌘9")
                LabeledContent(L10n("Mute tab"), value: "⌘⇧M")
                LabeledContent(L10n("Toggle tab bar"), value: "⌃⌥S")
                LabeledContent(L10n("Select multiple tabs"), value: L10n("⌘-click in tab bar"))
            }
            Section(L10n("Page")) {
                LabeledContent(L10n("Find on page"), value: "⌘F  ·  ⌘G  ·  ⌘⇧G")
                LabeledContent(L10n("Zoom"), value: "⌘=  ·  ⌘−  ·  ⌘0")
                LabeledContent(L10n("Copy Link"), value: "⌘⇧C")
                Picker("⌘⇧R", selection: $commandShiftR) {
                    ForEach(CommandShiftRAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                LabeledContent(L10n("Reload without cache"), value: "⌥⌘R")
                LabeledContent(L10n("Save to Sources (mod)"), value: "⌘⇧S")
                LabeledContent(L10n("Focus left / right pane"), value: "⌥⌘←  ·  ⌥⌘→")
                LabeledContent(L10n("Hide page element"), value: "⌥⌘B")
                LabeledContent(L10n("Edit / save Markdown"), value: "⌘E  ·  ⌘S")
                LabeledContent("Web Inspector", value: "F12  ·  ⌥⌘I")
            }
            Section(L10n("Navigation")) {
                LabeledContent(L10n("Show current URL in Spotlight"), value: L10n("Press and release ⌘⇧"))
                LabeledContent(L10n("Address or search"), value: "⌘L")
                LabeledContent(L10n("Back / forward"), value: L10n("⌘[ · ⌘] · two-finger swipe"))
                LabeledContent(L10n("Show navigation history"), value: L10n("Hold or right-click an arrow"))
                LabeledContent(L10n("Reload / stop"), value: "⌘R  ·  ⌘.")
            }
            Section(L10n("Bookmarks and history")) {
                LabeledContent(L10n("Add bookmark"), value: "⌘D")
                LabeledContent(L10n("Bookmarks"), value: "⌘⇧B")
                LabeledContent(L10n("History and accounts"), value: "⌘Y")
                LabeledContent(L10n("Downloads"), value: "⌥⌘L")
            }
            Section(L10n("Windows and profiles")) {
                LabeledContent(L10n("New Window"), value: "⌘N")
                LabeledContent(L10n("Incognito window"), value: "⌘⇧N")
                LabeledContent(L10n("Profile by number"), value: "⌃1 … ⌃9")
                LabeledContent(L10n("Open file"), value: "⌘O")
                LabeledContent(L10n("Settings"), value: "⌘,")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func loadCustomModifications() {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let targetDir = appSupportURL.appendingPathComponent("aircraft/mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        do {
            let files = try FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil)
            customScripts = files.filter { $0.pathExtension == "js" || $0.pathExtension == "css" }.map { $0.lastPathComponent }
        } catch {
            customScripts = []
        }
    }

    private func openScriptPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.sourceCode, UTType.plainText, UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let targetDir = appSupportURL.appendingPathComponent("aircraft/mods", isDirectory: true)
                    try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    let destination = availableDestination(for: url.lastPathComponent, source: url, in: targetDir)
                    do {
                        if FileManager.default.fileExists(atPath: destination.path),
                           FileManager.default.contentsEqual(atPath: url.path, andPath: destination.path) {
                            loadCustomModifications()
                            return
                        }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: url, to: destination)
                        loadCustomModifications()
                        reloadModsEverywhere()
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { downloadFolderPath = url.path }
        }
    }

    private func openModGuide() {
        guard let url = Bundle.main.url(forResource: "Modifications", withExtension: "md") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func installBundledModification(named name: String) {
        guard let source = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "ModTemplates"),
              let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            NSSound.beep()
            return
        }
        let targetDirectory = appSupportURL.appendingPathComponent("aircraft/mods", isDirectory: true)
        let destination = targetDirectory.appendingPathComponent("\(name).js")
        do {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            loadCustomModifications()
            reloadModsEverywhere()
        } catch {
            NSSound.beep()
        }
    }

    private func openModsFolder() {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let targetDir = appSupportURL.appendingPathComponent("aircraft/mods", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(targetDir)
    }

    private func saveURLPrefix() {
        guard let normalized = URLRouter.normalizedPrefix(editableURLPrefix) else {
            urlValidationMessage = L10n("Enter a domain or URL without spaces.")
            return
        }
        var prefixes = urlPrefixes
        if let editingURLPrefixIndex, prefixes.indices.contains(editingURLPrefixIndex) {
            prefixes[editingURLPrefixIndex] = normalized
        } else if !prefixes.contains(normalized) {
            prefixes.append(normalized)
        }
        prefixes = Array(NSOrderedSet(array: prefixes)) as? [String] ?? prefixes
        customURLPrefixesJSON = URLSystemStore.json(for: prefixes)
        customURLPrefix = prefixes.first ?? ""
        editableURLPrefix = ""
        editingURLPrefixIndex = nil
        urlValidationMessage = nil
    }

    private func beginEditingURLPrefix(at index: Int) {
        guard urlPrefixes.indices.contains(index) else { return }
        editableURLPrefix = urlPrefixes[index]
        editingURLPrefixIndex = index
        urlValidationMessage = nil
    }

    private func cancelURLPrefixEditing() {
        editableURLPrefix = ""
        editingURLPrefixIndex = nil
        urlValidationMessage = nil
    }

    private func removeURLPrefix(at index: Int) {
        var prefixes = urlPrefixes
        guard prefixes.indices.contains(index) else { return }
        prefixes.remove(at: index)
        customURLPrefixesJSON = URLSystemStore.json(for: prefixes)
        customURLPrefix = prefixes.first ?? ""
        if editingURLPrefixIndex == index { cancelURLPrefixEditing() }
        else if let editingURLPrefixIndex, editingURLPrefixIndex > index {
            self.editingURLPrefixIndex = editingURLPrefixIndex - 1
        }
        urlValidationMessage = nil
    }

    private func selectCustomSearch() {
        let template = customSearchURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLRouter.searchTarget(query: "test", template: template) != nil else {
            searchURLValidationMessage = L10n("Enter a full URL, e.g. https://site/search?q={query}")
            return
        }
        customSearchURL = template
        searchEngine = "custom"
        searchTemplatePreset = "custom"
        searchURLValidationMessage = nil
    }

    private func availableDestination(for fileName: String, source: URL, in directory: URL) -> URL {
        if let family = ModCatalog.family(for: fileName) {
            return directory.appendingPathComponent("\(family).js")
        }
        let original = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let source = URL(fileURLWithPath: fileName)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var copyNumber = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(copyNumber)" : "\(base) \(copyNumber).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            copyNumber += 1
        }
    }

    private func removeModification(named fileName: String) {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let fileURL = appSupportURL
            .appendingPathComponent("aircraft/mods", isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            loadCustomModifications()
            reloadModsEverywhere()
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Полоска загрузки страницы

/// Тонкая полоса над страницей: растёт по мере загрузки, доходит до конца и плавно гаснет.
private struct PageLoadingBar: View {
    let tab: TabModel
    @State private var visible = false
    @State private var shownProgress: Double = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * shownProgress, height: 2.5)
                .opacity(visible ? 1 : 0)
        }
        .frame(height: 2.5)
        // Полоса загрузки не вылезает за скруглённые углы страницы.
        .padding(.horizontal, AircraftTheme.insetPage ? AircraftTheme.pageCornerRadius * 0.6 : 0)
        .allowsHitTesting(false)
        .onAppear { update(isLoading: tab.isLoading, progress: tab.loadProgress) }
        .onChange(of: tab.isLoading) { _, loading in update(isLoading: loading, progress: tab.loadProgress) }
        .onChange(of: tab.loadProgress) { _, progress in update(isLoading: tab.isLoading, progress: progress) }
    }

    private func update(isLoading: Bool, progress: Double) {
        if isLoading {
            hideTask?.cancel()
            hideTask = nil
            if !visible {
                // Новая загрузка начинается с нуля, без анимации «назад».
                shownProgress = 0
                visible = true
            }
            withAnimation(.easeOut(duration: 0.25)) { shownProgress = max(0.08, progress) }
        } else if visible, hideTask == nil {
            withAnimation(.easeOut(duration: 0.2)) { shownProgress = 1 }
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { visible = false }
                hideTask = nil
            }
        }
    }
}

// MARK: - Анимация вкладок

extension Animation {
    /// Перестроение списка вкладок при открытии и закрытии.
    static let tabList = Animation.spring(response: 0.28, dampingFraction: 0.86)
}

extension AnyTransition {
    /// Новая вкладка проявляется, закрытая — уезжает к краю панели, сжимаясь и растворяясь.
    static func tabClose(edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92)),
            removal: .move(edge: edge).combined(with: .opacity).combined(with: .scale(scale: 0.85))
        )
    }
}

// MARK: - Settings helpers

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
    /// Стадия выпуска (alpha, beta…) из Info.plist.
    static var stage: String {
        Bundle.main.object(forInfoDictionaryKey: "AircraftReleaseStage") as? String ?? "alpha"
    }
    static var displayVersion: String { stage.isEmpty ? version : "\(version) \(stage)" }
    static var webKitVersion: String {
        Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case browser, general, tabs, profiles, privacy, search, adblock, resources, mods, agents, shortcuts, transfer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfer: L10n("Downloads and import")
        case .browser: L10n("Sites and browser")
        case .general: L10n("General")
        case .tabs: L10n("Tabs")
        case .search: L10n("Search and URLs")
        case .adblock: L10n("Content blocking")
        case .resources: L10n("Resources")
        case .mods: L10n("Mods")
        case .agents: L10n("Agents")
        case .shortcuts: L10n("Keyboard shortcuts")
        case .profiles: L10n("Profiles")
        case .privacy: L10n("Privacy")
        }
    }

    var icon: String {
        switch self {
        case .transfer: "arrow.down.doc"
        case .browser: "safari.fill"
        case .general: "gearshape.fill"
        case .tabs: "square.on.square"
        case .search: "magnifyingglass"
        case .adblock: "hand.raised.fill"
        case .resources: "memorychip.fill"
        case .mods: "puzzlepiece.extension.fill"
        case .agents: "sparkles"
        case .shortcuts: "keyboard.fill"
        case .profiles: "person.2.fill"
        case .privacy: "lock.fill"
        }
    }


}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(pane.title)
                    .font(BrowserDesign.TypeRole.title(scale: 1, emphasized: isSelected))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(
                BrowserDesign.Shape.row
                    .fill(BrowserDesign.Surface.tab(active: isSelected, hovered: isHovering))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct BundledMod: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let all: [BundledMod] = [
        .init(id: "aircraft-split-view", title: L10n("Split view"),
              subtitle: L10n("Open two tabs side by side. Both pages stay in memory."), icon: "rectangle.split.2x1"),
        .init(id: "aircraft-sources", title: L10n("Sources"),
              subtitle: L10n("Save articles, PDFs and citations. Export GOST, APA or BibTeX. ⌘⇧S"), icon: "books.vertical.fill"),
        .init(id: "aircraft-devtools-webextensions", title: "Web Inspector + WebExtensions",
              subtitle: L10n("Console, fetch log and chrome.* bridge on every page. ⌘⌥I"), icon: "hammer.fill")
    ]
}

// MARK: - Workspace View

private struct BrowserContentView: View {
    @Binding var showSearchModal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("splitViewRatio") private var splitRatio: Double = 0.5

    var body: some View {
        if let primaryID = tabManager.splitPrimaryTabID,
           let splitID = tabManager.splitTabID,
           splitID != primaryID,
           tabManager.modCapabilities.contains("splitView") {
            GeometryReader { geometry in
                let handleWidth = 8.0
                let availableWidth = max(0, geometry.size.width - handleWidth)
                HStack(spacing: 0) {
                    SplitBrowserPane(tabID: primaryID, showSearchModal: $showSearchModal)
                        .frame(width: availableWidth * splitRatio)
                    SplitResizeHandle(ratio: $splitRatio, totalWidth: availableWidth)
                    SplitBrowserPane(tabID: splitID, showSearchModal: $showSearchModal)
                        .frame(width: availableWidth * (1 - splitRatio))
                }
            }
        } else {
            BrowserPane(tabID: tabManager.activeTabID, showSearchModal: $showSearchModal)
        }
    }
}

private struct SplitBrowserPane: View {
    let tabID: UUID
    @Binding var showSearchModal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager

    private var tab: TabModel? { tabManager.tabs.first(where: { $0.id == tabID }) }
    private var isFocused: Bool { tabManager.activeTabID == tabID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Group {
                    if let tab, tab.url != nil {
                        TabFavicon(tab: tab, copied: false, size: 13)
                    } else {
                        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 13, height: 13)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Menu {
                    Button(L10n("Open URL in this pane…")) {
                        tabManager.focusSplitPane(tabID)
                        NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: tabManager.hostWindow)
                    }
                    Divider()
                    ForEach(tabManager.tabs.filter { $0.url != nil || $0.id == tabID }) { candidate in
                        Button {
                            tabManager.focusSplitPane(tabID)
                            tabManager.selectTab(id: candidate.id)
                        } label: {
                            if candidate.id == tabID {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title.isEmpty ? (candidate.url?.host ?? L10n("New Tab")) : candidate.title)
                            }
                        }
                        .disabled(candidate.id == tabManager.splitPrimaryTabID || candidate.id == tabManager.splitTabID)
                    }
                } label: {
                    Image(systemName: "rectangle.on.rectangle.angled")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n("Choose a page"))
                Button { tabManager.swapSplitPanes() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.plain)
                .help(L10n("Swap panes"))
                Button { tabManager.closeSplitPane(tabID) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L10n("Close pane and keep tab"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isFocused ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(isFocused ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { tabManager.swapSplitPanes() }
            .onTapGesture { tabManager.focusSplitPane(tabID) }
            Divider()
            BrowserPane(tabID: tabID, showSearchModal: $showSearchModal)
        }
        .overlay {
            // Сфокусированная панель — тонкая рамка цвета акцента: видно, куда пойдут ⌘R, ⌘L и ⌘W.
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var title: String {
        guard let tab else { return L10n("New page") }
        if !tab.title.isEmpty, tab.url != nil { return tab.title }
        return tab.url?.host ?? L10n("New page")
    }
}

private struct SplitResizeHandle: View {
    @Binding var ratio: Double
    let totalWidth: Double
    @State private var startingRatio: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(hovering ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: hovering ? 3 : 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { value in
            hovering = value
            if value { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.18)) { ratio = 0.5 }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if startingRatio == nil { startingRatio = ratio }
                    guard totalWidth > 0 else { return }
                    let minimum = min(0.45, 160 / totalWidth)
                    ratio = min(max((startingRatio ?? ratio) + value.translation.width / totalWidth, minimum), 1 - minimum)
                }
                .onEnded { _ in startingRatio = nil }
        )
        .help(L10n("Drag to resize. Double-click for equal widths."))
    }
}

private struct BrowserPane: View {
    let tabID: UUID?
    @Binding var showSearchModal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        if let tabID, let tab = tabManager.tabs.first(where: { $0.id == tabID }), tab.url != nil {
            PageContent(tab: tab)
                .overlay(alignment: .top) { PageLoadingBar(tab: tab) }
                .overlay(alignment: .top) { PageOverlays(tab: tab) }
                .overlay { AgentActivityOverlay(tabID: tabID) }
        } else {
            // Новая вкладка без адреса — просто пустая страница (скруглённая, если страница карточкой).
            RoundedRectangle(cornerRadius: AircraftTheme.insetPage ? AircraftTheme.pageCornerRadius : 0, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WindowPageTopBand: View {
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @Environment(TabManager.self) private var tabManager: TabManager

    @AppStorage(AircraftTheme.insetPageKey) private var insetPage = true

    var body: some View {
        Group {
            if insetPage {
                Color.clear
            } else {
                Color(tabManager.activeTab?.pageBackgroundColor ?? .windowBackgroundColor)
                    .overlay(alignment: .bottom) { Divider().opacity(0.35) }
            }
        }
        .frame(height: (insetPage ? 30 : 38) * tabScale)
    }
}

public struct WorkspaceView: View {
    @Environment(TabManager.self) private var tabManager: TabManager
    @Binding public var sidebarVisible: Bool
    @Binding public var showSearchModal: Bool

    public var tabGroupsEnabled: Bool
    public var tabPosition: String
    public var resourceMonitoring: Bool
    public var resourceLimitAlert: String
    public var resourceLimitMB: Double
    @Binding public var sidebarWidth: Double
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    /// Когда скрывать незакреплённую панель вкладок: always — всегда, windowed — только в окне
    /// (в полноэкранном режиме панель видна), never — не скрывать.
    @AppStorage("topBarHideMode") private var topBarHideMode: String = "always"
    @State private var isFullScreen = false
    /// Панель вкладок в узком окне — своя, чтобы не трогать закреплённую панель обычного режима.
    @State private var mobileTabsOpen = false

    @State private var hoverRevealed: Bool = false
    @State private var hoverHideTask: Task<Void, Never>?
    @State private var hostWindow = HostWindowRef()
    /// Проверка положения курсора у края окна (надёжнее, чем onHover над WKWebView).
    private let edgeHoverTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    @State private var memoryBytes: UInt64 = 0
    @State private var resourceTimerConnection: AnyCancellable?
    private let resourceTimer = Timer.publish(every: 5, on: .main, in: .common)

    public var body: some View {
        GeometryReader { geometry in
            Group {
            if tabGroupsEnabled && geometry.size.width < 600 {
                // Узкое окно: только выезжающая панель вкладок (без горизонтальной полосы),
                // внизу — строка адреса и кнопка вкладок, как в мобильных браузерах.
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 28)
                        BrowserContentView(showSearchModal: $showSearchModal)
                            .pageCard([.horizontal])
                        MobileBottomBar(tabsOpen: $mobileTabsOpen)
                    }
                    if resourceMonitoring {
                        ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            .padding(.bottom, 52)
                    }
                    if mobileTabsOpen {
                        MobileSidebarView(sidebarVisible: $mobileTabsOpen)
                            .transition(.move(edge: tabPosition == "right" ? .trailing : .leading).combined(with: .opacity))
                            .zIndex(10)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: mobileTabsOpen)
                .onChange(of: tabManager.activeTabID) { _, _ in mobileTabsOpen = false }
            } else if !tabGroupsEnabled {
                VStack(spacing: 0) {
                    SingleTabHeader(showSearchModal: $showSearchModal)
                        .frame(height: 38)
                    ZStack(alignment: .bottom) {
                        BrowserContentView(showSearchModal: $showSearchModal)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if resourceMonitoring {
                            ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                        }
                    }
                }
            } else {
                // Modular Mode: Dynamic layout switching without destroying WebContainerView
                if tabPosition == "right" {
                    HStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
                                .pageCard(!tabBarHidden ? [.bottom, .leading] : [.bottom, .horizontal])
                                .safeAreaInset(edge: .top, spacing: 0) { WindowPageTopBand() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                        if !tabBarHidden {
                            SidebarResizeHandle(width: sidebarWidth, sidebarOnRight: true) { newWidth in
                                sidebarWidth = newWidth
                            }
                            SidebarView(side: "right")
                                .frame(width: SidebarMetrics.clamp(sidebarWidth))
                        }
                    }
                    .overlay(alignment: .trailing) { hoverRevealLayer(side: "right") }
                } else if tabPosition == "top" {
                    VStack(spacing: 0) {
                        if !tabBarHidden {
                            TopBarView(showSearchModal: $showSearchModal, reservesWindowControls: true)
                        }
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
                                .pageCard(tabBarHidden ? [] : [.horizontal, .bottom])
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                    }
                    .overlay(alignment: .top) { hoverRevealLayer(side: "top") }
                } else {
                    // "left"
                    HStack(spacing: 0) {
                        if !tabBarHidden {
                            SidebarView(side: "left")
                                .frame(width: SidebarMetrics.clamp(sidebarWidth))
                            SidebarResizeHandle(width: sidebarWidth, sidebarOnRight: false) { newWidth in
                                sidebarWidth = newWidth
                            }
                        }
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
                                .pageCard(!tabBarHidden ? [.vertical, .trailing] : .all)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                    }
                    .overlay(alignment: .leading) { hoverRevealLayer(side: "left") }
                }
            }
        }
        .onAppear {
            tabManager.setMobileBrowsing(geometry.size.width < 600)
        }
        .onChange(of: geometry.size.width) { oldWidth, newWidth in
            let wasCompact = oldWidth < 600
            let isCompact = newWidth < 600
            if wasCompact != isCompact {
                tabManager.setMobileBrowsing(isCompact)
            }
        }
        }
        .chromeBackground()
        .environment(\.windowIsFullScreen, isFullScreen)
        .background(HostWindowReader(ref: hostWindow))
        .onReceive(edgeHoverTimer) { _ in
            // В фоне и в свёрнутом окне проверки не нужны — не будим главный поток зря.
            guard NSApp.isActive, hostWindow.window?.isVisible == true,
                  hostWindow.window?.isMiniaturized == false else { return }
            let fullScreen = hostWindow.window?.styleMask.contains(.fullScreen) ?? false
            if fullScreen != isFullScreen { isFullScreen = fullScreen }
            checkEdgeHover()
            updateWindowButtons()
        }
        .onDisappear { setWindowButtonsHidden(false) }
        .onChange(of: topBarHideMode) { _, _ in
            // ⌃⌥S в узком окне открывает и закрывает выезжающие вкладки.
            if isCompact { mobileTabsOpen.toggle() }
            hoverHideTask?.cancel()
            hoverHideTask = nil
            hoverRevealed = false
        }
        .onAppear { configureResourceTimer(enabled: resourceMonitoring) }
        .onChange(of: resourceMonitoring) { _, enabled in configureResourceTimer(enabled: enabled) }
        .onDisappear { resourceTimerConnection?.cancel(); resourceTimerConnection = nil }
        .onReceive(resourceTimer) { _ in
            guard resourceMonitoring else { return }
            memoryBytes = currentResidentMemory()
        }
    }

    /// Скрытая панель вкладок выезжает поверх страницы, когда курсор подходит к краю окна,
    /// и прячется обратно, когда курсор её покидает. Пока открыт Spotlight, панель видна всегда.
    @ViewBuilder
    private func hoverRevealLayer(side: String) -> some View {
        if tabBarHidden && side == "top" {
            ZStack(alignment: .top) {
                if hoverRevealed || showSearchModal {
                    TopBarView(showSearchModal: $showSearchModal, reservesWindowControls: true)
                        .floatingShadow(Rectangle(), color: .black.opacity(AircraftTheme.liquidGlass ? 0 : 0.18), radius: 12, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.18), value: showSearchModal)
        } else if tabBarHidden {
            ZStack(alignment: side == "right" ? .trailing : .leading) {
                if hoverRevealed || showSearchModal {
                    SidebarView(side: side, pinned: false)
                        .frame(width: SidebarMetrics.clamp(sidebarWidth))
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: side == "right" ? .leading : .trailing) {
                            Divider()
                        }
                        // Стеклянная панель отбрасывает свою тень; обычной — тень по прямоугольнику.
                        .floatingShadow(Rectangle(), color: .black.opacity(AircraftTheme.liquidGlass ? 0 : 0.18),
                                        radius: 12, x: side == "right" ? -2 : 2)
                        .transition(.move(edge: side == "right" ? .trailing : .leading).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: showSearchModal)
        }
    }

    private var isCompact: Bool { (hostWindow.window?.frame.width ?? 1000) < 600 }

    /// Скрыта ли сейчас панель вкладок (слева, справа или сверху): закреплённая видна всегда,
    /// незакреплённая — по настройке «Скрывать панель».
    private var tabBarHidden: Bool {
        guard !sidebarVisible else { return false }
        switch topBarHideMode {
        case "never": return false
        case "windowed": return !isFullScreen
        default: return true
        }
    }

    /// Когда панель вкладок скрыта (сверху, слева или справа), прячем и кнопки окна («светофор»);
    /// они появляются вместе с панелью при наведении или в Spotlight.
    private func updateWindowButtons() {
        let hide = tabGroupsEnabled && tabBarHidden && !isFullScreen
            && !hoverRevealed && !showSearchModal
            && (hostWindow.window?.frame.width ?? 0) >= 600
        setWindowButtonsHidden(hide)
        guard let window = hostWindow.window else { return }
        // Полноэкранный режим: системный заголовок, который выезжает вместе с меню, прячем —
        // кнопки окна стоят на самой панели вкладок.
        FullScreenChrome.setSystemTitlebarHidden(isFullScreen && tabGroupsEnabled, in: window)
        WindowButtonLayout.apply(windowButtonPlacement, to: window)
    }

    /// Куда ставить «светофор»: по центру верхней панели вкладок или шапки боковой панели.
    private var windowButtonPlacement: WindowButtonLayout.Placement? {
        guard tabGroupsEnabled, !isFullScreen, !isCompact else { return nil }
        let glass = AircraftTheme.liquidGlass && !tabManager.isIncognito
        switch tabPosition {
        case "top":
            guard !tabBarHidden || hoverRevealed || showSearchModal else { return nil }
            let inset: CGFloat = glass ? 5 : 0
            return .init(barHeight: inset * 2 + 42 * tabScale, leading: inset + 12)
        case "left":
            guard !tabBarHidden || hoverRevealed || showSearchModal else { return nil }
            let inset: CGFloat = glass ? 8 : 0
            return .init(barHeight: inset * 2 + 38 * tabScale, leading: inset + 12)
        default:
            return nil
        }
    }

    private func setWindowButtonsHidden(_ hidden: Bool) {
        // В полноэкранном режиме `standardWindowButton` находит кнопки на нашей панели, не трогаем их.
        guard let window = hostWindow.window, !window.styleMask.contains(.fullScreen) else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.isHidden != hidden else { continue }
            button.isHidden = hidden
        }
    }

    /// Раз в 50 мс смотрим, где курсор относительно окна: у края — показываем панель,
    /// ушёл с панели — прячем с небольшой задержкой.
    private func checkEdgeHover() {
        guard tabGroupsEnabled, tabBarHidden, !showSearchModal,
              ["top", "left", "right"].contains(tabPosition),
              let window = hostWindow.window, window.isKeyWindow, window.isVisible,
              window.frame.width >= 600 else {
            if hoverRevealed && !showSearchModal { setHoverReveal(false) }
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let edge: CGFloat = 8      // ширина «горячей зоны» внутри окна
        let outside: CGFloat = 4   // небольшой запас за краем окна
        let insideX = mouse.x >= frame.minX - outside && mouse.x <= frame.maxX + outside
        let insideY = mouse.y >= frame.minY - outside && mouse.y <= frame.maxY + outside
        let panelWidth = CGFloat(SidebarMetrics.clamp(sidebarWidth))
        let barHeight = CGFloat(42 * tabScale)

        let atEdge: Bool
        let overPanel: Bool
        switch tabPosition {
        case "top":
            atEdge = insideX && mouse.y >= frame.maxY - edge && mouse.y <= frame.maxY + outside
            overPanel = insideX && mouse.y >= frame.maxY - barHeight - 6 && mouse.y <= frame.maxY + outside
        case "right":
            atEdge = insideY && mouse.x >= frame.maxX - edge && mouse.x <= frame.maxX + outside
            overPanel = insideY && mouse.x >= frame.maxX - panelWidth - 6 && mouse.x <= frame.maxX + outside
        default:
            atEdge = insideY && mouse.x <= frame.minX + edge && mouse.x >= frame.minX - outside
            overPanel = insideY && mouse.x <= frame.minX + panelWidth + 6 && mouse.x >= frame.minX - outside
        }

        if atEdge || (hoverRevealed && overPanel) {
            setHoverReveal(true)
        } else if hoverRevealed {
            setHoverReveal(false)
        }
    }

    private func setHoverReveal(_ reveal: Bool) {
        if reveal {
            hoverHideTask?.cancel()
            hoverHideTask = nil
            guard !hoverRevealed else { return }
            withAnimation(.easeOut(duration: 0.18)) { hoverRevealed = true }
        } else {
            // Уже ждём скрытия — не перезапускаем таймер на каждом тике.
            guard hoverHideTask == nil else { return }
            // Небольшая задержка, чтобы панель не мигала при случайном выходе курсора.
            hoverHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { hoverRevealed = false }
                hoverHideTask = nil
            }
        }
    }

    private func configureResourceTimer(enabled: Bool) {
        resourceTimerConnection?.cancel()
        resourceTimerConnection = nil
        guard enabled else { return }
        memoryBytes = currentResidentMemory()
        resourceTimerConnection = AnyCancellable(resourceTimer.connect())
    }

    private func currentResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private struct MobileSidebarView: View {
    @Binding var sidebarVisible: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ряд значков: место под кнопки окна, навигация, настройки, закрыть.
            HStack(spacing: 4) {
                Color.clear.frame(width: 70)
                NavigationArrows(fontSize: 12 * tabScale)
                ReloadPageButton(fontSize: 12 * tabScale)
                Spacer()
                ChromeIconButton(symbol: "gearshape", help: L10n("Settings (⌘,)"), fontSize: 12 * tabScale) {
                    NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                }
                ChromeIconButton(symbol: "xmark", help: L10n("Hide tabs"), fontSize: 12 * tabScale) {
                    sidebarVisible = false
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)

            // Адрес — под рядом значков.
            MobileAddressField(fontSize: 14 * tabScale)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    FavoritesGrid()
                    TabTreeList(style: .mobile)
                    MobileNewTabButton(fontSize: 13 * tabScale)
                }
                .padding(.horizontal, 12)
            }
            ProfileBar()
        }
        .glassPanel()
        .ignoresSafeArea()
    }
}

/// Нижняя строка узкого окна: назад/вперёд, адрес с заголовком страницы, вкладки.
private struct MobileBottomBar: View {
    @Binding var tabsOpen: Bool
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        HStack(spacing: 6) {
            NavigationArrows(fontSize: 13)
            Button {
                NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: tabManager.hostWindow ?? NSApp.keyWindow)
            } label: {
                HStack(spacing: 6) {
                    if let tab = tabManager.activeTab, tab.url != nil {
                        FaviconImage(url: tab.url, image: tab.favicon, size: 14)
                        Text(tab.url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? tab.title)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "magnifyingglass")
                        Text(L10n("Search or address")).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L10n("Address or search (⌘L)"))
            Button { tabsOpen.toggle() } label: {
                Text("\(tabManager.tabs.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary, lineWidth: 1.6))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n("Tabs (⌃⌥S)"))
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .glassIfEnabled(Capsule(), themeTint: true, interactive: true)
        .padding(.horizontal, AircraftTheme.liquidGlass ? 8 : 0)
        .padding(.bottom, AircraftTheme.liquidGlass ? 6 : 0)
    }
}

private struct SidebarResizeHandle: View {
    let width: Double
    let sidebarOnRight: Bool
    let onCommit: (Double) -> Void
    @State private var startingWidth: Double?
    @State private var pendingWidth: Double?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(isHovering ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18))
                .frame(width: isHovering ? 2 : 1)
            if isHovering {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(4)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
            if let pendingWidth {
                Text("\(Int(pendingWidth))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .offset(x: sidebarOnRight ? -28 : 28)
            }
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startingWidth == nil { startingWidth = width }
                    let direction = sidebarOnRight ? -1.0 : 1.0
                    pendingWidth = SidebarMetrics.clamp((startingWidth ?? width) + value.translation.width * direction)
                }
                .onEnded { _ in
                    let committedWidth = pendingWidth ?? width
                    startingWidth = nil
                    pendingWidth = nil
                    onCommit(committedWidth)
                }
        )
    }
}

public struct SingleTabHeader: View {
    @Binding public var showSearchModal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var isHoveringTitle = false
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    public var body: some View {
        ZStack {
            ChromeBackground()

            if let tab = tabManager.activeTab {
                VStack(spacing: 1) {
                    Text(tab.title.isEmpty ? L10n("Title") : tab.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if isHoveringTitle {
                        Text(tab.url?.absoluteString ?? "")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: 260)
                .contentShape(Rectangle())
                .onHover { isHoveringTitle = $0 }
                .onTapGesture {
                    if let url = tab.url?.absoluteString {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                .help(L10n("Click to copy URL"))
            }

            HStack {
                // Keep clear titlebar space for the traffic lights while keeping
                // Settings adjacent to them, rather than in the tab strip.
                Color.clear.frame(width: 94)
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11 * tabScale, weight: .medium))
                        .frame(width: 28 * tabScale, height: 28 * tabScale)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n("Settings"))
                Spacer()
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }
}

// MARK: - Resource HUD

public struct ResourceHUDView: View {
    public let memoryBytes: UInt64
    public let warnAtLimit: Bool
    public let limitMB: Double
    public let tabCount: Int

    private var isOverLimit: Bool { warnAtLimit && Double(memoryBytes) >= limitMB * 1_024 * 1_024 }
    private var memoryUsage: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(L10n("App memory: %1$@", "\(memoryUsage)"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer()
            Text(isOverLimit ? L10n("Over %1$@ MB limit", "\(Int(limitMB))") : L10n("Tabs: %1$@", "\(tabCount)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOverLimit ? .red : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .cornerRadius(8)
        .padding(10)
    }
}

// MARK: - Top/Bottom Navigation Bar (Top and Bottom Bars)

public struct TopBarView: View {
    @Binding public var showSearchModal: Bool
    public var reservesWindowControls: Bool = true
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    public var body: some View {
        HStack(spacing: 0) {
            if reservesWindowControls {
                // Место под кнопки управления окном (закрыть/свернуть/развернуть);
                // в полноэкранном режиме кнопки свои, прямо на панели.
                WindowControlsSlot(width: 80, height: 42 * tabScale)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 3) {
                        ForEach(TopBarItem.items(for: tabManager)) { item in
                            switch item {
                            case .folder(let folder):
                                TopBarFolderChip(folder: folder)
                                    .id(folder.id)
                            case .tiles(let tiles):
                                TopBarTilesChip(tiles: tiles)
                                    .id(item.id)
                            case .tab(let tab, let groupColor):
                                if tab.isPinned {
                                    PinnedTabStripItem(tab: tab, isActive: tab.id == tabManager.activeTabID)
                                        .frame(width: 46 * tabScale)
                                        .padding(.vertical, 7 * tabScale)
                                        .id(tab.id)
                                        .transition(.tabClose(edge: .top))
                                } else {
                                    TabStripItem(tab: tab, showsURL: false, isActive: tab.id == tabManager.activeTabID)
                                        .frame(width: 170 * tabScale)
                                        .padding(.vertical, 7 * tabScale)
                                        .overlay(alignment: .bottom) {
                                            if let groupColor {
                                                Capsule().fill(groupColor).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 3)
                                            }
                                        }
                                        .id(tab.id)
                                        .transition(.tabClose(edge: .top))
                                }
                            }
                        }

                        // «Новая вкладка» сразу после вкладок, как в боковой панели.
                        NewItemMenu(fontSize: 11 * tabScale, clickCreatesTab: true)
                            .padding(.horizontal, 4)
                    }
                    .animation(.tabList, value: tabManager.tree)
                    .padding(.horizontal, 4)
                }
                .onChange(of: tabManager.activeTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Кнопки из настроек и профиль — как внизу боковой панели.
            PanelButtonsRow(compactProfile: true)
                .padding(.horizontal, 8)
        }
        .frame(height: 42 * tabScale)
        .background(WindowDragArea())
        .glassPanel(cornerRadius: 14, inset: 5)
    }
}

private struct PinnedTabStripItem: View {
    let tab: TabModel
    let isActive: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 1.0
    @State private var copied = false

    var body: some View {
        Button { isActive ? copyURL() : tabManager.selectTab(id: tab.id) } label: {
            HStack(spacing: 4) {
                Group {
                if copied {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    FaviconImage(url: tab.url ?? tab.pinnedURL, image: tab.favicon, size: 14 * tabScale)
                }
                }
                .frame(width: 14 * tabScale, height: 14 * tabScale)
                Image(systemName: "pin.fill")
                    .font(.system(size: 7 * tabScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrowserDesign.Surface.tab(active: isActive, hovered: false))
            .clipShape(BrowserDesign.Shape.row)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .overlay(alignment: .topTrailing) {
            TabStatusIcons(tab: tab, fontSize: 7 * tabScale).padding(2)
        }
        .draggable(TabDragPayload.encode(tab.id))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, onto: tab.id, intoFolder: false)
        }
        .contextMenu { TabContextMenu(tab: tab) }
    }

    private func copyURL() {
        guard let value = tab.url?.absoluteString else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private struct TabStripItem: View {
    let tab: TabModel
    let showsURL: Bool
    let isActive: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var isHovering = false
    @State private var copied = false
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            if copied {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .frame(width: 14 * tabScale, height: 14 * tabScale)
            } else {
                TabFavicon(tab: tab, copied: false, size: 14 * tabScale)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title.isEmpty ? L10n("Title") : tab.title)
                    .font(BrowserDesign.TypeRole.title(scale: tabScale, emphasized: isActive))
                    .lineLimit(1)
                if showsURL {
                    Text(tab.url?.host ?? "")
                        .font(BrowserDesign.TypeRole.detail(scale: tabScale))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TabStatusIcons(tab: tab, fontSize: 9 * tabScale)
            if isActive || isHovering {
                Button { tabManager.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8 * tabScale, weight: .semibold))
                        .frame(width: 20 * tabScale, height: 20 * tabScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n("Close tab"))
            }
        }
        .padding(.horizontal, 10 * tabScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserDesign.Surface.tab(active: isActive, hovered: isHovering))
        .clipShape(BrowserDesign.Shape.row)
        .contentShape(Rectangle())
        .onTapGesture { isActive ? copyURL() : tabManager.selectTab(id: tab.id) }
        .onHover { isHovering = $0 }
        .draggable(TabDragPayload.encode(tab.id)) {
            Text(tab.title).lineLimit(1).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap(TabDragPayload.decode).first else { return false }
            return tabManager.dropNode(id, onto: tab.id, intoFolder: false)
        }
        .contextMenu { TabContextMenu(tab: tab) }
    }

    private func copyURL() {
        guard let value = tab.url?.absoluteString else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Sidebar View

/// Боковая панель в духе Arc: кнопки окна и навигации, карточка адреса с заголовком
/// страницы, плитки избранных, закреплённые и обычные вкладки; внизу — профиль,
/// история с аккаунтами и загрузки.
public struct SidebarView: View {
    let side: String
    /// false — панель не закреплена и выехала при наведении.
    var pinned: Bool = true
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 1.0

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                // Закрепить/скрыть панель, настройки и прочее — в настраиваемом ряду внизу.
                if side == "left" {
                    // Место под кнопки окна («светофор»); в полноэкранном режиме — свои кнопки.
                    WindowControlsSlot(width: 70)
                    Spacer(minLength: 0)
                    NavigationArrows(fontSize: 11 * tabScale)
                    ReloadPageButton(fontSize: 11 * tabScale)
                } else {
                    // Справа кнопки окна нужны только в полноэкранном режиме — в окне они слева.
                    WindowControlsSlot(width: 70, onlyInFullScreen: true)
                    NavigationArrows(fontSize: 11 * tabScale)
                    ReloadPageButton(fontSize: 11 * tabScale)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 38 * tabScale)
            .background(WindowDragArea())

            AddressCard()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            // Плитки, закреплённые, папки, группы и вкладки; перетаскиваются мышью.
            ScrollView {
                VStack(spacing: 4) {
                    FavoritesGrid()
                    TabTreeList(style: .sidebar, side: side)
                    NewTabButton(title: L10n("New Tab"), fontSize: 12 * tabScale)
                }
                .padding(.top, 2)
                .padding(.horizontal, 8)
            }
            .contextMenu {
                Button(L10n("New folder")) { tabManager.createFolder() }
            }

            ProfileBar()
        }
        .glassPanel()
    }
}

private struct ReloadPageButton: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        ChromeIconButton(symbol: tabManager.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise",
                         help: tabManager.activeTab?.isLoading == true ? L10n("Stop (⌘.)") : L10n("Reload page (⌘R)"),
                         fontSize: fontSize) {
            tabManager.reloadActiveTab()
        }
        .disabled(tabManager.activeTab?.url == nil)
        .opacity(tabManager.activeTab?.url == nil ? 0.35 : 1)
    }
}

private struct CurrentURLLabel: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var copied = false

    var body: some View {
        HStack(spacing: 5) {
            Text(tabManager.activeTab?.url?.absoluteString ?? L10n("New Tab"))
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { copyURL() }
            Button {
                copyURL()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: fontSize * 0.9, weight: .medium))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(tabManager.activeTab?.url == nil)
            .help(L10n("Copy URL"))
        }
        .foregroundColor(.secondary)
    }

    private func copyURL() {
        guard let value = tabManager.activeTab?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private struct NewTabButton: View {
    let title: String
    let fontSize: CGFloat

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .createHomeTab, object: NSApp.keyWindow)
        } label: {
            Label(title, systemImage: "plus")
                .font(.system(size: fontSize, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 38)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }
}

private struct MobileNewTabButton: View {
    let fontSize: CGFloat
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .createHomeTabWithoutSpotlight, object: NSApp.keyWindow)
        } label: {
            Label(L10n("New Tab"), systemImage: "plus")
                .font(.system(size: fontSize, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 38)
        }
        .buttonStyle(.plain).foregroundColor(.secondary)
    }
}

private struct MobileAddressField: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var value = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n("Search or URL"), text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .onSubmit { guard !value.isEmpty else { return }; tabManager.navigateActiveTab(to: value) }
            Button { copyURL() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
                .buttonStyle(.plain).disabled(tabManager.activeTab?.url == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(BrowserDesign.Surface.field, in: BrowserDesign.Shape.field)
        .onAppear { value = tabManager.activeTab?.url?.absoluteString ?? "" }
        .onChange(of: tabManager.activeTabID) { _, _ in value = tabManager.activeTab?.url?.absoluteString ?? "" }
    }

    private func copyURL() {
        guard let url = tabManager.activeTab?.url?.absoluteString else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// Слабая ссылка на окно, в котором находится view.
final class HostWindowRef {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let ref: HostWindowRef

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { ref.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { ref.window = nsView.window }
    }
}

private struct WindowTabbingDisabler: NSViewRepresentable {
    @Binding var windowNumber: Int?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            windowNumber = view.window?.windowNumber
            disableTabbing(for: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            windowNumber = nsView.window?.windowNumber
            disableTabbing(for: nsView.window)
        }
    }

    private func disableTabbing(for window: NSWindow?) {
        guard let window else { return }
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if !AircraftTheme.liquidGlass { window.backgroundColor = .windowBackgroundColor }
        window.styleMask.insert(.fullSizeContentView)
    }
}

// MARK: - Reusable Components

public struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
            }
            content
        }
    }
}

public struct CapsuleButton: View {
    let text: String
    let isActive: Bool
    var color: Color = .black
    var action: () -> Void

    public init(text: String, isActive: Bool, color: Color = .primary, action: @escaping () -> Void = {}) {
        self.text = text
        self.isActive = isActive
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundColor(isActive ? Color(NSColor.windowBackgroundColor) : .primary)
                .background(isActive ? color : Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: isActive ? 0 : 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Адреса URL-системы для запроса — в том же виде, что подсказки Spotlight.
@MainActor
enum URLSystemTargets {
    static func suggestions(query: String, prefixes: [String]) -> [SpotlightSuggestion] {
        prefixes.compactMap { prefix in
            guard let target = URLRouter.prefixedTarget(query: query, prefix: prefix) else { return nil }
            let url = URL(string: target)
            return SpotlightSuggestion(kind: .direct(target), title: url.map(SpotlightSuggestionEngine.shortURL) ?? target,
                                       subtitle: L10n("URL shortcut · %1$@", "\(prefix)"), symbol: "link", url: url)
        }
    }
}

private struct URLSystemSuggestions: View {
    let query: String
    let prefixes: [String]
    let selectedIndex: Int
    let onSelect: (String) -> Void

    var body: some View {
        let items = URLSystemTargets.suggestions(query: query, prefixes: prefixes)
        if items.isEmpty {
            Text(L10n("Add a shortcut in Settings → Search and URLs"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            SpotlightSuggestionList(items: items, selectedIndex: selectedIndex) { item in
                if case .direct(let target) = item.kind { onSelect(target) }
            }
        }
    }
}

// MARK: - Search Modal View

/// Открыт ли Spotlight: пока открыт, ⌥← / ⌥→ двигают курсор в поле, а не переключают вкладки.
@MainActor
enum SpotlightPresence {
    static var openCount = 0
    static var isOpen: Bool { openCount > 0 }
}

/// Spotlight в духе Arc: большое поле по центру окна, до пяти подсказок с названиями
/// страниц (остальные — прокруткой). Tab переключает URL-систему: она показывается
/// меткой в поле, а адреса — такими же строками, как подсказки.
public struct SearchModalView: View {
    @Binding public var isPresented: Bool
    @Binding public var currentState: ViewState
    @State private var query = ""
    @State private var urlSystemActive = false
    @State private var selectedURLSystem = 0
    @State private var suggestions = SpotlightSuggestionEngine()
    @State private var selectedSuggestion = -1
    /// Подсказки появляются, только когда текст начали менять (а не на подставленном адресе).
    @State private var edited = false
    @State private var containerHeight: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @Environment(TabManager.self) private var tabManager: TabManager
    @FocusState private var isFocused: Bool
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("customURLPrefixesJSON") private var customURLPrefixesJSON: String = "[]"

    private static let fieldHeight: CGFloat = 58

    private var urlPrefixes: [String] {
        URLSystemStore.prefixes(json: customURLPrefixesJSON, legacyPrefix: customURLPrefix)
    }

    /// Поле — на трети высоты окна: под ним остаётся место для подсказок.
    private var fieldTop: CGFloat {
        max(16, containerHeight * 0.28 - Self.fieldHeight / 2)
    }

    private var panelWidth: CGFloat {
        min(720, max(320, containerWidth - 48))
    }

    public init(isPresented: Binding<Bool>, currentState: Binding<ViewState>, initialQuery: String = "") {
        self._isPresented = isPresented
        self._currentState = currentState
        self._query = State(initialValue: initialQuery)
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                field
                if showsList {
                    Divider().opacity(0.6)
                    if urlSystemActive {
                        URLSystemSuggestions(query: query, prefixes: urlPrefixes, selectedIndex: selectedURLSystem) { target in
                            tabManager.navigateActiveTab(to: target)
                            close()
                        }
                    } else {
                        SpotlightSuggestionList(items: visibleSuggestions, selectedIndex: selectedSuggestion) { open($0) }
                    }
                }
                footer
            }
            .glassOr(RoundedRectangle(cornerRadius: 20, style: .continuous), themeTint: true) {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Color(NSColor.windowBackgroundColor).opacity(0.55)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AircraftTheme.liquidGlass ? 20 : 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .floatingShadow(RoundedRectangle(cornerRadius: AircraftTheme.liquidGlass ? 20 : 16, style: .continuous),
                            color: Color.black.opacity(0.28), radius: 30, y: 12)
            .frame(width: panelWidth)
            .padding(.top, fieldTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            containerHeight = $0.height
            containerWidth = $0.width
        }
        .onAppear {
            SpotlightPresence.openCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isFocused = true }
            // Пустое поле (новая вкладка) — сразу недавние вкладки.
            if query.isEmpty {
                edited = true
                suggestions.showRecentTabs(manager: tabManager)
            }
        }
        .onDisappear { SpotlightPresence.openCount = max(0, SpotlightPresence.openCount - 1) }
    }

    private var showsList: Bool {
        urlSystemActive || !visibleSuggestions.isEmpty
    }

    private var field: some View {
        HStack(spacing: 12) {
            if urlSystemActive {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                    Text(selectedPrefixLabel).lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(Color.accentColor))
                .help(L10n("URL shortcuts · Tab to exit · ↑↓ to select"))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            TextField(urlSystemActive ? L10n("Path or query") : L10n("Search or address"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($isFocused)
                .onKeyPress(.tab) {
                    urlSystemActive.toggle()
                    selectedURLSystem = 0
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    moveSelection(press.key == .downArrow ? 1 : -1)
                }
                // ⌃N / ⌃P — как в Emacs и Spotlight macOS.
                .onKeyPress(keys: ["n", "p"]) { press in
                    guard press.modifiers == .control else { return .ignored }
                    return moveSelection(press.key == "n" ? 1 : -1)
                }
                .onExitCommand { isPresented = false }
                .onChange(of: query) { _, value in
                    edited = true
                    suggestions.update(query: value, manager: tabManager)
                }
                .onChange(of: suggestions.items) { _, items in
                    // Автодополнение адреса выбрано сразу: Enter откроет сайт.
                    let hasAutocomplete: Bool = { if case .autocomplete = items.first?.kind { return true }; return false }()
                    if selectedSuggestion > 0, selectedSuggestion < items.count { return }
                    selectedSuggestion = hasAutocomplete ? 0 : -1
                }
                .onSubmit {
                    if !urlSystemActive, visibleSuggestions.indices.contains(selectedSuggestion) {
                        open(visibleSuggestions[selectedSuggestion])
                    } else {
                        processSearch()
                    }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n("action.clear"))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.fieldHeight)
    }

    /// Нижняя строка: навигация по текущей странице и подсказка по клавишам.
    private var footer: some View {
        HStack(spacing: 4) {
            spotlightNavButton("arrow.left", help: L10n("Back (⌘[)"), enabled: tabManager.canGoBack) { tabManager.goBackActiveTab() }
            spotlightNavButton("arrow.right", help: L10n("Forward (⌘])"), enabled: tabManager.canGoForward) { tabManager.goForwardActiveTab() }
            spotlightNavButton("arrow.clockwise", help: L10n("Reload (⌘R)"), enabled: tabManager.activeTab?.url != nil) { tabManager.reloadActiveTab() }
            Spacer()
            Text(urlSystemActive ? L10n("↩ open · ↑↓ select · Tab search") : footerHint)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.primary.opacity(0.035))
    }

    /// ↑↓ по подсказкам по кругу; «−1» — само поле. На подставленном адресе ↓ показывает
    /// недавние вкладки, чтобы переключиться, не стирая адрес.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        if urlSystemActive {
            let count = URLSystemTargets.suggestions(query: query, prefixes: urlPrefixes).count
            guard count > 0 else { return .ignored }
            selectedURLSystem = (selectedURLSystem + delta + count) % count
            return .handled
        }
        if visibleSuggestions.isEmpty, delta > 0 {
            edited = true
            suggestions.showRecentTabs(manager: tabManager)
            selectedSuggestion = suggestions.items.isEmpty ? -1 : 0
            return suggestions.items.isEmpty ? .ignored : .handled
        }
        let count = visibleSuggestions.count
        guard count > 0 else { return .ignored }
        var next = selectedSuggestion + delta
        if next >= count { next = -1 }
        if next < -1 { next = count - 1 }
        selectedSuggestion = next
        return .handled
    }

    /// ⇧↩ — открыть в Split View (если мод разделения экрана установлен).
    private var opensInSplit: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            && tabManager.modCapabilities.contains("splitView")
            && tabManager.activeTab?.url != nil
    }

    private var visibleSuggestions: [SpotlightSuggestion] {
        edited ? suggestions.items : []
    }

    private func close() {
        isPresented = false
        currentState = .workspace
    }

    private var footerHint: String {
        tabManager.modCapabilities.contains("splitView")
            ? L10n("↩ open · ⌘↩ new tab · ⇧↩ split · ↑↓ select · Tab shortcuts")
            : L10n("↩ open · ⌘↩ new tab · ↑↓ select · Tab shortcuts")
    }

    /// Выбранная подсказка: вкладка — переключиться, остальное — открыть
    /// (⌘↩ — в новой вкладке, ⇧↩ — рядом, в Split View).
    private func open(_ suggestion: SpotlightSuggestion) {
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true && tabManager.activeTab?.url != nil
        let split = opensInSplit
        func go(_ target: String) {
            if split {
                tabManager.openInSplit(url: Self.resolve(target))
            } else if newTab {
                let url = URLRouter.navigationTarget(input: target, searchTemplate: SearchEngineOption.queryTemplate(
                    for: UserDefaults.standard.string(forKey: "searchEngine") ?? "duckduckgo",
                    customURL: UserDefaults.standard.string(forKey: "customSearchURL") ?? "")).flatMap(URL.init(string:))
                tabManager.createNewTab(url: url, selectNewTab: true, afterTabID: tabManager.activeTabID)
            } else {
                tabManager.navigateActiveTab(to: target)
            }
        }
        switch suggestion.kind {
        case .autocomplete(let host): go("https://" + host)
        case .tab(let id) where split:
            tabManager.activateSplit(with: id)
        case .tab(let id):
            // Пустая вкладка, с которой переключились, не нужна.
            if let empty = tabManager.activeTab, empty.url == nil {
                tabManager.selectTab(id: id)
                tabManager.closeTab(id: empty.id, remember: false)
            } else {
                tabManager.selectTab(id: id)
            }
        case .bookmark(let url), .history(let url): go(url.absoluteString)
        case .archive(let id):
            if let entry = tabManager.archive?.entries.first(where: { $0.id == id }) { tabManager.restoreFromArchive(entry) }
        case .search(let text), .direct(let text): go(text)
        }
        close()
    }

    private func processSearch() {
        var target = query
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if (urlSystemActive || flags.contains(.option)), !urlPrefixes.isEmpty,
           let prefixed = URLRouter.prefixedTarget(query: query, prefix: urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)]) {
            target = prefixed
        }
        if !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if opensInSplit {
                tabManager.openInSplit(url: Self.resolve(target))
            } else if flags.contains(.command), tabManager.activeTab?.url != nil {
                let url = URLRouter.navigationTarget(input: target, searchTemplate: SearchEngineOption.queryTemplate(
                    for: UserDefaults.standard.string(forKey: "searchEngine") ?? "duckduckgo",
                    customURL: UserDefaults.standard.string(forKey: "customSearchURL") ?? "")).flatMap(URL.init(string:))
                tabManager.createNewTab(url: url, selectNewTab: true, afterTabID: tabManager.activeTabID)
            } else {
                tabManager.navigateActiveTab(to: target)
            }
        }
        close()
    }

    /// Адрес для ввода: URL как есть, остальное — поиск выбранным поисковиком.
    private static func resolve(_ target: String) -> URL? {
        URLRouter.navigationTarget(input: target, searchTemplate: SearchEngineOption.queryTemplate(
            for: UserDefaults.standard.string(forKey: "searchEngine") ?? "duckduckgo",
            customURL: UserDefaults.standard.string(forKey: "customSearchURL") ?? "")).flatMap(URL.init(string:))
    }

    /// Кнопка навигации в Spotlight: выполняет действие на активной вкладке и закрывает Spotlight.
    private func spotlightNavButton(_ systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        ChromeIconButton(symbol: systemName, help: help, fontSize: 11) {
            action()
            close()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private var selectedPrefixLabel: String {
        guard !urlPrefixes.isEmpty else { return L10n("Not configured") }
        return urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)]
            .replacingOccurrences(of: "https://", with: "") + "/…"
    }
}

private extension Color {
    init(aircraftHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let number = UInt64(hex, radix: 16) else { self = .clear; return }
        let rgba = hex.count == 6 ? (number << 8) | 0xFF : number
        self.init(.sRGB,
                  red: Double((rgba >> 24) & 0xFF) / 255,
                  green: Double((rgba >> 16) & 0xFF) / 255,
                  blue: Double((rgba >> 8) & 0xFF) / 255,
                  opacity: Double(rgba & 0xFF) / 255)
    }
}

private extension NSColor {
    var aircraftHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255), Int(color.alphaComponent * 255))
    }
}
