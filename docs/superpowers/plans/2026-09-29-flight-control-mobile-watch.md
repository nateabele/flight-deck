# Flight Control on the phone — Phase 1 (Watch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone shows every Flight Control intake inline in the Sessions list with a live state pill and a "needs you" badge and banner, and opens any intake read-only: the pinned board strip, the agents at work, the landed rounds, round detail, and the plan (outline + reader with notes and "changes since previous").

**Architecture:** Intake **summaries** ride the existing sequenced snapshot — `WireProject.intakes` plus one new event, `project.intakes`, sent only to phones advertising the `flightControl` capability. The Mac keeps the last emitted summaries in a store-side cache that `FleetProjection` reads, so the drift oracle and the event log agree by construction; a coalesced refresh (on any store change, and a 60 s tick for retention) recomputes and emits diffs. The intake **detail** and the **plan** are request/reply (`intake.detail`, `intake.plan`), computed on the Mac from the desktop's own models (`BoardModel`, `LiveSeats`, `ConvergenceCellModel`, `ProgressSummary`, `PlanSection.effectivePlan`) with every now-dependent value replaced by a date, so an etag over the encoded detail is stable while nothing changes and the phone's 1.5 s poll of an idle intake costs a few dozen bytes. The phone renders; its decisions live in pure, unit-tested style types.

**Tech Stack:** Swift 5 (app) / Swift 6 (FleetKit, FlightDeckMobile), SwiftUI, XCTest, MarkdownUI (already a phone dependency), CryptoKit (etag).

**Spec:** `docs/superpowers/specs/2026-09-29-flight-control-mobile-design.md` (read §2–§4, §6.1–§6.3, §7, §9–§11 before any task). Terrain and hazards: `docs/FLIGHT-CONTROL-MOBILE-HANDOFF.md`.

## Global Constraints

- **Words (spec §3).** No user-visible string says bead/beads, Flywheel, or seat. Say task(s), Flight Control, agent. The `bead` preset reads **Single task**. Identifiers, wire keys and persisted keys may keep the old words. Task 12 adds the phone to the guard.
- **Honest data only.** No invented percentages, ETAs or cost. Clocks count up. Cost only when the harness reported it (`WireAgent.cost`).
- **Colour for exceptions only.** accent = live; amber = needs you / fallback / quiet ≥ 30 s / stalled ≥ 90 s / rate-limited / DIVERGING; red = failure. Verdict counts uncoloured.
- **Clocks** tick at 1 Hz from a local timer (`TimelineView(.periodic(from:by: 1))`), and drop to once a minute after 60 s when idle (paused/stopped). A disconnected phone **freezes** clocks at the moment the link was lost and marks them stale.
- **Reduce Motion:** the live-dot glow does not pulse; no animation is required anywhere in Phase 1.
- **Sizes relative, fonts named on every `Text`** (`docs/MOBILE-UI.md`). Monospace only for machine text: the strip, clocks, paths.
- **`Sources/FlightDeckMobile/` stays flat** — new files go directly in it, no subdirectories.
- **Wire enum cases are atomic:** a new `FleetEvent`/`FleetRequest`/`ServerFrame` case, its tag, encode, decode, and every exhaustive-switch arm land in ONE commit (Tasks 1 and 5).
- **Tests.** macOS: `./scripts/test-unit.sh` — runs the whole suite (~8 min) whatever you pass, and **exits 0 even on failures**: read the tail for `Executed N tests, with 0 failures` and `rg 'error:'` the output. iOS: `./scripts/test-ios.sh` (creates and deletes its own simulator). Touching `Sources/FleetKit` means running BOTH. Run tests in the foreground.
- **Builds.** `./scripts/build.sh` (macOS Debug), `./scripts/build-ios.sh` (read which branch it took — real build vs type-check fallback). Never launch a bundle from `DerivedData/`. Never `defaults delete`. Never loop `./scripts/smoke.sh`.
- **Shared checkout.** Work in a worktree (`superpowers:using-git-worktrees`); symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts` from the main checkout before building. Commit only your files by path; `git diff --cached --stat -- vendor` must be empty. quillmap mutators write to the main checkout from a worktree — use built-in Edit.
- **Commit style:** `feat: …` lowercase imperative, body = mechanism + evidence + rejected alternatives, trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Spec deltas (decided while planning; Task 12 writes them back into the spec)

1. `WireIntakeSummary` has no `version` field — the detail etag already gives the poll its cheap check, and a counter would need state the pure projection does not have.
2. The Mac computes the detail etag as SHA-256 over the encoded detail (with `servedAt` zeroed), not from file mtimes: every input is already in memory, and a hash cannot go stale the way hand-picked mtimes can.
3. `WireAgent` carries display strings the Mac already computes (`SeatRowModel` built at a fixed instant) plus the dates the phone needs for its own clock and quiet/stalled/rate-limit judgement; the thresholds move to FleetKit as `AgentActivityRules` (spec §6.2).
4. A round that failed without landing a checkpoint is not tappable on the board in Phase 1; its failure shows in the intake screen's Failure section.
5. Phase 1 renders waiting states read-only: questions listed, the recommendation shown, Review shows "Review and release on your Mac" — the forms are Phase 3.
6. The detail carries `servedAt`; the phone keeps `macClockOffset = servedAt − receivedAt` and adds it to its own clock, so Mac/phone clock skew never shows as a negative or jumping count.

## Review Focus

1. **Mac/phone clock skew.** A phone whose clock is 5 s behind the Mac must never show `-0:05` or a clock that jumps backwards when a poll lands → `ClockPolicy` clamps at 0 and applies `macClockOffset` (Task 7 test `testSkewedClockNeverGoesNegative`).
2. **An old phone paired to a new Mac.** A phone without the `flightControl` capability must never receive `project.intakes` — live or in a resume replay — or its socket dies → Task 3 tests both `broadcast(requiring:)` and the hello replay filter.
3. **A snapshot arriving after reconnect must not fire banners** for everything already waiting, but a genuine transition heard live must → Task 7 `BannerPolicy` tests: unknown previous → no banner; known not-attention → attention → banner; same attention → none; on the intake's own screen → none.
4. **Flight Control toggled on/off for a project on the Mac** must move the phone between "no intake rows" and "rows" without a drift assertion → Task 3 test `testTogglingFlightControlEmitsAndNeverDrifts`.
5. **A 30–50 KB plan with a note whose quote spans inline Markdown** (`**bold**`, `` `code` ``) must still land on its block, and a note whose quote vanished must show as detached, never crash or mis-pin → Task 4 test `testNoteQuotesLocateAcrossInlineMarkup`.

---

## File map

**FleetKit (shared, Swift 6, compiled for macOS and iOS):**
- Create `Sources/FleetKit/IntakeWire.swift` — every new `Wire*` intake type.
- Create `Sources/FleetKit/AgentActivityRules.swift` — the quiet/stalled thresholds shared by both ends.
- Modify `Sources/FleetKit/Wire.swift` (`WireProject.intakes`), `FleetEvent.swift`, `WireCoding.swift`, `SnapshotApplication.swift`, `FleetReplay.swift`, `PhoneLogs.swift` (`FleetCapability`), `TimelineFrames.swift` (`FleetRequest`), `Frames.swift` (`ServerFrame`), `FleetConnector.swift`, `FleetSocketServer.swift` (`broadcast(_:requiring:)`).

**Mac app:**
- Create `Sources/FlightDeck/Fleet/IntakeSummaryProjection.swift` — pure: intakes → summaries, per-project, retention, diff.
- Create `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift` — pure-ish: detail + etag.
- Create `Sources/FlightDeck/Fleet/IntakePlanProjection.swift` — pure: plan, outline, notes → blocks, block diff.
- Modify `Sources/FlightDeck/Fleet/FleetProjection.swift`, `Sources/FlightDeck/SessionStore.swift` (summary cache + refresh), `Sources/FlightDeck/Fleet/FleetService.swift` (capability filter, request arms, refresh start), `Sources/FlightDeck/Fleet/ControlScope.swift`, `Sources/FlightDeck/Intake/IntakeService.swift` (`needsAttention(_:)`), `Sources/FlightDeck/Intake/Planning/SeatRowModel.swift` (thresholds from FleetKit), `Sources/FlightDeckCLI/CLIOutput.swift`, `Sources/FlightDeckCLI/CLIRunner.swift`.

**Phone (flat):**
- Create `IntakeStyle.swift` (row + banner + clock pure types), `BoardStripModel.swift`, `AgentRowStyle.swift`, `RoundFacts.swift`, `OutlineStyle.swift`, `FlightControlModel.swift`, `IntakeDetailModel.swift`, `IntakeRoute.swift`, `IntakeRow.swift`, `AttentionBanner.swift`, `IntakeScreen.swift`, `BoardStrip.swift`, `AgentRow.swift`, `RoundDetailScreen.swift`, `ClarificationsScreen.swift`, `PlanOutlineScreen.swift`, `PlanReaderScreen.swift`.
- Modify `FleetModel.swift`, `FleetListScreen.swift`, `FlightDeckMobileApp.swift` (banner overlay).

**Tests:**
- macOS (`Tests/FlightDeckTests/`): `IntakeWireCodingTests.swift`, `IntakeSummaryProjectionTests.swift`, `IntakeFleetEmissionTests.swift`, `IntakeDetailProjectionTests.swift`, `IntakePlanProjectionTests.swift`, `IntakeRequestPlumbingTests.swift`; extend `FleetFrameCodingTests.swift`, `Intake/Planning/TerminologyGuardTests.swift`.
- iOS (`Tests/FlightDeckMobileTests/`): `IntakeStyleTests.swift`, `BoardStripModelTests.swift`, `AgentRowStyleTests.swift`, `RoundFactsTests.swift`, `OutlineStyleTests.swift`, `FlightControlModelTests.swift`, `IntakeRenderHarness.swift`.
- Docs: `docs/MOBILE.md` (checklist items), `docs/HANDOFF.md` (one paragraph), the spec (deltas).

---

### Task 1: Intake summaries on the wire (FleetKit, atomic)

**Files:**
- Create: `Sources/FleetKit/IntakeWire.swift`
- Modify: `Sources/FleetKit/Wire.swift:20-39`, `Sources/FleetKit/FleetEvent.swift:19-130`, `Sources/FleetKit/WireCoding.swift:6-22,25-33,37,121`, `Sources/FleetKit/SnapshotApplication.swift:12`, `Sources/FleetKit/FleetReplay.swift:102-122`, `Sources/FleetKit/PhoneLogs.swift:186-197`, `Sources/FlightDeckCLI/CLIOutput.swift:13` (the exhaustive `eventSession` switch)
- Test: `Tests/FlightDeckTests/IntakeWireCodingTests.swift`; extend `Tests/FlightDeckTests/FleetFrameCodingTests.swift:45-60` (`cases` array)

**Interfaces:**
- Produces: `public struct WireIntakeSummary` (fields below); `WireProject.intakes: [WireIntakeSummary]?`; `FleetEvent.projectIntakes(project: UUID, intakes: [WireIntakeSummary]?)`, tag `"project.intakes"`; `FleetCapability.flightControl == "flightControl"`, included in `FleetCapability.supported`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/IntakeWireCodingTests.swift`:

```swift
import XCTest
@testable import FleetKit

final class IntakeWireCodingTests: XCTestCase {
    static let summary = WireIntakeSummary(
        id: UUID(), title: "Offline sync for job tickets", state: "shaping",
        needsAttention: false, preset: "fullPlan", now: "Refine 2", runStatus: "running",
        clockSince: Date(timeIntervalSinceReferenceDate: 800_000_000),
        agentsDone: 1, agentsTotal: 2, createdAt: Date(timeIntervalSinceReferenceDate: 799_000_000)
    )

    func testProjectIntakesRoundTripsWithItsDottedTag() throws {
        let event = FleetEvent.projectIntakes(project: UUID(), intakes: [Self.summary])
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"project.intakes\""), json)
    }

    func testProjectIntakesWithNilOmitsTheKey() throws {
        // nil = Flight Control not enabled for the project: absent, never `null`, so the
        // phone's `decodeIfPresent` reads exactly what an older Mac would send.
        let data = try JSONEncoder().encode(FleetEvent.projectIntakes(project: UUID(), intakes: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["intakes"])
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data),
                       .projectIntakes(project: try XCTUnwrap(UUID(uuidString: json["project"] as! String)), intakes: nil))
    }

    func testProjectIntakesNamesItsProjectAndNoSession() {
        let project = UUID()
        let event = FleetEvent.projectIntakes(project: project, intakes: [])
        XCTAssertEqual(event.projectID, project)
        XCTAssertNil(event.sessionID)
    }

    func testProjectIntakesReplacesTheProjectsListOnTheSnapshot() {
        let project = WireProject(id: UUID(), name: "larkOS", path: "/w/larkOS")
        var snapshot = FleetSnapshot(projects: [project])
        snapshot.apply(.projectIntakes(project: project.id, intakes: [Self.summary]))
        XCTAssertEqual(snapshot.projects[0].intakes, [Self.summary])
        snapshot.apply(.projectIntakes(project: project.id, intakes: nil))
        XCTAssertNil(snapshot.projects[0].intakes)
        // An unknown project is ignored, like every other project event.
        let before = snapshot
        snapshot.apply(.projectIntakes(project: UUID(), intakes: []))
        XCTAssertEqual(snapshot, before)
    }

    func testAProjectFromAnOlderMacDecodesWithNoIntakes() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"a","path":"/a","isCollapsed":false,"sessions":[]}"#
        let project = try JSONDecoder().decode(WireProject.self, from: Data(old.utf8))
        XCTAssertNil(project.intakes)
    }

    func testAnUnknownStateStringStillDecodes() throws {
        var summary = Self.summary
        summary.state = "someFutureState"
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeSummary.self, from: data).state, "someFutureState")
    }

    func testThePhoneAdvertisesFlightControl() {
        XCTAssertEqual(FleetCapability.flightControl, "flightControl")
        XCTAssertTrue(FleetCapability.supported.contains(FleetCapability.flightControl))
    }
}
```

Add `.projectIntakes(project: UUID(), intakes: [])` and `.projectIntakes(project: UUID(), intakes: nil)` to the `cases: [FleetEvent]` array in `FleetFrameCodingTests.testEveryEventCaseRoundTrips` (`FleetFrameCodingTests.swift:45-60`).

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build failure — `cannot find 'WireIntakeSummary' in scope`, `type 'FleetEvent' has no member 'projectIntakes'`.

- [ ] **Step 3: Implement**

`Sources/FleetKit/IntakeWire.swift` (start the file; Task 2 appends to it):

```swift
import Foundation

/// One Flight Control intake as the Sessions list shows it — the coarse, sequenced part of the
/// phone's view of Flight Control (spec §6.1).
///
/// **Coarse on purpose.** Nothing here moves at agent-activity rate: it changes on a state
/// transition, a round starting or landing, an agent finishing, pause/resume, and release. The
/// live detail is `WireIntakeDetail`, fetched by request while a screen is open — putting it
/// here would record an event every two seconds per agent into the replay ring.
///
/// State-like values are `String`s, never enums: a state added on the Mac later must render
/// degraded on an older phone, not throw and end its socket.
public struct WireIntakeSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// `IntakeTitle.lead`, computed on the Mac so both ends cut the intent identically.
    public var title: String
    /// `IntakeState` raw value.
    public var state: String
    /// The Mac's own rule (`IntakeService.needsAttention(_:)`), never re-derived on the phone.
    public var needsAttention: Bool
    /// `Preset` raw value (`bead` reads "Single task" on screen).
    public var preset: String?
    /// The board's NOW name — "Refine 2", "Clarify 1", "Triage", "Review".
    public var now: String?
    /// `RunnerStatus` raw value while shaping.
    public var runStatus: String?
    /// When the current in-the-air or paused-for interval started (Mac clock).
    public var clockSince: Date?
    /// The round in flight only.
    public var agentsDone: Int?
    public var agentsTotal: Int?
    /// `needsAnswers` only: the open round's question count.
    public var questionCount: Int?
    /// `released`/`partiallyReleased` only.
    public var releasedTaskCount: Int?
    /// Orders "newest first" within a group on the phone.
    public var createdAt: Date

    public init(
        id: UUID, title: String, state: String, needsAttention: Bool, preset: String? = nil,
        now: String? = nil, runStatus: String? = nil, clockSince: Date? = nil,
        agentsDone: Int? = nil, agentsTotal: Int? = nil, questionCount: Int? = nil,
        releasedTaskCount: Int? = nil, createdAt: Date
    ) {
        self.id = id; self.title = title; self.state = state; self.needsAttention = needsAttention
        self.preset = preset; self.now = now; self.runStatus = runStatus; self.clockSince = clockSince
        self.agentsDone = agentsDone; self.agentsTotal = agentsTotal
        self.questionCount = questionCount; self.releasedTaskCount = releasedTaskCount
        self.createdAt = createdAt
    }
}
```

