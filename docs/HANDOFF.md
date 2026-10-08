# Flight Deck — Session Handoff

**Date:** 2026-08-11 · **Branch:** `master` · **Tip:** `4684bf1` · **Status:** Multi-Session Foundation **and** Session Name Sync both merged to `master`; unit + smoke gates GREEN (66 unit tests, 4 UITests).

Start here if you're picking up Flight Deck fresh. This is the map; the linked docs have the detail.

> **▶ One agent identity, grok and gemini tabs, account pools (2026-10-08) — merged to `master`.**
> `AgentID` (IntakeKit: claude, codex, grok, gemini) is the only agent type; `Harness`,
> `ModelFamily` and `HarnessID` are gone, and each `AgentAdapter` carries its headless
> `profile`. grok (`Agents/Grok/`) and gemini (`Agents/Gemini/`, driving the Antigravity CLI
> `agy`) run in tabs through real adapters. Settings → Accounts is one list of accounts and
> single-agent pools; a project assigns each agent an account or a pool, and tabs and every
> planning seat bill it through one `AccountResolver` and one `CapacityLedger` (the Rounds
> editor's per-seat account picker is gone). GUI checks still owed are in
> [FOLLOWUPS.md](FOLLOWUPS.md), "Unify agents, grok/gemini tabs, account pools"; no UI test has
> run on this work yet. Details: [ARCHITECTURE.md](ARCHITECTURE.md), "Agents".

> **▶ Flight Control on the phone (2026-09-29) — Phase 1 (watch, read-only) built on branch `fc-mobile-watch`; Phase 2 (steer) on `fc-mobile-steer`.**
> The phone lists a project's intakes at the top of its section (with a "N need you" badge and an
> in-app banner on a live transition to needing you), and opens an intake to its board strip,
> agents, rounds, round detail, clarifications, plan outline and plan reader (changes and notes
> shown, not editable). What crosses the wire: a sequenced `project.intakes` event of
> `WireIntakeSummary`s, sent only to peers claiming the `flightControl` capability, so an older
> phone never sees it; and two requests, `intake.detail` (etag-polled while an intake's screens
> are open) and `intake.plan`. Wire types are in `Sources/FleetKit/IntakeWire.swift`; the Mac side
> is `Sources/FlightDeck/Fleet/` plus `SessionStore.intakeSummaries`; the phone side is flat in
> `Sources/FlightDeckMobile/` (`FlightControlModel`, `IntakeDetailModel`, `IntakeScreen`,
> `BoardStrip`, `AgentRow`, `RoundDetailScreen`, `PlanOutlineScreen`, `PlanReaderScreen`, …).
> **Phase 2 (steer) built on branch `fc-mobile-steer`:** the strip grows a transport row (Pause,
> Step, Major, Review, Stop — the Mac's glyphs; tap acts, long-press on a play key sets the
> default, Stop always confirms), the Rounds header a "Refine ×N − +", and the plan reader notes —
> "Note…" in the selection menu, a per-passage ⋯ menu, a plan-wide note, Delete on a pending note,
> with unsent notes kept on screen by a `NoteOutbox`. Four commands (`intake.tape`,
> `intake.defaultPlay`, `intake.note`, `intake.removeNote`), sent only when the detail's `steer`
> is true (an older Mac drops the socket on an unknown command), validated on the Mac by the
> same `TransportRules` that drive its control bar and deduplicated by token. A phone note's
> rendered quote is found in its own block's source by `RenderedQuoteLocator`, falling back to
> the whole block, never another passage. Phone side: `TransportKeys`, `IntakeCommands`,
> `NoteComposer`, `NoteSheet`; Mac side: `IntakeService` and `TransportRules`.
> Phase 3 (unblock, start, finish: answers, fidelity, retry, review and release) is planned from
> the same spec.
> - **Spec:** [superpowers/specs/2026-09-29-flight-control-mobile-design.md](superpowers/specs/2026-09-29-flight-control-mobile-design.md) (§11.1, §11.2: as built) · **Plans:** [watch](superpowers/plans/2026-09-29-flight-control-mobile-watch.md), [steer](superpowers/plans/2026-09-29-flight-control-mobile-steer.md) · **Terrain:** [FLIGHT-CONTROL-MOBILE-HANDOFF.md](FLIGHT-CONTROL-MOBILE-HANDOFF.md) · **Device checks:** [MOBILE.md](MOBILE.md) items 75–93.

