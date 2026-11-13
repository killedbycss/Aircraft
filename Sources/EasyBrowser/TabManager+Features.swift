import Foundation
import WebKit
import AppKit
import ObjectiveC

public struct FindBarState: Equatable {
    public var isVisible = false
    public var query = ""
    public var current = 0
    public var total = 0
    /// Меняется, когда поле поиска нужно снова сфокусировать (повторный ⌘F).
    public var focusToken = UUID()
}

public struct ToastMessage: Equatable, Identifiable {
    public var id = UUID()
    public var text: String
    public var symbol: String
}

extension TabManager {
    // MARK: Хранилища текущего контекста

    /// Cookie и данные сайтов: профиль окна или память (инкогнито).
    var websiteDataStore: WKWebsiteDataStore {
        isIncognito ? incognitoStore : ProfileStore.shared.dataStore(for: profileID)
    }

    /// История профиля; в инкогнито её нет.
    public var history: HistoryStore? {
        isIncognito ? nil : ProfileStore.shared.history(for: profileID)
    }

    /// Закладки: в инкогнито — закладки профиля по умолчанию (читать и добавлять можно).
    public var bookmarks: BookmarkStore {
        ProfileStore.shared.bookmarks(for: profileID)
    }

    /// Настройки сайтов: в инкогнито — копия в памяти, изменения не сохраняются.
    public var siteSettings: SiteSettingsStore {
        isIncognito ? incognitoSites : ProfileStore.shared.sites(for: profileID)
    }

    public var archive: TabArchive? {
        isIncognito ? nil : ProfileStore.shared.archive(for: profileID)
    }

    public var profile: Profile { ProfileStore.shared.profile(profileID) }

