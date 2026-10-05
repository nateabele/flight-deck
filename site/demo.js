/* ==========================================================================
   Flight Deck — interactive demo
   A scroll-scrubbed replica of the real app window. The sidebar geometry,
   status glyphs, and state vocabulary mirror Sources/FlightDeck/:
   SessionSidebar.swift, ProjectHeaderRow.swift, SessionStatusIcon.swift.
   ========================================================================== */

(function () {
  "use strict";

  /* ---------------------------------------------------------------- glyphs */
  /* SF Symbol shapes redrawn as inline SVG. The app uses the real symbols;
     these match their silhouettes at sidebar size. */

  const svg = (cls, inner, box) =>
    `<svg class="${cls}" viewBox="0 0 ${box || 16} ${box || 16}" fill="none" aria-hidden="true">${inner}</svg>`;

  const GLYPH = {
    // circle.fill
    idle: (unread) =>
      svg(
        "glyph " + (unread ? "glyph-unread" : "glyph-idle"),
        '<circle cx="8" cy="8" r="5.2" fill="currentColor"/>'
      ),

    // questionmark.circle.fill — the mark is knocked out of the disc
    waiting: () =>
      svg(
        "glyph glyph-waiting",
        `<mask id="qm" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="16">
           <rect width="16" height="16" fill="white"/>
           <path d="M6.3 6.35a1.75 1.75 0 1 1 2.35 1.63c-.52.24-.72.6-.72 1.06v.28"
                 stroke="black" stroke-width="1.3" stroke-linecap="round" fill="none"/>
           <circle cx="8" cy="11.15" r="0.8" fill="black"/>
         </mask>
         <circle cx="8" cy="8" r="5.6" fill="currentColor" mask="url(#qm)"/>`
      ),

    // terminal.fill — prompt and underscore knocked out. BackgroundWorkBadge: a
    // green decoration beside the title of a session with a background task,
    // not a status of its own (the app dropped the old `.shell` activity).
    bgBadge: () =>
      svg(
        "glyph glyph-bg",
        `<mask id="tm" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="16">
           <rect width="16" height="16" fill="white"/>
           <path d="M4.5 6.2 6.9 8.05 4.5 9.9" stroke="black" stroke-width="1.15"
                 stroke-linecap="round" stroke-linejoin="round" fill="none"/>
           <path d="M8.1 10.15h2.9" stroke="black" stroke-width="1.15" stroke-linecap="round"/>
         </mask>
         <rect x="1.4" y="2.9" width="13.2" height="10.2" rx="2.4"
               fill="currentColor" mask="url(#tm)"/>`
      ),

    // The macOS indeterminate ProgressView — 8 tapered spokes
    busy: () =>
      '<span class="spinner" aria-hidden="true">' +
      Array.from({ length: 8 }, (_, i) =>
        `<i style="transform:rotate(${i * 45}deg);opacity:${0.22 + i * 0.1}"></i>`
      ).join("") +
      "</span>",

    // person.2.fill — "another tab is on this conversation"
    conflict: () =>
      svg(
        "glyph glyph-conflict",
        `<circle cx="6" cy="5.6" r="2.5" fill="currentColor"/>
         <path d="M1.5 12.6c0-2.2 2-3.6 4.5-3.6s4.5 1.4 4.5 3.6z" fill="currentColor"/>
         <circle cx="11.6" cy="5.9" r="2.1" fill="currentColor" opacity="0.55"/>
         <path d="M8.6 12.6c0-1.9 1.5-3.1 3-3.1 2 0 3.4 1.2 3.4 3.1z"
               fill="currentColor" opacity="0.55"/>`
      ),

    chevron: () =>
      svg("chev", '<path d="M6 3.6 10.4 8 6 12.4" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>'),

    xmark: () =>
      svg("close", '<path d="M4.6 4.6 11.4 11.4M11.4 4.6 4.6 11.4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'),

    plus: () =>
      '<svg viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M8 3.4v9.2M3.4 8h9.2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  };

  /* ------------------------------------------------------------- terminals */
  /* Claude Code as it actually renders — measured off a live `claude` 2.1.289
     in tmux, not remembered: the ⏺ bullet (white for the model's words, then
     grey / green / pink as a tool runs / succeeds / fails), the ⎿ result gutter,
     `Update(file)` with a numbered diff, the ✶ spinner row, and the ─ ruled
     composer. See .terminal in styles.css for the palette. */

  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const line = (html, cls) => `<span class="l${cls ? " " + cls : ""}">${html}</span>`;
  const sub = (s) => `<span class="t-sub">${s}</span>`;
  const code = (s) => `<span class="t-code">${esc(s)}</span>`;
  const bold = (s) => `<span class="t-b">${s}</span>`;

  /* ⏺ text — a wrapped line hangs under the words, not the bullet */
  const msg = (...lines) => lines.map((l, i) => line(i ? "  " + l : `<span class="b-msg">⏺</span> ${l}`, "hang")).join("");

  /* ⏺ Tool(arg) — state is "run" | "ok" | "err" */
  const tool = (state, name, arg) =>
    line(`<span class="b-${state}">⏺</span> ${bold(name)}(${esc(arg)})`);

  /* ⎿  result — continuation lines sit under the text, five columns in */
  const res = (...lines) =>
    lines.map((l, i) => line(i ? "     " + l : sub("  ⎿  ") + l)).join("");

  /* A tool group Claude collapses to one grey line */
  const folded = (html) => line("  " + sub(html + " (ctrl+o to expand)"));

  /* The submitted prompt: a grey block */
  const user = (text) => line(sub("❯ ") + esc(text), "user");

  /* Just enough highlighting for the three or four diff lines on screen */
  const KW = /\b(export|function|func|static|const|let|return|if|guard|await|async|new|private|struct|in|else)\b/g;
  const hl = (src) =>
    esc(src)
      .replace(/\b(\d[\d_]*)\b/g, '<span class="v">$1</span>')
      .replace(KW, '<span class="k">$1</span>')
      .replace(/\b(Math|Int|Bool|String|IndexSet|number|Promise|Response)\b/g, '<span class="n">$1</span>')
      .replace(/\b([a-z]\w*)(?=\()/gi, (m, n) => (/^(export|function|func|static|const|let|return|if|guard|await|async|new|in|else)$/.test(n) ? n : `<span class="f">${n}</span>`));

  /* One diff row: gutter is the line number plus the sign, as Claude prints it */
  const diff = (rows) =>
    rows
      .map(([sign, n, src]) =>
        line(
          `<span class="g">${String(n).padStart(4, " ")} ${sign === "c" ? " " : sign}</span> ${hl(src)}`,
          "df " + { "+": "add", "-": "del", c: "ctx" }[sign]
        )
      )
      .join("");

  /* Each terminal is body (always shown), tail (only once the turn has
     finished — it would contradict the spinner otherwise) and the spinner's
     verb/stats while the agent is still working. */
  const T = {
    "refactor-sidebar": {
      body:
        user("Pull the reorder policy out of SessionSidebar so it can be tested") +
        msg("I'll start with how the rows are built today.") + line("") +
        folded("Read <b>1</b> file") + line("") +
        msg(
          "The flat " + code("ForEach") + " is load-bearing — " + code(".onMove") + " isn't supported on a",
          "ForEach that yields Sections, so flattening is what lets one drag gesture",
          "reorder projects and sessions. I'll extract the row policy and leave the structure alone."
        ) + line("") +
        tool("ok", "Update", "Sources/FlightDeck/SidebarReorder.swift") +
        res("Added <b>3</b> lines, removed <b>2</b> lines") +
        diff([
          ["c", 41, "enum SidebarReorder {"],
          ["-", 42, "    func move(from: IndexSet, to: Int) {"],
          ["-", 43, "        rows.move(fromOffsets: from, toOffset: to)"],
          ["+", 42, "    static func apply(_ rows: [SidebarRow], from: IndexSet, to: Int) -> [SidebarRow] {"],
          ["+", 43, "        var next = rows"],
          ["+", 44, "        next.move(fromOffsets: from, toOffset: to)"],
          ["c", 45, "    }"],
        ]) + line("") +
        tool("ok", "Bash", "./scripts/test-unit.sh") +
        res(sub("Executed 66 tests, with 0 failures (2.104 seconds)")),
      tail: msg("Done. The policy is a pure function now, and " + code("SessionSidebar") + " just calls it."),
      spin: { verb: "Cogitating", secs: 38, tokens: "2.1k" },
      took: "Crunched for 1m 14s",
    },

    "status-pipeline": {
      body:
        user("Why does StatusWatcher poll instead of watching the registry directory?") +
        msg("Let me run its tests first to get a baseline.") + line("") +
        tool("ok", "Bash", "./scripts/test-unit.sh --filter StatusWatcher") +
        res(sub("Executed 12 tests, with 0 failures (0.418 seconds)")),
      tail:
        msg(
          "All twelve pass. The watcher polls rather than watching vnodes because " + code("claude"),
          "rewrites the registry file in place — no create, no rename — so a directory",
          "watch would never fire."
        ) + line("") +
        msg(
          "Summary of what changed:",
          "- " + code("ClaudeStatusFile") + " now fails closed on a torn read",
          "- a pid/filename mismatch yields nil instead of a stale status",
          "- the watcher keeps its last known value across a bad poll"
        ),
      spin: { verb: "Pondering", secs: 21, tokens: "1.4k" },
      took: "Crunched for 52s",
    },

    "retry-backoff": {
      body:
        user("Add full jitter to backoff() in the retry transport, then run the staging migration") +
        folded("Read <b>1</b> file") + line("") +
        msg(
          "The backoff is exponential but unjittered, so every client that saw the same",
          "503 retries on the same schedule. Adding full jitter."
        ) + line("") +
        tool("ok", "Update", "src/transport/retry.ts") +
        res("Added <b>2</b> lines, removed <b>1</b> line") +
        diff([
          ["c", 12, "export function backoff(attempt: number): number {"],
          ["-", 13, "  return Math.min(30000, 100 * 2 ** attempt);"],
          ["+", 13, "  const cap = Math.min(30000, 100 * 2 ** attempt);"],
          ["+", 14, "  return Math.random() * cap;"],
          ["c", 15, "}"],
        ]) + line("") +
        tool("run", "Bash", "npm run migrate:staging") +
        res(sub("Waiting…")),
      /* A blocked session sits in a dialog, not at the composer */
      dialog: {
        title: "Bash command",
        sub: "Run shell command",
        cmd: "npm run migrate:staging",
        note: "This command requires approval",
        ask: "Do you want to proceed?",
        opts: ["Yes", "Yes, and don’t ask again for: npm run *", "No"],
      },
      tail: msg("Migration applied to staging."),
      spin: { verb: "Noodling", secs: 9, tokens: "0.8k" },
      took: "Crunched for 31s",
    },

    "oauth-refresh": {
      body:
        user("Make token refresh single-flight, then run the integration suite") +
        tool("ok", "Update", "src/auth/refresh.ts") +
        res("Added <b>5</b> lines, removed <b>2</b> lines") +
        diff([
          ["c", 28, "let inflight: Promise<Token> | null = null;"],
          ["-", 29, "export async function refresh(): Promise<Token> {"],
          ["+", 29, "export function refresh(): Promise<Token> {"],
          ["+", 30, "  inflight ??= fetchToken().finally(() => { inflight = null; });"],
          ["+", 31, "  return inflight;"],
          ["c", 32, "}"],
        ]) + line("") +
        msg(
          "Concurrent callers now await one in-flight request instead of each starting",
          "their own and racing to write the token back. Kicking off the integration",
          "suite in the background."
        ) + line("") +
        tool("ok", "Bash", "npm run test:integration") +
        res(sub("Running in the background (↓ to manage)")),
      tail: msg("Refresh is single-flighted and the suite is running. I'll check it when it reports back."),
      spin: { verb: "Churning", secs: 17, tokens: "1.1k" },
      took: "Crunched for 48s",
    },

    "index-service": {
      body:
        user("Rebuild the index with the semantic feature and confirm the WAL holds across worktrees") +
        tool("ok", "Bash", "cargo build --release --features semantic") +
        res(sub("Compiling quillmap v0.9.2"), sub("Finished `release` profile [optimized] target(s) in 41.20s")),
      tail: msg(
        "Index is warm: 1,111 files, 20,723 symbols. Single-writer WAL holds across the",
        "worktrees, which was the open question."
      ),
      spin: { verb: "Sautéing", secs: 6, tokens: "0.5k" },
      took: "Crunched for 1m 03s",
    },
  };

  /* After a quit and relaunch the conversation is replayed, and the nudge Flight
     Deck offers is typed into the composer on the user's behalf */
  const RESUMED = {
    body: T["refactor-sidebar"].body + line("") + user("Keep going."),
    spin: { verb: "Pondering", secs: 3, tokens: "0.2k" },
  };

  /* The spinner row's glyph cycles through these, as Claude's does */
  const SPIN_GLYPHS = ["·", "✢", "✳", "✶", "✻", "✽"];
  const RULE = "─".repeat(240);
  const DASH = "╌".repeat(240);

  /* The composer, and the footer row under it */
  function composer(s) {
    const mode =
      '<span class="mode">⏵⏵ accept edits on</span>' +
      (s.bg ? ' · <span class="shell">1 shell</span> · /tasks to see subagents' : " (shift+tab to cycle)");
    return (
      `<span class="rule" aria-hidden="true">${RULE}</span>` +
      `<span class="l prompt"><span class="marker">❯</span><span class="caret"></span></span>` +
      `<span class="rule" aria-hidden="true">${RULE}</span>` +
      `<span class="l mode-row">  ${mode}</span>`
    );
  }

  /* The permission dialog Claude raises — numbered options, ❯ on the first */
  function dialog(d) {
    const dash = `<span class="rule dash" aria-hidden="true">${DASH}</span>`;
    return (
      `<div class="dialog"><span class="rule" aria-hidden="true">${RULE}</span>` +
      line(" " + `<span class="title">${d.title}</span>`) +
      line(" " + sub(d.sub)) +
      dash +
      line(" " + esc(d.cmd)) +
      dash +
      line(" " + d.note) +
      line("") +
      line(" " + d.ask) +
      d.opts
        .map((o, i) =>
          i === 0
            ? line(` <span class="opt-sel">❯ ${sub("1. ")}<span class="opt-sel">${o}</span></span>`)
            : line(`   ${sub(i + 1 + ".")} ${esc(o)}`)
        )
        .join("") +
      line("") +
      line(" " + sub("Esc to cancel · Tab to amend")) +
      `</div>`
    );
  }

  /* ----------------------------------------------------------------- beats */

  const P = (path, name, sessions, collapsed) => ({ path, name, sessions, collapsed: !!collapsed });
  const S = (id, title, status, extra) =>
    Object.assign({ id, title, status, subagents: 0, unread: false, conflict: false, bg: false }, extra);

  const BEATS = [
    {
      caption:
        "Open a project and start a session. It's a <strong>real terminal</strong> — the Ghostty engine, Metal-rendered — with your agent running inside it.",
      selected: "refactor-sidebar",
      projects: [P("~/Projects/flight-deck", "flight-deck", [S("refactor-sidebar", "refactor-sidebar", "busy")])],
    },
    {
      caption:
        "⌘N starts another. Sessions stack under their project, each with its <strong>own conversation and working directory</strong> — and its own subagent fan-out.",
      selected: "refactor-sidebar",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 3 }),
          S("status-pipeline", "status-pipeline", "busy"),
        ]),
      ],
    },
    {
      caption:
        "Drop a folder on the sidebar to add a project. Now you're running <strong>four agents across two repos</strong> in one window.",
      selected: "status-pipeline",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 3 }),
          S("status-pipeline", "status-pipeline", "busy"),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "busy"),
          S("oauth-refresh", "oauth-refresh", "busy"),
        ]),
      ],
    },
    {
      caption:
        "One hits a permission prompt. Its glyph turns <strong>orange the instant it needs you</strong> — you don't have to be looking at that tab to find out.",
      selected: "retry-backoff",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 3 }),
          S("status-pipeline", "status-pipeline", "busy"),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "waiting"),
          S("oauth-refresh", "oauth-refresh", "busy"),
        ]),
      ],
    },
    {
      caption:
        "The green terminal badge is the state most tools miss: the turn <strong>ended</strong>, but a backgrounded command is still running. Neither working nor done.",
      selected: "oauth-refresh",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 2 }),
          S("status-pipeline", "status-pipeline", "busy"),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "waiting"),
          S("oauth-refresh", "oauth-refresh", "idle", { bg: true }),
        ]),
      ],
    },
    {
      caption:
        "A session that finished while you were elsewhere keeps a <strong>filled accent dot</strong> until you actually look at it. Nothing completes into the void.",
      selected: "oauth-refresh",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 2 }),
          S("status-pipeline", "status-pipeline", "idle", { unread: true }),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "waiting"),
          S("oauth-refresh", "oauth-refresh", "idle", { bg: true }),
        ]),
      ],
    },
    {
      caption:
        "Collapse a project and it <strong>inherits the most demanding state underneath it</strong>. A blocked session can never hide inside a folded group.",
      selected: "refactor-sidebar",
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { subagents: 2 }),
          S("status-pipeline", "status-pipeline", "idle", { unread: true }),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "waiting"),
          S("oauth-refresh", "oauth-refresh", "idle", { bg: true }),
        ], true),
        P("~/Projects/quillmap", "quillmap", [S("index-service", "index-service", "busy")]),
      ],
    },
    {
      caption:
        "Quit and relaunch. Every session <strong>comes back attached to its own conversation</strong>, and anything that was mid-flight is offered a nudge to continue.",
      selected: "refactor-sidebar",
      resumed: true,
      projects: [
        P("~/Projects/flight-deck", "flight-deck", [
          S("refactor-sidebar", "refactor-sidebar", "busy", { conflict: false }),
          S("status-pipeline", "status-pipeline", "idle", { unread: true }),
        ]),
        P("~/Projects/ledger-sync", "ledger-sync", [
          S("retry-backoff", "retry-backoff", "waiting"),
          S("oauth-refresh", "oauth-refresh", "idle", { unread: true }),
        ]),
        P("~/Projects/quillmap", "quillmap", [S("index-service", "index-service", "idle", { conflict: true })]),
      ],
    },
  ];

  /* ------------------------------------------------------------------ dom */

  const $ = (s, r) => (r || document).querySelector(s);
  const listEl = $("#fd-list");
  const termEl = $("#fd-term");
  const capEl = $("#fd-caption");
  const railEl = $("#fd-rail");
  const demoEl = $("#demo");
  const footEl = $("#fd-newbtn-label");

  /* html.js hides the demo until it launches. Any path that gives up before
     wiring the launch must drop the class, or the demo stays hidden forever. */
  const unhide = () => document.documentElement.classList.remove("js");

  if (!listEl || !demoEl) return unhide();

  let current = -1;
  let override = null; // a session the visitor clicked

  /* Status priority for a collapsed project — mirrors SessionActivity.summaryRank */
  const RANK = { idle: 0, busy: 1, waiting: 2 };

  function collapsedStatus(sessions) {
    let best = null;
    for (const s of sessions) {
      if (!s.status || s.status === "idle") continue;
      if (!best || RANK[s.status] > RANK[best]) best = s.status;
    }
    return best;
  }

  function glyphFor(s) {
    if (!s.status) return "";
    if (s.status === "busy") return GLYPH.busy();
    if (s.status === "waiting") return GLYPH.waiting();
    return GLYPH.idle(s.unread);
  }

  /* SessionStatus.tooltip(unread:backgroundWork:) — the background clause is
     never substituted, and always last. */
  function tooltipFor(s) {
    let base = "";
    switch (s.status) {
      case "busy":
        base = s.subagents > 0
          ? `Working — ${s.subagents} subagent${s.subagents === 1 ? "" : "s"}`
          : "Working";
        break;
      case "waiting":
        base = "Waiting for you — Claude needs your permission to use Bash";
        break;
      case "idle":
        base = s.unread ? "Finished — not yet viewed" : "Idle";
        break;
    }
    return s.bg ? base + " — background command running" : base;
  }

  /* A collapsed project hides an idle child's dot, but not its badge — the same
     rule as store.projectHasBackgroundWork */
  const projectHasBg = (sessions) => sessions.some((s) => s.bg);

  function render(beat, selectedId) {
    const rows = [];

    for (const proj of beat.projects) {
      const rolled = proj.collapsed ? collapsedStatus(proj.sessions) : null;
      rows.push(
        `<div class="row row-project${proj.collapsed ? " collapsed" : ""}" title="${proj.path}">
           ${GLYPH.chevron()}
           <span class="proj-name">${proj.name}</span>
           ${
             proj.collapsed
               ? `<span class="count">${proj.sessions.length}</span>
                  <span class="trail">${rolled ? glyphFor({ status: rolled, subagents: 0 }) : ""}${projectHasBg(proj.sessions) ? GLYPH.bgBadge() : ""}</span>`
               : ""
           }
           ${GLYPH.xmark()}
         </div>`
      );

      if (proj.collapsed) continue;

      if (!proj.sessions.length) {
        rows.push('<div class="row-empty">No sessions</div>');
        continue;
      }

      for (const s of proj.sessions) {
        rows.push(
          `<div class="row row-session${s.id === selectedId ? " selected" : ""}"
                data-session="${s.id}" role="button" tabindex="0"
                aria-pressed="${s.id === selectedId}"
                title="${tooltipFor(s)}">
             <span class="slot">${glyphFor(s)}</span>
             ${s.bg ? GLYPH.bgBadge() : ""}
             <span class="row-title">${s.title}</span>
             <span class="trail">
               ${s.conflict ? GLYPH.conflict() : ""}
               ${s.status === "busy" && s.subagents > 0 ? `<span class="subcount">${s.subagents}</span>` : ""}
               ${GLYPH.xmark()}
             </span>
           </div>`
        );
      }
    }

    listEl.innerHTML = rows.join("");
    if (footEl) footEl.textContent = "New Session";

    // Terminal
    const sess = beat.projects.flatMap((p) => p.sessions).find((x) => x.id === selectedId)
      || beat.projects[0].sessions[0];
    termEl.innerHTML = terminalFor(beat.resumed && sess.id === "refactor-sidebar" ? RESUMED : T[sess.id], sess);
    startSpin();
  }

  /* The pane follows the session's status: spinner while busy, the permission
     dialog while waiting, and the finished turn's footer once idle. */
  function terminalFor(t, s) {
    let tail = "";
    let foot = composer(s);
    if (s.status === "busy") {
      tail =
        `<span class="l spin-row"><span class="glyph-s">${SPIN_GLYPHS[3]}</span>` +
        `<span class="verb">${t.spin.verb}…</span> ` +
        `<span class="stat">(<span class="secs" data-s="${t.spin.secs}">${t.spin.secs}s</span> · ↓ ${t.spin.tokens} tokens)</span></span>`;
    } else if (s.status === "waiting" && T[s.id].dialog) {
      foot = dialog(T[s.id].dialog);
    } else {
      tail =
        (t.tail ? line("") + t.tail : "") +
        line("") +
        line(`<span class="t-sub">✻ ${t.took || "Crunched for 40s"}${s.bg ? " · done 10:50 AM · 1 shell still running" : ""}</span>`);
    }
    return `<div class="term-body">${t.body}${tail}</div><div class="term-foot">${foot}</div>`;
  }

  /* Cycle the spinner glyph and count the seconds up, as the real row does.
     One interval, restarted on every render, so it can never stack. */
  let spinTimer = null;
  function startSpin() {
    clearInterval(spinTimer);
    spinTimer = null;
    const glyph = termEl.querySelector(".glyph-s");
    if (!glyph || reduceMotion) return;
    const secs = termEl.querySelector(".secs");
    let n = 3;
    const t0 = Date.now();
    spinTimer = setInterval(() => {
      if (!glyph.isConnected) return clearInterval(spinTimer);
      glyph.textContent = SPIN_GLYPHS[++n % SPIN_GLYPHS.length];
      secs.textContent = +secs.dataset.s + Math.floor((Date.now() - t0) / 1000) + "s";
    }, 220);
  }

  function selectedFor(beat) {
    if (override && beat.projects.some((p) => p.sessions.some((s) => s.id === override && !p.collapsed))) {
      return override;
    }
    return beat.selected;
  }

  function show(i, force) {
    i = Math.max(0, Math.min(BEATS.length - 1, i));
    if (i === current && !force) return;
    const changed = i !== current;
    if (changed) override = null;
    current = i;

    const beat = BEATS[i];
    render(beat, selectedFor(beat));

    // Caption crossfade
    if (changed && capEl) {
      capEl.classList.add("swap");
      window.setTimeout(() => {
        capEl.innerHTML = beat.caption;
        capEl.classList.remove("swap");
      }, 180);
    }

    syncRail(i);
  }

  /* --------------------------------------------------------------- autoplay */

  /* Long enough to read a two-line caption and take in the sidebar change.
     The active pip's fill runs for exactly this long, so the advance is
     telegraphed rather than sudden. */
  const DWELL = 5200;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  let timer = null;
  let hovering = false;
  let focused = false;
  let manual = false; // the visitor took the wheel via the rail
  let launched = false; // the demo window has zoomed open; see the launch section

  /* Autoplay is suppressed rather than merely stopped, so every entry point
     (hover out, focus out, the app opening) asks the same question. Declared
     up here with the other flags rather than beside the launch code because
     this predicate runs before that section has been evaluated. */
  const suspended = () =>
    reduceMotion || manual || hovering || focused || !launched;

  /* Is any part of the demo actually in the viewport? */
  const visible = () => {
    const r = demoEl.getBoundingClientRect();
    return r.bottom > 0 && r.top < window.innerHeight;
  };

  function schedule() {
    clearTimeout(timer);
    if (suspended()) return;
    timer = setTimeout(tick, DWELL);
  }

  /* The off-screen check happens here, at tick time, rather than through an
     IntersectionObserver. The loop is then self-healing: it always reschedules
     itself, so it can never be left permanently un-scheduled by a callback
     that never arrived. An observer is the tidier tool right up until its
     delivery is throttled, at which point the demo silently parks forever. */
  function tick() {
    if (visible()) show((current + 1) % BEATS.length);
    schedule();
  }

  function halt() {
    clearTimeout(timer);
    timer = null;
  }

  function syncRail(i) {
    if (!railEl) return;
    Array.from(railEl.children).forEach((b, n) => {
      const active = n === i;
      b.setAttribute("aria-current", String(active));
      const fill = b.firstElementChild;
      if (!fill) return;
      // Re-trigger the fill from zero: clearing the animation and forcing a
      // reflow is the only reliable restart for an identical animation name.
      fill.style.animation = "none";
      void fill.offsetWidth;
      if (!active) {
        fill.style.width = "0";
      } else if (reduceMotion || manual) {
        fill.style.width = "100%"; // no timer running; just mark the position
      } else {
        fill.style.width = "";
        fill.style.animation = `pip ${DWELL}ms linear forwards`;
        fill.style.animationPlayState = suspended() ? "paused" : "running";
      }
    });
  }

  function setFillPlayState(state) {
    const active = railEl && railEl.querySelector('[aria-current="true"]');
    const fill = active && active.firstElementChild;
    if (fill) fill.style.animationPlayState = state;
  }

  /* Resuming restarts the current beat's dwell from zero rather than resuming
     a partial one — someone who hovered to read shouldn't get two seconds of
     what's left before it moves on. */
  function resume() {
    if (suspended()) return;
    syncRail(current);
    schedule();
  }

  function suspend() {
    halt();
    setFillPlayState("paused");
  }

  demoEl.addEventListener("mouseenter", () => { hovering = true; suspend(); });
  demoEl.addEventListener("mouseleave", () => { hovering = false; resume(); });
  demoEl.addEventListener("focusin", () => { focused = true; suspend(); });
  demoEl.addEventListener("focusout", () => { focused = false; resume(); });

  /* ---------------------------------------------------------- interactions */

  // Clicking a session row swaps the terminal, like the real app.
  function activate(el) {
    const id = el.getAttribute("data-session");
    if (!id) return;
    override = id;
    render(BEATS[current], id);
  }

  listEl.addEventListener("click", (e) => {
    const row = e.target.closest(".row-session");
    if (row) activate(row);
  });
  listEl.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const row = e.target.closest(".row-session");
    if (row) {
      e.preventDefault();
      activate(row);
    }
  });

  // Rail buttons jump straight to a beat. Clicking one hands control over for
  // good: an autoplay that resumes underneath someone who just chose a step
  // would yank them off it a few seconds later.
  if (railEl) {
    BEATS.forEach((_, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("aria-label", `Show step ${i + 1} of ${BEATS.length}`);
      b.appendChild(document.createElement("span")).className = "pip-fill";
      b.addEventListener("click", () => {
        manual = true;
        halt();
        show(i);
      });
      railEl.appendChild(b);
    });
  }

  show(0, true);
  resume(); // start the clock; the observer pauses it if we're off-screen

  /* ------------------------------------------------------- scroll reveals */

  /* ================================================================== launch
     The icon travels down the page as you scroll, passing behind the hero
     copy, and when it reaches the demo the window zooms out of it the way a
     Mac app opens from its Finder icon.
     ================================================================== */

  const appEl = $("#fd-app");
  const windowEl = $(".window");
  const copyTopEl = $(".hero-sub");    // first thing the icon passes behind
  const copyBottomEl = $(".hero-note"); // last thing it passes behind
  const LANDING_GAP = 76; // window's resting distance below the top of the screen

  /* The icon descends faster than the page scrolls, so it reaches the demo well
     before the scroll does. This is the lever for how far the whole sequence
     runs ahead of the scrollbar: the icon arrives at land / TRAVEL_RATE, and
     the launch keys off that, so raising it pulls both forward together. */
  const TRAVEL_RATE = 2.2;

  /* Offset from the icon's arrival at which the window zooms open. Negative,
     so the launch is well underway before the icon finishes travelling and the
     two motions overlap rather than running end to end. */
  const LAUNCH_LEAD = -105;

  /* Scrolling back up closes it again so the sequence can replay. Measured back
     from the open point, not from the arrival: with a lead this large the two
     would otherwise cross, and the demo would open and then immediately close
     itself on the next scroll event. */
  const CLOSE_MARGIN = 60;

  /* Layout position in document space. Deliberately walks offsetTop rather
     than using getBoundingClientRect: the icon carries a scroll-driven
     transform, and a rect would fold that transform back into the maths that
     produces it. */
  function docTop(el) {
    let y = 0;
    for (let n = el; n; n = n.offsetParent) y += n.offsetTop;
    return y;
  }

  /* The window's *unstuck* top in document space.
     Measured from the demo section plus its top padding rather than by walking
     up from the window itself: .demo-inner is position:sticky, so once it pins,
     its offsetTop reports the shifted position, not the laid-out one. Walking
     through it makes every number here drift by up to the full sticky travel
     as you scroll — which moves the launch threshold under its own feet. The
     section never sticks, so it is a stable datum. */
  function windowStaticTop() {
    const pad = parseFloat(getComputedStyle(demoEl).paddingTop) || 0;
    return docTop(demoEl) + pad;
  }

  const landingScroll = () => Math.max(0, windowStaticTop() - LANDING_GAP);

  /* Where the icon has to end up: centred on the window it is about to open. */
  function travelDistance() {
    return windowStaticTop() + windowEl.offsetHeight / 2
         - appEl.offsetHeight / 2 - docTop(appEl);
  }

  function scrollProgress() {
    const land = landingScroll();
    return land <= 0 ? 1 : Math.min(1, Math.max(0, window.scrollY / land));
  }

  /* Dims while the icon is behind the hero copy and comes back to full as it
     clears the bottom of it. Ramped from the actual overlap rather than
     toggled at a threshold, so it reads as the icon passing under the text
     instead of blinking as it crosses a line. */
  function overlapFade() {
    if (!copyTopEl || !copyBottomEl) return 1;
    const icon = appEl.getBoundingClientRect();
    const top = copyTopEl.getBoundingClientRect().top;
    const bottom = copyBottomEl.getBoundingClientRect().bottom;
    const overlap = Math.min(icon.bottom, bottom) - Math.max(icon.top, top);
    if (overlap <= 0) return 1;
    const span = Math.min(icon.height, bottom - top) || 1;
    return 1 - 0.2 * Math.min(1, overlap / span);
  }

  function updateTravel() {
    if (reduceMotion) return;
    const ps = scrollProgress();
    if (!launched) {
      // Travel runs ahead of the scroll, then pins once it arrives.
      const pt = Math.min(1, ps * TRAVEL_RATE);
      appEl.style.transform = `translateY(${travelDistance() * pt}px)`;
      appEl.style.setProperty("--fade", overlapFade().toFixed(3));
    }
    /* Someone who pressed "See what it does" has taken the demo off the scroll's
       hands. Without this the reveal undoes itself immediately: the tween calls
       through here on every step, and at the top of the page that is below the
       close threshold, so the demo would open and shut on the next frame.

       Thresholds are in scroll pixels off the icon's arrival point, not a
       fraction of the way down, so the beat between the icon landing and the
       window opening stays the same regardless of how tall the page gets. */
    if (forced) return;

    /* Both thresholds are fixed positions on the page. They were briefly made
       to move with scroll velocity, to try to outrun a fast fling; that broke
       more than it fixed — chiefly the demo flickering open and shut whenever
       the scroll rate changed, because the two boundaries could cross. The
       icon's travel rate is the lever for racing ahead of the scroll instead. */
    const openAt = landingScroll() / TRAVEL_RATE + LAUNCH_LEAD;
    const y = window.scrollY;
    if (y >= openAt) open();
    else if (y < openAt - CLOSE_MARGIN) close();
  }

  /* Finder marks an icon selected on double-click, then opens the app a beat
     later. Same order here: flash to the selected state, hold just long enough
     to read, then zoom. */
  const SELECT_MS = 150;
  const ZOOM_MS = 520;
  let selectTimer = null;
  let forced = false; // the demo was revealed outright, not by scrolling to it

  /* The demo, fully formed, with no choreography. Used both by the "See what
     it does" button and by a scroll too fast for the zoom to finish. */
  function showInstant(ms) {
    demoEl.classList.add("instant", "launched");
    appEl.classList.add("opened");
    windowEl.style.transition = `opacity ${ms}ms linear`;
    windowEl.style.transform = "";
    windowEl.style.opacity = "1";
    show(0, true);
    resume();
  }

  function open() {
    if (launched) return;
    launched = true;
    appEl.classList.add("selected");
    clearTimeout(selectTimer);
    selectTimer = setTimeout(zoom, SELECT_MS);
  }

  /* The zoom itself: the window starts scaled down to the icon's size and
     centred on it, then expands into place. Geometry is read here rather than
     when the selection started, so a scroll during that beat can't launch the
     window from where the icon used to be. */
  function zoom() {
    selectTimer = null;
    if (!launched) return; // scrolled back up while the selection was showing

    const i = appEl.querySelector(".finder-icon").getBoundingClientRect();
    const w = windowEl.getBoundingClientRect();
    const scale = i.width / w.width;
    const dx = i.left + i.width / 2 - (w.left + w.width / 2);
    const dy = i.top + i.height / 2 - (w.top + w.height / 2);

    windowEl.style.transition = "none";
    windowEl.style.transform = `translate(${dx}px, ${dy}px) scale(${scale})`;
    windowEl.style.opacity = "0";
    void windowEl.offsetWidth; // commit the start frame before animating away from it

    windowEl.style.transition =
      `transform ${ZOOM_MS}ms cubic-bezier(0.19, 0.9, 0.28, 1), opacity 240ms ease-out`;
    windowEl.style.transform = "";
    windowEl.style.opacity = "1";

    appEl.classList.add("opened");
    demoEl.classList.add("launched");

    show(0, true); // the story starts when the app opens, not before
    resume();
  }

  function close() {
    if (!launched) return;
    launched = false;
    clearTimeout(selectTimer);
    selectTimer = null;
    halt();
    windowEl.style.transition = "none";
    windowEl.style.transform = "";
    windowEl.style.opacity = "0";
    appEl.classList.remove("opened", "selected");
    demoEl.classList.remove("launched", "instant");
  }

  /* Whichever of the two fires first drives the next step. rAF is the smoother
     clock and normally wins at ~16ms; the timer is only there because rAF is
     throttled to nothing in an occluded window, where a scroll that never
     finishes is worse than one that steps coarsely. */
  function nextFrame(fn) {
    let done = false;
    const run = () => {
      if (done) return;
      done = true;
      fn();
    };
    requestAnimationFrame(run);
    setTimeout(run, 32);
  }

  /* Double-click opens it, as it would in Finder. Enter and Space too, since
     this is a focusable control and double-click alone is unreachable from a
     keyboard. */
  /* Uniform rate, not a uniform duration: the page scrolls at a constant
     px/ms and the distance decides how long it takes. A fixed duration would
     make the long trip to the features section whip past at three times the
     speed of the short one to the demo. Calibrated from the short trip, which
     is the one that was tuned by eye. Linear within the run too — ease-in-out
     and a fast-ramp-then-glide were both tried here and read as awkward. */
  const SCROLL_SPEED = 1.03; // px per ms — opening the demo, tuned by eye
  const REVEAL_SPEED = 1.9; // px per ms — the button's longer run, briskly
  const SCROLL_MIN_MS = 240; // floor, so a short hop isn't an instant jump

  function glideTo(targetY, onArrive, speed) {
    const start = window.scrollY;
    const delta = targetY - start;
    const done = onArrive || function () {};
    if (Math.abs(delta) < 2) return done();

    const dur = Math.max(SCROLL_MIN_MS, Math.abs(delta) / (speed || SCROLL_SPEED));
    const t0 = performance.now();
    (function step() {
      const p = Math.min(1, (performance.now() - t0) / dur);
      window.scrollTo(0, start + delta * p);
      updateTravel(); // driven directly, so it never waits on a scroll event
      if (p < 1) nextFrame(step);
      else done();
    })();
  }

  function openFromClick() {
    glideTo(landingScroll(), open);
  }

  /* "See what it does" carries on to the features section rather than stopping
     at the demo — the demo is just switched on so it's already running as you
     pass it, no launch choreography to sit through. Its sticky hold means it
     stays put at the top for a moment on the way by. */
  /* Lands on the outcome list rather than the section's top edge — far enough
     in that the first card is the thing you arrive at, with the tail of the
     heading still above it for context. */
  const outcomesEl = $("#features .outcomes");
  const featuresEl = $("#features");
  const featuresScroll = () => {
    if (outcomesEl) return Math.max(0, docTop(outcomesEl) - LANDING_GAP - 40);
    if (featuresEl) return Math.max(0, docTop(featuresEl) - LANDING_GAP);
    return landingScroll();
  };

  function revealNow() {
    forced = true;
    if (!launched) {
      clearTimeout(selectTimer);
      selectTimer = null;
      launched = true;
      showInstant(10);
    }
    glideTo(featuresScroll(), null, REVEAL_SPEED);
  }

  const seeEl = $(".hero-cta .btn-secondary");
  if (seeEl && windowEl) {
    seeEl.addEventListener("click", (e) => {
      e.preventDefault();
      revealNow();
    });
  }

  if (appEl && windowEl) {
    appEl.addEventListener("dblclick", openFromClick);
    appEl.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        openFromClick();
      }
    });
    window.addEventListener("scroll", updateTravel, { passive: true });
    window.addEventListener("resize", updateTravel, { passive: true });

    if (reduceMotion) {
      // No travel, no zoom — the demo is simply there.
      demoEl.classList.add("launched");
      windowEl.style.opacity = "1";
      launched = true;
    } else {
      updateTravel();
    }
  } else {
    unhide(); // no icon or no window to zoom from — show the demo outright
  }

  /* A rect test on scroll rather than an IntersectionObserver, for the same
     reason as the autoplay tick — and the stakes are higher here. These
     elements start at opacity 0, so if observer callbacks are throttled or
     never delivered, every section below the hero stays invisible. A missed
     scroll event only delays a fade; a missed observer callback hides the
     page. Listeners detach once the last element has been revealed. */
  let pending = Array.from(document.querySelectorAll(".reveal"));

  function sweepReveals() {
    const limit = window.innerHeight * 0.88;
    pending = pending.filter((el) => {
      const r = el.getBoundingClientRect();
      if (r.top < limit && r.bottom > 0) {
        el.classList.add("in");
        return false;
      }
      return true;
    });
    if (!pending.length) {
      window.removeEventListener("scroll", sweepReveals);
      window.removeEventListener("resize", sweepReveals);
    }
  }

  window.addEventListener("scroll", sweepReveals, { passive: true });
  window.addEventListener("resize", sweepReveals, { passive: true });
  sweepReveals();
  /* Two more entry points that don't depend on a scroll ever happening: a
     deep link (#features) lands the viewport somewhere down the page before
     this script runs, and late-loading images can shift layout under it. */
  window.addEventListener("load", sweepReveals);
  setTimeout(sweepReveals, 400);

})();