`Wire.swift` — add to `WireProject` (synthesized `Codable` decodes an `Optional` with `decodeIfPresent`, so an older Mac's snapshot still decodes):

```swift
    /// This project's Flight Control intakes (spec §6.1). **nil** when Flight Control is not
    /// enabled for the project — no rows and no + on the phone; `[]` when enabled with none.
    /// Optional so a snapshot from a Mac that predates it decodes (synthesized `Codable`
    /// reads an `Optional` with `decodeIfPresent`).
    public var intakes: [WireIntakeSummary]?
```
and give `init` a trailing `intakes: [WireIntakeSummary]? = nil` parameter assigned to it.

`FleetEvent.swift` — add after `projectsReordered`:

```swift
    /// The whole intake list for one project, replacing the previous one (nil: Flight Control
    /// turned off there). Sent only to peers that advertise `FleetCapability.flightControl`:
    /// an older phone's decoder throws on an unknown tag and would drop the socket.
    case projectIntakes(project: UUID, intakes: [WireIntakeSummary]?)
```
In `sessionID` add `.projectIntakes` to the `return nil` list; in `projectID` add `case .projectIntakes(let id, _): return id` (join the `.projectRemoved(let id)…` arm).

`WireCoding.swift` — `FleetEventTag`: `case projectIntakes = "project.intakes"`; `CodingKeys`: add `intakes`; encode arm:

```swift
        case .projectIntakes(let project, let intakes):
            try c.encode(FleetEventTag.projectIntakes, forKey: .t)
            try c.encode(project, forKey: .project)
            // Absent, not `null`, for nil — see `WireProject.intakes`.
            try c.encodeIfPresent(intakes, forKey: .intakes)
```
decode arm:

```swift
        case .projectIntakes:
            self = .projectIntakes(project: try c.decode(UUID.self, forKey: .project),
                                   intakes: try c.decodeIfPresent([WireIntakeSummary].self, forKey: .intakes))
```
(`.project` is already a CodingKey, used by `sessionAdded`.)

`SnapshotApplication.swift` — in `apply(_:)`:

```swift
        case .projectIntakes(let id, let intakes):
            guard let p = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[p].intakes = intakes
```

`FleetReplay.swift` — add `case intakes(UUID)` to `FoldKey`, and in `key(_:)`:

```swift
        // Same rationale as `.activity`: a list that changed five times inside one resume gap
        // is only real in its last form by the time a reconnecting phone sees it.
        case .projectIntakes(let id, _): return .intakes(id)
```

`PhoneLogs.swift` — in `FleetCapability`:

```swift
    /// This peer understands Flight Control: the `project.intakes` event and the `intake.*`
    /// requests. Unlike `logs` it is a claim about what the peer can DECODE, not answer — the
    /// Mac withholds `project.intakes` from any peer without it (spec §6).
    public static let flightControl = "flightControl"
```
and `public static let supported = [logs, flightControl]`.

`CLIOutput.swift:13` — in the exhaustive `eventSession` switch, add `.projectIntakes` to the arm that returns `nil` for project-level events.

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -40` — expect `with 0 failures`; `rg 'error:'` on the output finds nothing.
Run: `./scripts/test-ios.sh 2>&1 | tail -20` — FleetKit compiles for iOS; expect `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/IntakeWire.swift Sources/FleetKit/Wire.swift Sources/FleetKit/FleetEvent.swift Sources/FleetKit/WireCoding.swift Sources/FleetKit/SnapshotApplication.swift Sources/FleetKit/FleetReplay.swift Sources/FleetKit/PhoneLogs.swift Sources/FlightDeckCLI/CLIOutput.swift Tests/FlightDeckTests/IntakeWireCodingTests.swift Tests/FlightDeckTests/FleetFrameCodingTests.swift
git commit -m "feat: carry flight control intake summaries on the fleet wire"
```

---

### Task 2: Detail, plan and activity-rule wire types (FleetKit)

Types only — no enum cases, so no switch arms; the request cases that carry them are Task 5.

**Files:**
- Modify: `Sources/FleetKit/IntakeWire.swift` (append)
- Create: `Sources/FleetKit/AgentActivityRules.swift`
- Modify: `Sources/FlightDeck/Intake/Planning/SeatRowModel.swift:403-407` (`SeatThresholds` defaults come from FleetKit)
- Test: extend `Tests/FlightDeckTests/IntakeWireCodingTests.swift`

**Interfaces:**
- Produces (all `public`, `Codable, Equatable, Sendable`, memberwise `public init` with defaults for optionals):
  - `WireIntakeDetail { etag: String; project: UUID; summary: WireIntakeSummary; intent: String; progress: [WireProgressPhase]; board: WireBoard?; agents: [WireAgent]; rounds: [WireRound]; questions: WireQuestions?; choice: WireChoice?; failure: WireFailure?; pendingNotes: Int; halt: String?; headCheckpoint: Int?; servedAt: Date }`
  - `WireProgressPhase { label: String; detail: String }`
  - `WireBoard { slots: [WireSlot]; nowName: String; nowChip: String; clockCaption: String; clockSince: Date?; clockText: String?; stopsAt: String; stopSlotID: String?; callingAt: String; convergence: WireConvergence?; defaultPlay: String }`
  - `WireSlot { id: String; name: String; code: String; state: String /* done|live|future|failed */; major: Bool; group: String?; checkpoint: Int?; duration: TimeInterval?; flagged: Bool }`
  - `WireConvergence { word: String; amber: Bool; spark: [Double] }`
  - `WireAgent { id: String; glyph: String /* queued|running|done|failed|fallback|needsYou */; role: String; identity: String; headline: String?; action: String?; steps: String?; contextFraction: Double?; footprint: [WireFootprint]; result: String?; cost: Double?; startedAt: Date?; lastEventAt: Date?; rateLimitedAt: Date?; duration: TimeInterval?; fallback: String?; failure: String? }`
  - `WireFootprint { dir: String; count: Int }`
  - `WireRound { checkpoint: Int; name: String; code: String; stage: String; startedAt: Date?; landedAt: Date; outcome: String /* ok|fallback|failed */; changeCount: Int?; linesAdded: Int; linesRemoved: Int; verdicts: WireVerdicts?; note: String?; sectionsChanged: [String]; agents: [WireRoundAgent]; notesConsumed: [WireNote] }`
  - `WireVerdicts { agreed: Int; somewhat: Int; declined: Int }`
  - `WireRoundAgent { role: String; ran: String; status: String /* ok|substituted|failed */; detail: String? }`
  - `WireNote { id: UUID; kind: String; text: String; quote: String?; section: String?; consumed: Bool; blockIndex: Int? }`
  - `WireQuestions { open: [String]?; answered: [WireExchange] }`, `WireExchange { questions: [String]; answers: [String] }`
  - `WireChoice { recommended: String?; reason: String?; chosen: String?; roundsSummary: String? }`
  - `WireFailure { reason: String; output: String? }`
  - `WireIntakePlan { checkpoint: Int; roundName: String; editsVersion: String; markdown: String; outline: [WireSection]; notes: [WireNote]; added: [Int]?; removed: [WireRemovedBlock]? }`
  - `WireSection { heading: String; level: Int; blockIndex: Int; churn: [Int]; diverging: Bool; settledSince: String? }`
  - `WireRemovedBlock { after: Int?; text: String }`
  - `public enum AgentActivityRules { public static let quiet: TimeInterval = 30; public static let stalled: TimeInterval = 90 }`

- [ ] **Step 1: Write the failing test**

Append to `IntakeWireCodingTests`:

```swift
    func testADetailRoundTripsEveryNestedType() throws {
        let note = WireNote(id: UUID(), kind: "mustChange", text: "Not enough.",
                            quote: "Require explicit proof", section: "7. Model-credential paths",
                            consumed: false, blockIndex: 14)
        let detail = WireIntakeDetail(
            etag: "abc", project: UUID(), summary: Self.summary, intent: "Build it.",
            progress: [WireProgressPhase(label: "Triage", detail: "3:40")],
            board: WireBoard(
                slots: [WireSlot(id: "refine-2", name: "Refine 2", code: "RF2", state: "live",
                                 major: false, group: "REFINE", checkpoint: nil, duration: nil, flagged: false)],
                nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: "IN THE AIR",
                clockSince: Self.summary.clockSince, clockText: nil, stopsAt: "Encode",
                stopSlotID: "encode-0", callingAt: "2 · Polish 6 · Review",
                convergence: WireConvergence(word: "CONVERGING ↘", amber: false, spark: [41, 14]),
                defaultPlay: "nextMajor"),
            agents: [WireAgent(id: "refine-2-reviewer", glyph: "running", role: "reviewer",
                               identity: "codex · gpt-6-sol · high", headline: "Checking §7",
                               action: "Reading broker.ts", footprint: [WireFootprint(dir: "beacon", count: 3)],
                               startedAt: Self.summary.clockSince)],
            rounds: [WireRound(checkpoint: 3, name: "Refine 1", code: "RF1", stage: "refine",
                               startedAt: nil, landedAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
                               outcome: "ok", changeCount: 41, linesAdded: 620, linesRemoved: 180,
                               verdicts: WireVerdicts(agreed: 33, somewhat: 6, declined: 2), note: nil,
                               sectionsChanged: ["7. Model-credential paths"],
                               agents: [WireRoundAgent(role: "reviewer", ran: "codex · gpt-6-sol · high", status: "ok", detail: nil)],
                               notesConsumed: [note])],
            questions: WireQuestions(open: nil, answered: [WireExchange(questions: ["Both?"], answers: ["Both"])]),
            choice: nil, failure: nil, pendingNotes: 1, halt: nil, headCheckpoint: 3,
            servedAt: Date(timeIntervalSinceReferenceDate: 800_000_200))
        let data = try JSONEncoder().encode(detail)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakeDetail.self, from: data), detail)
    }

    func testAPlanRoundTrips() throws {
        let plan = WireIntakePlan(
            checkpoint: 3, roundName: "Refine 1", editsVersion: "", markdown: "# P\n\n## 1. A\n\nText.",
            outline: [WireSection(heading: "1. A", level: 2, blockIndex: 1, churn: [4, 0],
                                  diverging: false, settledSince: "Refine 1")],
            notes: [], added: [2], removed: [WireRemovedBlock(after: 1, text: "Old text.")])
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(WireIntakePlan.self, from: data), plan)
    }

    func testActivityThresholdsMatchTheDesktop() {
        XCTAssertEqual(AgentActivityRules.quiet, 30)
        XCTAssertEqual(AgentActivityRules.stalled, 90)
    }
```

Add to an existing macOS app test (e.g. append to `IntakeWireCodingTests` with `@testable import FlightDeck` at the top of the file):

```swift
    func testTheDesktopRowsUseTheSharedThresholds() {
        XCTAssertEqual(SeatThresholds.default.quiet, AgentActivityRules.quiet)
        XCTAssertEqual(SeatThresholds.default.stalled, AgentActivityRules.stalled)
    }
```

- [ ] **Step 2: Run to verify it fails** — `./scripts/test-unit.sh 2>&1 | tail -30`; expected: `cannot find 'WireIntakeDetail' in scope`.

- [ ] **Step 3: Implement**

Append the types in the Interfaces block to `IntakeWire.swift`, each as a `public struct … : Codable, Equatable, Sendable` with a memberwise `public init` whose optional parameters default to `nil`, arrays to `[]`, `Bool` to `false`. Doc-comment each type in one or two lines naming what it mirrors on the Mac (`WireBoard` → `BoardModel`; `WireAgent` → `SeatRowModel` built at a fixed instant; `WireRound` → `Checkpoint` + `RoundRecord`; `WireNote` → `PlanNote`, `kind` is `NoteKind` raw value; `WireIntakePlan.added/removed` → block-level diff against the parent checkpoint, nil when not asked). Give `WireIntakeDetail` this comment:

```swift
/// Everything the intake screen shows, fetched by `FleetRequest.intakeDetail` and polled while
/// the screen is open (spec §6.2). **Nothing here depends on the Mac's clock** except
/// `servedAt`: running clocks travel as start DATES, so the encoded detail — and its `etag` —
/// stays byte-identical while nothing happens, and an idle poll costs a few dozen bytes.
```

`Sources/FleetKit/AgentActivityRules.swift`:

```swift
import Foundation

/// How long an agent may look idle before its row says quiet, then stalled (planning-UI spec
/// §6). Shared so the Mac's rows and the phone's say the same thing about the same agent at the
/// same moment — named constants, not tuned against real runs yet.
public enum AgentActivityRules {
    public static let quiet: TimeInterval = 30
    public static let stalled: TimeInterval = 90
}
```

`SeatRowModel.swift:403-407`:

```swift
struct SeatThresholds: Equatable {
    var quiet: TimeInterval = AgentActivityRules.quiet
    var stalled: TimeInterval = AgentActivityRules.stalled
    static let `default` = SeatThresholds()
}
```
(add `import FleetKit` at the top of `SeatRowModel.swift` if the file does not already have it).

- [ ] **Step 4: Run to verify it passes** — `./scripts/test-unit.sh` (0 failures) and `./scripts/test-ios.sh` (`TEST SUCCEEDED`).

- [ ] **Step 5: Commit** — `git add` the three files + test; `git commit -m "feat: add the intake detail and plan wire types"`.

---

### Task 3: Project summaries on the Mac, emitted only to capable phones

**Files:**
- Create: `Sources/FlightDeck/Fleet/IntakeSummaryProjection.swift`
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift:403-435` (add `needsAttention(_:)`), `Sources/FlightDeck/SessionStore.swift` (cache + refresh + recording), `Sources/FlightDeck/Fleet/FleetProjection.swift:41-64` (read the cache), `Sources/FleetKit/FleetSocketServer.swift:635-640` (`broadcast(_:requiring:)`), `Sources/FlightDeck/Fleet/FleetService.swift:353-359` (filter live events), `FleetService.handleHello` (filter replay), `FleetService.init` (start the refresh)
- Test: `Tests/FlightDeckTests/IntakeSummaryProjectionTests.swift`, `Tests/FlightDeckTests/IntakeFleetEmissionTests.swift`

**Interfaces:**
- Consumes: `WireIntakeSummary`, `FleetEvent.projectIntakes`, `FleetCapability.flightControl` (Task 1).
- Produces:
  - `enum IntakeSummaryProjection { static func summary(_ intake: Intake, tape: Tape?, seats: SeatFiles?, needsAttention: Bool) -> WireIntakeSummary; static func summaries(for intakes: [Intake], service: IntakeService, now: Date) -> [WireIntakeSummary]; static let releasedRetention: TimeInterval = 3 * 24 * 3600; static func isListed(_ intake: Intake, now: Date) -> Bool; static func changes(from old: [UUID: [WireIntakeSummary]?], to new: [UUID: [WireIntakeSummary]?]) -> [FleetEvent] }`
  - `IntakeService.needsAttention(_ intake: Intake) -> Bool`
  - `SessionStore.intakeSummaries: [Repo.ID: [WireIntakeSummary]?]` (read-only outside), `SessionStore.refreshIntakeSummaries()`, `SessionStore.startIntakeSummaries()`
  - `FleetSocketServer.broadcast(_ frame: ServerFrame, requiring capability: String?)`
  - `FleetService.requiredCapability(for event: FleetEvent) -> String?` (static), `FleetService.deliverable(_ frames: [ServerFrame], caps: Set<String>) -> [ServerFrame]` (static)

**Design notes for the implementer (read before coding):**
- `FleetProjection` is the drift oracle (`FleetReplicator.checkForDrift`). If it computed intakes live from `IntakeService`, any intake change the store did not record as an event — and the Flight Control toggle, which lives in preferences — would trip `assertionFailure` in DEBUG. So the projection reads **`store.intakeSummaries`, a cache that only `refreshIntakeSummaries()` writes, and that writes it in the same call that records the event**. Drift is impossible by construction; staleness is bounded by the refresh triggers.
- **Triggers:** `SessionStore.objectWillChange` (the store already forwards `IntakeService` and `PreferencesStore` into it — `SessionStore.swift:1335`, `:1929`), coalesced to one refresh per main-queue turn and run on the NEXT turn (`objectWillChange` fires before the change lands); plus a 60 s tick for the 3-day retention. The cache is a plain stored property — not `@Published` — so recording cannot re-trigger itself.
- **Run names** on disk are `<stage>-<round>-<role>…` (`draft-0-drafter-0`, `refine-1-reviewer`, `synthesis-0-integrator`); the round in flight's agents are `LiveSeats.rows(round:config:seats:now:)`'s output, which already knows this.

- [ ] **Step 1: Write the failing projection tests**

`Tests/FlightDeckTests/IntakeSummaryProjectionTests.swift`:

```swift
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
final class IntakeSummaryProjectionTests: XCTestCase {
    private func intake(_ state: IntakeState, intent: String = "Add a crew calendar. Then more.") -> Intake {
        var i = Intake(projectPath: "/w/larkOS", intent: intent, createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        i.state = state
        return i
    }

    func testTheTitleIsTheDesktopsLead() {
        let s = IntakeSummaryProjection.summary(intake(.triaging), tape: nil, seats: nil, needsAttention: false)
        XCTAssertEqual(s.title, IntakeTitle(intent: "Add a crew calendar. Then more.").lead)
        XCTAssertEqual(s.state, "triaging")
        XCTAssertEqual(s.now, "Triage")
    }

    func testNeedsAnswersCarriesTheOpenQuestionCount() {
        var i = intake(.needsAnswers)
        i.exchanges = [TriageExchange(questions: ["a", "b"], answers: ["x", "y"]),
                       TriageExchange(questions: ["c", "d", "e"])]
        let s = IntakeSummaryProjection.summary(i, tape: nil, seats: nil, needsAttention: true)
        XCTAssertEqual(s.questionCount, 3)
        XCTAssertEqual(s.now, "Clarify 2")
        XCTAssertTrue(s.needsAttention)
    }

    func testShapingCarriesTheRoundInFlightAndItsStart() {
        var i = intake(.shaping)
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        var tape = Tape()
        tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        tape.roundStartedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        let s = IntakeSummaryProjection.summary(i, tape: tape, seats: nil, needsAttention: false)
        XCTAssertEqual(s.now, "Refine 2")
        XCTAssertEqual(s.runStatus, "running")
        XCTAssertEqual(s.clockSince, tape.roundStartedAt)
        XCTAssertEqual(s.preset, "fullPlan")
    }

    func testReleasedIntakesAreListedForThreeDaysThenLeave() {
        var i = intake(.released)
        let released = Date(timeIntervalSinceReferenceDate: 10_000)
        i.release = ReleaseRecord(releasedAt: released, appliedSteps: 1, idMap: ["a": "fd-1", "b": "fd-2"])
        XCTAssertTrue(IntakeSummaryProjection.isListed(i, now: released.addingTimeInterval(3 * 24 * 3600 - 1)))
        XCTAssertFalse(IntakeSummaryProjection.isListed(i, now: released.addingTimeInterval(3 * 24 * 3600 + 1)))
        XCTAssertEqual(IntakeSummaryProjection.summary(i, tape: nil, seats: nil, needsAttention: false).releasedTaskCount, 2)
    }

    func testDiscardedIntakesAreNeverListed() {
        XCTAssertFalse(IntakeSummaryProjection.isListed(intake(.discarded), now: Date()))
    }

    func testChangesEmitOnlyForProjectsWhoseListDiffers() {
        let a = UUID(), b = UUID()
        let s = IntakeSummaryProjection.summary(intake(.triaging), tape: nil, seats: nil, needsAttention: false)
        let events = IntakeSummaryProjection.changes(from: [a: [s], b: nil], to: [a: [s], b: []])
        XCTAssertEqual(events, [.projectIntakes(project: b, intakes: [])])
    }
}
```

If `ReleaseRecord`'s memberwise init needs more arguments than the test passes, use its real public init (`Sources/IntakeKit/Intake.swift:48-56`) with empty values for the rest. Likewise `Tape()` — use its public init with defaults (`Tape.swift:195`).

- [ ] **Step 2: Run to verify it fails** — `./scripts/test-unit.sh 2>&1 | tail -30`; expected `cannot find 'IntakeSummaryProjection'`.

- [ ] **Step 3: Implement the projection and `needsAttention(_:)`**

`IntakeService.swift` — beside `attentionCount(forProject:)`:

```swift
    /// The ONE attention rule — the sidebar's count, the phone's badge and banner all read it,
    /// so an intake cannot need you on one surface and not the other.
    func needsAttention(_ i: Intake) -> Bool {
        i.state.needsAttention || shapingNeedsAttention(i)
    }
```
and change `attentionCount` to `intakes(forProject: path).filter(needsAttention).count`.

`Sources/FlightDeck/Fleet/IntakeSummaryProjection.swift`:

```swift
import FleetKit
import Foundation
import IntakeKit

/// Intakes → the phone's coarse list rows (spec §6.1). Pure: no I/O, no clock of its own.
enum IntakeSummaryProjection {
    /// Released intakes stay on the phone's list this long (the maintainer, 2026-09-29), then leave it.
    static let releasedRetention: TimeInterval = 3 * 24 * 3600

    static func isListed(_ i: Intake, now: Date) -> Bool {
        switch i.state {
        case .discarded: return false
        case .released:
            guard let at = i.release?.releasedAt else { return true }
            return now.timeIntervalSince(at) <= releasedRetention
        default: return true
        }
    }

    static func summary(_ i: Intake, tape: Tape?, seats: SeatFiles?, needsAttention: Bool) -> WireIntakeSummary {
        var s = WireIntakeSummary(
            id: i.id, title: IntakeTitle(intent: i.intent).lead, state: i.state.rawValue,
            needsAttention: needsAttention, preset: (i.chosenPreset ?? i.recommended)?.rawValue,
            createdAt: i.createdAt)
        switch i.state {
        case .triaging:
            s.now = "Triage"
        case .needsAnswers:
            s.now = "Clarify \(i.exchanges.count)"
            s.questionCount = i.exchanges.last?.questions.count
        case .awaitingChoice, .parked:
            s.now = "Ready"
        case .review, .releasing:
            s.now = "Review"
        case .released, .partiallyReleased:
            s.now = "Review"
            s.releasedTaskCount = i.release?.idMap.count
        case .shaping, .failed, .interrupted, .discarded:
            break
        }
        if let tape, i.state == .shaping || i.state == .failed || i.state == .interrupted {
            s.runStatus = tape.status.rawValue
            if let round = tape.roundInProgress {
                s.now = BoardModel.name(stage: round.stage, round: round.round)
            } else if let head = tape.head {
                s.now = BoardModel.name(stage: head.stage, round: head.round)
            }
            switch tape.status {
            case .running: s.clockSince = tape.roundStartedAt ?? tape.head?.createdAt
            case .failed: s.clockSince = tape.failedAt
            case .idle, .paused, .stopped: s.clockSince = tape.head?.createdAt
            case .reachedReview: s.clockSince = nil
            }
            if tape.status == .running, let round = tape.roundInProgress, let seats {
                // `.distantPast`: the row's done/failed glyph does not depend on the clock, and
                // using it keeps this function free of `now`.
                let rows = LiveSeats.rows(round: round, config: i.roundConfig, seats: seats, now: .distantPast)
                s.agentsTotal = rows.count
                s.agentsDone = rows.filter { $0.model.glyph == .done || $0.model.glyph == .failed }.count
            }
        }
        return s
    }

    @MainActor
    static func summaries(for intakes: [Intake], service: IntakeService, now: Date) -> [WireIntakeSummary] {
        intakes.filter { isListed($0, now: now) }.map { i in
            summary(i, tape: service.tapes[i.id], seats: service.files(i.id), needsAttention: service.needsAttention(i))
        }
    }

    /// One `projectIntakes` per project whose list differs, in the new map's key order sorted
    /// by uuid string so a test can compare arrays. A project present in `old` but gone from
    /// `new` emits nothing — `projectRemoved` already took it off the phone.
    static func changes(from old: [UUID: [WireIntakeSummary]?], to new: [UUID: [WireIntakeSummary]?]) -> [FleetEvent] {
        new.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let next = new[id] ?? nil
            let previous = old[id] ?? nil
            return next == previous && old[id] != nil ? nil : .projectIntakes(project: id, intakes: next)
        }
    }
}
```

Note the `old[id] != nil` clause: a project never emitted before (first refresh, new project) always emits once, even for nil, so the cache and the mirror agree from the start. Add a test for it:

```swift
    func testAProjectNeverEmittedBeforeEmitsOnceEvenWhenNil() {
        let a = UUID()
        XCTAssertEqual(IntakeSummaryProjection.changes(from: [:], to: [a: nil]),
                       [.projectIntakes(project: a, intakes: nil)])
        XCTAssertEqual(IntakeSummaryProjection.changes(from: [a: nil], to: [a: nil]), [])
    }
```

