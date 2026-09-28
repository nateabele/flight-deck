# Planning UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the intake detail pane per the approved design. It becomes one calm document (Direction D) with:
- a Logic-style control bar and LCD;
- an M2 departures-board timeline that uses measured full names and split-flap codes;
- live seat activity;
- a live-preview Markdown plan with your edits as a layer and anchored notes;
- convergence shown as an LCD sparkline, a churn gutter and an inline heatmap;
- "tasks" everywhere instead of "beads".

**Architecture:** The engine already exists on this branch: `SeatActivity`/`activity.json`, `PlanLayers`/`PlanNote`/`editPlan`, and `ConvergenceSeries`. This plan is app-side only.
- **Pure view models first.** Board, LCD, label fit, flap policy, seat rows and convergence cell each live in the app target with no SwiftUI, and each is unit-tested.
- **Thin SwiftUI/AppKit views on top.** The detail pane is then recomposed from those views.
- **The plan editor is a TextKit 2 `NSTextView` wrapper.** Styling is applied as attributes over plain Markdown source, so the stored text never changes shape.

**Tech Stack:** Swift 5 app target (SwiftUI + AppKit, macOS 14), IntakeKit (Swift 6), XCTest via `scripts/test-unit.sh` (sharded; `FD_TEST_FILTER=Class1,Class2` for inner loops), xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-27-planning-ui-redesign-design.md` (approved 2026-09-27). Visual reference: `.superpowers/brainstorm/57736-1790549157/content/convergence-combo.html` (the combined design) and `mashup.html` (M2). Research: `/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/9bf1e259-cc02-4f83-884e-27183594e064/scratchpad/planning-ui-research.md`.

## Global Constraints

- **"Tasks", never "beads", in any user-visible string.** This covers labels, buttons, status lines, in-app error text, empty states, the Enable Flywheel copy, Observe lanes and the release review.
  - Internals keep the word: `br`, `.beads/`, `BeadWriter`, schemas, agent prompts, logs, accessibility *identifiers*.
  - The `.bead` preset is displayed as **Single task**.
- **HIG placement.**
  - The primary action sits at the trailing edge and is the default button.
  - A destructive action is never the default and is always confirmed.
  - Nothing critical lives only at a window's bottom.
  - Use panels, not sheets, for repeated input.
  - No labelled spinners.
  - Durations count up; never show an ETA.
- **Colour only for exceptions.** Accent means live or selected, amber means attention or fallback, red means failure.
- **Honest data only.** No invented percentage, ETA or live cost. A determinate fraction appears only for seats done/total, the agent's own steps, or round N of M.
- **Reduce Motion is respected by every animation.** Clocks tick at 1 Hz from a local timer. 1 Hz timers suspend while the window is occluded (the existing occlusion gating pattern).
- **Label fit is measured, never a hard-coded breakpoint.** Full proper name if it fits, else the code.
- **The split-flap animation plays once, when a given text first appears.** It never replays on re-render, scroll, resize, re-hover or an unchanged value.
- **App target stays `SWIFT_VERSION: "5.0"`; IntakeKit stays Swift 6.** No new IntakeKit public API unless a task says so.
- **New ⌘-chords must be checked against Ghostty's performable keybinds before they're claimed.** Ghostty silently eats a menu chord it binds (memory `ghostty-claims-menu-shortcuts`). If a chord collides, pick another and record it.
- **Worktree hazards:**
  - Never launch a bundle from `DerivedData/`. Never run `smoke.sh`.
  - Never `git add -A`, never `git stash`. Stage explicit paths.
  - Before every commit, `git diff --cached --stat -- vendor` must be empty.
  - Search with `rg`.
  - Tests run in the foreground.
- **Commits:** lowercase behavioral subject; the body gives mechanism and evidence; the trailer names the model that wrote it.

## Review Focus

1. **A long run: 20+ rounds after extends, in a narrow (~600 pt) pane.** Board labels fall back to codes, nothing overlaps, the tape scrolls horizontally with the live slot kept in view, and the LCD drops cells in the specified order. *Pinned in Task 2 (`testNarrowTapeFallsBackToCodesWithoutOverlap`) and Task 6 (`testCellsDropInOrderAsWidthShrinks`).*
2. **Activity data that is missing, stale or out of order.** No `activity.json` yet, a seat whose `run.json` shows an exit while its activity says unfinished, a clock skew between file writes, a headline that never arrives. Expected: a queued row, then finished once `run.json` shows an exit, no negative elapsed time, and the action line standing in for a missing headline. *Pinned in Task 4.*
3. **Typing in the plan while a round lands.** No keystroke is lost. The editor never replaces text under an active edit. A new head arriving mid-edit shows a banner, "A new round landed · Show it", instead of swapping content. *Pinned in Task 10 (`testIncomingHeadDoesNotReplaceTextWhileEditing`).*
4. **A note whose anchor can no longer be found after edits.** It shows as detached at the top of the rail with its quote. It's never silently dropped, and it never attaches to the wrong text. *Pinned in Task 12 (`testUnlocatableNoteIsDetachedNotDropped`).*
5. **A convergence series across a reviewer-model change or an extend.** The verdict word still renders. The card states the model change, and the sparkline marks the discontinuity. It never shows a misleading CONVERGING across a model swap without saying so. *Pinned in Task 13 (`testModelChangeIsCalledOutOnTheCard`).*

---

## File Structure

New files, all under `Sources/FlightDeck/Intake/`. Each has one responsibility.

| File | Responsibility |
|---|---|
| `Planning/BoardModel.swift` | Pure. Tape slots (name, code, duration, major, state, flag), board fields (NOW / IN THE AIR / STOPS AT / CALLING AT), stop target for a play mode. |
| `Planning/LabelFit.swift` | Pure. Chooses the full name or code for a slot width given a measure closure; also the LCD cell drop order. |
| `Planning/FlapPolicy.swift` | Pure. Records which texts a flap surface has already shown and decides whether a new text flaps. |
| `Planning/LCDModel.swift` | Pure. The LCD cells and their state colouring, derived from `Tape` + config + convergence. |
| `Planning/SeatRowModel.swift` | Pure. Seat row text and exceptions from `SeatActivity` + `RunRecord` + clock, plus a dwell scheduler for the headline and action line. |
| `Planning/ConvergenceCellModel.swift` | Pure. Sparkline points, state word, card text and heatmap grid from `ConvergenceCycle`s. |
| `Planning/ProgressSummary.swift` | Pure. The header's "✓ Triage 3:40 · …" line. |
| `Planning/SplitFlapText.swift` | View. Measured label plus the flap animation, driven by `FlapPolicy`. |
| `Planning/ControlBar.swift` | View. Transport clusters, LCD, round tools, hover preview. |
| `Planning/DeparturesBoard.swift` | View. Board fields, tape, hover and flap card, selection. |
| `Planning/SeatRow.swift` + `Planning/LiveCard.swift` | Views. Seat rows, finished-round result cards, the triage and shaping live cards. |
| `Planning/ConvergenceViews.swift` | Views. The LCD convergence cell, the churn gutter lane and the heatmap disclosure. |
| `Planning/PlanEditor/MarkdownStyler.swift` | Pure-ish (AppKit attributes, no view). Block parse, attribute styling, caret-block syntax reveal. |
| `Planning/PlanEditor/PlanTextView.swift` | NSViewRepresentable. TextKit 2 `NSTextView` host, edit debounce, incoming-head policy. |
| `Planning/PlanEditor/EditLayer.swift` | Pure → attributes. Renders `PlanLayers.userDiff` hunks and gutter lanes. |
| `Planning/PlanEditor/NotesRail.swift` + `SelectionToolbar.swift` | Views. Notes rail, note cards, floating toolbar. |
| `Planning/PlanningCommands.swift` | The Run menu (`CommandMenu`) and focused-value plumbing. |

Modified: `IntakeDetailView.swift` (recomposed), `ShapingView.swift` (replaced by `LiveCard`; its pure bits move into models), `ShapingModel.swift` (kept for the tape and round-card logic that is reused, trimmed), `IntakeService.swift` (publishes seat activities and convergence), `RoundConfigEditor.swift` (inspector host plus a summary line), `ReleaseReviewView.swift`, `IntakeStatePill.swift`, `ProjectView.swift`, `Flywheel/Observe/*` (terminology), `FlightDeckApp.swift` (commands). Tests go in `Tests/FlightDeckTests/Intake/Planning/`.

Remove `TapeStrip.swift` once `DeparturesBoard` replaces it (Task 9).

---

## Task 1: "Tasks, never beads" pass and guard test

**Files:**
- Create: `Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift`
- Modify:
  - `ProjectView.swift:91`
  - `ReleaseReviewView.swift` ("New beads", row labels, the button title)
  - `RoundConfigEditor.swift:262` (`.bead` → "Single task")
  - `IntakeDetailView.swift` (preset labels)
  - `ShapingModel.swift:308` ("New bead new:…")
  - `IntakeService.swift` user-facing failure strings (`:165`, `:612`, `:799`, `:865`)
  - `Flywheel/Observe/ObserveDrawer.swift` (lane title "beads", "no assigned bead")
  - `Flywheel/FlywheelEnablePrompt.swift` / `FlywheelSetup.swift` (step strings shown in the UI: "beads sync hook", "beads workspace")

**Interfaces:** Produces `enum UIText` (in `Planning/UIText.swift`), which centralizes the renamed strings the later tasks use:
```swift
enum UIText {
    static func presetName(_ p: Preset) -> String   // .bead → "Single task", .sketch → "Sketch", .featurePlan → "Feature plan", .fullPlan → "Full plan"
    static func releaseButton(_ n: Int) -> String   // "Release 1 Task" / "Release 14 Tasks"
    static let newTasksSection = "New tasks"
}
```

- [ ] **Step 1: Write the failing guard test.** It scans every string literal in `Sources/FlightDeck/**/*.swift`. Skip:
  - lines that are comments;
  - lines containing `Logger`, `logger.`, `accessibilityIdentifier(`, `argv`, `args`, `"br"`, `".beads"`, `beads.db`, or a path component;
  - literals that are only a command token.

  Fail on any remaining literal matching `\bbeads?\b` (case-insensitive), and list them. Keep an explicit allow list for true internals. Its first entries are the `SessionStore.swift` `.beads` path literals and `IntakeDelivery` argv/thread-id literals, each with a comment giving the reason.
```swift
final class TerminologyGuardTests: XCTestCase {
    func testNoUserVisibleStringSaysBead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // …/Tests/FlightDeckTests/Intake/Planning
            .appendingPathComponent("../../../../Sources/FlightDeck").standardized
        let offenders = try TerminologyScan.offenders(under: root, allow: TerminologyScan.internalAllowList)
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }
    func testUIText() {
        XCTAssertEqual(UIText.presetName(.bead), "Single task")
        XCTAssertEqual(UIText.releaseButton(1), "Release 1 Task")
        XCTAssertEqual(UIText.releaseButton(14), "Release 14 Tasks")
    }
}
```
  Put `TerminologyScan` in the test file itself. It reads each file, walks lines, and extracts `"…"` literals, ignoring escaped quotes and multi-line `"""` blocks (scan those too).
- [ ] **Step 2: Run it and confirm it fails.** Run `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh`. Expected: FAIL, listing the current offenders.
- [ ] **Step 3: Implement.** Add `UIText` and rename every offender. Some strings are internal (argv, path, thread-id). For those, add them to the allow list with a reason instead of renaming. Two strings go to users and must say "task":
  - `IntakeService`'s "some beads may already be written — check `br list`" becomes "some tasks may already be written — check `br list`";
  - "Could not read the bead graph" becomes "Could not read the task graph".
- [ ] **Step 4: Run the suite and confirm it passes.** Run the full `./scripts/test-unit.sh` once.
- [ ] **Step 5: Commit.** `fix: call them tasks everywhere the user can see, and guard it`

## Task 2: Board model

**Files:**
- Create: `Planning/BoardModel.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/BoardModelTests.swift`

**Interfaces:**
- Consumes:
  - `Tape` and `Checkpoint` (`IntakeKit/Tape.swift`);
  - `TapePlanner.next(after:config:)` / `satisfies`;
  - `RoundConfig`;
  - `Intake.exchanges`, which gives the Clarify slots: one per answered exchange, with durations from exchange timestamps when present, otherwise none.
- Produces:
```swift
enum PlayMode: Hashable { case step, nextMajor, toReview }
struct TapeSlot: Identifiable, Equatable {
    enum State: Equatable { case done, live, future, failed, selected }
    let id: String                 // "clarify-1", "draft-0", "refine-2", …
    let name: String               // "Clarify 1", "Draft", "Synthesis", "Refine 2", "Encode", "Polish 1", "Fresh eyes", "Dedup", "Review"
    let code: String               // "CLR1", "DRFT", "SYN", "RF2", "ENC", "PL1", "FRSH", "DDUP", "REV"
    var state: State
    var duration: TimeInterval?    // finished rounds: checkpoint.createdAt − previous; live: now − round start
    let major: Bool
    var flagged: Bool              // round consumed notes, or has an unanchored note pending
    let checkpointID: Int?
    let group: String?             // "REFINE", "POLISH", "CLARIFY" for bracketed cycles
}
struct BoardField: Equatable { let label: String; let shortLabel: String; let value: String; let detail: String? }
struct BoardModel: Equatable {
    init(intake: Intake, tape: Tape, config: RoundConfig, now: Date, selected: Int?, preview: PlayMode?)
    var slots: [TapeSlot]
    var groups: [(name: String, range: ClosedRange<Int>, extendable: Stage?)]
    var now: BoardField; var inTheAir: BoardField; var stopsAt: BoardField; var callingAt: BoardField
    func stopTarget(for mode: PlayMode) -> String?   // slot id where that mode would stop, nil at review
}
```
- The code table is fixed: CLR{n}, DRFT, SYN, RF{n}, ENC, PL{n}, FRSH, DDUP, REV.
- `stopsAt.label` becomes "WOULD STOP" when `preview != nil`.
- `inTheAir.label` is "PAUSED FOR" when the tape is paused or idle.

- [ ] **Step 1: Write the failing tests.**
  - `testFullPlanSlotsAndCodes`: a fullPlan config and an empty tape give slots CLR…REV in order, with the codes above and majors at Draft, Synthesis, last Refine, Encode, last Polish, Dedup and Review.
  - `testLiveSlotAndDurations`: a tape running refine 2 with checkpoints gives the finished durations, the live slot's elapsed time since `roundInProgress` began, and later slots in the future state.
  - `testFailedRoundIsRed`
  - `testStopTargetPerMode`: paused after Refine 1 gives step → RF2, nextMajor → RF3, toReview → REV.
  - `testCallingAtListsRemainingMajors`
  - `testExtendMovesMajor`
  - `testSelectedCheckpoint`
  - `testNarrowTapeFallsBackToCodesWithoutOverlap`: combine with `LabelFit` over 22 slots at 600 pt. Every label is the code, the sum of slot widths ≤ available width + scroll, and no two label frames intersect.
- [ ] **Step 2: Run them and confirm they fail.** Run `FD_TEST_FILTER=BoardModelTests`.
- [ ] **Step 3: Implement it from `TapePlanner`'s sequence.** Reuse `ShapingModel`'s stage replay (`stages`), moving it into `BoardModel` rather than duplicating it. `ShapingModel` then calls `BoardModel`.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: model the departures board and its tape`

## Task 3: Label fit, the flap policy and `SplitFlapText`

**Files:**
- Create: `Planning/LabelFit.swift`, `Planning/FlapPolicy.swift`, `Planning/SplitFlapText.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/LabelFitTests.swift`, `FlapPolicyTests.swift`

**Interfaces:**
```swift
enum LabelFit {
    /// Full name when `measure(full) + padding <= width`, else code.
    static func choose(full: String, code: String, width: CGFloat, padding: CGFloat = 8, measure: (String) -> CGFloat) -> String
    static func measureWith(_ font: NSFont) -> (String) -> CGFloat   // NSAttributedString size
}
@MainActor final class FlapPolicy: ObservableObject {
    /// True the first time `text` is shown on `surface` (a stable key like "board.now" or "card.refine-2");
    /// false forever after for that pair, even across view re-creation (policy lives on IntakeService, keyed by intake).
    func shouldFlap(surface: String, text: String, reduceMotion: Bool) -> Bool
}
struct SplitFlapText: View {
    init(full: String, code: String, surface: String, policy: FlapPolicy, font: Font, nsFont: NSFont)
    // GeometryReader measures available width → LabelFit.choose; if it chose `code`, shows a dotted underline,
    // is focusable, and presents the flap card on hover/focus. Flap animation: per-character vertical flip,
    // 35 ms stagger, only when policy.shouldFlap(...) returned true for this (surface, text).
}
```
The policy's memory is per intake and per surface. It lives on `IntakeService` (`flapPolicies: [UUID: FlapPolicy]`) so that list-selection changes, which recreate views, don't replay the animation.

- [ ] **Step 1: Write the failing tests.**
  - Label fit:
    - `testChoosesFullWhenItFits`
    - `testChoosesCodeWhenTooNarrow`
    - `testPaddingCounts`
    - `testMeasureWithRealFont`: "Synthesis" in `.monospacedSystemFont(ofSize: 13, weight: .semibold)` measures > 60 and < 100.
  - Flap policy:
    - `testFirstAppearanceFlaps`
    - `testSameTextNeverFlapsAgain`, which includes a new policy lookup through the service for the same intake;
    - `testNewTextFlaps`, e.g. NOW changing Refine 2 → Refine 3;
    - `testReduceMotionNeverFlaps`
    - `testHoverCardFlapsOnceThenNot`: surface "card.refine-2", shown twice, flaps only the first time.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** For `SplitFlapText`, read `@Environment(\.accessibilityReduceMotion)`. Its accessibility label is always `full`.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: fit labels to their space and flap each new text exactly once`

## Task 4: Seat row model

**Files:**
- Create: `Planning/SeatRowModel.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/SeatRowModelTests.swift`

**Interfaces:**
- Consumes:
  - `SeatActivity`, `ActivityAction`, `ActivitySteps` (`IntakeKit/SeatActivity.swift`);
  - `RunRecord` (`IntakeKit/RoundExecutor.swift:33`);
  - `Slot` / `ModelChoice` / `DrafterPersona`;
  - `SlotOutcome` (finished).
- Produces:
```swift
struct SeatRowModel: Equatable, Identifiable {
    enum Glyph: Equatable { case queued, running, done, failed, fallback, needsYou }
    enum Exception: Equatable { case quiet(TimeInterval), stalled(TimeInterval, last: String?), rateLimited(TimeInterval), fallback(String), failed(String) }
    let id: String                     // run dir name
    var glyph: Glyph
    var role: String                   // "arbiter" / "reviewer" / "triage"
    var identity: String               // "codex · gpt-6-sol · high" or "claude → codex · gpt-6-sol"
    var headline: String?              // falls back to action text when nil
    var action: String?                // "Reading Board.swift" — object middle-truncated to 40
    var footprint: [(dir: String, count: Int)]   // sorted desc, max 4 + "+N"
    var steps: String?                 // "Step 3 of 7 · Rewrite the §4 ranking rule"
    var contextFraction: Double?       // inputTokens / window (window: codex 400k, claude opus 1M, haiku 200k — table in file)
    var elapsed: TimeInterval
    var exception: Exception?
    var result: String?                // set when finished: "14 changes across §2 §4 §7" etc.
    var cost: Double?                  // only when costUSD != nil
    static func make(run: String, slot: SlotOutcome?, requested: Slot?, activity: SeatActivity?, record: RunRecord?, now: Date,
                     thresholds: SeatThresholds = .default) -> SeatRowModel
}
struct SeatThresholds: Equatable { var quiet: TimeInterval = 30; var stalled: TimeInterval = 90; static let `default` = SeatThresholds() }
/// Enforces headline ≥3 s and action ≥1.5 s dwell; coalesces newer values into the latest.
@MainActor final class DwellScheduler: ObservableObject {
    init(clock: @escaping () -> Date = Date.init)
    func offer(headline: String?, action: String?) -> (headline: String?, action: String?)   // what to display now
}
```
A finished seat's result string comes from the checkpoint record: the reviewer and synthesizer use `changeCount` + `sectionsChanged`, the integrator uses its tally, and polish uses "N task changes". It never says "bead".

- [ ] **Step 1: Write the failing tests.**
  - `testQueuedBeforeAnyActivity`
  - `testRunningHeadlineAndAction`
  - `testMissingHeadlineUsesAction`
  - `testFinishedWhenRunJSONExitedEvenIfActivityUnfinished` (Review Focus 2)
  - `testQuietAndStalledThresholdsWithInjectedClock`
  - `testRateLimited`
  - `testFallbackIdentityAndReason`
  - `testFailedReason`
  - `testNoNegativeElapsedOnClockSkew` (Review Focus 2)
  - `testFootprintTopFourPlusMore`
  - `testCostOnlyWhenReported`
  - `testResultStrings`
  - `testDwellHoldsHeadline3sAndAction1_5s`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: turn each seat's live activity into an honest status row`

## Task 5: IntakeService publishes seat activity and convergence; no dead moments

**Files:**
- Modify: `IntakeService.swift`
- Test: `Tests/FlightDeckTests/Intake/IntakeServiceLiveTests.swift`

**Interfaces:**
- Consumes:
  - `TapeStore.activities(forRound:)`;
  - `ConvergenceSeries.cycles(_:loadFile:)`;
  - the existing mtime-gated `pollTapes()` tick;
  - `triageActivities`.
- Produces, on `IntakeService`:
```swift
@Published private(set) var seatActivities: [UUID: [String: SeatActivity]]   // round in progress, keyed by run dir
@Published private(set) var runRecords: [UUID: [String: RunRecord]]
@Published private(set) var convergence: [UUID: [ConvergenceCycle]]
@Published private(set) var pending: [UUID: PendingStart]      // optimistic "starting" state
struct PendingStart: Equatable { let kind: Kind; let since: Date; enum Kind { case triage, round(PlannedRound?) } }
func flapPolicy(for id: UUID) -> FlapPolicy
```
- **`pending`** is set synchronously, within the same main-actor turn, by `answer`, `beginShaping` and `send` (play commands only). It clears when the first `activity.json`/tape heartbeat for that work appears, or after 15 s with no activity it becomes a quiet queued row. This gives the "no dead moments" feedback in under 100 ms.
- **`activity.json`** is read only while `roundInProgress != nil`, mtime-gated per file.
- **`convergence`** is recomputed only when the checkpoint count changes.

- [ ] **Step 1: Write the failing tests** (temp root, fake controller, injected clock):
  - `testSendAnswersSetsPendingSynchronously`
  - `testPendingClearsOnFirstActivity`
  - `testSeatActivitiesLoadForRoundInProgressOnly`
  - `testActivityReloadIsMtimeGated` (count reads)
  - `testConvergenceRecomputesOnNewCheckpointOnly`
  - `testFlapPolicyIsStablePerIntake`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement it inside the existing tick.** Don't add a second timer.
- [ ] **Step 4: Run them and confirm they pass.** Then run the full suite once.
- [ ] **Step 5: Commit.** `feat: publish live seat activity and convergence, and acknowledge every start at once`

## Task 6: LCD model and control bar

**Files:**
- Create: `Planning/LCDModel.swift`, `Planning/ControlBar.swift`, `Planning/PlanningCommands.swift`
- Modify: `FlightDeckApp.swift` (add `PlanningCommands()`)
- Test: `Tests/FlightDeckTests/Intake/Planning/LCDModelTests.swift`

**Interfaces:**
```swift
struct LCDCell: Equatable, Identifiable {
    enum Kind: String { case round, elapsed, seatsDone, soFar, billed, convergence, stopsAt }
    enum Tone: Equatable { case normal, accent, amber, red }
    var id: Kind { kind }
    let kind: Kind; var value: String; var shortValue: String; var caption: String; var tone: Tone
}
struct LCDModel: Equatable {
    init(tape: Tape, config: RoundConfig, board: BoardModel, seats: [SeatRowModel], convergence: ConvergenceCellModel?, preview: PlayMode?, now: Date)
    var cells: [LCDCell]                       // full order: round, elapsed, seatsDone, soFar, billed, convergence, stopsAt
    static let dropOrder: [LCDCell.Kind] = [.billed, .soFar, .stopsAt]
    func visible(width: CGFloat, cellWidth: (LCDCell) -> CGFloat) -> [LCDCell]
}
```
- **`ControlBar`** view:
  - three transport clusters (Back · Pause | Step · Next major · To review | Stop), with a default-mode dot;
  - the LCD;
  - Extend and Annotate on the trailing edge.
- **Hover** on a play button sets `preview` through a binding shared with `DeparturesBoard`.
- **Enabled states** come from `ShapingModel.enabled`, which is kept.
- **"Pausing…"/"Stopping…"** shows while a pause or stop command is unacked (`tape.ackedCommandSeq < lastSeq`).
- **`PlanningCommands`:** a `CommandMenu("Run")` with Step, Next Major, To Review, Pause, Stop, Extend and Annotate, driven by `@FocusedValue(\.planningActions)`, which the live card publishes.
- **Chords:** proposed Step ⌘', Next Major ⇧⌘', To Review ⌥⌘', Pause ⌘., Stop ⇧⌘., Extend ⌘=, Annotate ⇧⌘A. Check each against Ghostty's performable bindings, per Global Constraints, and record any substitution in the commit body.

- [ ] **Step 1: Write the failing tests.**
  - `testCellsForRunningRefine`: values match `4:15`, `1/4`, `+42 −17`, `$0.61` (cost from finished seats only), convergence and stops-at.
  - `testPausedFailedReviewTones`
  - `testWouldStopWhenPreviewing`
  - `testCellsDropInOrderAsWidthShrinks` (Review Focus 1)
  - `testCompactSetAtNarrowWidth`: round, elapsed and convergence.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the model, then the views.** Build with `./scripts/build.sh`. Don't launch.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: drive planning rounds from a Logic-style control bar and Run menu`

## Task 7: Departures board view

**Files:**
- Create: `Planning/DeparturesBoard.swift`
- Test: extend `BoardModelTests` with the selection and hover-card content test (`testHoverCardText`: "Synthesis · landed 3:02").

**Interfaces:**
- Consumes: `BoardModel`, `SplitFlapText`, `FlapPolicy`.
- Produces: `DeparturesBoard(model:, policy:, preview: Binding<PlayMode?>, onSelect: (Int) -> Void, onExtend: (Stage) -> Void)`.

Layout:
- the board fields row on top (each a `SplitFlapText`, surfaces `board.now`, `board.inTheAir`, `board.stopsAt`, `board.callingAt`);
- the tape below: slots with group brackets, a + extend handle, taller ticks on majors, flags, an accent outline on the stop target, and a red failed slot;
- `DEP · CLR` / `ARR · REV` end captions.

Behaviour:
- The tape is a horizontal `ScrollView` that auto-scrolls to keep the live slot visible.
- The hover card for a slot uses `SplitFlapText`'s card, surface `card.<slot.id>`.
- Clicking a done slot calls `onSelect(checkpointID)`.
- Every slot gets an accessibility label in full words: "Refine 2, landed, 4 minutes 48 seconds".

- [ ] **Step 1: Write the failing test.** `testHoverCardText` and `testAccessibilityLabelsAreFullWords` go on the model's `accessibilityLabel(for:)`.
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run it and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: show the planning run as a departures board`

## Task 8: Seat rows, result cards and live cards

**Files:**
- Create: `Planning/SeatRow.swift`, `Planning/LiveCard.swift`, `Planning/ProgressSummary.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/ProgressSummaryTests.swift`

**Interfaces:**
- `SeatRow(model:)`:
  - glyph (SF Symbol, pulse via `.symbolEffect(.pulse)` when running, `.contentTransition(.symbolEffect(.replace))`);
  - role and identity, headline, action, footprint chips, steps, context gauge, elapsed (1 Hz `TimelineView(.periodic)`), exception line.
  - A finished row collapses to its result.
- `LiveCard.triage(intake:, activity:, pending:)` and `LiveCard.shaping(...)`:
  - control bar, board, then the seat rows of the round in progress, then the finished rounds' cards (reusing `ShapingModel.roundCards`, restyled);
  - the pause banner from `ShapingModel.pauseBanner`;
  - the edit-conflict banner (Task 11 supplies the data).
- `ProgressSummary.line(intake:, tape:) -> [(label: String, detail: String)]`, e.g. `("Triage","3:40 · 41 files")`, `("Draft & Synthesis","9:42 · 412 lines")`, `("Refine","×3")`.

- [ ] **Step 1: Write the failing tests.**
  - `testSummaryAfterTriageOnly`
  - `testSummaryAfterDraftAndSynthesis`
  - `testSummaryRefineCount`
  - `testNoBeadWording`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: show who is working and what they are doing, live`

## Task 9: Recompose the detail pane (Direction D) and the inspector

**Files:**
- Modify: `IntakeDetailView.swift` (restructure), `RoundConfigEditor.swift` (inspector host + `summary(preset:config:) -> String`), `IntakeStatePill.swift`, `ProjectView.swift` (inspector toggle ⌥⌘I, toolbar)
- Remove: `TapeStrip.swift`, `ShapingView.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/DetailLayoutTests.swift` (pure: which sections show for each state; the primary action title per state), plus update `IntakeDetailViewTests`.

**Interfaces:**
- `IntakeDetailView` becomes a document with these parts, top to bottom:
  - header: the "INTAKE · <state>" eyebrow, the intent title, and `ProgressSummary`;
  - Clarifications, reusing the existing collapsed rounds;
  - `LiveCard` for the state;
  - the plan section (Task 10 slots `PlanSection` in; until then the current viewer);
  - the pinned action bar, kept from the Q&A pass.

  The control bar and board pin under the toolbar on scroll, using `.safeAreaInset(edge: .top)` inside the scroll container once they scroll out.
- Awaiting choice has a segmented fidelity `Picker` using `UIText.presetName`, the recommendation, and `RoundConfigEditor.summary` with an **Edit in Inspector** button.
- The inspector (`.inspector(isPresented:)`, macOS 14) hosts `RoundConfigEditor` when awaiting a choice, and the selected seat's detail (full footprint file list, tokens, run dir) while shaping. The notes rail comes in Task 12.
- `DetailLayout.primaryAction(for: IntakeState, tape: Tape?) -> String?` returns "Send Answers", "Continue"/"Start Planning", "Review Tasks…", "Dismiss" or "Retry"; nil for shaping and triaging.

- [ ] **Step 1: Write the failing tests.**
  - `testSectionsPerState`
  - `testPrimaryActionTitles`
  - `testSummaryLine`: "Full plan · 4 drafters · refine ×5 · polish ×6 · customized".
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build. Add the env-gated render test `PlanningRenderTests`, skipped unless `FD_PLANNING_RENDER_DIR` is set. It renders every stage body at 1100 and 700 pt wide, dark, to PNGs. Use the `NSHostingView` + `layer.render(in:)` offscreen technique from `IntakeDetailViewRenderTests`.
- [ ] **Step 4: Run them and confirm they pass.** Then run the full suite once.
- [ ] **Step 5: Commit.** `feat: lay the intake out as one calm document with an inspector`

## Task 10: Live-preview Markdown plan editor

**Files:**
- Create: `Planning/PlanEditor/MarkdownStyler.swift`, `Planning/PlanEditor/PlanTextView.swift`, `Planning/PlanEditor/PlanSection.swift`
- Test: `Tests/FlightDeckTests/Intake/Planning/MarkdownStylerTests.swift`, `PlanTextViewPolicyTests.swift`

**Interfaces:**
```swift
struct MarkdownBlock: Equatable { enum Kind: Equatable { case heading(Int), paragraph, listItem, code, table, blank }
                                  let kind: Kind; let range: NSRange; let syntaxRanges: [NSRange] }  // syntax = "## ", "**", "- ", fences
enum MarkdownStyler {
    static func blocks(_ text: String) -> [MarkdownBlock]
    /// Attributes for rendering; syntax ranges hidden (zero-width font + clear color) except in `revealBlock`.
    static func apply(to storage: NSTextStorage, blocks: [MarkdownBlock], revealBlock: Int?, theme: PlanTheme)
}
struct PlanTextView: NSViewRepresentable {
    init(text: Binding<String>, editable: Bool, onCommit: @escaping (String) -> Void, incoming: String?, onShowIncoming: @escaping () -> Void)
}
enum EditPolicy {
    /// Commit when editing ends or after `idle` seconds without a keystroke; never per keystroke.
    static let idle: TimeInterval = 2
    /// While the view is first responder with uncommitted edits, a new head is NOT swapped in; the banner offers it.
    static func shouldReplace(editing: Bool, dirty: Bool) -> Bool
}
```
- The view is TextKit 2 (`NSTextView(usingTextLayoutManager: true)`).
- On a selection change, re-style the old and new caret blocks only; don't restyle the whole document.
- The stored text is always the raw Markdown.
- `PlanSection`:
  - owns the Plan · Diff vs Previous · Change set segmented control;
  - loads the selected checkpoint's effective plan (`PlanLayers.effectivePlan`);
  - commits through `service.send(id, .editPlan(checkpoint:markdown:))`, only for the head checkpoint. Past checkpoints are read-only, with a "Viewing Refine 2 · Go to latest" bar.

- [ ] **Step 1: Write the failing tests.**
  - Styler:
    - `testBlocksForHeadingsListsCodeTables`
    - `testSyntaxRangesForBoldAndHeadings`
    - `testRevealOnlyCaretBlock`: attributes in the revealed block keep the syntax visible, and other blocks hide it.
    - `testStoredTextUnchangedByStyling`
  - Policy:
    - `testCommitAfterIdleNotPerKeystroke`, with an injected clock and a debouncer;
    - `testIncomingHeadDoesNotReplaceTextWhileEditing` (Review Focus 3);
    - `testIncomingHeadReplacesWhenIdleAndClean`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: edit the plan in place as live-preview Markdown`

## Task 11: Your edits as a layer, and the conflict banner

**Files:**
- Create: `Planning/PlanEditor/EditLayer.swift`
- Modify: `PlanSection.swift`, `LiveCard.swift` (banner)
- Test: `Tests/FlightDeckTests/Intake/Planning/EditLayerTests.swift`

**Interfaces:**
- Consumes: `PlanLayers.userDiff(generated:edited:) -> [PlanHunk]`, `PlanLayers.revert(_:generated:edited:)`, `PlanLayers.conflictedEdits(_:)`, and `TapeStore.userEdits(checkpoint:)`.
- Produces:
```swift
struct EditMark: Equatable { enum Kind { case inserted, deleted }; let kind: Kind; let range: NSRange; let hunk: Int }
enum EditLayer {
    /// Ranges in the *edited* text for insertions, plus ghost deletions to draw struck-through, from hunks.
    static func marks(generated: String, edited: String) -> (marks: [EditMark], hunks: [PlanHunk])
    static func chip(_ hunks: [PlanHunk]) -> String?          // "3 edits by you"
    static func conflictBanner(_ c: [EditConflict], names: (Int) -> String) -> String?  // "Your edits to Refine 2 conflicted with this round"
}
```
- Rendering:
  - insertions get a green-tinted background and a green bar in the edit gutter lane;
  - deletions are drawn inline as struck-through, dimmed, red-tinted ghost text, as a non-editable attachment run;
  - a per-hunk hover shows Revert;
  - the header chip reads "N edits by you · Revert all";
  - a one-time note says "Your edits are kept; the next round treats them as fixed."
- The agents' round-to-round diff (Diff vs Previous) uses a neutral treatment.

- [ ] **Step 1: Write the failing tests.**
  - `testMarksForInsertAndDelete`
  - `testChipCounts`
  - `testRevertOneHunkRoundTrips`, through `PlanLayers.revert`
  - `testConflictBannerText`
  - `testNoMarksWhenNoUserEdits`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: show your plan edits as a layer over the agents' plan`

## Task 12: Highlight and annotate: selection toolbar and notes rail

**Files:**
- Create: `Planning/PlanEditor/SelectionToolbar.swift`, `Planning/PlanEditor/NotesRail.swift`
- Modify: `PlanTextView.swift` (selection → toolbar anchor rect; highlight attributes), `IntakeDetailView.swift` (the inspector shows the rail while the plan is focused)
- Test: `Tests/FlightDeckTests/Intake/Planning/NotesRailModelTests.swift`

**Interfaces:**
- Consumes:
  - `PlanNote`, `NoteKind` (comment, question, mustChange, delete, replace), `NoteAnchor(checkpoint:selecting:in:)`, `NoteAnchor.locate(in:)`;
  - `TapeStore.notes(in:) -> [TapeNote]`;
  - `.note` / `.removeNote` commands.
- Produces:
```swift
struct NoteCardModel: Equatable, Identifiable { let id: UUID; let kind: NoteKind; let quote: String?; let note: String; var anchorY: CGFloat?; let detached: Bool; let consumed: Bool }
enum NotesRailModel {
    static func cards(notes: [TapeNote], plan: String, lineY: (Range<String.Index>) -> CGFloat?) -> [NoteCardModel]  // pending first, ordered by anchor; unlocatable → detached at top
    static func summary(pending: Int, edits: Int) -> (chip: String?, tooltip: String?)   // "4 notes for the next round", "Sends your 3 edits and 4 notes"
    static func layout(_ cards: [NoteCardModel], minGap: CGFloat) -> [UUID: CGFloat]      // aligns to anchors, pushes down to avoid overlap
}
```
- The selection toolbar floats above the selection and has Comment, Question, Must change, Replace, Delete and Highlight.
- Choosing a kind:
  1. creates a draft card in the rail, focused, with no modal;
  2. on commit, sends `.note(PlanNote(kind:note:anchor:))`.
- Highlight alone creates a comment with an empty note.
- Annotated ranges get a system-highlight tint.
- The next-round transport tooltip uses `summary`.

- [ ] **Step 1: Write the failing tests.**
  - `testCardsOrderedByAnchor`
  - `testUnlocatableNoteIsDetachedNotDropped` (Review Focus 4)
  - `testConsumedNotesShownDimmedAfterRound`
  - `testLayoutAvoidsOverlap`
  - `testSummaryStrings`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: highlight and annotate the plan for the next round`

## Task 13: Convergence: LCD cell, churn gutter and heatmap

**Files:**
- Create: `Planning/ConvergenceCellModel.swift`, `Planning/ConvergenceViews.swift`
- Modify: `LCDModel.swift` (cell), `PlanTextView.swift` (churn lane), `LiveCard.swift` (heatmap disclosure under the tape)
- Test: `Tests/FlightDeckTests/Intake/Planning/ConvergenceCellModelTests.swift`

**Interfaces:**
- Consumes: `ConvergenceCycle` (stage, points, trend, verdict, explanation, suggestedAction), `ConvergencePoint.sectionChurn`, and `ConvergenceSeries.sectionChurn`.
- Produces:
```swift
struct ConvergenceCellModel: Equatable {
    init?(cycles: [ConvergenceCycle])                     // nil before any Refine/Polish cycle
    var spark: [Double]                                   // changeCount per round, current cycle
    var discontinuities: [Int]                            // indices where reviewerModel changed or an extend restarted
    var latest: Int; var word: String                     // "CONVERGING ↘" / "PLATEAU →" / "DIVERGING ↗" / "TOO EARLY"
    var tone: LCDCell.Tone                                // amber only for diverging
    var cardLines: [String]                               // series line, sections line, model-change line when present
    var action: String                                    // suggestedAction
}
struct HeatmapModel: Equatable {
    init(cycle: ConvergenceCycle)
    var sections: [String]; var rounds: [String]; var cells: [[Double]]   // normalized luminance 0…1
    var agree: [Double?]; var hot: Set<String>
}
struct ChurnLaneModel: Equatable {
    init(cycle: ConvergenceCycle, section: String)
    var bars: [Double]; var stillSince: String?; var hot: Bool            // "still since R2"
}
```
- The LCD cell shows a phosphor sparkline plus the count and the word. Hovering gives a board-style card (`SplitFlapText` card style, surface `card.convergence`). Clicking toggles the heatmap.
- The heatmap is an inline disclosure under the tape. Its columns align under the tape's R slots. Clicking a cell scrolls the plan to that section and switches to Diff vs Previous at that round. Esc closes it.
- The churn lane is a separate gutter lane beside the edit lane: bars per round, "still since Rn", and amber when hot. Clicking a bar opens the heatmap at that section.
- Hovering an amber marker lists that section's versions per round. They come from checkpoint `changes.json` entries whose `section` matches.

- [ ] **Step 1: Write the failing tests.**
  - `testConvergingWordAndSpark`: 41 → 14 → 5.
  - `testPlateau`
  - `testDivergingIsAmberAndNamesSection`
  - `testTooEarly`
  - `testModelChangeIsCalledOutOnTheCard` (Review Focus 5)
  - `testHeatmapNormalizationAndHot`
  - `testChurnLaneStillSince`
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.** Build.
- [ ] **Step 4: Run them and confirm they pass.**
- [ ] **Step 5: Commit.** `feat: show whether the plan is settling, and where it is not`

## Task 14: Release review, renders, docs and checklist

**Files:**
- Modify:
  - `ReleaseReviewView.swift`: title "Release plan as tasks"; sections New tasks / Edits / Dependencies; "N of M selected"; **Release N Tasks** as the default button with Cancel leading; "1 note carried into task notes".
  - `docs/ARCHITECTURE.md`: the planning UI section.
  - `docs/FLYWHEEL-INTAKE-CHECKLIST.md`: a new "Planning UI" section covering the spec §13 GUI list, including split-flap once, a narrow pane, Reduce Motion, VoiceOver and keyboard.
  - `docs/FOLLOWUPS.md`: threshold tuning; Ghostty chord substitutions, if any.
- Test: extend `PlanningRenderTests` with release review and the converging/plateau/diverging shaping screens at 1100 and 700 pt.

- [ ] **Step 1: Write the failing test.** `testReleaseButtonTitle` and `testReleaseSheetHasNoBeadWording` (via `UIText`).
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement and update the docs.** Run the renders once with `FD_PLANNING_RENDER_DIR=/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/9bf1e259-cc02-4f83-884e-27183594e064/scratchpad/planning-renders`. Look at every PNG and fix anything clipped or overlapping.
- [ ] **Step 4: Run the full suite once.** Then `./scripts/build.sh`.
- [ ] **Step 5: Commit.** `feat: release tasks from a HIG review sheet; document and check the planning UI`

---

## Execution notes

- **Order and parallelism:**
  1. Tasks 1, 2, 3, 4 and 10 run in parallel. They're pure or self-contained, in separate worktrees.
  2. Then Task 5, followed by 6, 7 and 8 in parallel.
  3. Then Task 9.
  4. Then Tasks 11, 12 and 13 in parallel. All three touch `PlanTextView`/`LiveCard`, so give each its own seams and merge in the order 11 → 12 → 13.
  5. Then Task 14.
- After the final review: a Release build and swap, then Nate walks the checklist.
