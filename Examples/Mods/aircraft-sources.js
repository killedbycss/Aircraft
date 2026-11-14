// Aircraft mod: «Источники» — менеджер литературы в духе Zotero.
// Сохранение страниц с метаданными (авторы, журнал, DOI, PDF), коллекции,
// цитаты по ГОСТ и APA, экспорт в BibTeX и RIS. Вся работа — в самом браузере;
// скрипт только сообщает, что мод установлен.
(() => {
  "use strict";
  if (window.top !== window || window.__aircraftSourcesMod) return;
  window.__aircraftSourcesMod = true;

  const register = () => window.aircraft?.post("registerCapability", { capability: "sources" });
  if (window.aircraft) register();
  else window.addEventListener("aircraft:ready", register, { once: true });
})();