If `BoardModel.name(stage:round:)`, `LiveSeats`, `SeatFiles` or `IntakeService.files(_:)` are `private`/`fileprivate`, widen them to internal (default access) — nothing else changes.

- [ ] **Step 4: Run** — the projection tests pass.

- [ ] **Step 5: Write the failing emission tests**

`Tests/FlightDeckTests/IntakeFleetEmissionTests.swift` — model the store set-up on `Tests/FlightDeckTests/Intake/ProjectViewIntakeListLiveTests.swift:36-52` and the replicator on `FleetEmissionHarness.attachedReplicator(to:)` (whose `onDrift` fails the test):

```swift
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
final class IntakeFleetEmissionTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeFleetEmission-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> (SessionStore, PreferencesStore, Repo) {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        return (store, prefs, store.repos[0])
    }

    private func enable(_ prefs: PreferencesStore, _ repo: Repo, _ on: Bool) {
        var settings = prefs.projectSettings(repo.url.path)
        settings.flywheelEnabled = on ? true : nil
        prefs.setProjectSettings(repo.url.path, settings)
    }

    func testTogglingFlightControlEmitsAndNeverDrifts() {
        let (store, prefs, repo) = makeStore()
        let replicator = attachedReplicator(to: store)   // XCTFails on drift
        var seen: [FleetEvent] = []
        replicator.onEvents = { seen += $0.map(\.event) }

        store.refreshIntakeSummaries()
        XCTAssertEqual(seen.last, .projectIntakes(project: repo.id, intakes: nil))

        enable(prefs, repo, true)
        store.refreshIntakeSummaries()
        XCTAssertEqual(seen.last, .projectIntakes(project: repo.id, intakes: []))
        XCTAssertEqual(FleetProjection.snapshot(of: store).projects[0].intakes, [])

        let count = seen.count
        store.refreshIntakeSummaries()   // nothing changed
        XCTAssertEqual(seen.count, count)

        enable(prefs, repo, false)
        store.refreshIntakeSummaries()
        XCTAssertEqual(seen.last, .projectIntakes(project: repo.id, intakes: nil))
    }

    func testANewIntakeReachesTheWire() throws {
        let (store, prefs, repo) = makeStore()
        _ = attachedReplicator(to: store)
        enable(prefs, repo, true)
        var i = Intake(projectPath: repo.url.standardizedFileURL.path, intent: "Plan the thing")
        i.state = .needsAnswers
        i.exchanges = [TriageExchange(questions: ["Which README?"])]
        try IntakeStore(root: root).save(i)
        store.intakeService.pollTapes()           // loads intakes from disk, as the live test does
        store.refreshIntakeSummaries()
        let listed = try XCTUnwrap(FleetProjection.snapshot(of: store).projects[0].intakes)
        XCTAssertEqual(listed.map(\.id), [i.id])
        XCTAssertTrue(listed[0].needsAttention)
    }

    func testOnlyCapablePeersGetIntakeEvents() {
        XCTAssertEqual(FleetService.requiredCapability(for: .projectIntakes(project: UUID(), intakes: [])),
                       FleetCapability.flightControl)
        XCTAssertNil(FleetService.requiredCapability(for: .projectCollapsed(id: UUID(), isCollapsed: true)))
    }

    func testTheHelloReplayDropsIntakeEventsForAnOldPhone() {
        let frames: [ServerFrame] = [
            .event(seq: 1, .projectCollapsed(id: UUID(), isCollapsed: true)),
            .event(seq: 2, .projectIntakes(project: UUID(), intakes: [])),
            .snapshot(seq: 2, fleet: .empty, reason: .initial),
        ]
        XCTAssertEqual(FleetService.deliverable(frames, caps: []).count, 2)
        XCTAssertEqual(FleetService.deliverable(frames, caps: [FleetCapability.flightControl]).count, 3)
    }
}
```

If `store.intakeService.pollTapes()` does not load newly-saved intakes, use whatever `ProjectViewIntakeListLiveTests` does to make the service see a seeded intake (it seeds before creating the service) — reorder so the intake is saved **before** the first touch of `store.intakeService`.

Add one `FleetSocketServer` test beside the existing loopback tests (`Tests/FlightDeckTests/FleetRequestPlumbingTests.swift` has a loopback server + client pattern): attach one client with `caps: []` and one with `caps: [FleetCapability.flightControl]`, `server.broadcast(.event(seq: 1, .projectIntakes(project: UUID(), intakes: [])), requiring: FleetCapability.flightControl)`, and assert only the capable client's connector sees the event (use its `onEvent`) while the other's socket stays connected (its `state` is still `.connected` 500 ms later).

- [ ] **Step 6: Run to verify they fail** — missing `refreshIntakeSummaries`, `requiredCapability`, `deliverable`, `broadcast(_:requiring:)`.

- [ ] **Step 7: Implement the store cache, refresh, and filtering**

`SessionStore.swift` — near `var replicator`:

```swift
    /// The Flight Control summaries last RECORDED on the fleet wire, per project — nil when
    /// Flight Control is off there. `FleetProjection` reads this, never `IntakeService`
    /// directly: the projection is the replicator's drift oracle, and an intake change (or the
    /// Flight Control toggle, which lives in preferences) that reached it without an event
    /// would trip the drift assertion. Written ONLY by `refreshIntakeSummaries()`, in the same
    /// call that records the event, so the two cannot disagree. Plain, not `@Published`:
    /// recording must not re-trigger the refresh that caused it.
    private(set) var intakeSummaries: [Repo.ID: [WireIntakeSummary]?] = [:]
    private var intakeRefreshScheduled = false
    private var intakeRefreshForward: AnyCancellable?
    private var lastIntakeRetentionTick = Date.distantPast

    func refreshIntakeSummaries() {
        let now = Date()
        var next: [Repo.ID: [WireIntakeSummary]?] = [:]
        for repo in repos {
            guard preferences?.projectSettings(repo.url.path).flywheelEnabled == true else {
                next[repo.id] = .some(nil); continue
            }
            let intakes = intakeService.intakes(forProject: repo.url.path)
            next[repo.id] = IntakeSummaryProjection.summaries(for: intakes, service: intakeService, now: now)
        }
        let events = IntakeSummaryProjection.changes(from: intakeSummaries, to: next)
        intakeSummaries = next
        emit(events)
    }

    /// Called once by `FleetService` after it installs the replicator. Coalesces every store
    /// change (the store already forwards `IntakeService` and preferences into
    /// `objectWillChange`) into one refresh on the NEXT main-queue turn — `objectWillChange`
    /// fires before the change lands — plus a 60 s tick so a released intake ages out.
    func startIntakeSummaries() {
        refreshIntakeSummaries()
        intakeRefreshForward = objectWillChange.sink { [weak self] _ in self?.scheduleIntakeRefresh() }
        clock.add(IntakeRetentionTicker.shared) { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastIntakeRetentionTick) >= 60 else { return }
            self.lastIntakeRetentionTick = Date()
            self.scheduleIntakeRefresh()
        }
    }

    private func scheduleIntakeRefresh() {
        guard !intakeRefreshScheduled else { return }
        intakeRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.intakeRefreshScheduled = false
            self.refreshIntakeSummaries()
        }
    }
```

`WatchClock.add(_:_:)` keys subscribers by owner identity (`WatchClock.swift:95-99`), so registering the store itself would replace any registration the store already has. Add at file scope:

```swift
/// A distinct owner for the retention tick on the shared `WatchClock`, which keys subscribers
/// by object identity — registering the store itself would replace its other registration.
final class IntakeRetentionTicker { static let shared = IntakeRetentionTicker() }
```
If more than one `SessionStore` exists in a test process, give each store its own ticker instance (a stored `let intakeRetentionTicker = IntakeRetentionTicker()`) instead of `shared` — prefer that; it is what the code above should use. Add `import FleetKit` to `SessionStore.swift` if missing.

`FleetProjection.swift` — in `project(_ repo:…)` pass the cache through: add a parameter `intakes: [WireIntakeSummary]? = nil` and set `intakes: intakes` on the `WireProject`; in `snapshot(of:)` pass `intakes: store.intakeSummaries[$0.id] ?? nil`.

`FleetSocketServer.swift`:

```swift
    /// `requiring`: only connections whose `hello` claimed that capability get the frame. An
    /// older phone throws on an event tag it does not know and drops the socket, so a new
    /// event must never reach one; the phone does not check `seq` gaps, so skipping is safe.
    public func broadcast(_ frame: ServerFrame, requiring capability: String? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        for (id, connection) in attached {
            if let capability, caps[id]?.contains(capability) != true { continue }
            FleetSocket.send(frame, over: connection)
        }
    }
```
(replace the existing `broadcast(_:)`; the default keeps every other caller unchanged.)

`FleetService.swift`:

```swift
    /// Which capability a peer must have claimed to be sent this event (spec §6).
    static func requiredCapability(for event: FleetEvent) -> String? {
        if case .projectIntakes = event { return FleetCapability.flightControl }
        return nil
    }

    /// `hello` replies with the capability filter applied — a resume replay must not hand an
    /// older phone the event `broadcast(_:requiring:)` withholds live.
    static func deliverable(_ frames: [ServerFrame], caps: Set<String>) -> [ServerFrame] {
        frames.filter { frame in
            guard case .event(_, let event) = frame, let needed = requiredCapability(for: event) else { return true }
            return caps.contains(needed)
        }
    }
```
In `replicator.onEvents` (`:353-359`): `let needed = Self.requiredCapability(for: entry.event)` and call `broadcast(.event(seq: entry.seq, entry.event), requiring: needed)` on both servers. In the `server.onHello` closure (`:375-378`): `return Self.deliverable(self.handleHello(attachment, lastSeq), caps: attachment.caps)`. At the end of `init`, after `store.replicator = replicator` (`:157`) and the `onEvents` wiring, call `store.startIntakeSummaries()`.

- [ ] **Step 8: Run** — `./scripts/test-unit.sh` (0 failures — this also re-runs every existing fleet emission test under the new projection field) and `./scripts/test-ios.sh`.

- [ ] **Step 9: Commit** — all touched files + both test files; `git commit -m "feat: project flight control summaries onto the fleet wire for capable phones"`. Body: the cache-as-oracle reasoning and the rejected alternative (projecting live, which drifts on the preferences toggle).

---

### Task 4: Detail and plan projections on the Mac (pure)

**Files:**
- Create: `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift`, `Sources/FlightDeck/Fleet/IntakePlanProjection.swift`
- Test: `Tests/FlightDeckTests/IntakeDetailProjectionTests.swift`, `Tests/FlightDeckTests/IntakePlanProjectionTests.swift`
- Fixture: `Tests/FlightDeckTests/Fixtures/sample-plan.md`, a long synthetic plan shaped like a real one (numbered items with **bold**, `code`, links). Never copy a real intake plan into the repo — they are private. `Fixtures/**` is excluded from the test target's sources (project.yml), so load it via `#filePath`.

**Interfaces:**
- Consumes: Task 2 types; `IntakeSummaryProjection.summary` (Task 3); `IntakeService` state (`tapes`, `files(_:)`, `triageActivities`, `convergence`, `halts`, `pending`, `checkpointFile(_:checkpoint:_:)`, `needsAttention(_:)`); `BoardModel(intake:tape:config:now:selected:preview:)`; `LiveSeats.rows(round:config:seats:now:)` / `LiveSeats.files(_:pending:)`; `SeatRowModel.make(...)`; `ConvergenceCellModel(cycles:plannedRounds:)`; `ProgressSummary.line(intake:tape:triage:loadFile:)`; `RoundConfigEditor.summary(preset:config:)`; `PlanSection.effectivePlan(checkpoint:tape:loadFile:)` / `PlanSection.planHead(tape:loadFile:)`; `ConvergenceSeries.sectionChurn`/`label`; `PlanBlocks.split`.
- Produces:
  - `enum IntakeDetailProjection { @MainActor static func detail(_ id: UUID, project: UUID, service: IntakeService, servedAt: Date) -> WireIntakeDetail?; static func etag(_ detail: WireIntakeDetail) -> String; static func agent(_ model: SeatRowModel, activity: SeatActivity?) -> WireAgent; static func round(_ checkpoint: Checkpoint) -> WireRound; static let failureOutputLimit = 4096 }`
  - `enum IntakePlanProjection { static func outline(markdown: String, blocks: PlanBlocks, churn: [[String: Int]], divergingSection: String?) -> [WireSection]; static func locate(_ note: PlanNote, consumed: Bool, in blocks: PlanBlocks) -> WireNote; static func blockDiff(current: PlanBlocks, parent: PlanBlocks) -> (added: [Int], removed: [WireRemovedBlock]); @MainActor static func plan(_ id: UUID, checkpoint: Int?, changes: Bool, service: IntakeService) -> WireIntakePlan? }`

- [ ] **Step 1: Write the failing plan-projection tests** (`IntakePlanProjectionTests.swift`):

```swift
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

final class IntakePlanProjectionTests: XCTestCase {
    private let markdown = """
    # Plan

    ## 1. Product contract

    Keep **account sign-in** in scope and `vault` keys.

    ## 7. Credential paths

    1. Require explicit proof that the chosen mode permits hosted execution.
    2. Run requests through [Beacon's gateway](https://x.test).
    """

    func testOutlineListsSecondLevelHeadingsWithTheirBlocks() {
        let blocks = PlanBlocks.split(markdown)
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: [], divergingSection: nil)
        XCTAssertEqual(outline.map(\.heading), ["1. Product contract", "7. Credential paths"])
        XCTAssertEqual(outline.map(\.level), [2, 2])
        for section in outline {
            XCTAssertTrue(blocks.blocks[section.blockIndex].text.hasPrefix("## "), section.heading)
        }
    }

    func testChurnIsPerRoundAndTheDivergingSectionIsFlagged() {
        let blocks = PlanBlocks.split(markdown)
        let churn: [[String: Int]] = [
            [ConvergenceSeries.label("7. Credential paths"): 12, ConvergenceSeries.label("1. Product contract"): 3],
            [ConvergenceSeries.label("7. Credential paths"): 9],
        ]
        let outline = IntakePlanProjection.outline(markdown: markdown, blocks: blocks, churn: churn,
                                                   divergingSection: "7. Credential paths")
        XCTAssertEqual(outline[0].churn, [3, 0])
        XCTAssertEqual(outline[1].churn, [12, 9])
        XCTAssertFalse(outline[0].diverging)
        XCTAssertTrue(outline[1].diverging)
    }

    func testNoteQuotesLocateAcrossInlineMarkup() {
        let blocks = PlanBlocks.split(markdown)
        let bold = PlanNote(kind: .comment, note: "x",
                            anchor: NoteAnchor(checkpoint: 1, quote: "Keep account sign-in in scope and vault keys."))
        let link = PlanNote(kind: .question, note: "y",
                            anchor: NoteAnchor(checkpoint: 1, quote: "through Beacon's gateway"))
        let gone = PlanNote(kind: .delete, note: "z", anchor: NoteAnchor(checkpoint: 1, quote: "a sentence that no longer exists"))
        let planWide = PlanNote(kind: .comment, note: "overall", anchor: nil)
        let located = [bold, link, gone, planWide].map { IntakePlanProjection.locate($0, consumed: false, in: blocks) }
        XCTAssertTrue(blocks.blocks[located[0].blockIndex!].text.contains("account sign-in"))
        XCTAssertTrue(blocks.blocks[located[1].blockIndex!].text.contains("Beacon"))
        XCTAssertNil(located[2].blockIndex, "a vanished quote is detached, never mis-pinned")
        XCTAssertNil(located[3].blockIndex)
        XCTAssertEqual(located[1].kind, "question")
    }

    func testNotesLocateInTheRealLarkOSPlan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample-plan.md")
        let plan = try String(contentsOf: url, encoding: .utf8)
        let blocks = PlanBlocks.split(plan)
        let note = PlanNote(kind: .mustChange, note: "n",
                            anchor: NoteAnchor(checkpoint: 2, quote: "Require explicit proof that the chosen mode permits hosted and unattended execution"))
        let located = IntakePlanProjection.locate(note, consumed: false, in: blocks)
        XCTAssertNotNil(located.blockIndex)
    }

    func testBlockDiffNamesAddedAndRemovedBlocks() {
        let parent = PlanBlocks.split("# P\n\nA.\n\nB.\n\nC.")
        let current = PlanBlocks.split("# P\n\nA.\n\nB2.\n\nC.")
        let diff = IntakePlanProjection.blockDiff(current: current, parent: parent)
        XCTAssertEqual(diff.added.map { current.blocks[$0].text }, ["B2."])
        XCTAssertEqual(diff.removed, [WireRemovedBlock(after: 1, text: "B.")])
    }
}
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `IntakePlanProjection`**

```swift
import FleetKit
import Foundation
import IntakeKit

