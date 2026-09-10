# API-Error Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Badge a session whose last turn died on a Claude API error, on the Mac sidebar and on the phone, so a 529 death stops looking identical to a finished session.

**Architecture:** `claude` writes the failed turn to its transcript JSONL as an assistant record carrying `isApiErrorMessage`, `apiErrorStatus`, `error` and `apiErrorIsTransient`. Flight Deck already tails that file and decodes each record once per poll, so the parser gains two events, the watcher folds them last-wins, and the store holds an orthogonal per-session flag — the exact shape `backgroundWorkSessions` already uses. The flag clears on the next transcript record that is not an error, never on a glance.

**Tech Stack:** Swift 5 (macOS app) / Swift 6 (FleetKit), SwiftUI + AppKit, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-03-api-error-badge-design.md`

## Global Constraints

- **`Sources/FleetKit` is `Foundation`, `Network` and `Security` only.** It compiles for iOS; no AppKit, no SwiftUI, no UIKit.
- **Do NOT bump `FleetKitVersion.wire`.** It stays `1`. The decoder treats an absent key as a meaningful value, exactly as it does for `hasBackgroundWork`.
- **Task 2 is one atomic commit.** A new `FleetEvent` case makes every exhaustive switch a compile error; the case and all its arms land together or not at all.
- **`./scripts/test-unit.sh` runs the whole suite (~8 min) and silently ignores `-only-testing:`.** Budget for it; do not investigate why your filter had no effect.
- **`./scripts/test-ios.sh` is required, not optional,** for any task touching `Sources/FleetKit` or `Sources/FlightDeckMobile` — Tasks 1, 2 and 7.
- **`./scripts/build-boringssl.sh` must have been run once** before any build, including the macOS one. Absent, both Debug and Release fail on a missing `BoringSSL.xcframework`.
- **Never launch a bundle from `DerivedData/` by path for a "quick check" of the whole app.** Flight Deck has no argv parsing, so it boots a second full instance. The one sanctioned exception is Task 6's visual check, which uses `-FlightDeckResetState YES`. Never run `swap-release.sh` as part of this plan — it kills every session on this machine.
- Comments explain *why* and name the failure they prevent. Commits are lowercase, behavioral, imperative, with the trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/FleetKit/SessionAPIError.swift` | **New.** The value and its user-facing label, shared by both platforms. | 1 |
| `Sources/FleetKit/Wire.swift` | `WireSession.apiError` + hand-written coding. | 2 |
| `Sources/FleetKit/FleetEvent.swift` | `.apiErrorChanged` case. | 2 |
| `Sources/FleetKit/WireCoding.swift` | Its tag, encode and decode arms. | 2 |
| `Sources/FleetKit/SnapshotApplication.swift` | Its fold arm. | 2 |
| `Sources/FleetKit/FleetReplay.swift` | Its coalescing key. | 2 |
| `Sources/FlightDeck/ClaudeSession.swift` | `TranscriptEvent.apiError`/`.progressed` + parsing. | 3 |
| `Sources/FlightDeck/TranscriptWatcher.swift` | `onAPIError` + last-wins fold. | 4 |
| `Sources/FlightDeck/Agents/AgentKind.swift` | `AgentEvent.apiError`. | 5 |
| `Sources/FlightDeck/Agents/ClaudeRuntime.swift` | Wires watcher → `AgentEvent`. | 5 |
| `Sources/FlightDeck/SessionStore.swift` | `apiErrors`, `setAPIError`, persistence, handler. | 5 |
| `Sources/FlightDeck/SessionPersistence.swift` | `Entry.apiError`. | 5 |
| `Sources/FlightDeck/Fleet/FleetProjection.swift` | Threads it into the oracle. | 5 |
| `Sources/FlightDeck/SessionStatusIcon.swift` | The Mac glyph. | 6 |
| `Sources/FlightDeckMobile/SessionStatusGlyph.swift` | The phone glyph + label. | 7 |

---

### Task 1: `SessionAPIError` in FleetKit

