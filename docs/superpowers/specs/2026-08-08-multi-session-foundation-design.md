# Flight Deck — Multi-Session Foundation (Design Spec)

**Date:** 2026-08-08 · **Status:** approved design, ready for planning · **Builds on:** the
[walking skeleton](2026-07-09-flight-deck-design.md) (a single reused-Ghostty terminal running a
live shell).

## 1. Purpose

Take the walking skeleton — one window, one hard-wired terminal surface — to a **multi-session
foundation**: several live terminal sessions, grouped by repo, created/switched/closed from a
sidebar, with a Store as the single source of truth. In doing so, **fold in the documented
teardown-lifetime (UAF) fix** so that closing a session frees its surface safely.

This is the design's §9 phase-1 continuation *before* the harness adapter: it stands up the
Session/Project Store and the Sidebar UI shells (minus live-status columns, which need the adapter)
and the app-shell wiring for multiple surfaces. It deliberately excludes any agent/harness
orchestration.

## 2. The lifetime hazard being retired

Today `TerminalContainer.Coordinator` creates one `GhosttyApp` **per view**. `GhosttyApp.deinit`
frees the libghostty app **synchronously**, but `Ghostty.Surface.deinit` defers
`ghostty_surface_free` to a detached `@MainActor` `Task`. With a per-view app, releasing a view
(closing a session/window) frees the app immediately, and the later deferred surface-free then runs
against an already-freed app → use-after-free. The skeleton never closes a surface before process
quit, so it does not bite today — but multi-session close is exactly the trigger.