> **▶ Flight Control coverage × fidelity (2026-09-29) — built, on branch `worktree-coverage`, not yet merged to `master`.**
> Refine rounds can now cross-check: a second model family (`RoundConfig.crossReviewer`)
> reviews the same round in parallel on whichever rounds the config's `CrossCheckPolicy` picks
> (off / first-and-last / every), turned on from the Rounds inspector's new Cross-check row.
> `CoverageSeries` folds both reviewers' verdicts into a coverage estimate — SATURATED / FEW
> LEFT / MANY LEFT / NO OVERLAP / STALLED — shown on the LCD's COVERAGE cell and the coverage
> card beside Convergence. `CoverageThresholds` (band boundaries) and `CoverageTargets`
> (per-fidelity stop targets), both in `IntakeKit`, are uncalibrated placeholders — no tape has
> run long enough yet to tune them against real data.
> - **Spec:** [superpowers/specs/2026-09-29-flight-control-coverage-design.md](superpowers/specs/2026-09-29-flight-control-coverage-design.md) · **Handoff:** [FLIGHT-CONTROL-COVERAGE-HANDOFF.md](FLIGHT-CONTROL-COVERAGE-HANDOFF.md).

> **▶ Multi-agent ⌘K search (2026-09-21) — built, on branch `worktree-multi-agent-search`, not yet merged to `master`.**
> ⌘K now searches every agent's history, not just claude's. A codex thread is discovered,
> indexed and resumed the same way a claude conversation is, through one capability object —
> `AgentSearchCorpus` — reached beside `textChannel`, `dialogDriver` and `openPromptReader`.
> Discovery is per-account now too, which also fixed ⌘K being blind to a second claude login.
> `codex exec` runs are indexed but ranked below real conversations, and Return resumes a
> result into its own agent and the working directory the walk recorded — for a name match
> as well as a transcript hit, both now filled from the same index lookup. The 18-commit
> branch passed its whole-branch review and the fix wave that followed; merge to `master` is
> still pending.
> - **Spec:** [superpowers/specs/2026-09-21-multi-agent-search-design.md](superpowers/specs/2026-09-21-multi-agent-search-design.md) · **Plan:** [superpowers/plans/2026-09-21-multi-agent-search.md](superpowers/plans/2026-09-21-multi-agent-search.md) · **Details:** [ARCHITECTURE.md](ARCHITECTURE.md), "Search" section.

> **✅ ⌘K Search (2026-08-27) — merged.**
> `⌘K` opens a fleet-wide search overlay: type a session or project name to jump straight to
> it, or a phrase you remember saying to search full transcript history — ranked by match
> quality; at equal quality an open session beats a closed one, then recency breaks ties. First launch backfills that transcript
> history in the background (newest conversations first), so name search works immediately
> and transcript hits fill in as the backfill catches up. A running session's own transcript
> indexes live as it streams, so it needs no backfill of its own. Ghostty claims `⌘K` for
> `clear_screen` by default and had to be unbound (`GhosttyDefaults.conf`), the same way
> `⌘⇧T` was for Reopen Closed Session below.
> - **Spec:** [superpowers/specs/2026-08-26-smart-search-design.md](superpowers/specs/2026-08-26-smart-search-design.md) · **Details:** [ARCHITECTURE.md](ARCHITECTURE.md), "Search" section.