    public func showToast(_ text: String, symbol: String) {
        let message = ToastMessage(text: text, symbol: symbol)
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if self?.toast?.id == message.id { self?.toast = nil }
        }
    }

    // MARK: ⌥← / ⌥→

    /// Соседняя вкладка в порядке отображения, по кругу.
    public func selectAdjacentTab(offset: Int) {
        let order = tree.visibleTabIDs
        guard order.count > 1 else { return }
        let current = activeTabID.flatMap { order.firstIndex(of: $0) } ?? 0
        let next = ((current + offset) % order.count + order.count) % order.count
        selectTab(id: order[next])
    }

    /// Стоит ли фокус в поле ввода на странице активной вкладки.
    public var activePageHasEditableFocus: Bool {
        guard let activeTabID else { return false }
        return editableFocusTabs.contains(activeTabID)
    }

    // MARK: ⌘⇧C

    public func copyActiveURL() {
        guard let url = activeTab?.url else {
            NSSound.beep()
            return
        }
        let clean = AdBlocker.cleanedURL(url) ?? url
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clean.absoluteString, forType: .string)
        showToast("Ссылка скопирована", symbol: "link")
    }

    // MARK: Масштаб

    static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    public func zoom(by step: Int) {
        guard let tab = activeTab, let webView = tab.webView else { return }
        let current = webView.pageZoom
        let levels = Self.zoomLevels
        let target: Double
        if step > 0 {
            target = levels.first { $0 > current + 0.001 } ?? levels.last!
        } else {
            target = levels.last { $0 < current - 0.001 } ?? levels.first!
        }
        setZoom(target, host: tab.url?.host)
    }

    public func resetZoom() {
        setZoom(1, host: activeTab?.url?.host)
    }

    private func setZoom(_ value: Double, host: String?) {
        siteSettings.setZoom(value, for: host)
        let key = SiteSettingsStore.key(host)
        for tab in tabs where SiteSettingsStore.key(tab.url?.host) == key {
            tab.webView?.pageZoom = value
        }
        if host == nil { activeTab?.webView?.pageZoom = value }
        showToast("\(Int((value * 100).rounded())) %", symbol: "plus.magnifyingglass")
    }

    func applyZoom(to webView: WKWebView) {
        let value = siteSettings.zoom(for: webView.url?.host)
        if abs(webView.pageZoom - value) > 0.001 { webView.pageZoom = value }
    }

    // MARK: Недавно закрытые (⌘⇧T)

    func closedRecord(for id: UUID) -> ClosedTab? {
        guard let tab = tabs.first(where: { $0.id == id }), tab.url != nil else { return nil }
        let location = tree.location(of: id)
        let state = (tab.webView?.interactionState as? Data) ?? tab.interactionState
        let saved = SavedTab(id: UUID(), title: tab.title, url: tab.url, isPinned: tab.isPinned, pinnedURL: tab.pinnedURL,
                             lastActiveAt: tab.lastActiveAt, interactionState: tab.content == .web ? state : nil)
        return ClosedTab(id: UUID(), tab: saved, closedAt: Date(), zone: location?.container.zone ?? .regular,
                         folderID: location?.container.folderID, index: location?.index ?? 0)
    }

    public func reopenClosedTab() {
        guard let record = closedTabs.popLast() else {
            NSSound.beep()
            return
        }
        restore(record)
    }

    public func reopenClosedTab(_ id: UUID) {
        guard let index = closedTabs.firstIndex(where: { $0.id == id }) else { return }
        restore(closedTabs.remove(at: index))
    }

    /// Возвращает вкладку на прежнее место (в ту же папку, если она ещё есть) с историей переходов.
    func restore(_ record: ClosedTab) {
        var tab = TabModel(id: UUID(), title: record.tab.title, url: record.tab.url, isLoading: false,
                           isHibernated: true, isPinned: record.zone != .regular,
                           pinnedURL: record.zone != .regular ? (record.tab.pinnedURL ?? record.tab.url) : nil)
        tab.interactionState = record.tab.interactionState
        if let url = record.tab.url, let viewer = Self.viewerContent(forLocal: url) { tab.content = viewer }
        tabs.append(tab)
        let container: SidebarContainer
        if let folderID = record.folderID, tree.folder(folderID) != nil {
            container = SidebarContainer(zone: record.zone, folderID: folderID)
        } else {
            container = SidebarContainer(zone: record.zone, folderID: nil)
        }
        if !tree.insert(.tab(tab.id), into: container, at: record.index) {
            tree.appendTab(tab.id)
        }
        syncPinnedFlags()
        syncTabOrder()
        selectTab(id: tab.id)
        saveSession()
    }

    // MARK: Звук

    public func toggleMute(id: UUID? = nil) {
        guard let id = id ?? activeTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isMuted.toggle()
        applyTabMediaState(id: id)
        if id == activeTabID {
            showToast(tabs[index].isMuted ? "Звук выключен" : "Звук включён",
                      symbol: tabs[index].isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
    }

    public func muteOtherTabs(except id: UUID) {
        for index in tabs.indices where tabs[index].id != id && tabs[index].isPlayingAudio {
            tabs[index].isMuted = true
            applyTabMediaState(id: tabs[index].id)
        }
    }

    func applyTabMediaState(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), let webView = tab.webView else { return }
        WebKitPrivate.setMuted(tab.isMuted, webView: webView)
    }

    // MARK: Поиск по странице (⌘F)

    public func showFindBar() {
        guard activeTab?.url != nil else { return }
        findBar.isVisible = true
        findBar.focusToken = UUID()
        if let selection = NSPasteboard(name: .find).string(forType: .string), findBar.query.isEmpty {
            findBar.query = selection
        }
        if !findBar.query.isEmpty { updateFind(query: findBar.query) }
    }

    public func closeFindBar() {
        findBar.isVisible = false
        findBar.current = 0
        findBar.total = 0
        activeTab?.webView?.evaluateJavaScript("window.getSelection().removeAllRanges()", in: nil, in: .defaultClient)
        NotificationCenter.default.post(name: .pdfFind, object: self, userInfo: ["query": ""])
    }

    public func updateFind(query: String) {
        findBar.query = query
        NSPasteboard(name: .find).clearContents()
        NSPasteboard(name: .find).setString(query, forType: .string)
        guard let tab = activeTab else { return }
        if case .pdf = tab.content {
            NotificationCenter.default.post(name: .pdfFind, object: self, userInfo: ["query": query])
            return
        }
        guard let webView = tab.webView else { return }
        guard !query.isEmpty else {
            findBar.current = 0
            findBar.total = 0
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()", in: nil, in: .defaultClient)
            return
        }
        Task { @MainActor in
            let total = await Self.countMatches(of: query, in: webView)
            guard findBar.query == query else { return }
            findBar.total = total
            findBar.current = 0
            if total > 0 { find(forward: true) }
        }
    }

    public func find(forward: Bool) {
        guard let tab = activeTab else { return }
        if case .pdf = tab.content {
            NotificationCenter.default.post(name: .pdfFind, object: self,
                                            userInfo: ["query": findBar.query, "backwards": !forward, "step": true])
            return
        }
        guard let webView = tab.webView, !findBar.query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findBar.query, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, result.matchFound, self.findBar.total > 0 else { return }
                let total = self.findBar.total
                if forward {
                    self.findBar.current = self.findBar.current % total + 1
                } else {
                    self.findBar.current = self.findBar.current <= 1 ? total : self.findBar.current - 1
                }
            }
        }
    }

    private static func countMatches(of query: String, in webView: WKWebView) async -> Int {
        let script = """
        const text = (document.body ? document.body.innerText : '').toLocaleLowerCase();
        const needle = query.toLocaleLowerCase();
        if (!needle) return 0;
        let count = 0, index = text.indexOf(needle);
        while (index !== -1 && count < 9999) { count++; index = text.indexOf(needle, index + needle.length); }
        return count;
        """
        let value = try? await webView.callAsyncJavaScript(script, arguments: ["query": query], in: nil, contentWorld: .defaultClient)
        return (value as? NSNumber)?.intValue ?? 0
    }

    // MARK: Файлы и просмотрщики

    /// Локальный PDF или Markdown открывается во встроенном просмотрщике.
    nonisolated static func viewerContent(forLocal url: URL) -> TabContent? {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf(url)
        case "md", "markdown", "mdown", "mkd": return .markdown(url)
        default: return nil
        }
    }

    /// Загрузка адреса во вкладку: локальные файлы получают доступ к своей папке.
    func load(_ url: URL, in webView: WKWebView, tabID: UUID) {
        if url.isFileURL {
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                let viewer = Self.viewerContent(forLocal: url) ?? .web
                tabs[index].content = viewer
                if case .markdown = viewer {
                    MarkdownViewer.render(file: url, in: webView)
                    return
                }
                tabs[index].content = viewer
                if case .pdf = viewer { return }
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Открывает файлы (⌘O, перетаскивание, «Открыть в Aircraft»).
    public func openFiles(_ urls: [URL]) {
        for (offset, url) in urls.enumerated() {
            if offset == 0, let active = activeTab, active.url == nil {
                navigateActiveTab(to: url.absoluteString)
            } else {
                createNewTab(url: url, selectNewTab: offset == 0, afterTabID: activeTabID)
            }
        }
    }
}

extension Notification.Name {
    /// Поиск в PDF-просмотрщике: userInfo["query"], ["backwards"], ["step"].
    static let pdfFind = Notification.Name("AircraftPDFFind")
}

// MARK: - Сигналы со страницы

/// Скрипт в изолированном мире: сообщает о фокусе в полях ввода и о картинке в картинке.
/// Страница не видит этот мир и не может подделать сообщения в нём.
@MainActor
final class PageSignals: NSObject, WKScriptMessageHandler {
    static let name = "aircraftSignals"
    weak var manager: TabManager?

    func install(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.name)
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .defaultClient))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let manager, let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView,
              let index = manager.tabs.firstIndex(where: { $0.webView === webView }) else { return }
        let id = manager.tabs[index].id
        switch type {
        case "focus":
            if body["editable"] as? Bool == true { manager.editableFocusTabs.insert(id) }
            else { manager.editableFocusTabs.remove(id) }
        case "pip":
            manager.tabs[index].isInPictureInPicture = body["active"] as? Bool == true
        case "reader":
            manager.tabs[index].isReaderActive = body["active"] as? Bool == true
        case "readerSettings":
            if let settings = body["settings"] as? [String: Any] { ReaderMode.settings = settings }
        default:
            break
        }
    }

    private static let source = """
    (() => {
      const post = (message) => { try { window.webkit.messageHandlers.aircraftSignals.postMessage(message); } catch (e) {} };
      const textTypes = ['text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date', 'datetime-local', 'month', 'time', 'week'];
      const editable = (el) => {
        if (!el) return false;
        if (el.isContentEditable) return true;
        if (el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') return true;
        if (el.tagName === 'INPUT') return textTypes.includes((el.type || 'text').toLowerCase());
        return false;
      };
      let last = null;
      const report = () => {
        const value = editable(document.activeElement);
        if (value !== last) { last = value; post({ type: 'focus', editable: value }); }
      };
      addEventListener('focusin', report, true);
      addEventListener('focusout', () => setTimeout(report, 0), true);
      addEventListener('pageshow', report, true);
      document.addEventListener('enterpictureinpicture', () => post({ type: 'pip', active: true }), true);
      document.addEventListener('leavepictureinpicture', () => post({ type: 'pip', active: false }), true);
      document.addEventListener('webkitpresentationmodechanged', (event) => {
        post({ type: 'pip', active: event.target && event.target.webkitPresentationMode === 'picture-in-picture' });
      }, true);
    })();
    """
}

