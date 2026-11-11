import AppKit
import WebKit

/// Пипетка «Скрыть элемент»: подсвечивает элемент под курсором, по клику прячет его и
/// сохраняет правило `сайт##селектор` в свои правила блокировщика.
@MainActor
enum ElementPicker {
    /// Запускает пипетку в странице. Возвращает добавленное правило или nil, если отменили.
    @discardableResult
    static func start(in webView: WKWebView) async -> String? {
        guard let host = AdBlocker.normalizedHost(webView.url?.host),
              webView.url?.scheme == "http" || webView.url?.scheme == "https" else {
            NSSound.beep()
            return nil
        }
        webView.window?.makeKeyAndOrderFront(nil)
        webView.window?.makeFirstResponder(webView)
        // Изолированный мир: страница не видит и не может подделать пипетку.
        let value = try? await webView.callAsyncJavaScript(pickerSource, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let selector = value as? String, !selector.isEmpty else { return nil }
        let rule = "\(host)##\(selector)"
        FilterListStore.shared.appendCustomRule(rule)
        return rule
    }

    /// Пипетка в первом окне браузера (например, по кнопке из окна настроек).
    static func startInFrontmostWindow() {
        guard let webView = AgentBrowser.frontmostManager?.activeWebView else {
            NSSound.beep()
            return
        }
        Task { await start(in: webView) }
    }

    private static let pickerSource = #"""
    return await new Promise((resolve) => {
      if (window.__aircraftPickerActive) { resolve(null); return; }
      window.__aircraftPickerActive = true;

      const host = document.createElement('div');
      host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
      const shadow = host.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `
        <style>
          .box { position: fixed; background: rgba(255,59,48,.16); outline: 2px solid #ff3b30;
                 border-radius: 3px; pointer-events: none; transition: all .05s; display: none; }
          .bar { position: fixed; left: 50%; bottom: 22px; transform: translateX(-50%);
                 display: flex; align-items: center; gap: 12px; max-width: min(860px, 92vw);
                 padding: 10px 12px 10px 16px; border-radius: 14px; pointer-events: auto;
                 background: rgba(28,28,30,.94); color: #fff; box-shadow: 0 10px 34px rgba(0,0,0,.4);
                 font: 13px -apple-system, system-ui, sans-serif; }
          .sel { flex: 1; min-width: 0; font: 12px ui-monospace, Menlo, monospace; color: #ffd60a;
                 overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .hint { color: #a1a1a6; white-space: nowrap; }
          button { font: inherit; border: 0; border-radius: 8px; padding: 6px 12px; cursor: pointer; }
          .ok { background: #ff3b30; color: #fff; } .ok:disabled { opacity: .4; cursor: default; }
          .cancel { background: #3a3a3c; color: #fff; }
        </style>
        <div class="box"></div>
        <div class="bar">
          <span class="sel">Наведите на рекламу и кликните</span>
          <span class="hint">↑ шире · ↓ уже · Esc отмена</span>
          <button class="cancel">Отмена</button>
          <button class="ok" disabled>Скрыть</button>
        </div>`;
      document.documentElement.appendChild(host);
      const box = shadow.querySelector('.box');
      const label = shadow.querySelector('.sel');
      const okButton = shadow.querySelector('.ok');
      const bar = shadow.querySelector('.bar');

      let current = null;
      let locked = false;
      const history = [];

      const stableId = (id) => /^[A-Za-z][\w-]*$/.test(id) && !/\d{4,}/.test(id);
      const stableClass = (c) => /^[A-Za-z_-][\w-]*$/.test(c) && c.length < 40 && !/\d{3,}/.test(c)
        && !/^(is-|has-|js-)?(active|hover|focus|open|opened|show|shown|visible|selected|loaded|sticky)$/.test(c);
      const unique = (sel, el) => { try { const m = document.querySelectorAll(sel); return m.length === 1 && m[0] === el; } catch (e) { return false; } };

      function part(el) {
        if (el.id && stableId(el.id)) return '#' + CSS.escape(el.id);
        let s = el.localName;
        const classes = [...el.classList].filter(stableClass).slice(0, 3);
        s += classes.map((c) => '.' + CSS.escape(c)).join('');
        const parent = el.parentElement;
        if (parent) {
          const sameTag = [...parent.children].filter((c) => c.localName === el.localName);
          const sameSel = sameTag.filter((c) => { try { return c.matches(s); } catch (e) { return false; } });
          if (sameSel.length > 1) s += ':nth-of-type(' + (sameTag.indexOf(el) + 1) + ')';
        }
        return s;
      }

      function selectorFor(el) {
        const path = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement && node !== document.body) {
          const p = part(node);
          path.unshift(p);
          const sel = path.join(' > ');
          if (unique(sel, el)) return sel;
          if (p.startsWith('#')) break;
          node = node.parentElement;
        }
        return path.join(' > ');
      }

      function show(el) {
        current = el;
        if (!el) { box.style.display = 'none'; okButton.disabled = true; return; }
        const r = el.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        label.textContent = selectorFor(el);
        okButton.disabled = false;
      }

      function insidePicker(e) { return e.composedPath().includes(host); }

      function onMove(e) {
        if (locked || insidePicker(e)) return;
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (el && el !== host && el !== current) { history.length = 0; show(el); }
      }

      function finish(selector) {
        window.removeEventListener('mousemove', onMove, true);
        window.removeEventListener('keydown', onKey, true);
        for (const type of ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu']) {
          window.removeEventListener(type, onBlock, true);
        }
        window.removeEventListener('scroll', onScroll, true);
        host.remove();
        window.__aircraftPickerActive = false;
        resolve(selector);
      }

      function confirm() {
        if (!current) return;
        const selector = selectorFor(current);
        try { document.querySelectorAll(selector).forEach((el) => el.style.setProperty('display', 'none', 'important')); } catch (e) {}
        finish(selector);
      }

      function onBlock(e) {
        if (insidePicker(e)) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        if (e.type === 'click') { locked = true; confirm(); }
      }

      function onKey(e) {
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(null); }
        else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); confirm(); }
        else if (e.key === 'ArrowUp' && current && current.parentElement && current.parentElement !== document.body) {
          e.preventDefault(); history.push(current); locked = true; show(current.parentElement);
        } else if (e.key === 'ArrowDown' && history.length) {
          e.preventDefault(); show(history.pop());
        }
      }

      function onScroll() { if (current) show(current); }

      shadow.querySelector('.cancel').addEventListener('click', () => finish(null));
      okButton.addEventListener('click', confirm);
      bar.addEventListener('mouseenter', () => { locked = true; });
      bar.addEventListener('mouseleave', () => { locked = false; });
      window.addEventListener('mousemove', onMove, true);
      window.addEventListener('keydown', onKey, true);
      for (const type of ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu']) {
        window.addEventListener(type, onBlock, true);
      }
      window.addEventListener('scroll', onScroll, true);
    });
    """#
}