/// A checkpoint's plan as the phone reads it (spec §6.3). Block indices are
/// `PlanBlocks.split(markdown)` — the same function the phone runs, so an index names the same
/// block on both ends.
enum IntakePlanProjection {
    static func outline(markdown: String, blocks: PlanBlocks, churn: [[String: Int]],
                        divergingSection: String?) -> [WireSection] {
        blocks.blocks.compactMap { block -> WireSection? in
            let line = block.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let hashes = line.prefix { $0 == "#" }.count
            guard (2...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            let heading = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
            let key = ConvergenceSeries.label(heading)
            let perRound = churn.map { $0[key] ?? 0 }
            let settled = perRound.lastIndex { $0 > 0 }.map { $0 + 1 < perRound.count ? "Round \($0 + 1)" : nil } ?? nil
            let diverging = divergingSection.map { ConvergenceSeries.label($0) == key } ?? false
            return WireSection(heading: heading, level: hashes, blockIndex: block.index,
                               churn: perRound, diverging: diverging, settledSince: settled)
        }
    }

    /// Whitespace runs to one space and inline markers (`**`, `*`, `_`, `` ` ``, `[text](url)` →
    /// text) removed — how rendered text a person selected compares to the source it came from.
    static func normalized(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`", "*", "_"] { t = t.replacingOccurrences(of: marker, with: "") }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func locate(_ note: PlanNote, consumed: Bool, in blocks: PlanBlocks) -> WireNote {
        let quote = note.anchor?.quote
        let index = quote.flatMap { q -> Int? in
            let needle = normalized(q)
            guard !needle.isEmpty else { return nil }
            return blocks.blocks.first { normalized($0.text).contains(needle) }?.index
        }
        return WireNote(id: note.id, kind: note.kind.rawValue, text: note.note, quote: quote,
                        section: note.anchor?.section, consumed: consumed, blockIndex: index)
    }

    static func blockDiff(current: PlanBlocks, parent: PlanBlocks) -> (added: [Int], removed: [WireRemovedBlock]) {
        let before = Set(parent.blocks.map(\.text)), after = Set(current.blocks.map(\.text))
        let added = current.blocks.filter { !before.contains($0.text) }.map(\.index)
        var removed: [WireRemovedBlock] = []
        var lastSurvivor: Int?
        for block in parent.blocks {
            if after.contains(block.text) {
                lastSurvivor = current.blocks.first { $0.text == block.text }?.index
            } else {
                removed.append(WireRemovedBlock(after: lastSurvivor, text: block.text))
            }
        }
        return (added, removed)
    }

    @MainActor
    static func plan(_ id: UUID, checkpoint requested: Int?, changes: Bool, service: IntakeService) -> WireIntakePlan? {
        guard service.intakes.contains(where: { $0.id == id }) else { return nil }
        let tape = service.storedTape(id)
        let load: (Int, String) -> Data? = { service.checkpointFile(id, checkpoint: $0, $1) }
        guard let checkpointID = requested ?? PlanSection.planHead(tape: tape, loadFile: load),
              let checkpoint = tape.checkpoints.first(where: { $0.id == checkpointID }),
              let markdown = PlanSection.effectivePlan(checkpoint: checkpointID, tape: tape, loadFile: load)
        else { return nil }
        let blocks = PlanBlocks.split(markdown)
        let cycle = service.convergence[id]?.last
        let churn = cycle?.points.filter { $0.checkpoint <= checkpointID }.map(\.sectionChurn) ?? []
        let diverging: String? = {
            if case .diverging(.hotSection(let s)) = cycle?.verdict { return s }
            if case .diverging(.reopened(let s)) = cycle?.verdict { return s }
            return nil
        }()
        let consumed = tape.checkpoints.flatMap(\.record.annotations)
        let notes = consumed.map { locate($0, consumed: true, in: blocks) }
            + tape.pendingNotes.map { locate($0, consumed: false, in: blocks) }
        var added: [Int]?, removed: [WireRemovedBlock]?
        if changes, let parentID = checkpoint.parent,
           let parentText = PlanSection.effectivePlan(checkpoint: parentID, tape: tape, loadFile: load) {
            (added, removed) = blockDiff(current: blocks, parent: PlanBlocks.split(parentText))
        }
        let edits = load(checkpointID, PlanLayers.userName).map { IntakeDetailProjection.hash($0) } ?? ""
        return WireIntakePlan(checkpoint: checkpointID, roundName: BoardModel.name(stage: checkpoint.stage, round: checkpoint.round),
                              editsVersion: edits, markdown: markdown,
                              outline: outline(markdown: markdown, blocks: blocks, churn: churn, divergingSection: diverging),
                              notes: notes, added: added, removed: removed)
    }
}
```

If `ConvergenceCycle.points`' element type does not carry `sectionChurn` keyed by `ConvergenceSeries.label(heading)`, read how `ChurnLaneModel(cycle:section:)` (`ConvergenceCellModel.swift:234`) looks a heading up and use exactly that key. The test `testChurnIsPerRoundAndTheDivergingSectionIsFlagged` pins the behaviour, not the key.

- [ ] **Step 4: Run** — the plan-projection tests pass.

- [ ] **Step 5: Write the failing detail-projection tests** (`IntakeDetailProjectionTests.swift`). Build an `IntakeService` exactly as `Tests/FlightDeckTests/Intake/IntakeServiceLiveTests.swift:71-134` does (copy its `FakeRunnerController`, `makeService`, `seed`, `updateTape`, `writeSeat` helpers into this file as `private`):

```swift
    func testAShapingDetailCarriesBoardAgentsAndRoundsWithNoClockInIt() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { tape in
            tape.status = .running
            tape.roundInProgress = PlannedRound(stage: .draft, round: 0, major: true)
            tape.roundStartedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        }
        var activity = SeatActivity(harness: .claude, startedAt: Date(timeIntervalSinceReferenceDate: 5_001))
        activity.headline = "Reading the repo"
        activity.lastEventAt = Date(timeIntervalSinceReferenceDate: 5_010)
        try writeSeat(i.id, run: "draft-0-drafter-0", activity: activity, record: nil)
        let svc = await makeService()
        svc.pollTapes()

        let a = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 6_000)))
        let b = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: a.project, service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 9_000)))
        XCTAssertEqual(a.etag, b.etag, "nothing changed but the time: the etag must not move")
        XCTAssertEqual(a.board?.clockSince, Date(timeIntervalSinceReferenceDate: 5_000))
        XCTAssertEqual(a.board?.clockCaption, "IN THE AIR")
        XCTAssertNil(a.board?.slots.first { $0.state == "live" }?.duration, "a live slot's duration is the phone's clock")
        let agent = try XCTUnwrap(a.agents.first { $0.id == "draft-0-drafter-0" })
        XCTAssertEqual(agent.headline, "Reading the repo")
        XCTAssertEqual(agent.lastEventAt, activity.lastEventAt)
        XCTAssertNil(agent.duration)
    }

    func testTheEtagMovesWhenAnAgentReportsSomethingNew() async throws { /* same seed, detail, then writeSeat with a new headline, pollTapes, detail again: etags differ */ }

    func testNeedsAnswersCarriesOpenAndAnsweredRounds() async throws {
        var i = try seed(.needsAnswers)
        i.exchanges = [TriageExchange(questions: ["Both?"], answers: ["Both"]), TriageExchange(questions: ["Who?", "Where?"])]
        try IntakeStore(root: root).save(i)
        let svc = await makeService()
        let d = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(d.questions?.open, ["Who?", "Where?"])
        XCTAssertEqual(d.questions?.answered, [WireExchange(questions: ["Both?"], answers: ["Both"])])
    }

    func testAFailureTailIsCappedAtFourKilobytes() async throws {
        var i = try seed(.failed)
        i.failure = "codex exited 1"
        i.rawFailureOutput = String(repeating: "x", count: 10_000) + "THE END"
        try IntakeStore(root: root).save(i)
        let svc = await makeService()
        let d = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(d.failure?.reason, "codex exited 1")
        XCTAssertEqual(d.failure?.output?.utf8.count, IntakeDetailProjection.failureOutputLimit)
        XCTAssertTrue(d.failure?.output?.hasSuffix("THE END") == true, "the TAIL is kept")
    }

    func testAnUnknownIntakeIsNil() async {
        let svc = await makeService()
        XCTAssertNil(IntakeDetailProjection.detail(UUID(), project: UUID(), service: svc, servedAt: Date()))
    }
```
Write out `testTheEtagMovesWhenAnAgentReportsSomethingNew` in full following the first test (the comment names every step).

- [ ] **Step 6: Run to verify they fail.**

- [ ] **Step 7: Implement `IntakeDetailProjection`**

```swift
import CryptoKit
import FleetKit
import Foundation
import IntakeKit

/// The intake screen's content (spec §6.2), built from the desktop's own models so the phone
/// and the Mac describe the same moment the same way. Every now-dependent value is a DATE:
/// board clocks travel as `clockSince`, agent rows are built at `.distantPast` (no quiet, no
/// stalled, no running elapsed) and carry their dates instead, and a live slot has no duration.
/// So the encoded detail is byte-identical while nothing happens, which is what the etag needs.
enum IntakeDetailProjection {
    static let failureOutputLimit = 4096

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func etag(_ detail: WireIntakeDetail) -> String {
        var d = detail
        d.etag = ""
        d.servedAt = .distantPast
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return hash((try? encoder.encode(d)) ?? Data())
    }

    static func agent(_ model: SeatRowModel, activity: SeatActivity?) -> WireAgent {
        let glyph: String = switch model.glyph {
        case .queued: "queued"
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        case .fallback: "fallback"
        case .needsYou: "needsYou"
        }
        var fallback: String?, failure: String?
        switch model.exception {
        case .fallback(let text): fallback = text
        case .failed(let text): failure = text
        default: break
        }
        let finished = model.glyph == .done || model.glyph == .failed
        return WireAgent(
            id: model.id, glyph: glyph, role: model.role, identity: model.identity,
            headline: model.headline, action: model.action, steps: model.steps,
            contextFraction: model.contextFraction,
            footprint: model.footprint.map { WireFootprint(dir: $0.dir, count: $0.count) },
            result: model.result, cost: model.cost,
            startedAt: activity?.startedAt, lastEventAt: activity?.lastEventAt,
            rateLimitedAt: finished ? nil : activity?.rateLimitedAt,
            duration: finished ? model.elapsed : nil, fallback: fallback, failure: failure)
    }

    static func round(_ c: Checkpoint) -> WireRound {
        let slots = c.record.slots
        let outcome = slots.contains { $0.status == .failed } ? "failed"
            : slots.contains { $0.status == .substituted } ? "fallback" : "ok"
        return WireRound(
            checkpoint: c.id, name: BoardModel.name(stage: c.stage, round: c.round),
            code: BoardModel.code(stage: c.stage, round: c.round), stage: c.stage.rawValue,
            startedAt: c.startedAt, landedAt: c.createdAt, outcome: outcome,
            changeCount: c.record.changeCount, linesAdded: c.record.linesAdded, linesRemoved: c.record.linesRemoved,
            verdicts: c.record.tally.map { WireVerdicts(agreed: $0.agree, somewhat: $0.somewhat, declined: $0.disagree) },
            note: c.record.note, sectionsChanged: c.record.sectionsChanged,
            agents: slots.map { s in
                WireRoundAgent(role: s.role, ran: "\(s.used.harness.rawValue) · \(s.used.model) · \(s.used.effort)",
                               status: s.status.rawValue, detail: s.diagnosis?.detail)
            },
            notesConsumed: c.record.annotations.map { IntakePlanProjection.locate($0, consumed: true, in: PlanBlocks(blocks: [])) })
    }

    @MainActor
    static func detail(_ id: UUID, project: UUID, service: IntakeService, servedAt: Date) -> WireIntakeDetail? {
        guard let i = service.intakes.first(where: { $0.id == id }) else { return nil }
        let tape = service.tapes[id]
        let summary = IntakeSummaryProjection.summary(i, tape: tape, seats: service.files(id),
                                                      needsAttention: service.needsAttention(i))
        let load: (Int, String) -> Data? = { service.checkpointFile(id, checkpoint: $0, $1) }
        let progress = tape.map { ProgressSummary.line(intake: i, tape: $0, triage: service.triageActivities[id], loadFile: load) } ?? []

        var board: WireBoard?
        var agents: [WireAgent] = []
        if let tape, let config = i.roundConfig {
            let model = BoardModel(intake: i, tape: tape, config: config, now: .distantPast, selected: nil, preview: nil)
            board = Self.board(model, tape: tape, config: config, cycles: service.convergence[id])
            if let round = tape.roundInProgress ?? pendingRound(service.pending[id]) {
                let seats = LiveSeats.files(service.files(id), pending: service.pending[id])
                agents = LiveSeats.rows(round: round, config: config, seats: seats, now: .distantPast)
                    .map { agent($0.model, activity: seats.activities[$0.model.id]) }
            }
        } else if i.state == .triaging {
            let activity = service.triageActivities[id]
            var model = SeatRowModel.make(run: "triage", slot: nil, requested: nil, activity: activity,
                                          record: nil, roundRecord: nil, now: .distantPast)
            if model.glyph == .running, model.headline == nil { model.headline = "Reading the repo" }
            agents = [agent(model, activity: activity)]
        }

        let answered = i.exchanges.compactMap { e in e.answers.map { WireExchange(questions: e.questions, answers: $0) } }
        let open = i.state == .needsAnswers ? i.exchanges.last.flatMap { $0.answers == nil ? $0.questions : nil } : nil
        let choice: WireChoice? = i.state == .awaitingChoice ? WireChoice(
            recommended: i.recommended?.rawValue, reason: i.recommendationReason, chosen: i.chosenPreset?.rawValue,
            roundsSummary: (i.chosenPreset ?? i.recommended).flatMap { p in i.roundConfig.map { RoundConfigEditor.summary(preset: p, config: $0) } }
        ) : nil
        let failure: WireFailure? = i.failure.map { reason in
            WireFailure(reason: reason, output: i.rawFailureOutput.map { String($0.utf8.suffix(failureOutputLimit)) ?? "" })
        }
        let halt: String? = service.halts[id].map { $0.kind == .pause ? "pausing" : "stopping" }

        var detail = WireIntakeDetail(
            etag: "", project: project, summary: summary, intent: i.intent,
            progress: progress.map { WireProgressPhase(label: $0.label, detail: $0.detail) },
            board: board, agents: agents,
            rounds: (tape?.checkpoints ?? []).reversed().map(round),
            questions: i.exchanges.isEmpty ? nil : WireQuestions(open: open, answered: answered),
            choice: choice, failure: failure, pendingNotes: tape?.pendingNotes.count ?? 0, halt: halt,
            headCheckpoint: tape.flatMap { PlanSection.planHead(tape: $0, loadFile: load) }, servedAt: servedAt)
        detail.etag = etag(detail)
        return detail
    }

    private static func pendingRound(_ p: PendingStart?) -> PlannedRound? {
        if case .round(let round)? = p?.kind { return round }
        return nil
    }

    static func board(_ m: BoardModel, tape: Tape, config: RoundConfig, cycles: [ConvergenceCycle]?) -> WireBoard {
        let (caption, since, text): (String, Date?, String?) = switch tape.status {
        case .running: ("IN THE AIR", tape.roundStartedAt ?? tape.head?.createdAt, nil)
        case .failed: ("HALTED FOR", tape.failedAt, nil)
        case .reachedReview: ("TOTAL", nil, m.inTheAir.value)
        case .idle, .paused, .stopped: ("PAUSED FOR", tape.head?.createdAt, nil)
        }
        let cell = cycles.flatMap { ConvergenceCellModel(cycles: $0) }
        return WireBoard(
            slots: m.slots.map { s in
                let state: String = switch s.state {
                case .done, .selected: "done"
                case .live: "live"
                case .future: "future"
                case .failed: "failed"
                }
                return WireSlot(id: s.id, name: s.name, code: s.code, state: state, major: s.major, group: s.group,
                                checkpoint: s.checkpointID, duration: s.state == .live ? nil : s.duration, flagged: s.flagged)
            },
            nowName: m.now.value, nowChip: m.nowChip, clockCaption: caption, clockSince: since, clockText: text,
            stopsAt: m.stopsAt.value, stopSlotID: m.stopSlotID, callingAt: m.callingAt.value,
            convergence: cell.map { WireConvergence(word: $0.word, amber: $0.tone == .amber, spark: $0.spark) },
            defaultPlay: config.defaultPlay.rawValue)
    }
}
```

Two things to check against the real code, and to pin with the tests you already wrote rather than assume:
- `BoardModel(... now: .distantPast ...)`: if a field you send (`now.value`, `stopsAt.value`, `callingAt.value`, slot `duration` for non-live slots) turns out to depend on `now`, the etag test fails — fix by sending the date instead, like `clockSince`, never by removing the etag test.
- `String(i.rawFailureOutput.utf8.suffix(...))` returns an optional when the cut lands mid-scalar; the `?? ""` keeps the test honest — if the test fails on byte count, trim to a scalar boundary by walking back from the cut until `String(Substring.UTF8View)` succeeds, and assert `<= failureOutputLimit` plus the suffix instead. Update the test's `XCTAssertEqual` to `XCTAssertLessThanOrEqual` in that case and say so in the commit.

- [ ] **Step 8: Run** — `./scripts/test-unit.sh`: 0 failures.

- [ ] **Step 9: Commit** — `git commit -m "feat: project an intake's detail and plan for the phone"` (both source files, both tests, the fixture).

---

### Task 5: `intake.detail` and `intake.plan` requests end to end (atomic)

**Files:**
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequest`: cases, `CodingKeys`, `Op`, encode `:217`, decode `:251`), `Sources/FleetKit/Frames.swift` (`ServerFrame`: cases, `CodingKeys`, `Tag`, encode `:626`, decode `:688`, `correlationID` `:748-755`), `Sources/FleetKit/FleetConnector.swift` (two request methods, pending tables, resolvers, `apply` arms `:595+`, `.err` routing `:644+`, `drainPending` `:869-908`), `Sources/FlightDeck/Fleet/FleetService.swift:497` (`handleRequest` arms), `Sources/FlightDeck/Fleet/ControlScope.swift:115`, `Sources/FlightDeckCLI/CLIRunner.swift:503`
- Test: `Tests/FlightDeckTests/IntakeRequestPlumbingTests.swift`; extend `TimelineFrameCodingTests.swift`, `FleetFrameCodingTests.swift`

**Interfaces:**
- Consumes: Task 2 types; `IntakeDetailProjection.detail`, `IntakePlanProjection.plan` (Task 4).
- Produces:
  - `FleetRequest.intakeDetail(id: UUID, ifNot: String?)` op `"intake.detail"`; `FleetRequest.intakePlan(id: UUID, checkpoint: Int?, changes: Bool)` op `"intake.plan"`
  - `ServerFrame.intakeDetail(cid: Int, WireIntakeDetail?)` tag `"intakeDetail"` (nil = unchanged since `ifNot`); `ServerFrame.intakePlan(cid: Int, WireIntakePlan)` tag `"intakePlan"`
  - `FleetConnector.requestIntakeDetail(id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void)`; `FleetConnector.requestIntakePlan(id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void)`
  - Refusal codes: `unknown_intake`, `unknown_checkpoint`.

- [ ] **Step 1: Write the failing tests**

Coding tests (append to `TimelineFrameCodingTests`):

```swift
    func testTheIntakeDetailRequestRoundTrips() throws {
        let frame = ClientFrame.req(cid: 11, .intakeDetail(id: UUID(), ifNot: "abc"))
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["op"] as? String, "intake.detail")
    }

    func testTheIntakePlanRequestRoundTripsWithAndWithoutACheckpoint() throws {
        for request in [FleetRequest.intakePlan(id: UUID(), checkpoint: 3, changes: true),
                        .intakePlan(id: UUID(), checkpoint: nil, changes: false)] {
            let frame = ClientFrame.req(cid: 12, request)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: JSONEncoder().encode(frame)), frame)
        }
    }
```
Append to `FleetFrameCodingTests` (use `fields(of:)`, `:9-12`):

```swift
    func testIntakeRepliesRoundTripCarryNoSeqAndDoNotLookLikeEvents() throws {
        let frames: [ServerFrame] = [
            .intakeDetail(cid: 3, nil),
            .intakePlan(cid: 4, WireIntakePlan(checkpoint: 1, roundName: "Synthesis", editsVersion: "",
                                               markdown: "# P", outline: [], notes: [])),
        ]
        for frame in frames {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
            let json = try fields(of: frame)
            XCTAssertNil(json["seq"])
            let tag = try XCTUnwrap(json["t"] as? String)
            XCTAssertFalse(tag.contains("."))
            XCTAssertNil(FleetEventTag(rawValue: tag))
        }
    }
```
Plumbing test (`IntakeRequestPlumbingTests.swift`) — follow the loopback pattern in `FleetRequestPlumbingTests.swift` (a real `FleetSocketServer` + `FleetConnector` on 127.0.0.1): the server's `onRequest` answers `.intakeDetail(id:, ifNot: "same")` with `.intakeDetail(cid:, nil)`, other ids with a small `WireIntakeDetail`, and `.intakePlan` for an unknown id with `.err(cid:, code: "unknown_intake")`. Assert: the connector's `requestIntakeDetail` completes `.success(nil)` for `"same"`, `.success(detail)` otherwise; `requestIntakePlan` completes `.failure(.server(code: "unknown_intake"))`; after `connector.stop()` a pending request completes `.failure(.disconnected)`. Also a `FleetService` test through `FleetTestHarness` (`FleetTestHarness.swift:28-49`): with a seeded intake in the store's intake root, a `.intakeDetail(id: seeded, ifNot: nil)` reply carries the detail, and a second request with `ifNot:` set to the first reply's `etag` is answered with `nil`; an unknown id gets `err unknown_intake`.

- [ ] **Step 2: Run to verify they fail** (`type 'FleetRequest' has no member 'intakeDetail'`).

- [ ] **Step 3: Implement — every arm in this one step**

`TimelineFrames.swift`:

```swift
    /// An intake's screen content (spec §6.2). `ifNot`: the etag the phone holds — the Mac
    /// answers `nil` when it still matches, so an idle poll costs a few dozen bytes.
    case intakeDetail(id: UUID, ifNot: String?)
    /// A checkpoint's plan (nil: the head), with a block diff against its parent when `changes`.
    case intakePlan(id: UUID, checkpoint: Int?, changes: Bool)
```
`CodingKeys` add `intake, ifNot, checkpoint, changes`; `Op` add `case intakeDetail = "intake.detail"`, `case intakePlan = "intake.plan"`. Encode:

```swift
        case .intakeDetail(let id, let ifNot):
            try c.encode(Op.intakeDetail, forKey: .op)
            try c.encode(id, forKey: .intake)
            try c.encodeIfPresent(ifNot, forKey: .ifNot)
        case .intakePlan(let id, let checkpoint, let changes):
            try c.encode(Op.intakePlan, forKey: .op)
            try c.encode(id, forKey: .intake)
            try c.encodeIfPresent(checkpoint, forKey: .checkpoint)
            try c.encode(changes, forKey: .changes)
```
Decode:

```swift
        case .intakeDetail:
            self = .intakeDetail(id: try c.decode(UUID.self, forKey: .intake),
                                 ifNot: try c.decodeIfPresent(String.self, forKey: .ifNot))
        case .intakePlan:
            self = .intakePlan(id: try c.decode(UUID.self, forKey: .intake),
                               checkpoint: try c.decodeIfPresent(Int.self, forKey: .checkpoint),
                               changes: try c.decodeIfPresent(Bool.self, forKey: .changes) ?? false)
```

`Frames.swift` — cases with the doc comment "Unsequenced, like `page`: a screen's content is not fleet state.":

```swift
    case intakeDetail(cid: Int, WireIntakeDetail?)
    case intakePlan(cid: Int, WireIntakePlan)
```
`CodingKeys` add `detail, plan`; `Tag` add `intakeDetail, intakePlan` (undotted). Encode:

```swift
        case .intakeDetail(let cid, let detail):
            try c.encode(Tag.intakeDetail, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encodeIfPresent(detail, forKey: .detail)
        case .intakePlan(let cid, let plan):
            try c.encode(Tag.intakePlan, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(plan, forKey: .plan)
```
Decode:

```swift
            case .intakeDetail:
                self = .intakeDetail(cid: try c.decode(Int.self, forKey: .cid),
                                     try c.decodeIfPresent(WireIntakeDetail.self, forKey: .detail))
            case .intakePlan:
                self = .intakePlan(cid: try c.decode(Int.self, forKey: .cid),
                                   try c.decode(WireIntakePlan.self, forKey: .plan))
```
`correlationID`: add `.intakeDetail(let cid, _), .intakePlan(let cid, _)` to the `return cid` arm.

`FleetConnector.swift` — copy the `newSessionOptions` shape (`:142`, `:270-281`, `:393-399`, `:619-623`, `:644-648`, `:880-884`) twice:

```swift
    private var pendingIntakeDetail: [Int: (Result<WireIntakeDetail?, FleetRequestError>) -> Void] = [:]
    private var pendingIntakePlan: [Int: (Result<WireIntakePlan, FleetRequestError>) -> Void] = [:]

    /// Ask for an intake's screen content. Same contract as `requestNewSessionOptions` —
    /// exactly one answer; `.success(nil)` means "unchanged since `ifNot`".
    public func requestIntakeDetail(
        id: UUID, ifNot: String?,
        then completion: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.intakeDetail(id: id, ifNot: ifNot))
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingIntakeDetail[cid] = completion
    }

    public func requestIntakePlan(
        id: UUID, checkpoint: Int?, changes: Bool,
        then completion: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.intakePlan(id: id, checkpoint: checkpoint, changes: changes))
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingIntakePlan[cid] = completion
    }