> **▶ Agent Adapters (2026-08-19) — in progress, one decided step remaining.**
> Any tab can now run **claude or codex**. Claude's half is complete and unchanged; codex
> creates, resumes and renames, but its observation half (title sync, status, sub-agent
> counts, unread) is inert because codex's app-server notifications turn out to be scoped to
> the connection that made the change — and turns run in a separate `codex resume` process.
> The fix is decided (tail the rollout `.jsonl`) and not yet built.
> **Start at [HANDOFF-agent-adapters.md](HANDOFF-agent-adapters.md) §2 before touching codex.**

> **✅ Two phases are merged to `master` and green.**
>
> **Multi-Session Foundation** — repo-grouped session sidebar with create/switch/close, a
> single `SessionStore` as source of truth, and a process-wide `GhosttyApp`. One macOS gotcha
> was resolved along the way: under XCUITest's raw-exec launch the initial window is gated
> behind the window-restoration handshake that only LaunchServices completes, so the tests
> pass `-ApplePersistenceIgnoreState YES` to match real-user launch semantics. Full
> postmortem: [done/HANDOFF-smoke-gate.md](done/HANDOFF-smoke-gate.md).
> - **Plan:** [superpowers/plans/2026-08-09-multi-session-foundation.md](superpowers/plans/2026-08-09-multi-session-foundation.md) · **Spec:** [superpowers/specs/2026-08-08-multi-session-foundation-design.md](superpowers/specs/2026-08-08-multi-session-foundation-design.md)
>
> **Session Name Sync** — session names stay in sync with the `claude` running in each
> terminal, in both directions, and sessions now survive relaunch (each terminal reattaches to
> its own Claude conversation via `--resume`). Rename is reachable three ways: double-click,
> Return on the selected row (once the sidebar has focus — click the row you are already on),
> and the row's context menu. Double-click and Return both come from a passive event monitor
> that adds nothing to the row, because the original SwiftUI tap gesture blocked
> drag-to-reorder and an `NSViewRepresentable` made the row title unhittable; see the
> project-tabs section of [FOLLOWUPS.md](FOLLOWUPS.md).
> - **Plan:** [superpowers/plans/2026-08-10-session-name-sync.md](superpowers/plans/2026-08-10-session-name-sync.md) · **Spec:** [superpowers/specs/2026-08-10-session-name-sync-design.md](superpowers/specs/2026-08-10-session-name-sync-design.md)
>
> Also fixed: ⌘Q and any other menu shortcut were being swallowed by the terminal
> (`Sources/FlightDeck/MenuKeyEquivalents.swift`).

---

## What Flight Deck is

An **orchestration-native macOS terminal**: a from-scratch app that reuses Ghostty for the terminal, will orchestrate external agent harnesses (Claude Code, opencode) behind an adapter, wrap them in a context engine you own and can inspect, and show every agent's live status in a nested `session → repo → project` sidebar.

Full vision and the locked design decisions: **[design spec](superpowers/specs/2026-07-09-flight-deck-design.md)**.

## Where things stand

The **walking skeleton is done**: the app renders a **live terminal running a real login shell**, drawing through a reused-Ghostty surface. Verified via screenshot (`me@mac ~ %` prompt), process tree (`FlightDeck → login → zsh`), and green unit + smoke tests.

That was deliberately the smallest self-contained slice that also retired the biggest unknown — *can we actually reuse Ghostty to render a terminal inside our own app?* Answer: **yes.** Everything else in the design (adapter, index, context engine, sidebar) is still ahead, each its own spec→plan→build cycle.

Also landed: a session whose turn died on a transient API error (rate limit, overload) can now nudge itself back to life on a backoff ladder, up to 15 minutes between tries, for as long as the outage lasts — gated by the **Retry after API errors** toggle in Shell & Environment → Recovery, off by default because it types into the session on the user's behalf.

## Quickstart (this host)

