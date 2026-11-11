import AppKit
import WebKit

/// Реализация MCP-инструментов поверх вкладок Aircraft.
///
/// Вспомогательный JS выполняется в отдельном мире `.defaultClient`: он видит тот же DOM,
/// но страница не может подменить его функции. Код агента (`browser_evaluate`) и буфер
/// консоли живут в мире страницы `.page`.
@MainActor
final class AgentBrowser {
    struct Output {
        var content: [[String: Any]]
        var isError = false

        static func text(_ text: String) -> Output { Output(content: [["type": "text", "text": text]]) }
        static func error(_ text: String) -> Output { Output(content: [["type": "text", "text": text]], isError: true) }
        static func json(_ object: Any) -> Output {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return .text(String(decoding: data, as: UTF8.self))
        }
    }

    struct AgentError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Реестр окон

    private struct WeakManager {
        weak var value: TabManager?
    }

    private static var managers: [WeakManager] = []

    /// Каждое окно браузера регистрирует свой TabManager.
    static func register(_ manager: TabManager) {
        managers.removeAll { $0.value == nil }
        managers.append(WeakManager(value: manager))
    }

    /// Все открытые окна браузера.
    static var allManagers: [TabManager] {
        managers.removeAll { $0.value == nil }
        return managers.compactMap(\.value)
    }

    /// Окно браузера, которое ближе всего к пользователю (для окна настроек и пипетки).
    static var frontmostManager: TabManager? {
        managers.removeAll { $0.value == nil }
        let order = NSApp.orderedWindows
        func index(_ manager: TabManager) -> Int {
            let window = manager.tabs.lazy.compactMap { $0.webView?.window }.first
            return window.flatMap { order.firstIndex(of: $0) } ?? Int.max
        }
        return managers.compactMap(\.value).min { index($0) < index($1) }
    }

    private var liveManagers: [TabManager] {
        Self.managers.removeAll { $0.value == nil }
        let order = NSApp.orderedWindows
        return Self.managers.compactMap(\.value).sorted { lhs, rhs in
            let left = window(of: lhs).flatMap { order.firstIndex(of: $0) } ?? Int.max
            let right = window(of: rhs).flatMap { order.firstIndex(of: $0) } ?? Int.max
            return left < right
        }
    }

    private func window(of manager: TabManager) -> NSWindow? {
        manager.tabs.lazy.compactMap { $0.webView?.window }.first
    }

    private var frontManager: TabManager? {
        let managers = liveManagers
        if let key = NSApp.keyWindow, let manager = managers.first(where: { window(of: $0) === key }) { return manager }
        return managers.first
    }

    // MARK: Вызов инструмента

    func call(_ name: String, arguments: [String: Any]) async -> Output {
        do {
            return try await run(name, arguments)
        } catch let error as AgentError {
            return .error(error.message)
        } catch {
            return .error(Self.message(for: error))
        }
    }

    private func run(_ name: String, _ args: [String: Any]) async throws -> Output {
        switch name {
        case "browser_tabs": return listTabs()
        case "browser_open_tab": return try await openTab(args)
        case "browser_select_tab":
            let (manager, id) = try target(args, focus: true)
            AgentActivity.shared.mark(tabID: id, action: "Переключение вкладки")
            return .text("Selected tab \(id.uuidString): \(manager.tabs.first { $0.id == id }?.title ?? "")")
        case "browser_close_tab":
            let (manager, id) = try target(args, focus: false)
            manager.closeTab(id: id)
            return .text("Closed tab \(id.uuidString)")
        case "browser_fullscreen": return try await fullscreen(args)
        case "browser_navigate": return try await navigate(args)
        case "browser_history": return try await history(args)
        case "browser_snapshot": return try await snapshot(args)
        case "browser_get_text": return try await getText(args)
        case "browser_screenshot": return try await screenshot(args)
        case "browser_click": return try await click(args)
        case "browser_type": return try await type(args)
        case "browser_press_key": return try await pressKey(args)
        case "browser_scroll": return try await scroll(args)
        case "browser_select_option": return try await selectOption(args)
        case "browser_wait_for": return try await waitFor(args)
        case "browser_evaluate": return try await evaluate(args)
        case "browser_console": return try await console(args)
        default: throw AgentError("Unknown tool \(name)")
        }
    }

    // MARK: Вкладки и навигация

    private func listTabs() -> Output {
        let front = frontManager
        let windows: [[String: Any]] = liveManagers.enumerated().map { index, manager in
            [
                "window": index + 1,
                "front": manager === front,
                "tabs": manager.tabs.map { tab in
                    [
                        "tabId": tab.id.uuidString,
                        "title": tab.webView?.title ?? tab.title,
                        "url": (tab.webView?.url ?? tab.url)?.absoluteString ?? "",
                        "active": tab.id == manager.activeTabID,
                        "loading": tab.webView?.isLoading ?? false,
                        "pinned": tab.isPinned
                    ] as [String: Any]
                }
            ]
        }
        return .json(["windows": windows])
    }

