import Foundation
import WebKit

import AppKit

/// Просмотрщик и редактор Markdown: рендер в WebView, оглавление, режимы «Просмотр / Правка /
/// Исходник», живой предпросмотр при правке, сохранение ⌘S, оформление (тема, шрифт, размер,
/// ширина), подсветка кода и живое обновление локальных файлов при сохранении извне.
@MainActor
enum MarkdownViewer {
    private static var watchers: [ObjectIdentifier: FileWatcher] = [:]
    private static var renderNavigations: Set<ObjectIdentifier> = []
    /// Локальные файлы, которые можно сохранять из редактора (по WebView).
    private static var editableFiles: [ObjectIdentifier: URL] = [:]
    /// WebView, где сейчас открыт наш просмотрщик (снимается при уходе со страницы).
    private static var markdownViews: Set<ObjectIdentifier> = []
    /// Когда мы сами сохранили файл — чтобы наблюдатель не перезагрузил редактор.
    private static var ownSaves: [ObjectIdentifier: Date] = [:]
    static let settingsKey = "markdownAppearance"

    /// `baseURL` — исходный адрес (для файла из сети); у локального файла — сам файл.
    static func render(file: URL, in webView: WKWebView, baseURL: URL? = nil, scrollY: Double = 0) {
        let data = (try? Data(contentsOf: file)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let key = ObjectIdentifier(webView)
        let editable = baseURL == nil && !file.path.hasPrefix(AircraftPaths.viewerCache.path)
            && FileManager.default.isWritableFile(atPath: file.path)
        let html = page(markdown: text, title: (baseURL ?? file).lastPathComponent.removingPercentEncoding ?? file.lastPathComponent,
                        scrollY: scrollY, editable: editable)
        if let navigation = webView.loadHTMLString(html, baseURL: baseURL ?? file) {
            renderNavigations.insert(ObjectIdentifier(navigation))
        }
        watchers[key]?.cancel()
        watchers[key] = nil
        editableFiles[key] = editable ? file : nil
        markdownViews.insert(key)
        // Живое обновление — только для файлов пользователя, не для скачанных копий.
        if baseURL == nil, !file.path.hasPrefix(AircraftPaths.viewerCache.path) {
            watchers[key] = FileWatcher(url: file) { [weak webView] in
                guard let webView else { return }
                Task { @MainActor in
                    // Своё сохранение не перезагружает страницу (иначе потеряется курсор).
                    if let saved = ownSaves[ObjectIdentifier(webView)], Date().timeIntervalSince(saved) < 1.5 { return }
                    let state = try? await webView.evaluateJavaScript("window.__mdState ? window.__mdState() : null") as? [String: Any]
                    if (state?["dirty"] as? Bool) == true { return }
                    let y = (state?["scroll"] as? Double) ?? 0
                    render(file: file, in: webView, scrollY: y)
                }
            }
        }
    }

    /// Навигация — это наш рендер, а не переход по ссылке.
    static func consumeRenderNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return false }
        return renderNavigations.remove(ObjectIdentifier(navigation)) != nil
    }

    static func stopWatching(_ webView: WKWebView) {
        watchers.removeValue(forKey: ObjectIdentifier(webView))?.cancel()
        editableFiles.removeValue(forKey: ObjectIdentifier(webView))
        markdownViews.remove(ObjectIdentifier(webView))
    }

    // MARK: Сообщения редактора

    /// Сообщение со страницы редактора. Принимаем только от главного фрейма просмотрщика
    /// Markdown, открытого нами (обычные сайты так сохранить файл не могут).
    static func handle(action: String, payload: [String: Any], webView: WKWebView, frame: WKFrameInfo) {
        let key = ObjectIdentifier(webView)
        guard frame.isMainFrame, markdownViews.contains(key) else { return }
        switch action {
        case "markdown.preview":
            let text = payload["text"] as? String ?? ""
            let rendered = MarkdownRenderer.render(text)
            let toc = tocHTML(rendered.headings)
            if let data = try? JSONSerialization.data(withJSONObject: [rendered.html, toc]),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.__mdPreview && window.__mdPreview(\(json)[0], \(json)[1])")
            }
        case "markdown.save":
            let text = payload["text"] as? String ?? ""
            if let file = editableFiles[key] {
                do {
                    ownSaves[key] = Date()
                    try text.write(to: file, atomically: true, encoding: .utf8)
                    webView.evaluateJavaScript("window.__mdSaved && window.__mdSaved(true)")
                } catch {
                    webView.evaluateJavaScript("window.__mdSaved && window.__mdSaved(false)")
                }
            } else {
                saveCopy(text, suggestedName: webView.title ?? "document.md", webView: webView)
            }
        case "markdown.settings":
            if let value = payload["value"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: value) {
                UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: settingsKey)
            }
        default:
            break
        }
    }

    private static func saveCopy(_ text: String, suggestedName: String, webView: WKWebView) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.hasSuffix(".md") ? suggestedName : suggestedName + ".md"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let ok = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            webView.evaluateJavaScript("window.__mdSaved && window.__mdSaved(\(ok))")
        }
        if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private static func tocHTML(_ headings: [MarkdownRenderer.Heading]) -> String {
        guard headings.count >= 3 else { return "" }
        return headings.map { heading in
            "<a href=\"#\(heading.id)\" class=\"l\(heading.level)\">\(MarkdownRenderer.escape(heading.text))</a>"
        }.joined(separator: "\n")
    }

    private static var savedSettingsJSON: String {
        let raw = UserDefaults.standard.string(forKey: settingsKey) ?? "{}"
        guard let data = raw.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return "{}" }
        return raw
    }

    static func page(markdown: String, title: String, scrollY: Double, editable: Bool = false) -> String {
        let rendered = MarkdownRenderer.render(markdown)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let toc = tocHTML(rendered.headings)
        return """
        <!doctype html>
        <html lang="ru"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob: file:; media-src * data: file:; style-src 'unsafe-inline'; font-src * data:; script-src 'nonce-\(nonce)'; frame-src 'none'; object-src 'none'; base-uri 'self'">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>\(css)</style>
        </head>
        <body class="\(toc.isEmpty ? "" : "has-toc") mode-view">
        <header class="bar">
          <span class="name">\(MarkdownRenderer.escape(title))</span>
          <span id="status" class="status"></span>
          <span class="spacer"></span>
          <span class="seg">
            <button data-mode="view" class="on" title="Просмотр">Просмотр</button>
            <button data-mode="edit" title="Правка с предпросмотром">Правка</button>
            <button data-mode="source" title="Исходный текст">Исходник</button>
          </span>
          <button id="toggle-toc" title="Оглавление"\(toc.isEmpty ? " hidden" : "")>☰</button>
          <button id="toggle-look" title="Оформление">Aa</button>
          <button id="save" title="\(editable ? "Сохранить (⌘S)" : "Сохранить копию (⌘S)")" hidden>\(editable ? "Сохранить" : "Сохранить копию…")</button>
        </header>
        <div id="look" class="look" hidden>
          <label>Тема <select id="look-theme"><option value="auto">Как в системе</option><option value="light">Светлая</option><option value="sepia">Сепия</option><option value="dark">Тёмная</option></select></label>
          <label>Шрифт <select id="look-font"><option value="sans">Без засечек</option><option value="serif">С засечками</option><option value="mono">Моноширинный</option></select></label>
          <label>Размер <button id="look-smaller">A−</button><span id="look-size">16</span><button id="look-bigger">A+</button></label>
          <label>Ширина <select id="look-width"><option value="narrow">Узко</option><option value="normal">Обычно</option><option value="wide">Широко</option></select></label>
        </div>
        <div id="toolbar" class="toolbar" hidden>
          <button data-wrap="**" title="Жирный (⌘B)"><b>B</b></button>
          <button data-wrap="_" title="Курсив (⌘I)"><i>I</i></button>
          <button data-wrap="~~" title="Зачёркнутый"><s>S</s></button>
          <button data-wrap="`" title="Код">&lt;/&gt;</button>
          <button data-line="# " title="Заголовок">H</button>
          <button data-line="- " title="Список">•</button>
          <button data-line="1. " title="Нумерованный список">1.</button>
          <button data-line="- [ ] " title="Задача">☐</button>
          <button data-line="> " title="Цитата">❝</button>
          <button data-link="1" title="Ссылка (⌘K)">🔗</button>
          <button data-block="```\n\n```" title="Блок кода">{ }</button>
          <button data-block="| Колонка | Колонка |\n| --- | --- |\n|  |  |" title="Таблица">▦</button>
        </div>
        <nav id="toc"\(toc.isEmpty ? " hidden" : "")>\(toc)</nav>
        <div id="workspace">
          <textarea id="editor" spellcheck="true" hidden>\(MarkdownRenderer.escape(markdown))</textarea>
          <main id="preview" class="markdown">\(rendered.html)</main>
        </div>
        <pre id="source" hidden>\(MarkdownRenderer.escape(markdown))</pre>
        <script nonce="\(nonce)">const editable = \(editable); const savedLook = \(savedSettingsJSON);\n\(script(scrollY: scrollY))</script>
        </body></html>
        """
    }

    private static let css = #"""
    :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --soft: #f6f8fa; --line: #d1d9e0; --link: #0969da; --mark: #fff8c5; }
    @media (prefers-color-scheme: dark) { :root { --fg: #e6edf3; --muted: #9198a1; --bg: #0d1117; --soft: #151b23; --line: #3d444d; --link: #4493f8; --mark: #3b2e00; } }
    * { box-sizing: border-box; }
    html { scroll-padding-top: 56px; }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .bar { position: sticky; top: 0; z-index: 5; display: flex; align-items: center; gap: 8px; padding: 8px 16px; background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(12px); border-bottom: 1px solid var(--line); font-size: 12px; }
    .bar .name { font-weight: 600; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .bar .spacer { flex: 1; }
    .bar button { font: inherit; border: 1px solid var(--line); background: var(--soft); color: var(--fg); border-radius: 6px; padding: 3px 10px; cursor: pointer; }
    .bar button.on { background: var(--link); border-color: var(--link); color: #fff; }
    #toc { position: fixed; top: 46px; left: 0; bottom: 0; width: 250px; overflow: auto; padding: 16px 12px 40px 16px; border-right: 1px solid var(--line); font-size: 13px; }
    #toc a { display: block; padding: 3px 8px; border-radius: 5px; color: var(--muted); text-decoration: none; line-height: 1.35; }
    #toc a:hover { background: var(--soft); color: var(--fg); }
    #toc a.current { color: var(--link); background: color-mix(in srgb, var(--link) 12%, transparent); }
    #toc .l2 { padding-left: 18px; } #toc .l3 { padding-left: 28px; font-size: 12px; } #toc .l4, #toc .l5, #toc .l6 { padding-left: 38px; font-size: 12px; }
    body.has-toc main, body.has-toc #source { margin-left: 250px; }
    body.toc-hidden #toc { display: none; } body.toc-hidden main, body.toc-hidden #source { margin-left: 0; }
    @media (max-width: 900px) { #toc { display: none; } body.has-toc main, body.has-toc #source { margin-left: 0; } }
    main, #source { max-width: 900px; padding: 32px 40px 80px; margin: 0 auto; }
    body.has-toc main, body.has-toc #source { margin-right: auto; }
    #source { white-space: pre-wrap; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .markdown h1, .markdown h2 { border-bottom: 1px solid var(--line); padding-bottom: .3em; }
    .markdown h1, .markdown h2, .markdown h3, .markdown h4, .markdown h5, .markdown h6 { position: relative; margin: 1.5em 0 .6em; line-height: 1.25; }
    .markdown h1 { font-size: 2em; } .markdown h2 { font-size: 1.5em; } .markdown h3 { font-size: 1.25em; }
    .markdown .anchor { position: absolute; left: -1em; padding-right: .3em; color: var(--muted); text-decoration: none; opacity: 0; font-weight: 400; }
    .markdown h1:hover .anchor, .markdown h2:hover .anchor, .markdown h3:hover .anchor, .markdown h4:hover .anchor { opacity: 1; }
    .markdown a { color: var(--link); text-decoration: none; } .markdown a:hover { text-decoration: underline; }
    .markdown img { max-width: 100%; }
    .markdown code { font: .87em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft); padding: .15em .4em; border-radius: 6px; }
    .markdown pre { background: var(--soft); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.45; position: relative; }
    .markdown pre code { background: none; padding: 0; font-size: 13px; }
    .markdown pre[data-lang]::after { content: attr(data-lang); position: absolute; top: 6px; right: 10px; font-size: 10px; color: var(--muted); text-transform: uppercase; }
    .markdown blockquote { margin: 0 0 1em; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--line); }
    .markdown table { border-collapse: collapse; display: block; overflow: auto; margin: 1em 0; }
    .markdown th, .markdown td { border: 1px solid var(--line); padding: 6px 13px; }
    .markdown tr:nth-child(2n) td { background: var(--soft); }
    .markdown hr { border: 0; height: 2px; background: var(--line); margin: 24px 0; }
    .markdown li.task { list-style: none; margin-left: -1.3em; }
    .markdown li + li { margin-top: .25em; }
    .markdown details { margin: 1em 0; } .markdown summary { cursor: pointer; }
    .bar .status { color: var(--muted); font-size: 11px; white-space: nowrap; }
    .bar .seg { display: inline-flex; border: 1px solid var(--line); border-radius: 7px; overflow: hidden; }
    .bar .seg button { border: 0; border-radius: 0; background: transparent; }
    .bar .seg button + button { border-left: 1px solid var(--line); }
    .bar .seg button.on { background: var(--link); color: #fff; }
    .look, .toolbar { position: sticky; top: 41px; z-index: 4; display: flex; flex-wrap: wrap; align-items: center; gap: 14px; padding: 7px 16px; background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(12px); border-bottom: 1px solid var(--line); font-size: 12px; }
    .look label { display: inline-flex; align-items: center; gap: 6px; color: var(--muted); }
    .look select, .look button, .toolbar button { font: inherit; border: 1px solid var(--line); background: var(--soft); color: var(--fg); border-radius: 6px; padding: 2px 8px; cursor: pointer; }
    .toolbar { gap: 4px; }
    .toolbar button { min-width: 30px; }
    [hidden] { display: none !important; }
    body.mode-edit #workspace { display: grid; grid-template-columns: 1fr 1fr; gap: 0; }
    body.mode-edit main { max-width: none; margin: 0 !important; border-left: 1px solid var(--line); height: calc(100vh - 82px); overflow: auto; }
    body.mode-edit #toc { display: none; }
    #editor { width: 100%; height: calc(100vh - 82px); resize: none; border: 0; outline: none; padding: 28px 32px 80px; background: var(--soft); color: var(--fg); font: 14px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; tab-size: 2; }
    @media (max-width: 760px) { body.mode-edit #workspace { grid-template-columns: 1fr; } body.mode-edit main { display: none; } }
    body.theme-light { --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --soft: #f6f8fa; --line: #d1d9e0; --link: #0969da; color-scheme: light; }
    body.theme-sepia { --fg: #3b2f22; --muted: #7a6a55; --bg: #f6efe2; --soft: #ece2cf; --line: #d9ccb4; --link: #9a5b13; color-scheme: light; }
    body.theme-dark { --fg: #e6edf3; --muted: #9198a1; --bg: #0d1117; --soft: #151b23; --line: #3d444d; --link: #4493f8; color-scheme: dark; }
    body.font-serif .markdown { font-family: "New York", "Iowan Old Style", Georgia, serif; }
    body.font-mono .markdown { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    body.width-narrow main, body.width-narrow #source { max-width: 680px; }
    body.width-wide main, body.width-wide #source { max-width: 1240px; }
    .markdown { font-size: var(--md-size, 16px); }
    .hl-c { color: #6e7781; font-style: italic; } .hl-s { color: #0a3069; } .hl-n { color: #0550ae; } .hl-k { color: #cf222e; }
    @media (prefers-color-scheme: dark) { .hl-c { color: #8b949e; } .hl-s { color: #a5d6ff; } .hl-n { color: #79c0ff; } .hl-k { color: #ff7b72; } }
    """#

    private static func script(scrollY: Double) -> String {
        "const initialScroll = \(Int(scrollY));\n" + #"""
        (() => {
          if (initialScroll > 0) requestAnimationFrame(() => window.scrollTo(0, initialScroll));
          const preview = document.getElementById('preview');
          const source = document.getElementById('source');
          const editor = document.getElementById('editor');
          const toolbar = document.getElementById('toolbar');
          const saveButton = document.getElementById('save');
          const status = document.getElementById('status');
          const toc = document.getElementById('toc');
          const post = (action, data) => window.webkit?.messageHandlers?.browserBridge?.postMessage(Object.assign({ action }, data || {}));
          let dirty = false;
          let mode = 'view';
          window.__mdState = () => ({ dirty, scroll: window.scrollY });

          const setMode = (next) => {
            mode = next;
            document.body.classList.remove('mode-view', 'mode-edit', 'mode-source');
            document.body.classList.add('mode-' + next);
            document.querySelectorAll('.seg button').forEach(b => b.classList.toggle('on', b.dataset.mode === next));
            editor.hidden = next !== 'edit';
            toolbar.hidden = next !== 'edit';
            source.hidden = next !== 'source';
            preview.hidden = next === 'source';
            saveButton.hidden = !(next === 'edit' || dirty);
            source.textContent = editor.value;
            if (next === 'edit') editor.focus();
          };
          document.querySelectorAll('.seg button').forEach(b => b.addEventListener('click', () => setMode(b.dataset.mode)));

          const setStatus = (text) => { status.textContent = text; };
          let previewTimer;
          const changed = () => {
            if (!dirty) { dirty = true; setStatus('Изменено •'); saveButton.hidden = false; }
            clearTimeout(previewTimer);
            previewTimer = setTimeout(() => post('markdown.preview', { text: editor.value }), 220);
          };
          editor.addEventListener('input', changed);
          window.__mdPreview = (html, tocHtml) => {
            preview.innerHTML = html;
            highlight();
            if (tocHtml) { toc.innerHTML = tocHtml; toc.hidden = false; document.body.classList.add('has-toc'); }
          };
          const save = () => { post('markdown.save', { text: editor.value }); setStatus('Сохранение…'); };
          window.__mdSaved = (ok) => {
            if (ok) { dirty = false; setStatus(editable ? 'Сохранено' : 'Копия сохранена'); setTimeout(() => { if (!dirty) setStatus(''); }, 1600); }
            else setStatus('Не удалось сохранить');
          };
          saveButton.addEventListener('click', save);

          // Правка: панель форматирования и сочетания клавиш.
          const replaceSelection = (before, after, placeholder) => {
            const start = editor.selectionStart, end = editor.selectionEnd;
            const selected = editor.value.slice(start, end) || placeholder || '';
            editor.setRangeText(before + selected + after, start, end, 'end');
            if (!editor.value.slice(start, end - 0)) editor.setSelectionRange(start + before.length, start + before.length + selected.length);
            editor.focus(); changed();
          };
          const prefixLines = (prefix) => {
            const value = editor.value;
            const start = value.lastIndexOf('\n', editor.selectionStart - 1) + 1;
            let end = value.indexOf('\n', editor.selectionEnd); if (end < 0) end = value.length;
            const lines = value.slice(start, end).split('\n').map(line => line.startsWith(prefix) ? line.slice(prefix.length) : prefix + line);
            editor.setRangeText(lines.join('\n'), start, end, 'select');
            editor.focus(); changed();
          };
          toolbar.querySelectorAll('button').forEach(button => button.addEventListener('click', () => {
            if (button.dataset.wrap) replaceSelection(button.dataset.wrap, button.dataset.wrap, 'текст');
            else if (button.dataset.line) prefixLines(button.dataset.line);
            else if (button.dataset.link) replaceSelection('[', '](https://)', 'ссылка');
            else if (button.dataset.block) replaceSelection('\n' + button.dataset.block.replace(/\\n/g, '\n') + '\n', '', '');
          }));
          editor.addEventListener('keydown', (event) => {
            if (event.key === 'Tab') { event.preventDefault(); replaceSelection('  ', '', ''); }
            if (event.metaKey && event.key.toLowerCase() === 'b') { event.preventDefault(); replaceSelection('**', '**', 'текст'); }
            if (event.metaKey && event.key.toLowerCase() === 'i') { event.preventDefault(); replaceSelection('_', '_', 'текст'); }
            if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); replaceSelection('[', '](https://)', 'ссылка'); }
          });
          addEventListener('keydown', (event) => {
            if (event.metaKey && event.key.toLowerCase() === 's') { event.preventDefault(); save(); }
            if (event.metaKey && event.key.toLowerCase() === 'e') { event.preventDefault(); setMode(mode === 'edit' ? 'view' : 'edit'); }
          });

          // Оформление: тема, шрифт, размер, ширина. Запоминается для всех файлов.
          const look = Object.assign({ theme: 'auto', font: 'sans', size: 16, width: 'normal' }, savedLook || {});
          const applyLook = () => {
            document.body.classList.remove('theme-light', 'theme-sepia', 'theme-dark', 'font-serif', 'font-mono', 'width-narrow', 'width-wide');
            if (look.theme !== 'auto') document.body.classList.add('theme-' + look.theme);
            if (look.font !== 'sans') document.body.classList.add('font-' + look.font);
            if (look.width !== 'normal') document.body.classList.add('width-' + look.width);
            document.body.style.setProperty('--md-size', look.size + 'px');
            document.getElementById('look-theme').value = look.theme;
            document.getElementById('look-font').value = look.font;
            document.getElementById('look-width').value = look.width;
            document.getElementById('look-size').textContent = look.size;
          };
          const storeLook = () => { applyLook(); post('markdown.settings', { value: look }); };
          document.getElementById('toggle-look').addEventListener('click', () => {
            const panel = document.getElementById('look'); panel.hidden = !panel.hidden;
          });
          document.getElementById('look-theme').addEventListener('change', (e) => { look.theme = e.target.value; storeLook(); });
          document.getElementById('look-font').addEventListener('change', (e) => { look.font = e.target.value; storeLook(); });
          document.getElementById('look-width').addEventListener('change', (e) => { look.width = e.target.value; storeLook(); });
          document.getElementById('look-smaller').addEventListener('click', () => { look.size = Math.max(12, look.size - 1); storeLook(); });
          document.getElementById('look-bigger').addEventListener('click', () => { look.size = Math.min(24, look.size + 1); storeLook(); });
          applyLook();

          const tocButton = document.getElementById('toggle-toc');
          if (tocButton) tocButton.addEventListener('click', () => document.body.classList.toggle('toc-hidden'));

          // Подсветка текущего раздела в оглавлении.
          const links = [...document.querySelectorAll('#toc a')];
          if (links.length) {
            const headings = links.map(link => document.getElementById(decodeURIComponent(link.hash.slice(1)))).filter(Boolean);
            const update = () => {
              let current = headings[0];
              for (const heading of headings) { if (heading.getBoundingClientRect().top < 90) current = heading; }
              links.forEach(link => link.classList.toggle('current', current && link.hash === '#' + current.id));
            };
            addEventListener('scroll', update, { passive: true });
            update();
          }

          // Простая подсветка кода: комментарии, строки, числа, ключевые слова.
          const keywords = 'abstract as async await break case catch class const continue def default defer del do elif else enum except export extends false final finally fn for from func function go guard if impl import in init interface is lambda let loop match mod module mut new nil None null of override package pass private protected pub public raise return self Self static struct super switch this throw throws true True False try type typeof undefined use var void where while with yield'.split(' ');
          const hashLanguages = /^(py|python|sh|bash|zsh|shell|console|rb|ruby|yaml|yml|toml|r|perl|make|makefile|dockerfile|conf|ini|nix)$/i;
          const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          function highlight() { document.querySelectorAll('pre code[data-lang]').forEach((block) => {
            const lang = block.dataset.lang || '';
            block.parentElement.dataset.lang = lang;
            if (/^(text|plain|txt|md|markdown|diff)$/i.test(lang)) return;
            const comment = hashLanguages.test(lang) ? '(#[^\n]*)' : '(\\/\\/[^\n]*|\\/\\*[\\s\\S]*?\\*\\/|<!--[\\s\\S]*?-->)';
            const pattern = new RegExp(comment + '|("(?:\\\\.|[^"\\\\\n])*"|\'(?:\\\\.|[^\'\\\\\n])*\'|`(?:\\\\.|[^`\\\\])*`)|(\\b\\d[\\d_.xXa-fA-F]*\\b)|(\\b(?:' + keywords.join('|') + ')\\b)', 'g');
            const text = block.textContent;
            let html = '', last = 0, match;
            while ((match = pattern.exec(text))) {
              html += escape(text.slice(last, match.index));
              const cls = match[1] ? 'hl-c' : match[2] ? 'hl-s' : match[3] ? 'hl-n' : 'hl-k';
              html += '<span class="' + cls + '">' + escape(match[0]) + '</span>';
              last = pattern.lastIndex;
            }
            block.innerHTML = html + escape(text.slice(last));
          }); }
          highlight();
        })();
        """#
    }
}

/// Следит за изменением файла (сохранение из редактора, запись агентом).
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Редакторы сохраняют через замену файла — подписываемся заново.
                if events.contains(.rename) || events.contains(.delete) {
                    self.source?.cancel()
                    self.start()
                }
                self.onChange()
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    deinit { cancel() }
}