```
Resolvers `resolveIntakeDetail(_:with:)` / `resolveIntakePlan(_:with:)` shaped like `resolveOptions`; `apply` arms (return before `onFleet`, like `.newSessionOptions`); `.err` routing entries; `drainPending` entries completing `.failure(.disconnected)`.

`FleetService.handleRequest`:

```swift
        case .intakeDetail(let id, let ifNot):
            // Read from memory (IntakeService already holds tapes, seats and convergence);
            // nothing is written and nothing enters `FleetSnapshot`.
            let project = store.repos.first { repo in
                store.intakeService.intakes(forProject: repo.url.path).contains { $0.id == id }
            }?.id
            guard let project,
                  let detail = IntakeDetailProjection.detail(id, project: project, service: store.intakeService, servedAt: Date())
            else {
                Self.logger.info("check=unknown_intake intake=\(id, privacy: .public)")
                return reply(.err(cid: cid, code: "unknown_intake"))
            }
            reply(.intakeDetail(cid: cid, detail.etag == ifNot ? nil : detail))
        case .intakePlan(let id, let checkpoint, let changes):
            // Two small file reads (the checkpoint's plan and, for `changes`, its parent's) —
            // tens of KB, done here like the other synchronous arms.
            guard store.intakeService.intakes.contains(where: { $0.id == id }) else {
                Self.logger.info("check=unknown_intake intake=\(id, privacy: .public)")
                return reply(.err(cid: cid, code: "unknown_intake"))
            }
            guard let plan = IntakePlanProjection.plan(id, checkpoint: checkpoint, changes: changes, service: store.intakeService) else {
                Self.logger.info("check=unknown_checkpoint intake=\(id, privacy: .public)")
                return reply(.err(cid: cid, code: "unknown_checkpoint"))
            }
            reply(.intakePlan(cid: cid, plan))
```
(use the file's existing `Logger`; if it is not `Self.logger`, use whatever name `FleetService` already logs through.)

`ControlScope.swift:115` — add `.intakeDetail, .intakePlan` to the `return true` arm (read-only). `CLIRunner.swift:503` — `case .intakeDetail(_, let detail): self.out(CLIOutput.json(detail))` and `case .intakePlan(_, let plan): self.out(CLIOutput.json(plan))`.

- [ ] **Step 4: Run** — `./scripts/test-unit.sh` (0 failures) and `./scripts/test-ios.sh` (`TEST SUCCEEDED`).

- [ ] **Step 5: Commit** — every file above in one commit: `git commit -m "feat: answer intake detail and plan requests from the phone"`.

---

### Task 6: Phone pure types — rows, banner, clock

**Files:**
- Create: `Sources/FlightDeckMobile/IntakeStyle.swift`
- Test: `Tests/FlightDeckMobileTests/IntakeStyleTests.swift`

**Interfaces:**
- Consumes: `WireIntakeSummary`, `WireProject.intakes`.
- Produces:
  - `enum IntakeRowStyle { static func ordered(_ intakes: [WireIntakeSummary]) -> [WireIntakeSummary]; static func glyph(_ s: WireIntakeSummary) -> IntakeGlyph; static func pill(_ s: WireIntakeSummary) -> String; static func fact(_ s: WireIntakeSummary, clock: String?) -> String?; static func badge(_ intakes: [WireIntakeSummary]?) -> String?; static func presetName(_ raw: String?) -> String?; static func stateWord(_ s: WireIntakeSummary) -> String }`
  - `struct IntakeGlyph: Equatable { let symbol: String; let tone: IntakeTone }`; `enum IntakeTone: Equatable { case live, attention, failure, quiet }`
  - `struct IntakeBanner: Equatable, Identifiable { let id: UUID; let project: String; let title: String; let subtitle: String }`
  - `enum BannerPolicy { static func banners(previous: [UUID: WireIntakeSummary], next: [WireIntakeSummary], project: String, onScreen: UUID?) -> [IntakeBanner] }`
  - `enum ClockPolicy { static func elapsed(since: Date, now: Date, offset: TimeInterval, frozenAt: Date?) -> TimeInterval; static func text(_ interval: TimeInterval) -> String; static func tickInterval(elapsed: TimeInterval, idle: Bool) -> TimeInterval }`

- [ ] **Step 1: Write the failing tests** (`IntakeStyleTests.swift`):

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class IntakeStyleTests: XCTestCase {
    private func s(_ state: String, attention: Bool = false, now: String? = nil, run: String? = nil,
                   created: Double = 0, questions: Int? = nil, released: Int? = nil,
                   done: Int? = nil, total: Int? = nil) -> WireIntakeSummary {
        WireIntakeSummary(id: UUID(), title: "T", state: state, needsAttention: attention, now: now,
                          runStatus: run, agentsDone: done, agentsTotal: total, questionCount: questions,
                          releasedTaskCount: released, createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    func testRowsOrderNeedsYouThenFlyingThenTheRestNewestFirst() {
        let old = s("released", created: 1), attention = s("needsAnswers", attention: true, created: 2),
            running = s("shaping", run: "running", created: 3), paused = s("shaping", run: "paused", created: 4),
            newer = s("released", created: 5)
        XCTAssertEqual(IntakeRowStyle.ordered([old, attention, running, paused, newer]).map(\.id),
                       [attention.id, paused.id, running.id, newer.id, old.id])
    }

    func testTheBadgeCountsNeedsYouAndIsAbsentAtZero() {
        XCTAssertEqual(IntakeRowStyle.badge([s("review", attention: true), s("needsAnswers", attention: true), s("shaping")]), "2 need you")
        XCTAssertEqual(IntakeRowStyle.badge([s("review", attention: true)]), "1 needs you")
        XCTAssertNil(IntakeRowStyle.badge([s("shaping")]))
        XCTAssertNil(IntakeRowStyle.badge(nil))
    }

    func testFactsSayWhatTheRowIsWaitingOn() {
        XCTAssertEqual(IntakeRowStyle.fact(s("needsAnswers", attention: true, questions: 3), clock: nil), "3 questions")
        XCTAssertEqual(IntakeRowStyle.fact(s("needsAnswers", attention: true, questions: 1), clock: nil), "1 question")
        XCTAssertEqual(IntakeRowStyle.fact(s("released", released: 6), clock: nil), "Released 6 tasks")
        XCTAssertEqual(IntakeRowStyle.fact(s("shaping", now: "Refine 2", run: "running", done: 1, total: 2), clock: "4:12"),
                       "Refine 2 · 4:12 · 1 of 2 agents")
    }

    func testPresetNamesSayTaskNeverBead() {
        XCTAssertEqual(IntakeRowStyle.presetName("bead"), "Single task")
        XCTAssertEqual(IntakeRowStyle.presetName("featurePlan"), "Feature plan")
        XCTAssertEqual(IntakeRowStyle.presetName("fullPlan"), "Full plan")
        XCTAssertEqual(IntakeRowStyle.presetName("sketch"), "Sketch")
        XCTAssertNil(IntakeRowStyle.presetName(nil))
    }

    func testGlyphsColourOnlyExceptions() {
        XCTAssertEqual(IntakeRowStyle.glyph(s("needsAnswers", attention: true)).tone, .attention)
        XCTAssertEqual(IntakeRowStyle.glyph(s("failed", attention: true)).tone, .failure)
        XCTAssertEqual(IntakeRowStyle.glyph(s("shaping", run: "running")).tone, .live)
        XCTAssertEqual(IntakeRowStyle.glyph(s("released")).tone, .quiet)
    }

    func testAnUnknownStateRendersDegradedNotBlank() {
        XCTAssertFalse(IntakeRowStyle.pill(s("someFutureState")).isEmpty)
    }

    // MARK: Banner (Review Focus #3)

    func testABannerFiresOnlyOnATransitionIntoNeedsYou() {
        let before = s("triaging")
        var after = before; after.state = "needsAnswers"; after.needsAttention = true; after.questionCount = 3
        XCTAssertEqual(BannerPolicy.banners(previous: [before.id: before], next: [after], project: "larkOS", onScreen: nil),
                       [IntakeBanner(id: after.id, project: "larkOS", title: "T needs answers", subtitle: "larkOS · 3 questions")])
        XCTAssertEqual(BannerPolicy.banners(previous: [after.id: after], next: [after], project: "larkOS", onScreen: nil), [],
                       "already waiting: no banner")
        XCTAssertEqual(BannerPolicy.banners(previous: [:], next: [after], project: "larkOS", onScreen: nil), [],
                       "never seen before (a snapshot, a reconnect): no banner")
        XCTAssertEqual(BannerPolicy.banners(previous: [before.id: before], next: [after], project: "larkOS", onScreen: after.id), [],
                       "its own screen is open: no banner")
    }

    func testBannerWordsPerState() {
        let base = s("triaging")
        for (state, words) in [("review", "is ready for review"), ("awaitingChoice", "is ready to plan"),
                               ("failed", "failed"), ("interrupted", "was interrupted"), ("shaping", "is paused")] {
            var next = base; next.state = state; next.needsAttention = true
            XCTAssertEqual(BannerPolicy.banners(previous: [base.id: base], next: [next], project: "p", onScreen: nil).first?.title,
                           "T \(words)")
        }
    }

    // MARK: Clock (Review Focus #1)

    func testSkewedClockNeverGoesNegative() {
        let since = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 95), offset: 0, frozenAt: nil), 0)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 95), offset: 10, frozenAt: nil), 5)
    }

    func testADisconnectedClockFreezes() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(ClockPolicy.elapsed(since: since, now: Date(timeIntervalSinceReferenceDate: 500), offset: 0,
                                           frozenAt: Date(timeIntervalSinceReferenceDate: 60)), 60)
    }

    func testClockTextAndIdleTicks() {
        XCTAssertEqual(ClockPolicy.text(0), "0:00")
        XCTAssertEqual(ClockPolicy.text(252), "4:12")
        XCTAssertEqual(ClockPolicy.text(3723), "1:02:03")
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 30, idle: true), 1)
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 61, idle: true), 60)
        XCTAssertEqual(ClockPolicy.tickInterval(elapsed: 600, idle: false), 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `./scripts/test-ios.sh 2>&1 | tail -30` → `cannot find 'IntakeRowStyle'`.

- [ ] **Step 3: Implement** `IntakeStyle.swift`:

```swift
import FleetKit
import Foundation

enum IntakeTone: Equatable { case live, attention, failure, quiet }
struct IntakeGlyph: Equatable { let symbol: String; let tone: IntakeTone }

/// The Sessions list's intake rows, as decisions (MOBILE-UI: a decision reachable without
/// SwiftUI is one a test can run). Words follow spec §3: tasks, agents, Flight Control.
enum IntakeRowStyle {
    static func ordered(_ intakes: [WireIntakeSummary]) -> [WireIntakeSummary] {
        func rank(_ s: WireIntakeSummary) -> Int {
            if s.needsAttention { return 0 }
            if s.runStatus == "running" || s.runStatus == "paused" || s.state == "triaging" { return 1 }
            return 2
        }
        return intakes.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.createdAt > b.createdAt
        }
    }

    static func badge(_ intakes: [WireIntakeSummary]?) -> String? {
        let n = intakes?.filter(\.needsAttention).count ?? 0
        return n == 0 ? nil : "\(n) \(n == 1 ? "needs" : "need") you"
    }

    static func presetName(_ raw: String?) -> String? {
        switch raw {
        case "bead": "Single task"
        case "sketch": "Sketch"
        case "featurePlan": "Feature plan"
        case "fullPlan": "Full plan"
        case nil: nil
        default: raw
        }
    }

    static func glyph(_ s: WireIntakeSummary) -> IntakeGlyph {
        switch s.state {
        case "failed", "interrupted": IntakeGlyph(symbol: "exclamationmark", tone: .failure)
        case "needsAnswers": IntakeGlyph(symbol: "questionmark", tone: .attention)
        case "awaitingChoice", "review", "partiallyReleased": IntakeGlyph(symbol: "diamond", tone: .attention)
        case "released": IntakeGlyph(symbol: "checkmark", tone: .quiet)
        default:
            if s.needsAttention { IntakeGlyph(symbol: "pause.fill", tone: .attention) }
            else if s.runStatus == "running" || s.state == "triaging" { IntakeGlyph(symbol: "airplane", tone: .live) }
            else { IntakeGlyph(symbol: "pause.fill", tone: .quiet) }
        }
    }

    static func stateWord(_ s: WireIntakeSummary) -> String {
        switch s.state {
        case "triaging": "Triaging"
        case "needsAnswers": "Needs answers"
        case "awaitingChoice": "Choose fidelity"
        case "parked": "Parked"
        case "shaping": s.runStatus == "running" ? "Shaping" : s.needsAttention ? "Paused" : "Shaping"
        case "review": "Ready for review"
        case "releasing": "Releasing"
        case "released": "Released"
        case "partiallyReleased": "Partly released"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        default: "Flight Control"
        }
    }

    static func pill(_ s: WireIntakeSummary) -> String {
        s.state == "shaping" ? (s.now ?? "Shaping") : stateWord(s)
    }

    static func fact(_ s: WireIntakeSummary, clock: String?) -> String? {
        switch s.state {
        case "needsAnswers":
            return s.questionCount.map { "\($0) question\($0 == 1 ? "" : "s")" }
        case "released", "partiallyReleased":
            return s.releasedTaskCount.map { "Released \($0) task\($0 == 1 ? "" : "s")" }
        case "shaping":
            var parts = [s.now, clock].compactMap { $0 }
            if let d = s.agentsDone, let t = s.agentsTotal { parts.append("\(d) of \(t) agents") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }
}

struct IntakeBanner: Equatable, Identifiable {
    let id: UUID
    let project: String
    let title: String
    let subtitle: String
}

/// In-app attention (spec §4.2, D4). A banner is a TRANSITION heard live: an intake the phone
/// already knew, which did not need you, now does. Never from a snapshot — a reconnect would
/// otherwise announce everything already waiting — and never over that intake's own screen.
enum BannerPolicy {
    static func banners(previous: [UUID: WireIntakeSummary], next: [WireIntakeSummary],
                        project: String, onScreen: UUID?) -> [IntakeBanner] {
        next.compactMap { s in
            guard s.needsAttention, let before = previous[s.id], !before.needsAttention, s.id != onScreen else { return nil }
            let words: String = switch s.state {
            case "needsAnswers": "needs answers"
            case "awaitingChoice": "is ready to plan"
            case "review", "partiallyReleased": "is ready for review"
            case "failed": "failed"
            case "interrupted": "was interrupted"
            default: "is paused"
            }
            let fact = IntakeRowStyle.fact(s, clock: nil) ?? IntakeRowStyle.stateWord(s)
            return IntakeBanner(id: s.id, project: project, title: "\(s.title) \(words)", subtitle: "\(project) · \(fact)")
        }
    }
}

/// Count-up clocks (spec §3). `offset` is the Mac's clock minus the phone's, from the last
/// detail's `servedAt`, so skew never shows; `frozenAt` is when the link was lost.
enum ClockPolicy {
    static func elapsed(since: Date, now: Date, offset: TimeInterval, frozenAt: Date?) -> TimeInterval {
        let end = (frozenAt ?? now).addingTimeInterval(offset)
        return max(0, end.timeIntervalSince(since))
    }

    static func text(_ interval: TimeInterval) -> String {
        let t = Int(interval.rounded(.down))
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func tickInterval(elapsed: TimeInterval, idle: Bool) -> TimeInterval {
        idle && elapsed > 60 ? 60 : 1
    }
}
```

- [ ] **Step 4: Run** — `./scripts/test-ios.sh`: `TEST SUCCEEDED`.
- [ ] **Step 5: Commit** — `git commit -m "feat: decide the phone's intake rows, banners and clocks"`.

---

### Task 7: Phone pure types — board strip, agent rows, round facts, outline

**Files:**
- Create: `Sources/FlightDeckMobile/BoardStripModel.swift`, `AgentRowStyle.swift`, `RoundFacts.swift`, `OutlineStyle.swift`
- Test: `Tests/FlightDeckMobileTests/BoardStripModelTests.swift`, `AgentRowStyleTests.swift`, `RoundFactsTests.swift`, `OutlineStyleTests.swift`

**Interfaces:**
- Consumes: Task 2 types, `ClockPolicy`, `IntakeRowStyle` (Task 6), `AgentActivityRules`.
- Produces:
  - `struct BoardStripModel: Equatable { let nowText: String; let clockCaption: String; let clockSince: Date?; let clockText: String?; let stopText: String; let convergence: String?; let convergenceAmber: Bool; let dots: [Dot]; let tone: IntakeTone; let idle: Bool; struct Dot: Equatable, Identifiable { let id: String; let state: String; let isStop: Bool; let checkpoint: Int?; let label: String; var tappable: Bool { checkpoint != nil && state != "future" } }; init(detail: WireIntakeDetail) }`
  - `enum AgentException: Equatable { case quiet(TimeInterval), stalled(TimeInterval, last: String?), rateLimited(TimeInterval), fallback(String), failed(String) }`
  - `enum AgentRowStyle { static func exception(_ a: WireAgent, now: Date) -> AgentException?; static func exceptionText(_ e: AgentException) -> String; static func isAmber(_ e: AgentException) -> Bool; static func elapsed(_ a: WireAgent, now: Date) -> TimeInterval; static func accessibilityLabel(_ a: WireAgent, now: Date) -> String }` (`now` is already skew-corrected by the caller)
  - `struct RoundFacts: Equatable { let time: String; let changes: String; let lines: String; let verdicts: String; let spoken: String; init(_ r: WireRound) }`
  - `enum OutlineStyle { static func subline(_ s: WireSection) -> String?; static func noteCounts(_ notes: [WireNote], outline: [WireSection]) -> [Int: Int] /* blockIndex of section → pending notes in it */ }`

- [ ] **Step 1: Write the failing tests** — one file per type:

`BoardStripModelTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class BoardStripModelTests: XCTestCase {
    static func detail(state: String = "shaping", run: String = "running", attention: Bool = false,
                       slots: [WireSlot], caption: String = "IN THE AIR", stop: String? = "encode-0") -> WireIntakeDetail {
        WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: state, needsAttention: attention,
                                       runStatus: run, createdAt: Date()),
            intent: "I", progress: [],
            board: WireBoard(slots: slots, nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: caption,
                             clockSince: Date(timeIntervalSinceReferenceDate: 0), clockText: nil, stopsAt: "Encode",
                             stopSlotID: stop, callingAt: "2 · Polish 6 · Review",
                             convergence: WireConvergence(word: "DIVERGING ↗", amber: true, spark: []), defaultPlay: "nextMajor"),
            agents: [], rounds: [], pendingNotes: 0, servedAt: Date())
    }
    static let slots = [
        WireSlot(id: "refine-1", name: "Refine 1", code: "RF1", state: "done", major: false, group: "REFINE", checkpoint: 3, duration: 391),
        WireSlot(id: "refine-2", name: "Refine 2", code: "RF2", state: "live", major: false, group: "REFINE"),
        WireSlot(id: "refine-3", name: "Refine 3", code: "RF3", state: "future", major: false, group: "REFINE"),
        WireSlot(id: "encode-0", name: "Encode", code: "ENC", state: "future", major: true),
    ]

    func testNowCountsTheRoundInItsCycle() {
        XCTAssertEqual(BoardStripModel(detail: Self.detail(slots: Self.slots)).nowText, "REFINE 2 OF 3")
    }

    func testOnlyLandedDotsAreTappableAndTheStopIsMarked() {
        let dots = BoardStripModel(detail: Self.detail(slots: Self.slots)).dots
        XCTAssertEqual(dots.map(\.tappable), [true, false, false, false])
        XCTAssertEqual(dots.first { $0.isStop }?.id, "encode-0")
        XCTAssertEqual(dots[0].label, "Refine 1, landed, 6 minutes 31")
    }

    func testToneFollowsState() {
        XCTAssertEqual(BoardStripModel(detail: Self.detail(slots: Self.slots)).tone, .live)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(run: "paused", slots: Self.slots, caption: "PAUSED FOR")).tone, .quiet)
        XCTAssertTrue(BoardStripModel(detail: Self.detail(run: "paused", slots: Self.slots, caption: "PAUSED FOR")).idle)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(state: "review", run: "reachedReview", attention: true, slots: Self.slots)).tone, .attention)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(state: "failed", run: "failed", attention: true, slots: Self.slots)).tone, .failure)
    }

    func testTheStopAndConvergenceLine() {
        let m = BoardStripModel(detail: Self.detail(slots: Self.slots))
        XCTAssertEqual(m.stopText, "→ STOPS AT ENCODE")
        XCTAssertEqual(m.convergence, "DIVERGING ↗")
        XCTAssertTrue(m.convergenceAmber)
    }

    func testANeedsAnswersIntakeWithNoBoardReadsItsTurn() {
        var d = Self.detail(state: "needsAnswers", attention: true, slots: [])
        d.board = nil
        d.summary.now = "Clarify 1"
        XCTAssertEqual(BoardStripModel(detail: d).nowText, "CLARIFY 1 · YOUR TURN")
    }
}
```

`AgentRowStyleTests.swift` — pin the Mac's precedence (`SeatRowModel.runningException`: rate limit > stalled > fallback > quiet) with a fixed `now`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class AgentRowStyleTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func agent(glyph: String = "running", last: TimeInterval? = 0, rateLimited: TimeInterval? = nil,
                       fallback: String? = nil, failure: String? = nil, action: String? = "Reading a.swift") -> WireAgent {
        WireAgent(id: "r", glyph: glyph, role: "reviewer", identity: "codex · gpt-6-sol · high", action: action,
                  startedAt: t0, lastEventAt: last.map { t0.addingTimeInterval($0) },
                  rateLimitedAt: rateLimited.map { t0.addingTimeInterval($0) }, fallback: fallback, failure: failure)
    }

    func testQuietThenStalled() {
        XCTAssertNil(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(29)))
        XCTAssertEqual(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(34)), .quiet(34))
        XCTAssertEqual(AgentRowStyle.exception(agent(), now: t0.addingTimeInterval(105)), .stalled(105, last: "Reading a.swift"))
    }

    func testPrecedenceMatchesTheMac() {
        XCTAssertEqual(AgentRowStyle.exception(agent(rateLimited: 10), now: t0.addingTimeInterval(200)), .rateLimited(190))
        XCTAssertEqual(AgentRowStyle.exception(agent(fallback: "fell back to codex · claude 401"), now: t0.addingTimeInterval(40)),
                       .fallback("fell back to codex · claude 401"))
        XCTAssertEqual(AgentRowStyle.exception(agent(fallback: "x"), now: t0.addingTimeInterval(95)), .stalled(95, last: "Reading a.swift"))
    }

    func testAFinishedRowHasOnlyItsFailure() {
        XCTAssertNil(AgentRowStyle.exception(agent(glyph: "done"), now: t0.addingTimeInterval(500)))
        XCTAssertEqual(AgentRowStyle.exception(agent(glyph: "failed", failure: "exit 1"), now: t0.addingTimeInterval(500)), .failed("exit 1"))
    }

    func testExceptionWords() {
        XCTAssertEqual(AgentRowStyle.exceptionText(.quiet(34)), "quiet 0:34")
        XCTAssertEqual(AgentRowStyle.exceptionText(.stalled(105, last: "Running swift build")), "No output for 1:45 · last: Running swift build")
        XCTAssertEqual(AgentRowStyle.exceptionText(.rateLimited(42)), "Waiting on rate limit · 0:42")
        XCTAssertFalse(AgentRowStyle.isAmber(.quiet(34)))
        XCTAssertTrue(AgentRowStyle.isAmber(.stalled(95, last: nil)))
    }
}
```

`RoundFactsTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class RoundFactsTests: XCTestCase {
    func testFourFactsAndDashesForWhatIsMissing() {
        let r = WireRound(checkpoint: 3, name: "Refine 1", code: "RF1", stage: "refine",
                          startedAt: Date(timeIntervalSinceReferenceDate: 0), landedAt: Date(timeIntervalSinceReferenceDate: 391),
                          outcome: "ok", changeCount: 41, linesAdded: 620, linesRemoved: 180,
                          verdicts: WireVerdicts(agreed: 33, somewhat: 6, declined: 2))
        let f = RoundFacts(r)
        XCTAssertEqual([f.time, f.changes, f.lines, f.verdicts], ["6:31", "41", "+620 −180", "33 · 6 · 2"])
        XCTAssertEqual(f.spoken, "6 minutes 31, 41 changes, 620 lines added and 180 removed, 33 agreed, 6 somewhat, 2 declined")

        let draft = WireRound(checkpoint: 1, name: "Drafts", code: "DRF", stage: "draft", startedAt: nil,
                              landedAt: Date(), outcome: "fallback", changeCount: nil, linesAdded: 0, linesRemoved: 0)
        let g = RoundFacts(draft)
        XCTAssertEqual([g.time, g.changes, g.verdicts], ["—", "—", "—"])
        XCTAssertTrue(g.spoken.contains("no duration recorded"))
        XCTAssertTrue(g.spoken.contains("no verdicts"))
        XCTAssertFalse(g.spoken.contains("—"), "VoiceOver hears words, never a dash")
    }
}
```

`OutlineStyleTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class OutlineStyleTests: XCTestCase {
    func testSublines() {
        XCTAssertEqual(OutlineStyle.subline(WireSection(heading: "A", level: 2, blockIndex: 1, churn: [4, 0], diverging: false, settledSince: "Round 1")),
                       "still since Round 1")
        XCTAssertEqual(OutlineStyle.subline(WireSection(heading: "B", level: 2, blockIndex: 3, churn: [9, 8], diverging: true, settledSince: nil)),
                       "still moving")
        XCTAssertNil(OutlineStyle.subline(WireSection(heading: "C", level: 2, blockIndex: 5, churn: [9, 8], diverging: false, settledSince: nil)))
    }

    func testPendingNotesCountTowardTheSectionTheyFallIn() {
        let outline = [WireSection(heading: "A", level: 2, blockIndex: 1, churn: [], diverging: false, settledSince: nil),
                       WireSection(heading: "B", level: 2, blockIndex: 4, churn: [], diverging: false, settledSince: nil)]
        func note(_ block: Int?, consumed: Bool = false) -> WireNote {
            WireNote(id: UUID(), kind: "comment", text: "", consumed: consumed, blockIndex: block)
        }
        XCTAssertEqual(OutlineStyle.noteCounts([note(2), note(5), note(6), note(6, consumed: true), note(nil)], outline: outline),
                       [1: 1, 4: 2])
    }
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement the four files.**

`BoardStripModel.swift`:

```swift
import FleetKit
import Foundation

/// The pinned strip's content (spec §4.3) — every word and colour decision, apart from the view.
struct BoardStripModel: Equatable {
    struct Dot: Equatable, Identifiable {
        let id: String
        let state: String
        let isStop: Bool
        let checkpoint: Int?
        let label: String
        var tappable: Bool { checkpoint != nil && state != "future" }
    }
    let nowText: String
    let clockCaption: String
    let clockSince: Date?
    let clockText: String?
    let stopText: String
    let convergence: String?
    let convergenceAmber: Bool
    let dots: [Dot]
    let tone: IntakeTone
    let idle: Bool

    init(detail: WireIntakeDetail) {
        let s = detail.summary
        let board = detail.board
        tone = s.state == "failed" || s.state == "interrupted" || s.runStatus == "failed" ? .failure
            : s.needsAttention ? .attention
            : (s.runStatus == "running" || s.state == "triaging") ? .live : .quiet
        idle = s.runStatus != "running" && s.state != "triaging"
        let now = (board?.nowName ?? s.now ?? IntakeRowStyle.stateWord(s)).uppercased()
        if let board, let live = board.slots.first(where: { $0.state == "live" }), let group = live.group {
            let inCycle = board.slots.filter { $0.group == group }
            nowText = "\(now) OF \(inCycle.count)"
        } else if s.state == "needsAnswers" || s.state == "awaitingChoice" {
            nowText = s.state == "needsAnswers" ? "\(now) · YOUR TURN" : "READY · PICK FIDELITY"
        } else if s.state == "review" {
            nowText = "REVIEW · READY FOR YOU"
        } else if s.runStatus == "paused" {
            nowText = "\(now) · PAUSED"
        } else {
            nowText = now
        }
        clockCaption = board?.clockCaption ?? (s.state == "triaging" ? "IN THE AIR" : "")
        clockSince = board?.clockSince ?? s.clockSince
        clockText = board?.clockText
        stopText = board.map { "→ STOPS AT \($0.stopsAt.uppercased())" } ?? ""
        convergence = board?.convergence?.word
        convergenceAmber = board?.convergence?.amber ?? false
        dots = (board?.slots ?? []).map { slot in
            let status = switch slot.state {
            case "done": "landed"
            case "live": "in the air"
            case "failed": "failed"
            default: "scheduled"
            }
            let duration = slot.duration.map { ", " + Self.spoken($0) } ?? ""
            return Dot(id: slot.id, state: slot.state, isStop: slot.id == board?.stopSlotID,
                       checkpoint: slot.checkpoint, label: "\(slot.name), \(status)\(duration)")
        }
    }

    static func spoken(_ t: TimeInterval) -> String {
        let s = Int(t), m = s / 60, r = s % 60
        return m == 0 ? "\(r) seconds" : "\(m) minute\(m == 1 ? "" : "s") \(r)"
    }
}
```

`AgentRowStyle.swift`:

```swift
import FleetKit
import Foundation

enum AgentException: Equatable {
    case quiet(TimeInterval)
    case stalled(TimeInterval, last: String?)
    case rateLimited(TimeInterval)
    case fallback(String)
    case failed(String)
}

/// An agent row's exception, judged on the phone with the Mac's precedence
/// (`SeatRowModel.runningException`: rate limit > stalled > fallback > quiet) and the shared
/// `AgentActivityRules`. `now` is the caller's skew-corrected clock.
enum AgentRowStyle {
    static func finished(_ a: WireAgent) -> Bool { a.glyph == "done" || a.glyph == "failed" }

    static func exception(_ a: WireAgent, now: Date) -> AgentException? {
        if finished(a) { return a.failure.map(AgentException.failed) }
        if let at = a.rateLimitedAt { return .rateLimited(max(0, now.timeIntervalSince(at))) }
        guard let started = a.startedAt else { return nil }
        let idle = max(0, now.timeIntervalSince(a.lastEventAt ?? started))
        if idle >= AgentActivityRules.stalled { return .stalled(idle, last: a.action) }
        if let fallback = a.fallback { return .fallback(fallback) }
        if idle >= AgentActivityRules.quiet { return .quiet(idle) }
        return nil
    }

    static func exceptionText(_ e: AgentException) -> String {
        switch e {
        case .quiet(let t): "quiet \(ClockPolicy.text(t))"
        case .stalled(let t, let last): "No output for \(ClockPolicy.text(t))" + (last.map { " · last: \($0)" } ?? "")
        case .rateLimited(let t): "Waiting on rate limit · \(ClockPolicy.text(t))"
        case .fallback(let text): text
        case .failed(let text): text
        }
    }

    static func isAmber(_ e: AgentException) -> Bool {
        switch e {
        case .quiet, .failed: false
        case .stalled, .rateLimited, .fallback: true
        }
    }

    static func elapsed(_ a: WireAgent, now: Date) -> TimeInterval {
        if let d = a.duration { return d }
        guard let started = a.startedAt else { return 0 }
        return max(0, now.timeIntervalSince(started))
    }

    static func accessibilityLabel(_ a: WireAgent, now: Date) -> String {
        var parts = ["\(a.role.capitalized), \(a.identity.replacingOccurrences(of: " · ", with: ", "))"]
        if let h = a.headline ?? a.result { parts.append(h) }
        if let action = a.action, !finished(a) { parts.append(action) }
        if let e = exception(a, now: now) { parts.append(exceptionText(e)) }
        return parts.joined(separator: ". ")
    }
}
```

`RoundFacts.swift` (Verdict order agreed · somewhat · declined; no colour):

```swift
import FleetKit
import Foundation

/// The round detail's facts strip (spec §4.6): the same four fields for every round, "—" for a
/// missing one on screen and words for it to VoiceOver.
struct RoundFacts: Equatable {
    let time: String
    let changes: String
    let lines: String
    let verdicts: String
    let spoken: String

    init(_ r: WireRound) {
        let duration = r.startedAt.map { r.landedAt.timeIntervalSince($0) }
        time = duration.map(ClockPolicy.text) ?? "—"
        changes = r.changeCount.map(String.init) ?? "—"
        let hasLines = r.linesAdded > 0 || r.linesRemoved > 0
        lines = hasLines ? "+\(r.linesAdded) −\(r.linesRemoved)" : "—"
        verdicts = r.verdicts.map { "\($0.agreed) · \($0.somewhat) · \($0.declined)" } ?? "—"
        spoken = [
            duration.map(BoardStripModel.spoken) ?? "no duration recorded",
            r.changeCount.map { "\($0) changes" } ?? "no change count",
            hasLines ? "\(r.linesAdded) lines added and \(r.linesRemoved) removed" : "no line counts",
            r.verdicts.map { "\($0.agreed) agreed, \($0.somewhat) somewhat, \($0.declined) declined" } ?? "no verdicts",
        ].joined(separator: ", ")
    }
}
```

`OutlineStyle.swift`:

```swift
import FleetKit
import Foundation

enum OutlineStyle {
    static func subline(_ s: WireSection) -> String? {
        if s.diverging { return "still moving" }
        return s.settledSince.map { "still since \($0)" }
    }

    /// Pending (unconsumed, located) notes per section, keyed by the section heading's block.
    static func noteCounts(_ notes: [WireNote], outline: [WireSection]) -> [Int: Int] {
        let starts = outline.map(\.blockIndex).sorted()
        var counts: [Int: Int] = [:]
        for note in notes where !note.consumed {
            guard let block = note.blockIndex, let section = starts.last(where: { $0 <= block }) else { continue }
            counts[section, default: 0] += 1
        }
        return counts
    }
}
```

- [ ] **Step 4: Run** — `./scripts/test-ios.sh`: `TEST SUCCEEDED`. If `testNowCountsTheRoundInItsCycle` fails on the uppercase of `nowName`, fix the model, not the expectation.
- [ ] **Step 5: Commit** — `git commit -m "feat: decide the phone's board strip, agent rows, round facts and outline"`.

---

### Task 8: Phone model — summaries, banners, detail polling, plan cache

**Files:**
- Create: `Sources/FlightDeckMobile/FlightControlModel.swift`, `Sources/FlightDeckMobile/IntakeDetailModel.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (conform to `IntakeFetching`, own a `FlightControlModel`, wire `onEvent` + `.connected`)
- Test: `Tests/FlightDeckMobileTests/FlightControlModelTests.swift`

**Interfaces:**
- Consumes: Task 5 connector methods; Task 6 `BannerPolicy`, `IntakeBanner`.
- Produces:
  - `@MainActor protocol IntakeFetching: AnyObject { func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void); func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) }`
  - `@MainActor @Observable final class IntakeDetailModel { let id: UUID; private(set) var detail: WireIntakeDetail?; private(set) var failure: String?; private(set) var gone: Bool; private(set) var macClockOffset: TimeInterval; func refresh(); init(id: UUID, fetcher: IntakeFetching, receivedAt: @escaping () -> Date = Date.init) }`
  - `@MainActor @Observable final class FlightControlModel { private(set) var banners: [IntakeBanner]; var onScreen: UUID?; func baseline(_ fleet: FleetSnapshot); func intakesChanged(project: UUID, intakes: [WireIntakeSummary]?, fleet: FleetSnapshot); func dismissBanner(_ id: UUID); func detailModel(for id: UUID) -> IntakeDetailModel; func plan(_ intake: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void); static let planCacheLimit = 4; init(fetcher: IntakeFetching) }`
  - `FleetModel.flightControl: FlightControlModel`

- [ ] **Step 1: Write the failing tests** (`FlightControlModelTests.swift`) with a stub, following the `StubPager` precedent (`SessionTimelineModelTests.swift:12`):

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
private final class StubFetcher: IntakeFetching {
    var detailCalls: [(UUID, String?)] = []
    var detailReplies: [Result<WireIntakeDetail?, FleetRequestError>] = []
    var planCalls = 0
    var planReply: Result<WireIntakePlan, FleetRequestError> = .failure(.disconnected)
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void) {
        detailCalls.append((id, ifNot)); then(detailReplies.isEmpty ? .failure(.disconnected) : detailReplies.removeFirst())
    }
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {
        planCalls += 1; then(planReply)
    }
}

@MainActor
final class FlightControlModelTests: XCTestCase {
    private func summary(_ id: UUID, attention: Bool, state: String) -> WireIntakeSummary {
        WireIntakeSummary(id: id, title: "T", state: state, needsAttention: attention, createdAt: Date())
    }
    private func fleet(_ project: UUID, _ intakes: [WireIntakeSummary]) -> FleetSnapshot {
        FleetSnapshot(projects: [WireProject(id: project, name: "larkOS", path: "/w", intakes: intakes)])
    }

    func testASnapshotBaselinesWithoutBannersAndALiveTransitionFiresOne() {
        let model = FlightControlModel(fetcher: StubFetcher())
        let project = UUID(), id = UUID()
        let waiting = [summary(id, attention: false, state: "triaging")]
        model.baseline(fleet(project, waiting))
        XCTAssertEqual(model.banners, [])
        let now = [summary(id, attention: true, state: "needsAnswers")]
        model.intakesChanged(project: project, intakes: now, fleet: fleet(project, now))
        XCTAssertEqual(model.banners.map(\.id), [id])
        model.intakesChanged(project: project, intakes: now, fleet: fleet(project, now))
        XCTAssertEqual(model.banners.count, 1, "the same state again is not a new transition")
        model.dismissBanner(id)
        XCTAssertEqual(model.banners, [])
    }

    func testDetailKeepsItsEtagAndIgnoresUnchangedReplies() {
        let fetcher = StubFetcher()
        let id = UUID()
        let d = WireIntakeDetail(etag: "e1", project: UUID(),
                                 summary: summary(id, attention: false, state: "triaging"), intent: "I", progress: [],
                                 agents: [], rounds: [], pendingNotes: 0, servedAt: Date(timeIntervalSinceReferenceDate: 110))
        fetcher.detailReplies = [.success(d), .success(nil)]
        let model = IntakeDetailModel(id: id, fetcher: fetcher, receivedAt: { Date(timeIntervalSinceReferenceDate: 100) })
        model.refresh()
        model.refresh()
        XCTAssertEqual(fetcher.detailCalls.map(\.1), [nil, "e1"])
        XCTAssertEqual(model.detail, d, "nil means unchanged: keep what we have")
        XCTAssertEqual(model.macClockOffset, 10)
    }

    func testAnUnknownIntakeSaysItIsGone() {
        let fetcher = StubFetcher()
        fetcher.detailReplies = [.failure(.server(code: "unknown_intake"))]
        let model = IntakeDetailModel(id: UUID(), fetcher: fetcher)
        model.refresh()
        XCTAssertTrue(model.gone)
    }

    func testADisconnectKeepsTheLastDetail() {
        let fetcher = StubFetcher()
        let d = WireIntakeDetail(etag: "e", project: UUID(), summary: summary(UUID(), attention: false, state: "triaging"),
                                 intent: "I", progress: [], agents: [], rounds: [], pendingNotes: 0, servedAt: Date())
        fetcher.detailReplies = [.success(d), .failure(.disconnected)]
        let model = IntakeDetailModel(id: d.summary.id, fetcher: fetcher)
        model.refresh(); model.refresh()
        XCTAssertEqual(model.detail, d)
        XCTAssertFalse(model.gone)
    }

    func testPlansAreCachedByCheckpointAndChanges() {
        let fetcher = StubFetcher()
        fetcher.planReply = .success(WireIntakePlan(checkpoint: 3, roundName: "Refine 1", editsVersion: "", markdown: "# P", outline: [], notes: []))
        let model = FlightControlModel(fetcher: fetcher)
        let id = UUID()
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        XCTAssertEqual(fetcher.planCalls, 1)
        model.plan(id, checkpoint: 3, changes: true) { _ in }
        XCTAssertEqual(fetcher.planCalls, 2)
        for c in 10..<15 { model.plan(id, checkpoint: c, changes: false) { _ in } }
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        XCTAssertEqual(fetcher.planCalls, 8, "LRU of 4: checkpoint 3 was evicted")
    }
}
```
Note: a head request (`checkpoint: nil`) is never cached — the head moves; the key is `(intake, checkpoint!, changes)` and nil bypasses the cache.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement.**

`IntakeDetailModel.swift`:

```swift
import FleetKit
import Foundation

@MainActor
protocol IntakeFetching: AnyObject {
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void)
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void)
}