    private func openTab(_ args: [String: Any]) async throws -> Output {
        guard let manager = frontManager else { throw AgentError("No browser window is open.") }
        let input = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = input.isEmpty ? nil : try Self.resolveURL(input)
        let background = args["background"] as? Bool ?? false
        let id = manager.createNewTab(url: url, selectNewTab: !background, afterTabID: manager.activeTabID)
        AgentActivity.shared.mark(tabID: id, action: "Новая вкладка")
        guard url != nil, let webView = manager.webView(for: id) else {
            return .text("Opened empty tab \(id.uuidString)")
        }
        await waitForLoad(webView)
        return .text("Opened tab \(id.uuidString)\n" + pageInfo(webView))
    }

    private func fullscreen(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        guard await waitForWindow(webView), let window = webView.window else {
            throw AgentError("The browser window is not on screen.")
        }
        let isFull = window.styleMask.contains(.fullScreen)
        let wantFull: Bool
        switch args["action"] as? String ?? "toggle" {
        case "enter": wantFull = true
        case "exit": wantFull = false
        case "toggle": wantFull = !isFull
        default: throw AgentError("action must be enter, exit or toggle")
        }
        guard wantFull != isFull else { return .text(isFull ? "Window is already fullscreen." : "Window is not fullscreen.") }
        AgentActivity.shared.mark(tabID: id, action: wantFull ? "Полный экран" : "Выход из полного экрана")
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.toggleFullScreen(nil)
        // Анимация перехода в полноэкранный режим длится около секунды.
        for _ in 0..<40 where window.styleMask.contains(.fullScreen) != wantFull {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let now = window.styleMask.contains(.fullScreen)
        guard now == wantFull else { throw AgentError("macOS did not change the fullscreen state.") }
        return .text((now ? "Window is now fullscreen." : "Window left fullscreen.") + "\n" + pageInfo(webView))
    }

    private func navigate(_ args: [String: Any]) async throws -> Output {
        guard let input = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            throw AgentError("url is required")
        }
        _ = try Self.resolveURL(input)
        let (manager, id) = try target(args, focus: true)
        AgentActivity.shared.mark(tabID: id, action: "Переход: \(input)")
        manager.navigateActiveTab(to: input)
        guard let webView = manager.webView(for: id) else { throw AgentError("Could not load \(input)") }
        await waitForLoad(webView)
        return .text(pageInfo(webView))
    }

    private func history(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        switch args["action"] as? String {
        case "back":
            guard webView.canGoBack else { throw AgentError("There is no previous page in this tab.") }
            webView.goBack()
        case "forward":
            guard webView.canGoForward else { throw AgentError("There is no next page in this tab.") }
            webView.goForward()
        case "reload":
            webView.reload()
        default:
            throw AgentError("action must be back, forward or reload")
        }
        AgentActivity.shared.mark(tabID: id, action: "Навигация")
        await settle(webView)
        return .text(pageInfo(webView))
    }

    // MARK: Чтение страницы

    private func snapshot(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        AgentActivity.shared.mark(tabID: id, action: "Читает страницу")
        let max = (args["maxElements"] as? Int).map { Swift.max(10, Swift.min($0, 2000)) } ?? 250
        let result = try await runJSON(webView, Self.snapshotScript, args: ["max": max])
        var text = "URL: \(result["url"] as? String ?? "")\nTitle: \(result["title"] as? String ?? "")\n"
        if let scroll = result["scroll"] as? [String: Any] {
            text += "Scroll: \(scroll["y"] ?? 0) of \(scroll["height"] ?? 0)px, viewport \(scroll["width"] ?? 0)×\(scroll["viewport"] ?? 0)\n"
        }
        if webView.isLoading { text += "(page is still loading)\n" }
        let lines = result["lines"] as? [String] ?? []
        text += lines.isEmpty ? "\nNo interactive elements found." : "\n" + lines.joined(separator: "\n")
        return .text(text)
    }