```bash
cd ~/Projects/flight-deck
git submodule update --init          # fetch vendored Ghostty @ v1.3.1
./scripts/build-libghostty.sh        # build GhosttyKit.xcframework (~10 min first run)
./scripts/build.sh                   # generate project + build "Flight Deck.app"
open "DerivedData/Build/Products/Debug/Flight Deck.app"   # a live terminal
```

Full details, prerequisites, and troubleshooting: **[BUILD.md](BUILD.md)**.

## Driving Flight Deck from a shell (`flightdeck`)

Every tab ships a CLI that speaks the same protocol as a paired phone, over a local socket
instead of the network — so an agent running *inside* a tab can see and drive the rest of the
fleet without going through the UI. It's already on `PATH` (`Contents/MacOS`, alongside
Ghostty's own bin dir), so no absolute path is needed from inside a tab:

```bash
flightdeck ls                                  # every session, grouped by project
flightdeck tail --session self --no-snapshot   # stream this tab's fleet events (activity, unread, rename, …) as NDJSON
flightdeck send <tab> "run the tests" --wait   # type into another tab, then block until that turn ends
flightdeck wait <tab> --for idle               # block until a tab is idle (or busy, waiting, gone)
flightdeck prompt <tab>                        # print the open question/permission prompt a tab is blocked on
```

`tail` streams fleet events, not the transcript (use `timeline` for that), and without
`--no-snapshot` its first line is a snapshot of the whole fleet, even with `--session`. Use
`send --wait` rather than `send` then `wait --for idle`: the tab is still idle when the send is
acked, because the Mac has not typed the text yet, so a bare `wait` right after returns at once.
Put `--` before text that starts with `-`: `flightdeck send S --wait -- "- text"`. Flags may go
before or after operands, but never after `--`.

Full command table, wire mapping, and the `--help` output: **[design spec](superpowers/specs/2026-09-24-flightdeck-cli-design.md)**. What each tab is allowed to reach — any session, only its own, or nothing — is set per-Mac in Preferences → Devices → "Command Line"; see **[ARCHITECTURE.md](ARCHITECTURE.md)**, "Local control socket".

Codex tabs (codex 0.155.1 or newer) reach `flightdeck` through a narrow sandbox grant, for the control socket file only, that Flight Deck adds to their launch line (not when you chose a codex sandbox in Preferences); a blocked agent gets exit `77`. After a codex update, run `./scripts/test-codex-live.sh` to check the grant still holds — see ARCHITECTURE.md, "Codex tabs".

## Remote hosts (sub-project A)

**State:** merged to master (12 tasks). A Flight Deck can pair
a second Mac or a Linux box as a *host*, keep an authenticated link to it, and read its toolchain
with `flightdeck host ls` and `flightdeck host info <name>`. Settings has two new tabs: Hosts
(paired hosts, Add Host) and Hosting (this Mac as a host). Running commands on a host is
sub-project C, the next section.

- Design: [the remote-hosts spec](superpowers/specs/2026-10-03-remote-hosts-delegation-design.md)
  (its §3.2 lists the deviations decided while building, including the 0xCCAC ruling).
