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
    @State private var sidebarVisible: Bool = true
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
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var windowWidth: CGFloat = 1000

    public init() {}

    public var body: some View {
        moreHandlers(styledContent
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { notification in
            guard isTargetWindow(notification) else { return }
            showSearchModal = false
            currentState = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLocation)) { notification in
            guard isTargetWindow(notification) else { return }
            currentState = .workspace
            presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { notification in
            guard isTargetWindow(notification) else { return }
            sidebarVisible.toggle()
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
        })
    }

    /// Окно с общим оформлением (размер, фон, тема).
    private var styledContent: some View {
        windowContent
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
            .onChange(of: tabManager.activeTabID) { _, _ in refreshSpotlightForActiveTab() }
            .frame(minWidth: 360, minHeight: 520)
            .ignoresSafeArea(.container, edges: .top)
            .background(Color(NSColor.windowBackgroundColor))
            .background(WindowTabbingDisabler(windowNumber: $windowNumber))
            .fontWeight(.medium)
            .preferredColorScheme(browserTheme == "dark" ? .dark : (browserTheme == "light" ? .light : nil))
    }

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
                case .settings:
                    SettingsView(currentState: $currentState)
                case .workspace:
                    WorkspaceView(
                        sidebarVisible: $sidebarVisible,
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

    /// При переключении вкладки в открытом Spotlight подставляем её URL.
    private func refreshSpotlightForActiveTab() {
        guard showSearchModal else { return }
        presentSpotlight(query: tabManager.activeTab?.url?.absoluteString ?? "")
    }

    /// Место, которое занимает панель вкладок; Spotlight его не закрывает.
    private var spotlightTabInsets: EdgeInsets {
        guard currentState == .workspace, tabGroupsEnabled, windowWidth >= 600 else { return EdgeInsets() }
        let sidebar = min(max(sidebarWidth, 140), 360)
        let bar = 42 * tabScale
        switch tabPosition {
        case "top": return EdgeInsets(top: bar, leading: 0, bottom: 0, trailing: 0)
        case "bottom": return EdgeInsets(top: 0, leading: 0, bottom: bar, trailing: 0)
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
                            .foregroundColor(urlSystemActive ? .white : .gray)
                        TextField(urlSystemActive ? selectedPrefixLabel : "Поиск или URL · Tab — url-система", text: $searchInput)
                            .textFieldStyle(.plain)
                            .foregroundColor(urlSystemActive ? .white : .primary)
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
                    .background(urlSystemActive ? Color.primary : Color(NSColor.controlBackgroundColor))

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
                Text("настрой →")
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
        guard !urlPrefixes.isEmpty else { return "URL-система не настроена" }
        return urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)] + "/…"
    }
}

// MARK: - Settings View

public struct SettingsView: View {
    @Binding public var currentState: ViewState
    @Environment(TabManager.self) private var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("tabGroupsEnabled") private var tabGroupsEnabled: Bool = false
    @AppStorage("tabPosition") private var tabPosition: String = "left"
    @AppStorage("browserTheme") private var browserTheme: String = "system"
    @AppStorage("tabScale") private var tabScale: Double = 0.9
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

    @State private var customScripts: [String] = []
    @State private var editableURLPrefix: String = ""
    @State private var editingURLPrefixIndex: Int?
    @State private var urlValidationMessage: String?
    @State private var searchURLValidationMessage: String?
    @State private var searchTemplatePreset: String = "duckduckgo"
    @State private var modBackgroundColor = Color.clear

