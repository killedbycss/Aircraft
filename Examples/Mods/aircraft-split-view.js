(() => {
  "use strict";
  if (window.top !== window || window.__aircraftSplitViewMod) return;
  window.__aircraftSplitViewMod = true;

  const register = () => window.aircraft?.post("registerCapability", { capability: "splitView" });
  if (window.aircraft) register();
  else window.addEventListener("aircraft:ready", register, { once: true });
})();