- Plan: [the host-foundation plan](superpowers/plans/2026-10-04-host-foundation.md).
- As built: [ARCHITECTURE.md, "Hosts"](ARCHITECTURE.md#hosts-hostkit--hostdaemon--hostdaemonlinux--sourcesflightdeckhosts);
  scripts in [BUILD.md](BUILD.md); the macOS hostd ships as the helper app
  `Contents/Library/LoginItems/Flight Deck Host.app` (`dev.flightdeck.hostd`) so it never borrows
  the app's identity; the hostd process hazards in
  [AGENT-OPERATIONS.md](AGENT-OPERATIONS.md); open items in [FOLLOWUPS.md](FOLLOWUPS.md).
- **Sub-project C is built** (next section); probe P3, the one placement assumption, is still
  unverified.
- **The maintainer's before merging:** the GUI end-to-end checklist (FOLLOWUPS), building both Linux
  architectures, and publishing the release (next section).

## Delegated execution (sub-project C)

**State:** built in parallel tracks C0–C8, integrated on branch `c8-int`, and merged to master
with the final-review fixes (not pushed).
A tab runs a command on a paired host as if locally: `flightdeck run --on mini -- xcodebuild test`
syncs the tab's uncommitted worktree through git, streams the output, and exits with the remote
code (125 with one `flightdeck:` line when delegation itself failed). `up`/`down` keep a service
running with its ports forwarded to `localhost`; `diff`/`apply` bring back what the run changed;
`.flightdeck/delegate.toml` holds recipes and `[[route]]` rules, and routed commands are
intercepted by per-tab shims on `PATH`. Claude and codex tabs learn all of it from one bundled
`delegate` skill.

- Design: [the remote-hosts spec](superpowers/specs/2026-10-03-remote-hosts-delegation-design.md), §4–§9.
- Plan: [the delegated-execution plan](superpowers/plans/2026-10-05-delegated-execution.md).
- As built: [ARCHITECTURE.md, "Delegated execution"](ARCHITECTURE.md#delegated-execution-sub-project-c);
  test commands in [BUILD.md](BUILD.md); probes P1–P4 in [DELEGATION-PROBES.md](DELEGATION-PROBES.md);
  open items in [FOLLOWUPS.md](FOLLOWUPS.md).
- **Verified in unit tests, an end-to-end loopback (`DelegationLoopbackTests`: the real service,
  link and macOS hostd in one process) and the Linux hostd in a container
  (`test-hostd-linux-interop.sh run`).** No delegated run has crossed to a real second machine. The maintainer's before relying on it: probes P3 and P4 on a second Mac, a real
  UI-test run there (the "don't touch" panel, a second screen run queueing), a Linux pairing plus a
  `flightdeck run`, and `command -v <routed command>` in a real tab to see the shim is first on
  `PATH` (FOLLOWUPS lists all of it).
- **Not from this repo.** Flight Deck's own repo has submodules (`vendor/ghostty`,
  `vendor/boringssl`), and v1 refuses any repo with submodules (`submodules_unsupported`, exit 125).
  Try it from a project without them.
- **Debug builds:** shims go under `Flight Deck (Debug)/route-shims/`; a UITest reset builds no
  delegation at all; a Debug codex start does not install the skill into the real `~/.codex`.

### Use a second Mac today

The laptop is the *controller*, the other Mac (here, `mini`) the *host*. Both need **git 2.40 or
later at `/usr/bin/git`**: the hostd is started by launchd with launchd's `PATH`, so it runs
`/usr/bin/git` (the Xcode or Command Line Tools git, whichever `xcode-select -p` names) and never a
Homebrew one. `/usr/bin/git --version` on each machine; anything older refuses every run with
`git_too_old`. The repo you run from must have no submodules and no LFS.

1. **Install the same build on the mini.** Copy the laptop's `/Applications/Flight Deck.app` there
   (a different major version is refused with "Update Flight Deck on <name>"). Someone must stay
   logged in on the mini: the hostd is a LaunchAgent and stops at logout.
2. **On the mini: Settings → Hosting → "Let other Macs use this Mac" on.** Approve it if macOS asks
   (System Settings → General → Login Items); the tab then says "Running on port 47410". Click +
   under Controllers to show a pairing code (it expires in 2 minutes). The sheet also lists where
   the mini can be reached — its Tailscale address and MagicDNS name when Tailscale is up, its LAN
   addresses, its `.local` name — each with the pairing port (47411, or the ephemeral port it fell
   back to when 47411 was taken, called out in orange), and **Copy Pairing Details** copies
   `<best address>:<port> <CODE>`.
3. **On the laptop: Settings → Hosts → Add Host (+ under Paired Hosts), choose Mac,** pick the mini
   from the Macs showing a code, and type the code. **Not on the same network (e.g. over
   Tailscale)?** Bonjour stops at the LAN, so the list stays empty (after 5 s it says so). Type the
   mini's address into the address field instead — or paste the copied pairing details there,
   which fills the address and the code at once. The Linux tab's address field takes the same
   paste.
4. **Check the link from a tab on the laptop:** `flightdeck host ls` shows the mini online under the
   name you will pass to `--on`, and `flightdeck host info mini` lists its Xcode versions.
5. **A first run.** From a tab whose working directory is inside a git repo (uncommitted edits
   included): `flightdeck run --on mini -- 'uname -n && pwd'` (quoted, so the `&&` runs
   on the mini). It syncs the
   worktree, prints the mini's output, and exits with the remote code; a delegation failure is
   exit 125 with one `flightdeck:` line saying what to do. Then a real one, e.g.
   `flightdeck run --on mini -- xcodebuild test -scheme App`. `flightdeck diff <run>` /
   `flightdeck apply <run>` bring back what it changed.
6. **Optional: `.flightdeck/delegate.toml`** in the repo, so agents need no flags:

   ```toml
   default_host = "mini"

   [recipe.ui-tests]
   run = "xcodebuild test -scheme App -only-testing:AppUITests"
   screen = true      # waits for the mini's one screen; needs it logged in and unlocked
   long = true        # prints the run id and exits; `flightdeck wait <id>` picks it up

   [[route]]
   match = "xcodebuild test *"
   recipe = "ui-tests"
   ```

   `flightdeck recipe check` validates it. Tabs opened in the project after that route a typed
   `xcodebuild test …` to the mini; `FLIGHTDECK_NO_ROUTE=1` runs one locally.

Stopping Hosting on the mini (or an update that restarts its hostd) stops its delegated runs and
services cleanly; see [AGENT-OPERATIONS.md](AGENT-OPERATIONS.md), "Delegated runs".

## Releasing the Linux host (`flightdeck-hostd`)

Settings → Hosts → Add Host → Linux shows one command, `curl -fsSL <base>/hostd-install.sh | sh
-s -- --sha256 <digest>`. Its `<base>` is `https://github.com/nateabele/flight-deck/releases/download/hostd-v<MARKETING_VERSION>`
(`MARKETING_VERSION` is in `project.yml`), and its `<digest>` is the SHA-256 of that release's
`SHA256SUMS`. Until the digest is set, the sheet says the installer is not published.

1. `./scripts/build-hostd-linux.sh` builds both architectures in Docker (x86_64 is emulated and
   slow) into `build/hostd-release/`: the two tarballs, `hostd-install.sh`, `SHA256SUMS`, and
   `installer.xcconfig`, which carries the digest.
2. `./scripts/test-hostd-install.sh` runs the pasted command end to end in `ubuntu:24.04` from a
   local HTTP server and ends `INSTALL PASS`. It rebuilds aarch64 only, which **empties
   `build/hostd-release/`**, so run it before step 1 or with `FD_HOSTD_SKIP_BUILD=1`.
3. **Publishing is a manual, outward-facing step that no script performs.** Create the GitHub
   release `hostd-v<MARKETING_VERSION>` and upload the two tarballs, `hostd-install.sh` and
   `SHA256SUMS` from step 1, with no rebuild in between: the digest pins those exact bytes.
4. Build the Release app (`scripts/swap-release.sh`). The Release config includes
   `build/hostd-release/installer.xcconfig` optionally, so it embeds the digest. Debug, and any
   checkout that has no assets built, keep the digest empty.

## How the code is laid out

The spine is `FlightDeckApp → RootWindow → TerminalPane → GhosttyApp → Ghostty.SurfaceView`. Flight Deck's own code is small; the terminal surface is adapt-copied from Ghostty and decoupled from its app shell. Component map and key files: **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Key decisions already made (don't relitigate without reason)

