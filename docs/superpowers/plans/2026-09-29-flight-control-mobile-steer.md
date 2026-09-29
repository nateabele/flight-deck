# Flight Control on the phone — Phase 2 (Steer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the phone, the maintainer can steer a running Flight Control tape — Pause · Step · Next major · To review · Stop (confirmed), set the default play by long-press, add/remove refine and polish rounds — and annotate the plan: select a phrase (or pick a whole passage, or the whole plan) and leave a Comment / Question / Must change / Replace / Delete / Highlight note for the next round, and delete his pending notes.

**Architecture:** Four new phone→Mac `FleetCommand` cases (`intake.tape`, `intake.defaultPlay`, `intake.note`, `intake.removeNote`), each token-idempotent and applied by ONE new `IntakeService` method that returns a named refusal code (the store-method rule at `FleetService.apply`'s `.prompt` arm). An older Mac throws on an unknown command op and drops the socket (`FleetCommand` decode throws; `FleetSocketServer` salvages only `req`), so the phone sends these only when the intake's detail carries `steer == true`, which only a Phase-2 Mac sets. The Mac also projects the transport rules it already applies on the desktop — extracted from `ShapingModel.enabled` + `PlanningActions.shaping` into one pure `TransportRules`, used by both — as `WireBoard.controls`, so the phone's enabled keys and ± control can never disagree with the Mac's. Notes: the phone sends the checkpoint it is reading, the `PlanBlocks` block index and the RENDERED quote it selected; the Mac maps that to a source range with a pure `RenderedQuoteLocator` (spec §6.6) and builds the `NoteAnchor` with the same `NoteAnchor(checkpoint:selecting:in:)` the desktop uses, falling back to the whole block. The phone gives every tap feedback at once, confirms on ack, rolls back with words on err, and times out after 10 s (spec §8).

**Tech Stack:** Swift 5 (app) / Swift 6 (FleetKit, IntakeKit, FlightDeckMobile), SwiftUI, UIKit (`UITextView` edit menu), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-29-flight-control-mobile-design.md` — Phase 2 = §11 item 2: §4.3 transport, §4.4 rounds ±, §4.8 annotation, §6.5 (tape/note/defaultPlay/removeNote rows), §6.6, §8. §11.1 lists Phase 1's as-built deltas; they stand. Phase 1 plan (for patterns): `docs/superpowers/plans/2026-09-29-flight-control-mobile-watch.md`.

## Global Constraints

- **Words:** tasks (never beads), Flight Control (never Flywheel), agent (never seat) in every user-visible string. The phone is covered by `TerminologyGuardTests`.
- **Honest data / colour for exceptions only / every `Text` names its font / relative sizes / monospace only for machine text** — as Phase 1 (`docs/MOBILE-UI.md`).
- **HIG:** Stop always confirms ("Stop the run?", destructive **Stop Run**, never the default, Cancel); Pause acts at once; ± never confirm (the other undoes it); no labelled spinners except the acknowledgement of the maintainer's own press ("Pausing…", "Stopping…").
- **No dead moments (spec §8):** every tap changes the screen within 100 ms; on ack re-request the detail immediately; on err roll back with words; no ack in **10 s** → roll back with "Couldn't reach your Mac."; the token makes a retry safe.
- **Compatibility:** a phone NEVER sends an `intake.*` command unless the intake's latest detail has `steer == true`. An older phone never sees these screens' controls (it decodes and ignores the new optional fields).
- **Wire enum cases are atomic:** the four `FleetCommand` cases, their ops, encode/decode, `ControlScope.permits` and `FleetService.apply` arms land in ONE commit (Task 4).
- **Refusals** return a named `err` code AND log `check=<code> intake=<id>` on the Mac.
- **Head-plan cache contract (Phase 1):** after a note is added or removed, the reader re-requests the head with `checkpoint: nil`.
- **Tests:** macOS `./scripts/test-unit.sh` (whole suite, ~8 min; success = `** SHARDED UNIT RUN PASSED`); iOS `./scripts/test-ios.sh` (`** TEST SUCCEEDED **`); touching FleetKit/IntakeKit ⇒ both; `./scripts/build-ios.sh` for phone UI (must take the real build branch). Foreground only. Never smoke.sh; never launch a built app; never write under `~/Library/Application Support/Flight Deck`.
- **Work in a worktree** off current master (symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts`; `xcodegen generate`); commit by path; empty `git diff --cached --stat -- vendor`; built-in Edit (not quillmap mutators). Commit trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **An older Mac, a Phase-2 phone:** the phone must not send `intake.*` (the Mac would drop the socket) → Task 6 test `testNoCommandIsSentWithoutSteer`.
2. **A double tap / a retry after a lost ack** must not queue two Steps or two identical notes → Task 3 test `testARepeatedTokenAcksWithoutSendingAgain`.
3. **The phone offering a key the Mac would refuse** (e.g. Next major after a failure, extend on a finished stage) → Task 1 `TransportRules` tests shared by desktop and wire; Task 3 `testAKeyTheRulesDisallowIsRefused`.
4. **A selected phrase spanning `**bold**`, `` `code` ``, a link, or a wrapped line** must anchor to that phrase; a phrase not found must anchor to the whole passage, never to the wrong one → Task 2 locator tests against the real larkOS plan; Task 3 fallback test.
5. **The note sheet over the keyboard** and the long-press/tap coexistence are device-only → Task 9 MOBILE.md items name the failures.

---

## File map

