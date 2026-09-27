# Flywheel Intake GUI verification checklist

> Agents cannot drive the real Flight Deck app (AGENTS.md rule 2: no headless host for an
> AppKit/SwiftUI surface). Every piece of the intake pipeline is built on pure, unit-tested
> engine code (`Sources/IntakeKit/`) and an orchestration layer unit-tested against fake
> subprocesses (`Sources/FlightDeck/Intake/IntakeService.swift`) — this checklist is the only
> place their wiring into the live app, real `br`/`bv`/`am`/`codex`/`claude`, and real SwiftUI
> is actually exercised, and it is **the maintainer's** to run, not an agent's.

## Purpose

Confirm intake capture, headless triage, the release review, `br` release, and delivery to a
bead's holder behave correctly end to end against a real flywheel project — plus the sidebar
mechanics the project-row click depends on, and the collapsed/expanded rollup this plan adds
to the project header. "Plan from scratch (Feature plan)" covers the round engine: planning rounds run by
the detached runner and driven from the shaping view.

## Prerequisites

- A **real, non-temp** flywheel project — e.g. `~/fw-functest` — not a `/tmp` scratch repo.
  Spec §12: `br` integration is tested against repos under `$HOME`, "because `am` treats temp
  paths as ephemeral and silently skips enforcement" — a `/tmp` project would let a
  guard/reservation bug pass silently here too.
- That project has flywheel markers (`.beads/`, `.agent-mail.yaml`) and at least one open bead
  a change set could plausibly reference — add the project in Flight Deck, then use the
  project header's context menu ("Setup Flywheel…" if the markers don't exist yet, "Enable
  Flywheel…" if they do) as in `docs/FLYWHEEL-OBSERVE-CHECKLIST.md` step 1.
- A registered agent-mail identity for at least one tab in the project (`am macros
  start-session`), so step 10's inject/mail delivery has a real holder to land on.
- Flight Deck built and run in place (never swap `/Applications` mid-session — see
  `docs/AGENT-OPERATIONS.md`).
- A second terminal outside Flight Deck with `br`, `bv`, and `am` on `PATH`, for steps 8–10.
- Ability to quit and relaunch Flight Deck for step 11 (not `-FlightDeckResetState`, which
  would also wipe the intake you are mid-triage on).

## Steps

### 1. Sidebar mechanics — chevron collapses, row selects, drag still reorders

