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
    public var isReaderModeActive: Bool = false
    /// Tabs shown in split mode. `activeTabID` is the pane receiving commands.
    public var splitPrimaryTabID: UUID?
    public var splitTabID: UUID?
    public var modCapabilities: Set<String> = []
    /// A capability is advertised only after its script has actually run in a page.
    /// This prevents menu entries for a copied-but-broken modification.
    public var loadedModCapabilities: Set<String> = []

    private let scriptBridge = ScriptBridge()
    private var storageObserver: NSObjectProtocol?
    private var userScriptRefreshTask: Task<Void, Never>?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Из какой вкладки открыта вкладка — чтобы новые вставали подряд справа от «родителя».
    private var openedFrom: [UUID: UUID] = [:]
    private var webViewObservers: [UUID: [NSKeyValueObservation]] = [:]
    private var mobileBrowsing = false
    private static let sessionKey = "browserSessionV1"

    private struct SavedSession: Codable {
        var tabs: [SavedTab]
        var activeTabID: UUID?
    }

    private struct SavedTab: Codable {
        var id: UUID
        var title: String
        var url: URL?
        var isPinned: Bool
        var pinnedURL: URL?
    }

    public override init() {
        super.init()
        scriptBridge.delegate = self
        restoreSession()
        refreshInstalledModCapabilities()
        storageObserver = NotificationCenter.default.addObserver(forName: .modStorageDidChange, object: nil, queue: .main) { [weak self] notification in
            // Готовим JS-строку здесь, чтобы не передавать Any между потоками.
            let script = (notification.userInfo?["key"] as? String).flatMap {
                ScriptBridge.syncScript(key: $0, value: notification.userInfo?["value"])
            }
            MainActor.assumeIsolated { self?.applyModStorageChange(syncScript: script) }
        }
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
                self.scriptBridge.configure(userContentController: controller)
                self.loadCustomModifications(into: controller)
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

    public var canGoBack: Bool { activeTab?.webView?.canGoBack == true }
    public var canGoForward: Bool { activeTab?.webView?.canGoForward == true }

    // MARK: - Управление вкладками

    @discardableResult
    public func createNewTab(url: URL? = nil, selectNewTab: Bool = true, afterTabID: UUID? = nil) -> UUID {
        let previouslyFocusedID = activeTabID
        let webView = url == nil ? nil : createWebView()

        let newTab = TabModel(
            id: UUID(),
            title: "Новая вкладка",
            url: url,
            isLoading: url != nil,
            isHibernated: url != nil && webView == nil,
            isPinned: false,
            pinnedURL: nil,
            favicon: nil,
            webView: webView
        )

        insertTab(newTab, after: afterTabID)
        if let webView { setupObservations(for: newTab.id, webView: webView) }

        if selectNewTab || activeTabID == nil {
            if splitPrimaryTabID != nil, splitTabID != nil {
                if previouslyFocusedID == splitTabID { splitTabID = newTab.id }
                else { splitPrimaryTabID = newTab.id }
            }
            activeTabID = newTab.id
        }

        if let url, let webView { webView.load(URLRequest(url: url)) }
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
        activeTabID = id
        if let tab = tabs.first(where: { $0.id == id }), (tab.isHibernated || tab.webView == nil) {
            if tab.url != nil { restoreTab(id: id) }
        }
        saveSession()
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        removeObservations(for: id)
        openedFrom.removeValue(forKey: id)
        let tabToClose = tabs[index]
        tabToClose.webView?.stopLoading()
        tabToClose.webView?.navigationDelegate = nil
        tabToClose.webView?.uiDelegate = nil

        tabs.remove(at: index)
        if splitPrimaryTabID == id || splitTabID == id {
            let survivor = splitPrimaryTabID == id ? splitTabID : splitPrimaryTabID
            splitPrimaryTabID = nil
            splitTabID = nil
            if activeTabID == id { activeTabID = survivor }
        }

        if activeTabID == id {
            if tabs.indices.contains(index) {
                activeTabID = tabs[index].id
            } else if let last = tabs.last {
                activeTabID = last.id
            } else {
                activeTabID = nil
                createNewTab()
                NotificationCenter.default.post(name: .showEmptySpotlight, object: nil)
            }
        }
        saveSession()
    }

    public func togglePinTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()
        tabs[index].pinnedURL = tabs[index].isPinned ? tabs[index].url : nil
        let tab = tabs.remove(at: index)
        if tab.isPinned {
            if let lastPinnedIndex = tabs.lastIndex(where: { $0.isPinned }) {
                tabs.insert(tab, at: lastPinnedIndex + 1)
            } else {
                tabs.insert(tab, at: 0)
            }
        } else {
            if let firstUnpinnedIndex = tabs.firstIndex(where: { !$0.isPinned }) {
                tabs.insert(tab, at: firstUnpinnedIndex)
            } else {
                tabs.append(tab)
            }
        }
        saveSession()
    }

    public func closeActiveTabFromShortcut() {
        guard let id = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].isPinned, let pinnedURL = tabs[index].pinnedURL {
            tabs[index].url = pinnedURL
            tabs[index].title = pinnedURL.host ?? "Закреплённая вкладка"
            if tabs[index].webView == nil { restoreTab(id: id) }
            tabs[index].webView?.load(URLRequest(url: pinnedURL))
            saveSession()
        } else {
            closeTab(id: id)
        }
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
        let event: String
        switch capability {
        case "historyAccounts": event = "aircraft:toggleHistoryAccounts"
        default: return
        }
        activeWebView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(event)'))")
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

        removeObservations(for: id)
        tabs[index].webView?.stopLoading()
        tabs[index].webView?.navigationDelegate = nil
        tabs[index].webView?.uiDelegate = nil
        tabs[index].webView = nil

        tabs[index].url = currentURL
        tabs[index].title = currentTitle
        tabs[index].isLoading = false
        tabs[index].isHibernated = true
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

        if let url = tab.url { webView.load(URLRequest(url: url)) }
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
        tabs[index].title = targetURL.host ?? "Новая вкладка"
        tabs[index].webView?.load(URLRequest(url: targetURL))
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
            for id in tabs.compactMap({ $0.url == nil ? nil : $0.id }) { hibernateTab(id: id) }
        case "webCache":
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {}
        default:
            for tab in tabs where tab.id != activeTabID && tab.url != nil { hibernateTab(id: tab.id) }
        }
    }

    private func saveSession() {
        let saved = SavedSession(
            tabs: tabs.map { SavedTab(id: $0.id, title: $0.title, url: $0.url, isPinned: $0.isPinned, pinnedURL: $0.pinnedURL) },
            activeTabID: activeTabID
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        Foundation.UserDefaults.standard.set(data, forKey: Self.sessionKey)
    }

    private func restoreSession() {
        guard let data = Foundation.UserDefaults.standard.data(forKey: Self.sessionKey),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              !saved.tabs.isEmpty else {
            createNewTab()
            return
        }
        tabs = saved.tabs.map {
            TabModel(
                id: $0.id,
                title: $0.title,
                url: $0.url,
                isLoading: false,
                isHibernated: $0.url != nil,
                isPinned: $0.isPinned,
                pinnedURL: $0.pinnedURL,
                favicon: nil,
                webView: nil
            )
        }
        activeTabID = tabs.contains(where: { $0.id == saved.activeTabID }) ? saved.activeTabID : tabs.first?.id
    }

    /// Recreates the web views so newly added CSS/JS modifications apply immediately.
    public func reloadCustomModifications() {
        loadedModCapabilities = []
        modCapabilities = []
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

    public func toggleReaderMode() {
        isReaderModeActive.toggle()
        guard let webView = activeWebView else { return }
        let css = isReaderModeActive ? """
        body { max-width: 800px !important; margin: 0 auto !important; font-family: -apple-system, sans-serif !important; line-height: 1.6 !important; background-color: #fbfbfb !important; color: #222 !important; padding: 20px !important; }
        nav, header, footer, sidebar, aside, .ad, .ads, .banner { display: none !important; }
        """ : ""

        let js = isReaderModeActive ? """
        (function() {
            var el = document.getElementById('easybrowser-reader-style');
            if (!el) {
                el = document.createElement('style');
                el.id = 'easybrowser-reader-style';
                el.innerHTML = `\(css)`;
                document.head.appendChild(el);
            }
        })();
        """ : """
        (function() {
            var el = document.getElementById('easybrowser-reader-style');
            if (el) { el.remove(); }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKWebView Factory

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = mobileBrowsing ? .mobile : .desktop
        scriptBridge.configure(userContentController: config.userContentController)
        loadCustomModifications(into: config.userContentController)

        let webView = WKWebView(frame: .zero, configuration: config)
        // This exposes the real WebKit inspector in Safari's Develop menu.
        // It is deliberately enabled only while the DevTools modification is loaded.
        webView.isInspectable = ModCatalog.isInstalled("aircraft-devtools-webextensions", in: installedModFiles())
        webView.underPageBackgroundColor = .windowBackgroundColor
        configureContentMode(for: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func configureContentMode(for webView: WKWebView) {
        webView.configuration.defaultWebpagePreferences.preferredContentMode = mobileBrowsing ? .mobile : .desktop
        webView.customUserAgent = mobileBrowsing ? Self.mobileUserAgent : nil
        webView.pageZoom = 1
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
        modCapabilities = loadedModCapabilities
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
                    self.saveSession()
                }
            }
        }

        let urlObs = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                if let url = webView.url {
                    self.tabs[index].url = url
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

        webViewObservers[tabID] = [titleObs, urlObs, loadingObs]
    }

    private func removeObservations(for tabID: UUID) {
        webViewObservers[tabID]?.forEach { $0.invalidate() }
        webViewObservers.removeValue(forKey: tabID)
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
                           openerTabID: tabs.first(where: { $0.webView === webView })?.id)
        }
    }

    /// Вкладка, открытая со страницы, встаёт сразу справа от неё (после уже открытых
    /// ею вкладок), а не в конец списка.
    private func insertTab(_ tab: TabModel, after openerID: UUID?) {
        guard let openerID, let openerIndex = tabs.firstIndex(where: { $0.id == openerID }) else {
            tabs.append(tab)
            return
        }
        var index = openerIndex + 1
        while index < tabs.count, openedFrom[tabs[index].id] == openerID { index += 1 }
        tabs.insert(tab, at: index)
        openedFrom[tab.id] = openerID
    }

    private func createPopupTab(configuration: WKWebViewConfiguration, url: URL?, openerTabID: UUID?) -> WKWebView {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.isInspectable = ModCatalog.isInstalled("aircraft-devtools-webextensions", in: installedModFiles())
        popup.underPageBackgroundColor = .windowBackgroundColor
        configureContentMode(for: popup)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let tabURL = (url?.absoluteString.isEmpty == false ? url : nil) ?? URL(string: "about:blank")
        let tab = TabModel(title: "Новая вкладка", url: tabURL, isLoading: true, webView: popup)
        insertTab(tab, after: openerTabID)
        setupObservations(for: tab.id, webView: popup)
        activeTabID = tab.id
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
                self.tabs[index].favicon = nil
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
                }
                self.saveSession()
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
        // <a download>, blob:- и data:-ссылки на файл — скачиваем, а не открываем.
        // ⌘-клик по ссылке — открыть её в фоновой вкладке справа от текущей.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            MainActor.assumeIsolated {
                let openerID = tabs.first(where: { $0.webView === webView })?.id
                createNewTab(url: url, selectNewTab: false, afterTabID: openerID)
                decisionHandler(.cancel, preferences)
            }
            return
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
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            policy = .download
        }
        MainActor.assumeIsolated { decisionHandler(policy) }
    }

    nonisolated public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        MainActor.assumeIsolated {
            let destination = Self.downloadDestination(for: suggestedFilename)
            if let destination { downloadDestinations[ObjectIdentifier(download)] = destination }
            completionHandler(destination)
        }
    }

    nonisolated public func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            // Значок «Загрузки» в Dock подпрыгивает, как в Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    nonisolated public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
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
            if let activeTabID = activeTabID { closeTab(id: activeTabID) }
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
