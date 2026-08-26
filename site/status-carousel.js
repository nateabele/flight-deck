/* ==========================================================================
   Flight Deck — hero "blocked" state carousel
   Rolls the "[glyph] blocked" pair in the hero paragraph through the app's
   other session states. Lives in its own file (not demo.js) and only ever
   touches #fd-status-carousel — the rest of the hero sentence is untouched.
   ========================================================================== */

(function () {
  "use strict";

  var ROTATE_MS = 4000;
  var TRANSITION_MS = 420; // keep in sync with the transition duration in styles.css

  var container = document.getElementById("fd-status-carousel");
  if (!container) return;

  // Reduced motion asked for zero rotation, and the markup this script is
  // about to replace is already a static "blocked" — so the requirement is
  // met by simply not enhancing it, same as if the script never ran at all.
  var reduceMotion =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) return;

  /* ---------------------------------------------------------------- glyphs */
  /* Same SF Symbol silhouettes as demo.js's GLYPH object (kept in sync by
     hand since demo.js is off limits here). Mask ids are scoped with a
     "cs" prefix so they can never collide with heroQm, the id on the static
     fallback markup this script tears down below. */

  function glyphWaiting(maskId) {
    return (
      '<svg class="inline-glyph glyph-waiting" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
      '<mask id="' +
      maskId +
      '" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="16">' +
      '<rect width="16" height="16" fill="white"/>' +
      '<path d="M6.3 6.35a1.75 1.75 0 1 1 2.35 1.63c-.52.24-.72.6-.72 1.06v.28" stroke="black" stroke-width="1.3" stroke-linecap="round" fill="none"/>' +
      '<circle cx="8" cy="11.15" r="0.8" fill="black"/>' +
      "</mask>" +
      '<circle cx="8" cy="8" r="5.6" fill="currentColor" mask="url(#' +
      maskId +
      ')"/></svg>'
    );
  }

  function glyphShell(maskId) {
    return (
      '<svg class="inline-glyph glyph-shell" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
      '<mask id="' +
      maskId +
      '" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="16">' +
      '<rect width="16" height="16" fill="white"/>' +
      '<path d="M4.5 6.2 6.9 8.05 4.5 9.9" stroke="black" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round" fill="none"/>' +
      '<path d="M8.1 10.15h2.9" stroke="black" stroke-width="1.15" stroke-linecap="round"/>' +
      "</mask>" +
      '<rect x="1.4" y="2.9" width="13.2" height="10.2" rx="2.4" fill="currentColor" mask="url(#' +
      maskId +
      ')"/></svg>'
    );
  }

  function glyphCircle(cls) {
    return (
      '<svg class="inline-glyph ' +
      cls +
      '" viewBox="0 0 16 16" fill="none" aria-hidden="true"><circle cx="8" cy="8" r="5.2" fill="currentColor"/></svg>'
    );
  }

  function glyphConflict() {
    return (
      '<svg class="inline-glyph glyph-conflict" viewBox="0 0 16 16" fill="none" aria-hidden="true">' +
      '<circle cx="6" cy="5.6" r="2.5" fill="currentColor"/>' +
      '<path d="M1.5 12.6c0-2.2 2-3.6 4.5-3.6s4.5 1.4 4.5 3.6z" fill="currentColor"/>' +
      '<circle cx="11.6" cy="5.9" r="2.1" fill="currentColor" opacity="0.55"/>' +
      '<path d="M8.6 12.6c0-1.9 1.5-3.1 3-3.1 2 0 3.4 1.2 3.4 3.1z" fill="currentColor" opacity="0.55"/>' +
      "</svg>"
    );
  }

  // Every state but "busy" — that one's already the spinner half of the
  // sentence and stays put. Order starts on "blocked" so first paint keeps
  // matching what was hard-coded in index.html before this script runs.
  var STATES = [
    { word: "blocked", glyph: function () { return glyphWaiting("csCarouselWaitingMask"); } },
    { word: "unread", glyph: function () { return glyphCircle("glyph-unread"); } },
    { word: "idle", glyph: function () { return glyphCircle("glyph-idle"); } },
    { word: "duplicated", glyph: function () { return glyphConflict(); } },
    { word: "backgrounded", glyph: function () { return glyphShell("csCarouselShellMask"); } },
  ];

  /* ------------------------------------------------------------------ dom */

  container.textContent = "";
  container.classList.add("status-carousel");

  var viewport = document.createElement("span");
  viewport.className = "status-carousel-viewport";
  viewport.setAttribute("aria-hidden", "true");
  container.appendChild(viewport);

  // One static, non-live equivalent rather than announcing every rotation —
  // an aria-live region here would re-announce a new word at every interval,
  // which is noise, not information.
  var srLabel = document.createElement("span");
  srLabel.className = "status-carousel-sr";
  srLabel.textContent = STATES[0].word;
  container.appendChild(srLabel);

  function makeItem(state) {
    var item = document.createElement("span");
    item.className = "status-carousel-item";
    item.innerHTML = state.glyph() + state.word;
    return item;
  }

  // The slot is the last thing before the sentence's full stop, so unlike a
  // mid-sentence slot it can shrink-wrap the current word instead of being
  // pinned to the widest one — that's what lets the full stop sit flush
  // after it in every state rather than leaving a dead gap for short words.
  var index = 0;
  var current = makeItem(STATES[index]);
  current.classList.add("is-current");
  viewport.appendChild(current);
  viewport.style.width = Math.ceil(current.getBoundingClientRect().width) + "px";

  /* ------------------------------------------------------------- rotation */

  var paused = document.hidden;
  document.addEventListener("visibilitychange", function () {
    paused = document.hidden;
  });

  var pendingCleanup = null;

  function scheduleNext() {
    setTimeout(tick, ROTATE_MS);
  }

  function tick() {
    // Rotating an off-screen tab wastes cycles and risks landing mid-roll
    // right as the tab becomes visible again — skip the swap, not just the
    // paint, while hidden.
    if (paused) {
      scheduleNext();
      return;
    }

    index = (index + 1) % STATES.length;
    var incoming = makeItem(STATES[index]);
    incoming.classList.add("is-entering");
    viewport.appendChild(incoming);

    // Read layout back so the "entering" starting transform is committed
    // to a rendered frame before it flips to "is-current" — without this
    // the two class changes coalesce into one paint and the roll never
    // shows, it just cuts.
    var incomingWidth = incoming.getBoundingClientRect().width;

    // Set the target width in the same tick as the transform/opacity swap
    // below so the CSS "width" transition on the viewport runs in lockstep
    // with the vertical roll — the full stop rides the slot's edge instead
    // of jumping to it once the roll finishes.
    viewport.style.width = Math.ceil(incomingWidth) + "px";

    current.classList.remove("is-current");
    current.classList.add("is-leaving");
    incoming.classList.remove("is-entering");
    incoming.classList.add("is-current");

    var outgoing = current;
    current = incoming;

    if (pendingCleanup) clearTimeout(pendingCleanup);
    pendingCleanup = setTimeout(function () {
      if (outgoing.parentNode) outgoing.parentNode.removeChild(outgoing);
      pendingCleanup = null;
    }, TRANSITION_MS);

    scheduleNext();
  }

  scheduleNext();
})();
