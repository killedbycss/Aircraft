(() => {
  "use strict";
  if (window.top !== window || window.__aircraftBackgroundMod) return;
  window.__aircraftBackgroundMod = true;
  const start = () => {
    const api = window.aircraft;
    if (!api) return;
    api.post("registerCapability", { capability: "themes" });
    const value = api.storage.get("themes.background", "#00000000");
    if (!/^#[0-9a-f]{8}$/i.test(value) || value.endsWith("00")) return;
    const style = document.createElement("style");
    style.id = "aircraft-site-background";
    style.textContent = `html, body { background-color: ${value} !important; }`;
    document.documentElement.append(style);
  };
  if (window.aircraft) start();
  else window.addEventListener("aircraft:ready", start, { once: true });
})();