/// One open intake's content, refreshed by the screen's 1.5 s loop (spec §6.2). A `nil` reply
/// means "unchanged since my etag"; a disconnect keeps what is on screen (it goes stale, it does
/// not go blank); `unknown_intake` means the Mac no longer has it (spec §9).
@MainActor
@Observable
final class IntakeDetailModel {
    let id: UUID
    private(set) var detail: WireIntakeDetail?
    private(set) var failure: String?
    private(set) var gone = false
    /// Mac clock − phone clock, from the last detail's `servedAt` (Review Focus #1).
    private(set) var macClockOffset: TimeInterval = 0
    @ObservationIgnored private weak var fetcher: IntakeFetching?
    @ObservationIgnored private let receivedAt: () -> Date
    @ObservationIgnored private var inFlight = false

    init(id: UUID, fetcher: IntakeFetching, receivedAt: @escaping () -> Date = Date.init) {
        self.id = id
        self.fetcher = fetcher
        self.receivedAt = receivedAt
    }

    func refresh() {
        guard !inFlight, let fetcher else { return }
        inFlight = true
        fetcher.intakeDetail(id, ifNot: detail?.etag) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let fresh?):
                self.detail = fresh
                self.macClockOffset = fresh.servedAt.timeIntervalSince(self.receivedAt())
                self.failure = nil
            case .success(nil):
                break
            case .failure(.server(code: "unknown_intake")):
                self.gone = true
            case .failure(.disconnected):
                break
            case .failure(let error):
                self.failure = "\(error)"
            }
        }
    }
}
```
If `FleetRequestError` has other cases than `.disconnected`/`.server(code:)`, the `.failure(let error)` arm covers them; if the stub's synchronous completion makes `inFlight` race in a test, the test drives it synchronously so it does not.

`FlightControlModel.swift`:

```swift
import FleetKit
import Foundation

/// The phone's Flight Control state beside the fleet: known summaries for banner transitions,
/// the banner queue, open intakes' detail models, and a small plan cache (spec §7).
@MainActor
@Observable
final class FlightControlModel {
    static let planCacheLimit = 4
    private(set) var banners: [IntakeBanner] = []
    /// The intake whose screen is on top; its banner is suppressed.
    var onScreen: UUID?
    @ObservationIgnored private var known: [UUID: WireIntakeSummary] = [:]
    @ObservationIgnored private var details: [UUID: IntakeDetailModel] = [:]
    @ObservationIgnored private var plans: [String: WireIntakePlan] = [:]
    @ObservationIgnored private var planOrder: [String] = []
    @ObservationIgnored private weak var fetcher: IntakeFetching?

    init(fetcher: IntakeFetching) { self.fetcher = fetcher }

    /// A snapshot (connect, resync): learn everything, announce nothing (Review Focus #3).
    func baseline(_ fleet: FleetSnapshot) {
        known = [:]
        for project in fleet.projects { for s in project.intakes ?? [] { known[s.id] = s } }
    }

    /// A live `project.intakes` event, heard after the connector folded it into `fleet`.
    func intakesChanged(project: UUID, intakes: [WireIntakeSummary]?, fleet: FleetSnapshot) {
        let name = fleet.projects.first { $0.id == project }?.name ?? ""
        let fresh = BannerPolicy.banners(previous: known, next: intakes ?? [], project: name, onScreen: onScreen)
        for s in intakes ?? [] { known[s.id] = s }
        banners.removeAll { b in fresh.contains { $0.id == b.id } }
        banners.append(contentsOf: fresh)
    }

    func dismissBanner(_ id: UUID) { banners.removeAll { $0.id == id } }

    func detailModel(for id: UUID) -> IntakeDetailModel {
        if let m = details[id] { return m }
        let m = IntakeDetailModel(id: id, fetcher: fetcher!)
        details[id] = m
        return m
    }

    func plan(_ intake: UUID, checkpoint: Int?, changes: Bool,
              then completion: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {
        let key = checkpoint.map { "\(intake)/\($0)/\(changes)" }
        if let key, let cached = plans[key] {
            planOrder.removeAll { $0 == key }; planOrder.append(key)
            return completion(.success(cached))
        }
        guard let fetcher else { return completion(.failure(.disconnected)) }
        fetcher.intakePlan(intake, checkpoint: checkpoint, changes: changes) { [weak self] result in
            if let self, case .success(let plan) = result {
                let stored = "\(intake)/\(plan.checkpoint)/\(changes)"
                self.plans[stored] = plan
                self.planOrder.removeAll { $0 == stored }; self.planOrder.append(stored)
                while self.planOrder.count > Self.planCacheLimit { self.plans.removeValue(forKey: self.planOrder.removeFirst()) }
            }
            completion(result)
        }
    }
}
```
Cache key note: the phone's `editsVersion` is part of spec §6.3's key. The head request is uncached, and a checkpoint request only happens after the reader already loaded that checkpoint's `editsVersion` — keep it simple here: when a head fetch returns a plan whose `editsVersion` differs from the cached entry for the same checkpoint, replace the cached entry (add that line in the completion: `if let old = self.plans[stored], old.editsVersion != plan.editsVersion { … }` — the store above already overwrites, which is exactly this).

`FleetModel.swift`:
- Conform: `extension FleetModel: IntakeFetching` with both methods forwarding to `connector?.requestIntakeDetail` / `requestIntakePlan`, completing `.failure(.disconnected)` synchronously when there is no connector (the `timelinePage` shape, `:554-560`).
- `@ObservationIgnored private(set) lazy var flightControl = FlightControlModel(fetcher: self)` — if `lazy` conflicts with `@Observable`, make it a `let` initialised at the end of `init` via an implicitly unwrapped `private(set) var flightControl: FlightControlModel!` set after all stored properties.
- In `connector.onEvent` (`:729-757`) add:

```swift
                case .projectIntakes(let project, let intakes):
                    guard let self else { return }
                    self.flightControl.intakesChanged(project: project, intakes: intakes, fleet: self.fleet)
```
- In the deferred `.connected` block (`:805-809`) add `self?.flightControl.baseline(self?.fleet ?? .empty)` — deferred for the same reason the refreshes are (`.connected` is reported before its snapshot is applied).

- [ ] **Step 4: Run** — `./scripts/test-ios.sh`: `TEST SUCCEEDED`.
- [ ] **Step 5: Commit** — `git commit -m "feat: hold flight control state on the phone"`.

---

### Task 9: Sessions list rows, badge, banner and routes

**Files:**
- Create: `Sources/FlightDeckMobile/IntakeRoute.swift`, `IntakeRow.swift`, `AttentionBanner.swift`
- Modify: `Sources/FlightDeckMobile/FleetListScreen.swift` (`projectHeader` `:360-401`, section body `:68-84`, a second `navigationDestination` beside `:130`), `Sources/FlightDeckMobile/FlightDeckMobileApp.swift` (overlay)
- Test: extend `Tests/FlightDeckMobileTests/FleetListScreenTests.swift`

**Interfaces:**
- Consumes: Tasks 6 and 8.
- Produces: `enum IntakeRoute: Hashable { case intake(UUID), round(intake: UUID, checkpoint: Int), plan(intake: UUID, checkpoint: Int?), reader(intake: UUID, checkpoint: Int?, block: Int?, changes: Bool), clarifications(UUID) }`; `static func FleetListScreen.intakeRows(_ project: WireProject) -> [WireIntakeSummary]` (ordered; empty when collapsed or nil).

- [ ] **Step 1: Write the failing test** (append to `FleetListScreenTests`):

```swift
    func testIntakeRowsComeOrderedAndHideWithTheProject() {
        let attention = WireIntakeSummary(id: UUID(), title: "A", state: "needsAnswers", needsAttention: true, createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let flying = WireIntakeSummary(id: UUID(), title: "B", state: "shaping", needsAttention: false, runStatus: "running", createdAt: Date(timeIntervalSinceReferenceDate: 2))
        var project = WireProject(id: UUID(), name: "larkOS", path: "/w", intakes: [flying, attention])
        XCTAssertEqual(FleetListScreen.intakeRows(project).map(\.id), [attention.id, flying.id])
        project.isCollapsed = true
        XCTAssertEqual(FleetListScreen.intakeRows(project), [])
        project.isCollapsed = false; project.intakes = nil
        XCTAssertEqual(FleetListScreen.intakeRows(project), [])
    }
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement.**

`IntakeRoute.swift`:

```swift
import Foundation

/// Every Flight Control screen reachable from the Sessions list's `NavigationPath`. One
/// `Hashable` enum beside the existing `UUID` destination, so a session id and an intake id
/// can never be confused on the path.
enum IntakeRoute: Hashable {
    case intake(UUID)
    case round(intake: UUID, checkpoint: Int)
    case plan(intake: UUID, checkpoint: Int?)
    case reader(intake: UUID, checkpoint: Int?, block: Int?, changes: Bool)
    case clarifications(UUID)
}
```

`FleetListScreen`:

```swift
    static func intakeRows(_ project: WireProject) -> [WireIntakeSummary] {
        project.isCollapsed ? [] : IntakeRowStyle.ordered(project.intakes ?? [])
    }
```
Section body: before `ForEach(project.sessions)`, add `ForEach(Self.intakeRows(project)) { intake in NavigationLink(value: IntakeRoute.intake(intake.id)) { IntakeRow(summary: intake, frozenAt: frozenAt) }.listRowInsets(Self.rowInsets) }` — keep the existing `if !project.isCollapsed` around sessions and let `intakeRows` handle intakes. `frozenAt`: `if case .lost = model.state { model.lastLive } else { nil }`.
`projectHeader`: after `Spacer()`, before the session count: `if let badge = IntakeRowStyle.badge(project.intakes) { Text(badge).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Color.orange)).foregroundStyle(.black).accessibilityLabel(badge) }` — shown even when collapsed. (The + for new intakes is Phase 3; do not add it.)
**The navigation path moves to `FleetModel`** so the banner (app level) and the board strip (deep in the stack) can both push: add `var path = NavigationPath()` to `FleetModel` (observed — not `@ObservationIgnored`), delete `FleetListScreen`'s `@State private var path` (`:20`), and use `NavigationStack(path: Bindable(model).path)`; every existing `path.append(…)` / `path = …` in the file becomes `model.path…`. The `IntakeRoute` destination is added in Task 10, once the screens exist; until then an intake row's `NavigationLink(value:)` pushes nothing, which is fine for one task.

`IntakeRow.swift`:

```swift
import FleetKit
import SwiftUI

/// One intake in the Sessions list (spec §4.1): a glyph tile, the title, a pill and one fact.
struct IntakeRow: View {
    let summary: WireIntakeSummary
    let frozenAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let glyph = IntakeRowStyle.glyph(summary)
            let clock = summary.clockSince.map {
                ClockPolicy.text(ClockPolicy.elapsed(since: $0, now: context.date, offset: 0, frozenAt: frozenAt))
            }
            HStack(spacing: 10) {
                Image(systemName: glyph.symbol)
                    .font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(glyph.tone == .attention ? Color.black : Self.color(glyph.tone))
                    .background(RoundedRectangle(cornerRadius: 7).fill(
                        glyph.tone == .attention ? Color.orange : Self.color(glyph.tone).opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(.body).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(IntakeRowStyle.pill(summary).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Self.color(glyph.tone))
                        if let fact = IntakeRowStyle.fact(summary, clock: clock) {
                            Text(fact).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func color(_ tone: IntakeTone) -> Color {
        switch tone {
        case .live: .accentColor
        case .attention: .orange
        case .failure: .red
        case .quiet: .secondary
        }
    }
}
```
(The list row does not know the Mac clock offset — it uses 0, clamped; the intake screen uses the precise offset. A row a second off is acceptable; a negative one is not, and `ClockPolicy` clamps.)

`AttentionBanner.swift`:

```swift
import SwiftUI

/// The in-app "needs you" banner (spec §4.2): top of the screen, ~4 s, swipe up or tap.
struct AttentionBanner: View {
    let banner: IntakeBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark").font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26).foregroundStyle(.black)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(banner.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < 0 { onDismiss() } })
        .task(id: banner.id) {
            try? await Task.sleep(for: .seconds(4))
            onDismiss()
        }
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "\(banner.title). \(banner.subtitle)") }
    }
}
```
`FlightDeckMobileApp.swift`: overlay the root with `.overlay(alignment: .top) { if let banner = model.flightControl.banners.first { AttentionBanner(banner: banner, onOpen: { model.flightControl.dismissBanner(banner.id); openIntake(banner.id) }, onDismiss: { model.flightControl.dismissBanner(banner.id) }).transition(.move(edge: .top).combined(with: .opacity)) } }`. `openIntake(id)` is `model.path.append(IntakeRoute.intake(id))`. Under Reduce Motion (`@Environment(\.accessibilityReduceMotion)`) use `.opacity` only.

- [ ] **Step 4: Run** — `./scripts/build-ios.sh` (read which branch ran) and `./scripts/test-ios.sh`.
- [ ] **Step 5: Commit** — `git commit -m "feat: list flight control intakes in the phone's sessions list"`.

---

### Task 10: The intake screen — strip, agents, rounds, waiting states, round detail, clarifications

**Files:**
- Create/replace: `Sources/FlightDeckMobile/IntakeScreen.swift`, `BoardStrip.swift`, `AgentRow.swift`, `RoundDetailScreen.swift`, `ClarificationsScreen.swift`
- Test: none new (every decision is in Tasks 6–7); this task is verified by renders (Task 12) and the device checklist.

**Interfaces:**
- Consumes: `IntakeDetailModel`, `BoardStripModel`, `AgentRowStyle`, `RoundFacts`, `ClockPolicy`, `IntakeRowStyle`, `IntakeRoute`, `FleetModel.flightControl`, `FleetModel.state`, `FleetModel.lastLive`.

- [ ] **Step 1: `BoardStrip.swift`**

```swift
import FleetKit
import SwiftUI

/// The pinned phosphor strip (spec §4.3). Phase 1 has no transport row.
struct BoardStrip: View {
    let model: BoardStripModel
    let offset: TimeInterval
    let frozenAt: Date?
    let onDot: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phosphor: Color {
        switch model.tone {
        case .live: Color(red: 0.49, green: 0.88, blue: 1)
        case .attention: .orange
        case .failure: .red
        case .quiet: Color(white: 0.8)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let clock: String = model.clockText ?? model.clockSince.map {
                ClockPolicy.text(ClockPolicy.elapsed(since: $0, now: context.date, offset: offset, frozenAt: frozenAt))
            } ?? ""
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.nowText).font(.system(.subheadline, design: .monospaced)).foregroundStyle(phosphor)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(clock).font(.system(.subheadline, design: .monospaced).monospacedDigit()).foregroundStyle(phosphor)
                        if frozenAt != nil { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.clockCaption.lowercased()) \(clock)\(frozenAt != nil ? ", as of the last connection" : "")")
                }
                if !model.dots.isEmpty {
                    HStack(spacing: 3) {
                        Text("CLR").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        ForEach(model.dots) { dot in dotView(dot) }
                        Text("REV").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if !model.stopText.isEmpty || model.convergence != nil {
                    HStack {
                        Text(model.stopText).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        if let word = model.convergence {
                            Text(word).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(model.convergenceAmber ? .orange : .secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.05, green: 0.07, blue: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder private func dotView(_ dot: BoardStripModel.Dot) -> some View {
        let fill: Color = switch dot.state {
        case "done": Color(red: 0.11, green: 0.31, blue: 0.45)
        case "live": model.tone == .live ? Color.accentColor : Color(white: 0.55)
        case "failed": .red
        default: Color(white: 0.12)
        }
        let shape = Capsule().fill(fill).frame(height: dot.state == "live" ? 6 : 4)
            .frame(maxWidth: .infinity)
            .overlay(dot.isStop ? Capsule().stroke(Color.accentColor, lineWidth: 1.5) : nil)
            .shadow(color: dot.state == "live" && model.tone == .live && !reduceMotion ? .accentColor : .clear, radius: 3)
        if dot.tappable, let checkpoint = dot.checkpoint {
            Button { onDot(checkpoint) } label: { shape.frame(minHeight: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(dot.label)
        } else {
            shape.frame(minHeight: 22).accessibilityLabel(dot.label)
        }
    }
}
```
(The 22 pt minimum height is the tap target; a strip too narrow for 44 pt targets per dot is the reason Rounds rows also open the same detail.)

- [ ] **Step 2: `AgentRow.swift`**

```swift
import FleetKit
import SwiftUI

/// One agent in the round in flight (spec §4.4).
struct AgentRow: View {
    let agent: WireAgent
    let now: Date   // skew-corrected

    var body: some View {
        let exception = AgentRowStyle.exception(agent, now: now)
        HStack(alignment: .top, spacing: 10) {
            glyph.padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.result ?? agent.headline ?? agent.action ?? "Queued").font(.subheadline).lineLimit(2)
                if !AgentRowStyle.finished(agent), let action = agent.action, action != agent.headline {
                    Text(action).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("\(agent.role.capitalized) · \(agent.identity)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let steps = agent.steps { Text(steps).font(.caption2).foregroundStyle(.secondary) }
                if let e = exception {
                    Text(AgentRowStyle.exceptionText(e)).font(.caption).foregroundStyle(Self.color(e))
                }
                if let fraction = agent.contextFraction, !AgentRowStyle.finished(agent) {
                    ProgressView(value: min(max(fraction, 0), 1)).tint(.secondary).scaleEffect(y: 0.6)
                        .accessibilityLabel("Context used").accessibilityValue("\(Int(fraction * 100)) percent")
                }
            }
            Spacer(minLength: 0)
            Text(ClockPolicy.text(AgentRowStyle.elapsed(agent, now: now)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentRowStyle.accessibilityLabel(agent, now: now))
    }

    static func color(_ e: AgentException) -> Color {
        if case .failed = e { return .red }
        return AgentRowStyle.isAmber(e) ? .orange : .secondary
    }

    @ViewBuilder private var glyph: some View {
        switch agent.glyph {
        case "running": Circle().fill(Color.accentColor).frame(width: 9, height: 9)
        case "fallback": Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.orange)
        case "failed": Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
        case "done": Circle().fill(Color.secondary).frame(width: 9, height: 9)
        default: Circle().stroke(Color.secondary).frame(width: 9, height: 9)
        }
    }
}
```
- [ ] **Step 3: `IntakeScreen.swift`**

```swift
import FleetKit
import SwiftUI

/// One intake (spec §4.3–§4.5), read-only in Phase 1.
struct IntakeScreen: View {
    let id: UUID
    let model: IntakeDetailModel
    let fleet: FleetModel
    @Environment(\.scenePhase) private var scenePhase

    private var frozenAt: Date? { if case .lost = fleet.state { return fleet.lastLive }; return nil }

    var body: some View {
        Group {
            if model.gone {
                ContentUnavailableView("This intake is no longer on your Mac", systemImage: "airplane.departure")
            } else if let detail = model.detail {
                content(detail)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.detail?.summary.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let s = model.detail?.summary {
                    VStack(spacing: 0) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text([IntakeRowStyle.presetName(s.preset), IntakeRowStyle.stateWord(s)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { fleet.flightControl.onScreen = id }
        .onDisappear { if fleet.flightControl.onScreen == id { fleet.flightControl.onScreen = nil } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                model.refresh()
            }
        }
    }

    @ViewBuilder private func content(_ d: WireIntakeDetail) -> some View {
        VStack(spacing: 0) {
            BoardStrip(model: BoardStripModel(detail: d), offset: model.macClockOffset, frozenAt: frozenAt) { checkpoint in
                fleet.path.append(IntakeRoute.round(intake: id, checkpoint: checkpoint))
            }
            .padding(.bottom, 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = (frozenAt ?? context.date).addingTimeInterval(model.macClockOffset)
                List {
                    sections(for: d, now: now)
                }
                .opacity(frozenAt == nil ? 1 : 0.5)
            }
        }
    }

    @ViewBuilder private func sections(for d: WireIntakeDetail, now: Date) -> some View {
        if let open = d.questions?.open {
            Section("Round \(d.questions!.answered.count + 1) · \(open.count) questions") {
                ForEach(Array(open.enumerated()), id: \.offset) { i, q in
                    Text("\(i + 1). \(q)").font(.subheadline)
                }
                Text("Answer on your Mac for now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let answered = d.questions?.answered, !answered.isEmpty {
            Section {
                NavigationLink(value: IntakeRoute.clarifications(id)) {
                    Text("✓ Clarifications · \(answered.count) round\(answered.count == 1 ? "" : "s")").font(.subheadline)
                }
            }
        }
        if let choice = d.choice {
            Section("Fidelity") {
                if let rec = IntakeRowStyle.presetName(choice.recommended) {
                    Text("Recommended: \(rec).").font(.subheadline.weight(.semibold))
                }
                if let reason = choice.reason { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
                if let rounds = choice.roundsSummary { Text(rounds).font(.caption).foregroundStyle(.secondary) }
                Text("Choose fidelity and start on your Mac for now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if d.summary.state == "review" {
            Section { Text("Review and release on your Mac for now.").font(.subheadline) }
        }
        if let failure = d.failure {
            Section("Failure") {
                Text(failure.reason).font(.subheadline).foregroundStyle(.red)
                if let output = failure.output {
                    DisclosureGroup("Show output") { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
                        .font(.subheadline)
                }
            }
        }
        if !d.agents.isEmpty {
            let done = d.agents.filter(AgentRowStyle.finished).count
            Section("Agents · \(done) of \(d.agents.count) done") {
                ForEach(d.agents, id: \.id) { AgentRow(agent: $0, now: now) }
            }
        }
        if !d.rounds.isEmpty {
            Section("Rounds") {
                ForEach(d.rounds, id: \.checkpoint) { r in
                    NavigationLink(value: IntakeRoute.round(intake: id, checkpoint: r.checkpoint)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.subheadline)
                                Text(Self.roundFact(r)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(RoundFacts(r).time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if let head = d.headCheckpoint {
            Section {
                NavigationLink(value: IntakeRoute.plan(intake: id, checkpoint: head)) {
                    HStack {
                        Text("Plan").font(.subheadline).foregroundStyle(Color.accentColor)
                        Spacer()
                        if d.pendingNotes > 0 { Text("\(d.pendingNotes) note\(d.pendingNotes == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    static func roundFact(_ r: WireRound) -> String {
        if let v = r.verdicts, let c = r.changeCount { return "\(c) changes · agreed \(v.agreed) · somewhat \(v.somewhat) · declined \(v.declined)" }
        if r.linesAdded > 0 || r.linesRemoved > 0 { return "+\(r.linesAdded) −\(r.linesRemoved)" + (r.outcome == "fallback" ? " · fell back ⇄" : "") }
        return r.outcome == "fallback" ? "fell back ⇄" : ""
    }
}
```
- [ ] **Step 3b: Add the destination** in `FleetListScreen`, beside the `UUID` one. The plan cases arrive in Task 11, which replaces the one `EmptyView` arm:

```swift
            .navigationDestination(for: IntakeRoute.self) { route in
                switch route {
                case .intake(let id):
                    IntakeScreen(id: id, model: model.flightControl.detailModel(for: id), fleet: model)
                case .round(let intake, let checkpoint):
                    RoundDetailScreen(intake: intake, checkpoint: checkpoint, model: model.flightControl.detailModel(for: intake))
                case .clarifications(let id):
                    ClarificationsScreen(model: model.flightControl.detailModel(for: id))
                case .plan, .reader:
                    EmptyView()   // Task 11
                }
            }
```

- [ ] **Step 4: `RoundDetailScreen.swift`**

```swift
import FleetKit
import SwiftUI

/// A landed round (spec §4.6), from a board dot or a Rounds row; ‹ › step to its neighbours.
struct RoundDetailScreen: View {
    let intake: UUID
    @State var checkpoint: Int
    let model: IntakeDetailModel

    init(intake: UUID, checkpoint: Int, model: IntakeDetailModel) {
        self.intake = intake; self._checkpoint = State(initialValue: checkpoint); self.model = model
    }

    private var rounds: [WireRound] { (model.detail?.rounds ?? []).sorted { $0.checkpoint < $1.checkpoint } }
    private var round: WireRound? { rounds.first { $0.checkpoint == checkpoint } }

    var body: some View {
        List {
            if let r = round {
                let facts = RoundFacts(r)
                Section {
                    HStack(spacing: 0) {
                        fact("Time", facts.time); Divider(); fact("Changes", facts.changes)
                        Divider(); fact("Lines", facts.lines); Divider(); fact("Verdicts", facts.verdicts)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel(facts.spoken)
                }
                if let note = r.note { Section("Note") { Text(note).font(.subheadline).textSelection(.enabled) } }
                if !r.agents.isEmpty {
                    Section("Agents") {
                        ForEach(Array(r.agents.enumerated()), id: \.offset) { _, a in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.role.capitalized).font(.subheadline)
                                Text(a.ran).font(.caption).foregroundStyle(.secondary)
                                if let detail = a.detail {
                                    Text(detail).font(.caption).foregroundStyle(a.status == "failed" ? .red : .orange)
                                }
                            }
                        }
                    }
                }
                if !r.sectionsChanged.isEmpty {
                    Section("Sections changed · \(r.sectionsChanged.count)") {
                        ForEach(r.sectionsChanged, id: \.self) { s in
                            NavigationLink(value: IntakeRoute.reader(intake: intake, checkpoint: r.checkpoint, block: nil, changes: true)) {
                                Text(s).font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                }
                if !r.notesConsumed.isEmpty {
                    Section("Notes consumed · \(r.notesConsumed.count)") {
                        ForEach(r.notesConsumed, id: \.id) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                if let q = n.quote { Text("“\(q)”").font(.caption).italic().foregroundStyle(.secondary) }
                                Text(n.text.isEmpty ? "Highlight" : n.text).font(.subheadline)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(round?.name ?? "Round")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(rounds.first?.checkpoint == checkpoint).accessibilityLabel("Previous round")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(rounds.last?.checkpoint == checkpoint).accessibilityLabel("Next round")
            }
        }
    }

    private func step(_ delta: Int) {
        guard let i = rounds.firstIndex(where: { $0.checkpoint == checkpoint }), rounds.indices.contains(i + delta) else { return }
        checkpoint = rounds[i + delta].checkpoint
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
```
Sections changed open the reader at the round's checkpoint with changes on; jumping to the specific section needs the section's block index, which the round does not carry — the reader opens at the top of that checkpoint's plan with changes highlighted (spec §4.6 says "at that section"; recorded as a Phase 2 refinement in Task 12's spec deltas).

- [ ] **Step 5: `ClarificationsScreen.swift`**

```swift
import FleetKit
import SwiftUI

struct ClarificationsScreen: View {
    let model: IntakeDetailModel
    var body: some View {
        List {
            ForEach(Array((model.detail?.questions?.answered ?? []).enumerated()), id: \.offset) { round, exchange in
                Section("Round \(round + 1)") {
                    ForEach(Array(exchange.questions.enumerated()), id: \.offset) { i, q in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(exchange.answers.indices.contains(i) ? exchange.answers[i] : "").font(.subheadline)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Clarifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] **Step 6: Build and test** — `./scripts/build-ios.sh` and `./scripts/test-ios.sh`.
- [ ] **Step 7: Commit** — `git commit -m "feat: show a flight control intake on the phone"`.

---

### Task 11: Plan outline and reader

**Files:**
- Create/replace: `Sources/FlightDeckMobile/PlanOutlineScreen.swift`, `Sources/FlightDeckMobile/PlanReaderScreen.swift`

**Interfaces:**
- Consumes: `FlightControlModel.plan(_:checkpoint:changes:then:)`, `OutlineStyle`, `PlanBlocks.split`, `TimelineMarkdown.theme` (MarkdownUI), `IntakeRoute`.

- [ ] **Step 1: `PlanOutlineScreen.swift`**

```swift
import FleetKit
import SwiftUI

/// A plan's front door (spec §4.7): its sections with churn and note counts.
struct PlanOutlineScreen: View {
    let intake: UUID
    let checkpoint: Int?
    let flightControl: FlightControlModel
    @State private var plan: WireIntakePlan?
    @State private var failed = false
    @State private var query = ""