- **IntakeKit:** create `Sources/IntakeKit/RenderedQuoteLocator.swift`.
- **FleetKit:** modify `Sources/FleetKit/IntakeWire.swift` (`WireControls`, `WireBoard.controls`, `WireIntakeDetail.steer`), `Sources/FleetKit/Frames.swift` (4 `FleetCommand` cases).
- **Mac app:** create `Sources/FlightDeck/Intake/Planning/TransportRules.swift`; modify `ShapingModel.swift`, `PlanningCommands.swift` (use `TransportRules`), `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift` (controls, steer), `Sources/FlightDeck/Intake/IntakeService.swift` (phone methods + tokens), `Sources/FlightDeck/Fleet/FleetService.swift` (apply arms), `Sources/FlightDeck/Fleet/ControlScope.swift`.
- **Phone (flat):** create `IntakeCommands.swift` (protocol, `IntakeCommandModel`, `CommandCopy`), `TransportKeys.swift` (pure keys + rounds control model), `NoteSheet.swift`, `NoteComposer.swift` (pure draft rules); modify `FleetModel.swift`, `FlightControlModel.swift`, `BoardStrip.swift`, `BoardStripModel.swift`, `IntakeScreen.swift`, `PlanReaderScreen.swift`, `SelectableProseView.swift`, `TimelineRow.swift` (adapt to the generalised edit-menu actions).
- **Tests:** macOS `TransportRulesTests.swift`, `RenderedQuoteLocatorTests.swift`, `IntakePhoneCommandTests.swift`, `IntakeCommandCodingTests.swift`; iOS `IntakeCommandModelTests.swift`, `TransportKeysTests.swift`, `NoteComposerTests.swift`; extend `IntakeRenderHarness.swift`.
- **Docs:** `docs/MOBILE.md` (items), spec §11.2 "Phase 2 as built", `docs/HANDOFF.md`.

---

### Task 1: One transport rule, used by the desktop and projected to the phone

**Files:**
- Create: `Sources/FlightDeck/Intake/Planning/TransportRules.swift`
- Modify: `Sources/FlightDeck/Intake/ShapingModel.swift:92-109` (`enabled`, `extendStages`, `trimStages` delegate), `Sources/FlightDeck/Intake/Planning/PlanningCommands.swift:47-68` (stage choice from `TransportRules`), `Sources/FleetKit/IntakeWire.swift` (`WireControls`, `WireBoard.controls`, `WireIntakeDetail.steer`), `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift` (`board(...)`, `detail(...)`)
- Test: `Tests/FlightDeckTests/TransportRulesTests.swift`; extend `Tests/FlightDeckTests/IntakeDetailProjectionTests.swift`, `IntakeWireCodingTests.swift`

**Interfaces:**
- Produces: `struct TransportRules: Equatable { var enabled: Set<TransportButton>; var extendStage: Stage?; var trimStage: Stage?; static func make(tape: Tape, config: RoundConfig?) -> TransportRules }`; `public struct WireControls: Codable, Equatable, Sendable { public var enabled: [String]; public var extendStage: String?; public var trimStage: String?; public var cycleName: String?; public var cyclePlanned: Int? }` (memberwise public init, optionals default nil); `WireBoard.controls: WireControls?` (last init param, default nil); `WireIntakeDetail.steer: Bool?` (last init param, default nil); `IntakeDetailProjection.controls(_ rules: TransportRules, board: BoardModel) -> WireControls`.
- `TransportButton` raw names on the wire: `step, nextMajor, toReview, pause, stop, extend, trim` (`annotate` is never sent — notes have their own gate).

- [ ] **Step 1: Failing tests** — `TransportRulesTests.swift`:

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

final class TransportRulesTests: XCTestCase {
    private func config() -> RoundConfig { PresetExpansion.config(for: .fullPlan, available: .defaults) }

    func testRunningAllowsOnlyPauseStopAndAnnotate() {
        var tape = Tape(); tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false)
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [.pause, .stop, .annotate])
    }

    func testPausedAllowsPlaysAndRoundEdits() {
        var tape = Tape(); tape.status = .paused
        let rules = TransportRules.make(tape: tape, config: config())
        XCTAssertTrue(rules.enabled.isSuperset(of: [.step, .nextMajor, .toReview, .annotate]))
        XCTAssertEqual(rules.extendStage, .refine, "before refine has run, + lengthens refine")
    }

    func testFailedWithholdsNextMajor() {
        var tape = Tape(); tape.status = .failed
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [.step, .toReview, .annotate])
    }

    func testReviewAllowsNothing() {
        var tape = Tape(); tape.status = .reachedReview
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [])
    }

    func testExtendAndTrimDropOutWhenNoStageQualifies() {
        var tape = Tape(); tape.status = .paused
        let rules = TransportRules.make(tape: tape, config: nil)
        XCTAssertFalse(rules.enabled.contains(.extend))
        XCTAssertFalse(rules.enabled.contains(.trim))
    }
}
```
(Use `Tape`'s and `PlannedRound`'s real public inits; widen nothing unless the compiler says so.) Also a desktop-parity test: build `ShapingModel` for a paused Full-plan tape and assert `PlanningActions.shaping(...).enabled == TransportRules.make(...).enabled` (read `PlanningCommands.swift` for how tests construct it; if `PlanningActions` needs a live `IntakeService`, compare `ShapingModel.enabled` instead).

Extend `IntakeDetailProjectionTests` with `testAShapingDetailCarriesControlsAndSteer`: running tape → `board.controls.enabled == ["pause", "stop"]` (sorted, no "annotate"), `steer == true`; paused before refine → `extendStage == "refine"`, `cycleName == "Refine"`, `cyclePlanned` = the refine slot count on the board. And `testTheEtagIsStableWithControls` (two details, only `servedAt` differs → same etag). Extend `IntakeWireCodingTests` with a round trip of a `WireBoard` carrying `WireControls`, and `testADetailFromAPhase1MacDecodesWithNoSteer` (JSON without `steer`/`controls` decodes to nil).

- [ ] **Step 2: Run** `./scripts/test-unit.sh` → compile failure naming `TransportRules`/`WireControls`.

- [ ] **Step 3: Implement.** `TransportRules.swift`:

```swift
import Foundation
import IntakeKit

/// Which transport controls a tape allows right now, and which stage + and − act on — the ONE
/// rule the desktop's control bar, its Run menu, and the phone (via `WireControls`) all read, so
/// the phone can never offer a key the Mac would refuse. Moved out of `ShapingModel.enabled`
/// and `PlanningActions.shaping` unchanged.
struct TransportRules: Equatable {
    var enabled: Set<TransportButton>
    var extendStage: Stage?
    var trimStage: Stage?

