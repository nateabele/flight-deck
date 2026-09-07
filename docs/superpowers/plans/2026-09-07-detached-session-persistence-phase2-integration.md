# Detached Session Persistence — Phase 2: Swift integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `fd-abduco` (Phase 1) into Flight Deck so each session's agent runs in a detached daemon that survives the app being killed, reattaches with full terminal restored, and only cold-starts (with today's `--resume`/"Keep going") when no live daemon exists — deleting "Keep going" from the common restore path.

**Scope:** This is Phase 2 of the approved spec (`docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md`); Phase 1 (the `fd-abduco` fork + replay) is complete on this branch. Phase 3 (a dedicated end-to-end `TerminalSmokeTests` case + user-facing scrollback knob) remains separate.

**Architecture:** A new app-side `SessionDaemon` owns the socket/pidfile layout, a space-free path to the bundled `fd-abduco`, a liveness probe (Unix-socket `connect`), and daemon teardown. A pure `LaunchPlan` decides, per session, **attach** (a live daemon exists → `config.command = fd-abduco -a <sock>`, type nothing) vs **cold-create** (`config.command = fd-abduco -c <sock> <shell>` + today's typed resume/launch command). The decision is consumed at the two surface-creation sites and the Codex resume path; teardown fires on `closeSession` (not on quit — quit intentionally leaves daemons running); a launch-time reconcile reaps daemons with no matching session.

**Tech Stack:** Swift 5-mode app target (`Sources/FlightDeck`), `FlightDeckTests` (macOS, run via `./scripts/test-unit.sh`), POSIX `AF_UNIX`/signals, the Phase-1 C daemon (`vendor/fd-abduco`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md`

## Global Constraints

- **fd-abduco edits** retain the ISC/provenance headers; rebuild via `scripts/build-fd-abduco.sh`; keep all Phase-1 tests green (`Tests/fd-abduco/run_all.sh`).
- **Socket/pidfile dir:** a per-uid dir `"/tmp/flight-deck-\(getuid())"`, created mode `0700`. Socket `"<dir>/<sessionUUID>.sock"`, pidfile `"<sock>.pid"`. All paths must stay well under the macOS `sun_path` 104-byte limit (they do: ~53 chars).
- **Space-free binary path:** the bundled binary is at `Bundle.main.url(forResource:"fd-abduco",withExtension:nil)` — a path containing a space (`Flight Deck.app`). Never put that path in `config.command`. `SessionDaemon` maintains a symlink `"<dir>/fd-abduco"` → the bundled binary and uses THAT space-free path in commands.
- **`config.command` forms:** attach → `"<binary> -a <sock>"`; cold-create → `"<binary> -c <sock> <shell>"` (abduco grammar: `name` then command, **no** `--`). No path in these contains a space (per above), so ghostty's shell tokenizer splits them cleanly.
- **Behavior split:** `closeSession` terminates the daemon; **quit / `reapAllForQuit` must NOT** (daemons persist across quit — the setsid'd daemon is already outside the client's process group the quit reap targets, so this is mostly "do not add a kill", plus a test pinning it). Launch reconcile reaps daemons whose session is gone.
- **"Keep going" / resume gating:** the `DeferredPrompt`/`pendingPrompts` queueing and the typed `resumeCommand` fire **only on the cold-create path**, never on attach.
- **Seams for tests:** daemon probing/control and process signalling go behind protocols injected into `SessionStore`, so `FlightDeckTests` can drive attach-vs-cold and teardown without real daemons where possible; the `SessionDaemon` socket/probe unit may use real temp sockets.
- **No new entitlements.** Touching `Sources/FlightDeckMobile`/`FleetKit` is out of scope (macOS-only). `./scripts/test-unit.sh` runs the whole macOS suite (~8 min) and ignores `-only-testing:` — budget for that.

---

### Task 1: `fd-abduco` writes a pidfile so the daemon can be signalled

**Files:**
- Modify: `vendor/fd-abduco/abduco.c` (server-process branch of `create_session`, ~line 434-450; and the exit/`server_sigterm_handler` path).
- Test: `Tests/fd-abduco/run_pidfile_test.sh`.

**Interfaces:**
- Produces: a daemon at socket `S` writes `"<S>.pid"` containing its own decimal PID (the server process that owns the PTY and handles SIGTERM) at creation, and unlinks it on exit. Consumed by Task 3's `terminate`/`daemonPID`.

- [ ] **Step 1: Write the failing test.** `Tests/fd-abduco/run_pidfile_test.sh`: build, create a session at an explicit socket `S` running `sh -c 'sleep 30'`, assert `"<S>.pid"` exists and its contents are a live PID (`kill -0`), then `kill -TERM` that PID and assert both `S` and `"<S>.pid"` disappear within a short grace.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdp.XXXXXX).sock
"$BIN" -n "$SOCK" sh -c 'sleep 30'
sleep 0.5
test -f "$SOCK.pid"
PID=$(cat "$SOCK.pid"); kill -0 "$PID"
kill -TERM "$PID"
for i in $(seq 1 20); do test -e "$SOCK.pid" || break; sleep 0.1; done
test ! -e "$SOCK.pid" && test ! -e "$SOCK"
echo "pidfile OK"
```

- [ ] **Step 2: Run it, verify it fails** (`bash Tests/fd-abduco/run_pidfile_test.sh` → no `.pid` file).
- [ ] **Step 3: Implement.** In `abduco.c`, in the `default:` (server process) branch of the `forkpty` switch (after the SIGTERM/SIGINT handlers are installed, ~line 442, before `server_mainloop`), build the pidfile path (the daemon knows its socket path — reuse the resolved `sockaddr.sun_path`, or reconstruct from `server.session_name`; store the socket path in a static so the exit path can unlink it), write `getpid()` to `"<sock>.pid"` (create/truncate, `0600`). Unlink it in `server_sigterm_handler` and on the normal `server_mainloop` exit / `server_cleanup` path (wherever the socket itself is `unlink`ed — mirror that). Guard so a pidfile write failure is non-fatal (the daemon still runs).
- [ ] **Step 4: Run it, verify it passes** (`pidfile OK`).
- [ ] **Step 5: Rebuild + full fd-abduco suite.** `bash Tests/fd-abduco/run_all.sh` still green; add `run_pidfile_test.sh` to `run_all.sh`.
- [ ] **Step 6: Commit** (`feat(fd-abduco): write a <socket>.pid sidecar for daemon teardown`).

---

### Task 2: `SessionDaemon` — socket/pidfile/binary path layout (pure, unit-tested)

**Files:**
- Create: `Sources/FlightDeck/Fleet/SessionDaemon.swift` (or `Sources/FlightDeck/SessionDaemon.swift` — match where sibling infra like `SurfaceProcessRegistry.swift` lives).
- Test: `Tests/FlightDeckTests/SessionDaemonPathsTests.swift`.

**Interfaces:**
- Produces (consumed by Tasks 3-7):
  - `struct SessionDaemon` with an injectable `directory: URL` (default `URL(fileURLWithPath: "/tmp/flight-deck-\(getuid())")`) and `bundledBinary: URL?` (default `Bundle.main.url(forResource: "fd-abduco", withExtension: nil)`).
  - `func socketPath(for id: UUID) -> String` → `"<dir>/<id.uuidString>.sock"` (lowercased uuid).
  - `func pidfilePath(for id: UUID) -> String` → `socketPath(for:) + ".pid"`.
  - `func ensureDirectory() throws` → creates `directory` mode `0o700` (idempotent).
  - `func resolvedBinaryPath() throws -> String` → ensures a symlink `"<dir>/fd-abduco"` points at `bundledBinary`, returns that space-free path. Idempotent; re-points if stale.
  - `func attachCommand(for id: UUID) throws -> String` → `"\(binary) -a \(sock)"`.
  - `func coldCreateCommand(for id: UUID, shell: String) throws -> String` → `"\(binary) -c \(sock) \(shell)"`.

- [ ] **Step 1: Write failing tests** asserting: socket/pidfile path shapes for a known UUID and dir; total socket path length < 104; `ensureDirectory` creates a `0700` dir; `resolvedBinaryPath` creates a symlink to the injected fake binary and returns a space-free path; the two command strings contain no space in the binary or socket tokens (inject a `directory` under a space-free temp dir and a fake binary). Use a temp `directory` and a fake executable file.
- [ ] **Step 2: Run, verify fail** (`./scripts/test-unit.sh`, or compile just the new test if faster — note test-unit runs the whole suite).
- [ ] **Step 3: Implement `SessionDaemon`** per the interface. `resolvedBinaryPath` uses `FileManager` symlink APIs (remove + recreate if the link target differs). Throw a typed error if `bundledBinary` is nil.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: SessionDaemon socket/pidfile/binary path layout`).

---

### Task 3: Daemon liveness probe + teardown behind a seam

**Files:**
- Create: `Sources/FlightDeck/Fleet/DaemonControl.swift` (protocol `DaemonControlling` + real `PosixDaemonControl`).
- Modify: `Sources/FlightDeck/Fleet/SessionDaemon.swift` (adopt/expose the control).
- Test: `Tests/FlightDeckTests/DaemonControlTests.swift`.

**Interfaces:**
- Consumes: `SessionDaemon` paths (Task 2), the Phase-1 daemon (Task 1 pidfile).
- Produces (consumed by Tasks 5-7):
  - `protocol DaemonControlling { func isLive(_ id: UUID) -> Bool; func daemonPID(_ id: UUID) -> pid_t?; func terminate(_ id: UUID) }`
  - `PosixDaemonControl`: `isLive` does a non-blocking `connect()` to the AF_UNIX socket — `true` if it connects (or `EISCONN`), `false` on `ENOENT`/`ECONNREFUSED` (and unlink the stale socket + pidfile on `ECONNREFUSED`). `daemonPID` reads+parses the pidfile and returns it only if `kill(pid, 0)` succeeds. `terminate` reads the pid, `SIGTERM`, waits up to ~1s (poll `kill(pid,0)`), then `SIGKILL`; finally unlink socket + pidfile. All no-throw (log on failure).

- [ ] **Step 1: Write failing tests.** For `isLive`: bind a real `AF_UNIX` listener in the test at the computed socket path → `isLive` true; no socket → false; a stale socket file with no listener → false and the file is unlinked. For `daemonPID`/`terminate`: launch a REAL `fd-abduco -n <sock> sh -c 'sleep 30'` (the artifact built by Phase 1) so a real daemon+pidfile exist, assert `daemonPID` matches the pidfile and `isLive` is true, call `terminate`, assert `isLive` becomes false and socket+pidfile are gone. (These are integration-flavored unit tests using the real binary; gate on the artifact existing, build it if missing.)
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement `PosixDaemonControl`** (raw `socket(2)`/`connect(2)` with `O_NONBLOCK`; `kill(2)`; `unlink(2)`).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: daemon liveness probe + SIGTERM/SIGKILL teardown`).

---

### Task 4: `LaunchPlan` — the pure attach-vs-cold-create decision

**Files:**
- Create: `Sources/FlightDeck/Fleet/LaunchPlan.swift`.
- Test: `Tests/FlightDeckTests/LaunchPlanTests.swift`.

**Interfaces:**
- Consumes: `SessionDaemon` command builders (Task 2), a liveness bool.
- Produces (consumed by Tasks 5-6):
  - `enum LaunchPlan { case attach(command: String); case coldCreate(command: String, typed: String) }`
  - `static func decide(sessionID: UUID, isLive: Bool, shell: String, resumeOrLaunch typed: String, daemon: SessionDaemon) throws -> LaunchPlan` — `isLive` → `.attach(daemon.attachCommand(...))`; else → `.coldCreate(daemon.coldCreateCommand(..., shell: shell), typed: typed)`. `typed` is the caller's existing `initialInput`/`resumeCommand` string (empty allowed).

- [ ] **Step 1: Write failing tests:** live → `.attach` with the `-a` command and (implicitly) no typed text; dead → `.coldCreate` with the `-c` command and the passed-through `typed`. Assert command strings match `SessionDaemon`'s builders.
- [ ] **Step 2-4: Run-fail, implement, run-pass.**
- [ ] **Step 5: Commit** (`feat: LaunchPlan attach-vs-cold-create decision`).

---

### Task 5: Wire the decision into the two surface-creation sites

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — `insertSession(_:in:initialInput:at:)` (config block ~1922-1945) and `respawnSurface(for:)` (~1007-1051); add an injected `daemon: SessionDaemon` + `daemonControl: DaemonControlling` to `SessionStore` (default real impls in the production initializer at `FlightDeckApp.makeStore`, `FlightDeckApp.swift:160-209`).
- Test: `Tests/FlightDeckTests/SessionDaemonWiringTests.swift`.

**Interfaces:**
- Consumes: `LaunchPlan` (Task 4), `DaemonControlling` (Task 3), `SessionDaemon` (Task 2).
- Produces: both sites set `config.command` from the `LaunchPlan` and set `config.initialInput` to the plan's typed text (empty on attach). A test seam `DaemonControlling` lets tests force live/dead.

- [ ] **Step 1: Write a failing test** with a fake `DaemonControlling`: forcing `isLive == true` for a session makes `insertSession` produce a surface whose config `command` is the `-a` attach command and whose `initialInput` is empty; forcing `false` yields the `-c` cold command with the caller's `initialInput` preserved. (Use the existing `SurfaceProvider` test seam — inspect the `Ghostty.SurfaceConfiguration` handed to a fake provider.)
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** In `insertSession`, replace the `config.command = resolvedShell()` / `config.initialInput = initialInput` pair with: compute `isLive = daemonControl.isLive(session.id)`, `plan = LaunchPlan.decide(sessionID: session.id, isLive: isLive, shell: resolvedShell, resumeOrLaunch: initialInput, daemon: daemon)`, then set `config.command = plan.command`; `config.initialInput = plan.typed` (attach ⇒ ""). Do the same in `respawnSurface` (its `initialInput` there is `adapter.launchCommand(...)`; on attach that becomes ""). Keep `workingDirectory`/`env`/`fontSize` unchanged. Ensure `daemon.ensureDirectory()`/`resolvedBinaryPath()` run once before first use.
- [ ] **Step 4: Run, verify pass** (plus the full suite green).
- [ ] **Step 5: Commit** (`feat: launch sessions through fd-abduco (attach or cold-create)`).

---

### Task 6: Gate resume + "Keep going" to the cold path (Claude and Codex)

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — `restore()` (the per-entry loop ~2044-2152, the `initialInput` construction ~2089-2110, and the `pendingPrompts` gate ~2145-2151) and `resumeRestoredCodex(_:)` (~2204-2264, the `sendToShell(resumeCommand)` at ~2262).
- Test: `Tests/FlightDeckTests/ResumeGatingTests.swift`.

**Interfaces:**
- Consumes: `DaemonControlling` (Task 3), the Task-5 wiring.
- Produces: when a session's daemon is live at restore, no `resumeCommand` is typed and no `DeferredPrompt`/"Keep going" is queued; when dead, behavior is exactly as today.

- [ ] **Step 1: Write failing tests.** With a fake `DaemonControlling`: (a) live daemon at restore → the restored tab gets `initialInput == ""` (attach, via Task 5) AND `pendingPrompts[id]` is NOT set even when `activity == .busy` and `autoResume == true`; (b) dead daemon → `initialInput == resumeCommand` and the "Keep going" `DeferredPrompt` IS queued under the same `isResumable` gate as today. Drive `restore()` through the existing persistence/test seams (see `SessionAutoResumeTests` for the established harness).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** In `restore()`: compute `isLive` once per entry; when live, set the entry's `initialInput` to `""` (the Task-5 wiring already turns a live probe into an attach command, but the resume-string construction at ~2096 must be skipped so nothing is typed) and skip the `pendingPrompts[entry.id] = DeferredPrompt(...)` block. When dead, keep both. For Codex in `resumeRestoredCodex`: if `daemonControl.isLive(tabID)`, skip the `sendToShell(adapter.resumeCommand(...))` (the thread is already live in the daemon) — still refresh the title if cheap; when dead, run the existing flow. Keep the orphaned/deferred handling intact.
- [ ] **Step 4: Run, verify pass** (full suite).
- [ ] **Step 5: Commit** (`feat: skip --resume and "Keep going" when reattaching a live daemon`).

---

### Task 7: Terminate on close; reconcile/reap orphans on launch; keep daemons across quit

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — `reapSession(_:process:context:)` (~2570-2583) or `closeSession` (~2437-2528) to also `daemonControl.terminate(id)`; a launch reconcile invoked from `restore()`/init; confirm `reapAllForQuit` (~2701+) and `sweepOrphans` (~2599-2643) do NOT terminate daemons.
- Test: `Tests/FlightDeckTests/DaemonLifecycleTests.swift`.

**Interfaces:**
- Consumes: `DaemonControlling` (Task 3), `SessionDaemon` directory enumeration (Task 2 — add `func liveSessionIDs() -> [UUID]` that lists `*.sock` in `directory` and maps filenames back to UUIDs).
- Produces: closing a tab terminates its daemon; a launch reconcile terminates daemons whose UUID is not among the restored sessions; quit leaves daemons alive.

- [ ] **Step 1: Write failing tests** with a fake `DaemonControlling` recording `terminate` calls: (a) `closeSession(id)` calls `terminate(id)` exactly once (after the existing client reap); (b) a reconcile given "sockets for {A,B,C}" and "restored sessions {A,B}" calls `terminate(C)` and not `terminate(A/B)`; (c) `reapAllForQuit`/quit path calls `terminate` for NO session (persistence across quit). Add `SessionDaemon.liveSessionIDs()` with its own path-parsing test.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** Add `terminate(id)` to the `closeSession`→`reapSession` async tail (after `reaper.reap` of the client, so the client detaches first, then the daemon dies). Add a `reconcileDaemons(restored: Set<UUID>)` called near the end of `restore()`: for each `daemon.liveSessionIDs()` not in `restored`, `daemonControl.terminate(id)`. Make NO change that terminates daemons in `reapAllForQuit`/`sweepOrphans` (add a comment pinning why: the setsid'd daemon is outside the client pgid those reap, and quit must persist). 
- [ ] **Step 4: Run, verify pass** (full suite).
- [ ] **Step 5: Commit** (`feat: terminate daemon on close and reap orphans on launch; persist across quit`).

---

### Task 8: Build, wire production defaults, document

**Files:**
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (`makeStore`, ~160-209) — construct the real `SessionDaemon` + `PosixDaemonControl` and inject them into `SessionStore` (only if not already done in Task 5).
- Modify: `docs/ARCHITECTURE.md` (a "Detached sessions" section: the daemon model, attach-vs-cold, quit-persists, close-terminates) and `docs/FOLLOWUPS.md` (carry-forward: replay backpressure via `writefds`, nested-binary signing validation, opportunistic `FdOutlog` hardening; debug/release share the socket dir — note the `-FlightDeckStateDir` salting option).
- Test: n/a (build + full suite).

- [ ] **Step 1:** Ensure the production `SessionStore` is constructed with the real daemon + control; default parameters keep every existing initializer/test call compiling.
- [ ] **Step 2: Build the app** per `docs/BUILD.md` (`./scripts/build-fd-abduco.sh` then `./scripts/build.sh`) → BUILD SUCCEEDED; confirm `fd-abduco` still bundles.
- [ ] **Step 3: Run the full suites:** `bash Tests/fd-abduco/run_all.sh` and `./scripts/test-unit.sh` (macOS; ~8 min; ignores `-only-testing:`). Both green.
- [ ] **Step 4:** Write the ARCHITECTURE/FOLLOWUPS docs.
- [ ] **Step 5: Commit** (`docs: document detached-session daemon model; wire production defaults`).

---

## Verification (whole phase)

- `bash Tests/fd-abduco/run_all.sh` (incl. new `run_pidfile_test.sh`) green.
- `./scripts/test-unit.sh` green (SessionDaemon paths, DaemonControl probe/teardown, LaunchPlan, wiring, resume-gating, lifecycle).
- App builds; `fd-abduco` bundled.
- **Manual end-to-end (the payoff, not automated here — Phase 3 automates it):** launch the app with a running claude session; `kill -9` the app (simulating swap-release); relaunch → the tab reattaches, the terminal shows the prior scrollback, claude is the SAME process (same pid, mid-work), and **no "Keep going" is typed**. Then close the tab → the daemon (and claude) exit; the socket/pidfile are gone.

## Non-goals (Phase 3 / later)

- A dedicated `TerminalSmokeTests` end-to-end reattach test and the user-facing scrollback-budget preference.
- Replay backpressure (drive replay via `writefds` instead of the `write_all` busy-spin) and nested-binary code-signing validation — carried forward from Phase 1 review.
- Surviving a Mac reboot (daemons in `/tmp` die on reboot; cold-resume remains the post-reboot path).