// MARK: - Приватные API WebKit

/// Вызовы приватных методов WebKit с проверкой, что метод существует.
@MainActor
enum WebKitPrivate {
    /// `-[WKWebView _setPageMuted:]`, бит 0 — звук.
    static func setMuted(_ muted: Bool, webView: WKWebView) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(webView, selector, muted ? 1 : 0)
    }

    static var canObservePlayingAudio: Bool {
        WKWebView.instancesRespond(to: NSSelectorFromString("_isPlayingAudio"))
    }
}

/// Классический KVO для приватных свойств, у которых нет Swift key path.
final class KeyValueToken: NSObject {
    private weak var object: NSObject?
    private let keyPath: String
    private let handler: (Any?) -> Void

    init(object: NSObject, keyPath: String, handler: @escaping (Any?) -> Void) {
        self.object = object
        self.keyPath = keyPath
        self.handler = handler
        super.init()
        object.addObserver(self, forKeyPath: keyPath, options: [.initial, .new], context: nil)
    }

    func invalidate() {
        object?.removeObserver(self, forKeyPath: keyPath)
        object = nil
    }

    deinit { invalidate() }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        handler(change?[.newKey])
    }
}

// MARK: - Картинка в картинке

extension TabManager {
    /// Самое крупное (лучше играющее) видео на странице уходит в картинку в картинке или возвращается.
    /// Вызов из приложения WebKit засчитывает как жест пользователя.
    public func togglePictureInPicture(id: UUID? = nil, enterOnly: Bool = false) {
        guard let id = id ?? activeTabID, let webView = tabs.first(where: { $0.id == id })?.webView else { return }
        let script = """
        const videos = [...document.querySelectorAll('video')].filter(v => v.readyState > 0);
        const active = document.pictureInPictureElement || videos.find(v => v.webkitPresentationMode === 'picture-in-picture');
        if (active) {
          if (enterOnly) return 'on';
          if (document.pictureInPictureElement) await document.exitPictureInPicture();
          else active.webkitSetPresentationMode('inline');
          return 'off';
        }
        if (!videos.length) return 'none';
        const playing = videos.filter(v => !v.paused);
        if (enterOnly && !playing.length) return 'none';
        const area = v => v.clientWidth * v.clientHeight;
        const pick = (playing.length ? playing : videos).sort((a, b) => area(b) - area(a))[0];
        try {
          if (pick.requestPictureInPicture) { await pick.requestPictureInPicture(); return 'on'; }
        } catch (e) {}
        try { pick.webkitSetPresentationMode('picture-in-picture'); return 'on'; } catch (e) { return 'error'; }
        """
        Task { @MainActor in
            let result = try? await webView.callAsyncJavaScript(script, arguments: ["enterOnly": enterOnly], in: nil, contentWorld: .page)
            if (result as? String) == "none", !enterOnly {
                showToast("На странице нет видео", symbol: "pip")
            }
        }
    }