**Fix:** make the libghostty app a **process-wide singleton that outlives every surface**, owned by
an `AppDelegate` (mirroring Ghostty's own `AppDelegate` ownership, per FOLLOWUPS). The app is then
freed only at process termination, after all surfaces; the deferred surface-free can never race it.

## 3. Scope

**In scope**
- App-level singleton `GhosttyApp` owned by an `AppDelegate`.
- `Session` + `Repo` model and an observable `SessionStore` (single source of truth).
- A sidebar tree: repos → sessions, with create / switch / close.
- Repo creation via folder picker (`NSOpenPanel`); repo display name = last path component.
- Live terminal surfaces, one per session, **retained by the Store** and kept alive across
  switching; freed only on close.
- First-launch seed (one repo at `$HOME`, one session) so the app opens into a live terminal.
- Tests: model/store logic, and a create→close→create surface-lifecycle guard.

**Out of scope (deferred, and why)**
- Harness/agent orchestration, `AgentEvent`s, injection — the adapter phase.
- Sidebar live-status columns (attention / run-state / context budget / cost) — need the adapter's
  event stream; nothing real to show yet.
- Project rollup above repo — needs the memory/index layer; §5 lists it as later.
- Multiple windows, tabs, split panes — one main window with a sidebar is the north-star layout.
- Persisting/restoring sessions across launches — not needed to prove the foundation.
- Wiring `close_surface_cb` / `action_cb` (shell `exit`, title/clipboard/OSC) — the block-model /
  adapter phase (already tracked in FOLLOWUPS).

## 4. Architecture

Spine becomes:

```
FlightDeckApp (@main)
  └─ @NSApplicationDelegateAdaptor AppDelegate ── owns ──▶ GhosttyApp (singleton, process-wide)
  └─ RootWindow (single window)
       └─ RootView
            ├─ SessionSidebar        (renders SessionStore; create/switch/close)
            └─ TerminalPane          (shows the selected Session's retained SurfaceView)

SessionStore (ObservableObject, @MainActor)  ── single source of truth
  ├─ [Repo]  (id, url, displayName, [Session])
  ├─ selectedSessionID
  └─ per-session SurfaceView retention
```

| Unit | Purpose | Owns | Depends on |
|---|---|---|---|
| `AppDelegate` | Process-lifetime host for the libghostty app | the singleton `GhosttyApp` | `GhosttyApp` |
| `GhosttyApp` | libghostty app-state + surface factory (unchanged role, now shared) | `ghostty_app_t`, config | GhosttyKit |
| `SessionStore` | Session/repo data model + live state; single source of truth | repos, sessions, selection, retained surfaces | `GhosttyApp` (to make surfaces) |
| `SessionSidebar` | Render the tree; issue create/switch/close intents | rendering only | `SessionStore` |
| `TerminalPane` | Host the selected session's surface | rendering only | `SessionStore` |

**Invariants (carried over from the design spec's §3):** the Store is the single source of truth;
the sidebar and pane only render it. No component other than the Store creates or frees surfaces.

## 5. Data model

```swift
struct Session: Identifiable {
    let id: UUID
    var title: String            // e.g. "session 1"; renaming is out of scope
    let workingDirectory: String // inherited from its repo
}

struct Repo: Identifiable {
    let id: UUID
    let url: URL                 // the folder root
    var displayName: String      // url.lastPathComponent
    var sessions: [Session]
}
```

`SessionStore` holds `[Repo]`, `selectedSessionID: UUID?`, and a private
`[Session.ID: Ghostty.SurfaceView]` retaining live surfaces. It is `@MainActor` and
`ObservableObject`; all mutations are main-actor (surfaces are main-actor-bound).

## 6. Lifecycle & data flow

- **Create session**: sidebar "+" → folder picker → resolve/reuse the `Repo` for that URL (dedupe by
  path) → append a `Session` → make its `SurfaceView` via the singleton app (working dir = repo url,
  command = `ShellResolver.resolve()`) → retain in the Store → select it. First launch seeds this
  once with `$HOME` and no picker.
- **Switch session**: set `selectedSessionID`. The `TerminalPane` reads the retained `SurfaceView`
  for that id and re-parents it; the previously shown surface is **not** freed (its shell keeps
  running). This is the key mechanism: surfaces are retained by the Store, not the SwiftUI view
  tree, so switching never tears a shell down.
- **Close session**: remove the `Session` from its repo, drop the retained `SurfaceView` (its
  `deinit` schedules the deferred `ghostty_surface_free`; the singleton app stays alive). If the
  repo now has zero sessions, remove the repo. Re-select a sensible neighbor (or empty state).
- **Empty state**: if no sessions remain, the pane shows a placeholder with a "new session" action.
- **Quit**: single window ⇒ closing it terminates the app; `GhosttyApp` frees at process exit after
  all surfaces. (Window-close-without-quit only becomes reachable with multi-window, later; the
  singleton already makes it safe.)

## 7. Testing strategy

- **Store unit tests** (no UI): create dedupes repos by path; closing the last session removes the
  repo; selection moves to a valid neighbor on close; titles increment.
- **Surface-lifecycle guard**: drive create→close→create→close cycles through the Store and assert
  no crash and that the singleton `GhosttyApp`'s `ghostty_app_t` remains valid throughout (the
  regression test for the UAF fix). Runs headless where possible; otherwise a minimal launched-app
  harness extending the existing smoke test.
- **Launch smoke test**: extend the existing `TerminalSmokeTests` to assert the seeded session
  renders a live shell (unchanged first-run behavior) and that a second session can be created and
  closed.

## 8. Risks / notes

- **SwiftUI surface re-parenting.** Keeping a live `NSView` across selection changes fights SwiftUI's
  tendency to recreate representable views. Mechanism (a representable that returns the Store-retained
  surface instead of making a new one, re-parenting on update) is a plan-level detail; the invariant
  is that the Store owns surface lifetime, not the view tree.
- **Main-actor discipline.** All surface make/free and Store mutation stay on the main actor, matching
  libghostty's threading and the existing `Ghostty.Surface` contract.
- **No persistence.** Sessions are in-memory; relaunch starts from the seed. Acceptable for a
  foundation; restoration is a later concern.
```
