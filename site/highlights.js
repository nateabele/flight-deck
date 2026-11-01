/* Features: the scroll-driven highlights stage, and the dialog that stands in
   for it on narrow screens.

   Wide: the tile nearest the middle of the viewport is the active one. Its
   art loops (the others pause), and its detail (product shot + points) is
   the one shown on the sticky stage. Clicking a tile scrolls it to the
   middle, which makes it active the same way scrolling does.

   Narrow (≤ 900px): the stage is hidden. Tapping a tile moves its detail
   node into the dialog, and closing puts it back — moved, not cloned, so the
   SVG ids and <use> references inside the shots stay unique.

   Product shots are drawn for a 1000px stage and zoomed to the width they
   get, so their px layouts scale as one piece. */
(() => {
  "use strict";

  const tiles = Array.from(document.querySelectorAll("#features .hl-tile"));
  const stage = document.querySelector("#features .hl-stage");
  const dialog = document.querySelector(".hl-modal");
  if (!tiles.length || !stage) return;

  const DESIGN_W = 1000;
  const narrow = window.matchMedia("(max-width: 900px)");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const detailFor = (tile) => document.getElementById("hl-d-" + tile.dataset.hl);

  /* --- zoom ------------------------------------------------------------- */

  /* Fit the stage's width, and on the stage also its height: the shot and the
     points under it must fit the viewport, or the sticky stage runs off the
     bottom of a short window. */
  function fit(shot, width, height) {
    const fig = shot.querySelector(".fviz");
    if (!fig) return;
    let z = Math.min(1, width / DESIGN_W);
    if (height) {
      fig.style.zoom = "1";
      const natural = fig.getBoundingClientRect().height;
      const points = shot.parentElement.querySelector(".hl-points");
      const below = points ? points.getBoundingClientRect().height + 26 : 0;
      if (natural) z = Math.min(z, Math.max(0.5, (height - below) / natural));
    }
    fig.style.zoom = String(z);
  }

  function fitStage() {
    const w = stage.clientWidth;
    const h = window.innerHeight - 32;
    if (w) stage.querySelectorAll(".hl-shot").forEach((s) => fit(s, w, h));
  }

  /* --- wide: the active tile follows the scroll ------------------------- */

  let active = null;

  function activate(tile) {
    if (tile === active) return;
    if (active) {
      active.classList.remove("is-active");
      active.setAttribute("aria-pressed", "false");
      detailFor(active)?.classList.remove("is-active");
    }
    active = tile;
    tile.classList.add("is-active");
    tile.setAttribute("aria-pressed", "true");
    detailFor(tile)?.classList.add("is-active");
  }

  /* A rect test on scroll, as demo.js does for reveals, rather than an
     IntersectionObserver whose callbacks can be throttled or dropped. */
  let queued = false;
  function pick() {
    queued = false;
    if (narrow.matches) return;
    const mid = window.innerHeight / 2;
    let best = null;
    let bestD = Infinity;
    for (const t of tiles) {
      const r = t.getBoundingClientRect();
      const d = Math.abs((r.top + r.bottom) / 2 - mid);
      if (d < bestD) { bestD = d; best = t; }
    }
    if (best) activate(best);
  }
  const schedule = () => {
    if (!queued) { queued = true; requestAnimationFrame(pick); }
  };

  function centre(tile) {
    const r = tile.getBoundingClientRect();
    const y = window.scrollY + r.top + r.height / 2 - window.innerHeight / 2;
    window.scrollTo({ top: Math.max(0, y), behavior: reduced.matches ? "auto" : "smooth" });
  }

  /* --- narrow: the dialog ----------------------------------------------- */

  let lent = null; // { node, home } while a detail is in the dialog

  function openDialog(tile) {
    const node = detailFor(tile);
    if (!node || !dialog) return;
    const title = tile.querySelector(".hl-title");
    dialog.querySelector(".hl-modal-title").textContent = title ? title.textContent : "";
    lent = { node, home: node.nextSibling };
    dialog.querySelector(".hl-modal-body").appendChild(node);
    dialog.showModal();
    dialog.scrollTop = 0;
    const body = dialog.querySelector(".hl-modal-body");
    if (window.innerWidth > 640) fit(node.querySelector(".hl-shot"), body.clientWidth - 32);
  }

  function returnDetail() {
    if (!lent) return;
    stage.insertBefore(lent.node, lent.home);
    lent = null;
    fitStage();
  }

  if (dialog) {
    dialog.addEventListener("close", returnDetail);
    dialog.querySelector(".hl-modal-close").addEventListener("click", () => dialog.close());
    // A click on the backdrop lands on the dialog element itself.
    dialog.addEventListener("click", (e) => { if (e.target === dialog) dialog.close(); });
  }

  /* --- wiring ----------------------------------------------------------- */

  function choose(tile) {
    if (narrow.matches) openDialog(tile);
    else centre(tile);
  }
  for (const t of tiles) {
    t.setAttribute("aria-pressed", "false");
    t.addEventListener("click", () => choose(t));
    t.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); choose(t); }
    });
    // Keyboard focus walks the list; on wide screens it makes the tile active.
    t.addEventListener("focus", () => { if (!narrow.matches) activate(t); });
  }

  function onLayout() {
    if (narrow.matches) {
      // Narrow: every tile loops; nothing is "active".
      tiles.forEach((t) => t.classList.add("is-active"));
      active = null;
    } else {
      if (dialog?.open) dialog.close();
      tiles.forEach((t) => { if (t !== active) t.classList.remove("is-active"); });
      fitStage();
      pick();
    }
  }

  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", () => { fitStage(); schedule(); }, { passive: true });
  narrow.addEventListener("change", onLayout);
  if ("ResizeObserver" in window) new ResizeObserver(fitStage).observe(stage);
  onLayout();
  if (!active && !narrow.matches) activate(tiles[0]);
})();
