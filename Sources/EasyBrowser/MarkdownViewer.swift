import Foundation
import WebKit

/// Просмотрщик Markdown: рендер в WebView, оглавление, «Просмотр / Исходник», подсветка кода,
/// живое обновление локальных файлов при сохранении.
@MainActor
enum MarkdownViewer {
    private static var watchers: [ObjectIdentifier: FileWatcher] = [:]
    private static var renderNavigations: Set<ObjectIdentifier> = []

    /// `baseURL` — исходный адрес (для файла из сети); у локального файла — сам файл.
    static func render(file: URL, in webView: WKWebView, baseURL: URL? = nil, scrollY: Double = 0) {
        let data = (try? Data(contentsOf: file)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let html = page(markdown: text, title: (baseURL ?? file).lastPathComponent.removingPercentEncoding ?? file.lastPathComponent,
                        scrollY: scrollY)
        if let navigation = webView.loadHTMLString(html, baseURL: baseURL ?? file) {
            renderNavigations.insert(ObjectIdentifier(navigation))
        }
        let key = ObjectIdentifier(webView)
        watchers[key]?.cancel()
        watchers[key] = nil
        // Живое обновление — только для файлов пользователя, не для скачанных копий.
        if baseURL == nil, !file.path.hasPrefix(AircraftPaths.viewerCache.path) {
            watchers[key] = FileWatcher(url: file) { [weak webView] in
                guard let webView else { return }
                Task { @MainActor in
                    let y = (try? await webView.evaluateJavaScript("window.scrollY") as? Double) ?? 0
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
    }

    static func page(markdown: String, title: String, scrollY: Double) -> String {
        let rendered = MarkdownRenderer.render(markdown)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let toc = rendered.headings.count >= 3 ? rendered.headings.map { heading in
            "<a href=\"#\(heading.id)\" class=\"l\(heading.level)\">\(MarkdownRenderer.escape(heading.text))</a>"
        }.joined(separator: "\n") : ""
        return """
        <!doctype html>
        <html lang="ru"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob: file:; media-src * data: file:; style-src 'unsafe-inline'; font-src * data:; script-src 'nonce-\(nonce)'; frame-src 'none'; object-src 'none'; base-uri 'self'">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>\(css)</style>
        </head>
        <body class="\(toc.isEmpty ? "" : "has-toc")">
        <header class="bar">
          <span class="name">\(MarkdownRenderer.escape(title))</span>
          <span class="spacer"></span>
          \(toc.isEmpty ? "" : "<button id=\"toggle-toc\" title=\"Оглавление\">☰</button>")
          <button id="toggle-source">Исходник</button>
        </header>
        \(toc.isEmpty ? "" : "<nav id=\"toc\">\(toc)</nav>")
        <main id="preview" class="markdown">\(rendered.html)</main>
        <pre id="source" hidden>\(MarkdownRenderer.escape(markdown))</pre>
        <script nonce="\(nonce)">\(script(scrollY: scrollY))</script>
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
    .hl-c { color: #6e7781; font-style: italic; } .hl-s { color: #0a3069; } .hl-n { color: #0550ae; } .hl-k { color: #cf222e; }
    @media (prefers-color-scheme: dark) { .hl-c { color: #8b949e; } .hl-s { color: #a5d6ff; } .hl-n { color: #79c0ff; } .hl-k { color: #ff7b72; } }
    """#

    private static func script(scrollY: Double) -> String {
        "const initialScroll = \(Int(scrollY));\n" + #"""
        (() => {
          if (initialScroll > 0) requestAnimationFrame(() => window.scrollTo(0, initialScroll));
          const preview = document.getElementById('preview');
          const source = document.getElementById('source');
          const sourceButton = document.getElementById('toggle-source');
          sourceButton.addEventListener('click', () => {
            const showSource = source.hidden;
            source.hidden = !showSource;
            preview.hidden = showSource;
            sourceButton.classList.toggle('on', showSource);
            sourceButton.textContent = showSource ? 'Просмотр' : 'Исходник';
          });
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
          document.querySelectorAll('pre code[data-lang]').forEach((block) => {
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
          });
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
