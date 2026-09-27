# Flywheel Intake GUI verification checklist

> Agents cannot drive the real Flight Deck app (AGENTS.md rule 2: no headless host for an
> AppKit/SwiftUI surface). Every piece of the intake pipeline is built on pure, unit-tested
> engine code (`Sources/IntakeKit/`) and an orchestration layer unit-tested against fake
> subprocesses (`Sources/FlightDeck/Intake/IntakeService.swift`) — this checklist is the only
> place their wiring into the live app, real `br`/`bv`/`am`/`codex`/`claude`, and real SwiftUI
> is actually exercised, and it is **Nate's** to run, not an agent's.

## Purpose

Confirm intake capture, headless triage, the release review, `br` release, and delivery to a
bead's holder behave correctly end to end against a real flywheel project — plus the sidebar
mechanics the project-row click depends on, and the collapsed/expanded rollup this plan adds
to the project header.

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
  way — and the detail pane switches to the per-project view (`ProjectView`, currently just a
  header + "Intakes" placeholder until Task 17 lands the real tab).
- With the project selected, check the highlight is visible in **both** light and dark
  appearance (System Settings → Appearance, or the sidebar's own context if themed), and in
  **both** an active and an inactive window (click another app, or another Flight Deck
  window if one is open, then look back at this one). The highlight is hand-drawn now, not
  `List`'s, so both of those are real ways for it to silently vanish that a native selection
  ring wouldn't have.
- Drag a project header up or down past another one. Confirm it still reorders — this is the
  mechanic the whole "no `Button`/gesture/`NSViewRepresentable` in this row" constraint
  exists to protect, per the row's own doc comment.
- With a project selected (detail pane showing `ProjectView`), click a **session** row in the
  sidebar (in this or another project). Confirm the detail pane switches to that session's
  terminal — the project view is left, not stacked or backgrounded.

**Expect:** chevron collapses without selecting; a row click elsewhere selects + opens the
project view, with a highlight visible in every appearance/window-focus combination tried;
drag-to-reorder still works; clicking a session returns to the terminal from the project
view.

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

In the second terminal, run `br update <bead> --assignee <someone> --status in_progress` on a
bead the change set actually edits (pick one from the ops the review just showed you). Reopen
(or refresh) the review.

**Expect:** that op is now flagged as drifted, with the change explained (e.g. "claimed by
`<someone>` since triage — this edit is now an in-progress change"), and **Release is
disabled** until you either confirm it, drop it, or re-triage it.

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
- Resolve the intake (release it, or discard it). Confirm the icon disappears from the header
  in both collapse states once no intake in that project needs attention.

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

## Pass criteria (summary)

- [ ] Step 1 — chevron collapses without selecting; row click selects + opens the project
  view with a highlight visible in light/dark and active/inactive window; drag reorders;
  clicking a session returns to the terminal
- [ ] Step 2 — capture starts triage
- [ ] Step 3 — answering questions re-triages
- [ ] Step 4 — accepting Bead produces a change set, moves to review
- [ ] Step 5 — review shows the change set with no drift
- [ ] Step 6 — a concurrent `br update` is caught as drift; Release disabled until confirmed
- [ ] Step 7 — Release writes the beads and edges `br list`/`br graph` show correctly
- [ ] Step 8 — a scopeChange edit injects the holder's tab and lands in `am inbox`
- [ ] Step 9 — the orange "needs you" icon shows collapsed AND expanded while an intake
  needs attention, and clears once resolved
- [ ] Step 10 — quitting mid-triage leaves the intake interrupted; Retry starts fresh
