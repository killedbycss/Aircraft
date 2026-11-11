import Foundation
import WebKit

/// Режим чтения: статья извлекается из страницы и показывается поверх неё в закрытом
/// Shadow DOM со своей вёрсткой. Скрипт работает в изолированном мире — страница его не видит.
extension TabManager {
    /// ⌘⇧R: открыть или закрыть режим чтения в активной вкладке.
    public func toggleReaderMode() {
        guard let id = activeTabID, let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].content == .web, let webView = tabs[index].webView else {
            NSSound.beep()
            return
        }
        let opening = !tabs[index].isReaderActive
        Task { @MainActor in
            let result = try? await webView.callAsyncJavaScript(
                ReaderMode.source, arguments: ["open": opening, "settings": ReaderMode.settings],
                in: nil, contentWorld: .defaultClient)
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            switch result as? String {
            case "opened": tabs[index].isReaderActive = true
            case "closed": tabs[index].isReaderActive = false
            default:
                tabs[index].isReaderActive = false
                showToast("Не удалось найти статью на странице", symbol: "doc.plaintext")
            }
        }
    }

    /// После загрузки: есть ли на странице статья (тогда показывается кнопка «Режим чтения»).
    func checkReaderAvailability(tabID: UUID, webView: WKWebView) async {
        let value = try? await webView.callAsyncJavaScript(ReaderMode.probeSource, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.webView === webView }) else { return }
        let readerable = (value as? Bool) == true
        if tabs[index].isReaderable != readerable { tabs[index].isReaderable = readerable }
    }
}

enum ReaderMode {
    /// Шрифт, размер, ширина и тема — общие для всех страниц.
    static var settings: [String: Any] {
        get {
            UserDefaults.standard.dictionary(forKey: "readerSettings")
                ?? ["font": "serif", "size": 20, "width": 680, "theme": "auto"]
        }
        set { UserDefaults.standard.set(newValue, forKey: "readerSettings") }
    }

    /// Признак статьи: достаточно длинных абзацев (как `isProbablyReaderable` в Readability).
    static let probeSource = #"""
    if (!document.body || location.protocol === 'about:') return false;
    let score = 0;
    for (const node of document.querySelectorAll('p, pre, article')) {
      const text = (node.textContent || '').trim();
      if (text.length < 140) continue;
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden') continue;
      score += Math.sqrt(text.length - 140);
      if (score > 20) return true;
    }
    return false;
    """#

    static let source = #"""
    const HOST_ID = '__aircraft_reader__';
    const existing = document.getElementById(HOST_ID);
    if (!open) { if (existing) { existing.remove(); document.documentElement.style.overflow = existing.dataset.overflow || ''; } return 'closed'; }
    if (existing) return 'opened';