    private var urlPrefixes: [String] {
        URLSystemStore.prefixes(json: customURLPrefixesJSON, legacyPrefix: customURLPrefix)
    }

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
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { currentState = .workspace }
        .onAppear {
            loadCustomModifications()
            modBackgroundColor = Color(aircraftHex: UserDefaults.standard.string(forKey: "aircraftModBackgroundHex") ?? "#00000000")
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
            Text("Настройки")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ForEach(SettingsPane.allCases) { pane in
                SettingsSidebarRow(pane: pane, isSelected: selectedSection == pane) {
                    selectedSection = pane
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

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedSection.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(selectedSection.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            Text(selectedSection.title)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("Готово") { currentState = .workspace }
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
        case .general: generalPane
        case .tabs: tabsPane
        case .search: searchPane
        case .resources: resourcesPane
        case .mods: modsPane
        case .shortcuts: shortcutsPane
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Основные

    private var generalPane: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $browserTheme) {
                    Text("Системная").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
                .pickerStyle(.segmented)
                if tabManager.modCapabilities.contains("themes") {
                    ColorPicker("Фон сайтов", selection: $modBackgroundColor, supportsOpacity: true)
                        .onChange(of: modBackgroundColor) { _, value in selectModBackground(value) }
                }
            }
            Section("Загрузки") {
                LabeledContent("Папка для загрузок") {
                    HStack(spacing: 8) {
                        Text(downloadFolderPath.isEmpty ? "Загрузки" : URL(fileURLWithPath: downloadFolderPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Выбрать…") { chooseDownloadFolder() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Вкладки

    private var tabsPane: some View {
        Form {
            Section {
                Toggle("Панель вкладок", isOn: $tabGroupsEnabled)
            } footer: {
                Text("Если выключено, показывается только текущая вкладка.")
                    .foregroundStyle(.secondary)
            }
            Section("Расположение") {
                Picker("Где показывать вкладки", selection: $tabPosition) {
                    Text("Слева").tag("left")
                    Text("Справа").tag("right")
                    Text("Сверху").tag("top")
                    Text("Снизу").tag("bottom")
                }
                .pickerStyle(.segmented)
                LabeledContent("Размер панели") {
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
            Section("Скрытая панель") {
                LabeledContent("Показать или скрыть", value: "⌃⌥S")
                Text("Скрытая панель слева, справа или сверху сама выезжает, когда курсор подходит к краю окна, и видна, пока открыт Spotlight.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .disabled(!tabGroupsEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Поиск и URL

    private var searchPane: some View {
        Form {
            Section {
                Picker("Поисковая система", selection: $searchTemplatePreset) {
                    ForEach(SearchEngineOption.popular) { engine in
                        Text(engine.title).tag(engine.id)
                    }
                    Divider()
                    Text("Свой шаблон").tag("custom")
                }
                .onChange(of: searchTemplatePreset) { _, preset in
                    guard let engine = SearchEngineOption.popular.first(where: { $0.id == preset }) else { return }
                    customSearchURL = engine.queryURL
                    searchEngine = engine.id
                    searchURLValidationMessage = nil
                }
                HStack(spacing: 8) {
                    TextField("Шаблон", text: $customSearchURL, prompt: Text("https://search.example/?q={query}"))
                        .onSubmit { selectCustomSearch() }
                    Button("Сохранить") { selectCustomSearch() }
                }
                if let searchURLValidationMessage {
                    Text(searchURLValidationMessage).foregroundStyle(.red).font(.system(size: 12))
                }
            } header: {
                Text("Поиск")
            } footer: {
                Text("В шаблоне используйте {query}, %s или %@ на месте запроса.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Домен", text: $editableURLPrefix, prompt: Text("например, github.io"))
                        .onSubmit { saveURLPrefix() }
                    Button(editingURLPrefixIndex == nil ? "Добавить" : "Сохранить") { saveURLPrefix() }
                    if editingURLPrefixIndex != nil {
                        Button("Отмена") { cancelURLPrefixEditing() }
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
                            .help("Редактировать")
                        Button { removeURLPrefix(at: index) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Удалить")
                    }
                }
            } header: {
                Text("URL-системы")
            } footer: {
                Text("В Spotlight нажмите Tab, чтобы открыть адрес внутри выбранной системы.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Ресурсы

    private var resourcesPane: some View {
        Form {
            Section("Мониторинг") {
                Toggle("Показывать строку потребления памяти", isOn: $resourceMonitoring)
                Picker("Предупреждать", selection: $resourceLimitAlert) {
                    Text("Никогда").tag("none")
                    Text("При превышении лимита").tag("limit")
                }
                LabeledContent("Лимит памяти") {
                    HStack(spacing: 10) {
                        Slider(value: $resourceLimitMB, in: 128...2048, step: 64)
                            .frame(width: 180)
                        Text("\(Int(resourceLimitMB)) МБ")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(resourceLimitAlert != "limit")
            }
            Section("Сброс ресурсов") {
                Picker("Что сбрасывать", selection: $resourceResetScope) {
                    Text("Фоновые вкладки").tag("backgroundTabs")
                    Text("Все вкладки из памяти").tag("allTabs")
                    Text("Веб-кэш и данные сайтов").tag("webCache")
                }
                Picker("Сочетание клавиш", selection: $resourceResetShortcut) {
                    Text("⌃⌥R").tag("control-option-r")
                    Text("⌃⌥⇧R").tag("control-option-shift-r")
                    Text("⌘⌥⇧R").tag("command-option-shift-r")
                }
                HStack {
                    Spacer()
                    Button("Сбросить сейчас") { tabManager.resetResources(scope: resourceResetScope) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Модификации

    private var modsPane: some View {
        Form {
            Section {
                ForEach(BundledMod.all) { mod in
                    let installedFile = customScripts.first { ModCatalog.family(for: $0) == mod.id }
                    HStack(spacing: 12) {
                        Image(systemName: mod.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(mod.tint.gradient, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.title)
                            Text(mod.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let installedFile {
                            Button("Удалить", role: .destructive) { removeModification(named: installedFile) }
                        } else {
                            Button("Установить") { installBundledModification(named: mod.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Встроенные")
            }

            Section {
                let ownScripts = customScripts.filter { ModCatalog.family(for: $0) == nil }
                if ownScripts.isEmpty {
                    Text("Своих модификаций пока нет.")
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
                            .help("Удалить в корзину")
                    }
                }
                HStack {
                    Button("Добавить файл…") { openScriptPanel() }
                    Spacer()
                    Button("Гайд по SDK") { openModGuide() }
                    Button("Открыть папку") { openModsFolder() }
                }
            } header: {
                Text("Свои модификации")
            } footer: {
                Text("Файлы .js и .css подключаются ко всем страницам.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Сочетания клавиш

    private var shortcutsPane: some View {
        Form {
            Section("Вкладки") {
                LabeledContent("Новая вкладка", value: "⌘T  ·  ⌘N")
                LabeledContent("Закрыть вкладку", value: "⌘W")
                LabeledContent("Вкладка по номеру", value: "⌘1 … ⌘8")
                LabeledContent("Последняя вкладка", value: "⌘9")
                LabeledContent("Показать/скрыть панель вкладок", value: "⌃⌥S")
            }
            Section("Навигация") {
                LabeledContent("Spotlight с адресом вкладки", value: "⌘⇧ (нажать и отпустить)")
                LabeledContent("Адрес или поиск", value: "⌘L")
                LabeledContent("Назад / вперёд", value: "⌘[  ·  ⌘]")
                LabeledContent("Обновить", value: "⌘R")
            }
            Section("Окно") {
                LabeledContent("Новое окно", value: "⌘⇧N")
                LabeledContent("Настройки", value: "⌘,")
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
                        tabManager.reloadCustomModifications()
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

    private func selectModBackground(_ color: Color) {
        let value = NSColor(color).aircraftHex
        UserDefaults.standard.set(value, forKey: "aircraftModBackgroundHex")
        ScriptBridge.setStoredValue(value, for: "themes.background")
        tabManager.reloadCustomModifications()
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
            tabManager.reloadCustomModifications()
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
            urlValidationMessage = "Нужен домен или URL без пробелов"
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
            searchURLValidationMessage = "Нужен полный URL, например https://site/search?q={query}"
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
            tabManager.reloadCustomModifications()
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Settings helpers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tabs, search, resources, mods, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Основные"
        case .tabs: "Вкладки"
        case .search: "Поиск и URL"
        case .resources: "Ресурсы"
        case .mods: "Модификации"
        case .shortcuts: "Сочетания клавиш"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .tabs: "square.on.square"
        case .search: "magnifyingglass"
        case .resources: "memorychip.fill"
        case .mods: "puzzlepiece.extension.fill"
        case .shortcuts: "keyboard.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .tabs: .blue
        case .search: .orange
        case .resources: .green
        case .mods: .purple
        case .shortcuts: .indigo
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
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                Text(pane.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.06 : 0))
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
    let tint: Color

    static let all: [BundledMod] = [
        .init(id: "aircraft-tab-history-accounts", title: "История и аккаунты",
              subtitle: "История переходов и сайты со входом · ⌘Y", icon: "clock.arrow.circlepath", tint: .blue),
        .init(id: "aircraft-split-view", title: "Разделение экрана",
              subtitle: "Две вкладки рядом в одном окне", icon: "rectangle.split.2x1", tint: .teal),
        .init(id: "aircraft-color-themes", title: "Цветные темы",
              subtitle: "Свой цвет фона сайтов", icon: "paintpalette.fill", tint: .pink),
        .init(id: "aircraft-devtools-webextensions", title: "Web Inspector + WebExtensions",
              subtitle: "Консоль, журнал fetch и мост chrome.* · ⌘⌥I", icon: "hammer.fill", tint: .gray)
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
                Image(systemName: isFocused ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                Text(tab?.title.isEmpty == false ? tab!.title : "Новая страница")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    ForEach(tabManager.tabs) { candidate in
                        Button {
                            tabManager.focusSplitPane(tabID)
                            tabManager.selectTab(id: candidate.id)
                        } label: {
                            if candidate.id == tabID {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.on.rectangle.angled")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Выбрать открытую страницу")
                Button { tabManager.closeSplitView() } label: {
                    Image(systemName: "rectangle.split.2x1.slash")
                }
                .buttonStyle(.plain)
                .help("Закрыть разделение")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isFocused ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(isFocused ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { tabManager.focusSplitPane(tabID) }
            Divider()
            BrowserPane(tabID: tabID, showSearchModal: $showSearchModal)
        }
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
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if startingRatio == nil { startingRatio = ratio }
                    guard totalWidth > 0 else { return }
                    let minimum = min(0.45, 160 / totalWidth)
                    ratio = min(max((startingRatio ?? ratio) + value.translation.width / totalWidth, minimum), 1 - minimum)
                }
                .onEnded { _ in startingRatio = nil }
        )
        .help("Изменить размеры окон")
    }
}

private struct BrowserPane: View {
    let tabID: UUID?
    @Binding var showSearchModal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        if let tabID, let tab = tabManager.tabs.first(where: { $0.id == tabID }), tab.url != nil {
            WebContainerView(activeWebView: tabManager.webView(for: tabID))
        } else {
            // Новая вкладка без адреса — просто пустая страница.
            Color(NSColor.windowBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WindowPageTopBand: View {
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        Color(tabManager.activeTab?.pageBackgroundColor ?? .windowBackgroundColor)
            .frame(height: 38 * tabScale)
            .overlay(alignment: .bottom) { Divider().opacity(0.35) }
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
    @AppStorage("tabScale") private var tabScale: Double = 0.9

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
            if tabGroupsEnabled && geometry.size.width < 600 && (tabPosition == "left" || tabPosition == "right") {
                ZStack {
                    BrowserContentView(showSearchModal: $showSearchModal)
                    if resourceMonitoring {
                        VStack {
                            Spacer()
                            ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                        }
                    }
                    if sidebarVisible {
                        MobileSidebarView(sidebarVisible: $sidebarVisible)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(10)
                    }
                }
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
                                .safeAreaInset(edge: .top, spacing: 0) { WindowPageTopBand() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                        if sidebarVisible {
                            SidebarResizeHandle(width: sidebarWidth, sidebarOnRight: true) { newWidth in
                                sidebarWidth = newWidth
                            }
                            SidebarView(side: "right")
                                .frame(width: min(max(sidebarWidth, 140), 360))
                        }
                    }
                    .overlay(alignment: .trailing) { hoverRevealLayer(side: "right") }
                } else if tabPosition == "top" {
                    VStack(spacing: 0) {
                        if sidebarVisible {
                            TopBarView(showSearchModal: $showSearchModal, reservesWindowControls: true, showsTabBarToggle: true)
                        }
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                    }
                    .overlay(alignment: .top) { hoverRevealLayer(side: "top") }
                } else if tabPosition == "bottom" {
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
                                .safeAreaInset(edge: .top, spacing: 0) { WindowPageTopBand() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if resourceMonitoring {
                                ResourceHUDView(memoryBytes: memoryBytes, warnAtLimit: resourceLimitAlert == "limit", limitMB: resourceLimitMB, tabCount: tabManager.tabs.count)
                            }
                        }
                        TopBarView(showSearchModal: $showSearchModal, reservesWindowControls: false)
                    }
                } else {
                    // "left"
                    HStack(spacing: 0) {
                        if sidebarVisible {
                            SidebarView(side: "left")
                                .frame(width: min(max(sidebarWidth, 140), 360))
                            SidebarResizeHandle(width: sidebarWidth, sidebarOnRight: false) { newWidth in
                                sidebarWidth = newWidth
                            }
                        }
                        ZStack(alignment: .bottom) {
                            BrowserContentView(showSearchModal: $showSearchModal)
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
        .overlay(alignment: .top) {
            if tabGroupsEnabled && !sidebarVisible && (tabPosition == "left" || tabPosition == "right") {
                HStack {
                    if tabPosition == "right" { Spacer() }
                    Button { sidebarVisible = true } label: {
                        Image(systemName: tabPosition == "right" ? "sidebar.right" : "sidebar.left")
                            .font(.system(size: 11 * tabScale, weight: .medium))
                            .frame(width: 30 * tabScale, height: 30 * tabScale)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Показать панель вкладок")
                    if tabPosition == "left" { Spacer() }
                }
                .padding(8)
            }
        }
        .background(HostWindowReader(ref: hostWindow))
        .onReceive(edgeHoverTimer) { _ in
            checkEdgeHover()
            updateWindowButtons()
        }
        .onDisappear { setWindowButtonsHidden(false) }
        .onChange(of: sidebarVisible) { _, _ in
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
        if !sidebarVisible && side == "top" {
            ZStack(alignment: .top) {
                if hoverRevealed || showSearchModal {
                    TopBarView(showSearchModal: $showSearchModal, reservesWindowControls: true, showsTabBarToggle: true)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.18), value: showSearchModal)
        } else if !sidebarVisible {
            ZStack(alignment: side == "right" ? .trailing : .leading) {
                if hoverRevealed || showSearchModal {
                    SidebarView(side: side)
                        .frame(width: min(max(sidebarWidth, 140), 360))
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: side == "right" ? .leading : .trailing) {
                            Divider()
                        }
                        .shadow(color: .black.opacity(0.18), radius: 12, x: side == "right" ? -2 : 2)
                        .transition(.move(edge: side == "right" ? .trailing : .leading).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: showSearchModal)
        }
    }

    /// Когда верхняя панель вкладок скрыта, прячем и кнопки окна («светофор»);
    /// они появляются вместе с панелью при наведении или в Spotlight.
    private func updateWindowButtons() {
        let hide = tabGroupsEnabled && tabPosition == "top" && !sidebarVisible
            && !hoverRevealed && !showSearchModal
            && (hostWindow.window?.frame.width ?? 0) >= 600
        setWindowButtonsHidden(hide)
    }

    private func setWindowButtonsHidden(_ hidden: Bool) {
        guard let window = hostWindow.window else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.isHidden != hidden else { continue }
            button.isHidden = hidden
        }
    }

    /// Раз в 50 мс смотрим, где курсор относительно окна: у края — показываем панель,
    /// ушёл с панели — прячем с небольшой задержкой.
    private func checkEdgeHover() {
        guard tabGroupsEnabled, !sidebarVisible, !showSearchModal,
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
        let panelWidth = CGFloat(min(max(sidebarWidth, 140), 360))
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
    @AppStorage("tabScale") private var tabScale: Double = 0.9

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MobileAddressField(fontSize: 12 * tabScale)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11 * tabScale, weight: .semibold))
                        .frame(width: 28 * tabScale, height: 28 * tabScale)
                }
                .buttonStyle(.plain)
                .help("Настройки")
                Button { sidebarVisible = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20 * tabScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Скрыть панель вкладок")
            }
            .padding(.leading, 128)
            .padding(.trailing, 12)
            .frame(height: 42 * tabScale)
            .overlay(alignment: .bottom) { Divider().opacity(0.35) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(tabManager.tabs) { tab in
                        MobileTabRow(tab: tab)
                    }
                    ModNavigationItems(horizontal: false)
                    MobileNewTabButton(fontSize: 13 * tabScale)
                }
                .padding(.horizontal, 12)
            }
        }
        .background(.regularMaterial)
        .ignoresSafeArea()
    }
}

private struct MobileTabRow: View {
    let tab: TabModel
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if copied {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if let favicon = tab.favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                } else {
                    Image(systemName: tab.isPinned ? "pin.fill" : "globe")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18 * tabScale, height: 18 * tabScale)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "Новая вкладка" : tab.title)
                    .font(.system(size: 14 * tabScale, weight: .medium))
                    .lineLimit(1)
                if let host = tab.url?.host {
                    Text(host)
                        .font(.system(size: 10 * tabScale))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8 * tabScale))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { tabManager.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9 * tabScale, weight: .semibold))
                    .frame(width: 24 * tabScale, height: 24 * tabScale)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 48 * tabScale)
        .background(tab.id == tabManager.activeTabID ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            if tab.id == tabManager.activeTabID { copyURL() }
            else { tabManager.selectTab(id: tab.id) }
        }
        .contextMenu {
            Button(tab.isPinned ? "Открепить" : "Закрепить") { tabManager.togglePinTab(id: tab.id) }
            if tabManager.modCapabilities.contains("splitView") {
                Button("Разделить экран") { tabManager.activateSplit(with: tab.id) }
            }
            Button("Закрыть") { tabManager.closeTab(id: tab.id) }
        }
    }

    private func copyURL() {
        guard let value = tab.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
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
                    pendingWidth = min(max((startingWidth ?? width) + value.translation.width * direction, 140), 360)
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
    @AppStorage("tabScale") private var tabScale: Double = 0.9

    public var body: some View {
        ZStack {
            VisualEffectView(material: .headerView, blendingMode: .withinWindow)

            if let tab = tabManager.activeTab {
                VStack(spacing: 1) {
                    Text(tab.title.isEmpty ? "Заголовок" : tab.title)
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
                .help("Нажать, чтобы скопировать URL")
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
                .help("Настройки")
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
            Text("RAM приложения: \(memoryUsage)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer()
            Text(isOverLimit ? "лимит \(Int(limitMB)) MB превышен" : "вкладок: \(tabCount)")
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
    public var showsSettingsButton: Bool = true
    /// Кнопка «Показать/скрыть вкладки» — для режима вкладок сверху.
    public var showsTabBarToggle: Bool = false
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9

    public var body: some View {
        HStack(spacing: 0) {
            if reservesWindowControls {
                // Место под кнопки управления окном (закрыть/свернуть/развернуть).
                Color.clear.frame(width: 80, height: 42 * tabScale)
            }

            if showsTabBarToggle {
                Button {
                    NotificationCenter.default.post(name: .toggleSidebar, object: NSApp.keyWindow)
                } label: {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 11 * tabScale, weight: .medium))
                        .frame(width: 32 * tabScale, height: 42 * tabScale)
                }
                .buttonStyle(.plain)
                .help("Показать/скрыть вкладки (⌃⌥S)")
            }

            if showsSettingsButton {
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11 * tabScale, weight: .medium))
                        .frame(width: 32 * tabScale, height: 42 * tabScale)
                }
                .buttonStyle(.plain)
                .help("Настройки")
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 3) {
                        ForEach(tabManager.tabs) { tab in
                            if tab.isPinned {
                                PinnedTabStripItem(tab: tab, isActive: tab.id == tabManager.activeTabID)
                                    .frame(width: 46 * tabScale)
                                    .padding(.vertical, 7 * tabScale)
                                    .id(tab.id)
                            } else {
                                TabStripItem(tab: tab, showsURL: false, isActive: tab.id == tabManager.activeTabID)
                                    .frame(width: 170 * tabScale)
                                    .padding(.vertical, 7 * tabScale)
                                    .id(tab.id)
                            }
                        }

                        ModNavigationItems(horizontal: true)

                        Button(action: {
                            NotificationCenter.default.post(name: .createHomeTab, object: NSApp.keyWindow)
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10 * tabScale, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32 * tabScale, height: 40 * tabScale)
                        }
                        .buttonStyle(.plain)
                    }
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
        }
        .frame(height: 42 * tabScale)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }
}

private struct PinnedTabStripItem: View {
    let tab: TabModel
    let isActive: Bool
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var copied = false

    var body: some View {
        Button { isActive ? copyURL() : tabManager.selectTab(id: tab.id) } label: {
            HStack(spacing: 4) {
                Group {
                if copied {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if let favicon = tab.favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
                }
                .frame(width: 14 * tabScale, height: 14 * tabScale)
                Image(systemName: "pin.fill")
                    .font(.system(size: 7 * tabScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? Color.primary.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .contextMenu {
            Button("Открепить") { tabManager.togglePinTab(id: tab.id) }
            if tabManager.modCapabilities.contains("splitView") {
                Button("Разделить экран") { tabManager.activateSplit(with: tab.id) }
            }
            Button("Закрыть") { tabManager.closeTab(id: tab.id) }
        }
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
    @AppStorage("tabScale") private var tabScale: Double = 0.9

    var body: some View {
        HStack(spacing: 6) {
            if copied {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .frame(width: 14 * tabScale, height: 14 * tabScale)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14 * tabScale, height: 14 * tabScale)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isActive ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.16))
                    .frame(width: 14 * tabScale, height: 14 * tabScale)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title.isEmpty ? "Заголовок" : tab.title)
                    .font(.system(size: 11 * tabScale, weight: .medium))
                    .lineLimit(1)
                if showsURL {
                    Text(tab.url?.host ?? "")
                        .font(.system(size: 8 * tabScale))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isActive || isHovering {
                Button { tabManager.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8 * tabScale, weight: .semibold))
                        .frame(width: 20 * tabScale, height: 20 * tabScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Закрыть вкладку")
            }
        }
        .padding(.horizontal, 10 * tabScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? Color.primary.opacity(0.10) : Color.primary.opacity(isHovering ? 0.04 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { isActive ? copyURL() : tabManager.selectTab(id: tab.id) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(tab.isPinned ? "Открепить" : "Закрепить") { tabManager.togglePinTab(id: tab.id) }
            if tabManager.modCapabilities.contains("splitView") {
                Button("Разделить экран") { tabManager.activateSplit(with: tab.id) }
            }
            Button("Закрыть") { tabManager.closeTab(id: tab.id) }
        }
    }

    private func copyURL() {
        guard let value = tab.url?.absoluteString else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Sidebar View

public struct SidebarView: View {
    let side: String
    @Environment(TabManager.self) private var tabManager: TabManager
    @AppStorage("tabScale") private var tabScale: Double = 0.9
    @State private var copiedTabID: UUID?

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if side == "left" {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 116)
                        Spacer(minLength: 0)
                        Button {
                            NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                        } label: { Image(systemName: "gearshape") }
                        Button {
                            NotificationCenter.default.post(name: .toggleSidebar, object: NSApp.keyWindow)
                        } label: { Image(systemName: "sidebar.left") }
                    }
                    .frame(height: 38 * tabScale)
                    HStack(spacing: 8) {
                        CurrentURLLabel(fontSize: 10 * tabScale)
                        Spacer(minLength: 0)
                        ReloadPageButton(fontSize: 10 * tabScale)
                    }
                    .frame(height: 28 * tabScale)
                }
                .font(.system(size: 11 * tabScale, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
            } else {
                HStack(spacing: 10) {
                    Button(action: {
                        NotificationCenter.default.post(name: .toggleSidebar, object: NSApp.keyWindow)
                    }) { Image(systemName: "sidebar.right") }
                    CurrentURLLabel(fontSize: 10 * tabScale)
                    Spacer(minLength: 0)
                    ReloadPageButton(fontSize: 10 * tabScale)
                    Button {
                        NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
                    } label: { Image(systemName: "gearshape") }
                    .help("Настройки")
                }
                .frame(height: 38 * tabScale)
                .font(.system(size: 11 * tabScale, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
            }
            Divider()

            // On the left, loaded mod actions belong below the window controls;
            // the right sidebar keeps them fixed at the bottom.
            if side == "left" {
                ModNavigationItems(horizontal: false)
                    .padding(.horizontal, 8)
                Divider()
            }

            // Tabs list with favicon, pin & close functionality
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tabManager.tabs) { tab in
                        HStack(spacing: 8) {
                            if copiedTabID == tab.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                    .frame(width: 14 * tabScale, height: 14 * tabScale)
                            } else if let favicon = tab.favicon {
                                Image(nsImage: favicon)
                                    .resizable()
                                    .frame(width: 14 * tabScale, height: 14 * tabScale)
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 14 * tabScale, height: 14 * tabScale)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.title.isEmpty ? "Заголовок" : tab.title)
                                    .font(.system(size: 12 * tabScale))
                                    .lineLimit(1)
                                    .foregroundColor(tab.id == tabManager.activeTabID ? .primary : .secondary)
                                Text(tab.url?.host ?? "Новая вкладка")
                                    .font(.system(size: 9 * tabScale))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                            if tab.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8 * tabScale))
                                    .foregroundColor(.secondary)
                            }
                            Button { tabManager.closeTab(id: tab.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8 * tabScale, weight: .semibold))
                                    .frame(width: 20 * tabScale, height: 20 * tabScale)
                            }
                            .buttonStyle(.plain)
                            .help("Закрыть вкладку")
                        }
                        .padding(.vertical, 7 * tabScale)
                        .padding(.horizontal, 10)
                        .background(tab.id == tabManager.activeTabID ? Color.gray.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if tab.id == tabManager.activeTabID { copyURL(of: tab) }
                            else { tabManager.selectTab(id: tab.id) }
                        }
                        .contextMenu {
                            Button(tab.isPinned ? "Открепить" : "Закрепить") {
                                tabManager.togglePinTab(id: tab.id)
                            }
                            Button("Выгрузить из памяти") {
                                tabManager.hibernateTab(id: tab.id)
                            }
                            if tabManager.modCapabilities.contains("splitView") {
                                Button("Разделить экран") { tabManager.activateSplit(with: tab.id) }
                            }
                            Divider()
                            Button("Закрыть") {
                                tabManager.closeTab(id: tab.id)
                            }
                        }
                    }
                    NewTabButton(title: "Новая страница", fontSize: 12 * tabScale)
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
            }

            if side != "left" {
                Divider()
                ModNavigationItems(horizontal: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func copyURL(of tab: TabModel) {
        guard let value = tab.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedTabID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedTabID == tab.id { copiedTabID = nil }
        }
    }
}

private struct ReloadPageButton: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        Button { tabManager.reloadActiveTab() } label: {
            Image(systemName: tabManager.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                .font(.system(size: fontSize, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(tabManager.activeTab?.url == nil)
        .help(tabManager.activeTab?.isLoading == true ? "Остановить" : "Обновить страницу")
    }
}

private struct CurrentURLLabel: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var copied = false

    var body: some View {
        HStack(spacing: 5) {
            Text(tabManager.activeTab?.url?.absoluteString ?? "Новая вкладка")
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
            .help("Скопировать URL")
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
            Label("Новая вкладка", systemImage: "plus")
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            TextField("Поиск или URL", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .onSubmit { guard !value.isEmpty else { return }; tabManager.navigateActiveTab(to: value) }
            Button { copyURL() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
                .buttonStyle(.plain).disabled(tabManager.activeTab?.url == nil)
        }
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

private struct ModNavigationItems: View {
    let horizontal: Bool
    @Environment(TabManager.self) private var tabManager: TabManager

    private var hasItems: Bool {
        !tabManager.modCapabilities.isDisjoint(with: ["devtools", "historyAccounts", "splitView"])
    }

    var body: some View {
        Group {
            if hasItems {
                if horizontal {
                    Divider().frame(height: 22).padding(.horizontal, 4)
                } else {
                    Divider().padding(.vertical, 6)
                }
            }
            if tabManager.modCapabilities.contains("devtools") {
                item("Web Inspector", icon: "ladybug") { tabManager.toggleModPanel("devtools") }
            }
            if tabManager.modCapabilities.contains("historyAccounts") {
                item("История и аккаунты", icon: "clock.arrow.circlepath") { tabManager.toggleModPanel("historyAccounts") }
            }
            if tabManager.modCapabilities.contains("splitView") {
                item("Разделить экран", icon: "rectangle.split.2x1") { tabManager.startSplitView() }
            }
        }
    }

    private func item(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if horizontal { Image(systemName: icon).frame(width: 32, height: 36).help(title) }
            else { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 34) }
        }.buttonStyle(.plain).foregroundColor(.secondary)
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
        window.backgroundColor = .windowBackgroundColor
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

private struct URLSystemSuggestions: View {
    let query: String
    let prefixes: [String]
    let selectedIndex: Int
    let onSelect: (String) -> Void

    private var targets: [String] {
        prefixes.compactMap { URLRouter.prefixedTarget(query: query, prefix: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                Button(action: { onSelect(target) }) {
                    HStack {
                        Image(systemName: index == selectedIndex ? "chevron.right" : "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(index == selectedIndex ? .primary : .secondary)
                        Text(target.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 10))
                            .foregroundColor(index == selectedIndex ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 42)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedIndex ? Color.primary.opacity(0.08) : Color.clear)
            }
            if targets.isEmpty {
                Text("Добавьте URL-систему в Настройки → Продвинутый функционал")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 42)
                    .frame(height: 34)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Search Modal View

public struct SearchModalView: View {
    @Binding public var isPresented: Bool
    @Binding public var currentState: ViewState
    @State private var query = ""
    @State private var urlSystemActive = false
    @State private var selectedURLSystem = 0
    @Environment(TabManager.self) private var tabManager: TabManager
    @FocusState private var isFocused: Bool
    @AppStorage("customURLPrefix") private var customURLPrefix: String = ""
    @AppStorage("customURLPrefixesJSON") private var customURLPrefixesJSON: String = "[]"

    private var urlPrefixes: [String] {
        URLSystemStore.prefixes(json: customURLPrefixesJSON, legacyPrefix: customURLPrefix)
    }

    public init(isPresented: Binding<Bool>, currentState: Binding<ViewState>, initialQuery: String = "") {
        self._isPresented = isPresented
        self._currentState = currentState
        self._query = State(initialValue: initialQuery)
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: urlSystemActive ? "link" : "magnifyingglass")
                        .foregroundColor(urlSystemActive ? .white : .gray)
                    TextField(urlSystemActive ? selectedPrefixLabel : "Поиск или URL · Tab — url-система", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(urlSystemActive ? .white : .primary)
                        .focused($isFocused)
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
                        .onSubmit { processSearch() }
                    if !urlSystemActive {
                        HStack(spacing: 2) {
                            spotlightNavButton("chevron.left", help: "Назад (⌘[)", enabled: tabManager.canGoBack) {
                                tabManager.goBackActiveTab()
                            }
                            spotlightNavButton("chevron.right", help: "Вперёд (⌘])", enabled: tabManager.canGoForward) {
                                tabManager.goForwardActiveTab()
                            }
                            spotlightNavButton("arrow.clockwise", help: "Перезагрузить (⌘R)", enabled: tabManager.activeTab?.url != nil) {
                                tabManager.reloadActiveTab()
                            }
                        }
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(urlSystemActive ? Color.primary : Color(NSColor.windowBackgroundColor))

                if urlSystemActive {
                    URLSystemSuggestions(query: query, prefixes: urlPrefixes, selectedIndex: selectedURLSystem) { target in
                        tabManager.navigateActiveTab(to: target)
                        isPresented = false
                        currentState = .workspace
                    }
                }
            }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: Color.black.opacity(0.15), radius: 15, y: 5)
                .frame(maxWidth: 480)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
    }

    private func processSearch() {
        var target = query
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if (urlSystemActive || flags.contains(.option)), !urlPrefixes.isEmpty,
           let prefixed = URLRouter.prefixedTarget(query: query, prefix: urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)]) {
            target = prefixed
        }
        if !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabManager.navigateActiveTab(to: target)
        }
        isPresented = false
        currentState = .workspace
    }

    /// Кнопка навигации в Spotlight: выполняет действие на активной вкладке и закрывает Spotlight.
    private func spotlightNavButton(_ systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
            currentState = .workspace
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? .primary : .gray.opacity(0.5))
        .disabled(!enabled)
        .help(help)
    }

    private var selectedPrefixLabel: String {
        guard !urlPrefixes.isEmpty else { return "URL-система не настроена" }
        return urlPrefixes[min(selectedURLSystem, urlPrefixes.count - 1)] + "/…"
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