    private func getText(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        AgentActivity.shared.mark(tabID: id, action: "Читает текст")
        let offset = Swift.max(0, args["offset"] as? Int ?? 0)
        let maxChars = Swift.max(100, Swift.min(args["maxChars"] as? Int ?? 20_000, 200_000))
        let result = try await runJSON(webView, #"""
            const text = (document.body ? document.body.innerText : document.documentElement.innerText) || '';
            const slice = text.slice(args.offset, args.offset + args.max);
            return JSON.stringify({ total: text.length, text: slice, url: location.href, title: document.title });
            """#, args: ["offset": offset, "max": maxChars])
        let total = result["total"] as? Int ?? 0
        let chunk = result["text"] as? String ?? ""
        var header = "URL: \(result["url"] as? String ?? "")\nTitle: \(result["title"] as? String ?? "")\n"
        header += "Characters \(offset)–\(offset + chunk.count) of \(total)"
        if offset + chunk.count < total { header += " (call again with offset \(offset + chunk.count) for more)" }
        return .text(header + "\n\n" + chunk)
    }

    private func screenshot(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        AgentActivity.shared.mark(tabID: id, action: "Скриншот")
        guard await waitForWindow(webView) else { throw AgentError("The tab is not on screen, so it cannot be captured.") }
        try? await Task.sleep(for: .milliseconds(120))
        let image = try await webView.takeSnapshot(configuration: nil)
        let zoom = webView.pageZoom * webView.magnification
        // 1 пиксель скриншота = 1 CSS-пиксель, чтобы координаты подходили для browser_click.
        let cssSize = NSSize(width: webView.bounds.width / zoom, height: webView.bounds.height / zoom)
        let scale = min(1, 1600 / max(cssSize.width, 1))
        let pixelSize = NSSize(width: (cssSize.width * scale).rounded(), height: (cssSize.height * scale).rounded())
        guard let jpeg = Self.jpegData(image, size: pixelSize) else { throw AgentError("Could not encode the screenshot.") }
        var note = "Viewport \(Int(cssSize.width))×\(Int(cssSize.height)) CSS px. \(pageInfo(webView))"
        if scale < 1 { note += "\nImage is scaled by \(String(format: "%.3f", scale)); divide image coordinates by it for browser_click." }
        return Output(content: [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": note]
        ])
    }

    // MARK: Действия

    private func click(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        let count = (args["doubleClick"] as? Bool ?? false) ? 2 : 1
        var x: Double
        var y: Double
        var description = ""
        var warning = ""
        if let ax = Self.number(args["x"]), let ay = Self.number(args["y"]) {
            x = ax
            y = ay
            let info = try await runJSON(webView, #"""
                const el = document.elementFromPoint(args.x, args.y);
                return JSON.stringify({ desc: el ? describe(el) : 'nothing' });
                """#, args: ["x": x, "y": y])
            description = info["desc"] as? String ?? ""
        } else if args["ref"] != nil || args["text"] != nil {
            let info = try await runJSON(webView, Self.locateScript, args: [
                "ref": args["ref"] as? String ?? "",
                "text": args["text"] as? String ?? ""
            ])
            x = Self.number(info["x"]) ?? 0
            y = Self.number(info["y"]) ?? 0
            description = info["desc"] as? String ?? ""
            if let covered = info["covered"] as? String { warning = "\nNote: the element is covered by \(covered); the click went to that element." }
        } else {
            throw AgentError("Pass ref, text, or x and y.")
        }

        AgentActivity.shared.mark(tabID: id, action: "Клик: \(description)")
        var method = "native mouse events"
        if !(await waitForWindow(webView)) || !nativeClick(webView, x: x, y: y, count: count) {
            method = "JavaScript click()"
            _ = try await runJSON(webView, #"""
                const el = document.elementFromPoint(args.x, args.y);
                if (!el) return JSON.stringify({ error: 'Nothing to click at that point.' });
                for (let i = 0; i < args.count; i++) el.click();
                if (args.count === 2) el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
                return JSON.stringify({ ok: true });
                """#, args: ["x": x, "y": y, "count": count])
        }
        await settle(webView)
        return .text("Clicked \(description) at (\(Int(x)), \(Int(y))) using \(method).\(warning)\n\(pageInfo(webView))")
    }

    private func type(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        guard let text = args["text"] as? String else { throw AgentError("text is required") }
        AgentActivity.shared.mark(tabID: id, action: "Ввод текста")
        if let window = webView.window { window.makeFirstResponder(webView) }
        let result = try await runJSON(webView, Self.typeScript, args: [
            "ref": args["ref"] as? String ?? "",
            "text": text,
            "clear": args["clear"] as? Bool ?? true
        ])
        var output = "Typed into \(result["desc"] as? String ?? "element"). Value is now: \(result["value"] as? String ?? "")"
        if args["submit"] as? Bool == true {
            try await sendKey("Enter", to: webView)
            await settle(webView)
            output += "\nPressed Enter.\n" + pageInfo(webView)
        }
        return .text(output)
    }

    private func pressKey(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        guard let key = args["key"] as? String, !key.isEmpty else { throw AgentError("key is required") }
        AgentActivity.shared.mark(tabID: id, action: "Клавиша \(key)")
        let method = try await sendKey(key, to: webView)
        await settle(webView)
        return .text("Pressed \(key) using \(method).\n" + pageInfo(webView))
    }

    private func scroll(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        AgentActivity.shared.mark(tabID: id, action: "Прокрутка")
        let result = try await runJSON(webView, Self.scrollScript, args: [
            "ref": args["ref"] as? String ?? "",
            "direction": args["direction"] as? String ?? "down",
            "amount": Self.number(args["amount"]) ?? 0
        ])
        if let desc = result["desc"] as? String { return .text("Scrolled \(desc) into view.") }
        return .text("Scrolled. Position \(result["y"] ?? 0) of \(result["height"] ?? 0)px (viewport \(result["viewport"] ?? 0)px).")
    }

    private func selectOption(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: true)
        let webView = try webView(manager, id)
        AgentActivity.shared.mark(tabID: id, action: "Выбор варианта")
        let result = try await runJSON(webView, #"""
            const el = byRef(args.ref);
            if (!el) return JSON.stringify({ error: 'No element with ref ' + args.ref + '. Take a new browser_snapshot.' });
            if (el.tagName !== 'SELECT') return JSON.stringify({ error: 'Element ' + args.ref + ' is not a <select>; click it instead.' });
            const wanted = String(args.option);
            const option = [...el.options].find(o => o.value === wanted) || [...el.options].find(o => clean(o.text) === clean(wanted))
                || [...el.options].find(o => clean(o.text).toLowerCase().includes(clean(wanted).toLowerCase()));
            if (!option) return JSON.stringify({ error: 'No option ' + JSON.stringify(wanted) + '. Options: ' + [...el.options].map(o => clean(o.text)).join(', ') });
            el.focus();
            el.value = option.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return JSON.stringify({ selected: clean(option.text) });
            """#, args: ["ref": args["ref"] as? String ?? "", "option": args["option"] as? String ?? ""])
        await settle(webView)
        return .text("Selected \"\(result["selected"] as? String ?? "")\".")
    }

    private func waitFor(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        let timeout = Double(Swift.min(Swift.max(args["timeoutMs"] as? Int ?? 10_000, 100), 60_000)) / 1000
        let text = args["text"] as? String
        let textGone = args["textGone"] as? String
        let selector = args["selector"] as? String
        AgentActivity.shared.mark(tabID: id, action: "Ожидание")
        let deadline = Date().addingTimeInterval(timeout)
        guard text != nil || textGone != nil || selector != nil else {
            await waitForLoad(webView, timeout: timeout)
            return .text((webView.isLoading ? "Still loading after timeout.\n" : "Page loaded.\n") + pageInfo(webView))
        }
        while true {
            let state = try await runJSON(webView, #"""
                const body = document.body ? document.body.innerText : '';
                let selectorOk = true;
                if (args.selector) { try { selectorOk = !!document.querySelector(args.selector); } catch (e) { return JSON.stringify({ error: 'Invalid selector: ' + e.message }); } }
                return JSON.stringify({
                    ok: (!args.text || body.includes(args.text)) && (!args.gone || !body.includes(args.gone)) && selectorOk
                });
                """#, args: ["text": text ?? "", "gone": textGone ?? "", "selector": selector ?? ""])
            if state["ok"] as? Bool == true { return .text("Condition met.\n" + pageInfo(webView)) }
            if Date() >= deadline { throw AgentError("Timed out after \(Int(timeout * 1000)) ms. " + pageInfo(webView)) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func evaluate(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        guard let script = args["script"] as? String, !script.isEmpty else { throw AgentError("script is required") }
        AgentActivity.shared.mark(tabID: id, action: "Выполняет JavaScript")
        let serializer = #"""
            const __aircraftSerialize = (r) => {
                if (r === undefined) return 'undefined';
                if (typeof Node !== 'undefined' && r instanceof Node) return r.outerHTML ? r.outerHTML.slice(0, 20000) : String(r.textContent);
                try { return JSON.stringify(r, null, 2) ?? String(r); } catch (e) { return String(r); }
            };
            """#
        var value: Any?
        do {
            value = try await webView.callAsyncJavaScript(serializer + "return __aircraftSerialize(await (\n\(script)\n));",
                                                          arguments: [:], in: nil, contentWorld: .page)
        } catch where Self.message(for: error).contains("SyntaxError") {
            do {
                value = try await webView.callAsyncJavaScript(serializer + "return __aircraftSerialize(await (async () => {\n\(script)\n})());",
                                                              arguments: [:], in: nil, contentWorld: .page)
            } catch {
                throw AgentError("JavaScript error: " + Self.message(for: error))
            }
        } catch {
            throw AgentError("JavaScript error: " + Self.message(for: error))
        }
        let text = value as? String ?? "undefined"
        return .text(text.count > 50_000 ? String(text.prefix(50_000)) + "\n… (truncated)" : text)
    }

    private func console(_ args: [String: Any]) async throws -> Output {
        let (manager, id) = try target(args, focus: false)
        let webView = try webView(manager, id)
        let level = args["level"] as? String ?? "all"
        let value = try await webView.callAsyncJavaScript(#"""
            const buffer = window.__aircraftConsole;
            if (!buffer) return JSON.stringify({ missing: true });
            const items = buffer.filter(m => level === 'all' || m.level === level);
            if (clear) buffer.length = 0;
            return JSON.stringify({ items: items.slice(-200) });
            """#, arguments: ["level": level, "clear": args["clear"] as? Bool ?? false], in: nil, contentWorld: .page)
        guard let data = (value as? String)?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("Could not read the console.")
        }
        if object["missing"] as? Bool == true {
            _ = try? await webView.callAsyncJavaScript(Self.consoleCaptureSource, arguments: [:], in: nil, contentWorld: .page)
            return .text("Console capture was not active in this tab; it is now. Messages logged from now on will appear here (reload the page to capture load-time messages).")
        }
        let items = object["items"] as? [[String: Any]] ?? []
        if items.isEmpty { return .text("No console messages.") }
        let lines = items.map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }
        return .text(lines.joined(separator: "\n"))
    }

    // MARK: Нативный ввод

    /// Клик настоящими событиями мыши: для страницы они неотличимы от пользовательских (isTrusted).
    private func nativeClick(_ webView: WKWebView, x: Double, y: Double, count: Int) -> Bool {
        guard let window = webView.window else { return false }
        let zoom = webView.pageZoom * webView.magnification
        let local = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        guard webView.bounds.contains(local) else { return false }
        let point = webView.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: time,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            webView.mouseMoved(with: move)
        }
        for click in 1...count {
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 0)
            else { return false }
            webView.mouseDown(with: down)
            webView.mouseUp(with: up)
        }
        return true
    }

    @discardableResult
    private func sendKey(_ combo: String, to webView: WKWebView) async throws -> String {
        let parts = combo.split(separator: "+").map { String($0) }
        var modifiers: NSEvent.ModifierFlags = []
        var keyName = parts.last ?? combo
        if combo.hasSuffix("++") { keyName = "+" }
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "meta", "cmd", "command", "super": modifiers.insert(.command)
            default: throw AgentError("Unknown modifier \(part)")
            }
        }
        guard let key = Self.keyInfo(keyName) else { throw AgentError("Unknown key \(keyName)") }

        if await waitForWindow(webView), let window = webView.window {
            window.makeFirstResponder(webView)
            let time = ProcessInfo.processInfo.systemUptime
            var characters = key.characters
            if modifiers.contains(.shift), key.characters.count == 1, key.characters.first?.isLetter == true {
                characters = characters.uppercased()
            }
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: time,
                                              windowNumber: window.windowNumber, context: nil, characters: characters,
                                              charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code),
                  let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: time,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
            else { throw AgentError("Could not create the key event.") }
            if modifiers.contains(.command), webView.performKeyEquivalent(with: down) {
                return "native key events"
            }
            webView.keyDown(with: down)
            webView.keyUp(with: up)
            return "native key events"
        }

        _ = try await runJSON(webView, #"""
            const el = document.activeElement || document.body;
            const init = { key: args.key, bubbles: true, cancelable: true, shiftKey: args.shift, ctrlKey: args.ctrl, altKey: args.alt, metaKey: args.meta };
            const proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
            if (proceed && args.key === 'Enter' && el.form) el.form.requestSubmit();
            el.dispatchEvent(new KeyboardEvent('keyup', init));
            return JSON.stringify({ ok: true });
            """#, args: [
                "key": key.domKey,
                "shift": modifiers.contains(.shift), "ctrl": modifiers.contains(.control),
                "alt": modifiers.contains(.option), "meta": modifiers.contains(.command)
            ])
        return "synthetic DOM events (tab is not on screen)"
    }

    private struct KeyInfo {
        let code: UInt16
        let characters: String
        let domKey: String
    }

    private static func keyInfo(_ name: String) -> KeyInfo? {
        func function(_ value: Int) -> String { String(Character(UnicodeScalar(value)!)) }
        switch name.lowercased() {
        case "enter", "return": return KeyInfo(code: 36, characters: "\r", domKey: "Enter")
        case "tab": return KeyInfo(code: 48, characters: "\t", domKey: "Tab")
        case "escape", "esc": return KeyInfo(code: 53, characters: "\u{1b}", domKey: "Escape")
        case "backspace": return KeyInfo(code: 51, characters: "\u{7f}", domKey: "Backspace")
        case "delete", "del": return KeyInfo(code: 117, characters: function(NSDeleteFunctionKey), domKey: "Delete")
        case "space", " ": return KeyInfo(code: 49, characters: " ", domKey: " ")
        case "arrowup", "up": return KeyInfo(code: 126, characters: function(NSUpArrowFunctionKey), domKey: "ArrowUp")
        case "arrowdown", "down": return KeyInfo(code: 125, characters: function(NSDownArrowFunctionKey), domKey: "ArrowDown")
        case "arrowleft", "left": return KeyInfo(code: 123, characters: function(NSLeftArrowFunctionKey), domKey: "ArrowLeft")
        case "arrowright", "right": return KeyInfo(code: 124, characters: function(NSRightArrowFunctionKey), domKey: "ArrowRight")
        case "pageup": return KeyInfo(code: 116, characters: function(NSPageUpFunctionKey), domKey: "PageUp")
        case "pagedown": return KeyInfo(code: 121, characters: function(NSPageDownFunctionKey), domKey: "PageDown")
        case "home": return KeyInfo(code: 115, characters: function(NSHomeFunctionKey), domKey: "Home")
        case "end": return KeyInfo(code: 119, characters: function(NSEndFunctionKey), domKey: "End")
        default:
            guard name.count == 1 else { return nil }
            let character = name.lowercased()
            return KeyInfo(code: ansiKeyCodes[character] ?? 0, characters: character, domKey: name)
        }
    }

    private static let ansiKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50
    ]

    // MARK: Вспомогательное

    private func target(_ args: [String: Any], focus: Bool) throws -> (TabManager, UUID) {
        if let raw = args["tabId"] as? String, !raw.isEmpty {
            guard let id = UUID(uuidString: raw) else { throw AgentError("Invalid tabId \(raw)") }
            guard let manager = liveManagers.first(where: { $0.tabs.contains { $0.id == id } }) else {
                throw AgentError("No tab with id \(raw). Call browser_tabs.")
            }
            if focus, manager.activeTabID != id { manager.selectTab(id: id) }
            return (manager, id)
        }
        guard let manager = frontManager, let id = manager.activeTabID else { throw AgentError("No browser tab is open.") }
        return (manager, id)
    }

    private func webView(_ manager: TabManager, _ id: UUID) throws -> WKWebView {
        guard let tab = manager.tabs.first(where: { $0.id == id }) else { throw AgentError("The tab was closed.") }
        guard tab.url != nil, let webView = manager.webView(for: id) else {
            throw AgentError("The tab is empty. Use browser_navigate to load a page first.")
        }
        return webView
    }

    private func pageInfo(_ webView: WKWebView) -> String {
        var text = "Page: \(webView.title?.isEmpty == false ? webView.title! : "(untitled)") — \(webView.url?.absoluteString ?? "about:blank")"
        if webView.isLoading { text += " (still loading)" }
        return text
    }

    private func waitForLoad(_ webView: WKWebView, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// После действия даём странице отреагировать и дожидаемся навигации, если она началась.
    private func settle(_ webView: WKWebView) async {
        try? await Task.sleep(for: .milliseconds(350))
        if webView.isLoading { await waitForLoad(webView, timeout: 15) }
    }

    /// После selectTab SwiftUI вставляет WKWebView в окно на следующем проходе — ждём немного.
    private func waitForWindow(_ webView: WKWebView) async -> Bool {
        for _ in 0..<20 where webView.window == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return webView.window != nil
    }

    private func runJSON(_ webView: WKWebView, _ body: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(Self.prelude + body, arguments: ["args": args], in: nil, contentWorld: .defaultClient)
        } catch {
            throw AgentError("Page script failed: " + Self.message(for: error))
        }
        guard let string = value as? String, let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError("The page returned no result (it may be a PDF, an image or a restricted page).")
        }
        if let error = object["error"] as? String { throw AgentError(error) }
        return object
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String { return message }
        return nsError.localizedDescription
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func resolveURL(_ input: String) throws -> URL {
        let defaults = UserDefaults.standard
        let template = SearchEngineOption.queryTemplate(
            for: defaults.string(forKey: "searchEngine") ?? "duckduckgo",
            customURL: defaults.string(forKey: "customSearchURL") ?? ""
        )
        guard let url = URLRouter.navigationTarget(input: input, searchTemplate: template).flatMap(URL.init(string:)) else {
            throw AgentError("Could not turn \(input) into a URL.")
        }
        return url
    }

    private static func jpegData(_ image: NSImage, size: NSSize) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    // MARK: JavaScript

    /// Общие функции для скриптов в мире `.defaultClient`.
    private static let prelude = #"""
        const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
        const visible = (el) => {
            if (!el || !el.getBoundingClientRect) return false;
            const r = el.getBoundingClientRect();
            if (r.width < 1 || r.height < 1) return false;
            const s = getComputedStyle(el);
            return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.02;
        };
        const byRef = (ref) => ref ? document.querySelector('[data-aircraft-ref="' + CSS.escape(String(ref)) + '"]') : null;
        const roleOf = (el) => {
            const role = el.getAttribute('role');
            if (role) return role;
            switch (el.tagName) {
                case 'A': return 'link';
                case 'BUTTON': case 'SUMMARY': return 'button';
                case 'SELECT': return 'select';
                case 'TEXTAREA': return 'textbox';
                case 'INPUT': {
                    const t = (el.type || 'text').toLowerCase();
                    if (['submit', 'button', 'reset', 'image'].includes(t)) return 'button';
                    if (['checkbox', 'radio', 'range', 'file', 'color'].includes(t)) return t;
                    return t === 'text' ? 'textbox' : 'textbox(' + t + ')';
                }
            }
            if (el.isContentEditable) return 'textbox';
            return el.tagName.toLowerCase();
        };
        const labelOf = (el) => {
            const labelled = el.getAttribute('aria-labelledby');
            const fromIds = labelled ? labelled.split(/\s+/).map(id => document.getElementById(id)?.innerText || '').join(' ') : '';
            const candidates = [
                el.getAttribute('aria-label'), fromIds,
                el.labels && el.labels[0] ? el.labels[0].innerText : '',
                ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) ? '' : el.innerText,
                el.getAttribute('placeholder'), el.getAttribute('title'), el.getAttribute('alt'),
                el.querySelector && el.querySelector('img[alt]') ? el.querySelector('img[alt]').getAttribute('alt') : '',
                ['submit', 'button', 'reset'].includes(el.type) ? el.value : '',
                el.getAttribute('name')
            ];
            for (const c of candidates) { const v = clean(c); if (v) return v.slice(0, 100); }
            return '';
        };
        const describe = (el) => roleOf(el) + ' "' + labelOf(el) + '"';

        """#

    private static let snapshotScript = #"""
        const interactive = 'a[href],button,input:not([type=hidden]),textarea,select,summary,[contenteditable=""],[contenteditable=true],'
            + '[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],'
            + '[role=combobox],[role=textbox],[role=searchbox],[role=slider],[onclick],[tabindex]:not([tabindex="-1"])';
        window.__aircraftRef = window.__aircraftRef || 0;
        const lines = [];
        let count = 0, skipped = 0;
        for (const el of document.querySelectorAll(interactive + ',h1,h2,h3,h4')) {
            if (!visible(el)) continue;
            const heading = /^H[1-4]$/.test(el.tagName);
            if (heading) { const t = clean(el.innerText).slice(0, 140); if (t) lines.push('#'.repeat(Number(el.tagName[1])) + ' ' + t); continue; }
            if (el.closest('[aria-hidden="true"]')) continue;
            if (count >= args.max) { skipped++; continue; }
            let ref = el.getAttribute('data-aircraft-ref');
            if (!ref) { ref = 'e' + (++window.__aircraftRef); el.setAttribute('data-aircraft-ref', ref); }
            const r = el.getBoundingClientRect();
            const offscreen = !(r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth);
            let line = '[' + ref + '] ' + describe(el);
            if (el.tagName === 'A') {
                const href = el.getAttribute('href') || '';
                if (href && !href.startsWith('javascript:') && href !== '#') line += ' -> ' + href.slice(0, 150);
            }
            const t = (el.type || '').toLowerCase();
            if (t === 'checkbox' || t === 'radio' || ['checkbox', 'radio', 'switch'].includes(el.getAttribute('role'))) {
                const checked = el.checked ?? (el.getAttribute('aria-checked') === 'true');
                line += checked ? ' [checked]' : ' [unchecked]';
            }
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                if (t === 'password') { if (el.value) line += ' value=••••'; }
                else if (el.value && !['checkbox', 'radio', 'submit', 'button', 'reset'].includes(t)) line += ' value="' + clean(el.value).slice(0, 100) + '"';
            } else if (el.isContentEditable && clean(el.innerText)) {
                line += ' value="' + clean(el.innerText).slice(0, 100) + '"';
            }
            if (el.tagName === 'SELECT') {
                const opts = [...el.options];
                line += ' selected="' + clean(el.selectedOptions[0]?.text) + '" options=[' + opts.slice(0, 25).map(o => JSON.stringify(clean(o.text))).join(', ') + (opts.length > 25 ? ', …' : '') + ']';
            }
            if (el.getAttribute('aria-expanded')) line += el.getAttribute('aria-expanded') === 'true' ? ' [expanded]' : ' [collapsed]';
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' [disabled]';
            if (document.activeElement === el) line += ' [focused]';
            if (offscreen) line += ' [offscreen]';
            lines.push(line);
            count++;
        }
        if (skipped) lines.push('… ' + skipped + ' more elements not shown (raise maxElements or scroll).');
        const doc = document.scrollingElement || document.documentElement;
        return JSON.stringify({
            url: location.href, title: document.title, lines,
            scroll: { y: Math.round(doc.scrollTop), height: doc.scrollHeight, viewport: innerHeight, width: innerWidth }
        });
        """#

    private static let locateScript = #"""
        let el = null;
        if (args.ref) {
            el = byRef(args.ref);
            if (!el) return JSON.stringify({ error: 'No element with ref ' + args.ref + ' (the page may have changed). Take a new browser_snapshot.' });
        } else {
            const wanted = clean(args.text).toLowerCase();
            const clickable = 'a,button,input[type=submit],input[type=button],[role=button],[role=link],[role=tab],[role=menuitem],[role=option],summary,label,[onclick]';
            const textOf = (e) => clean(e.innerText || e.value || e.getAttribute('aria-label')).toLowerCase();
            const candidates = [...document.querySelectorAll(clickable)].filter(visible);
            el = candidates.find(e => textOf(e) === wanted) || candidates.find(e => textOf(e).includes(wanted));
            if (!el) {
                let best = null;
                for (const e of document.body.querySelectorAll('*')) {
                    if (!visible(e) || !textOf(e).includes(wanted)) continue;
                    if (!best || best.contains(e)) best = e;
                }
                el = best;
            }
            if (!el) return JSON.stringify({ error: 'No visible element with text ' + JSON.stringify(args.text) + '.' });
        }
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return JSON.stringify({ error: 'Element ' + describe(el) + ' is not visible.' });
        const x = Math.min(Math.max(r.left + r.width / 2, 1), innerWidth - 1);
        const y = Math.min(Math.max(r.top + r.height / 2, 1), innerHeight - 1);
        const top = document.elementFromPoint(x, y);
        const covered = top && top !== el && !el.contains(top) && !top.contains(el) && !(top.closest && top.closest('label') && top.closest('label').control === el) ? describe(top) : null;
        return JSON.stringify({ x, y, desc: describe(el), covered });
        """#

    private static let typeScript = #"""
        const el = args.ref ? byRef(args.ref) : document.activeElement;
        if (!el || el === document.body) return JSON.stringify({ error: args.ref ? 'No element with ref ' + args.ref + '. Take a new browser_snapshot.' : 'No element is focused; pass a ref.' });
        const isField = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
        if (!isField && !el.isContentEditable) return JSON.stringify({ error: describe(el) + ' is not a text field.' });
        el.scrollIntoView({ block: 'center', behavior: 'instant' });
        el.focus();
        if (args.clear) {
            if (isField) { el.select(); }
            else { const range = document.createRange(); range.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(range); }
            if (!args.text) document.execCommand('delete');
        } else if (isField) {
            const end = el.value.length; try { el.setSelectionRange(end, end); } catch (e) {}
        }
        let ok = args.text ? document.execCommand('insertText', false, args.text) : true;
        const current = () => isField ? el.value : el.innerText;
        if (!ok || (args.text && !current().includes(args.text))) {
            if (isField) {
                const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, args.clear ? args.text : el.value + args.text);
            } else {
                el.textContent = args.clear ? args.text : el.textContent + args.text;
            }
            el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: args.text }));
        }
        if (isField) el.dispatchEvent(new Event('change', { bubbles: true }));
        const value = el.type === 'password' ? '•'.repeat(current().length) : clean(current()).slice(0, 300);
        return JSON.stringify({ desc: describe(el), value });
        """#

    private static let scrollScript = #"""
        if (args.ref) {
            const el = byRef(args.ref);
            if (!el) return JSON.stringify({ error: 'No element with ref ' + args.ref + '. Take a new browser_snapshot.' });
            el.scrollIntoView({ block: 'center', behavior: 'instant' });
            return JSON.stringify({ desc: describe(el) });
        }
        const vertical = !['left', 'right'].includes(args.direction);
        const doc = document.scrollingElement || document.documentElement;
        const canScroll = (e) => vertical ? e.scrollHeight > e.clientHeight + 1 : e.scrollWidth > e.clientWidth + 1;
        let scroller = doc;
        if (!canScroll(doc)) {
            let e = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
            while (e && e !== document.body && e !== doc) {
                const s = getComputedStyle(e);
                if (/(auto|scroll|overlay)/.test(vertical ? s.overflowY : s.overflowX) && canScroll(e)) { scroller = e; break; }
                e = e.parentElement;
            }
        }
        const size = scroller === doc ? (vertical ? innerHeight : innerWidth) : (vertical ? scroller.clientHeight : scroller.clientWidth);
        const amount = args.amount || size * 0.8;
        const to = (top, left) => scroller.scrollTo({ top, left, behavior: 'instant' });
        switch (args.direction) {
            case 'up': to(scroller.scrollTop - amount, scroller.scrollLeft); break;
            case 'left': to(scroller.scrollTop, scroller.scrollLeft - amount); break;
            case 'right': to(scroller.scrollTop, scroller.scrollLeft + amount); break;
            case 'top': to(0, scroller.scrollLeft); break;
            case 'bottom': to(scroller.scrollHeight, scroller.scrollLeft); break;
            default: to(scroller.scrollTop + amount, scroller.scrollLeft);
        }
        return JSON.stringify({ y: Math.round(scroller.scrollTop), height: scroller.scrollHeight, viewport: size });
        """#

    /// Перехват console.* и необработанных ошибок в мире страницы для browser_console.
    static let consoleCaptureSource = #"""
        (() => {
            if (window.__aircraftConsole) return;
            const buffer = [];
            Object.defineProperty(window, '__aircraftConsole', { value: buffer, enumerable: false });
            const format = (a) => {
                if (a instanceof Error) return a.stack || String(a);
                if (typeof a === 'object' && a !== null) { try { return JSON.stringify(a); } catch (e) { return String(a); } }
                return String(a);
            };
            const push = (level, args) => {
                try {
                    buffer.push({ level, time: Date.now(), text: args.map(format).join(' ').slice(0, 4000) });
                    if (buffer.length > 500) buffer.splice(0, buffer.length - 500);
                } catch (e) {}
            };
            for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
                const original = console[level];
                console[level] = function (...args) { push(level, args); return original.apply(this, args); };
            }
            addEventListener('error', (e) => push('error', [e.message + (e.filename ? ' at ' + e.filename + ':' + e.lineno : '')]));
            addEventListener('unhandledrejection', (e) => push('error', ['Unhandled rejection: ' + format(e.reason)]));
        })();
        """#
}
