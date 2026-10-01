# Flight Control on the phone — hand-off after Phases 1 and 2

**For:** the next session that ships, verifies, or builds Phase 3 of Flight Control on the iOS
companion. **Written:** 2026-09-30, against `master` = `6b084da` (merge of `fc-mobile-steer`).
Read this, then the spec's §11.1 and §11.2, before touching anything. The original terrain map
is `docs/FLIGHT-CONTROL-MOBILE-HANDOFF.md` (its §0.1 is superseded — data now crosses the wire).

---

## 1. Where things stand

| | State | Where |
|---|---|---|
| Spec | Approved 2026-09-29 (Plannotator). §11 phases; §11.1 = 17 Phase-1 as-built decisions; §11.2 = 14 Phase-2 decisions | `docs/superpowers/specs/2026-09-29-flight-control-mobile-design.md` |
| Phase 1 — Watch | **Merged.** Intake rows + "N needs you" badge + in-app banner in Sessions; intake screen (board strip, agents, rounds, round detail, clarifications); plan outline + reader with notes and "changes since previous" | plan `docs/superpowers/plans/2026-09-29-flight-control-mobile-watch.md` |
| Plan text selection | **Merged** (`97c1a0b`, via `447105a`). Prose paragraphs render through `SelectableProseView`; notes open from a per-block button | — |
| Phase 2 — Steer | **Merged** (`6b084da`). Transport keys (Pause · Step · Next major · To review · Stop, confirmed), long-press default play, rounds ±, plan notes (selection "Note…", per-passage menu, plan-wide), delete pending notes (confirmed) | plan `docs/superpowers/plans/2026-09-29-flight-control-mobile-steer.md` |
| Phase 3 — Unblock, start, finish | **Not planned.** | spec §11 item 3 |
| Pushed to origin | **No.** See §4 (fixture). | — |

### What is installed right now (checked 2026-09-30 17:33)

- **Mac** `/Applications/Flight Deck.app`: a Release swapped in at 11:16 today by another session,
  built from the main checkout **before** the Phase 2 merge. Its FleetKit has no `intake.tape` /
  `intake.removeNote` strings → **no Phase 2 on the Mac.**
- **Phone (Mobile3):** last successful install was a Release of `6c62acd` (Phase 1 only). The
  selection fix and Phase 2 were built but **never installed** — the phone was asleep/unplugged
  each time (`xcrun devicectl list devices` showed `unavailable`).

**To ship Phase 2 you need BOTH ends.** The phone shows steering controls only when the intake's
detail has `steer == true`, which only a Phase-2 Mac sends (§2). A phone-only deploy looks exactly
like Phase 1.

1. Mac: build Release from current master and swap — `scripts/swap-release.sh`, run **detached**
   (docs/AGENT-OPERATIONS.md §2). Check the swap log's `new bundle:` path afterwards; other
   sessions swap too (memory `concurrent-swaps-clobber`, `installed-build-may-be-a-stale-worktree`).
2. Phone: plug in + unlock Mobile3, then `./scripts/deploy-phone.sh --release` from a worktree at
   master (after `xcodegen generate`). The script **exits 0 on failure** — require both
   `App installed:` and `Launched application…` in its output.
3. Then the maintainer runs the device checklist, `docs/MOBILE.md` items **75–93**.

---

## 2. How the pieces fit (what Phase 3 builds on)

- **Summaries** (sequenced): `WireProject.intakes` + `FleetEvent.projectIntakes`, sent only to peers
  whose `hello.caps` contains `flightControl`. The Mac keeps a store-side cache
  (`SessionStore.intakeSummaries`) that `FleetProjection` reads, so the drift oracle and the event
  log agree by construction; refreshed on store changes, `SeatFeed.onSettled`, and a 60 s tick.
- **Detail / plan** (request/reply): `intake.detail` (etag; polled 1.5 s while any screen of the
  intake is open, via the shared `.intakePresence` modifier) and `intake.plan` (head is ALWAYS
  requested with `checkpoint: nil`; explicit checkpoints are cached, LRU 4).
- **Commands** (phone → Mac): `intake.tape`, `intake.defaultPlay`, `intake.note`,
  `intake.removeNote`. Each is applied by ONE `IntakeService.phone*` method returning a named
  refusal code (logged `check=<code> intake=<id>`). Token-idempotent: an accepted token acks before
  validation; the phone keeps a timed-out token ≤60 s and on a mid-send drop, so a retry is
  deduplicated.
- **Compatibility gates:** an older Mac drops the socket on an unknown **command** op (only `req`
  is salvaged). Phase 2 is gated on `WireIntakeDetail.steer`. **Phase 3's new commands need their
  own gate** (e.g. a new detail flag or a bump the phone checks) — do not reuse `steer`, or a
  Phase-2 Mac would receive Phase-3 ops and drop the phone's socket.
- **Phone command layer:** `IntakeCommandModel` (per intake, from `FlightControlModel.commands(for:)`)
  gives 100 ms feedback, 10 s deadline, ack → detail refresh, err → words (`CommandCopy`). Reuse it
  for every Phase 3 action.