These are the project-row mechanics the rest of this checklist leans on (`ProjectHeaderRow`
is `.selectionDisabled()` and draws its own selection highlight — see its doc comment for
why `List`'s native highlight is gone). Before touching intakes:

- Click the **chevron** on a project row. Confirm it collapses/expands **without** selecting
  the project — the detail pane stays on whatever was showing (a session's terminal, or
  nothing).
- Click the row **anywhere else** (the name, the blank trailing space). Confirm the project
  becomes selected — the row's text switches from secondary to primary tint and stays that
  way — and the detail pane switches to the per-project view (`ProjectView`: the intake
  composer, the Intakes list and the selected intake's detail).
- With the project selected, check the highlight is visible in **both** light and dark
  appearance (System Settings → Appearance, or the sidebar's own context if themed), and in
  **both** an active and an inactive window (click another app, or another Flight Deck
  window if one is open, then look back at this one). The highlight is hand-drawn now, not
  `List`'s, so both of those are real ways for it to silently vanish that a native selection
  ring wouldn't have.
- Compare it with a selected session row: same pill height, side inset, corner and text size.
  It is **gray** while the terminal has focus and turns **accent** only once the sidebar holds
  focus (click the selected row again) in the key window — exactly when a selected session row
  does. A blue header beside a gray session highlight in the same window state is the bug.
- Drag a project header up or down past another one. Confirm it still reorders — this is the
  mechanic the whole "no `Button`/gesture/`NSViewRepresentable` in this row" constraint
  exists to protect, per the row's own doc comment.
- With a project selected (detail pane showing `ProjectView`), click a **session** row in the
  sidebar (in this or another project). Confirm the detail pane switches to that session's
  terminal — the project view is left, not stacked or backgrounded.
- Select a project again, then press **⌘W**. Confirm the project view closes and the detail
  pane returns to the session that was selected before — that session is **not** closed, and
  its tab is still in the sidebar. With the project view up, **⌘R** and **Return** (sidebar
  focused) do nothing — no rename field opens on the hidden session's row.
- Select a project, then close that project (its header's context menu). Confirm the detail
  pane falls back to a terminal and that terminal does not pick up an unread dot while you are
  looking at it.

**Expect:** chevron collapses without selecting; a row click elsewhere selects + opens the
project view, with a highlight visible in every appearance/window-focus combination tried;
drag-to-reorder still works; clicking a session returns to the terminal from the project
view; ⌘W closes the project view, never the hidden session, and ⌘R/Return don't rename it.

### 2. Capture an intent

In `~/fw-functest` (or your chosen real project), open its `ProjectView` and type an intent
into the intake composer — something specific enough to produce a real change set, e.g. "Add
a `--dry-run` flag to the release script that prints what it would do without writing
anything."

**Expect:** the intake appears in the Intakes list in state *triaging*, then either moves to
*needs answers* or straight to a recommendation once the headless triage turn returns.

### 3. Answer the triage questions

If triage came back with clarifying questions, answer them in the composer it presents.

**Expect:** the intake re-triages with your answers folded in as a follow-up turn in the same
harness session, and lands on either more questions or a recommendation.

### 4. Accept Bead

Accept the **Bead** preset when the recommendation appears (Sketch and above are next-plan
scope — see `docs/FOLLOWUPS.md`).

**Expect:** the intake moves to *review*, with a change set attached.

### 5. Open the review

Open the release review from the intake's detail state.

**Expect:** the review sheet shows the proposed ops (creates/edits/edges) against the current
graph, with no drift flagged yet, and a **Release** button.

### 6. Force drift, confirm it's caught

With the review from step 5 still open (and showing no drift), run `br update <bead> --assignee
<someone> --status in_progress` in the second terminal on a bead the change set actually edits
(pick one from the ops the review just showed you). Then press **Release** on the now-stale
sheet, without reopening it.

**Expect:** nothing is written. The sheet stays open with the refusal in orange at the top
("Drift changed since review; confirm or drop the drifted ops again."), and the intake's detail
pane shows the same line above "Open release review". The sheet reloads its review as it
refuses, so it now shows the drift too:

**Expect:** that op is flagged as drifted, with the change explained (the text reads
"`<bead>` was open at triage and is in_progress by `<someone>` now"), and **Release is
disabled** until you either confirm it or drop it (re-triaging a drifted op is not built — see
`docs/FOLLOWUPS.md`). Because the bead is in progress *now*, the edit's row also shows
**Holder: `<someone>`** — the live holder, not whoever held it at triage — with a rating picker
(defaulting to Scope change) and the delivery release will make.

### 7. Release

Confirm the drifted op (or drop it), then Release.

**Expect:** `br list` shows the new/edited beads with the right fields; `br graph` shows the
edges the change set specified, correctly directed (held existing→new edges included, since
they only ever get written at release).

### 8. scopeChange delivery reaches the holder

Repeat capture→review with a change set that edits a bead currently `in_progress` under a
real agent-mail identity with a live Flight Deck tab (a `scopeChange`-rated edit is the
default rating for such an edit — no need to force it). Release.

**Expect:** the holder's tab receives an injected notice of the change (queued if the agent
was mid-turn), and `am inbox` for that identity shows the same notice as mail.

### 9. Rollup badge — collapsed and expanded

Capture an intent in a **second** project (or leave the one from step 2 sitting at *needs
answers*/*review* without resolving it) so at least one intake is in a state
`IntakeState.needsAttention` covers (`needsAnswers`, `awaitingChoice`, `review`,
`partiallyReleased`, `failed`, `interrupted`).

- **Collapse** that project's header. Confirm the trailing icon is the orange
  `questionmark.circle.fill` and its tooltip (hover) reads "Waiting for you — N intake(s)
  need you" — the same icon a session's own permission-prompt wait uses, folded in by
  `SessionStore.collapsedStatus`.
- **Expand** it. Confirm the same orange icon still shows in the header (drawn directly by
  `ProjectHeaderRow` this time, since there is no per-project status row to fold it into once
  every session row is visible on its own), with tooltip "N intake(s) need you".
- Resolve the intake (release it, or Discard it — every state but *releasing* has a Discard
  button in the detail pane). Confirm the icon disappears from the header in both collapse
  states once no intake in that project needs attention, **without** clicking anything else in
  the sidebar first — the header must update on its own.
- If you have a *partial* intake (a release that stopped partway), its detail pane has a
  **Dismiss** button; confirm dismissing it clears the icon too.

**Expect:** the orange "needs you" icon appears in both the collapsed and expanded header
exactly while an intake needs attention, and clears once none do.

### 10. Quit mid-triage; Retry works

Capture a new intent and, while it is still in state *triaging* (before the headless turn
returns — you likely only have a few seconds; a long/complex intent buys more time), quit
Flight Deck. Relaunch it.

**Expect:** the intake is now *interrupted* ("Flight Deck quit while triage was running."),
and its **Retry** action starts a fresh triage turn from the unchanged intent text (the
earlier partial turn, and any exchanges already answered, are intentionally discarded — see
`docs/FOLLOWUPS.md`'s note on Retry).

## Plan from scratch (Feature plan)

The round engine: a fidelity above Bead, run in the detached `flightdeck intake run` runner and
driven from the shaping view's transport bar. `RoundsLiveProbeTests` proved the engine reaches
review against real models in-process (Sketch, codex `gpt-5.6-luna`/`low`); nothing but this
section exercises the app spawning the runner under fd-abduco with the isolation flags on its
claude and codex seats, the tape watcher, the transport buttons, or a runner dying mid-round.
Use the same real, non-temp project as above. Each round is a real model turn at the preset's
default models — budget minutes per round, and real tokens.

1. **Type an intent, choose Feature plan, and look at the Rounds editor.** Once triage
   recommends, pick **Feature plan** and open the **Rounds** disclosure.
   **Expect:** one row per seat — two drafters (arbiter, realist), synthesizer, reviewer,
   integrator, encoder, polisher — each with harness, model, effort (`low`…`max`, **no**
   `ultra`) and fallback, the Fallback pickers left-aligned in their column; refinement cap 3,
   polish cap 2, fresh-eyes + dedup off, default play ⏭. Changing any field relabels it
   "Feature plan, customized". Put it back, or leave it. (Choose **Sketch** for a moment and
   check the polish cap and fresh-eyes toggle are greyed out, with a tooltip saying Sketch has
   no polisher; then back to Feature plan.)
2. **Start. It stops after draft; ⏭ again runs synthesis.**
   **Expect:** the intake goes to *shaping* and the shaping view appears (tape strip, transport
   bar, status line). The playhead runs draft and the tape pauses there — draft is a major
   checkpoint, so the default ⏭ stops on it. The draft card shows both drafters (or a
   *substituted*/*failed* badge with its diagnosis on hover). Press ⏭ again: synthesis runs and
   the tape pauses after it, with its change count and verdict tally on the card.
3. **Read the plan.** Click the synthesis card; the plan viewer shows its `plan.md`. Switch to
   **Diff vs previous**.
   **Expect:** monospaced, scrollable, selectable text; the diff is against drafter 0's draft.
4. **✎ annotate, then ⏯ one refine round, and check that the annotation shaped it.** Annotate
   with something specific and checkable ("the plan must not add any new dependency"), then ⏯.
   **Expect:** exactly one refine round runs and the tape pauses again. Its card records your
   annotation, and its diff shows the plan moved toward it.
5. **⏩ to review.**
   **Expect:** the remaining refine rounds, encode, and both polish rounds run without stopping;
   the intake moves to *review* on its own, with the final change set in the release review.
6. **`kill -9` the runner mid-round.** During step 5, while the status line says a round is
   running, find the runner with `pgrep -f 'flightdeck intake run'` and `kill -9` it.
   **Expect:** within ~30 s the app respawns a runner (`pgrep` shows a new pid, and only one),
   the interrupted round's orphaned `codex`/`claude` children are killed, and the round reruns
   from scratch — its card notes "rerun after interruption".
7. **Quit Flight Deck mid-round and relaunch.** Also during step 5 (or a fresh intake's
   rounds): quit while a round is running, wait ~30 s, relaunch.
   **Expect:** the runner kept going or was respawned, and the round completed. `ps -ef | rg
   'intake run'` shows **one** runner for the intake, never two. If it was respawned, the
   rerun round's card notes "rerun after interruption".
8. **⏹ mid-round. Nothing is checkpointed.** On a fresh intake (or before step 5 finishes),
   press ⏹ while a round runs.
   **Expect:** the tape stops at the last checkpoint with no card for the cancelled round, and
   no `codex`/`claude` child of that round is left running (`ps -ef | rg 'codex exec|claude -p'`).
9. **No MCP side effects in the work dir.** Once step 5 reaches review, search the intake's
   directory, `work/` included: `find "$HOME/Library/Application Support/Flight Deck/intakes/<id>"
   -name .quillmap` (under `$FLIGHT_DECK_STATE_DIR/intakes/<id>` if that is set).
   **Expect:** nothing. A `.quillmap/` there means a seat started the user's MCP servers — the
   isolation flags (`--ignore-user-config` for codex, `--restricted --strict-mcp-config` for
   claude) did not hold.
10. **Release review, then release.** From step 5's intake, open the release review and Release,
    as in steps 5–7 above.
    **Expect:** the same release behaviour as a Bead intake: `br list`/`br graph` show exactly
    the change set's beads and edges, and nothing was written to `br` before Release (check
    `br list` for the intake's beads *before* step 10 — there must be none).

### Full plan variant

Repeat steps 1–2 and 5 with **Full plan** on a fresh intake. It is the most expensive run here
(four drafters, five refine rounds, six polish rounds) — run it once, not per change.

**Expect:** the Rounds editor shows four drafters (arbiter, realist, coverage, stressTest)
alternating codex and claude, polish cap 6 and fresh eyes + dedup **on**. ⏩ runs draft,
synthesis, refine, encode, polish, then fresh eyes and dedup before review; the draft card
lists all four drafters, and mixed codex/claude seats all complete (or substitute with a
diagnosis) — no seat pauses on authentication or a missing proxy. Step 9's `.quillmap/` check
holds here too.

## Pass criteria (summary)

- [ ] Step 1 — chevron collapses without selecting; row click selects + opens the project
  view with a highlight visible in light/dark and active/inactive window; drag reorders;
  clicking a session returns to the terminal; ⌘W closes the project view, not the hidden
  session; ⌘R/Return don't rename it
- [ ] Step 2 — capture starts triage
- [ ] Step 3 — answering questions re-triages
- [ ] Step 4 — accepting Bead produces a change set, moves to review
- [ ] Step 5 — review shows the change set with no drift
- [ ] Step 6 — a concurrent `br update` is caught as drift, with the live holder and a rating
  picker; Release disabled until confirmed or dropped; a refused Release keeps the sheet open
  with its reason
- [ ] Step 7 — Release writes the beads and edges `br list`/`br graph` show correctly
- [ ] Step 8 — a scopeChange edit injects the holder's tab and lands in `am inbox`
- [ ] Step 9 — the orange "needs you" icon shows collapsed AND expanded while an intake
  needs attention, and clears on its own once resolved (Discard, or Dismiss for a partial)
- [ ] Step 10 — quitting mid-triage leaves the intake interrupted; Retry starts fresh
- [ ] Plan from scratch (Feature plan) — the Rounds editor shows every Feature plan seat and
  relabels on edit (Sketch greys out polish/fresh eyes); Start pauses after draft and ⏭ after
  synthesis; the plan and its diff read correctly; an annotation shapes the next refine round;
  ⏩ lands in review; a `kill -9`'d runner is respawned within ~30 s and the round reruns with
  "rerun after interruption"; a quit mid-round completes the round with one runner; ⏹
  checkpoints nothing and leaves no child running; no `.quillmap/` under the intake; release
  writes the change set and nothing reached `br` before it
- [ ] Full plan variant — four mixed codex/claude drafters, polish, fresh eyes + dedup all run
  to review