**Files:**
- Create: `Sources/FleetKit/SessionAPIError.swift`
- Test: `Tests/FlightDeckTests/SessionAPIErrorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct SessionAPIError: Equatable, Sendable, Codable` with `public var status: Int?`, `public var kind: String?`, `public var isTransient: Bool`, `public init(status: Int? = nil, kind: String? = nil, isTransient: Bool = false)`, and `public var label: String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FleetKit

final class SessionAPIErrorTests: XCTestCase {
    func testLabelCarriesStatusAndKind() {
        let e = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
        XCTAssertEqual(e.label, "Stopped — API error 529 (overloaded)")
    }

    /// Every component is optional because the CLI sets them independently — a client-side
    /// failure raises `isApiErrorMessage` with no HTTP status at all. The badge has to survive
    /// that rather than render "API error nil".
    func testLabelDegradesWhenPartsAreMissing() {
        XCTAssertEqual(SessionAPIError(status: 529).label, "Stopped — API error 529")
        XCTAssertEqual(SessionAPIError(kind: "overloaded").label,
                       "Stopped — API error (overloaded)")
        XCTAssertEqual(SessionAPIError().label, "Stopped — API error")
    }

    /// An empty string is not a kind. It reaches us from a record whose `error` key is
    /// present but blank, and "()" in the sidebar is worse than saying nothing.
    func testEmptyKindIsTreatedAsAbsent() {
        XCTAssertEqual(SessionAPIError(status: 500, kind: "").label, "Stopped — API error 500")
    }

    func testRoundTripsThroughCodable() throws {
        let e = SessionAPIError(status: 429, kind: "rate_limit", isTransient: true)
        let data = try JSONEncoder().encode(e)
        XCTAssertEqual(try JSONDecoder().decode(SessionAPIError.self, from: data), e)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SessionAPIError' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Why a session's last turn stopped, when it stopped because the API said no.
///
/// Lives in FleetKit rather than in `Sources/FlightDeck` so the Mac and the phone share the
/// type *and* `label` instead of re-pinning the same strings twice.
/// `SessionStatusGlyph.swift` on iOS hand-copies the Mac's tooltip literals today, and its own
/// doc comment records why that is dangerous: a VoiceOver user hearing a different word than
/// the Mac's tooltip for the identical state is as bad as a mismatched symbol. Sharing the
/// code means this state cannot drift that way at all.
///
/// Every field is optional or defaulted because `claude` sets them independently: a
/// client-side failure raises `isApiErrorMessage` carrying neither a status nor a kind.
public struct SessionAPIError: Equatable, Sendable, Codable {
    /// The HTTP status, from the record's `apiErrorStatus` — 529 for an overloaded API.
    public var status: Int?
    /// The CLI's own error kind, from the record's `error` key — "overloaded", "rate_limit",
    /// "server_error", "invalid_request". Read verbatim and never matched against an enum:
    /// the vocabulary is the CLI's and it will grow, so an unrecognised kind must still reach
    /// the sidebar as text rather than be dropped on the floor.
    public var kind: String?
    /// Whether `claude` considered this failure a transient one. Evaluated at parse time
    /// using the CLI's own predicate, so the rule lives at the one place holding the record.
    ///
    /// Carried but not yet rendered: nothing distinguishes a transient failure from a
    /// permanent one in the UI today. It is here because it is free at parse time and
    /// impossible to recover later — the record is long gone by the time anyone wants it.
    public var isTransient: Bool

    public init(status: Int? = nil, kind: String? = nil, isTransient: Bool = false) {
        self.status = status
        self.kind = kind
        self.isTransient = isTransient
    }

    /// The tooltip, the accessibility label, and the phone's VoiceOver string — one function
    /// so the three cannot disagree.
    public var label: String {
        var out = "Stopped — API error"
        if let status { out += " \(status)" }
        if let kind, !kind.isEmpty { out += " (\(kind))" }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expect PASS.
Run: `./scripts/test-ios.sh` — expect PASS. Required: this adds a file to FleetKit, which builds for iOS too.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/SessionAPIError.swift Tests/FlightDeckTests/SessionAPIErrorTests.swift
git commit -m "add SessionAPIError, shared by both platforms"
```

---

### Task 2: The wire surface — one atomic commit

**Files:**
- Modify: `Sources/FleetKit/Wire.swift` (`WireSession`: property, init, `CodingKeys`, `encode`, `init(from:)`)
- Modify: `Sources/FleetKit/FleetEvent.swift` (new case + the `sessionID` accessor arm)
- Modify: `Sources/FleetKit/WireCoding.swift` (tag, `CodingKeys`, encode arm, decode arm)
- Modify: `Sources/FleetKit/SnapshotApplication.swift` (fold arm)
- Modify: `Sources/FleetKit/FleetReplay.swift` (`FoldKey` case + `key(_:)` arm)
- Test: `Tests/FlightDeckTests/FleetFrameCodingTests.swift`, `Tests/FlightDeckTests/FleetEventApplicationTests.swift`, `Tests/FlightDeckTests/FleetReplayFoldTests.swift`

**Interfaces:**
- Consumes: `SessionAPIError` (Task 1).
- Produces: `WireSession.apiError: SessionAPIError?` (init parameter `apiError: SessionAPIError? = nil`, placed last); `FleetEvent.apiErrorChanged(id: UUID, error: SessionAPIError?)`.

**Why one commit:** adding a `FleetEvent` case makes every exhaustive switch over it a compile error. All five files move together.

- [ ] **Step 1: Write the failing tests**

Add to `FleetFrameCodingTests`:

```swift
/// `WireSession`'s encoder is hand-written, and `planGate`'s comment records the trap: a
/// member omitted from `CodingKeys` is not a compile error, it is a field that silently
/// never reaches the wire. Only a round-trip catches it.
func testSessionWithAnAPIErrorRoundTrips() throws {
    let s = WireSession(
        id: UUID(), title: "t", agent: "claude", activity: "idle",
        apiError: SessionAPIError(status: 529, kind: "overloaded", isTransient: true))
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(WireSession.self, from: data).apiError, s.apiError)
}

/// An older Mac sends no key at all. That is "no error", not a decode failure — the same
/// contract `hasBackgroundWork` established, and the reason the wire version stays at 1.
func testSessionWithNoAPIErrorKeyDecodesToNil() throws {
    let s = WireSession(id: UUID(), title: "t", agent: "claude")
    let data = try JSONEncoder().encode(s)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(object["apiError"],
                 "absent, not null — an older phone must see the bytes it always saw")
    XCTAssertNil(try JSONDecoder().decode(WireSession.self, from: data).apiError)
}

func testAPIErrorChangedEventRoundTrips() throws {
    let id = UUID()
    for event in [FleetEvent.apiErrorChanged(id: id, error: SessionAPIError(status: 529)),
                  FleetEvent.apiErrorChanged(id: id, error: nil)] {
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
    }
}
```

Add to `FleetEventApplicationTests`:

```swift
func testApplyingAnAPIErrorChangedSetsAndClearsIt() {
    let id = UUID()
    let snapshot = FleetSnapshot(projects: [
        WireProject(id: UUID(), name: "p", path: "/p", isCollapsed: false,
                    sessions: [WireSession(id: id, title: "t", agent: "claude")])
    ])
    let raised = snapshot.applying([
        .apiErrorChanged(id: id, error: SessionAPIError(status: 529, kind: "overloaded"))])
    XCTAssertEqual(raised.projects[0].sessions[0].apiError?.status, 529)

    let cleared = raised.applying([.apiErrorChanged(id: id, error: nil)])
    XCTAssertNil(cleared.projects[0].sessions[0].apiError)
}
```

