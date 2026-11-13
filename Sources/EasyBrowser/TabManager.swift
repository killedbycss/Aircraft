import Foundation
import WebKit
import Observation
import AppKit

/// Менеджер вкладок браузера, хранящий и управляющий инстансами WKWebView
@MainActor
@Observable
public final class TabManager: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, ScriptBridgeDelegate {
    public var tabs: [TabModel] = []
    public var activeTabID: UUID?
    /// Tabs shown in split mode. `activeTabID` is the pane receiving commands.
    public var splitPrimaryTabID: UUID?
    public var splitTabID: UUID?
    public var modCapabilities: Set<String> = []
    /// A capability is advertised only after its script has actually run in a page.
    /// This prevents menu entries for a copied-but-broken modification.
    public var loadedModCapabilities: Set<String> = []

    private let scriptBridge = ScriptBridge()
    private var storageObserver: NSObjectProtocol?
    private var adBlockObserver: NSObjectProtocol?
    private var userScriptRefreshTask: Task<Void, Never>?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Скачивания для просмотрщиков PDF и Markdown.
    @ObservationIgnored var pendingViewerDownloads: [UUID: (kind: ViewerKind, url: URL?)] = [:]
    @ObservationIgnored var viewerDownloads: [ObjectIdentifier: (tabID: UUID, kind: ViewerKind, url: URL?)] = [:]
    /// Из какой вкладки открыта вкладка — чтобы новые вставали подряд справа от «родителя».
    private var openedFrom: [UUID: UUID] = [:]
    private var webViewObservers: [UUID: [NSKeyValueObservation]] = [:]
    private var mobileBrowsing = false

    // MARK: Окно, профиль, дерево

    /// Окно в сессии (`session.json`).
    public let windowID: UUID
    /// Окно инкогнито: своё хранилище в памяти, ничего не пишется на диск.
    public let isIncognito: Bool
    public private(set) var profileID: UUID
    /// Порядок вкладок, папки и группы.
    public var tree = SidebarTree()
    /// Недавно закрытые вкладки этого окна (⌘⇧T), новые — в конце.
    public var closedTabs: [ClosedTab] = []
    public static let closedTabsLimit = 25
    /// Вкладки других профилей этого окна (пока окно показывает текущий).
    @ObservationIgnored var otherSets: [String: SavedTabSet] = [:]
    @ObservationIgnored public weak var hostWindow: NSWindow?
    @ObservationIgnored lazy var incognitoStore: WKWebsiteDataStore = .nonPersistent()
    @ObservationIgnored lazy var incognitoSites = SiteSettingsStore(url: nil, seed: ProfileStore.shared.sites(for: profileID).sites)
    @ObservationIgnored private var kvoTokens: [UUID: [KeyValueToken]] = [:]
    @ObservationIgnored let pageSignals = PageSignals()
    /// Вкладки, открытые как всплывающие окна входа — их не группируем.
    @ObservationIgnored private var popupTabIDs: Set<UUID> = []
    /// Вкладки, где адрес ввели в Spotlight (для ранжирования истории).
    @ObservationIgnored var typedNavigations: Set<UUID> = []

    // MARK: Состояние интерфейса окна

    /// Плашка поиска по странице (⌘F).
    public var findBar = FindBarState()
    /// Короткое уведомление поверх страницы («Ссылка скопирована», «110 %»).
    public var toast: ToastMessage?
    /// Запрос разрешения от сайта, ожидающий ответа.
    public var permissionRequests: [PermissionRequest] = []
    /// Папка, у которой сейчас редактируется название.
    public var renamingFolderID: UUID?
    /// Вкладки, выделенные ⌘-кликом в панели.
    public var selectedTabIDs: Set<UUID> = []
    /// «Открыть в приложении» для вкладок (Zoom, Telegram…).
    var appLinkOffers: [UUID: AppLinkOffer] = [:]
    /// Сайты, где предложение открыть приложение закрыли (до перезапуска).
    @ObservationIgnored var dismissedAppLinkHosts: Set<String> = []
    /// Открыт ли поповер «Добавить в закладки» (⌘D).
    public var bookmarkEditorVisible = false
    /// Фокус на странице стоит в поле ввода (для ⌥← / ⌥→).
    @ObservationIgnored public var editableFocusTabs: Set<UUID> = []

    public convenience override init() {
        self.init(window: SessionStore.shared.claimWindow(), incognito: false)
    }

    public init(window saved: SavedWindow?, incognito: Bool, profileID requestedProfile: UUID? = nil) {
        let profiles = ProfileStore.shared
        isIncognito = incognito
        windowID = incognito ? UUID() : (saved?.id ?? UUID())
        profileID = profiles.profile(requestedProfile ?? saved?.activeProfileID ?? profiles.lastUsedProfileID).id
        super.init()
        scriptBridge.delegate = self
        pageSignals.manager = self
        AgentBrowser.register(self)
        if incognito {
            createNewTab()
        } else {
            otherSets = saved?.sets ?? [:]
            let set = otherSets.removeValue(forKey: profileID.uuidString)
            load(set)
            SessionStore.shared.register(self)
            profiles.lastUsedProfileID = profileID
        }
        refreshInstalledModCapabilities()
        storageObserver = NotificationCenter.default.addObserver(forName: .modStorageDidChange, object: nil, queue: .main) { [weak self] notification in
            // Готовим JS-строку здесь, чтобы не передавать Any между потоками.
            let script = (notification.userInfo?["key"] as? String).flatMap {
                ScriptBridge.syncScript(key: $0, value: notification.userInfo?["value"])
            }
            MainActor.assumeIsolated { self?.applyModStorageChange(syncScript: script) }
        }
        adBlockObserver = NotificationCenter.default.addObserver(forName: .adBlockRulesDidChange, object: nil, queue: .main) { [weak self] notification in
            let reload = notification.userInfo?["reload"] as? Bool ?? false
            MainActor.assumeIsolated { self?.applyAdBlockRules(reloadActiveTab: reload) }
        }
    }