    // --- Поиск основного текста: оценка по абзацам, как в Readability ---
    const negative = /comment|sidebar|footer|foot|nav|menu|masthead|share|social|related|promo|advert|banner|sponsor|cookie|subscribe|popup|modal|breadcrumb|widget|tags|author-bio|newsletter|ambox|hatnote|navbox|noprint|editsection|metadata|toc|infobox|mw-jump/i;
    const positive = /article|body|content|entry|main|page|post|text|story|blog/i;
    const classScore = (el) => {
      const value = (el.className && typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
      let score = 0;
      if (negative.test(value)) score -= 25;
      if (positive.test(value)) score += 25;
      return score;
    };
    const scores = new Map();
    const add = (el, value) => { if (el && el !== document.documentElement) scores.set(el, (scores.get(el) || classScore(el)) + value); };
    for (const p of document.querySelectorAll('p, pre, td, blockquote')) {
      const text = (p.textContent || '').trim();
      if (text.length < 25) continue;
      const score = 1 + text.split(/[,،、]/).length + Math.min(Math.floor(text.length / 100), 3);
      add(p.parentElement, score);
      add(p.parentElement && p.parentElement.parentElement, score / 2);
    }
    let best = null, bestScore = 0;
    for (const [el, raw] of scores) {
      const links = [...el.querySelectorAll('a')].reduce((sum, a) => sum + (a.textContent || '').length, 0);
      const total = (el.textContent || '').length || 1;
      const score = raw * (1 - links / total);
      if (score > bestScore) { best = el; bestScore = score; }
    }
    const semantic = document.querySelector('article') || document.querySelector('[role="main"]') || document.querySelector('main');
    if (!best) best = semantic;
    else if (semantic && semantic.contains(best) && (semantic.textContent || '').length < (best.textContent || '').length * 1.3) best = semantic;
    if (!best || (best.textContent || '').trim().length < 250) return 'none';

    // --- Очистка: только текстовая разметка, без скриптов, стилей и обработчиков ---
    const keep = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','CODE','IMG','FIGURE','FIGCAPTION','A','EM','STRONG','B','I','U','S','SUB','SUP','MARK','TABLE','THEAD','TBODY','TR','TD','TH','BR','HR','DL','DT','DD','KBD','SMALL','TIME','PICTURE']);
    const drop = new Set(['SCRIPT','STYLE','NOSCRIPT','IFRAME','FORM','BUTTON','INPUT','SELECT','TEXTAREA','NAV','ASIDE','FOOTER','SVG','CANVAS','VIDEO','AUDIO','OBJECT','EMBED','DIALOG','TEMPLATE','LINK','META']);
    const doc = document.implementation.createHTMLDocument('');
    const absolute = (value) => { try { return new URL(value, location.href).href; } catch (e) { return ''; } };
    const clean = (node) => {
      if (node.nodeType === Node.TEXT_NODE) return doc.createTextNode(node.textContent);
      if (node.nodeType !== Node.ELEMENT_NODE) return null;
      const tag = node.tagName;
      if (drop.has(tag)) return null;
      if (node !== best && negative.test(((typeof node.className === 'string' ? node.className : '') + ' ' + (node.id || ''))) && (node.textContent || '').length < 600) return null;
      const style = node.ownerDocument.defaultView.getComputedStyle(node);
      if (style && (style.display === 'none' || style.visibility === 'hidden')) return null;
      let out;
      if (tag === 'IMG') {
        const src = node.currentSrc || node.getAttribute('src') || node.getAttribute('data-src') || '';
        if (!src || src.startsWith('data:image/gif') || (node.naturalWidth && node.naturalWidth < 48)) return null;
        out = doc.createElement('img');
        out.src = absolute(src);
        if (node.alt) out.alt = node.alt;
        return out;
      }
      if (tag === 'PICTURE') {
        const img = node.querySelector('img');
        return img ? clean(img) : null;
      }
      out = keep.has(tag) ? doc.createElement(tag) : doc.createDocumentFragment();
      if (tag === 'A') {
        const href = absolute(node.getAttribute('href') || '');
        if (href && !href.startsWith('javascript:')) out.setAttribute('href', href);
      }
      for (const child of node.childNodes) { const cleaned = clean(child); if (cleaned) out.appendChild(cleaned); }
      // Блоки-обёртки (div, section) становятся абзацами, если внутри только текст.
      if (!keep.has(tag) && ['DIV','SECTION','ARTICLE','MAIN','HEADER'].includes(tag)) {
        const hasBlock = node.querySelector('p,div,h1,h2,h3,h4,ul,ol,pre,blockquote,table,figure,img');
        if (!hasBlock && (node.textContent || '').trim().length > 0) {
          const p = doc.createElement('p');
          p.appendChild(out);
          return p;
        }
      }
      return out;
    };
    const content = doc.createElement('div');
    const cleaned = clean(best);
    if (cleaned) content.appendChild(cleaned);
    // Убираем пустые абзацы и дубль заголовка.
    content.querySelectorAll('p, li, h2, h3').forEach(el => { if (!el.textContent.trim() && !el.querySelector('img')) el.remove(); });

    const meta = (name) => (document.querySelector(`meta[property="${name}"], meta[name="${name}"]`) || {}).content || '';
    const h1 = ((document.querySelector('h1') || {}).textContent || '').trim();
    const pageTitle = meta('og:title') || document.title || '';
    const title = h1 && pageTitle.includes(h1) ? h1 : (pageTitle || h1);
    content.querySelectorAll('h1').forEach(el => { if (el.textContent.trim() === title.trim()) el.remove(); });
    const site = meta('og:site_name') || location.hostname.replace(/^www\./, '');
    const byline = meta('author') || meta('article:author');
    const words = (content.textContent || '').trim().split(/\s+/).length;
    const minutes = Math.max(1, Math.round(words / 200));

    // --- Вёрстка ---
    const host = document.createElement('div');
    host.id = HOST_ID;
    host.dataset.overflow = document.documentElement.style.overflow || '';
    host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;';
    const root = host.attachShadow({ mode: 'closed' });
    const themes = {
      light: ['#ffffff', '#1d1d1f', '#6e6e73', '#0a64d8'],
      sepia: ['#f8f1e3', '#4f3b26', '#8b7355', '#9c5a1a'],
      dark: ['#1c1c1e', '#e5e5e7', '#98989d', '#5eaaff']
    };
    const state = Object.assign({ font: 'serif', size: 20, width: 680, theme: 'auto' }, settings || {});
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .page { position: absolute; inset: 0; overflow: auto; background: var(--bg); color: var(--fg); transition: background .2s, color .2s; }
        .bar { position: sticky; top: 0; display: flex; gap: 6px; justify-content: flex-end; align-items: center; padding: 10px 16px; background: color-mix(in srgb, var(--bg) 85%, transparent); backdrop-filter: blur(10px); font: 12px -apple-system, sans-serif; z-index: 2; }
        .bar button { font: inherit; border: 1px solid color-mix(in srgb, var(--fg) 18%, transparent); background: transparent; color: var(--fg); border-radius: 7px; height: 26px; min-width: 30px; padding: 0 8px; cursor: pointer; }
        .bar button.swatch { width: 24px; min-width: 24px; padding: 0; border-radius: 50%; }
        .bar .grow { flex: 1; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        article { max-width: var(--width); margin: 0 auto; padding: 24px 28px 120px; font-size: var(--size); line-height: 1.65; font-family: var(--font); }
        .site { font: 600 13px -apple-system, sans-serif; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
        h1.title { font-size: 1.9em; line-height: 1.2; margin: .3em 0 .3em; }
        .meta { font: 13px -apple-system, sans-serif; color: var(--muted); margin-bottom: 2em; }
        a { color: var(--link); }
        img { max-width: 100%; height: auto; border-radius: 6px; display: block; margin: 1.2em auto; }
        figcaption { font: 13px -apple-system, sans-serif; color: var(--muted); text-align: center; }
        pre { overflow: auto; padding: 12px 14px; border-radius: 8px; background: color-mix(in srgb, var(--fg) 7%, transparent); font-size: .8em; line-height: 1.5; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: .88em; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid color-mix(in srgb, var(--fg) 25%, transparent); color: var(--muted); }
        table { border-collapse: collapse; font-size: .85em; display: block; overflow: auto; }
        td, th { border: 1px solid color-mix(in srgb, var(--fg) 18%, transparent); padding: 4px 8px; }
        h2, h3, h4 { line-height: 1.3; margin-top: 1.6em; }
      </style>
      <div class="page">
        <div class="bar">
          <span class="grow">Режим чтения · ${minutes} мин</span>
          <button data-a="smaller" title="Меньше">A−</button>
          <button data-a="bigger" title="Больше">A+</button>
          <button data-a="font" title="Шрифт">Aa</button>
          <button data-a="narrow" title="Уже">⇥⇤</button>
          <button data-a="wide" title="Шире">⇤⇥</button>
          <button class="swatch" data-a="light" style="background:#fff"></button>
          <button class="swatch" data-a="sepia" style="background:#f8f1e3"></button>
          <button class="swatch" data-a="dark" style="background:#1c1c1e"></button>
          <button data-a="close" title="Закрыть (Esc)">✕</button>
        </div>
        <article>
          <div class="site"></div>
          <h1 class="title"></h1>
          <div class="meta"></div>
          <div class="content"></div>
        </article>
      </div>`;
    root.querySelector('.site').textContent = site;
    root.querySelector('.title').textContent = title.trim();
    root.querySelector('.meta').textContent = [byline, `${minutes} мин чтения`].filter(Boolean).join(' · ');
    root.querySelector('.content').appendChild(content);
    const page = root.querySelector('.page');
    const apply = () => {
      const dark = matchMedia('(prefers-color-scheme: dark)').matches;
      const theme = themes[state.theme === 'auto' ? (dark ? 'dark' : 'light') : state.theme] || themes.light;
      page.style.setProperty('--bg', theme[0]);
      page.style.setProperty('--fg', theme[1]);
      page.style.setProperty('--muted', theme[2]);
      page.style.setProperty('--link', theme[3]);
      page.style.setProperty('--size', state.size + 'px');
      page.style.setProperty('--width', state.width + 'px');
      page.style.setProperty('--font', state.font === 'serif' ? '"New York", "Iowan Old Style", Georgia, serif' : '-apple-system, "SF Pro Text", sans-serif');
    };
    const save = () => { try { window.webkit.messageHandlers.aircraftSignals.postMessage({ type: 'readerSettings', settings: state }); } catch (e) {} };
    const close = () => {
      host.remove();
      document.documentElement.style.overflow = host.dataset.overflow;
      try { window.webkit.messageHandlers.aircraftSignals.postMessage({ type: 'reader', active: false }); } catch (e) {}
    };
    root.querySelector('.bar').addEventListener('click', (event) => {
      const action = event.target.dataset && event.target.dataset.a;
      if (!action) return;
      if (action === 'close') return close();
      if (action === 'smaller') state.size = Math.max(14, state.size - 2);
      if (action === 'bigger') state.size = Math.min(32, state.size + 2);
      if (action === 'font') state.font = state.font === 'serif' ? 'sans' : 'serif';
      if (action === 'narrow') state.width = Math.max(520, state.width - 80);
      if (action === 'wide') state.width = Math.min(1000, state.width + 80);
      if (['light', 'sepia', 'dark'].includes(action)) state.theme = action;
      apply();
      save();
    });
    addEventListener('keydown', function onKey(event) {
      if (event.key === 'Escape' && document.getElementById(HOST_ID)) { close(); removeEventListener('keydown', onKey, true); }
    }, true);
    apply();
    document.documentElement.style.overflow = 'hidden';
    document.documentElement.appendChild(host);
    page.focus();
    return 'opened';
    """#
}
