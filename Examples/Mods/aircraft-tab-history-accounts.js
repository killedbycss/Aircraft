// Aircraft-мод «История и аккаунты» · Aircraft Mod SDK 0.2
// Локальный журнал переходов и список сайтов, где выполнен вход.
// Открыть/закрыть — ⌘Y или кнопка «История и аккаунты» на панели вкладок; Esc — закрыть.
// Пароли, cookies, токены и значения полей форм не читаются и не сохраняются.
(() => {
  "use strict";
  if (window.top !== window || window.__aircraftHistoryMod) return;
  window.__aircraftHistoryMod = true;

  const HISTORY_KEY = "session.history";
  const ACCOUNTS_KEY = "session.accounts";
  const HISTORY_LIMIT = 300;
  const ACCOUNTS_LIMIT = 100;

  const start = () => {
    const api = window.aircraft;
    if (!api) return;
    api.post("registerCapability", { capability: "historyAccounts" });

    // Всегда читаем свежие данные из хранилища: его обновляют и другие вкладки.
    const readList = (key) => {
      const value = api.storage.get(key, []);
      return Array.isArray(value) ? value : [];
    };

    // ---------- Запись истории ----------

    const currentEntry = () => ({
      url: location.href,
      title: (document.title || "").trim() || location.hostname,
      host: location.hostname,
      visitedAt: Date.now()
    });

    const saveVisit = () => {
      if (!/^https?:$/.test(location.protocol)) return;
      const entry = currentEntry();
      const history = readList(HISTORY_KEY);
      const latest = history[0];
      if (latest && latest.url === entry.url) {
        // Повторный заход на ту же страницу — обновляем время и заголовок, без дубликата.
        if (Date.now() - latest.visitedAt < 5000 && latest.title === entry.title) return;
        history[0] = { ...latest, title: entry.title, visitedAt: entry.visitedAt };
      } else {
        history.unshift(entry);
      }
      api.storage.set(HISTORY_KEY, history.slice(0, HISTORY_LIMIT));
    };

    // Заголовок часто появляется уже после загрузки (SPA) — дописываем его в запись.
    const updateTitle = () => {
      const title = (document.title || "").trim();
      if (!title) return;
      const history = readList(HISTORY_KEY);
      const index = history.findIndex((item) => item.url === location.href);
      if (index === -1 || index > 5 || history[index].title === title) return;
      history[index] = { ...history[index], title };
      api.storage.set(HISTORY_KEY, history);
    };

    // ---------- Обнаружение входа ----------

    // Сохраняются только видимые подписи аккаунта/профиля.
    const detectAccount = () => {
      if (!/^https?:$/.test(location.protocol)) return;
      const candidates = [...document.querySelectorAll('a,button,[role="button"],[role="menuitem"]')].slice(0, 1500);
      const signOut = candidates.find((node) =>
        /(^|\s)(sign\s*out|log\s*out|logout|signout|выйти|выход)(\s|$)/i.test((node.textContent || node.getAttribute("aria-label") || "").trim()));
      const accountNodes = [...document.querySelectorAll(
        '[aria-label*="account" i],[aria-label*="profile" i],[aria-label*="аккаунт" i],[aria-label*="профиль" i],[data-testid*="account" i],[data-account-index]'
      )].slice(0, 20);
      if (!signOut && !accountNodes.length) return;
      const labels = accountNodes
        .map((node) => node.getAttribute("aria-label") || (node.textContent || "").trim())
        .filter(Boolean)
        .map((label) => label.replace(/\s+/g, " ").slice(0, 120));
      if (!labels.length) labels.push("Вход выполнен");
      const label = [...new Set(labels)][0];
      const accounts = readList(ACCOUNTS_KEY).filter((item) => item.host !== location.hostname);
      accounts.unshift({ host: location.hostname, label, url: location.origin, lastSeen: Date.now() });
      api.storage.set(ACCOUNTS_KEY, accounts.slice(0, ACCOUNTS_LIMIT));
    };

    // ---------- Интерфейс ----------

    const host = document.createElement("div");
    host.id = "aircraft-history-host";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial}
      .panel{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#0000001a;--hover:#0000000a;--accent:#0a84ff;
        position:fixed;z-index:2147483647;inset:0;display:none;flex-direction:column;background:var(--bg);color:var(--text);
        font:13px/1.35 -apple-system,BlinkMacSystemFont,sans-serif;-webkit-font-smoothing:antialiased}
      @media (prefers-color-scheme:dark){.panel{--bg:#1c1c1e;--card:#2c2c2e;--text:#f5f5f7;--muted:#98989d;--line:#ffffff1f;--hover:#ffffff0f}}
      .panel.open{display:flex}
      .head{display:flex;align-items:center;gap:12px;padding:20px 24px 12px;max-width:860px;width:100%;box-sizing:border-box;margin:0 auto}
      .title{font-size:22px;font-weight:700;flex:1}
      .seg{display:flex;background:var(--hover);border-radius:8px;padding:2px}
      .seg button{border:0;background:transparent;color:inherit;font:inherit;padding:5px 14px;border-radius:6px;cursor:pointer}
      .seg button.active{background:var(--card);box-shadow:0 1px 2px #0000001f;font-weight:600}
      .close{border:0;background:var(--hover);color:inherit;width:28px;height:28px;border-radius:14px;cursor:pointer;font-size:13px}
      .tools{display:flex;gap:8px;padding:0 24px 12px;max-width:860px;width:100%;box-sizing:border-box;margin:0 auto}
      .search{flex:1;border:1px solid var(--line);background:var(--card);color:inherit;font:inherit;padding:7px 10px;border-radius:8px;outline:none}
      .search:focus{border-color:var(--accent);box-shadow:0 0 0 3px #0a84ff33}
      .clear{border:1px solid var(--line);background:var(--card);color:#ff453a;font:inherit;padding:0 12px;border-radius:8px;cursor:pointer}
      .content{flex:1;overflow:auto;padding:0 24px 32px;max-width:860px;width:100%;box-sizing:border-box;margin:0 auto}
      .day{font-size:12px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.03em;margin:18px 4px 6px}
      .group{background:var(--card);border-radius:12px;overflow:hidden;box-shadow:0 0 0 1px var(--line)}
      .row{display:flex;align-items:center;gap:12px;padding:9px 12px;cursor:pointer;position:relative}
      .row+.row{border-top:1px solid var(--line)}
      .row:hover{background:var(--hover)}
      .icon{flex:none;width:28px;height:28px;border-radius:7px;display:grid;place-items:center;color:#fff;font-weight:700;font-size:13px}
      .text{flex:1;min-width:0}
      .name{font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .meta{color:var(--muted);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .time{color:var(--muted);font-size:11px;flex:none}
      .remove{flex:none;border:0;background:transparent;color:var(--muted);width:24px;height:24px;border-radius:12px;cursor:pointer;visibility:hidden}
      .row:hover .remove{visibility:visible}
      .remove:hover{background:var(--hover);color:var(--text)}
      .empty{color:var(--muted);padding:64px 10px;text-align:center}
      .hint{color:var(--muted);font-size:11px;text-align:center;margin-top:16px}
    </style>
    <section class="panel" role="dialog" aria-label="История и аккаунты">
      <header class="head">
        <span class="title">История</span>
        <div class="seg"><button data-tab="history">История</button><button data-tab="accounts">Аккаунты</button></div>
        <button class="close" data-close title="Закрыть (Esc)">✕</button>
      </header>
      <div class="tools">
        <input class="search" type="search" placeholder="Поиск по названию или адресу" autocomplete="off" spellcheck="false">
        <button class="clear" data-clear>Очистить</button>
      </div>
      <main class="content"></main>
    </section>`;
    document.documentElement.append(host);

    const panel = root.querySelector(".panel");
    const content = root.querySelector(".content");
    const search = root.querySelector(".search");
    const titleNode = root.querySelector(".title");
    const clearButton = root.querySelector("[data-clear]");
    let active = "history";

    const colorFor = (text) => {
      let hash = 0;
      for (const char of text) hash = (hash * 31 + char.charCodeAt(0)) | 0;
      return `hsl(${Math.abs(hash) % 360} 55% 50%)`;
    };

    const dayLabel = (time) => {
      const date = new Date(time);
      const today = new Date(); today.setHours(0, 0, 0, 0);
      const diff = Math.round((today - new Date(date).setHours(0, 0, 0, 0)) / 86400000);
      if (diff === 0) return "Сегодня";
      if (diff === 1) return "Вчера";
      return date.toLocaleDateString("ru-RU", { weekday: "long", day: "numeric", month: "long" });
    };

    const timeLabel = (time) => new Date(time).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });

    const makeRow = ({ title, meta, time, hostName, onOpen, onRemove }) => {
      const row = document.createElement("div");
      row.className = "row";
      row.title = meta;
      const icon = document.createElement("span");
      icon.className = "icon";
      icon.style.background = colorFor(hostName || "?");
      icon.textContent = (hostName || "?").replace(/^www\./, "").charAt(0).toUpperCase();
      const text = document.createElement("div");
      text.className = "text";
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = title;
      const metaNode = document.createElement("div");
      metaNode.className = "meta";
      metaNode.textContent = meta;
      text.append(name, metaNode);
      const timeNode = document.createElement("span");
      timeNode.className = "time";
      timeNode.textContent = time;
      const remove = document.createElement("button");
      remove.className = "remove";
      remove.title = "Удалить";
      remove.textContent = "✕";
      remove.onclick = (event) => { event.stopPropagation(); onRemove(); };
      row.append(icon, text, timeNode, remove);
      row.onclick = (event) => onOpen(event.metaKey);
      return row;
    };

    const open = (url, inNewTab) => {
      close();
      if (inNewTab) api.openTab(url);
      else location.href = url;
    };

    const renderHistory = (query) => {
      const history = readList(HISTORY_KEY).filter((item) =>
        !query || `${item.title} ${item.url}`.toLowerCase().includes(query));
      if (!history.length) {
        content.innerHTML = `<div class="empty"></div>`;
        content.firstChild.textContent = query ? "Ничего не найдено" : "История пока пуста";
        return;
      }
      const nodes = [];
      let group = null;
      let currentDay = "";
      for (const item of history) {
        const day = dayLabel(item.visitedAt);
        if (day !== currentDay) {
          currentDay = day;
          const heading = document.createElement("div");
          heading.className = "day";
          heading.textContent = day;
          group = document.createElement("div");
          group.className = "group";
          nodes.push(heading, group);
        }
        group.append(makeRow({
          title: item.title || item.host,
          meta: item.url,
          time: timeLabel(item.visitedAt),
          hostName: item.host,
          onOpen: (newTab) => open(item.url, newTab),
          onRemove: () => api.storage.set(HISTORY_KEY,
            readList(HISTORY_KEY).filter((entry) => !(entry.url === item.url && entry.visitedAt === item.visitedAt)))
        }));
      }
      const hint = document.createElement("div");
      hint.className = "hint";
      hint.textContent = "Клик — открыть здесь, ⌘-клик — в новой вкладке";
      content.replaceChildren(...nodes, hint);
    };

    const renderAccounts = (query) => {
      const accounts = readList(ACCOUNTS_KEY).filter((item) =>
        !query || `${item.label} ${item.host}`.toLowerCase().includes(query));
      if (!accounts.length) {
        content.innerHTML = `<div class="empty"></div>`;
        content.firstChild.textContent = query ? "Ничего не найдено" : "Пока не найдено сайтов со входом";
        return;
      }
      const group = document.createElement("div");
      group.className = "group";
      for (const item of accounts) {
        group.append(makeRow({
          title: item.host,
          meta: item.label,
          time: `${dayLabel(item.lastSeen)}, ${timeLabel(item.lastSeen)}`,
          hostName: item.host,
          onOpen: (newTab) => open(item.url || `https://${item.host}/`, newTab),
          onRemove: () => api.storage.set(ACCOUNTS_KEY, readList(ACCOUNTS_KEY).filter((entry) => entry.host !== item.host))
        }));
      }
      const hint = document.createElement("div");
      hint.className = "hint";
      hint.textContent = "Хранятся только видимые подписи профиля — без паролей и cookies";
      content.replaceChildren(group, hint);
    };

    const render = () => {
      if (!panel.classList.contains("open")) return;
      root.querySelectorAll("[data-tab]").forEach((button) => button.classList.toggle("active", button.dataset.tab === active));
      titleNode.textContent = active === "history" ? "История" : "Аккаунты";
      clearButton.textContent = active === "history" ? "Очистить историю" : "Очистить список";
      const query = search.value.trim().toLowerCase();
      if (active === "history") renderHistory(query); else renderAccounts(query);
    };

    const show = () => {
      panel.classList.add("open");
      render();
      setTimeout(() => search.focus(), 0);
    };
    const close = () => panel.classList.remove("open");
    const toggle = () => (panel.classList.contains("open") ? close() : show());

    root.querySelector("[data-close]").onclick = close;
    root.querySelectorAll("[data-tab]").forEach((button) => {
      button.onclick = () => { active = button.dataset.tab; render(); };
    });
    search.addEventListener("input", render);
    clearButton.onclick = () => {
      const isHistory = active === "history";
      if (!confirm(isHistory ? "Удалить всю историю?" : "Очистить список аккаунтов?")) return;
      api.storage.set(isHistory ? HISTORY_KEY : ACCOUNTS_KEY, []);
    };

    window.addEventListener("aircraft:toggleHistoryAccounts", toggle);
    window.addEventListener("keydown", (event) => {
      if (event.metaKey && !event.shiftKey && !event.altKey && event.code === "KeyY") {
        event.preventDefault();
        event.stopPropagation();
        toggle();
      } else if (event.key === "Escape" && panel.classList.contains("open")) {
        event.preventDefault();
        event.stopPropagation();
        close();
      }
    }, true);

    // Данные изменились в этой или другой вкладке — перерисовываем открытую панель.
    window.addEventListener("aircraft:storage", (event) => {
      const key = event.detail?.key;
      if (key === HISTORY_KEY || key === ACCOUNTS_KEY) render();
    });

    // ---------- Отслеживание переходов ----------

    for (const method of ["pushState", "replaceState"]) {
      const original = window.history?.[method];
      if (typeof original !== "function") continue;
      window.history[method] = function (...args) {
        const result = original.apply(this, args);
        queueMicrotask(saveVisit);
        return result;
      };
    }
    window.addEventListener("popstate", saveVisit);
    window.addEventListener("hashchange", saveVisit);

    const titleElement = document.querySelector("title");
    if (titleElement) {
      new MutationObserver(updateTitle).observe(titleElement, { childList: true, characterData: true, subtree: true });
    }
    window.addEventListener("load", () => { updateTitle(); setTimeout(detectAccount, 1500); }, { once: true });

    saveVisit();
    if (document.readyState === "complete") setTimeout(detectAccount, 1500);
  };

  if (window.aircraft) start();
  else window.addEventListener("aircraft:ready", start, { once: true });
})();