- **Transport rules:** `TransportRules.make(tape:config:)` is the single rule for the desktop bar,
  the Run menu, the Mac's validation and `WireBoard.controls`.

## 3. Phase 3 scope (spec §11 item 3, §4.5, §4.10, §6.4, §6.5)

Answers (`needsAnswers` form, drafts persisted on the phone), fidelity + Start Planning
(`awaitingChoice`), Retry (`failed`/`interrupted`), Discard (⋯ menu, confirmed), New intake (sheet
from a project header's +, phone-supplied id so it can navigate before the ack), Review + Release
(`intake.review` request + `intakeReviewOp`/`intakeRelease` commands, drift decisions gate the
button, Release confirms). The Phase-1 waiting states currently say "… on your Mac for now" — those
are the placeholders Phase 3 replaces. Process: `superpowers:brainstorming` is already done (the spec
covers it) → `superpowers:writing-plans` → Plannotator → subagent-driven, as Phases 1–2.

## 4. Open items (decide or do before/with Phase 3)

1. **Mac poll cost (measured, unfixed).** 40 s profile with an intake open on the phone: serving the
   phone ≈ 3.8% of the main thread; ≈ 35 ms of main-thread time per 1.5 s detail poll, mostly
   `needsAttention` re-reading and decoding `commands.jsonl` (82 samples) and `ProgressSummary`
   reading checkpoint files (61); an unchanged poll costs the same as a changed one because the etag
   is computed after the full rebuild; a plan fetch cost ≈ 0.6 s. Fixes: compute the etag from cheap
   inputs before rebuilding; cache `needsAttention` per tape change; cache the progress line.
2. **`ProjectViewInspectorLiveTests.testInspectorClosesFromTheEditorAndIsRememberedPerProject`**
   failed deterministically on this Mac on 09-29 evening (line 90, "the panel itself collapsed") —
   including at `73b8ffb`, where the full suite had passed earlier that day — then **passed** in the
   full run on merged master `6b084da` on 09-30 (4272 cases, `SHARDED UNIT RUN PASSED`). So it
   depends on machine/window state, not Flight Control code; worth hardening if it recurs.
3. **The real larkOS plan fixture was removed** (the maintainer: keep it out of the repo); the quote-locator
   and note-anchor tests now read the synthetic `Tests/FlightDeckTests/Fixtures/sample-plan.md`.
   The old file is still in local history (added in `c4efb0b`, never pushed) — purge it from
   history before any `git push`. Never copy a real intake plan into the repo.
4. **Flaky:** `FleetListScreenTests.testRefreshRecentlyClosedKeepsTheListThroughADisconnect`
   (real socket; failed 1 in 4 runs on 09-29).
5. **Parked polish (CAN-WAIT, from the final reviews):** transport row at AX5 (glyphs overlap,
   captions truncate — use a capped dynamic type size + large-content viewer); note-sheet kind chips
   (scroll the selected chip into view, stronger dark-mode selected state); "N notes" badge excludes
   unsent notes; existing vs unsent note cards styled differently; Phase-1 AX5 agent-row truncation;
   "changes" green wash hides a pending note's wash; resync snapshot doesn't re-baseline banner
   state; `known`/`details` never pruned until unpair; `RenderedQuoteLocator` doesn't strip escapes,
   image `!`, list bullets or `)` inside URLs (all fall back to the whole passage, never the wrong
   one); `PlanBlocks.split` treats `\r` lines as non-blank; ± absent until a round exists; outbox
   lives in the reader's `@State` (a failed draft is lost on leaving the screen). Full lists:
   memory `fc-mobile-phase1-ledger.txt` / `fc-mobile-phase2-ledger.txt`.

## 5. Working notes that cost time

- `./scripts/test-unit.sh` runs the whole suite whatever you pass, ~8–10 min, and can exit 0 on
  failure — success is the line `** SHARDED UNIT RUN PASSED`; shard logs in
  `DerivedData/fd-test-shards/`. Touching FleetKit or the phone ⇒ also `./scripts/test-ios.sh`.
- Worktrees: symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts` from the main checkout and run
  `xcodegen generate`; base them on **local** master (origin is behind). Commit by path; check
  `git diff --cached --stat -- vendor` is empty.
- The unit suite can't see a screen. Every view decision lives in a pure type with tests
  (`IntakeStyle`, `BoardStripModel`, `TransportKeys`, `NoteComposer`, …); appearance is checked with
  the offscreen harness `Tests/FlightDeckMobileTests/IntakeRenderHarness.swift` (gate `RENDER_INTAKE`,
  flipped via the project.yml scheme env for one run, then restored) — open the PNGs, a blank image
  is the failure mode. The renders found real defects both phases.
- Measure on the live app before reporting perf (`sample <pid>` on `/Applications/Flight Deck.app`).
- Words: tasks (never beads), Flight Control (never Flywheel), agent (never seat) — enforced for the
  phone by `TerminologyGuardTests`.