Add to `FleetReplayFoldTests` (match this file's existing way of invoking the fold):

```swift
/// Coalesced like `.activity`. A session that errors, is nudged, and errors again inside one
/// resume gap only needs its final state delivered — without a `FoldKey` the flap ships in
/// full, which is exactly the volume the fold exists to absorb.
func testRepeatedAPIErrorsForOneSessionCoalesce() {
    let id = UUID()
    let folded = fold([
        .apiErrorChanged(id: id, error: SessionAPIError(status: 529)),
        .apiErrorChanged(id: id, error: nil),
        .apiErrorChanged(id: id, error: SessionAPIError(status: 500, kind: "server_error")),
    ])
    XCTAssertEqual(folded.count, 1)
    XCTAssertEqual(folded, [.apiErrorChanged(
        id: id, error: SessionAPIError(status: 500, kind: "server_error"))])
}

/// Two sessions are two keys, so neither swallows the other.
func testAPIErrorsForDifferentSessionsDoNotCoalesce() {
    let a = UUID(), b = UUID()
    XCTAssertEqual(fold([.apiErrorChanged(id: a, error: SessionAPIError(status: 529)),
                         .apiErrorChanged(id: b, error: SessionAPIError(status: 529))]).count, 2)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no `apiError` argument, no `apiErrorChanged` case.

- [ ] **Step 3: Implement across all five files**

`Wire.swift` — add the property beside `planGate`:

```swift
/// Why this session's last turn stopped, when the API refused it. Orthogonal to `activity`,
/// like `hasBackgroundWork`: the Mac reports `activity: "idle"` and this together for a tab
/// that died on a 529 and went quiet.
public var apiError: SessionAPIError?
```

Add `apiError: SessionAPIError? = nil` as the **last** init parameter and assign it. Add `apiError` to `CodingKeys`. In `encode`:

```swift
// Absent, not `null`, for the same reason `planGate` is: a build that predates this field
// must see exactly the bytes it has always seen for a session that has no error.
try c.encodeIfPresent(apiError, forKey: .apiError)
```

In `init(from:)`:

```swift
// Absent from an older Mac, and from every healthy session — both decode as "no error",
// not as a failure. Same contract as `hasBackgroundWork` above, and the reason
// `FleetKitVersion.wire` is deliberately not bumped for this field either.
apiError = try c.decodeIfPresent(SessionAPIError.self, forKey: .apiError)
```

`FleetEvent.swift` — add after `unreadChanged`:

```swift
/// This session's last turn died on an API error, or a newer record cleared it.
///
/// Its own case rather than a seventh parameter on `activityChanged`, and for
/// `unreadChanged`'s reasons: it arrives on the transcript watcher's cadence rather than
/// `commitStatuses`', and it clears on an entirely different trigger. Folding it into the
/// status triple would tie two things that move independently.
///
/// `nil` clears. There is no separate "cleared" case, so a client cannot forget to handle it.
case apiErrorChanged(id: UUID, error: SessionAPIError?)
```

Add `.apiErrorChanged(let id, _)` to the `sessionID` accessor's session-scoped list (the arm beginning `case .sessionRemoved(let id), .sessionMoved(let id, _, _),`).

`WireCoding.swift` — tag `case apiErrorChanged = "session.apiError"`; add `apiError` to that file's `CodingKeys`; then:

```swift
case .apiErrorChanged(let id, let error):
    try c.encode(FleetEventTag.apiErrorChanged, forKey: .t)
    try c.encode(id, forKey: .id)
    // Absent, not `null`, matching `planGateChanged` directly above: a decoder that has
    // never heard of this key must see what a Mac predating the case entirely would send.
    try c.encodeIfPresent(error, forKey: .apiError)
```

```swift
case .apiErrorChanged:
    self = .apiErrorChanged(
        id: try c.decode(UUID.self, forKey: .id),
        error: try c.decodeIfPresent(SessionAPIError.self, forKey: .apiError))
```

`SnapshotApplication.swift` — after the `unreadChanged` arm:

```swift
case .apiErrorChanged(let id, let error):
    mutate(id) { $0.apiError = error }
```

`FleetReplay.swift` — add `case apiError(UUID)` to `FoldKey`, and in `key(_:)`:

```swift
// Same rationale as `.activity`: a session can error, be nudged, and error again inside one
// resume gap, and only the final value is real by the time a reconnecting phone sees it.
case .apiErrorChanged(let id, _): return .apiError(id)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expect PASS.
Run: `./scripts/test-ios.sh` — expect PASS. Required: all five files are FleetKit.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/ Tests/FlightDeckTests/
git commit -m "carry an api error on the wire"
```

---

### Task 3: Parse the error out of the transcript

**Files:**
- Modify: `Sources/FlightDeck/ClaudeSession.swift:152-208` (`TranscriptEvent`, `events(inObject:)`)
- Test: `Tests/FlightDeckTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: `SessionAPIError` (Task 1).
- Produces: `ClaudeSession.TranscriptEvent.apiError(SessionAPIError)` and `.progressed`.

**Field provenance** (probed out of `~/.local/share/claude/versions/2.1.259`, not documentation): the transcript writer spreads the whole message entry into the record, so an assistant record carries `isApiErrorMessage: Bool`, `apiErrorStatus: Int`, `error: String`, `apiErrorIsTransient: Bool`. The CLI's transient predicate is `apiErrorIsTransient === true || error === "overloaded" || error === "server_error"`.

- [ ] **Step 1: Write the failing test**

```swift
func testAssistantAPIErrorRecordRaisesTheError() {
    let line = #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":529,"error":"overloaded","apiErrorIsTransient":true,"message":{"content":[{"type":"text","text":"API Error: 529"}]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()),
                   [.apiError(SessionAPIError(status: 529, kind: "overloaded",
                                              isTransient: true))])
}

/// The kind is read verbatim, never matched against a known set: the CLI's vocabulary is its
/// own and will grow, and a badge that renders an unrecognised kind beats one that drops it.
func testUnrecognisedKindIsCarriedThrough() {
    let line = #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":418,"error":"teapot_error","message":{"content":[]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()),
                   [.apiError(SessionAPIError(status: 418, kind: "teapot_error"))])
}

/// A client-side failure raises the flag with neither status nor kind. It still has to badge.
func testErrorWithNoStatusOrKindStillRaises() {
    let line = #"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()),
                   [.apiError(SessionAPIError())])
}

/// The CLI's own predicate: these two kinds are transient even without the explicit flag.
func testOverloadedAndServerErrorAreTransientWithoutTheFlag() {
    for kind in ["overloaded", "server_error"] {
        let line = #"{"type":"assistant","isApiErrorMessage":true,"error":"\#(kind)","message":{"content":[]}}"#
        guard case .apiError(let e)? = ClaudeSession.events(inLine: line,
                                                            sessionID: UUID()).first else {
            return XCTFail("expected an apiError event for \(kind)")
        }
        XCTAssertTrue(e.isTransient, "\(kind) is transient per the CLI's own predicate")
    }
}

func testOrdinaryAssistantRecordProgresses() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()), [.progressed])
}

/// The tool_use scan is unchanged and still runs — `.progressed` is appended to it, not
/// substituted for it.
func testAgentToolUseStillReportsAlongsideProgress() {
    let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"a1"}]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()),
                   [.agentStarted("a1"), .progressed])
}

/// A tool result means the turn is alive and producing, which is exactly what makes an
/// earlier error stale.
func testToolResultProgresses() {
    let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1"}]}}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()),
                   [.agentFinished("a1"), .progressed])
}

/// System records are bookkeeping, not conversational progress. If `turn_duration` cleared
/// the badge, a turn that died would clear its own error a moment later.
func testTurnDurationDoesNotProgress() {
    let line = #"{"type":"system","subtype":"turn_duration"}"#
    XCTAssertEqual(ClaudeSession.events(inLine: line, sessionID: UUID()), [.turnEnded])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `type 'ClaudeSession.TranscriptEvent' has no member 'apiError'`.

- [ ] **Step 3: Implement**

Add to `TranscriptEvent`:

```swift
/// This record IS a failed turn: `claude` asked the API, the API refused, and the retry
/// loop gave up. One record per dead turn — the retries happen inside the request loop and
/// never reach the transcript — so this needs no de-duplication.
case apiError(SessionAPIError)
/// The conversation moved past whatever came before. Emitted for any assistant record that
/// is not an error and any user record, which is what clears a stale `apiError`.
case progressed
```

Replace the `"assistant"` and `"user"` arms of `events(inObject:)`:

```swift
case "assistant":
    // The tool_use scan runs for error records too. An error message's content is a single
    // text block, so it finds nothing — but depending on that buys nothing and costs a
    // silently dropped `agentStarted` the day it stops being true.
    var events: [TranscriptEvent] = contentBlocks(obj).compactMap { block in
        guard block["type"] as? String == "tool_use",
              block["name"] as? String == "Agent",
              let id = block["id"] as? String
        else { return nil }
        return .agentStarted(id)
    }
    if obj["isApiErrorMessage"] as? Bool == true {
        let kind = obj["error"] as? String
        events.append(.apiError(SessionAPIError(
            status: obj["apiErrorStatus"] as? Int,
            kind: kind,
            // The CLI's own predicate, evaluated here because this is the only place that
            // still has the record. `apiErrorIsTransient` is set explicitly only for
            // capacity-shaped 429s; these two kinds are transient without carrying it.
            isTransient: obj["apiErrorIsTransient"] as? Bool == true
                || kind == "overloaded" || kind == "server_error")))
    } else {
        events.append(.progressed)
    }
    return events

case "user":
    var events: [TranscriptEvent] = contentBlocks(obj).compactMap { block in
        guard block["type"] as? String == "tool_result",
              let id = block["tool_use_id"] as? String
        else { return nil }
        return .agentFinished(id)
    }
    // Including tool results: a result arriving means the turn is alive. Ordering is what
    // makes this safe — the failure sequence is prompt → call fails → error record, so an
    // error always arrives after the prompt that provoked it and is never cleared by it.
    events.append(.progressed)
    return events
```

Leave the `"system"` arm exactly as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expect PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ClaudeSession.swift Tests/FlightDeckTests/ClaudeSessionTests.swift
git commit -m "parse api errors out of the transcript"
```

---

### Task 4: Fold the events in the watcher

**Files:**
- Modify: `Sources/FlightDeck/TranscriptWatcher.swift` (stored properties, init parameter, `apply`)
- Test: `Tests/FlightDeckTests/TranscriptWatcherTests.swift`

**Interfaces:**
- Consumes: `TranscriptEvent.apiError`/`.progressed` (Task 3).
- Produces: `TranscriptWatcher.init(..., onAPIError: @escaping (SessionAPIError?) -> Void = { _ in })`, placed after `onSubagentCount` and before `onMessages`.

**Test idiom:** follow `SubagentCountTests` — create the file empty, `drain()` once to prime, then rewrite the file with the **cumulative** content and `drain()` again. `TailReader`'s truncation policy is `.restartFromZero`, so `write(to:atomically:true)` with the full accumulated text is how this suite appends. Do not invent an `append` helper.

- [ ] **Step 1: Write the failing test**

```swift
private func apiErrorRecord(_ status: Int, _ kind: String) -> String {
    #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":\#(status),"error":"\#(kind)","message":{"content":[]}}"# + "\n"
}
private let plainAssistant =
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"back"}]}}"# + "\n"

/// The fold end to end: an error raises, and the next real record clears it.
func testAPIErrorRaisesThenClears() throws {
    let url = dir.appendingPathComponent("e.jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    var seen: [SessionAPIError?] = []
    let w = TranscriptWatcher(sessionID: sid, url: url, onTitle: { _ in },
                              onSubagentCount: { _ in }, onAPIError: { seen.append($0) })
    w.drain()

    let first = apiErrorRecord(529, "overloaded")
    try first.write(to: url, atomically: true, encoding: .utf8)
    w.drain()
    XCTAssertEqual(seen, [SessionAPIError(status: 529, kind: "overloaded", isTransient: true)])

    try (first + plainAssistant).write(to: url, atomically: true, encoding: .utf8)
    w.drain()
    XCTAssertEqual(seen.count, 2)
    XCTAssertNil(seen[1])
}

/// A session dead for an hour must not re-emit on every poll — the discipline `setUnread`'s
/// early return exists to enforce, for the same reason.
func testUnchangedAPIErrorDoesNotReEmit() throws {
    let url = dir.appendingPathComponent("r.jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    var seen: [SessionAPIError?] = []
    let w = TranscriptWatcher(sessionID: sid, url: url, onTitle: { _ in },
                              onSubagentCount: { _ in }, onAPIError: { seen.append($0) })
    w.drain()

    let one = apiErrorRecord(529, "overloaded")
    try one.write(to: url, atomically: true, encoding: .utf8)
    w.drain()
    try (one + one).write(to: url, atomically: true, encoding: .utf8)
    w.drain()

    XCTAssertEqual(seen.count, 1, "identical error reported once, not once per poll")
}

/// Last event in one scan wins, matching how `.title` already resolves.
func testLastEventInAScanWins() throws {
    let url = dir.appendingPathComponent("l.jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    var seen: [SessionAPIError?] = []
    let w = TranscriptWatcher(sessionID: sid, url: url, onTitle: { _ in },
                              onSubagentCount: { _ in }, onAPIError: { seen.append($0) })
    w.drain()

    try (apiErrorRecord(529, "overloaded") + plainAssistant)
        .write(to: url, atomically: true, encoding: .utf8)
    w.drain()

    XCTAssertEqual(seen, [nil], "one net change per scan, and it is the last one")
}
```

`dir` and `sid` are this file's existing fixtures; if `TranscriptWatcherTests` names them differently, use its names rather than adding new ones.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no `onAPIError` parameter.

- [ ] **Step 3: Implement**

Add beside `outstandingAgents`:

```swift
/// The error currently reported to the store, so an unchanged value re-emits nothing.
/// Without this the store would receive an event per poll for a session that has been dead
/// for an hour — the volume `setUnread`'s early return exists to prevent.
private var lastAPIError: SessionAPIError?
```

Add the callback property `private let onAPIError: (SessionAPIError?) -> Void`, the defaulted init parameter (so no existing call site changes), and the assignment.

In `apply(_:)`, beside `lastTitle`:

```swift
// Three-valued on purpose: `nil` means no event in this scan touched it, `.some(nil)` means
// cleared, `.some(error)` means raised. A plain optional cannot tell the first two apart.
var apiErrorOutcome: SessionAPIError??
```

Two new switch arms:

```swift
case .apiError(let error):
    apiErrorOutcome = .some(error)
case .progressed:
    apiErrorOutcome = .some(nil)
```

And after `if let lastTitle { onTitle(lastTitle) }`:

```swift
if let outcome = apiErrorOutcome, outcome != lastAPIError {
    lastAPIError = outcome
    onAPIError(outcome)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expect PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TranscriptWatcher.swift Tests/FlightDeckTests/TranscriptWatcherTests.swift
git commit -m "fold api errors last-wins in the transcript watcher"
```

---

### Task 5: Runtime → store → snapshot → projection

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift:47-52` (`AgentEvent`)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift:63-68` (watcher construction)
- Modify: `Sources/FlightDeck/SessionStore.swift` (property, `setAPIError`, `apply(_:to:)` arm + visibility, `wire(_:)`, snapshot build ~2321, restore ~2116, `closeSession`)
- Modify: `Sources/FlightDeck/SessionPersistence.swift` (`Entry.apiError` + its `init`)
- Modify: `Sources/FlightDeck/Fleet/FleetProjection.swift` (all three signatures)
- Test: `Tests/FlightDeckTests/FleetFieldEmissionTests.swift`, `Tests/FlightDeckTests/SessionAutoResumeTests.swift`, `Tests/FlightDeckTests/FleetProjectionTests.swift`

**Interfaces:**
- Consumes: `TranscriptWatcher.onAPIError` (Task 4), `FleetEvent.apiErrorChanged` (Task 2).
- Produces: `AgentEvent.apiError(SessionAPIError?)`; `SessionStore.apiErrors: [UUID: SessionAPIError]` (`@Published private(set)`); `SessionStore.apply(_ event: AgentEvent, to tabID: UUID)` (visibility widened from `private` to internal); `SessionSnapshot.Entry.apiError: SessionAPIError?`; `FleetProjection.project(_:status:unread:hasBackgroundWork:openPromptCall:apiError:planGates:)`.

**Merged deliberately.** The `AgentEvent` case, its `ClaudeRuntime` wiring and its store arm are one behavior; splitting them would commit a `case .apiError: break` placeholder that no test can distinguish from a bug.

**One seam widening.** `apply(_ event: AgentEvent, to tabID: UUID)` is `private`, and `@testable import` does not reach `private`. Make it internal, with a comment saying it is the test seam — exactly what `applyRegistry` already is for the status path.

- [ ] **Step 1: Write the failing tests**

Add to `FleetFieldEmissionTests` (use this file's existing store + recorder helpers):

```swift
/// The mutation and its event must not be separable: a phone left un-notified is silently
/// wrong until it reconnects, and nothing crashes to tell you.
func testAPIErrorEmitsOnceAndOnlyOnChange() {
    let (store, recorder) = makeStoreWithRecorder()
    let id = store.repos[0].sessions[0].id
    func emitted() -> Int {
        recorder.events.filter {
            if case .apiErrorChanged = $0 { return true } else { return false }
        }.count
    }

    store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: id)
    XCTAssertEqual(store.apiErrors[id]?.status, 529)
    XCTAssertEqual(emitted(), 1)

    store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: id)
    XCTAssertEqual(emitted(), 1, "an unchanged error must not re-emit")

    store.apply(.apiError(nil), to: id)
    XCTAssertNil(store.apiErrors[id])
    XCTAssertEqual(emitted(), 2)
}
```

Add to `SessionAutoResumeTests` — extend its existing `entry(...)` helper with an `apiError: SessionAPIError? = nil` parameter, then:

```swift
/// The clearing trigger is a NEW transcript record, and `TailReader` starts a first look at
/// an existing file at its end. Without persistence, every relaunch would silently forget
/// every dead session — which matters more here than it does for the unread mark.
func testRestoreSeedsTheAPIError() {
    let (record, id) = entry(activity: "idle",
                             apiError: SessionAPIError(status: 529, kind: "overloaded"))
    let snap = SessionSnapshot(sessions: [record], selectedSessionID: nil, sessionCounter: 1)
    let store = makeStore(snap, autoResume: true)

    store.restore(directoryExists: allDirsExist)

    XCTAssertEqual(store.apiErrors[id]?.status, 529)
    XCTAssertEqual(store.apiErrors[id]?.kind, "overloaded")
}
```

Add to `FleetProjectionTests`:

```swift
/// A field the projection oracle can see that no event can produce is a disagreement by
/// construction — the trap `planGateChanged` was added to close. This is that check here.
func testOracleMatchesTheReplayedMirrorWithAnErrorRaised() {
    let store = makeStore()
    let id = store.repos[0].sessions[0].id
    let mirror = FleetProjection.snapshot(of: store)
    let error = SessionAPIError(status: 529, kind: "overloaded")

    store.apply(.apiError(error), to: id)

    XCTAssertEqual(FleetProjection.snapshot(of: store),
                   mirror.applying([.apiErrorChanged(id: id, error: error)]))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `type 'AgentEvent' has no member 'apiError'`.

- [ ] **Step 3: Implement**

`AgentKind.swift`, in `AgentEvent`:

```swift
/// This tab's last turn died on an API error, or `nil` because a newer record cleared it.
///
/// Like `.subagentCount` and unlike `.activity`, this is folded from transcript records
/// before it reaches here — the store never learns which channel carried it. Only the claude
/// runtime raises it today; codex's failure shape is a separate probe.
case apiError(SessionAPIError?)
```

`ClaudeRuntime.swift`, in the `TranscriptWatcher(...)` call after `onSubagentCount:`:

```swift
onAPIError: { subscribers.emit(.apiError($0)) },
```

`SessionStore.swift` — the property, beside `backgroundWorkSessions`:

```swift
/// Sessions whose last turn died on an API error, keyed by tab. Orthogonal to `statuses`,
/// like `backgroundWorkSessions`: a tab in here reports `activity: .idle`, because that is
/// what `claude` writes to its status file once the turn dies. Telling those two idles apart
/// is the whole point of the badge.
@Published private(set) var apiErrors: [UUID: SessionAPIError] = [:]
```

The single writer, beside `setUnread`:

```swift
/// The only writer of `apiErrors`, for `setUnread`'s reasons: the mutation and its event must
/// not be separable, or a connected phone goes silently wrong until it reconnects. The
/// unchanged guard also keeps a client from receiving an event per poll for a dead session.
@discardableResult
private func setAPIError(_ id: UUID, _ error: SessionAPIError?) -> Bool {
    guard apiErrors[id] != error else { return false }
    apiErrors[id] = error
    emit(.apiErrorChanged(id: id, error: error))
    return true
}
```

Widen `apply` and add its arm:

```swift
/// One place where an agent's report becomes tab state, whichever agent reported it.
///
/// Internal rather than private so the fleet-emission and projection suites can deliver an
/// `AgentEvent` without standing up a runtime and a live transcript — the same seam
/// `applyRegistry` is for the status path.
func apply(_ event: AgentEvent, to tabID: UUID) {
    switch event {
    ...
    // Persisted only when it actually changed: `.progressed` fires on every turn, and
    // `setAPIError`'s guard is what keeps that from rewriting sessions.json each time.
    case .apiError(let error):
        if setAPIError(tabID, error) { persist() }
    }
}
```

In `wire(_:)`, pass `apiError: apiErrors[session.id]`.

In the snapshot build (~2321), beside `hasBackgroundWork`:

```swift
// `nil` for the common case, like `unread` and `hasBackgroundWork` above, so the file stays
// readable.
apiError: apiErrors[$0.id],
```

In `restore()` (~2116), beside the `hasBackgroundWork` seed:

```swift
// Assigned directly rather than through `setAPIError`, for exactly the reason the
// `backgroundWorkSessions` insert above is: this runs inside `SessionStore.init`, before
// `FleetService` attaches the replicator, so an emit here would go nowhere. Moving it after
// that wiring would require it to emit.
if let error = entry.apiError { apiErrors[entry.id] = error }
```

Wherever `closeSession` calls `setUnread(id, false)`, add `setAPIError(id, nil)` beside it so a closed tab leaves no entry behind.

`SessionPersistence.swift` — add to `Entry` beside `hasBackgroundWork`, plus the matching defaulted `init` parameter:

```swift
/// Why this session's last turn died, if it died on an API error. Absent means it did not.
/// Optional for the same load-bearing reason as `activity`: synthesized `Codable` decodes an
/// optional with `decodeIfPresent`, so every existing `sessions.json` still decodes instead
/// of throwing and wiping every tab on the first launch after this change.
var apiError: SessionAPIError?
```

`FleetProjection.swift` — add `apiError: SessionAPIError? = nil` to the session-level `project` (before `planGates`) and pass it into the `WireSession`; add `apiErrors: [UUID: SessionAPIError] = [:]` to the repo-level `project`, passing `apiError: apiErrors[$0.id]` down; in `snapshot(of:)` pass `apiErrors: store.apiErrors`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expect PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ Tests/FlightDeckTests/
git commit -m "hold, persist and project a session's api error"
```

---

### Task 6: The Mac glyph

**Files:**
- Modify: `Sources/FlightDeck/SessionStatusIcon.swift`
- Modify: `Sources/FlightDeck/SidebarRow.swift` (the `SessionStatusIcon(` call site)

**Interfaces:**
- Consumes: `SessionStore.apiErrors` (Task 5), `SessionAPIError.label` (Task 1).
- Produces: `SessionStatusIcon(status:unread:hasBackgroundWork:apiError:)`, `apiError` defaulted to `nil`.

**No new unit test, deliberately.** `SessionStatusIcon` is a SwiftUI view with no logic reachable from the headless suite — its precedence is three `if` branches, and extracting them to satisfy a test would be worse code. The label it renders is already pinned by Task 1, and the rendering is covered by the visual check in Step 3 plus the existing UITest suite. Do not write a test that passes before the change and call it TDD.

- [ ] **Step 1: Implement**

Add the property to `SessionStatusIcon`:

```swift
var apiError: SessionAPIError?
```

Add a branch **ahead of** the existing `if let status` / `else if unread`:

```swift
if let apiError {
    // Wins outright — over the idle dot, over unread, and over the activity glyph.
    //
    // The justification is the clearing rule: this flag only survives while no newer
    // transcript record has arrived, so if it is set, the last thing that actually happened
    // in this conversation WAS an error, whatever the status file currently claims. A status
    // file reading `busy` against a transcript whose last record is a failure is precisely
    // the stale-status case this badge exists to expose, so deferring to it would defeat the
    // feature. The window is small: the first record of a genuine new turn clears the flag.
    //
    // Red and a triangle: distinct in BOTH channels, per the HIG rule this file already
    // enforces. Orange is spoken for by `waiting` and must not be reused.
    symbol("exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .help(apiError.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(apiError.label)
        .accessibilityIdentifier("session-status")
} else if let status {
    ...
```

In `SidebarRow.swift`, pass `apiError: store.apiErrors[session.id]` at the call site.

- [ ] **Step 2: Build and run the suite**

Run: `./scripts/build.sh` — expect a clean build.
Run: `./scripts/test-unit.sh` — expect PASS (no regressions).

- [ ] **Step 3: Look at it**

Launch the Debug build **in place**. Never swap `/Applications` — that kills every other session on this machine.

```bash
open -a "$PWD/DerivedData/Build/Products/Debug/Flight Deck.app" --args -FlightDeckResetState YES
```

Append an error record to a scratch session's transcript (see Verification below) and confirm: a red triangle replaces the idle dot on that row, and hovering reads `Stopped — API error 529 (overloaded)`.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlightDeck/SessionStatusIcon.swift Sources/FlightDeck/SidebarRow.swift
git commit -m "badge a session that died on an api error"
```

---

### Task 7: The phone glyph

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionStatusGlyph.swift` (`body`, a new `activityGlyph`, and `label(for:)`)
- Test: `Tests/FlightDeckMobileTests/SessionStatusGlyphTests.swift`

**Interfaces:**
- Consumes: `WireSession.apiError` (Task 2), `SessionAPIError.label` (Task 1).
- Produces: nothing downstream.

**The trap this task exists to avoid:** `baseLabel(for:)` returns `nil` when `activity == nil`, and `body`'s `nil` branch renders `Color.clear` with **no accessibility element**. A session that died on a 529 and whose process then exited has exactly that shape — so the error branch must sit ahead of the activity switch in *both* functions, or the badge silently never appears in the case that matters most.

- [ ] **Step 1: Write the failing test**

```swift
/// The label is the Mac's, from the same function — not a re-pinned literal. That is the
/// whole reason `SessionAPIError` lives in FleetKit.
func testAPIErrorLabelMatchesTheSharedOne() {
    let error = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
    let session = WireSession(id: UUID(), title: "t", agent: "claude",
                              activity: "idle", apiError: error)
    XCTAssertEqual(SessionStatusGlyph.label(for: session), error.label)
}

/// The case that matters most: the session died AND its process exited, so `activity` is nil.
/// `baseLabel` returns nil for that and the glyph's nil branch renders no accessibility
/// element at all — so the error branch has to come first, or the badge never appears.
func testAPIErrorLabelSurvivesANilActivity() {
    let error = SessionAPIError(status: 529, kind: "overloaded")
    let session = WireSession(id: UUID(), title: "t", agent: "claude", apiError: error)
    XCTAssertEqual(SessionStatusGlyph.label(for: session), error.label)
}

/// The error outranks unread, matching the Mac's precedence exactly.
func testAPIErrorOutranksUnread() {
    let error = SessionAPIError(status: 500, kind: "server_error")
    let session = WireSession(id: UUID(), title: "t", agent: "claude",
                              activity: "idle", isUnread: true, apiError: error)
    XCTAssertEqual(SessionStatusGlyph.label(for: session), error.label)
}

/// No error means every existing label is byte-identical to what it was.
func testLabelsAreUnchangedWithoutAnError() {
    let session = WireSession(id: UUID(), title: "t", agent: "claude", activity: "idle")
    XCTAssertEqual(SessionStatusGlyph.label(for: session), "Idle")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-ios.sh`
Expected: FAIL on the first three — `label(for:)` returns the activity label, and `nil` for the nil-activity case.

- [ ] **Step 3: Implement**

Move the existing `switch session.activity { … }` out of `body` verbatim into a new property, and make `body` the precedence decision. Extracting rather than nesting keeps the ViewBuilder readable and avoids `AnyView`:

```swift
var body: some View {
    // Ahead of the activity switch, and winning over every branch of it — the Mac's
    // precedence, for the Mac's reason (see `SessionStatusIcon`). Critically it also wins
    // over the `nil` branch, which renders no accessibility element at all: a session that
    // died and whose process then exited has `activity == nil`, and that is the case this
    // badge matters most for.
    if let apiError = session.apiError {
        glyph(
            Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                .foregroundStyle(.red),
            label: apiError.label)
    } else {
        activityGlyph
    }
}

/// The activity vocabulary, unchanged — moved out of `body` only so the error branch above
/// can precede it without nesting a switch inside an `if`.
@ViewBuilder
private var activityGlyph: some View {
    switch session.activity {
    // ... the existing branches, verbatim
    }
}
```

In `label(for:)`, **before** the `baseLabel` guard:

```swift
// Before `baseLabel`, deliberately: that function returns nil for a nil activity, and this
// state must still announce. Not appended like the background clause either — this replaces
// the label rather than decorating it, because the session is not in the state the base
// string would describe.
if let apiError = session.apiError { return apiError.label }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-ios.sh` — expect PASS.
Run: `./scripts/build-ios.sh` — expect a clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/SessionStatusGlyph.swift Tests/FlightDeckMobileTests/SessionStatusGlyphTests.swift
git commit -m "show the api-error badge on the phone"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/FOLLOWUPS.md`, `docs/MOBILE.md`

- [ ] **Step 1: Add the non-goals to `docs/FOLLOWUPS.md`**

Match the file's existing format. Four entries:

- **No backfill of API errors missed while closed.** `TailReader` starts a first look at an existing transcript at its current end, so a session that died while Flight Deck was not running gets no badge beyond what the snapshot restored. Scanning backwards means finding the last assistant record and proving nothing followed it.
- **The API-error badge is claude-only.** `WireSession.apiError` is agent-agnostic, but only `ClaudeSession.events(inObject:)` raises it. Codex's failure shape needs its own probe against a current `codex app-server`; a claim about an older version is not evidence.
- **No notification when a session dies on an API error.** Deferred: a capacity blip kills many sessions at once, so this edge needs its own suppression design in `SessionNotificationPolicy` rather than riding the idle/waiting rules.
- **No project-header rollup for the API-error badge.** `SessionActivity.summaryRank` ranks activities and this is not one, so a collapsed project whose child died still shows the child's activity.

- [ ] **Step 2: Add the glyph to `docs/MOBILE.md`**

In the checklist of what the phone renders: a red `exclamationmark.triangle.fill` for `WireSession.apiError`, taking precedence over every activity branch **including `nil`**, with its VoiceOver string from `SessionAPIError.label` in FleetKit rather than a re-pinned literal.

- [ ] **Step 3: Commit**

```bash
git add docs/FOLLOWUPS.md docs/MOBILE.md
git commit -m "document the api-error badge's limits"
```

---

## Verification

From a clean tree, after Task 8:

1. `./scripts/test-unit.sh` — full macOS suite, ~8 min. Expect PASS.
2. `./scripts/test-ios.sh` — required; this touched FleetKit and FlightDeckMobile. Expect PASS.
3. `./scripts/build.sh` and `./scripts/build-ios.sh` — both clean.
4. **End to end, by hand.** A real 529 cannot be summoned, so append records to a **scratch** session's transcript and watch both devices:

```bash
# The transcript the tab is actually tailing — the app exposes it via watchedTranscriptURL(of:).
T=~/.claude/projects/<encoded-project>/<conversation-id>.jsonl
echo '{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":529,"error":"overloaded","apiErrorIsTransient":true,"message":{"content":[{"type":"text","text":"API Error: 529"}]}}' >> "$T"
# Expect within one poll (~500 ms): red triangle on that row, tooltip
# "Stopped — API error 529 (overloaded)", and the same badge on a paired phone.

echo '{"type":"user","message":{"content":[{"type":"text","text":"keep going"}]}}' >> "$T"
# Expect: badge clears on both devices.
```

Use a scratch session, never one doing real work — appended records are visible to `claude` on its next resume.

5. **Do not loop `./scripts/smoke.sh`.** If a GUI check is wanted, run it once.

## Note carried from the spec

**Fixtures are constructed, not captured.** No transcript on this machine contains an `isApiErrorMessage` record; the field names come from the CLI binary. The tests prove the parser handles the shape read out of `claude` 2.1.259, not that that shape lands on disk. The cheap confirmation is to pin a real record as a fixture the first time a session here does die on a 529 — worth doing, and worth saying out loud until it is done.