    /// Правила блокировщика рекламы изменились: переподключаем их во всех вкладках.
    private func applyAdBlockRules(reloadActiveTab: Bool) {
        for tab in tabs {
            guard let controller = tab.webView?.configuration.userContentController else { continue }
            controller.removeAllContentRuleLists()
            AdBlocker.shared.attach(to: controller)
        }
        if reloadActiveTab, let webView = activeTab?.webView, webView.url != nil { webView.reload() }
    }

    /// Хранилище модов изменилось (в любой вкладке любого окна): обновляем открытые
    /// страницы сразу, а снимок для новых страниц — с небольшой задержкой.
    private func applyModStorageChange(syncScript script: String?) {
        if let script {
            for tab in tabs { tab.webView?.evaluateJavaScript(script, completionHandler: nil) }
        }
        userScriptRefreshTask?.cancel()
        userScriptRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            for tab in self.tabs {
                guard let controller = tab.webView?.configuration.userContentController else { continue }
                controller.removeAllUserScripts()
                self.pageSignals.install(into: controller)
                if AgentServer.isEnabled {
                    controller.addUserScript(WKUserScript(source: AgentBrowser.consoleCaptureSource, injectionTime: .atDocumentStart,
                                                          forMainFrameOnly: true, in: .page))
                }
                self.scriptBridge.configure(userContentController: controller)
                self.loadCustomModifications(into: controller)
                AdBlocker.shared.installPageScript(into: controller)
            }
        }
    }

    public var activeTab: TabModel? {
        guard let activeTabID = activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    public var activeWebView: WKWebView? {
        guard let activeTabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return nil }

        let tab = tabs[index]
        guard tab.url != nil else { return nil }
        if tab.isHibernated || tab.webView == nil {
            restoreTab(id: activeTabID)
            return tabs[index].webView
        }
        return tab.webView
    }

    public var canGoBack: Bool {
        if case .pdf = activeTab?.content, let pageURL = activeTab?.webView?.url, pageURL != activeTab?.url { return true }
        return activeTab?.webView?.canGoBack == true
    }
    public var canGoForward: Bool { activeTab?.webView?.canGoForward == true }

    // MARK: - Управление вкладками

    @discardableResult
    public func createNewTab(url: URL? = nil, selectNewTab: Bool = true, afterTabID: UUID? = nil,
                             openedByPage: Bool = false) -> UUID {
        let previouslyFocusedID = activeTabID
        let viewer = url.flatMap(Self.viewerContent(forLocal:))
        let webView = url == nil ? nil : createWebView()

        var newTab = TabModel(
            id: UUID(),
            title: "Новая вкладка",
            url: url,
            isLoading: url != nil,
            isHibernated: url != nil && webView == nil,
            isPinned: false,
            pinnedURL: nil,
            favicon: FaviconCache.shared.image(for: url),
            webView: webView
        )
        if let viewer { newTab.content = viewer }

        insertTab(newTab, after: afterTabID, openedByPage: openedByPage)
        if let webView { setupObservations(for: newTab.id, webView: webView) }

        if selectNewTab || activeTabID == nil {
            if splitPrimaryTabID != nil, splitTabID != nil {
                if previouslyFocusedID == splitTabID { splitTabID = newTab.id }
                else { splitPrimaryTabID = newTab.id }
            }
            activeTabID = newTab.id
        }

        if let url, let webView { load(url, in: webView, tabID: newTab.id) }
        saveSession()
        return newTab.id
    }

    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if let primaryID = splitPrimaryTabID, let secondaryID = splitTabID {
            if id == primaryID || id == secondaryID {
                activeTabID = id
            } else if activeTabID == secondaryID {
                splitTabID = id
            } else {
                splitPrimaryTabID = id
            }
        }
        if let previous = activeTabID, previous != id, let index = tabs.firstIndex(where: { $0.id == previous }) {
            tabs[index].lastActiveAt = Date()
            if Self.autoPictureInPicture, tabs[index].isPlayingAudio, tabs[index].content == .web,
               previous != splitTabID, previous != splitPrimaryTabID {
                togglePictureInPicture(id: previous, enterOnly: true)
            }
        }
        activeTabID = id
        if let index = tabs.firstIndex(where: { $0.id == id }) { tabs[index].lastActiveAt = Date() }
        tree.reveal(id)
        if findBar.isVisible { closeFindBar() }
        if let tab = tabs.first(where: { $0.id == id }), (tab.isHibernated || tab.webView == nil) {
            if tab.url != nil { restoreTab(id: id) }
        }
        saveSession()
    }

    /// Закрывает вкладку. `remember == false` — не класть в «Недавно закрытые» (архив кладёт сам).
    public func closeTab(id: UUID, remember: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        if remember, let record = closedRecord(for: id) {
            closedTabs.append(record)
            if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst(closedTabs.count - Self.closedTabsLimit) }
        }
        removeObservations(for: id)
        openedFrom.removeValue(forKey: id)
        popupTabIDs.remove(id)
        editableFocusTabs.remove(id)
        cancelPermissionRequests(tabID: id)
        appLinkOffers[id] = nil
        let tabToClose = tabs[index]
        tabToClose.webView?.stopLoading()
        tabToClose.webView?.navigationDelegate = nil
        tabToClose.webView?.uiDelegate = nil
        if case .pdf(let file) = tabToClose.content, file.path.hasPrefix(AircraftPaths.viewerCache.path) {
            try? FileManager.default.removeItem(at: file)
        }
        if let webView = tabToClose.webView { MarkdownViewer.stopWatching(webView) }

        // Следующей активной становится соседняя вкладка в порядке отображения.
        let order = tree.visibleTabIDs
        let position = order.firstIndex(of: id)
        tree.removeNode(id)
        tree.dissolveSmallGroups()
        tabs.remove(at: index)
        syncTabOrder()

        if splitPrimaryTabID == id || splitTabID == id {
            let survivor = splitPrimaryTabID == id ? splitTabID : splitPrimaryTabID
            splitPrimaryTabID = nil
            splitTabID = nil
            if activeTabID == id, let survivor {
                activeTabID = nil
                selectTab(id: survivor)
            }
        }

        if activeTabID == id {
            let remaining = tree.visibleTabIDs.isEmpty ? tree.orderedTabIDs : tree.visibleTabIDs
            let candidate = position.flatMap { remaining.indices.contains($0) ? remaining[$0] : nil } ?? remaining.last
            activeTabID = nil
            if let candidate {
                selectTab(id: candidate)
            } else {
                createNewTab()
                NotificationCenter.default.post(name: .showEmptySpotlight, object: hostWindow)
            }
        }
        saveSession()
    }

    public func togglePinTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let pinning = !tabs[index].isPinned
        if pinning {
            tree.move(id, to: .pinnedRoot)
        } else {
            tree.move(id, to: .regularRoot, at: 0)
        }
        tree.dissolveSmallGroups()
        syncPinnedFlags()
        syncTabOrder()
        saveSession()
    }

    /// Флаг «закреплена» следует за зоной в дереве; адрес закрепления запоминается при закреплении.
    func syncPinnedFlags() {
        for index in tabs.indices {
            let zone = tree.zone(of: tabs[index].id)
            let pinned = zone == .pinned || zone == .favorites
            if pinned != tabs[index].isPinned {
                tabs[index].isPinned = pinned
                tabs[index].pinnedURL = pinned ? tabs[index].url : nil
            }
        }
    }

    /// `tabs` хранится в порядке дерева: на этом порядке держатся ⌘1…⌘9 и агенты.
    func syncTabOrder() {
        let order = tree.orderedTabIDs
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = tabs.sorted { (position[$0.id] ?? Int.max) < (position[$1.id] ?? Int.max) }
        if sorted.map(\.id) != tabs.map(\.id) { tabs = sorted }
    }

    public func closeActiveTabFromShortcut() {
        guard let id = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Закреплённая вкладка и плитка ⌘W не закрываются никогда: как в Arc, вкладка
        // возвращается к закреплённому адресу, выгружается, а фокус уходит на соседнюю.
        if isProtectedPin(id) {
            if !tabs[index].isPinned { syncPinnedFlags() }
            let pinnedURL = tabs[index].pinnedURL ?? tabs[index].url
            if tabs[index].pinnedURL == nil { tabs[index].pinnedURL = pinnedURL }
            if let pinnedURL, tabs[index].webView?.url != pinnedURL {
                tabs[index].url = pinnedURL
                tabs[index].interactionState = nil
                tabs[index].favicon = FaviconCache.shared.image(for: pinnedURL) ?? tabs[index].favicon
            }
            let fallback = tabs
                .filter { $0.id != id && !$0.isPinned }
                .max { $0.lastActiveAt < $1.lastActiveAt }?.id
            hibernateTab(id: id)
            if let pinnedURL { tabs[index].url = pinnedURL; tabs[index].interactionState = nil }
            if let fallback { selectTab(id: fallback) }
            saveSession()
        } else {
            closeTab(id: id)
        }
    }

    /// Закреплённая вкладка или плитка — в том числе внутри папки закреплённых.
    /// Смотрим на место в дереве, а не только на флаг: флаг мог не успеть обновиться.
    func isProtectedPin(_ id: UUID) -> Bool {
        if tabs.first(where: { $0.id == id })?.isPinned == true { return true }
        guard let zone = tree.zone(of: id) else { return false }
        return zone == .pinned || zone == .favorites
    }

    /// Starts split mode with a new blank page in the second pane.
    public func startSplitView() {
        guard modCapabilities.contains("splitView"), let primaryID = activeTabID else { return }
        if splitPrimaryTabID != nil, let splitTabID {
            activeTabID = splitTabID
            return
        }
        let blankID = createNewTab(selectNewTab: false)
        splitPrimaryTabID = primaryID
        splitTabID = blankID
        activeTabID = blankID
        saveSession()
    }

    /// Starts split mode with an already open tab, or replaces the focused pane.
    public func activateSplit(with tabID: UUID) {
        guard modCapabilities.contains("splitView"), tabs.contains(where: { $0.id == tabID }) else { return }
        if splitPrimaryTabID != nil, splitTabID != nil {
            selectTab(id: tabID)
            return
        }
        guard let currentID = activeTabID else { return }
        if tabID == currentID {
            guard let otherID = tabs.first(where: { $0.id != currentID })?.id else {
                startSplitView()
                return
            }
            splitPrimaryTabID = currentID
            splitTabID = otherID
        } else {
            splitPrimaryTabID = currentID
            splitTabID = tabID
        }
        activeTabID = splitTabID
        if let splitTabID, let tab = tabs.first(where: { $0.id == splitTabID }), tab.url != nil, tab.webView == nil {
            restoreTab(id: splitTabID)
        }
        saveSession()
    }

    public func focusSplitPane(_ tabID: UUID) {
        guard tabID == splitPrimaryTabID || tabID == splitTabID else { return }
        activeTabID = tabID
        saveSession()
    }

    public func closeSplitView() {
        let focusedID = activeTabID
        splitPrimaryTabID = nil
        splitTabID = nil
        if let focusedID, tabs.contains(where: { $0.id == focusedID }) { activeTabID = focusedID }
        saveSession()
    }

    /// Открывает или закрывает встроенный Web Inspector WebKit для активной вкладки (F12, ⌥⌘I).
    /// Использует приватный `_WKInspector`, который WebKit отдаёт через `-[WKWebView _inspector]`.
    public func toggleWebInspector() {
        guard let webView = activeWebView else { return }
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        guard let inspector = Self.inspector(of: webView) else { return }
        let isVisible = (inspector.value(forKey: "visible") as? Bool) ?? false
        let action = NSSelectorFromString(isVisible ? "close" : "show")
        if inspector.responds(to: action) { inspector.perform(action) }
    }

    static func closeWebInspector(of webView: WKWebView) {
        guard let inspector = inspector(of: webView),
              (inspector.value(forKey: "visible") as? Bool) == true else { return }
        inspector.perform(NSSelectorFromString("close"))
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    public func toggleModPanel(_ capability: String) {
        if capability == "devtools" {
            activeWebView?.isInspectable = true
            let alert = NSAlert()
            alert.messageText = "Web Inspector включён"
            alert.informativeText = "Откройте Safari → Develop и выберите текущую страницу Aircraft. Это нативный инспектор WebKit."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        switch capability {
        case "historyAccounts": LibraryWindow.show(.history, for: self)
        case "accounts": LibraryWindow.show(.accounts, for: self)
        case "downloads": LibraryWindow.show(.downloads, for: self)
        default: return
        }
    }

    public func webView(for tabID: UUID?) -> WKWebView? {
        guard let tabID, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        if tabs[index].url != nil, (tabs[index].isHibernated || tabs[index].webView == nil) { restoreTab(id: tabID) }
        return tabs[index].webView
    }

    /// Гибернация вкладки: удаляет ссылку на WKWebView для освобождения памяти в com.apple.WebKit.WebContent, сохраняя URL и title
    public func hibernateTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard !tabs[index].isHibernated else { return }

        let currentURL = tabs[index].webView?.url ?? tabs[index].url
        let currentTitle = tabs[index].webView?.title ?? tabs[index].title
        if let state = tabs[index].webView?.interactionState as? Data { tabs[index].interactionState = state }
        if let webView = tabs[index].webView {
            TabManager.closeWebInspector(of: webView)
            MarkdownViewer.stopWatching(webView)
        }

        removeObservations(for: id)
        tabs[index].webView?.stopLoading()
        tabs[index].webView?.navigationDelegate = nil
        tabs[index].webView?.uiDelegate = nil
        tabs[index].webView = nil

        tabs[index].url = currentURL
        tabs[index].title = currentTitle
        tabs[index].isLoading = false
        tabs[index].isHibernated = true
        tabs[index].isPlayingAudio = false
        tabs[index].isCapturingMedia = false
        tabs[index].isInPictureInPicture = false
        editableFocusTabs.remove(id)
        saveSession()
    }

    /// Восстановление гибернированной вкладки
    public func restoreTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        guard tab.isHibernated || tab.webView == nil else { return }

        let webView = createWebView()
        tabs[index].webView = webView
        tabs[index].isHibernated = false
        setupObservations(for: id, webView: webView)

        if tab.content == .web, let state = tab.interactionState {
            webView.interactionState = state
            tabs[index].interactionState = nil
        } else if let url = tab.url {
            load(url, in: webView, tabID: id)
        }
        applyTabMediaState(id: id)
    }

    public func navigateActiveTab(to urlString: String) {
        guard let activeTabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }

        let defaults = Foundation.UserDefaults.standard
        let engineID = defaults.string(forKey: "searchEngine") ?? "duckduckgo"
        let customURL = defaults.string(forKey: "customSearchURL") ?? ""
        let template = SearchEngineOption.queryTemplate(for: engineID, customURL: customURL)
        let finalURL = URLRouter.navigationTarget(input: urlString, searchTemplate: template).flatMap(URL.init(string:))

        guard let targetURL = finalURL else { return }

        if tabs[index].webView == nil {
            let webView = createWebView()
            tabs[index].webView = webView
            tabs[index].isHibernated = false
            setupObservations(for: activeTabID, webView: webView)
        }

        tabs[index].url = targetURL
        tabs[index].title = targetURL.host ?? (targetURL.isFileURL ? targetURL.lastPathComponent : "Новая вкладка")
        tabs[index].content = Self.viewerContent(forLocal: targetURL) ?? .web
        typedNavigations.insert(activeTabID)
        if let webView = tabs[index].webView { load(targetURL, in: webView, tabID: activeTabID) }
        saveSession()
    }

    public func reloadActiveTab() {
        guard let activeTab = activeTab else { return }
        if activeTab.isLoading {
            activeTab.webView?.stopLoading()
        } else {
            if activeTab.isHibernated || activeTab.webView == nil {
                if let activeTabID = activeTabID { restoreTab(id: activeTabID) }
            } else {
                activeTab.webView?.reload()
            }
        }
    }

    public func goBackActiveTab() {
        // Из PDF, открытого со страницы, «назад» возвращает на эту страницу.
        if let id = activeTabID, let index = tabs.firstIndex(where: { $0.id == id }),
           case .pdf = tabs[index].content, let pageURL = tabs[index].webView?.url, pageURL != tabs[index].url {
            tabs[index].content = .web
            tabs[index].url = pageURL
            tabs[index].title = tabs[index].webView?.title ?? tabs[index].title
            return
        }
        activeTab?.webView?.goBack()
    }

    public func goForwardActiveTab() {
        activeTab?.webView?.goForward()
    }

    public func setMobileBrowsing(_ enabled: Bool) {
        guard mobileBrowsing != enabled else { return }
        mobileBrowsing = enabled

        let inactiveIDs = tabs.compactMap { tab in
            tab.id != activeTabID && tab.webView != nil ? tab.id : nil
        }
        inactiveIDs.forEach(hibernateTab)

        guard let webView = activeTab?.webView else { return }
        configureContentMode(for: webView)
        if webView.url != nil { webView.reload() }
    }

    public func resetResources(scope: String) {
        switch scope {
        case "allTabs":
            for id in tabs.compactMap({ $0.url == nil || $0.isBusy ? nil : $0.id }) { hibernateTab(id: id) }
        case "webCache":
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        default:
            for tab in tabs where tab.id != activeTabID && tab.url != nil && !tab.isBusy { hibernateTab(id: tab.id) }
        }
    }

    /// Сессия пишется на диск с задержкой (см. `SessionStore`); инкогнито не пишется вовсе.
    func saveSession() {
        guard !isIncognito else { return }
        SessionStore.shared.markDirty()
    }

    /// Загружает вкладки профиля. Все вкладки усыплены, проснётся только активная.
    private func load(_ set: SavedTabSet?) {
        tabs = []
        tree = SidebarTree()
        closedTabs = []
        activeTabID = nil
        guard let set, !set.tabs.isEmpty else {
            createNewTab()
            return
        }
        tabs = set.tabs.map { saved in
            var tab = TabModel(
                id: saved.id,
                title: saved.title,
                url: saved.url,
                isLoading: false,
                isHibernated: saved.url != nil,
                isPinned: saved.isPinned,
                pinnedURL: saved.pinnedURL,
                favicon: FaviconCache.shared.image(for: saved.url ?? saved.pinnedURL),
                webView: nil
            )
            tab.lastActiveAt = saved.lastActiveAt ?? Date()
            tab.interactionState = saved.interactionState
            if let url = saved.url, let viewer = Self.viewerContent(forLocal: url) { tab.content = viewer }
            return tab
        }
        tree = set.tree
        tree.reconcile(with: tabs.map(\.id), pinnedIDs: Set(tabs.filter(\.isPinned).map(\.id)))
        syncPinnedFlags()
        syncTabOrder()
        closedTabs = set.closed
        activeTabID = tabs.contains(where: { $0.id == set.activeTabID }) ? set.activeTabID : tabs.first?.id
    }

    /// Текущие вкладки в виде, пригодном для записи.
    func currentTabSet() -> SavedTabSet {
        var set = SavedTabSet()
        set.tabs = tabs.map { tab in
            let state = (tab.webView?.interactionState as? Data) ?? tab.interactionState
            return SavedTab(id: tab.id, title: tab.title, url: tab.url, isPinned: tab.isPinned, pinnedURL: tab.pinnedURL,
                            lastActiveAt: tab.lastActiveAt, interactionState: tab.content == .web ? state : nil)
        }
        set.tree = tree
        set.activeTabID = activeTabID
        set.closed = closedTabs
        return set
    }

    func snapshotWindow() -> SavedWindow {
        var sets = otherSets
        sets[profileID.uuidString] = currentTabSet()
        return SavedWindow(id: windowID, activeProfileID: profileID, sets: sets)
    }

    /// Переключает окно на другой профиль. Вкладки прежнего профиля выгружаются из памяти
    /// и вернутся, когда профиль выберут снова.
    public func switchProfile(to id: UUID) {
        guard !isIncognito, id != profileID, ProfileStore.shared.profiles.contains(where: { $0.id == id }) else { return }
        splitPrimaryTabID = nil
        splitTabID = nil
        if findBar.isVisible { closeFindBar() }
        let current = currentTabSet()
        for tab in tabs {
            removeObservations(for: tab.id)
            tab.webView?.stopLoading()
            tab.webView?.navigationDelegate = nil
            tab.webView?.uiDelegate = nil
        }
        otherSets[profileID.uuidString] = current
        profileID = id
        ProfileStore.shared.lastUsedProfileID = id
        permissionRequests.forEach { $0.respond(false) }
        permissionRequests = []
        editableFocusTabs = []
        load(otherSets.removeValue(forKey: id.uuidString))
        if let activeTabID { restoreTab(id: activeTabID) }
        saveSession()
        if activeTab?.url == nil {
            NotificationCenter.default.post(name: .showEmptySpotlight, object: hostWindow)
        }
    }

    /// Профиль удалили: если окно его показывало — переходим на профиль по умолчанию.
    func profileWasDeleted(_ id: UUID) {
        otherSets[id.uuidString] = nil
        if profileID == id {
            let fallback = ProfileStore.shared.defaultProfile.id
            otherSets[profileID.uuidString] = nil
            profileID = fallback
            load(otherSets.removeValue(forKey: fallback.uuidString))
            saveSession()
        }
    }

    /// Recreates the web views so newly added CSS/JS modifications apply immediately.
    public func reloadCustomModifications() {
        loadedModCapabilities = []
        refreshInstalledModCapabilities()
        for index in tabs.indices where tabs[index].webView != nil {
            let tabID = tabs[index].id
            let targetURL = tabs[index].webView?.url ?? tabs[index].url
            removeObservations(for: tabID)
            tabs[index].webView?.stopLoading()
            tabs[index].webView?.navigationDelegate = nil
            tabs[index].webView?.uiDelegate = nil

            let webView = createWebView()
            tabs[index].webView = webView
            tabs[index].isHibernated = false
            tabs[index].isLoading = true
            setupObservations(for: tabID, webView: webView)
            if let targetURL {
                webView.load(URLRequest(url: targetURL))
            }
        }
    }

    // MARK: - WKWebView Factory

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        pageSignals.install(into: config.userContentController)
        // Включает встроенный Web Inspector (F12, «Проверить элемент» в контекстном меню).
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.preferredContentMode = mobileBrowsing ? .mobile : .desktop
        scriptBridge.configure(userContentController: config.userContentController)
        loadCustomModifications(into: config.userContentController)
        AdBlocker.shared.attach(to: config.userContentController)
        if AgentServer.isEnabled {
            // Буфер консоли для MCP-инструмента browser_console.
            config.userContentController.addUserScript(WKUserScript(
                source: AgentBrowser.consoleCaptureSource, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .page))
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        // This exposes the real WebKit inspector in Safari's Develop menu.
        // It is deliberately enabled only while the DevTools modification is loaded.
        webView.isInspectable = ModCatalog.isInstalled("aircraft-devtools-webextensions", in: installedModFiles())
        webView.underPageBackgroundColor = .windowBackgroundColor
        // Свайп двумя пальцами — назад и вперёд, как в Safari и Dia.
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        configureContentMode(for: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func configureContentMode(for webView: WKWebView) {
        webView.configuration.defaultWebpagePreferences.preferredContentMode = mobileBrowsing ? .mobile : .desktop
        webView.customUserAgent = mobileBrowsing ? Self.mobileUserAgent : nil
    }

    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private func loadCustomModifications(into controller: WKUserContentController) {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let modsURL = appSupportURL.appendingPathComponent("aircraft/mods", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var loadedBundledFamilies: Set<String> = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if ModCatalog.retiredFamily(for: file.lastPathComponent) != nil { continue }
            if let family = ModCatalog.family(for: file.lastPathComponent) {
                guard loadedBundledFamilies.insert(family).inserted else { continue }
            }
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            switch file.pathExtension.lowercased() {
            case "js": scriptBridge.injectCustomScript(source, into: controller)
            case "css": scriptBridge.injectCSS(source, into: controller)
            default: break
            }
        }
    }

    private func refreshInstalledModCapabilities() {
        modCapabilities = loadedModCapabilities.union(ModCatalog.installedCapabilities(in: installedModFiles()))
        if !modCapabilities.contains("splitView") {
            splitPrimaryTabID = nil
            splitTabID = nil
        }
    }

    private func installedModFiles() -> [String] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("aircraft/mods").path)) ?? []
    }

    // MARK: - KVO Наблюдение

    private func setupObservations(for tabID: UUID, webView: WKWebView) {
        removeObservations(for: tabID)

        let titleObs = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                if let title = webView.title, !title.isEmpty {
                    self.tabs[index].title = title
                    if let url = webView.url { self.history?.updateTitle(url: url, title: title) }
                    self.saveSession()
                }
            }
        }

        let urlObs = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                if let url = webView.url {
                    self.tabs[index].url = url
                    self.refreshAppLinkOffer(tabID: tabID, url: url)
                    self.saveSession()
                }
            }
        }

        let loadingObs = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.tabs[index].isLoading = webView.isLoading
            }
        }

        let progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.tabs[index].loadProgress = webView.estimatedProgress
            }
        }

        let cameraObs = webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in self?.updateCaptureState(tabID: tabID, webView: webView) }
        }
        let microphoneObs = webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in self?.updateCaptureState(tabID: tabID, webView: webView) }
        }

        webViewObservers[tabID] = [titleObs, urlObs, loadingObs, progressObs, cameraObs, microphoneObs]
        if WebKitPrivate.canObservePlayingAudio {
            kvoTokens[tabID] = [KeyValueToken(object: webView, keyPath: "_isPlayingAudio") { [weak self] value in
                let playing = (value as? NSNumber)?.boolValue ?? false
                Task { @MainActor [weak self] in
                    guard let self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                    if self.tabs[index].isPlayingAudio != playing { self.tabs[index].isPlayingAudio = playing }
                }
            }]
        }
    }

    private func updateCaptureState(tabID: UUID, webView: WKWebView) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let capturing = webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        if tabs[index].isCapturingMedia != capturing { tabs[index].isCapturingMedia = capturing }
    }

    /// Остановить камеру и микрофон вкладки (клик по красной точке).
    public func stopMediaCapture(id: UUID) {
        guard let webView = tabs.first(where: { $0.id == id })?.webView else { return }
        webView.setCameraCaptureState(.none)
        webView.setMicrophoneCaptureState(.none)
    }

    private func removeObservations(for tabID: UUID) {
        webViewObservers[tabID]?.forEach { $0.invalidate() }
        webViewObservers.removeValue(forKey: tabID)
        kvoTokens[tabID]?.forEach { $0.invalidate() }
        kvoTokens.removeValue(forKey: tabID)
    }

    // MARK: - WKUIDelegate (новые окна и диалоги)

    /// target="_blank" и window.open(): создаём вкладку с настоящим WKWebView из переданной
    /// конфигурации, чтобы у страницы сохранились window.opener и postMessage
    /// (нужно для входа через всплывающие окна и для страниц, которые пишут в новое окно сами).
    nonisolated public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            createPopupTab(configuration: configuration, url: navigationAction.request.url,
                           openerTabID: tabs.first(where: { $0.webView === webView })?.id,
                           isLoginPopup: windowFeatures.width != nil || windowFeatures.height != nil)
        }
    }

    /// Вкладка, открытая со страницы, встаёт сразу справа от неё (после уже открытых
    /// ею вкладок), а не в конец списка.
    private func insertTab(_ tab: TabModel, after openerID: UUID?, openedByPage: Bool = false, isPopup: Bool = false) {
        tabs.append(tab)
        if let openerID, tree.contains(tab: openerID) {
            let anchor = lastOpened(from: openerID) ?? openerID
            if openedByPage && !isPopup {
                let openerURL = tabs.first(where: { $0.id == openerID })?.url
                let title = openerURL.map(HistoryStore.displayHost).flatMap { $0.isEmpty ? nil : $0 } ?? "Группа"
                tree.insertOpenedTab(tab.id, opener: openerID, anchor: anchor, grouping: Self.groupsOpenedLinks,
                                     groupTitle: title)
            } else {
                tree.insertTab(tab.id, after: anchor)
            }
            openedFrom[tab.id] = openerID
        } else {
            tree.appendTab(tab.id)
        }
        if isPopup { popupTabIDs.insert(tab.id) }
        syncTabOrder()
    }

    /// Ссылки, открытые в новой вкладке, собираются в группу (Настройки → Вкладки).
    static var groupsOpenedLinks: Bool {
        UserDefaults.standard.object(forKey: "groupOpenedLinks") as? Bool ?? true
    }

    /// Последняя вкладка, открытая со страницы `opener` подряд за ней.
    private func lastOpened(from opener: UUID) -> UUID? {
        let order = tree.orderedTabIDs
        guard var index = order.firstIndex(of: opener) else { return nil }
        var last: UUID?
        index += 1
        while index < order.count, openedFrom[order[index]] == opener {
            last = order[index]
            index += 1
        }
        return last
    }

    private func createPopupTab(configuration: WKWebViewConfiguration, url: URL?, openerTabID: UUID?, isLoginPopup: Bool) -> WKWebView {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.isInspectable = ModCatalog.isInstalled("aircraft-devtools-webextensions", in: installedModFiles())
        popup.underPageBackgroundColor = .windowBackgroundColor
        configureContentMode(for: popup)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let tabURL = (url?.absoluteString.isEmpty == false ? url : nil) ?? URL(string: "about:blank")
        let tab = TabModel(title: "Новая вкладка", url: tabURL, isLoading: true, webView: popup)
        insertTab(tab, after: openerTabID, openedByPage: true, isPopup: isLoginPopup)
        setupObservations(for: tab.id, webView: popup)
        selectTab(id: tab.id)
        saveSession()
        return popup
    }

    /// window.close() из страницы.
    nonisolated public func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(id: tab.id) }
        }
    }

    nonisolated public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makePageAlert(message: message, frame: frame)
            alert.addButton(withTitle: "OK")
            Self.present(alert, over: webView) { _ in completionHandler() }
        }
    }

    nonisolated public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makePageAlert(message: message, frame: frame)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Отмена")
            Self.present(alert, over: webView) { response in completionHandler(response == .alertFirstButtonReturn) }
        }
    }

    nonisolated public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let alert = Self.makePageAlert(message: prompt, frame: frame)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Отмена")
            alert.window.initialFirstResponder = field
            Self.present(alert, over: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }

    private static func makePageAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "Сообщение страницы" : "Сайт \(host) сообщает"
        alert.informativeText = message
        return alert
    }

    private static func present(_ alert: NSAlert, over webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            if let index = self.tabs.firstIndex(where: { $0.webView === webView }) {
                self.tabs[index].isLoading = true
                // Значок меняем, только если ушли на другой сайт, — иначе он мигает при каждом переходе.
                if FaviconCache.key(for: webView.url) != FaviconCache.key(for: self.tabs[index].url) {
                    self.tabs[index].favicon = FaviconCache.shared.image(for: webView.url)
                }
            }
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            self.applyZoom(to: webView)
            if let index = self.tabs.firstIndex(where: { $0.webView === webView }) {
                let id = self.tabs[index].id
                // Переход по ссылке из Markdown — дальше обычная страница.
                if case .markdown = self.tabs[index].content, !MarkdownViewer.consumeRenderNavigation(navigation) {
                    self.tabs[index].content = .web
                    MarkdownViewer.stopWatching(webView)
                }
                self.editableFocusTabs.remove(id)
                self.tabs[index].isReaderActive = false
                self.tabs[index].isReaderable = false
                self.cancelPermissionRequests(tabID: id)
                if id == self.activeTabID, self.findBar.isVisible { self.closeFindBar() }
                if self.tabs[index].isMuted { self.applyTabMediaState(id: id) }
            }
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if let index = self.tabs.firstIndex(where: { $0.webView === webView }) {
                let tabID = self.tabs[index].id
                self.tabs[index].isLoading = false
                if let title = webView.title, !title.isEmpty {
                    self.tabs[index].title = title
                }
                if let url = webView.url {
                    self.tabs[index].url = url
                    if self.tabs[index].content == .web {
                        self.history?.recordVisit(url: url, title: webView.title ?? "", typed: self.typedNavigations.remove(tabID) != nil)
                    }
                }
                self.saveSession()
                if self.tabs[index].content == .web { await self.checkReaderAvailability(tabID: tabID, webView: webView) }
                await self.updatePageBackground(for: tabID, from: webView)
                await self.loadFavicon(for: tabID, from: webView)
            }
        }
    }

    private func updatePageBackground(for tabID: UUID, from webView: WKWebView) async {
        let script = """
        (() => {
          const transparent = (value) => !value || value === 'transparent' || value === 'rgba(0, 0, 0, 0)';
          let node = document.body;
          while (node) {
            const value = getComputedStyle(node).backgroundColor;
            if (!transparent(value)) return value;
            node = node.parentElement;
          }
          return matchMedia('(prefers-color-scheme: dark)').matches ? 'rgb(28, 28, 30)' : 'rgb(255, 255, 255)';
        })()
        """
        guard let css = try? await webView.evaluateJavaScript(script) as? String,
              let color = NSColor(cssRGB: css),
              let index = tabs.firstIndex(where: { $0.id == tabID && $0.webView === webView }) else { return }
        tabs[index].pageBackgroundColor = color
        webView.underPageBackgroundColor = color
    }

    private func loadFavicon(for tabID: UUID, from webView: WKWebView) async {
        guard let pageURL = webView.url else { return }
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]')];
          return links.map(link => link.href).find(Boolean) || null;
        })()
        """
        let result = try? await webView.evaluateJavaScript(script)
        let discovered = result as? String
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        let faviconURL = discovered.flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } ?? fallback
        guard let faviconURL,
              let (data, response) = try? await URLSession.shared.data(from: faviconURL),
              (response as? HTTPURLResponse).map({ 200..<400 ~= $0.statusCode }) != false,
              let image = NSImage(data: data),
              let index = tabs.firstIndex(where: { $0.id == tabID && $0.webView === webView }) else { return }
        tabs[index].favicon = image
        FaviconCache.shared.store(image, for: pageURL)
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let description = (error as NSError).description
        Task { @MainActor in
            NSLog("Aircraft: provisional navigation failed: %@", description)
            if let index = self.tabs.firstIndex(where: { $0.webView === webView }) {
                self.tabs[index].isLoading = false
            }
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            if let index = self.tabs.firstIndex(where: { $0.webView === webView }) {
                self.tabs[index].isLoading = false
            }
        }
    }

    // MARK: - Загрузки

    nonisolated public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Адрес приложения (zoommtg://, tg://, mailto:…) — WebKit его не откроет: спрашиваем и отдаём приложению.
        if let url = navigationAction.request.url, AppLinks.isExternal(url) {
            MainActor.assumeIsolated {
                let handled = handleExternalNavigation(url, from: webView,
                                                       userClicked: navigationAction.navigationType == .linkActivated)
                decisionHandler(handled ? .cancel : .allow, preferences)
            }
            return
        }
        // <a download>, blob:- и data:-ссылки на файл — скачиваем, а не открываем.
        // ⌘-клик по ссылке — открыть её в фоновой вкладке справа от текущей.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            MainActor.assumeIsolated {
                let openerID = tabs.first(where: { $0.webView === webView })?.id
                createNewTab(url: url, selectNewTab: false, afterTabID: openerID, openedByPage: true)
                decisionHandler(.cancel, preferences)
            }
            return
        }
        // Ссылка на локальный .md или .pdf — во встроенный просмотрщик.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url, url.isFileURL,
           Self.viewerContent(forLocal: url) != nil {
            MainActor.assumeIsolated {
                if let index = tabs.firstIndex(where: { $0.webView === webView }) {
                    tabs[index].url = url
                    tabs[index].title = url.lastPathComponent
                    load(url, in: webView, tabID: tabs[index].id)
                }
                decisionHandler(.cancel, preferences)
            }
            return
        }
        // Защита от трекеров: убираем метки отслеживания (utm_*, fbclid, gclid…) из адреса страницы.
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.httpMethod == "GET",
           let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            let cleaned: URL? = MainActor.assumeIsolated {
                AdBlocker.shared.blocksTrackers && !AdBlocker.shared.isAllowed(host: url.host)
                    ? AdBlocker.cleanedURL(url) : nil
            }
            if let cleaned {
                MainActor.assumeIsolated {
                    decisionHandler(.cancel, preferences)
                    webView.load(URLRequest(url: cleaned))
                }
                return
            }
        }
        let policy: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? .download : .allow
        MainActor.assumeIsolated { decisionHandler(policy, preferences) }
    }

    nonisolated public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        var policy: WKNavigationResponsePolicy = navigationResponse.canShowMIMEType ? .allow : .download
        var isAttachment = false
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            policy = .download
            isAttachment = true
        }
        let response = navigationResponse.response
        let isMainFrame = navigationResponse.isForMainFrame
        MainActor.assumeIsolated {
            // PDF и Markdown открываются во встроенных просмотрщиках: файл скачивается
            // через сессию страницы (работает и за логином), вкладка показывает его.
            if isMainFrame, !isAttachment, let viewer = Self.remoteViewerKind(for: response),
               let tabID = tabs.first(where: { $0.webView === webView })?.id {
                pendingViewerDownloads[tabID] = (viewer, response.url)
                decisionHandler(.download)
                return
            }
            decisionHandler(policy)
        }
    }

    nonisolated public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated {
            download.delegate = self
            if let tabID = tabs.first(where: { $0.webView === webView })?.id,
               let pending = pendingViewerDownloads.removeValue(forKey: tabID) {
                viewerDownloads[ObjectIdentifier(download)] = (tabID, pending.kind, pending.url)
            }
        }
    }

    nonisolated public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        MainActor.assumeIsolated {
            if viewerDownloads[ObjectIdentifier(download)] != nil {
                let folder = AircraftPaths.ensure(AircraftPaths.viewerCache.appendingPathComponent(UUID().uuidString, isDirectory: true))
                let name = suggestedFilename.replacingOccurrences(of: "/", with: "-")
                let destination = folder.appendingPathComponent(name.isEmpty ? "document" : name)
                downloadDestinations[ObjectIdentifier(download)] = destination
                completionHandler(destination)
                return
            }
            let destination = Self.downloadDestination(for: suggestedFilename)
            if let destination {
                downloadDestinations[ObjectIdentifier(download)] = destination
                DownloadStore.shared.started(download, destination: destination, source: response.url ?? download.originalRequest?.url)
                showToast("Загрузка: \(destination.lastPathComponent)", symbol: "arrow.down.circle")
            }
            completionHandler(destination)
        }
    }

    nonisolated public func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            if let viewer = viewerDownloads.removeValue(forKey: ObjectIdentifier(download)),
               let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                showViewer(viewer.kind, file: file, sourceURL: viewer.url, tabID: viewer.tabID)
                return
            }
            DownloadStore.shared.finished(download, success: true)
            guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            // Значок «Загрузки» в Dock подпрыгивает, как в Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    nonisolated public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            viewerDownloads.removeValue(forKey: ObjectIdentifier(download))
            DownloadStore.shared.finished(download, success: false)
            NSSound.beep()
        }
    }

    /// Папка из настроек или «Загрузки»; при совпадении имени добавляется « (2)», « (3)»…
    private static func downloadDestination(for suggestedFilename: String) -> URL? {
        let fileManager = FileManager.default
        let configured = UserDefaults.standard.string(forKey: "downloadFolderPath") ?? ""
        let folder = configured.isEmpty
            ? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            : URL(fileURLWithPath: configured, isDirectory: true)
        guard let folder else { return nil }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let cleanName = suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let name = cleanName.isEmpty ? "download" : cleanName
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    // MARK: - ScriptBridgeDelegate

    public func scriptBridge(_ bridge: ScriptBridge, didReceiveAction action: String, payload: [String : Any]) {
        switch action {
        case "toggleReaderMode":
            toggleReaderMode()
        case "closeTab":
            // Как ⌘W: закреплённые вкладки скрипты страниц не закрывают.
            closeActiveTabFromShortcut()
        case "newTab":
            createNewTab()
        case "reloadTab":
            reloadActiveTab()
        case "openSpotlight":
            NotificationCenter.default.post(name: .showCurrentURLSpotlight, object: NSApp.keyWindow)
        case "openSettings":
            NotificationCenter.default.post(name: .openSettings, object: NSApp.keyWindow)
        case "openTab":
            let value = payload["url"] as? String ?? ""
            let defaults = Foundation.UserDefaults.standard
            let template = SearchEngineOption.queryTemplate(
                for: defaults.string(forKey: "searchEngine") ?? "duckduckgo",
                customURL: defaults.string(forKey: "customSearchURL") ?? ""
            )
            let url = value.isEmpty ? nil : URLRouter.navigationTarget(input: value, searchTemplate: template).flatMap(URL.init(string:))
            createNewTab(url: url, selectNewTab: true)
        case "enableDevTools":
            activeWebView?.isInspectable = true
        case "modStorageSet":
            if let key = payload["key"] as? String, let value = payload["value"] {
                ScriptBridge.setStoredValue(value, for: key)
                NotificationCenter.default.post(name: .modStorageDidChange, object: nil, userInfo: ["key": key, "value": value])
            }
        case "modStorageRemove":
            if let key = payload["key"] as? String {
                ScriptBridge.removeStoredValue(for: key)
                NotificationCenter.default.post(name: .modStorageDidChange, object: nil, userInfo: ["key": key])
            }
        case "registerCapability":
            if let capability = payload["capability"] as? String {
                loadedModCapabilities.insert(capability)
                refreshInstalledModCapabilities()
            }
        default:
            print("Получена нераспознанная команда JS: \(action) с данными: \(payload)")
        }
    }
}

private extension NSColor {
    convenience init?(cssRGB value: String) {
        let numbers = value.split(whereSeparator: { !("0123456789.".contains($0)) }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        self.init(
            calibratedRed: numbers[0] / 255,
            green: numbers[1] / 255,
            blue: numbers[2] / 255,
            alpha: numbers.count > 3 ? numbers[3] : 1
        )
    }
}