From the [design spec](superpowers/specs/2026-07-09-flight-deck-design.md) and the two forced calls during the build:

- **macOS-native** (Swift + AppKit/SwiftUI + Metal), same stack as Ghostty's own app.
- **Orchestrate external harnesses** (Claude Code + opencode first) via a per-harness adapter; **interactive** drive mode (harness owns its context window; Flight Deck influences it via MCP tools / prompt injection / bootstrap files / an owned authoritative memory layer).
- **Reuse boundary = adapt-copy.** Ghostty's Swift `SurfaceView` is too coupled to its app shell to reuse by reference (it transitively needs ~82 app files). So its surface + input files are **copied into `Sources/FlightDeck/GhosttyEmbed/` as owned, editable, decoupled files** (~97% verbatim, provenance-marked), linking `GhosttyKit.xcframework`. See the spec's 2026-07-10 addendum.
- **Session = terminal + agent + optional worktree**; repos roll up to projects; layered context.

## The two blockers we hit (and how they're resolved)

Both are documented in **[TOOLING.md](TOOLING.md)**:

1. **Zig 0.15.2's linker is broken on the macOS 26.5 SDK** (upstream [zig#31658](https://codeberg.org/ziglang/zig/issues/31658); fixed only in Zig 0.16.0, which Ghostty rejects). Resolved **self-contained, no `sudo`**: `scripts/build-libghostty.sh` shims `xcrun` to build against the locally-present `MacOSX15.4.sdk`, which Zig 0.15.2 parses correctly. It fails fast with a clear error if that SDK is absent.
2. **Ghostty's `SurfaceView` isn't cleanly separable** → the adapt-copy decision above.

