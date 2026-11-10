(() => {
  "use strict";
  if (window.top !== window || window.__aircraftDevtoolsMod) return;
  window.__aircraftDevtoolsMod = true;

  const start = () => {
    const api = window.aircraft;
    if (!api) return;
    api.post("registerCapability", { capability: "devtools" });
    api.enableDevTools();

    /* The actual inspector is provided by WKWebView (Safari Develop menu).
       Keeping the bridge registration preserves compatibility for local mods. */
    return;
    const listeners = new Set();
    const emit = (...args) => listeners.forEach((listener) => listener(...args));
    const extensionStoreKey = "devtools.webextensions.storage";

    // Lightweight WebExtensions compatibility layer. It intentionally covers only
    // runtime messaging, storage.local and opening tabs; it is not a CRX loader.
    const chrome = window.chrome || {};
    chrome.runtime = chrome.runtime || {};
    chrome.runtime.id = chrome.runtime.id || "aircraft-local-mod";
    chrome.runtime.getURL = (path = "") => `aircraft-extension://${String(path).replace(/^\//, "")}`;
    chrome.runtime.onMessage = chrome.runtime.onMessage || {
      addListener: (listener) => listeners.add(listener),
      removeListener: (listener) => listeners.delete(listener),
      hasListener: (listener) => listeners.has(listener)
    };
    chrome.runtime.sendMessage = (message, callback) => {
      emit(message, { id: chrome.runtime.id, url: location.href }, callback || (() => {}));
      callback?.();
      return Promise.resolve();
    };
    chrome.storage = chrome.storage || {};
    chrome.storage.local = {
      get(keys, callback) {
        const all = api.storage.get(extensionStoreKey, {});
        let result = all;
        if (typeof keys === "string") result = { [keys]: all[keys] };
        if (Array.isArray(keys)) result = Object.fromEntries(keys.map((key) => [key, all[key]]));
        if (keys && typeof keys === "object" && !Array.isArray(keys)) {
          result = Object.fromEntries(Object.entries(keys).map(([key, fallback]) => [key, all[key] ?? fallback]));
        }
        callback?.(result);
        return Promise.resolve(result);
      },
      set(items, callback) {
        api.storage.set(extensionStoreKey, { ...api.storage.get(extensionStoreKey, {}), ...items });
        callback?.();
        return Promise.resolve();
      },
      remove(keys, callback) {
        const next = { ...api.storage.get(extensionStoreKey, {}) };
        for (const key of Array.isArray(keys) ? keys : [keys]) delete next[key];
        api.storage.set(extensionStoreKey, next);
        callback?.();
        return Promise.resolve();
      },
      clear(callback) {
        api.storage.set(extensionStoreKey, {});
        callback?.();
        return Promise.resolve();
      }
    };
    chrome.tabs = chrome.tabs || {
      create: ({ url = "" } = {}, callback) => {
        api.openTab(url);
        callback?.({ id: Date.now(), url });
      }
    };
    window.chrome = chrome;

    const logs = [];
    const push = (kind, values) => {
      logs.push({ time: new Date().toLocaleTimeString(), kind, text: values.map(format).join(" ") });
      if (logs.length > 250) logs.shift();
      render();
    };
    const format = (value) => {
      if (typeof value === "string") return value;
      try { return JSON.stringify(value); } catch { return String(value); }
    };

    for (const method of ["log", "info", "warn", "error"]) {
      const original = console[method].bind(console);
      console[method] = (...values) => { original(...values); push(method, values); };
    }
    window.addEventListener("error", (event) => push("error", [event.message]));
    window.addEventListener("unhandledrejection", (event) => push("error", ["Promise:", event.reason]));

    const originalFetch = window.fetch?.bind(window);
    if (originalFetch) {
      window.fetch = async (...args) => {
        const started = performance.now();
        try {
          const response = await originalFetch(...args);
          push("network", [`${response.status}`, response.url, `${Math.round(performance.now() - started)}ms`]);
          return response;
        } catch (error) {
          push("error", ["FETCH", args[0], error]);
          throw error;
        }
      };
    }

    const host = document.createElement("div");
    host.id = "aircraft-devtools-host";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial} .panel{position:fixed;z-index:2147483647;left:12px;right:12px;bottom:12px;height:min(42vh,360px);display:none;background:#111;color:#eee;border:1px solid #444;border-radius:12px;box-shadow:0 18px 55px #0008;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;overflow:hidden}
      .panel.open{display:flex;flex-direction:column}.bar{height:38px;display:flex;align-items:center;gap:8px;padding:0 12px;background:#1d1d1f;border-bottom:1px solid #444}.title{font:600 12px -apple-system,sans-serif;flex:1}.bar button{color:#ddd;background:#333;border:0;border-radius:6px;padding:5px 9px}.rows{overflow:auto;flex:1}.row{display:grid;grid-template-columns:74px 64px 1fr;gap:8px;padding:5px 10px;border-bottom:1px solid #ffffff12;white-space:pre-wrap;word-break:break-word}.warn{color:#ffd76a}.error{color:#ff8b8b}.network{color:#79c7ff}
    </style><section class="panel"><header class="bar"><span class="title">Aircraft DevTools · ⌘⌥I</span><button data-clear>Очистить</button><button data-close>Закрыть</button></header><div class="rows"></div></section>`;
    document.documentElement.append(host);
    const panel = root.querySelector(".panel");
    const rows = root.querySelector(".rows");
    const render = () => {
      if (!panel.classList.contains("open")) return;
      rows.replaceChildren(...logs.map((entry) => {
        const row = document.createElement("div");
        row.className = `row ${entry.kind}`;
        row.innerHTML = `<span>${entry.time}</span><span>${entry.kind}</span><span></span>`;
        row.lastElementChild.textContent = entry.text;
        return row;
      }));
      rows.scrollTop = rows.scrollHeight;
    };
    const toggle = () => { panel.classList.toggle("open"); render(); };
    window.addEventListener("aircraft:toggleDevtools", toggle);
    root.querySelector("[data-close]").onclick = () => panel.classList.remove("open");
    root.querySelector("[data-clear]").onclick = () => { logs.length = 0; render(); };
    window.addEventListener("keydown", (event) => {
      if (event.metaKey && event.altKey && event.key.toLowerCase() === "i") {
        event.preventDefault();
        toggle();
      }
    }, true);
    push("info", ["DevTools bridge ready", location.href]);
  };

  if (window.aircraft) start();
  else window.addEventListener("aircraft:ready", start, { once: true });
})();
