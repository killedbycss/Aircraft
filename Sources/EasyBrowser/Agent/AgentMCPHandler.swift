import Foundation

/// Разбирает JSON-RPC 2.0 сообщения протокола MCP и вызывает инструменты браузера.
@MainActor
final class AgentMCPHandler {
    private let browser = AgentBrowser()

    /// Возвращает тело ответа или nil, если ответ не нужен (только уведомления).
    func handle(_ data: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = object as? [Any] {
            var responses: [[String: Any]] = []
            for item in batch {
                if let response = await handleMessage(item) { responses.append(response) }
            }
            return responses.isEmpty ? nil : Self.encode(responses)
        }
        guard let response = await handleMessage(object) else { return nil }
        return Self.encode(response)
    }

    private func handleMessage(_ object: Any) async -> [String: Any]? {
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            // Ответы клиента на наши запросы нам не нужны: сервер ничего не спрашивает.
            if let message = object as? [String: Any], message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        guard let id = message["id"], !(id is NSNull) else { return nil } // уведомление
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return Self.result(id: id, [
                "protocolVersion": requested ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "aircraft",
                    "title": "Aircraft Browser",
                    "version": AppInfo.version
                ],
                "instructions": AgentTools.instructions
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": AgentTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard AgentTools.names.contains(name) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let output = await browser.call(name, arguments: arguments)
            var result: [String: Any] = ["content": output.content]
            if output.isError { result["isError"] = true }
            return Self.result(id: id, result)
        case "resources/list":
            return Self.result(id: id, ["resources": []])
        case "prompts/list":
            return Self.result(id: id, ["prompts": []])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

/// Описание инструментов для `tools/list`. Тексты на английском — их читает модель.
@MainActor
enum AgentTools {
    static let instructions = """
    Aircraft is the user's macOS web browser (WebKit). These tools drive its real tabs, \
    with the user's own logins and cookies. Typical loop: browser_navigate → browser_snapshot \
    (gives [eN] refs for interactive elements) → browser_click / browser_type with a ref → \
    browser_snapshot again. Refs stay valid until the page navigates. Use browser_screenshot \
    when layout matters and browser_get_text to read long content. Tools act on the active \
    tab of the front window unless tabId is given; acting on a tab brings it to the front. \
    Ask the user before submitting payments, sending messages or deleting data.
    """

    private static let tabID: [String: Any] = [
        "type": "string",
        "description": "Tab id from browser_tabs. Defaults to the active tab of the front window."
    ]

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: Any] = [:], required: [String] = [],
                             readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": [
                "title": title,
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "openWorldHint": true
            ]
        ]
    }

    static let definitions: [[String: Any]] = [
        tool("browser_tabs", "List tabs",
             "List open windows and tabs with their ids, titles, URLs and which tab is active.",
             readOnly: true),
        tool("browser_open_tab", "Open tab",
             "Open a new tab (optionally with a URL or search query) in the front window and wait for it to load.",
             properties: [
                "url": ["type": "string", "description": "URL or search query. Omit for an empty tab."],
                "background": ["type": "boolean", "description": "Open without switching to it. Default false."]
             ]),
        tool("browser_select_tab", "Select tab", "Make a tab active (bring it to the front).",
             properties: ["tabId": tabID], required: ["tabId"]),
        tool("browser_close_tab", "Close tab", "Close a tab.",
             properties: ["tabId": tabID], destructive: true),
        tool("browser_fullscreen", "Window fullscreen",
             "Put the browser window that holds the tab into macOS fullscreen, take it out, or toggle. Returns the resulting state.",
             properties: [
                "action": ["type": "string", "enum": ["enter", "exit", "toggle"], "description": "Default toggle."],
                "tabId": tabID
             ]),
        tool("browser_navigate", "Navigate",
             "Load a URL (or search query) in a tab and wait until the page has loaded. Returns the final URL and title.",
             properties: [
                "url": ["type": "string", "description": "URL or search query."],
                "tabId": tabID
             ], required: ["url"]),
        tool("browser_history", "Back / forward / reload",
             "Go back, go forward or reload the page, then wait for it to load.",
             properties: [
                "action": ["type": "string", "enum": ["back", "forward", "reload"]],
                "tabId": tabID
             ], required: ["action"]),
        tool("browser_snapshot", "Page snapshot",
             "Describe the page: URL, title, headings and visible interactive elements (links, buttons, fields, selects) with refs like [e12] for browser_click / browser_type. Elements outside the viewport are marked [offscreen].",
             properties: [
                "tabId": tabID,
                "maxElements": ["type": "integer", "description": "Default 250."]
             ], readOnly: true),
        tool("browser_get_text", "Read page text",
             "Return the visible text of the page (document.body.innerText), paginated.",
             properties: [
                "tabId": tabID,
                "offset": ["type": "integer", "description": "Character offset. Default 0."],
                "maxChars": ["type": "integer", "description": "Default 20000."]
             ], readOnly: true),
        tool("browser_screenshot", "Screenshot",
             "Take a JPEG screenshot of the visible part of the page.",
             properties: ["tabId": tabID], readOnly: true),
        tool("browser_click", "Click",
             "Click an element by ref from browser_snapshot, by visible text, or at viewport coordinates (CSS pixels, from a screenshot). Uses real mouse events when the tab is on screen.",
             properties: [
                "ref": ["type": "string", "description": "Element ref, e.g. e12."],
                "text": ["type": "string", "description": "Visible text of the element to click, if no ref."],
                "x": ["type": "number"],
                "y": ["type": "number"],
                "doubleClick": ["type": "boolean"],
                "tabId": tabID
             ]),
        tool("browser_type", "Type text",
             "Type text into an input, textarea or contenteditable element. Replaces the current value unless clear is false. Set submit to press Enter afterwards.",
             properties: [
                "ref": ["type": "string", "description": "Element ref. Defaults to the focused element."],
                "text": ["type": "string"],
                "clear": ["type": "boolean", "description": "Replace existing value. Default true."],
                "submit": ["type": "boolean", "description": "Press Enter after typing. Default false."],
                "tabId": tabID
             ], required: ["text"]),
        tool("browser_press_key", "Press key",
             "Press a key in the page, optionally with modifiers: Enter, Tab, Escape, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, PageUp, PageDown, Home, End, Space, or a single character. Combine with + like Shift+Tab or Meta+A.",
             properties: [
                "key": ["type": "string"],
                "tabId": tabID
             ], required: ["key"]),
        tool("browser_scroll", "Scroll",
             "Scroll the page (or the scrollable area under the viewport centre), or scroll an element into view.",
             properties: [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
                "amount": ["type": "number", "description": "Pixels. Default: 80% of the viewport."],
                "ref": ["type": "string", "description": "Scroll this element into view instead."],
                "tabId": tabID
             ]),
        tool("browser_select_option", "Select option",
             "Choose an option in a <select> by its value or visible label.",
             properties: [
                "ref": ["type": "string"],
                "option": ["type": "string", "description": "Option value or label."],
                "tabId": tabID
             ], required: ["ref", "option"]),
        tool("browser_wait_for", "Wait",
             "Wait until text appears, text disappears or a CSS selector matches, or just wait for the page to finish loading.",
             properties: [
                "text": ["type": "string"],
                "textGone": ["type": "string"],
                "selector": ["type": "string"],
                "timeoutMs": ["type": "integer", "description": "Default 10000, max 60000."],
                "tabId": tabID
             ], readOnly: true),
        tool("browser_evaluate", "Run JavaScript",
             "Run JavaScript in the page and return the JSON-serialised result. Accepts an expression (document.title) or a function body with return/await.",
             properties: [
                "script": ["type": "string"],
                "tabId": tabID
             ], required: ["script"]),
        tool("browser_console", "Console messages",
             "Read console messages and uncaught errors from the page.",
             properties: [
                "level": ["type": "string", "enum": ["all", "error", "warn", "info", "log", "debug"]],
                "clear": ["type": "boolean", "description": "Clear the buffer after reading."],
                "tabId": tabID
             ], readOnly: true)
    ]

    static let names: Set<String> = Set(definitions.compactMap { $0["name"] as? String })
}