    var body: some View {
        List {
            if let plan {
                let counts = OutlineStyle.noteCounts(plan.notes, outline: plan.outline)
                ForEach(plan.outline.filter { query.isEmpty || $0.heading.localizedCaseInsensitiveContains(query) }, id: \.blockIndex) { s in
                    NavigationLink(value: IntakeRoute.reader(intake: intake, checkpoint: plan.checkpoint, block: s.blockIndex, changes: false)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.heading).font(.subheadline).lineLimit(1).padding(.leading, s.level > 2 ? 12 : 0)
                                if let sub = OutlineStyle.subline(s) {
                                    Text(sub).font(.caption).foregroundStyle(s.diverging ? .orange : .secondary)
                                }
                            }
                            Spacer()
                            if let n = counts[s.blockIndex] {
                                Text("\(n)").font(.caption2.weight(.bold)).padding(.horizontal, 6)
                                    .background(Capsule().fill(Color.yellow.opacity(0.2))).foregroundStyle(.yellow)
                                    .accessibilityLabel("\(n) note\(n == 1 ? "" : "s")")
                            }
                            churnLane(s.churn, amber: s.diverging)
                        }
                    }
                }
            } else if failed {
                Text("Couldn't load the plan.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Find a section")
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let plan {
                HStack {
                    let pending = plan.notes.filter { !$0.consumed }.count
                    Text("\(pending) note\(pending == 1 ? "" : "s") for the next round").font(.footnote)
                    Spacer()
                    NavigationLink("Whole plan", value: IntakeRoute.reader(intake: intake, checkpoint: plan.checkpoint, block: nil, changes: false))
                        .font(.footnote)
                }
                .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            }
        }
        .task { load() }
    }

    private func load() {
        flightControl.plan(intake, checkpoint: checkpoint, changes: false) { result in
            switch result {
            case .success(let p): plan = p
            case .failure: failed = true
            }
        }
    }

    private func churnLane(_ churn: [Int], amber: Bool) -> some View {
        let peak = max(churn.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(churn.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(amber ? Color.orange : Color.secondary)
                    .frame(width: 4, height: max(1, 14 * CGFloat(v) / CGFloat(peak)))
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Lines changed per round: \(churn.map(String.init).joined(separator: ", "))")
    }
}
```

- [ ] **Step 2: `PlanReaderScreen.swift`**

```swift
import FleetKit
import MarkdownUI
import SwiftUI

/// The whole plan as one scroll (spec §4.8), split with `PlanBlocks.split` — the same split the
/// Mac used to locate notes, so a note's `blockIndex` names this block. Read-only in Phase 1.
struct PlanReaderScreen: View {
    let intake: UUID
    let checkpoint: Int?
    let startBlock: Int?
    @State var changes: Bool
    let flightControl: FlightControlModel
    @State private var plan: WireIntakePlan?
    @State private var openNote: WireNote?

    init(intake: UUID, checkpoint: Int?, startBlock: Int?, changes: Bool, flightControl: FlightControlModel) {
        self.intake = intake; self.checkpoint = checkpoint; self.startBlock = startBlock
        self._changes = State(initialValue: changes); self.flightControl = flightControl
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let plan {
                    let blocks = PlanBlocks.split(plan.markdown).blocks
                    let added = Set(plan.added ?? [])
                    LazyVStack(alignment: .leading, spacing: 10) {
                        removed(after: nil, plan)
                        ForEach(blocks, id: \.index) { block in
                            let notes = plan.notes.filter { $0.blockIndex == block.index }
                            Markdown(block.text)
                                .markdownTheme(TimelineMarkdown.theme)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(
                                    changes && added.contains(block.index) ? Color.green.opacity(0.12)
                                    : notes.contains { !$0.consumed } ? Color.yellow.opacity(0.14)
                                    : notes.isEmpty ? Color.clear : Color.yellow.opacity(0.06)))
                                .onTapGesture { if let first = notes.first { openNote = first } }
                                .id(block.index)
                            removed(after: block.index, plan)
                        }
                        let detached = plan.notes.filter { $0.blockIndex == nil && !$0.consumed }
                        if !detached.isEmpty {
                            Divider()
                            Text("Notes not pinned to a passage").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(detached, id: \.id) { n in noteCard(n) }
                        }
                    }
                    .padding(16)
                    .task { if let startBlock { proxy.scrollTo(startBlock, anchor: .top) } }
                } else {
                    ProgressView().padding(40)
                }
            }
        }
        .navigationTitle(plan?.roundName ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $changes) { Text("Changes") }.toggleStyle(.button).font(.footnote)
                    .accessibilityLabel("Show changes since the previous round")
            }
        }
        .sheet(item: $openNote) { n in noteCard(n).padding().presentationDetents([.medium]) }
        .task(id: changes) { load() }
    }

    @ViewBuilder private func removed(after index: Int?, _ plan: WireIntakePlan) -> some View {
        if changes {
            ForEach(Array((plan.removed ?? []).filter { $0.after == index }.enumerated()), id: \.offset) { _, r in
                Text(r.text).font(.subheadline).strikethrough().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.08)))
                    .accessibilityLabel("Removed: \(r.text)")
            }
        }
    }

    private func noteCard(_ n: WireNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.kindName(n.kind, text: n.text)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let q = n.quote { Text("“\(q)”").font(.subheadline).italic().foregroundStyle(.secondary) }
            if !n.text.isEmpty { Text(n.text).font(.body) }
            if n.consumed { Text("Read by a round").font(.caption).foregroundStyle(.secondary) }
        }
        .opacity(n.consumed ? 0.7 : 1)
    }

    static func kindName(_ kind: String, text: String) -> String {
        switch kind {
        case "comment": text.isEmpty ? "Highlight" : "Comment"
        case "question": "Question"
        case "mustChange": "Must change"
        case "replace": "Replace"
        case "delete": "Delete"
        default: "Note"
        }
    }

    private func load() {
        flightControl.plan(intake, checkpoint: checkpoint, changes: changes) { result in
            if case .success(let p) = result { plan = p }
        }
    }
}
```
`WireNote` must be `Identifiable` for `.sheet(item:)` — it has `id: UUID`; add `extension WireNote: Identifiable {}` in this file if Task 2 did not declare it. Move `kindName` into `OutlineStyle` and add a test for it (`XCTAssertEqual(OutlineStyle.kindName("comment", text: ""), "Highlight")` and one per kind) — decisions live in the pure types.

- [ ] **Step 3: Replace the `EmptyView` arm** in `FleetListScreen`'s `IntakeRoute` destination:

```swift
                case .plan(let intake, let checkpoint):
                    PlanOutlineScreen(intake: intake, checkpoint: checkpoint, flightControl: model.flightControl)
                case .reader(let intake, let checkpoint, let block, let changes):
                    PlanReaderScreen(intake: intake, checkpoint: checkpoint, startBlock: block, changes: changes,
                                     flightControl: model.flightControl)
```

- [ ] **Step 4: Build and test** — `./scripts/build-ios.sh`, `./scripts/test-ios.sh`.
- [ ] **Step 5: Commit** — `git commit -m "feat: read a flight control plan on the phone"`.

---

### Task 12: Guard, renders, checklist, docs

**Files:**
- Modify: `Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift` (new test), `docs/MOBILE.md`, `docs/HANDOFF.md`, `docs/superpowers/specs/2026-09-29-flight-control-mobile-design.md`
- Create: `Tests/FlightDeckMobileTests/IntakeRenderHarness.swift`

- [ ] **Step 1: Extend the terminology guard (spec §10.4).** Add to `TerminologyGuardTests`:

```swift
    /// The phone had no guard (handoff §0.5); Flight Control's words reach it now.
    func testNoUserVisiblePhoneStringSaysBeadFlywheelOrSeat() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Sources/FlightDeckMobile").standardized
        let offenders = try TerminologyScan.offenders(under: root, allow: TerminologyScan.internalAllowList)
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }
```
Run `./scripts/test-unit.sh`. If it reports offenders in pre-existing phone files, fix the user-visible wording; if a literal is genuinely internal (an identifier, a key), add it to `fileAllowList` under its file name with a comment saying why — never to `internalAllowList`.

- [ ] **Step 2: Offscreen renders (spec §10.5).** Create `IntakeRenderHarness.swift` modelled exactly on `Tests/FlightDeckMobileTests/ProseRenderHarness.swift` — same gate (skipped by default; read that file's header for how the gate is flipped for one run), same two-pass measure/draw technique, a real `UIWindow` and `drawHierarchy`. Render at 393 pt, light and dark, and at `.accessibilityExtraExtraExtraLarge`: `IntakeScreen`-equivalent content built from fixture details (running with a live, a done and a stalled agent; paused; needs answers; awaiting choice; failed) — render `BoardStrip` + a `List` of `AgentRow`s and rounds directly with fixture `WireIntakeDetail`s rather than the polling screen; `RoundDetailScreen` for a round with verdicts and one without; `PlanOutlineScreen` and `PlanReaderScreen` fed a fixture plan through a `StubFetcher`. Write PNGs to the harness's existing output directory. Flip the gate, run once, check each PNG's pixel size against an independently measured expectation (a blank image is the failure mode), look at every image, then restore the gate. Do not commit PNGs.

- [ ] **Step 3: Device checklist (spec §10.6).** Append to `docs/MOBILE.md` under `## The manual checklist`, continuing the numbering after the last item (73/74 as of writing — use the real last number), and fix the stale count sentence under `## A second checklist` (it says "sixty-one"; make it say the true count):

```markdown
75. **Watch a Flight Control run from the phone.** Start a Full plan on the Mac for a project
    with Flight Control enabled. On the phone the intake sits at the TOP of that project's
    section with a blue pill "REFINE N" (or DRAFT) and a clock that counts up once a second.
    Open it: the strip shows REFINE N OF M, the clock matches the Mac's IN THE AIR within a
    second or two, and the tape's dots match the Mac's board slot for slot. Wrong: a clock
    that jumps backwards when the screen refreshes, a negative clock, or a dot count that
    differs from the Mac's board.
76. **Get the banner once, and only once.** Leave the phone on the Sessions list. On the Mac,
    let triage reach Needs answers. The banner drops in within about two seconds, reads
    "<title> needs answers", and a tap opens the intake. Background the phone, come back: no
    second banner. Force-quit and relaunch the phone app: no banner (the badge "1 needs you"
    is there instead). Wrong: a banner on relaunch, or none at all while the list is open.
77. **Pull the network during a run.** With an intake open, turn on Airplane Mode. The screen
    dims, the clocks STOP and show the no-signal mark; they do not keep counting. Turn it off:
    the clocks resume at the Mac's true value, without counting backwards.
78. **Read the plan and its changes.** From the intake open Plan: sections are listed with
    churn bars; a section the Mac's convergence flags is amber. Open a section: the reader
    lands on it. Tap Changes: blocks the last round added are tinted green and removed ones
    struck through. A note left on the Mac shows as a yellow wash on its passage; tap it to
    read it. Wrong: a note on the wrong paragraph, or a note that is on the Mac but nowhere on
    the phone (it should at worst be under "Notes not pinned to a passage").
79. **Pair an older phone build.** Install a phone build from before this change against a Mac
    with it, and run a Flight Control round on the Mac for a few minutes. The old phone stays
    connected and shows sessions as before. Wrong: the old phone's connection drops or loops
    when an intake changes.
```

- [ ] **Step 4: Docs.**
  - `docs/HANDOFF.md`: one paragraph under the mobile section: Phase 1 of Flight Control on the phone (read-only) — what crosses the wire (`project.intakes` to `flightControl` peers; `intake.detail`/`intake.plan` requests), where the phone code lives, and that Phases 2 (steer) and 3 (unblock/start/finish) are planned from the same spec.
  - The spec: add a short "Phase 1 as built" subsection under §11 listing the spec deltas at the top of this plan (1–6) plus: the round detail's "sections changed" opens the reader at the round's checkpoint top, not the section (needs a section→block map on `WireRound`, Phase 2).
  - `docs/FLIGHT-CONTROL-MOBILE-HANDOFF.md` §0.1: "No Flight Control data crosses the wire today" is no longer true — change it to point at the spec and name what now crosses.

- [ ] **Step 5: Full verification.** `./scripts/build.sh`, `./scripts/test-unit.sh` (0 failures, no `error:`), `./scripts/build-ios.sh` (real build, not type-check), `./scripts/test-ios.sh` (`TEST SUCCEEDED`). Paste the tails into the task report.

- [ ] **Step 6: Commit** — `git commit -m "test: guard the phone's words and document flight control on the phone"`.

---

## Self-review (done while writing)

- **Spec coverage (Phase 1 = spec §11 item 1):** §4.1 rows/badge/collapse/retention → Tasks 3, 6, 9; §4.2 banner → 6, 8, 9; §4.3 strip (no transport) → 7, 10; §4.4 agents/rounds/plan row → 7, 10 (extend/trim controls are Phase 2); §4.5 waiting states read-only → 10 (forms Phase 3, delta 5); §4.6 → 7, 10; §4.7 → 7, 11; §4.8 read-only → 4, 11; §4.9 → 10; §6.1 → 1, 3; §6.2 → 2, 4, 5; §6.3 → 2, 4, 5; §7 → 6–11; §9 disconnected/gone → 8, 10; §10.1–10.6 → every task + 12. §4.10, §6.4, §6.5, §6.6, §8 are Phases 2–3.
- **Types:** `WireIntakeSummary`/`WireIntakeDetail`/`WireIntakePlan` field names are identical in Tasks 1, 2, 4, 6–11; `IntakeRoute` cases match between Tasks 9–11; `FlightControlModel.plan(_:checkpoint:changes:then:)` and `detailModel(for:)` match their callers.
- **Review Focus:** each of the five lines has its test named in the owning task (6: clock skew, banner; 3: old phone, toggle; 4: note locating).
