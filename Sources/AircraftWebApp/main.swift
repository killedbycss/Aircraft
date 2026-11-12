import AppKit
import WebKit

// aircraft-webapp — сайт как отдельное приложение («Добавить в Dock» в Aircraft).
//
// Aircraft копирует этот бинарник в `~/Applications/Aircraft Apps/<Имя>.app` и пишет
// адрес сайта в Info.plist (ключ AircraftWebAppURL). У каждого такого приложения свой
// bundle ID, поэтому у него свои cookie и входы на сайты, своя иконка в Dock и свой процесс.
// Ссылки на другие сайты открываются в Aircraft.

@MainActor
final class WebAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var windows: [NSWindow] = []
    private let startURL: URL
    private let appName: String
    private let homeHost: String

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let raw = info["AircraftWebAppURL"] as? String ?? "https://example.com"
        startURL = URL(string: raw) ?? URL(string: "https://example.com")!
        appName = info["CFBundleName"] as? String ?? "Web App"
        homeHost = Self.baseDomain(startURL.host ?? "")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        openWindow(url: startURL)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Окна

    @discardableResult
    private func openWindow(url: URL?, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let config = configuration ?? WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.title = appName
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        if windows.isEmpty {
            window.setFrameAutosaveName("AircraftWebAppWindow")
            if window.frame.origin == .zero { window.center() }
        } else if let last = windows.last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.removeAll { $0 === window } }
        }
        titleObservers.append(webView.observe(\.title, options: [.new]) { [weak window] webView, _ in
            MainActor.assumeIsolated {
                if let title = webView.title, !title.isEmpty { window?.title = title }
            }
        })
        if let url { webView.load(URLRequest(url: url)) }
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    private var titleObservers: [NSKeyValueObservation] = []

    private var activeWebView: WKWebView? { NSApp.keyWindow?.contentView as? WKWebView }

    // MARK: Меню

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "Вид")
        view.addItem(withTitle: "Назад", action: #selector(goBack), keyEquivalent: "[")
        view.addItem(withTitle: "Вперёд", action: #selector(goForward), keyEquivalent: "]")
        view.addItem(withTitle: "Обновить", action: #selector(reload), keyEquivalent: "r")
        view.addItem(withTitle: "Домой", action: #selector(goHome), keyEquivalent: "H")
        view.addItem(.separator())
        view.addItem(withTitle: "Увеличить", action: #selector(zoomIn), keyEquivalent: "=")
        view.addItem(withTitle: "Уменьшить", action: #selector(zoomOut), keyEquivalent: "-")
        view.addItem(withTitle: "Реальный размер", action: #selector(zoomReset), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "Открыть в Aircraft", action: #selector(openInAircraft), keyEquivalent: "o")
        view.addItem(withTitle: "Скопировать ссылку", action: #selector(copyLink), keyEquivalent: "C")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Окно")
        window.addItem(withTitle: "Новое окно", action: #selector(newWindow), keyEquivalent: "n")
        window.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Свернуть", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    @objc private func goBack() { activeWebView?.goBack() }
    @objc private func goForward() { activeWebView?.goForward() }
    @objc private func reload() { activeWebView?.reload() }
    @objc private func goHome() { activeWebView?.load(URLRequest(url: startURL)) }
    @objc private func zoomIn() { activeWebView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc private func zoomOut() { activeWebView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc private func zoomReset() { activeWebView?.pageZoom = 1 }
    @objc private func newWindow() { openWindow(url: startURL) }
    @objc private func openInAircraft() { if let url = activeWebView?.url { openExternally(url) } }
    @objc private func copyLink() {
        guard let url = activeWebView?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: Ссылки на другие сайты — в Aircraft

    private static func baseDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    private func isHome(_ url: URL) -> Bool {
        guard let host = url.host else { return true }
        return Self.baseDomain(host) == homeHost
    }

    private func openExternally(_ url: URL) {
        if let aircraft = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.taras.aircraft") {
            NSWorkspace.shared.open([url], withApplicationAt: aircraft, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            // Пользователь перешёл по ссылке на другой сайт — открываем в браузере.
            if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true, !isHome(url) {
                openExternally(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let canShow = navigationResponse.canShowMIMEType
        MainActor.assumeIsolated { decisionHandler(canShow ? .allow : .download) }
    }

    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true, !isHome(url),
               windowFeatures.width == nil {
                openExternally(url)
                return nil
            }
            // Окна входа и ссылки этого сайта — новым окном приложения.
            return openWindow(url: nil, configuration: configuration)
        }
    }

    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated { webView.window?.close() }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
            completionHandler()
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Отмена")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    nonisolated func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                             initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                             decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        MainActor.assumeIsolated { decisionHandler(.prompt) }
    }

    // MARK: Загрузки — в «Загрузки»

    nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                              completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        MainActor.assumeIsolated {
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            var target = folder.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (suggestedFilename as NSString).deletingPathExtension
                let ext = (suggestedFilename as NSString).pathExtension
                target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)")
                number += 1
            }
            completionHandler(target)
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { WebAppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