    /// Автоматическая картинка в картинке при уходе с вкладки, где играет видео (настройка).
    static var autoPictureInPicture: Bool { UserDefaults.standard.bool(forKey: "autoPictureInPicture") }
}

// MARK: - Просмотрщики для файлов из сети

public enum ViewerKind: Sendable {
    case pdf, markdown
}

extension TabManager {
    nonisolated static func remoteViewerKind(for response: URLResponse) -> ViewerKind? {
        let mime = response.mimeType?.lowercased() ?? ""
        let ext = response.url?.pathExtension.lowercased() ?? ""
        if mime == "application/pdf" || (ext == "pdf" && mime == "application/octet-stream") {
            return UserDefaults.standard.object(forKey: "pdfViewerEnabled") as? Bool ?? true ? .pdf : nil
        }
        if mime == "text/markdown" || mime == "text/x-markdown" ||
            (["md", "markdown"].contains(ext) && (mime.hasPrefix("text/") || mime == "application/octet-stream")) {
            return .markdown
        }
        return nil
    }

    func showViewer(_ kind: ViewerKind, file: URL, sourceURL: URL?, tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if case .pdf(let old) = tabs[index].content, old != file { try? FileManager.default.removeItem(at: old) }
        tabs[index].url = sourceURL ?? file
        tabs[index].title = sourceURL?.lastPathComponent.removingPercentEncoding ?? file.lastPathComponent
        tabs[index].isLoading = false
        switch kind {
        case .pdf:
            tabs[index].content = .pdf(file)
            if let url = sourceURL { history?.recordVisit(url: url, title: tabs[index].title) }
        case .markdown:
            tabs[index].content = .markdown(file)
            if let webView = tabs[index].webView { MarkdownViewer.render(file: file, in: webView, baseURL: sourceURL) }
        }
        saveSession()
    }
}