    static func make(tape: Tape, config: RoundConfig?) -> TransportRules {
        var enabled: Set<TransportButton> = switch tape.status {
        case .running: [.pause, .stop, .annotate]
        case .paused, .idle, .stopped: [.step, .nextMajor, .toReview, .extend, .trim, .annotate]
        // ⏯ re-runs the round that failed; ⏭ is withheld because after a failure the human
        // should see one round succeed before committing to a whole stage again.
        case .failed: [.step, .toReview, .annotate]
        case .reachedReview: []
        }
        let current = tape.roundInProgress?.stage ?? tape.head?.stage
        let extendable = BoardModel.extendableStages(tape: tape, config: config)
        let trimmable = BoardModel.trimmableStages(tape: tape, config: config)
        let extendStage = extendable.first { $0 == current } ?? extendable.first
        let trimStage = trimmable.first { $0 == current } ?? trimmable.first
        if extendStage == nil { enabled.remove(.extend) }
        if trimStage == nil { enabled.remove(.trim) }
        return TransportRules(enabled: enabled, extendStage: extendStage, trimStage: trimStage)
    }
}
```
`ShapingModel.enabled` returns `TransportRules.make(tape: tape, config: intake.roundConfig).enabled` WITHOUT the extend/trim removal? — check: today `ShapingModel.enabled` includes extend/trim unconditionally for paused and `PlanningActions` removes them. Keep the desktop's observable behaviour identical: `PlanningActions.shaping` uses `TransportRules.make(...)` for `enabled`, `extendStage`, `trimStage`; `ShapingModel.enabled` also returns `TransportRules.make(...).enabled` (its other callers then see extend/trim removed when no stage qualifies — which is what every caller already did via `PlanningActions`; confirm with `rg -n '\.enabled' Sources/FlightDeck/Intake` and note any caller that relied on the unfiltered set in the report). Keep `extendStages`/`trimStages` as they are.

`IntakeWire.swift`: add `WireControls` (doc: "the Mac's `TransportRules`, as strings; nil from a Phase-1 Mac"), `WireBoard.controls`, `WireIntakeDetail.steer` (doc: "true from a Mac that accepts `intake.*` commands — the phone's ONLY licence to send them; an older Mac drops the socket on an unknown command").

`IntakeDetailProjection`:

```swift
    static func controls(_ rules: TransportRules, board: BoardModel) -> WireControls {
        let order: [TransportButton] = [.step, .nextMajor, .toReview, .pause, .stop, .extend, .trim]
        let names: [TransportButton: String] = [.step: "step", .nextMajor: "nextMajor", .toReview: "toReview",
                                                .pause: "pause", .stop: "stop", .extend: "extend", .trim: "trim"]
        let stage = rules.extendStage ?? rules.trimStage
        let group = stage.map { $0 == .refine ? "REFINE" : "POLISH" }
        return WireControls(
            enabled: order.filter(rules.enabled.contains).compactMap { names[$0] },
            extendStage: rules.extendStage?.rawValue, trimStage: rules.trimStage?.rawValue,
            cycleName: stage.map { $0 == .refine ? "Refine" : "Polish" },
            cyclePlanned: group.map { g in board.slots.filter { $0.group == g }.count })
    }
```
In `board(...)` pass `controls: controls(TransportRules.make(tape: tape, config: config), board: m)`; in `detail(...)` set `steer: true`. Check the BoardModel group strings (`"REFINE"`/`"POLISH"`) against `BoardModel.swift` before relying on them.

- [ ] **Step 4: Run** test-unit.sh (0 failures; every existing desktop ShapingModel/Planning test still passes) and test-ios.sh (FleetKit compiles for iOS).
- [ ] **Step 5: Commit** `feat: share the transport rule between the desktop and the phone`.

---

### Task 2: Map a rendered quote back to its Markdown source

**Files:**
- Create: `Sources/IntakeKit/RenderedQuoteLocator.swift`
- Test: `Tests/FlightDeckTests/RenderedQuoteLocatorTests.swift` (uses `Tests/FlightDeckTests/Fixtures/larkos-plan.md`, already in the repo)

**Interfaces:**
- Produces: `public enum RenderedQuoteLocator { public static func range(of rendered: String, within scope: Range<String.Index>, of markdown: String) -> Range<String.Index>? }` — the source range whose RENDERED text equals `rendered` (after both sides are normalised), or nil.

Normalisation (both sides): drop inline markers `**`, `__`, `*`, `_`, `` ` ``; turn `[text](url)` into `text` (drop `[`, and `](…)`); drop a leading `#…# ` heading prefix at the start of a line; collapse every whitespace run to one space; trim. The source side keeps, for each kept character, its source index, so a match maps back to a real `Range` from the first kept char's index to just past the last kept char's.

- [ ] **Step 1: Failing tests:**

```swift
import XCTest
import IntakeKit

final class RenderedQuoteLocatorTests: XCTestCase {
    private func locate(_ q: String, in md: String) -> String? {
        RenderedQuoteLocator.range(of: q, within: md.startIndex..<md.endIndex, of: md).map { String(md[$0]) }
    }

    func testPlainTextMatchesVerbatim() {
        XCTAssertEqual(locate("chosen mode", in: "Require that the chosen mode permits."), "chosen mode")
    }
    func testBoldSpansMapToTheirSource() {
        XCTAssertEqual(locate("account sign-in and API", in: "separate **account sign-in** and **API credential** paths"),
                       "account sign-in** and **API")
    }
    func testCodeAndLinksMapToTheirSource() {
        XCTAssertEqual(locate("keep vault keys", in: "keep `vault` keys"), "keep `vault` keys")
        XCTAssertEqual(locate("through Beacon's gateway now", in: "through [Beacon's gateway](https://x.test) now"),
                       "through [Beacon's gateway](https://x.test) now")
    }
    func testWrappedWhitespaceStillMatches() {
        XCTAssertEqual(locate("hosted and unattended", in: "hosted\n  and   unattended"), "hosted\n  and   unattended")
    }
    func testHeadingPrefixIsIgnored() {
        XCTAssertEqual(locate("7. Credential paths", in: "## 7. Credential paths"), "7. Credential paths")
    }
    func testNotFoundIsNil() {
        XCTAssertNil(locate("nowhere to be seen", in: "Some other text."))
    }
    func testScopeLimitsTheSearch() {
        let md = "alpha beta\n\nalpha gamma"
        let second = md.range(of: "alpha gamma")!
        let r = RenderedQuoteLocator.range(of: "alpha", within: second, of: md)!
        XCTAssertEqual(md.distance(from: md.startIndex, to: r.lowerBound), md.distance(from: md.startIndex, to: second.lowerBound))
    }
    func testTheRealLarkOSPlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/larkos-plan.md")
        let md = try String(contentsOf: url, encoding: .utf8)
        let r = RenderedQuoteLocator.range(of: "Require explicit proof that the chosen mode permits hosted and unattended execution",
                                           within: md.startIndex..<md.endIndex, of: md)
        XCTAssertNotNil(r)
    }
}
```