## What to do next

Immediate + phased next steps live in **[FOLLOWUPS.md](FOLLOWUPS.md)**. The short version:

- **DONE (merged to `master`):** the **Multi-Session Foundation** — singleton `GhosttyApp` owned
  by `AppDelegate` (so a deferred `ghostty_surface_free` can never race a freed app), the
  `Session`/`Repo` model, `@MainActor SessionStore` as single source of truth, and the
  repo→session sidebar. Followed by **Session Name Sync** — bidirectional naming with `claude`
  plus session persistence/restore. Both have their plan and spec linked at the top of this file.
- **NOW — the design's phase-1 remainder**, each its own spec→plan→build: the **harness adapter** (Claude Code hooks + `stream-json`, opencode's server/events), the **shared code index** (quillmap is a ready substrate, MCP-exposed), the **context engine** (auto-assembly + memory + inspectable compaction), and the **mission-control sidebar** live-status columns (needs the adapter's event stream). See [design spec §9](superpowers/specs/2026-07-09-flight-deck-design.md).
- **Known limitation:** CI / other-host builds are blocked on the upstream Zig fix (see TOOLING.md / FOLLOWUPS.md).

## How this was built (process record)

Built subagent-driven (a fresh implementer per task + a spec/quality review after each + a whole-branch review). The full task-by-task record — the progress ledger, per-task briefs, and reports — is on disk under `.superpowers/sdd/` (git-ignored). The executed plan is **[the walking-skeleton plan](superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md)**.

## Doc index

See **[docs/README.md](README.md)** for the full index. In short:
- [ARCHITECTURE.md](ARCHITECTURE.md) — as-built code structure & reuse boundary
- [BUILD.md](BUILD.md) — build / run / test / troubleshoot
- [TOOLING.md](TOOLING.md) — toolchain versions + the SDK-shim workaround
- [FOLLOWUPS.md](FOLLOWUPS.md) — known limitations & prioritized next fixes
- [superpowers/specs/2026-07-09-flight-deck-design.md](superpowers/specs/2026-07-09-flight-deck-design.md) — the overall design (why)
- [superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md](superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md) — the executed walking-skeleton plan
- [superpowers/specs/2026-08-08-multi-session-foundation-design.md](superpowers/specs/2026-08-08-multi-session-foundation-design.md) — **next phase** design spec
- [superpowers/plans/2026-08-09-multi-session-foundation.md](superpowers/plans/2026-08-09-multi-session-foundation.md) — **next phase** implementation plan (ready to execute)
