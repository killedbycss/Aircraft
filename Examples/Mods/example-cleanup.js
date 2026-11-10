(() => {
  "use strict";
  if (location.hostname !== "example.com") return;
  if (document.getElementById("aircraft-example-cleanup")) return;

  const style = document.createElement("style");
  style.id = "aircraft-example-cleanup";
  style.textContent = `
    body { max-width: 960px; margin-inline: auto; }
    aside, .advertisement, [aria-label="Advertisement"] { display: none !important; }
  `;
  document.head.appendChild(style);
})();