- [ ] **Step 2: Run** → compile failure.
- [ ] **Step 3: Implement** (pure, Foundation only): build `kept: [(Character, String.Index)]` from `markdown[scope]` applying the rules above (a small state machine: skip `[`; on `](` skip to the matching `)`; skip marker runs; at line start skip `#+ `; map any whitespace run to one `" "` recorded at the run's first index); build the needle from `rendered` with the same rules minus index tracking; search `kept` for the needle's characters (simple sliding compare is fine — plans are ≤ 60 KB and this runs once per note); map back. Doc comment names spec §6.6 and why rendered, not source, text arrives (the phone's `UITextView` selection is of attributed text).
- [ ] **Step 4: Run** test-unit.sh (+ test-ios.sh: IntakeKit isn't compiled for iOS — if `rg -n IntakeKit project.yml` shows it is macOS-only, test-unit.sh alone suffices).
- [ ] **Step 5: Commit** `feat: find a rendered quote in its markdown source`.

---

### Task 3: Phone-facing intake commands on the Mac

**Files:**
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift` (four methods + token memory)
- Test: `Tests/FlightDeckTests/IntakePhoneCommandTests.swift` (service set-up copied from `IntakeDetailProjectionTests`' private helpers: temp root, fake runner, `seed`, `updateTape`)

**Interfaces:**
- Consumes: `TransportRules` (Task 1), `RenderedQuoteLocator` (Task 2), `PlanSection.effectivePlan(checkpoint:tape:loadFile:)`, `PlanBlocks.split`, `NoteAnchor(checkpoint:selecting:in:)`, existing `send(_:_:)`, `setDefaultPlay(_:_:)`, `storedTape(_:)`, `checkpointFile(_:checkpoint:_:)`.
- Produces (all return `nil` = accepted, else a refusal code; all log `check=<code> intake=<id>` on refusal):
  - `func phoneTape(_ id: UUID, token: UUID, command: String, stage: String?) -> String?`
  - `func phoneDefaultPlay(_ id: UUID, token: UUID, mode: String) -> String?`
  - `func phoneNote(_ id: UUID, token: UUID, noteID: UUID, kind: String, text: String, checkpoint: Int?, block: Int?, quote: String?) -> String?`
  - `func phoneRemoveNote(_ id: UUID, token: UUID, noteID: UUID) -> String?`
- Refusal codes: `unknown_intake`, `intake_moved_on` (not `.shaping`), `not_allowed` (transport button not in `TransportRules.enabled`, or ± stage not the rule's stage), `unknown_command`, `unknown_mode`, `unknown_kind`, `empty_note` (blank text for any kind but a Highlight — a `comment` with empty text IS a Highlight and is allowed), `unknown_checkpoint`, `unknown_block`, `note_consumed` (remove of a note not in `tape.pendingNotes`).

- [ ] **Step 1: Failing tests** (`IntakePhoneCommandTests`), each seeding a shaping intake with a Full-plan config:
  - `testAPauseWhileRunningIsQueued`: tape running → `phoneTape(id, token: t, command: "pause", stage: nil) == nil`, then `service.halts[id]?.kind == .pause` and the tape store's `commands.jsonl` gained one line.
  - `testARepeatedTokenAcksWithoutSendingAgain`: same token twice → both nil, `commands.jsonl` has ONE new line.
  - `testAKeyTheRulesDisallowIsRefused`: tape failed → `phoneTape(… "nextMajor" …) == "not_allowed"`; running → `"step"` → `"not_allowed"`.
  - `testExtendNeedsTheRulesStage`: paused before refine → `phoneTape(… "extend", stage: "refine") == nil`; `stage: "polish"` → `"not_allowed"`.
  - `testANonShapingIntakeHasMovedOn`: intake in `.review` → `"intake_moved_on"`; unknown id → `"unknown_intake"`.
  - `testDefaultPlay`: `phoneDefaultPlay(… mode: "toReview") == nil` and the intake's `roundConfig.defaultPlay == .toReview`; `"sideways"` → `"unknown_mode"`.
  - `testANoteOnAPhraseAnchorsToThatPhrase`: write a checkpoint plan (use `updateTape` + write `checkpoints/1/plan.md` via the tape store's checkpoint directory, as the Phase-1 detail tests do) containing `"Keep **account sign-in** in scope."`; block index of that paragraph from `PlanBlocks.split`; `phoneNote(… kind: "mustChange", text: "No.", checkpoint: 1, block: b, quote: "account sign-in in scope")` → nil; the tape's pending notes (after the service folds its overlay — read `service.tapes[id]?.pendingNotes` or the stored commands) contain a `PlanNote` with `kind == .mustChange`, `note == "No."`, `anchor?.quote == "account sign-in** in scope"`, `anchor?.checkpoint == 1`.
  - `testAPhraseNotFoundAnchorsToTheWholeBlock`: quote `"not in the text"` → nil; anchor quote == the block's full text.
  - `testAPlanWideNoteHasNoAnchor`: `checkpoint: nil, block: nil, quote: nil` → nil; anchor == nil.
  - `testAHighlightMayBeEmptyButACommentOnAQuestionMayNot`: kind `"comment"`, text `""` → nil; kind `"question"`, text `"  "` → `"empty_note"`.
  - `testBadBlockAndCheckpoint`: block 999 → `"unknown_block"`; checkpoint 999 → `"unknown_checkpoint"`.
  - `testRemovingAPendingNoteAndAConsumedOne`: add a note, then `phoneRemoveNote(… noteID: thatID) == nil`; a random id → `"note_consumed"`.

- [ ] **Step 2: Run** → compile failure.
- [ ] **Step 3: Implement** in `IntakeService`:

```swift
    /// Phone command tokens already accepted, per intake — a repeat is acked without being
    /// applied twice (a retry after a lost ack must not queue a second Step). Last 16 kept.
    private var phoneTokens: [UUID: [UUID]] = [:]
    static let maxRememberedPhoneTokens = 16

    /// True the first time `token` is seen for `id` (and remembers it).
    private func firstSighting(_ token: UUID, for id: UUID) -> Bool {
        var seen = phoneTokens[id, default: []]
        if seen.contains(token) { return false }
        seen.append(token)
        if seen.count > Self.maxRememberedPhoneTokens { seen.removeFirst(seen.count - Self.maxRememberedPhoneTokens) }
        phoneTokens[id] = seen
        return true
    }

    private func refuse(_ code: String, _ id: UUID) -> String {
        Self.logger.info("check=\(code, privacy: .public) intake=\(id, privacy: .public)")
        return code
    }

    /// The phone's transport key (spec §6.5 `intakeTape`). Validated against the same
    /// `TransportRules` the desktop's control bar uses, so the phone cannot do what the Mac's
    /// own buttons would not.
    func phoneTape(_ id: UUID, token: UUID, command: String, stage: String?) -> String? {
        guard let i = intake(id) else { return refuse("unknown_intake", id) }
        guard i.state == .shaping else { return refuse("intake_moved_on", id) }
        let rules = TransportRules.make(tape: storedTape(id), config: i.roundConfig)
        let tapeCommand: TapeCommand
        switch command {
        case "step": tapeCommand = .step
        case "nextMajor": tapeCommand = .nextMajor
        case "toReview": tapeCommand = .toReview
        case "pause": tapeCommand = .pause
        case "stop": tapeCommand = .stop
        case "extend":
            guard let s = rules.extendStage, stage == s.rawValue else { return refuse("not_allowed", id) }
            tapeCommand = .extend(s, by: 1)
        case "trim":
            guard let s = rules.trimStage, stage == s.rawValue else { return refuse("not_allowed", id) }
            tapeCommand = .trim(s, by: 1)
        default: return refuse("unknown_command", id)
        }
        let button: TransportButton = switch tapeCommand {
        case .step: .step
        case .nextMajor: .nextMajor
        case .toReview: .toReview
        case .pause: .pause
        case .stop: .stop
        case .extend: .extend
        default: .trim
        }
        guard rules.enabled.contains(button) else { return refuse("not_allowed", id) }
        guard firstSighting(token, for: id) else { return nil }
        send(id, tapeCommand)
        return nil
    }
```
(Order: validation first, then the token — a refused command does not burn its token, so a corrected retry with the same token still works. A repeated token of an ACCEPTED command acks without re-sending.) Write `phoneDefaultPlay`, `phoneNote`, `phoneRemoveNote` in the same shape:
- `phoneDefaultPlay`: intake/shaping checks; `PlayMode(rawValue: mode)` else `unknown_mode`; token; `setDefaultPlay`.
- `phoneNote`: intake/shaping; `NoteKind(rawValue: kind)` else `unknown_kind`; trimmed text empty && kind != .comment → `empty_note`; anchor:
  ```swift
  var anchor: NoteAnchor?
  if let checkpoint {
      let tape = storedTape(id)
      let load: (Int, String) -> Data? = { self.checkpointFile(id, checkpoint: $0, $1) }
      guard let markdown = PlanSection.effectivePlan(checkpoint: checkpoint, tape: tape, loadFile: load)
      else { return refuse("unknown_checkpoint", id) }
      if let block {
          let blocks = PlanBlocks.split(markdown)
          guard let b = blocks.block(at: block) else { return refuse("unknown_block", id) }
          // The block's own occurrence: count earlier blocks with identical text, take that occurrence.
          let scope = Self.occurrence(of: b, in: blocks, markdown: markdown)
          let found = quote.flatMap { RenderedQuoteLocator.range(of: $0, within: scope, of: markdown) }
          if quote != nil, found == nil { Self.logger.info("check=note_anchor_fallback intake=\(id, privacy: .public)") }
          anchor = NoteAnchor(checkpoint: checkpoint, selecting: found ?? scope, in: markdown)
      }
  } else if block != nil { return refuse("unknown_checkpoint", id) }
  guard firstSighting(token, for: id) else { return nil }
  send(id, .note(PlanNote(id: noteID, kind: noteKind, note: trimmed, anchor: anchor)))
  ```
  with `static func occurrence(of b: PlanBlocks.Block, in blocks: PlanBlocks, markdown: String) -> Range<String.Index>` (nth `markdown.range(of:options:range:)` where n = number of earlier blocks with the same text; falls back to the whole markdown if not found).
- `phoneRemoveNote`: intake/shaping; `storedTape(id).pendingNotes.contains { $0.id == noteID }` else `note_consumed`; token; `send(id, .removeNote(noteID))`.
Use `IntakeService`'s existing logger (check its name). If `PlanSection` lives in a view file that `IntakeService` shouldn't depend on, it is still the same module; import nothing new.

- [ ] **Step 4: Run** test-unit.sh.
- [ ] **Step 5: Commit** `feat: accept transport, default play and notes from the phone`.

---

### Task 4: The four `intake.*` commands on the wire (atomic)

**Files:**
- Modify: `Sources/FleetKit/Frames.swift` (`FleetCommand` cases, `CodingKeys`, `Op`, encode `:293`, decode `:382`), `Sources/FlightDeck/Fleet/ControlScope.swift:87`, `Sources/FlightDeck/Fleet/FleetService.swift:1082` (`apply`)
- Test: `Tests/FlightDeckTests/IntakeCommandCodingTests.swift`; a FleetService-level test (in `IntakePhoneCommandTests.swift` or a new file) via `FleetTestHarness` + a store with `intakesRoot:`

**Interfaces:**
- Produces:
  - `case intakeTape(id: UUID, token: UUID, command: String, stage: String?)` op `"intake.tape"`
  - `case intakeDefaultPlay(id: UUID, token: UUID, mode: String)` op `"intake.defaultPlay"`
  - `case intakeNote(id: UUID, token: UUID, noteID: UUID, kind: String, text: String, checkpoint: Int?, block: Int?, quote: String?)` op `"intake.note"`
  - `case intakeRemoveNote(id: UUID, token: UUID, noteID: UUID)` op `"intake.removeNote"`
  - Keys added: `command, stage, mode, noteID, kind, checkpoint, quote` (`id`, `token`, `text`, `block` exist). Optionals encode with `encodeIfPresent`, decode with `decodeIfPresent`.
  - Doc comment on the group: sent only when the intake's detail has `steer == true` — an older Mac throws on an unknown op and, because only `req` is salvaged, drops the socket.

- [ ] **Step 1: Failing tests** — round trips of all four (with and without optionals), each asserting its `op` string; `ControlScope`: at `.ownSession` for a session caller all four → false, at `.full` → true; FleetService: with a seeded shaping intake, `.intakeTape(… "pause" …)` while running replies `.ack`; with an unknown id replies `.err(code: "unknown_intake")`; `.intakeNote` plan-wide replies `.ack`.
- [ ] **Step 2: Run** → compile failure.
- [ ] **Step 3: Implement** every arm in one step. `ControlScope.permits`: add the four to the fleet-wide `return false` arm with a comment ("an intake is a project's, not the asking session's"). `FleetService.apply`:

```swift
        case .intakeTape(let id, let token, let command, let stage):
            // No validation here — `IntakeService.phoneTape` is the one place that knows the
            // tape and the rules (the store-method rule stated at `.prompt`).
            if let code = store.intakeService.phoneTape(id, token: token, command: command, stage: stage) {
                return .err(cid: cid, code: code)
            }
```
and the same shape for the other three, falling through to the shared `return .ack(cid: cid)` tail.
- [ ] **Step 4: Run** test-unit.sh and test-ios.sh.
- [ ] **Step 5: Commit** (every file) `feat: carry phone transport and note commands for flight control`.

---

### Task 5: The phone sends intake commands and hears back

**Files:**
- Create: `Sources/FlightDeckMobile/IntakeCommands.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (conform to `IntakeCommanding`), `Sources/FlightDeckMobile/FlightControlModel.swift` (hold a weak commander; vend one `IntakeCommandModel` per intake; `reset()` clears them)
- Test: `Tests/FlightDeckMobileTests/IntakeCommandModelTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor protocol IntakeCommanding: AnyObject { func sendIntake(_ command: FleetCommand, then: @escaping (Result<Void, FleetRequestError>) -> Void) }` — `FleetModel` forwards to `connector.send(_:then:)`, completing `.failure(.disconnected)` synchronously with no connector (the `sendPrompt` shape).
  - `enum IntakeAction: Hashable { case tape(String), defaultPlay(String), note(UUID), removeNote(UUID) }`
  - `@MainActor @Observable final class IntakeCommandModel { let intake: UUID; private(set) var inFlight: Set<IntakeAction>; private(set) var message: String?; func send(_ action: IntakeAction, command: (UUID) -> FleetCommand, onAck: @escaping () -> Void); func clearMessage(); init(intake: UUID, commander: IntakeCommanding, timeout: Duration = .seconds(10)) }` — mints the token, inserts `action` into `inFlight` at once (the 100 ms feedback), arms the 10 s deadline BEFORE sending (the send may complete synchronously), on ack removes it and calls `onAck`, on err/timeout removes it and sets `message = CommandCopy.message(for:)`. One action of a kind at a time: a second `send` of an action already in flight is ignored.
  - `enum CommandCopy { static func message(for error: FleetRequestError?) -> String }` — nil (timeout) → "Couldn't reach your Mac."; `.disconnected` → "Not connected to your Mac, so this wasn't sent."; `.server(code:)`: `intake_moved_on` → "This intake has moved on."; `not_allowed` → "That isn't possible right now."; `note_consumed` → "A round has already read that note."; `empty_note` → "Write something first."; `unknown_intake` → "This intake is no longer on your Mac."; `unknown_checkpoint`, `unknown_block` → "The plan changed — reopen it and try again."; other → "Your Mac wouldn't do that (\(code))."
  - `FlightControlModel.commands(for id: UUID) -> IntakeCommandModel`; `FlightControlModel.init(fetcher:commander:receivedAt:)` (commander optional-weak; `FleetModel` passes `self`).

- [ ] **Step 1: Failing tests** with a `StubCommander` modelled on `SessionTimelinePromptTests.StubFleet` (records commands; can answer synchronously or later): in-flight set immediately then cleared on ack and `onAck` called; err sets the mapped message and clears in-flight; a synchronous `.disconnected` sets "Not connected…" (deadline still cancelled — no later timeout message); timeout (use `timeout: .milliseconds(50)` and `await` 150 ms) sets "Couldn't reach your Mac."; a duplicate in-flight action sends nothing; each send carries a fresh token (two sends → two distinct tokens in the recorded commands). `CommandCopy` table test for every listed code.
- [ ] **Step 2–4:** RED, implement, `./scripts/test-ios.sh`.
- [ ] **Step 5: Commit** `feat: send flight control commands from the phone and hear back`.

---

### Task 6: Pure phone models — transport keys, rounds ±, note drafts

**Files:**
- Create: `Sources/FlightDeckMobile/TransportKeys.swift`, `Sources/FlightDeckMobile/NoteComposer.swift`
- Test: `Tests/FlightDeckMobileTests/TransportKeysTests.swift`, `Tests/FlightDeckMobileTests/NoteComposerTests.swift`

**Interfaces:**
- Produces:
  - `struct TransportKey: Equatable, Identifiable { let id: String /* step|nextMajor|toReview|pause|stop */; let symbol: String; let caption: String; let enabled: Bool; let isDefault: Bool; let ack: String? /* "Pausing…" | "Stopping…" */; let accessibilityLabel: String }`
  - `enum TransportKeys { static func keys(detail: WireIntakeDetail, inFlight: Set<IntakeAction>) -> [TransportKey] /* [] unless steer == true && state == "shaping" && board.controls != nil */; static func stopConfirmation(detail: WireIntakeDetail) -> (title: String, message: String) }`
  - `struct RoundsControl: Equatable { let title: String /* "Refine ×5" */; let canTrim: Bool; let canExtend: Bool; let stage: String }`; `enum RoundsControlModel { static func make(detail: WireIntakeDetail, inFlight: Set<IntakeAction>) -> RoundsControl? }`
  - `enum NoteComposer { static let kinds: [(id: String, title: String)] /* comment Comment, question Question, mustChange Must change, replace Replace, delete Delete, highlight Highlight */; static func canAdd(kind: String, text: String) -> Bool; static func wire(kind: String) -> (kind: String, sendsImmediately: Bool) /* highlight → ("comment", true) */; static func notesAllowed(detail: WireIntakeDetail?) -> Bool /* steer == true && state == "shaping" */ }`
- Keys: symbols `pause.fill`, `forward.frame.fill`, `forward.end.fill`, `forward.end.alt.fill`, `stop.fill`; captions `PAUSE`, `STEP`, `MAJOR`, `REVIEW`, `STOP`; `isDefault` = key id == `board.defaultPlay`; enabled = id ∈ `controls.enabled` AND not blocked by in-flight (while `.tape("stop")` is in flight or `detail.halt == "stopping"`, every play key is disabled); `ack` = "Stopping…" on stop when `halt == "stopping"` or `.tape("stop")` in flight; "Pausing…" on pause when `halt == "pausing"` or `.tape("pause")` in flight. Stop confirmation: title "Stop the run?", message "\(nowName)'s work in progress is discarded. Landed rounds and your notes are kept." (nowName = `board.nowName`).
- RoundsControl: nil unless steer/shaping/controls with a `cycleName`; title "\(cycleName) ×\(cyclePlanned)"; `canTrim` = `controls.enabled.contains("trim") && trimStage != nil` and no `.tape("trim")` in flight; `canExtend` likewise; `stage` = extendStage ?? trimStage.

- [ ] **Step 1: Failing tests** covering: no keys without steer (Review Focus #1 — `testNoCommandIsSentWithoutSteer` asserts `keys == []` and `RoundsControlModel.make == nil` and `NoteComposer.notesAllowed == false` for a detail whose `steer == nil`); running → only pause/stop enabled; default dot on `nextMajor`; a pause in flight shows "Pausing…" on pause; halt "stopping" disables every play key and shows "Stopping…"; stop confirmation text verbatim; rounds control title and ± enablement; `NoteComposer.canAdd` (highlight always; others need non-blank), `wire("highlight") == ("comment", true)`, kinds order/titles verbatim.
- [ ] **Step 2–4:** RED, implement, test-ios.sh.
- [ ] **Step 5: Commit** `feat: decide the phone's transport keys, round controls and note drafts`.

---

### Task 7: Transport row, default play, Stop confirmation, rounds ±

**Files:**
- Modify: `Sources/FlightDeckMobile/BoardStrip.swift` (a `keys: [TransportKey]` input and callbacks `onKey: (String) -> Void`, `onDefault: (String) -> Void`; the transport row as the strip's bottom row, keys split by hairlines, symbol over a tiny mono caption, a dot over the default play key, the ack label replacing the symbol; long-press on a play key → `onDefault` with a haptic (`UIImpactFeedbackGenerator(style: .medium)`); Stop → `onKey("stop")` (the screen confirms)), `Sources/FlightDeckMobile/IntakeScreen.swift` (wire keys to `IntakeCommandModel`; Stop `.confirmationDialog` with `TransportKeys.stopConfirmation` and a destructive **Stop Run** button; Rounds section header shows `RoundsControl` title with − and + buttons (each ≥ 44 pt tap target, accessibility labels "Remove a \(stage) round" / "Add another \(stage) round") sending `.tape("trim")` / `.tape("extend")` with the stage; the command model's `message` shown as an inline caption under the strip with a dismiss ✕ (named font, orange); every ack triggers `model.refresh()` immediately).
- Keep: the strip's dimming/frozen behaviour; every key disabled when `frozenAt != nil` (disconnected).

- [ ] **Step 1:** Implement (no new unit tests — decisions are in Task 6). Commands built as:
  - key → `commands.send(.tape(id), command: { .intakeTape(id: intake, token: $0, command: id, stage: nil) }, onAck: { model.refresh() })`
  - default → `.defaultPlay(id)` / `.intakeDefaultPlay(id: intake, token: $0, mode: id)`
  - ± → `.tape("extend")` / `.intakeTape(…, command: "extend", stage: control.stage)`
- [ ] **Step 2:** `./scripts/build-ios.sh` (real build) and `./scripts/test-ios.sh`.
- [ ] **Step 3: Commit** `feat: steer a flight control run from the phone`.

---

### Task 8: Annotate the plan from the phone

**Files:**
- Modify: `Sources/FlightDeckMobile/SelectableProseView.swift` — generalise `onReply: ((String) -> Void)?` to `actions: [ProseAction]` where `struct ProseAction { let title: String; let systemImage: String; let perform: (String) -> Void }`; the edit menu appends one `UIAction` per action (empty → system menu only). `TimelineRow.swift` / the session timeline pass `[ProseAction(title: "Reply", systemImage: "arrowshape.turn.up.left", perform: onReply)]` so the timeline is unchanged.
- Create: `Sources/FlightDeckMobile/NoteSheet.swift` — half sheet: Cancel · "Note for next round" · Add; the quote (italic, accent bar) when present, or "About the whole plan" / "About this passage"; kind chips from `NoteComposer.kinds` (Highlight sends at once); a multi-line field (named font, dictation via keyboard); Add enabled per `NoteComposer.canAdd`. Keyboard: follow `docs/MOBILE-UI.md` / the composer's approach (`KeyboardOverlapReader`) if the sheet's field is covered at `.medium`; use `.presentationDetents([.medium, .large])`.
- Modify: `Sources/FlightDeckMobile/PlanReaderScreen.swift` —
  - prose segments pass `actions: [ProseAction(title: "Note…", systemImage: "text.bubble", perform: { quote in draft = NoteDraftTarget(block: block.index, quote: quote) })]` when `NoteComposer.notesAllowed(detail:)`;
  - every block gets a trailing `Menu` (icon `ellipsis.circle`, accessibility "Passage actions") with "Add note to this passage" (`NoteDraftTarget(block:, quote: nil)`) and, when notes exist, "Show N notes"; the existing notes button stays for notes-bearing blocks;
  - a footer button "Add a note to the whole plan" (`NoteDraftTarget(block: nil, quote: nil)`);
  - the notes sheet's pending (unconsumed) note cards get a **Delete** button → `IntakeCommandModel.send(.removeNote(noteID), command: { .intakeRemoveNote(id: intake, token: $0, noteID: noteID) }, onAck: reloadHead)`;
  - Add → `send(.note(noteID), command: { .intakeNote(id: intake, token: $0, noteID: noteID, kind: wireKind, text: text, checkpoint: block == nil && quote == nil && planWide ? nil : plan.checkpoint, block: block, quote: quote) }, onAck: reloadHead)`; while in flight, show the note as a pending card (italic "Sending…" is NOT allowed — use a grey "Not yet sent" caption until ack; on failure show the command model's message and keep the draft text so the maintainer can retry);
  - `reloadHead` = `flightControl.plan(intake, checkpoint: nil, changes: changes)` + detail refresh (head contract).
  - Checkpoint rule: a passage note carries the checkpoint the reader shows (`plan.checkpoint`); a plan-wide note sends `checkpoint: nil, block: nil`.
  - Only when `NoteComposer.notesAllowed(detail:)` (needs `flightControl.detailModel(for: intake).detail`); otherwise no Note… action, no menu items, no footer button (Phase-1 behaviour).
- Test: pure parts are covered by Task 6; add a `PlanReaderStyle`/`NoteDraftTarget` test only if you extract a decision (e.g. which checkpoint a draft carries) into a static — do so.

- [ ] **Step 1:** Implement. **Step 2:** build-ios.sh + test-ios.sh (the timeline's Reply tests must still pass). **Step 3: Commit** `feat: annotate a flight control plan from the phone`.

---

### Task 9: Renders, checklist, docs

- [ ] **Step 1: Renders** — extend `IntakeRenderHarness.swift` (gate `RENDER_INTAKE`, same mechanism as Phase 1 — read its header): the running strip with the transport row (light/dark/AX5); paused with the default dot; "Pausing…"; the Stop confirmation can't be rendered — render the keys with halt "stopping"; the Rounds header with ±; the note sheet (render `NoteSheet` directly) with a quote and with none; the reader with a pending note card. Write to `/tmp/claude-501/fc-renders-p2/`, restore the gate (`git diff project.yml` empty), OPEN every PNG and list defects per image in the report (do not fix views in this task; the controller routes them).
- [ ] **Step 2: `docs/MOBILE.md`** — continue the manual checklist numbering (check the real last number) with items that name failures: Pause from the phone (key reads "Pausing…" at once; the Mac's bar shows paused within 2 s; wrong: no feedback, or a second tap queues twice); Stop (confirmation names the round; Cancel does nothing; wrong: stops without asking); long-press sets the default (dot moves; the Mac's control bar dot moves too); ± on Refine (count changes on both ends; wrong: + offered on a finished stage); select a phrase with bold in it → Note… → Must change → Add (the Mac's notes rail shows the note on exactly that phrase; wrong: on another paragraph); a plan-wide note appears unanchored on the Mac; delete a pending note from the phone (gone on the Mac); disconnect mid-send (message "Couldn't reach your Mac." within ~10 s, draft kept); an older Mac (Phase 1 build) with this phone: no transport row, no Note… action. Update the count sentence under "A second checklist".
- [ ] **Step 3: Spec** — add "§11.2 Phase 2 as built" listing: `steer` gate; `WireControls` from the shared `TransportRules`; the four ops and refusal codes; token memory (16 per intake, validation before the token); `RenderedQuoteLocator` + whole-block fallback (`check=note_anchor_fallback`); the phone's `ProseAction` edit-menu generalisation; the passage menu replacing "tap a paragraph" (tap is selection's); plan-wide notes have no checkpoint.
- [ ] **Step 4: `docs/HANDOFF.md`** — extend the Flight Control mobile paragraph with Phase 2.
- [ ] **Step 5: Verification** — `./scripts/build.sh`, `./scripts/test-unit.sh`, `./scripts/build-ios.sh`, `./scripts/test-ios.sh`; paste tails.
- [ ] **Step 6: Commit** `docs: record flight control steering on the phone`.

---

## Self-review

- **Spec coverage (Phase 2 = §11 item 2):** §4.3 transport keys, default dot + long-press, ack labels, dimmed keys, Stop confirmation → Tasks 1, 6, 7; §4.4 Rounds ± shown only when the Mac can act → 1, 6, 7; §4.8 phrase notes, block notes, plan-wide note, six kinds, Highlight immediate, Delete pending → 2, 3, 6, 8; §6.5 tape/defaultPlay/note/removeNote rows with tokens and refusals → 3, 4; §6.6 anchoring with whole-block fallback + log → 2, 3; §8 immediate feedback, ack refresh, err rollback with words, 10 s timeout → 5, 7, 8; compatibility (older Mac) → 1 (`steer`), 6 (gate); §10.4 words guard already covers the phone; §10.6 checklist → 9.
- **Types:** `WireControls` fields match between Tasks 1, 6; `IntakeAction`/`IntakeCommandModel.send` signatures match between Tasks 5, 7, 8; the four `FleetCommand` cases' labels match between Tasks 4, 7, 8; `IntakeService.phone*` signatures match between Tasks 3, 4.
- **Review Focus:** each line names its test in the owning task (1→Task 6, 2→Task 3, 3→Tasks 1+3, 4→Tasks 2+3, 5→Task 9 checklist).
