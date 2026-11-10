(() => {
  "use strict";
  if (window.top !== window || window.__aircraftHistoryMod) return;
  window.__aircraftHistoryMod = true;

  const start = () => {
    const api = window.aircraft;
    if (!api) return;
    api.post("registerCapability", { capability: "historyAccounts" });
    const historyKey = "session.history";
    const accountsKey = "session.accounts";
    let history = api.storage.get(historyKey, []);
    let accounts = api.storage.get(accountsKey, []);

    const saveVisit = () => {
      if (!/^https?:$/.test(location.protocol)) return;
      const entry = { url: location.href, title: document.title || location.hostname, host: location.hostname, visitedAt: Date.now() };
      if (history[0]?.url === entry.url && Date.now() - history[0].visitedAt < 5000) return;
      history.unshift(entry);
      history = history.slice(0, 300);
      api.storage.set(historyKey, history);
      render();
    };

    // Account discovery remains privacy-preserving: only visible account/profile labels
    // are stored. Passwords, cookies, tokens and form values are never accessed.
    const detectAccount = () => {
      const candidates = [...document.querySelectorAll('a,button,[role="button"]')].slice(0, 1200);
      const signOut = candidates.find((node) => /(^|\s)(sign\s*out|log\s*out|выйти|выход)(\s|$)/i.test((node.textContent || "").trim()));
      const accountNodes = [...document.querySelectorAll('[aria-label*="account" i],[aria-label*="profile" i],[data-testid*="account" i],[data-account-index]')];
      if (!signOut && !accountNodes.length) return;
      const labels = accountNodes.map((node) => node.getAttribute("aria-label") || node.textContent?.trim())
        .filter(Boolean).map((label) => label.replace(/\s+/g, " ").slice(0, 120));
      if (!labels.length) labels.push("Вход выполнен");
      const discovered = [...new Set(labels)].map((label) => ({ host: location.hostname, label, lastSeen: Date.now() }));
      accounts = [...discovered, ...accounts.filter((entry) => entry.host !== location.hostname)].slice(0, 100);
      api.storage.set(accountsKey, accounts);
      render();
    };

    const host = document.createElement("div");
    host.id = "aircraft-history-host";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial}.panel{position:fixed;z-index:2147483647;inset:0;display:none;flex-direction:column;background:#f6f6f6;color:#171717;font:13px -apple-system,sans-serif;overflow:hidden}.panel.open{display:flex}.head{display:flex;align-items:center;gap:8px;padding:18px 22px;border-bottom:1px solid #7773}.title{font-size:20px;font-weight:700;flex:1}.head button,.tabs button{border:0;background:transparent;color:inherit}.tabs{display:flex;gap:4px;padding:12px 22px}.tabs button{padding:8px 12px;border-radius:8px}.tabs button.active{background:#00000012}.content{overflow:auto;padding:0 22px 24px;max-width:980px;width:100%;box-sizing:border-box;margin:0 auto}.row{display:grid;grid-template-columns:1fr auto;gap:3px 18px;padding:12px;border-radius:10px}.row:hover{background:#0000000a}.name{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta{color:#6b6b6b;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.time{color:#777;font-size:11px}.empty{color:#777;padding:48px 10px;text-align:center}
    </style><section class="panel"><header class="head"><span class="title">Журнал Aircraft</span><button data-close>✕</button></header><nav class="tabs"><button data-tab="history">История</button><button data-tab="accounts">Аккаунты</button></nav><main class="content"></main></section>`;
    document.documentElement.append(host);
    const panel = root.querySelector(".panel");
    const content = root.querySelector(".content");
    let active = "history";
    const render = () => {
      if (!panel.classList.contains("open")) return;
      root.querySelectorAll("[data-tab]").forEach((button) => button.classList.toggle("active", button.dataset.tab === active));
      const data = active === "history" ? history : accounts;
      if (!data.length) { content.innerHTML = `<div class="empty">Пока нет данных</div>`; return; }
      content.replaceChildren(...data.map((entry) => {
        const row = document.createElement("div");
        row.className = "row";
        const title = active === "history" ? entry.title : entry.label;
        row.innerHTML = `<span class="name"></span><span class="time"></span><span class="meta"></span>`;
        row.children[0].textContent = title;
        row.children[1].textContent = new Date(active === "history" ? entry.visitedAt : entry.lastSeen).toLocaleString();
        row.children[2].textContent = entry.host;
        if (active === "history") { row.style.cursor = "pointer"; row.onclick = () => api.openTab(entry.url); }
        return row;
      }));
    };
    root.querySelector("[data-close]").onclick = () => panel.classList.remove("open");
    window.addEventListener("aircraft:toggleHistoryAccounts", () => { panel.classList.toggle("open"); render(); });
    root.querySelectorAll("[data-tab]").forEach((button) => button.onclick = () => { active = button.dataset.tab; render(); });
    window.addEventListener("keydown", (event) => {
      if (event.metaKey && event.key.toLowerCase() === "y") {
        event.preventDefault();
        panel.classList.toggle("open");
        render();
      }
    }, true);

    for (const method of ["pushState", "replaceState"]) {
      const original = historyAPI(method);
      if (!original) continue;
      window.history[method] = function (...args) {
        const result = original.apply(this, args);
        queueMicrotask(saveVisit);
        return result;
      };
    }
    function historyAPI(method) { return window.history?.[method]; }
    window.addEventListener("popstate", saveVisit);
    window.addEventListener("hashchange", saveVisit);
    saveVisit();
    setTimeout(detectAccount, 1500);
  };

  if (window.aircraft) start();
  else window.addEventListener("aircraft:ready", start, { once: true });
})();
