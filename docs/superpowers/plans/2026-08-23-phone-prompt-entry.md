# Phone Prompt Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person can type a message on their paired iPhone and have it typed into, and submitted to, a live Claude Code session on their Mac — with an honest account on the phone of whether it landed.

**Architecture:** A new `FleetCommand.prompt(id:token:text:)` travels southbound as a `cmd`, answered `ack`/`err` on its `cid`. `FleetConnector` gains a second pending table so a command's ack reaches a caller for the first time. On the Mac, `SessionStore.submitPrompt` is the single decision point: claude only, through the existing `inject` funnel, with a per-tab FIFO for prompts that arrive mid-turn. The phone draws no optimistic timeline row; it keeps an outbox beside the conversation that retires itself when the agent's own transcript comes back holding the message.

**Tech Stack:** Swift 6 (`FleetKit`, `FlightDeckMobile`), Swift 5 (`Sources/FlightDeck`), Network.framework, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` — but read the next section first. Four of its statements, and one of the statements in this plan's own brief, are contradicted by the code.

---

## Findings that change the spec and the brief, decided here

**Read this section before Task 1.** Each was checked against the source on this branch, not inherited.

### 1. §9 "Prompt bridging" is not this feature, and this plan must not consume its names.

§9 designs a `PromptBroker`, a `PendingPrompt`, `prompt.opened` / `prompt.closed`, and a hook helper that blocks on a unix socket until Flight Deck returns a decision. Every word of that is about **answering a permission request the agent raised** — a question travelling agent → user. Typing a message to an agent is the opposite direction and is designed nowhere in the spec. This plan is a new capability, not "slice 2's §9".

### 2. `TimelineItem.Kind.prompt` belongs to §9, and a user's message is a `.userTurn`.

The brief states that §6's `.prompt` kind "already ships in the wire vocabulary specifically so this would be a Mac-side change and not a protocol break." Both halves are false.

`rg 'Kind.prompt|\.prompt\b' Sources/` finds `.prompt` only in its own declaration in `Sources/FleetKit/Timeline.swift:24`. Nothing emits it, and `Timeline.swift`'s own comment on `Status.streaming` says the vocabulary was widened for "slice 2's prompt bridging (spec §9)" — the permission path. A message the user typed is written by claude into its transcript as a `user` record, and `ClaudeTimelineMapper` already maps that to `.userTurn` (`ClaudeTimelineMapper.swift:55`, `:83`). **Squatting on `.prompt` here would make the case unusable for the thing it was reserved for.** This plan emits nothing new into `TimelineItem` at all.

And the change is not Mac-side only: `FleetCommand` has two cases, `markRead` and `markUnread`, and no prompt op. Task 2 adds one.

### 3. The phone cannot hear an `ack` today. §4 defines the frame; nothing on the client uses it.

`FleetConnector.send(_ command: FleetCommand)` returns `Void` and files nothing. `FleetConnector.apply`'s `.ack` arm says so outright: *"An `ack` for a command matches nothing here and is a no-op, which is what it has always been."* So a `cmd` from the phone is fire-and-forget: it either happens or it does not, and the phone is told nothing either way. That is tolerable for `markRead`, whose effect arrives as a northbound event or does not matter. It is not tolerable for a prompt. **Task 3 is not optional polish; without it the failure mode is exactly the one the brief names — a person believing they told an agent something.**

### 4. Nothing polls the session timeline. `loadNewer()` has no caller.

`SessionTimelineModel.loadNewer()`'s doc comment says "Called by the poll and by a fleet event for this session." `rg 'loadNewer' Sources/FlightDeckMobile/` returns only its own declaration and its own comment. `SessionTimelineScreen` calls `loadLatest()` once, from `.task(id: model.sessionID)`. A session screen is a static snapshot from the moment it opens.

This matters here and nowhere else so far: the outbox is retired by the transcript, and without a fetch after the ack the transcript is never re-read. Task 8 has the ack trigger exactly one `loadNewer()`. **This plan deliberately does not add a timer-driven poll** — that is a separate decision about battery and about a screen that is not this plan's to redesign, and one fetch per send is what this feature needs.

### 5. Codex has no route to a live turn, and the refusal is a finding rather than a gap.

Both halves of a possible codex route are closed, and each is documented in the code:

- **The app-server cannot start a turn.** A codex tab is a `codex resume <id>` TUI in its own pty, holding the thread's writer lock. `CodexAdapter.prepare` (`Sources/FlightDeck/Agents/Codex/CodexAdapter.swift:43-72`) documents the exact refusal it had to work around: `thread/resume failed: thread <id> already has an active writer (code -32600)`. Rename works over that connection because `thread/name/set` is metadata; a turn is not.
- **The pty route has no input box to read.** `InputBar` is Claude Code's box, and `InputBar.read` locks onto the last line starting `❯` — a glyph a plain shell prompt also draws. `SessionStore.rename`'s comment is the record of what that costs: codex's rename once queued `/rename <name>` for a pty that would eventually match, and *"a match would have sent Ctrl-U and pasted `/rename foo` into the user's live codex session."* Guessing at a second TUI's input box with the user's own words is a worse version of a bug this codebase has already paid for.

So the answer is `unsupported_agent`, said out loud on the phone, and the composer is disabled with a reason before the user types anything.

§5's rule — *"anything the phone can do, the Mac's own UI should be able to do"* — is satisfied: the Mac's own UI cannot type into a codex tab either, other than by the user focusing it and typing.

---

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No AppKit, no UIKit, no SwiftUI, no Observation. `FleetKitiOS` compiles the same sources for iOS and is what enforces it.
- **`FleetKit` and `FlightDeckMobile` build in Swift 6 language mode. `Sources/FlightDeck` is Swift 5.** `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate (vendored Ghostty is not Swift-6 clean) — do not "fix" it.
- **`FleetSocketServer` and `FleetConnector` confine their state to `queue`** (`.main` in production) and assert it with `dispatchPrecondition`. Every closure this plan adds keeps that discipline. No `nonisolated(unsafe)`, no `@unchecked Sendable`.
- **Sessions are keyed on the tab `id`, never `conversationId`.** Every frame this plan adds carries a tab id.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`.
- **Mobile sources stay flat.** `build-ios.sh`'s type-check fallback globs `Sources/FlightDeckMobile/*.swift` only; a file in a subdirectory is invisible to it on a machine with no iOS platform installed.
- **`project.yml` needs no change.** `Sources/FleetKit`, `Sources/FlightDeck` and `Sources/FlightDeckMobile` are recursive path entries. It is modified in the working tree by another agent — leave it alone.
- **Three files are being edited concurrently on this branch.** `Sources/FlightDeck/SessionStore.swift` and `Sources/FlightDeck/Fleet/TimelineService.swift` (one agent), and everything under `Sources/FlightDeckMobile/` (another). Tasks 4, 5, 6, 8 and 9 all land in those files. **Run `git status` and re-read each file immediately before editing; merge into what is there rather than pasting over it.** Never `git stash`, never `git checkout .`, never revert blind — the stack is shared.
- **Every test must be shown to fail against the bug it exists for.** Each task below carries an explicit **"prove it can fail"** step naming the exact mutation, and the result goes in the task report. This is not ceremonial: five tests were deleted during the preceding plan for being unable to fail at all, and three briefs shipped fixtures shaped so the named bug would pass. **When you write a fixture, check that it distinguishes the failure** — two values that differ, not two that happen to agree.
- **Verification per task:** `./scripts/build.sh`, `./scripts/test-unit.sh`, `./scripts/build-ios.sh`, `./scripts/test-ios.sh`. Baselines as this was written are **1491 unit / 47 iOS** — measure your own before Task 1 and report deltas against that, because every handed-down figure in this work has been wrong at least once.
- **Never run `./scripts/smoke.sh`.** It seizes the foreground for ~70s. **Never run `build.sh` while `test-unit.sh` is live** — they share `DerivedData`.

---

## Security: what this widens, stated plainly

**It widens what a paired device can do, and materially.** Before this, the two commands a phone could send named a tab and carried no payload: `markRead` and `markUnread` flip one boolean in Flight Deck's own state. After it, a paired device can cause arbitrary text to be typed into, and submitted to, a Claude Code process running with the user's full privileges — which reads any file the user can read, runs any command, and reaches the network.

The **trust level** is unchanged. §11 already says the phone is fully privileged once paired, and it can already read every session's entire transcript, which is a comparable disclosure. The **blast radius** is not unchanged: reading is not writing, and a metadata write is not code execution. Say that rather than "a paired phone is already privileged, so this is free."

Two guards the existing commands have no need for and this one does:

1. **`PromptText` rejects C0 controls and DEL** (Task 1). `sendText` is a *paste*, not typing, and ghostty wraps a paste in bracketed-paste markers — `TextInjecting.sendReturn()`'s comment documents `\u{1b}[200~ … \u{1b}[201~` and is the reason Return goes through `ghostty_surface_key` instead. A payload containing `ESC` can therefore close the bracket early, after which the remainder is raw terminal input rather than content: keystrokes, not text. **`vendor/ghostty` in this checkout holds artifacts only, not sources, so whether libghostty strips that sequence cannot be verified here.** That is precisely why it is rejected before it reaches the pty rather than assumed harmless one layer down.
2. **The `.shell` and no-status refusal** (Task 4). At a bare shell prompt the text is a command, not a message. `inject`'s idle gate already excludes `.shell`, and `submitPrompt` refuses rather than queues, because a shell does not become claude by waiting. This is the same class of failure as the codex `/rename` incident and it is the one place where a wrong answer is arbitrary code execution rather than a stray message.

What this deliberately does **not** add: a confirmation step on the Mac, a per-prompt approval, or an allow-list of text. A phone that has to be confirmed on the Mac for every message is not a companion. The control §11 names is the right one — revocation plus the attached-device indicator, both shipped, plus `DevicesSettingsTab` showing which device is attached while it does this.

**One gap, recorded rather than argued away:** a paired phone can prompt a tab the user is not looking at. There is no per-tab opt-in and no Mac-side notification that a phone just typed something; the only signal is the terminal itself changing. That is a scope decision, not an oversight, and it belongs in `docs/FOLLOWUPS.md` if anyone disagrees with it.

---

## The wire shape, and why

**A prompt is a `cmd`, not a `req`.** `FleetRequest`'s own doc comment draws the line this decision sits on: a request asks the Mac to **tell** the client something and *"its whole point is the data it carries back"*; a command asks the Mac to **do** something, and `ack` means *dispatched, not done* — a rule written, per §4, because *"typing into a pty has no delivery confirmation, so the observable effect always arrives separately."* A prompt is the operation that rule describes. Its observable effect is the `.userTurn` the agent writes into its own transcript, which the already-shipped history channel reads back.

Making it a `req` would mean inventing a second reply payload beside `TimelinePage`, widening `ServerFrame.page`'s hard-coded `try c.decode(TimelinePage.self, forKey: .page)`, and retyping `FleetConnector.pending` — a protocol change across a channel that is already shipped and reviewed, to carry a boolean the transcript settles within seconds anyway.

The gap that made `req` tempting is real and is closed differently: **`ack` correlation on the client** (Task 3). A second pending table, sharing the one `cid` space `FleetClient.nextCID` already mints for both verbs, so a caller learns the Mac *heard* it without any change to the frames.

One consequence to hold onto through Task 2: **`FleetSocketServer.onUndecodable` salvages `t == "req"` and nothing else, deliberately.** A `cmd` this build cannot parse takes the socket down. So `FleetCommand`'s decoder must never throw over a prompt's *content* — only over an unknown `op` or a missing key. Length and character refusals are the Mac's, answered as `err`.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `Sources/FleetKit/PromptText.swift` | Create | The one validator both ends run; the Mac's is the guarantee |
| `Sources/FleetKit/Frames.swift` | Modify | `FleetCommand.prompt` + a codec that reads `op` first |
| `Sources/FleetKit/FleetConnector.swift` | Modify | `send(_:then:)`, `pendingAcks`, ack/err routing, drain |
| `Sources/FleetKit/PromptOutbox.swift` | Create | Phone-side outbox value type and its transcript reconciliation |
| `Sources/FlightDeck/SessionStore.swift` | Modify | `PromptDispatch`, `submitPrompt`, `promptQueue`, flush, close cleanup |
| `Sources/FlightDeck/Fleet/FleetService.swift` | Modify | `.prompt` → `submitPrompt` → `ack`/`err` |
| `Sources/FlightDeckMobile/SessionTimelineModel.swift` | Modify | `PromptSending`, `send(_:)`, per-send deadline, reconcile on merge |
| `Sources/FlightDeckMobile/FleetModel.swift` | Modify | `sendPrompt` forwarding, `PromptSending` conformance |
| `Sources/FlightDeckMobile/PromptComposer.swift` | Create | The field, the send button, the outbox rows, the unavailable reason |
| `Sources/FlightDeckMobile/SessionTimelineScreen.swift` | Modify | Mount the composer as a bottom safe-area inset |
| `Tests/FlightDeckTests/PromptTextTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptCommandCodingTests.swift` | Create | |
| `Tests/FlightDeckTests/FleetConnectorAckTests.swift` | Create | |
| `Tests/FlightDeckTests/PhonePromptDispatchTests.swift` | Create | |
| `Tests/FlightDeckTests/PhonePromptQueueTests.swift` | Create | |
| `Tests/FlightDeckTests/PhonePromptLoopbackTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptOutboxTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` | Modify | `StubPager` gains `PromptSending` |
| `Tests/FlightDeckMobileTests/PromptComposerTests.swift` | Create | |
| `docs/MOBILE.md` | Modify | Four manual checklist items |

`PromptOutbox` lives in `FleetKit` rather than in the phone app for the reason `TimelineFeed` does: it is a pure value computation over `[TimelineItem]`, and there it is covered by the macOS suite rather than only by a simulator run.

---

## Task 1: `PromptText` — the one rule, in one place

**Files:**
- Create: `Sources/FleetKit/PromptText.swift`
- Test: `Tests/FlightDeckTests/PromptTextTests.swift`

**Interfaces:**
- Consumes: `TimelineLimits.maxItemBytes` (existing, `Sources/FleetKit/TimelineLimits.swift`)
- Produces:
  - `public struct PromptText: Equatable, Hashable, Sendable`
  - `public init?(_ raw: String)`
  - `public let value: String`
  - `public static func rejection(for raw: String) -> PromptText.Rejection?`
  - `public enum PromptText.Rejection: String, Equatable, Sendable { case empty = "prompt_empty", tooLong = "prompt_too_long", controlCharacters = "prompt_control_characters" }`
  - `public static let maxCharacters = 8_000`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptTextTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The validator that stands between a paired phone and a pty.
///
/// Every test here is written against a specific way of getting it wrong, and the fixtures
/// are built to distinguish: the control-character case carries a real bracketed-paste
/// terminator rather than a bare `\u{1b}`, and the tab/newline case carries both characters
/// rather than one, so a rule that handled only half of either would fail rather than pass.
final class PromptTextTests: XCTestCase {
    /// The load-bearing one. `sendText` is a paste, and ghostty wraps a paste in
    /// `ESC [ 200~ … ESC [ 201~`. Text carrying the closing marker ends the paste early and
    /// everything after it is read as raw terminal input.
    func testAnEscapeSequenceIsRefusedBecauseItCanCloseABracketedPaste() {
        XCTAssertEqual(
            PromptText.rejection(for: "please continue\u{1b}[201~\u{1b}[Bmalicious"),
            .controlCharacters
        )
        XCTAssertNil(PromptText("please continue\u{1b}[201~\u{1b}[Bmalicious"))
    }

    func testACarriageReturnIsRefusedRatherThanNormalised() {
        XCTAssertEqual(PromptText.rejection(for: "one\r\ntwo"), .controlCharacters)
    }

    /// The negative control, and it needs both characters: a rule that allowed newline and
    /// rejected tab would pass a fixture holding only a newline.
    func testTabAndNewlineSurviveBecauseTheyArePastedContent() {
        XCTAssertEqual(PromptText("run this:\n\tswift build")?.value, "run this:\n\tswift build")
    }

    /// `inject` sends the text and then Return as a separate key event, so a trailing
    /// newline inserts a blank line into the input box instead of submitting anything.
    func testTrailingNewlinesAreStrippedSoReturnSubmitsRatherThanInserts() {
        XCTAssertEqual(PromptText("ship it\n\n")?.value, "ship it")
    }

    func testWhitespaceOnlyIsEmptyRatherThanSendable() {
        XCTAssertEqual(PromptText.rejection(for: "   \n  \t "), .empty)
        XCTAssertNil(PromptText("   \n  \t "))
    }

    /// Both sides of the boundary, so an off-by-one in either direction fails.
    func testTheCapIsInclusive() {
        XCTAssertNil(PromptText.rejection(for: String(repeating: "a", count: PromptText.maxCharacters)))
        XCTAssertEqual(
            PromptText.rejection(for: String(repeating: "a", count: PromptText.maxCharacters + 1)),
            .tooLong
        )
    }

    /// The cap is not arbitrary: the phone confirms a send by finding its own text verbatim
    /// in a transcript page, and a body at or over `maxItemBytes` comes back truncated. A
    /// prompt that could be truncated is a prompt whose confirmation could never arrive.
    func testTheCapSitsBelowTheItemBodyCapSoAConfirmationCanAlwaysArrive() {
        XCTAssertLessThan(PromptText.maxCharacters, TimelineLimits.maxItemBytes)
    }

    /// These strings are `err`'s `code` on the wire, so a case rename must not silently
    /// become a protocol break — the same rule `TimelineAnchor.name` states.
    func testRejectionCodesAreTheWireSpelling() {
        XCTAssertEqual(PromptText.Rejection.empty.rawValue, "prompt_empty")
        XCTAssertEqual(PromptText.Rejection.tooLong.rawValue, "prompt_too_long")
        XCTAssertEqual(PromptText.Rejection.controlCharacters.rawValue, "prompt_control_characters")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PromptTextTests|error:"`
Expected: compile failure — `cannot find 'PromptText' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FleetKit/PromptText.swift`:

```swift
import Foundation

/// Text a client asked the Mac to type into a live agent, checked before anyone types it.
///
/// **This is the guard the existing commands do not need.** `markRead` and `markUnread` name
/// a tab and carry no payload; a prompt carries a string that ends up in
/// `TextInjecting.sendText`, which is a *paste* into a pty running a full-screen TUI. Ghostty
/// wraps a paste in bracketed-paste markers — `ESC [ 200~ … ESC [ 201~`, which is why
/// `sendReturn()` goes through `ghostty_surface_key` instead — so a payload containing `ESC`
/// can close the bracket early and have everything after it read as raw terminal input rather
/// than as content: keystrokes, not text. `vendor/ghostty` in this checkout holds build
/// artifacts and not sources, so whether libghostty strips that sequence cannot be checked
/// here. It is refused before it reaches the pty rather than assumed harmless one layer down.
///
/// In `FleetKit` so the phone can disable its Send button on exactly the rule the Mac
/// enforces. **The phone running it is a courtesy; the Mac running it is the guarantee** —
/// `SessionStore.submitPrompt` re-checks every prompt regardless of what a client claims to
/// have checked, because a client is not trusted to have checked anything.
public struct PromptText: Equatable, Hashable, Sendable {
    /// Why a string is not sendable text. Each `rawValue` is the wire spelling carried in
    /// `err`'s `code` field, stated as a table rather than derived from the case name, for
    /// the same reason `TimelineAnchor.name` is: a case rename must not silently become a
    /// protocol break.
    public enum Rejection: String, Equatable, Sendable {
        /// Nothing but whitespace. Submitting it would press Return on an empty bar.
        case empty = "prompt_empty"
        /// Longer than `maxCharacters`.
        case tooLong = "prompt_too_long"
        /// Carries a C0 control or DEL. See this type's own comment.
        case controlCharacters = "prompt_control_characters"
    }

    /// Well under `TimelineLimits.maxItemBytes` (65,536), and that relationship is the
    /// reason for the number rather than a coincidence: the phone confirms a send by finding
    /// its own text verbatim in a transcript page, and a body at or over that cap comes back
    /// cut with `Body.truncatedBytes` set. A prompt long enough to be truncated is a prompt
    /// whose confirmation could never arrive, so it would sit in the outbox forever.
    public static let maxCharacters = 8_000

    /// Exactly what gets typed.
    public let value: String

    public init?(_ raw: String) {
        guard Self.rejection(for: raw) == nil else { return nil }
        self.value = Self.normalized(raw)
    }

    /// The reason, or `nil` when the string is sendable.
    ///
    /// Separate from `init?` because both ends need the reason and not just the verdict: the
    /// Mac has to answer *which* refusal on the wire, and the phone has to say which in copy.
    public static func rejection(for raw: String) -> Rejection? {
        let text = normalized(raw)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.count > maxCharacters { return .tooLong }
        for scalar in text.unicodeScalars {
            // Tab and newline are ordinary content inside a bracketed paste and are the two
            // controls a person legitimately pastes — a snippet of indented code has both.
            // Everything else in C0, and DEL, is not text and has no business in a message.
            if scalar == "\n" || scalar == "\t" { continue }
            if scalar.value < 0x20 || scalar.value == 0x7F { return .controlCharacters }
        }
        return nil
    }

    /// Trailing newlines only, and never `\r`: `inject` sends the text and then Return as a
    /// separate key event, so a trailing newline inserts a blank line into the input box
    /// rather than submitting anything. A `\r` survives this and is then refused above,
    /// which is the right answer — a phone has no business sending CRLF to a pty.
    private static func normalized(_ raw: String) -> String {
        var text = raw
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: baseline + 8, 0 failures.

- [ ] **Step 5: Prove each test can fail**

Apply each mutation, run only `PromptTextTests`, confirm the named test goes red, then revert:

| Mutation | Must fail |
| --- | --- |
| Delete the `scalar.value < 0x20` branch | `testAnEscapeSequenceIsRefused…`, `testACarriageReturnIsRefused…` |
| Add `scalar == "\t"` to the rejected set | `testTabAndNewlineSurvive…` |
| Delete the `while text.hasSuffix("\n")` loop | `testTrailingNewlinesAreStripped…` |
| Change `text.count > maxCharacters` to `>=` | `testTheCapIsInclusive` |
| Set `maxCharacters = 100_000` | `testTheCapSitsBelowTheItemBodyCap…` |

Record which mutation broke which test in the task report.

- [ ] **Step 6: Build the other three targets**

Run: `./scripts/build.sh && ./scripts/build-ios.sh`
Expected: `BUILD SUCCEEDED` for FlightDeck, and three for the iOS script.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/PromptText.swift Tests/FlightDeckTests/PromptTextTests.swift
git commit -m "feat: one rule for text a phone may have typed into a pty"
```

---

## Task 2: `FleetCommand.prompt` on the wire

**Files:**
- Modify: `Sources/FleetKit/Frames.swift` (the whole `FleetCommand` enum, lines 19-50)
- Test: `Tests/FlightDeckTests/PromptCommandCodingTests.swift`

**Interfaces:**
- Consumes: `PromptText.maxCharacters` (Task 1, for the oversized fixture only)
- Produces: `case FleetCommand.prompt(id: UUID, token: UUID, text: String)`, wire `op` `"session.prompt"`, keys `id`, `token`, `text` flat in the `cmd` object.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptCommandCodingTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The southbound prompt frame, and the two properties that are not obvious from its shape:
/// that it reads as one flat line in a packet dump, and that its decoder never throws over
/// its own payload.
final class PromptCommandCodingTests: XCTestCase {
    private let session = UUID()
    private let token = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Flattened into the frame's own object, exactly as `markRead` and every `req` are: one
    /// command reads as one line, which is what makes a dump usable.
    func testAPromptEncodesAsOneFlatObject() throws {
        let json = try object(.cmd(cid: 41, .prompt(id: session, token: token, text: "ship it")))
        XCTAssertEqual(json["t"] as? String, "cmd")
        XCTAssertEqual(json["cid"] as? Int, 41)
        XCTAssertEqual(json["op"] as? String, "session.prompt")
        XCTAssertEqual(json["id"] as? String, session.uuidString)
        XCTAssertEqual(json["token"] as? String, token.uuidString)
        XCTAssertEqual(json["text"] as? String, "ship it")
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "id", "token", "text"])
    }

    func testAPromptRoundTripsThroughClientFrame() throws {
        let sent = ClientFrame.cmd(cid: 9, .prompt(id: session, token: token, text: "a\n\tb"))
        let data = try JSONEncoder().encode(sent)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
    }

    /// **The rule this file exists for.** `FleetSocketServer.onUndecodable` salvages
    /// `t == "req"` and nothing else, deliberately — so a `cmd` this build cannot parse takes
    /// the socket down with it. Refusing oversized or control-bearing text in the DECODER
    /// would therefore disconnect a phone over a paste, and the phone, with the same text
    /// still in its composer, would be one tap from doing it again. It decodes; the Mac
    /// refuses it with an `err` code the phone can render.
    ///
    /// The fixture breaks BOTH rules at once, so a decoder that enforced either one fails.
    func testTextTheMacWillRefuseStillDecodesRatherThanKillingTheSocket() throws {
        let hostile = "\u{1b}[201~" + String(repeating: "x", count: PromptText.maxCharacters + 1)
        let line = """
        {"t":"cmd","cid":3,"op":"session.prompt","id":"\(session.uuidString)",\
        "token":"\(token.uuidString)","text":\(String(data: try JSONEncoder().encode(hostile), encoding: .utf8)!)}
        """
        let frame = try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8))
        guard case .cmd(3, .prompt(session, token, let text)) = frame else {
            return XCTFail("a prompt whose text the Mac will refuse must still decode as a prompt")
        }
        XCTAssertEqual(text, hostile, "and it must arrive verbatim, not sanitised in transit")
    }

    /// The old two-case shape read `id` before it read `op`. This one reads `op` first, and
    /// this is the test that says the reorder did not move `markRead`.
    func testMarkReadStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"{"t":"cmd","cid":7,"op":"session.markRead","id":"\#(session.uuidString)"}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .markRead(id: session))
        )
    }

    /// An unrecognised `op` throws, like `FleetRequest`'s and unlike `TimelineItem.Kind`'s:
    /// phone → Mac is executed rather than rendered, and there is no default that is not a
    /// wrong answer.
    func testAnUnknownOpStillThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.detonate","id":"\#(session.uuidString)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// A prompt missing its token is not a prompt. Refused as the command it claimed to be,
    /// which is what reading `op` first buys.
    func testAPromptWithoutATokenThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.prompt","id":"\#(session.uuidString)","text":"hi"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PromptCommandCoding|error:"`
Expected: compile failure — `type 'FleetCommand' has no member 'prompt'`.

- [ ] **Step 3: Replace `FleetCommand` in `Sources/FleetKit/Frames.swift`**

Replace the whole enum (currently lines 19-50) with:

```swift
public enum FleetCommand: Codable, Equatable, Sendable {
    case markRead(id: UUID)
    case markUnread(id: UUID)

    /// Type `text` into tab `id`'s live agent and submit it.
    ///
    /// **A `cmd` and not a `req`, and `FleetRequest`'s own doc comment draws the line.** A
    /// request asks the Mac to *tell* the client something and its whole point is the data
    /// carried back; a command asks the Mac to *do* something, and `ack` means dispatched,
    /// not done — a rule §4 states because typing into a pty has no delivery confirmation.
    /// This is the operation that rule was written for. Its observable effect arrives
    /// separately, as the `.userTurn` the agent writes into its own transcript and the phone
    /// reads back over the history channel.
    ///
    /// Making it a request would mean inventing a second reply payload beside `TimelinePage`,
    /// widening `ServerFrame.page`, and retyping `FleetConnector.pending` — a change across a
    /// shipped channel to carry a boolean the transcript settles anyway. What made a request
    /// tempting is that a `cmd` told the caller nothing; that is closed instead by
    /// `FleetConnector.send(_:then:)`, which correlates the `ack` on the same `cid`.
    ///
    /// `token` is the client's own idempotency key, minted once per composed message. It is
    /// the entire answer to "what if the phone retries" — see `SessionStore.submitPrompt`,
    /// which dedupes on it and acks a repeat without queueing anything.
    case prompt(id: UUID, token: UUID, text: String)

    enum CodingKeys: String, CodingKey { case op, id, token, text }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
        case prompt = "session.prompt"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markRead(let id):
            try c.encode(Op.markRead, forKey: .op)
            try c.encode(id, forKey: .id)
        case .markUnread(let id):
            try c.encode(Op.markUnread, forKey: .op)
            try c.encode(id, forKey: .id)
        case .prompt(let id, let token, let text):
            try c.encode(Op.prompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(text, forKey: .text)
        }
    }

    /// `op` is read BEFORE `id`, where the two-case version read `id` first. That mattered
    /// not at all while every case had the same one field and matters now: a prompt missing
    /// its `token` must be refused as the *prompt* it claimed to be.
    ///
    /// **`text` is decoded as an ordinary `String` and is never judged here.** An unknown
    /// `op` throws — the phone → Mac direction rule `FleetRequest` states, because a command
    /// that cannot be understood cannot be executed. But a *length* or *content* refusal must
    /// not throw, and the reason is `FleetSocketServer.onUndecodable`: it salvages
    /// `t == "req"` and nothing else, deliberately, so a `cmd` this build cannot parse ends
    /// the socket. A phone that pasted a control character would lose its fleet connection,
    /// reconnect, and — with the text still sitting in its composer — be one tap from doing it
    /// again. So hostile text decodes cleanly and `SessionStore.submitPrompt` refuses it with
    /// an `err` code the phone can render into a sentence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .markRead:
            self = .markRead(id: try c.decode(UUID.self, forKey: .id))
        case .markUnread:
            self = .markUnread(id: try c.decode(UUID.self, forKey: .id))
        case .prompt:
            self = .prompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                text: try c.decode(String.self, forKey: .text)
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: baseline + 14 cumulative, 0 failures. Existing `FleetFrameCodingTests` must still pass unchanged — `FleetCommand` is exhaustively switched in `FleetService.apply`, so a non-exhaustive switch there is a compile error you will fix in Task 6; until then `./scripts/build.sh` fails and that is expected.

Note: **`./scripts/build.sh` will fail after this step** with `switch must be exhaustive` in `FleetService.apply`. That is the intended intermediate state; `./scripts/test-unit.sh` builds the same target and fails the same way. To keep this task independently verifiable, add the `FleetService` arm now as a one-line placeholder that refuses:

In `Sources/FlightDeck/Fleet/FleetService.swift`, inside `apply(_:cid:)`:

```swift
        case .prompt:
            // Wired for real in Task 6. Refused rather than acked in the meantime, so an
            // intermediate build cannot silently claim to have typed something.
            return .err(cid: cid, code: "unhandled")
```

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `init(from:)`'s `.prompt` arm, add `guard PromptText(text) != nil else { throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "") }` | `testTextTheMacWillRefuseStillDecodes…` |
| In `encode`, nest the prompt under a `"prompt"` key instead of flattening | `testAPromptEncodesAsOneFlatObject` |
| Decode `id` before the `switch`, as the old version did, and use `decodeIfPresent` for `token` | `testAPromptWithoutATokenThrows` |
| Add a `default: self = .markRead(id: ...)` fallback to the op switch | `testAnUnknownOpStillThrows` |

- [ ] **Step 6: Verify**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Frames.swift Sources/FlightDeck/Fleet/FleetService.swift \
        Tests/FlightDeckTests/PromptCommandCodingTests.swift
git commit -m "feat: a prompt is a command on the wire"
```

---

## Task 3: The phone hears an `ack`

**Files:**
- Modify: `Sources/FleetKit/FleetConnector.swift` (add `pendingAcks` beside `pending` ~line 86; add `send(_:then:)` after `send(_:)` ~line 147; add `resolveAck` after `resolve` ~line 183; extend `apply`'s `.err`/`.ack` arms ~line 319; extend `drainPending` ~line 473)
- Test: `Tests/FlightDeckTests/FleetConnectorAckTests.swift`

**Interfaces:**
- Consumes: `FleetCommand.prompt` (Task 2), `FleetRequestError` (existing)
- Produces: `public func FleetConnector.send(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void)`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/FleetConnectorAckTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit

/// The connector's command half, against a real listener.
///
/// Until this existed a `cmd` from the phone was fire-and-forget: `send(_:)` returned `Void`
/// and `apply`'s `.ack` arm said so outright — *"an `ack` for a command matches nothing here
/// and is a no-op."* That is tolerable for `markRead`, whose effect arrives as a northbound
/// event or does not matter, and is not tolerable for a prompt, where being told nothing
/// leaves a person believing they told an agent something.
///
/// `browse: false` throughout, as every other connector test does: Bonjour on the build
/// machine finds whatever else is running and makes the race nondeterministic.
@MainActor
final class FleetConnectorAckTests: XCTestCase {
    private var server: FleetSocketServer!
    private var connector: FleetConnector!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        connector?.stop()
        connector = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func prompt(_ text: String) -> FleetCommand {
        .prompt(id: session, token: UUID(), text: text)
    }

    private func startConnector() async throws -> FleetConnector {
        server.onHello = { _, _ in [.snapshot(seq: 0, fleet: .empty, reason: .initial)] }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Test", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"], lastSeq: 0
        )
        let store = InMemoryPairedMacStore()
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 10)
        return connector
    }

    func testACommandWithACompletionIsAnsweredByItsAck() async throws {
        server.onCommand = { _, cid, _ in .ack(cid: cid) }
        let connector = try await startConnector()

        let answered = expectation(description: "acked")
        var result: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("an ack must resolve the command that earned it")
        }
    }

    /// The crossing test. A command's `err` and a request's `err` both arrive as the same
    /// frame shape, and the two tables share one `cid` space — so an implementation that
    /// tried them in the wrong table, or in only one, would deliver the refusal to the wrong
    /// caller. The request is deliberately left OUTSTANDING and asserted so, because "the
    /// command completion fired" alone passes just as happily when the fetch was stolen.
    func testACommandsErrReachesItsOwnCompletionAndLeavesAFetchAlone() async throws {
        server.onCommand = { _, cid, _ in .err(cid: cid, code: "unsupported_agent") }
        // Deliberately never answered, so the test can assert it is still waiting.
        server.onRequest = { _, _, _, _ in }
        let connector = try await startConnector()

        var pageResult: Result<TimelinePage, FleetRequestError>?
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) {
            pageResult = $0
        }

        let refused = expectation(description: "err reached the command")
        var commandResult: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { commandResult = $0; refused.fulfill() }
        await fulfillment(of: [refused], timeout: 10)

        guard case .failure(.server(let code)) = try XCTUnwrap(commandResult) else {
            return XCTFail("a command's err must reach the command's own completion")
        }
        XCTAssertEqual(code, "unsupported_agent")
        XCTAssertNil(pageResult, "the fetch was never answered and must still be waiting")
    }

    /// The rule that was already here and must survive: an `ack` correlated to a REQUEST is a
    /// server answering the wrong verb, and the caller is freed with a server error rather
    /// than left waiting.
    func testAnAckForARequestIsStillAnUnexpectedAckFailure() async throws {
        server.onRequest = { _, cid, _, reply in reply(.ack(cid: cid)) }
        let connector = try await startConnector()

        let answered = expectation(description: "request answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) {
            result = $0
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.server(let code)) = try XCTUnwrap(result) else {
            return XCTFail("an ack is no answer to a question whose point is the data back")
        }
        XCTAssertEqual(code, "unexpected_ack")
    }

    /// A socket that dies with a command outstanding must answer it. Without the drain the
    /// completion is never called at all — and a phone whose Mac went away mid-send is
    /// exactly the case this feature cannot get wrong.
    func testASocketThatDiesMidCommandAnswersDisconnected() async throws {
        // Swallowed: the command is received and never answered, so only the teardown can
        // resolve it.
        server.onCommand = { _, _, _ in .ack(cid: 0) }
        let connector = try await startConnector()

        let answered = expectation(description: "drained")
        var result: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { result = $0; answered.fulfill() }
        connector.stop()
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.disconnected) = try XCTUnwrap(result) else {
            return XCTFail("a command outstanding when the socket goes must be answered")
        }
    }

    /// The same asymmetry `request(_:then:)` documents, and for the same reason: a caller that
    /// arms a deadline before sending must be able to rely on the completion possibly having
    /// already run by the time `send` returns.
    func testSendingWithNoConnectionAnswersSynchronously() async throws {
        let connector = try await startConnector()
        connector.stop()

        var answeredBeforeReturning = false
        var returned = false
        connector.send(prompt("ship it")) { _ in answeredBeforeReturning = !returned }
        returned = true

        XCTAssertTrue(answeredBeforeReturning,
                      "with no socket the answer must come back inside the call, not later")
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "FleetConnectorAck|error:"`
Expected: compile failure — no `send(_:then:)` overload.

- [ ] **Step 3: Implement**

In `Sources/FleetKit/FleetConnector.swift`, immediately after the `pending` declaration:

```swift
    /// Outstanding **commands**, by correlation id, for callers that need to know the Mac
    /// heard them.
    ///
    /// A second table beside `pending` rather than a generic one, and it is safe because the
    /// two share a single `cid` space: `FleetClient.send` mints both verbs from one `nextCID`,
    /// deliberately (see its comment), so a number is filed in at most one of these and
    /// `apply` can try each in turn. A generic reply type would have meant retyping `pending`,
    /// widening `ServerFrame`, and touching every call site of a channel already shipped.
    ///
    /// Same exactly-once rule as `pending`, for a stronger reason: `send(_:)` without a
    /// completion drops silently when nothing is connected, which is harmless for `markRead`
    /// and is not harmless for a prompt. `drainPending()` empties this table too.
    private var pendingAcks: [Int: (Result<Void, FleetRequestError>) -> Void] = [:]
```

After the existing `send(_ command:)`:

```swift
    /// Ask the Mac to do something and hear that it heard.
    ///
    /// `ack` still means dispatched, not done — the observable effect arrives separately, as
    /// a northbound event or (for a prompt) in the agent's own transcript. What this adds
    /// over `send(_:)` is the *hearing*: `.success` on `ack`, `.failure(.server(code:))` on
    /// `err`, and `.failure(.disconnected)` — **synchronously** — when there is no socket.
    ///
    /// Same asymmetry and same reason as `request(_:then:)`: a dropped command with no caller
    /// waiting is merely ineffective, while a dropped answer to a caller that IS waiting is a
    /// person who believes they told an agent something.
    public func send(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(command)
        // `0` is `FleetClient`'s "there is no connection to write to" — a seatbelt rather
        // than a live case, kept for the reason `request(_:then:)`'s own guard is kept: the
        // alternative to a redundant check is a completion that is silently never filed.
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingAcks[cid] = completion
    }
```

After the existing `resolve(_:with:)`:

```swift
    /// Resolves one outstanding command, reporting whether there was one.
    ///
    /// Removed before it is invoked, exactly as `resolve` does and for the same reason: a
    /// completion is free to re-enter — `stop()` from inside one is ordinary — and whatever
    /// it does next must find nothing left filed under this number.
    ///
    /// The `Bool` is what lets `apply` try this table first and fall through to `pending`
    /// without either arm having to know which verb a `cid` belonged to.
    @discardableResult
    private func resolveAck(_ cid: Int, with result: Result<Void, FleetRequestError>) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingAcks.removeValue(forKey: cid) else { return false }
        completion(result)
        return true
    }
```

In `apply(_:)`, replace the `.err` and `.ack` arms with:

```swift
        case .err(let cid, let code):
            // Commands first, then requests. The two tables share one `cid` space
            // (`FleetClient.nextCID` mints for both), so a number is in at most one of them
            // and the order cannot cross an answer — it is stated so a future third table is
            // added deliberately rather than by accident.
            //
            // `code` is carried through verbatim rather than interpreted: `unhandled` (no
            // handler wired) and `unsupported` (a request this Mac cannot parse) are both on
            // this wire today, and a newer Mac may invent more.
            if resolveAck(cid, with: .failure(.server(code: code))) { return }
            resolve(cid, with: .failure(.server(code: code)))
            return
        case .ack(let cid):
            // An `ack` for a command with a completion filed is that completion's answer.
            if resolveAck(cid, with: .success(())) { return }
            // An `ack` correlated to a REQUEST is a server that answered the wrong verb —
            // "dispatched, not done" is no answer to a question whose point is the data it
            // carries back. Released as a server error rather than dropped, so the caller is
            // freed either way. An `ack` matching neither table is a `send(_:)` with no
            // completion, and is the no-op it has always been.
            resolve(cid, with: .failure(.server(code: "unexpected_ack")))
            return
```

In `drainPending()`, after the existing loop:

```swift
        // Commands too, and the same `removeAll`-before-the-loop discipline: a completion
        // that re-enters through `stop()` runs this whole drain again and must find nothing
        // left to answer a second time.
        let outstandingAcks = pendingAcks
        pendingAcks.removeAll()
        for completion in outstandingAcks.values { completion(.failure(.disconnected)) }
```

Update `drainPending`'s doc comment's first line to: `/// Answers every outstanding request and command. Drained, not cleared — see 'pending'.`

- [ ] **Step 4: Run and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: cumulative baseline + 19, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Delete the `if resolveAck(...) { return }` line from `.ack` | `testACommandWithACompletionIsAnsweredByItsAck` |
| Delete the `if resolveAck(...) { return }` line from `.err` | `testACommandsErrReachesItsOwnCompletion…` |
| Make `.ack` `return` unconditionally after `resolveAck` | `testAnAckForARequestIsStillAnUnexpectedAckFailure` |
| Delete the ack drain from `drainPending` | `testASocketThatDiesMidCommandAnswersDisconnected` |
| In `send(_:then:)`, replace both `guard`s' `completion(...)` with `pendingAcks[0] = completion` | `testSendingWithNoConnectionAnswersSynchronously` |

- [ ] **Step 6: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Tests/FlightDeckTests/FleetConnectorAckTests.swift
git commit -m "feat: a command's ack reaches the caller that sent it"
```

---

## Task 4: `SessionStore.submitPrompt` — the routing decision

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — add near `rename`/`inject` (~line 2670)
- Test: `Tests/FlightDeckTests/PhonePromptDispatchTests.swift`

**Interfaces:**
- Consumes: `PromptText`, `PromptText.Rejection` (Task 1); existing `locate(_:)`, `status(for:)`, `injector(for:)`, `inject(_:into:stillWanted:onSent:)`, `now`
- Produces:
  - `enum SessionStore.PromptDispatch: Equatable { case sent, queued, duplicate, rejected(PromptText.Rejection), unknownSession, unsupportedAgent, notRunning }`
  - `var PromptDispatch.errorCode: String? { get }`
  - `@discardableResult func SessionStore.submitPrompt(_ raw: String, token: UUID, to id: UUID) -> PromptDispatch`
  - `struct SessionStore.QueuedPrompt: Equatable { let text: String; let token: UUID; let deadline: Date }`
  - `private(set) var SessionStore.promptQueue: [UUID: [QueuedPrompt]]`
  - `static let SessionStore.phonePromptWindow: TimeInterval`
  - `static let SessionStore.maxRememberedPromptTokens: Int`

> Task 4 lands the type, the refusals and the immediate-injection path. Task 5 lands the deferral, the tick and the cleanup. They are split because a reviewer can meaningfully reject one and accept the other, and because `SessionStore.swift` is being edited concurrently — two smaller merges beat one large one.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PhonePromptDispatchTests.swift`:

```swift
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// Which prompts reach an agent, and which are refused with a reason.
///
/// The store is the single decision point on purpose: it is the only thing that knows a tab's
/// agent, its status and whether it has a surface, and splitting those checks across
/// `FleetService` is how they drift.
@MainActor
final class PhonePromptDispatchTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// Answers `thread/name/set` so a codex tab can be created at all. Lifted from
    /// `AgentRoutingTests`, which is the only other place a test needs a real codex tab.
    private final class ScriptedCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// An idle claude tab whose injection settles synchronously, so the tests read as
    /// straight-line code. Same shape as `SessionRenameTests.makeStore`.
    private func makeStore(activity: SessionActivity = .idle)
        -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id)
    }

    func testAnIdlePromptIsTypedAndSubmitted() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret])
    }

    /// A prompt goes through `inject`, not through `sendToShell`: the kill-and-yank is what
    /// gives the user their half-typed draft back instead of destroying it.
    func testAOneRowDraftIsRestoredAfterThePromptIsSubmitted() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["half-written thought"])
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret, .yank])
    }

    /// **Both assertions, and the second is the one that matters.** A refusal that returned
    /// the right enum and still typed the text would pass an enum-only test — which is exactly
    /// the failure `SessionStore.rename`'s comment records for codex.
    func testACodexTabIsRefusedRatherThanPastedInto() async throws {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport())),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .unsupportedAgent)
        XCTAssertTrue(spy.events.isEmpty,
                      "codex has no safe route: the app-server refuses a turn on a thread the "
                      + "TUI holds the writer lock on, and `InputBar` reads claude's box only")
    }

    func testAnUnknownTabIsRefused() {
        let (store, spy, _) = makeStore()
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: UUID()), .unknownSession)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The one refusal where a wrong answer is arbitrary code execution rather than a stray
    /// message: at a bare shell the text is a command.
    func testATabAtABareShellIsRefusedRatherThanQueued() {
        let (store, spy, id) = makeStore(activity: .shell)
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .notRunning)
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(store.promptQueue[id], "a shell does not become claude by waiting")
    }

    func testATabWithNoAgentAtAllIsRefused() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        // No `applyRegistry`, so the tab has no status at all — which is NOT `.idle`.
        spy.events.removeAll()

        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: session.id), .notRunning)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnEscapeSequenceIsRefusedAndNothingIsTyped() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(
            store.submitPrompt("go\u{1b}[201~ahead", token: UUID(), to: id),
            .rejected(.controlCharacters)
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The retry answer.** The two sends carry DIFFERENT text on purpose: a store that
    /// ignored the token would type "actually don't" as well, which a same-text fixture
    /// could not distinguish from a correct single send.
    func testTheSameTokenTwiceTypesOnce() {
        let (store, spy, id) = makeStore()
        let token = UUID()
        XCTAssertEqual(store.submitPrompt("ship it", token: token, to: id), .sent)
        XCTAssertEqual(store.submitPrompt("actually don't", token: token, to: id), .duplicate)
        XCTAssertEqual(spy.sent, ["ship it"])
    }

    /// The negative control, so the dedupe cannot pass by refusing everything after the first.
    func testADifferentTokenTypesAgain() {
        let (store, spy, id) = makeStore()
        XCTAssertEqual(store.submitPrompt("one", token: UUID(), to: id), .sent)
        XCTAssertEqual(store.submitPrompt("two", token: UUID(), to: id), .sent)
        XCTAssertEqual(spy.sent, ["one", "two"])
    }

    /// The mapping `FleetService` reads. Asserted here rather than only end-to-end, because
    /// several of these need a Mac in a state the loopback test cannot arrange.
    func testEveryRefusalCarriesAWireCodeAndEveryAcceptanceCarriesNone() {
        XCTAssertNil(SessionStore.PromptDispatch.sent.errorCode)
        XCTAssertNil(SessionStore.PromptDispatch.queued.errorCode)
        XCTAssertNil(SessionStore.PromptDispatch.duplicate.errorCode)
        XCTAssertEqual(SessionStore.PromptDispatch.unknownSession.errorCode, "unknown_session")
        XCTAssertEqual(SessionStore.PromptDispatch.unsupportedAgent.errorCode, "unsupported_agent")
        XCTAssertEqual(SessionStore.PromptDispatch.notRunning.errorCode, "not_running")
        XCTAssertEqual(
            SessionStore.PromptDispatch.rejected(.tooLong).errorCode, "prompt_too_long"
        )
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PhonePromptDispatch|error:"`
Expected: compile failure — no `submitPrompt`, no `promptQueue`.

- [ ] **Step 3: Implement**

Add to `Sources/FlightDeck/SessionStore.swift`, immediately after `injectPendingRename` (~line 2718):

```swift
    // MARK: - A prompt from a paired phone

    /// What a client's prompt did.
    ///
    /// Three cases ack and four refuse. The refusals are distinguished on the wire because
    /// each sends the reader somewhere different: `unsupportedAgent` means never on this tab,
    /// `notRunning` means not until something starts, and a `rejected` means edit the text.
    /// One code for all four would leave someone retyping a message the Mac will never take.
    enum PromptDispatch: Equatable {
        /// Accepted, and the injection has started. `ack`.
        case sent
        /// Accepted and queued — the bar was busy, or claude has not finished booting. `ack`.
        case queued
        /// This token has already been accepted for this tab; nothing was queued a second
        /// time. `ack`, because from the client's side a retry that lands is a send that
        /// landed. See `acceptedPromptTokens`.
        case duplicate
        case rejected(PromptText.Rejection)
        /// No such tab.
        case unknownSession
        /// This tab's agent has no route for a prompt. See `submitPrompt`.
        case unsupportedAgent
        /// Nothing to type into: no surface, no status, or a bare shell.
        case notRunning

        /// The wire spelling — `err`'s `code` — or `nil` for the three that ack. Computed
        /// here rather than in `FleetService` so the mapping lives beside the decision.
        var errorCode: String? {
            switch self {
            case .sent, .queued, .duplicate: return nil
            case .rejected(let reason): return reason.rawValue
            case .unknownSession: return "unknown_session"
            case .unsupportedAgent: return "unsupported_agent"
            case .notRunning: return "not_running"
            }
        }
    }

    /// One phone-sent prompt waiting for a moment when it can be typed.
    ///
    /// **Deliberately NOT `DeferredPrompt`/`pendingPrompts`**, which is one-per-tab with
    /// REPLACE semantics and is cancelled the instant a session goes busy or waiting. Both
    /// are right for what that queue holds — a restore's "Keep going" and a sign-in's
    /// `/login`, where a second request supersedes the first and an agent that started
    /// working on its own has already done the thing — and both are wrong here. Two messages
    /// typed on a phone are two messages, in order. And a prompt arriving mid-turn is the
    /// ORDINARY case rather than the edge one: mid-turn is when a person reaches for their
    /// phone. Reusing that queue would have silently dropped the first of two prompts and
    /// then cancelled the survivor at the next status change.
    struct QueuedPrompt: Equatable {
        let text: String
        /// The client's idempotency key, kept so a flush can identify the entry it retires
        /// without comparing text — two identical messages are two messages.
        let token: UUID
        /// When it stops being worth typing. See `phonePromptWindow`.
        let deadline: Date
    }

    /// FIFO per tab. Internal rather than private so tests can watch a deferral stay
    /// deferred, in the same style as `pendingPrompts`; nothing outside this type writes it.
    private(set) var promptQueue: [UUID: [QueuedPrompt]] = [:]

    /// How long a phone-sent prompt stays worth typing.
    ///
    /// Fifteen minutes against `resumePromptWindow`'s two, and the gap is the whole point.
    /// That one is a restore's "Keep going", which stops making sense within a couple of
    /// minutes of the restore. This one waits out a claude turn, and a turn running a test
    /// suite is routinely longer than two minutes. Bounded at all for the reason that window
    /// is bounded, and the reason is stronger here: this text is the user's own words rather
    /// than two fixed ones, so a prompt surfacing hours later in a conversation that has
    /// moved on is a stranger thing to read.
    static let phonePromptWindow: TimeInterval = 900

    /// Tokens this store has already accepted, oldest first, per tab.
    ///
    /// **This is the whole answer to "what if the phone retries".** The socket can drop
    /// between a prompt being queued and its `ack` being read, and nothing below the phone's
    /// screen model runs a liveness timer — a half-open socket reports nothing until the TCP
    /// retransmit horizon, which is minutes. So the phone genuinely cannot tell "the Mac
    /// never got it" from "the Mac got it and I never heard". Without a key the only safe
    /// client behaviour is never to retry, which makes a lost prompt lost silently; with one,
    /// a retry is free — the same token acks and queues nothing.
    ///
    /// Bounded, and per-tab, because the window in which a retry happens is one screen's
    /// session rather than a day, and an unbounded list keyed on a tab left open for a week
    /// is a leak with a client on the other end of it. Cleared with the tab in
    /// `closeSession`.
    private var acceptedPromptTokens: [UUID: [UUID]] = [:]
    static let maxRememberedPromptTokens = 16

    /// A client asked for text to be typed into a live agent and submitted.
    ///
    /// **claude only, and the refusal for codex is a finding rather than a gap.** Claude's
    /// route is the one `rename` already takes: type into the pty through `inject`, the
    /// single funnel where an idle status, a readable one-row `InputBar` and the
    /// kill-and-yank draft dance are all decided. Codex has neither half of it. Its tab is a
    /// `codex resume <id>` TUI holding the thread's writer lock, so the app-server route that
    /// carries its rename cannot start a turn — `CodexAdapter.prepare` documents the exact
    /// refusal, `thread <id> already has an active writer (code -32600)`. And the pty route
    /// has no input box to read: `InputBar.read` locks onto the last line starting `❯`, a
    /// glyph a plain shell prompt also draws, which is precisely how a queued `/rename` for a
    /// codex tab would have pasted itself into a live session — see `rename`, which is the
    /// reason that dispatch exists at all. Guessing at a second TUI's input box with the
    /// user's own words is a worse version of a bug this codebase has already paid for.
    ///
    /// **The order of the checks is load-bearing twice.** The agent test comes before the
    /// status test, so a codex tab is told `unsupportedAgent` — never on this tab — rather
    /// than `notRunning`, which would invite a retry that can never succeed. And the token
    /// test comes before the text is validated, so a retry of something already accepted is
    /// idempotent even if the two sends disagreed about the text; they cannot, since a token
    /// is minted per composed message, and if they ever did the first send is the one the
    /// user watched land.
    @discardableResult
    func submitPrompt(_ raw: String, token: UUID, to id: UUID) -> PromptDispatch {
        guard let at = locate(id) else { return .unknownSession }
        guard repos[at.repo].sessions[at.session].agent == .claude else {
            return .unsupportedAgent
        }
        if acceptedPromptTokens[id, default: []].contains(token) { return .duplicate }
        guard let text = PromptText(raw) else {
            // `rejection(for:)` and `init?` are the same predicate; this call is only to
            // recover the reason. `.empty` is unreachable and is a safe default rather
            // than a force-unwrap.
            return .rejected(PromptText.rejection(for: raw) ?? .empty)
        }
        // A tab with no status and no surface has nothing to type into, and a `.shell` one is
        // at a bare prompt where the text would be RUN rather than read. Refused rather than
        // queued, because neither state resolves itself: a closed tab never gets a surface
        // again, and a shell does not become claude by waiting.
        guard let activity = status(for: id)?.activity, activity != .shell,
              injector(for: id) != nil
        else { return .notRunning }

        remember(token, for: id)
        promptQueue[id, default: []].append(
            QueuedPrompt(
                text: text.value, token: token,
                deadline: now().addingTimeInterval(Self.phonePromptWindow)
            )
        )
        // Tried at once rather than left for the next registry tick, so an idle tab feels
        // immediate. `flushPromptQueue(_:)` is exactly what the tick runs; this is only
        // earlier, the same relationship `injectPendingRename` has with `flushPendingRenames`.
        flushPromptQueue(id)
        // Still queued means the injection was deferred. `inject` decides *now* whether the
        // bar is busy, and its `onSent` runs inside the settle — synchronous under a test's
        // substituted `injectionSettle`, one turn later in production — so by the time this
        // line runs the entry is either gone or genuinely waiting.
        return promptQueue[id]?.contains { $0.token == token } == true ? .queued : .sent
    }

    /// Files a token against a tab, oldest evicted first. See `acceptedPromptTokens`.
    private func remember(_ token: UUID, for id: UUID) {
        var tokens = acceptedPromptTokens[id, default: []]
        tokens.append(token)
        if tokens.count > Self.maxRememberedPromptTokens {
            tokens.removeFirst(tokens.count - Self.maxRememberedPromptTokens)
        }
        acceptedPromptTokens[id] = tokens
    }

    /// One tab's turn at the input box. Task 5 gives this its expiry sweep and its tick.
    private func flushPromptQueue(_ id: UUID) {
        guard let head = promptQueue[id]?.first else { return }
        inject(
            head.text,
            into: id,
            stillWanted: { [weak self] in self?.promptQueue[id]?.first?.token == head.token },
            onSent: { [weak self] in
                guard let self, self.promptQueue[id]?.first?.token == head.token else { return }
                self.promptQueue[id]?.removeFirst()
                if self.promptQueue[id]?.isEmpty == true {
                    self.promptQueue.removeValue(forKey: id)
                }
            }
        )
    }
```

- [ ] **Step 4: Run and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: cumulative baseline + 30, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Replace the `inject(...)` call in `flushPromptQueue` with `sendToShell(head.text, into: id)` | `testAOneRowDraftIsRestored…` (events lose the kill and yank) |
| Delete the `agent == .claude` guard | `testACodexTabIsRefusedRatherThanPastedInto` |
| Move the `agent == .claude` guard below the status guard | `testACodexTabIsRefusedRatherThanPastedInto` (becomes `.notRunning`) |
| Delete `activity != .shell` from the status guard | `testATabAtABareShellIsRefused…` |
| Change `status(for: id)?.activity` to `status(for: id)?.activity ?? .idle` | `testATabWithNoAgentAtAllIsRefused` |
| Delete the `acceptedPromptTokens` contains check | `testTheSameTokenTwiceTypesOnce` |
| Make `submitPrompt` return `.duplicate` whenever the queue is non-empty | `testADifferentTokenTypesAgain` |
| Delete the `PromptText` guard | `testAnEscapeSequenceIsRefused…` |

- [ ] **Step 6: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/PhonePromptDispatchTests.swift
git commit -m "feat: decide, in one place, which prompts reach an agent"
```

---

## Task 5: The queue — mid-turn arrival, order, expiry, cleanup

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — `flushPromptQueue(_:)` (added in Task 4), a new `flushPromptQueue()`, the `defer` in `applyRegistry(_:)` (~line 2980), `closeSession` (~line 2109), and the testing seams block (~line 2577)
- Test: `Tests/FlightDeckTests/PhonePromptQueueTests.swift`

**Interfaces:**
- Consumes: everything Task 4 produced
- Produces: `func SessionStore.flushPromptQueueForTesting()`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PhonePromptQueueTests.swift`:

```swift
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// A prompt that arrives while the agent is mid-turn — which is the ordinary case, not the
/// edge one, because mid-turn is when a person reaches for their phone.
@MainActor
final class PhonePromptQueueTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    private let clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeStore(activity: SessionActivity = .busy)
        -> (SessionStore, SpyInjector, UUID, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.now = { [clock] in clock }
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, session.pinnedConversationID)
    }

    private func goIdle(_ store: SessionStore, _ conversation: UUID) {
        store.applyRegistry([1: entry(conversation, .idle, cwd: tmp.path)])
    }

    func testAPromptSentMidTurnIsQueuedRatherThanTyped() {
        let (store, spy, id, _) = makeStore(activity: .busy)
        XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .queued)
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["ship it"])
    }

    func testAQueuedPromptIsTypedOnceTheTurnEnds() {
        let (store, spy, id, conversation) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)
        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["ship it"])
        XCTAssertNil(store.promptQueue[id])
    }

    /// **The supersession test, and the reason this queue is not `pendingPrompts`.**
    /// `cancelSupersededPrompts` drops a resume prompt the moment a session starts working,
    /// which is right for "Keep going" and catastrophic for a message a person typed: their
    /// words would vanish at exactly the transition they sent them across.
    func testAQueuedPromptSurvivesTheAgentGoingBusy() {
        let (store, _, id, _) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.cancelSupersededPromptsForTesting([
            StatusTransition(id: id, old: nil,
                             new: SessionStatus(activity: .busy, waitingFor: nil))
        ])
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["ship it"],
                       "a message a person typed is not superseded by the agent getting busy")
    }

    /// Two messages are two messages, in order. Distinct texts, and the ORDER asserted, so a
    /// LIFO or a dictionary-backed store fails rather than passing on a count.
    func testTwoPromptsAreTypedInOrderOneTickApart() {
        let (store, spy, id, conversation) = makeStore(activity: .busy)
        store.submitPrompt("first", token: UUID(), to: id)
        store.submitPrompt("second", token: UUID(), to: id)
        XCTAssertEqual(store.promptQueue[id]?.map(\.text), ["first", "second"])

        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["first"], "one per pass — the second would land on a bar "
                       + "that has just started a turn")
        store.flushPromptQueueForTesting()
        XCTAssertEqual(spy.sent, ["first", "second"])
        XCTAssertNil(store.promptQueue[id])
    }

    /// A window, for the reason `resumePromptWindow` has one, and a longer one because a
    /// claude turn running a test suite outlives two minutes routinely.
    func testAnExpiredPromptIsDroppedUnsent() {
        let (store, spy, id, conversation) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.now = { [clock] in clock.addingTimeInterval(SessionStore.phonePromptWindow + 1) }

        goIdle(store, conversation)
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(store.promptQueue[id])
    }

    func testTheWindowIsLongerThanAResumePrompts() {
        XCTAssertGreaterThan(SessionStore.phonePromptWindow, SessionStore.resumePromptWindow)
    }

    /// Closing the tab is the most literal case of "a prompt that will never be typed".
    func testClosingATabDropsItsQueue() {
        let (store, _, id, _) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)
        XCTAssertNotNil(store.promptQueue[id])

        store.closeSession(id)
        XCTAssertNil(store.promptQueue[id])
        XCTAssertEqual(store.submitPrompt("again", token: UUID(), to: id), .unknownSession)
    }

    /// A rename is a direct user action on the same input box and clears within a tick or
    /// two; a queued prompt can wait for it, and waiting costs nothing.
    func testAPendingRenameGoesFirst() {
        let (store, spy, id, conversation) = makeStore(activity: .busy)
        store.submitPrompt("ship it", token: UUID(), to: id)
        store.rename(id, to: "renamed")
        goIdle(store, conversation)
        XCTAssertEqual(spy.sent, ["/rename renamed"],
                       "the rename takes the bar this pass; the prompt takes the next one")
        store.flushPromptQueueForTesting()
        XCTAssertEqual(spy.sent, ["/rename renamed", "ship it"])
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PhonePromptQueue|error:"`
Expected: compile failure — no `flushPromptQueueForTesting`.

- [ ] **Step 3: Implement**

Replace `flushPromptQueue(_:)` (added in Task 4) with:

```swift
    /// Types the head of every tab's queue that is finally ready for it.
    ///
    /// Driven by the registry scan for the reason `flushPendingPrompts` is: what a queued
    /// prompt waits on — a turn ending, a draft being cleared, claude finishing its boot — is
    /// often not a status change at all, so gating the retry on one would strand it.
    private func flushPromptQueue() {
        for id in promptQueue.keys { flushPromptQueue(id) }
    }

    /// One tab's turn at the input box.
    ///
    /// **The head only, never the whole queue.** `inject` submits with a Return, so a second
    /// entry in the same pass would be typed into a bar that has just started a turn.
    /// `inject`'s idle gate would refuse it — but only after the settle, by which point the
    /// entry looks flushed to everything upstream. One per pass, and the next pass is a
    /// registry tick away.
    private func flushPromptQueue(_ id: UUID) {
        // Expiry first, and it runs whether or not this tab can be typed into: a queue that
        // is never drained because its tab lost its surface must still empty itself.
        let currentTime = now()
        promptQueue[id] = promptQueue[id]?.filter { currentTime < $0.deadline }
        if promptQueue[id]?.isEmpty == true { promptQueue.removeValue(forKey: id) }
        guard let head = promptQueue[id]?.first else { return }
        // Both other users of this input box go first, and neither costs anything to wait
        // for: a rename is a direct user action that clears within a tick or two, and the
        // resume queue holds text that stops making sense in two minutes. This queue has
        // fifteen.
        guard pendingRenames[id] == nil, pendingPrompts[id] == nil else { return }
        inject(
            head.text,
            into: id,
            // Re-checked after the settle: the tab can be closed, or the entry can expire,
            // while claude repaints. Matched on the TOKEN and not on the text, because two
            // identical messages are two messages and retiring the wrong one loses the other.
            stillWanted: { [weak self] in self?.promptQueue[id]?.first?.token == head.token },
            onSent: { [weak self] in
                guard let self, self.promptQueue[id]?.first?.token == head.token else { return }
                self.promptQueue[id]?.removeFirst()
                if self.promptQueue[id]?.isEmpty == true {
                    self.promptQueue.removeValue(forKey: id)
                }
            }
        )
    }
```

In `applyRegistry(_:)`, extend the existing `defer` block:

```swift
        defer {
            flushPendingRenames()
            // Same reason as the line above: this is the retry tick, and a prompt usually
            // waits on a `claude` that has not finished booting — which is not a status
            // change, so gating the retry on one would strand it.
            flushPendingPrompts()
            // And the phone's queue, for the same reason and one more: what a phone-sent
            // prompt waits on is usually a turn ENDING, and the tick is where that is seen.
            flushPromptQueue()
        }
```

In `closeSession(_:recordingHistory:)`, immediately after `subagentCounts.removeValue(forKey: id)`:

```swift
        // A queued prompt for a tab that no longer exists is the most literal case of "text
        // that will never be typed", and its tokens go with it: `acceptedPromptTokens` is
        // keyed by tab, so a reopened tab reusing this id starts with a clean dedupe window
        // rather than inheriting one from a session that is over.
        promptQueue.removeValue(forKey: id)
        acceptedPromptTokens.removeValue(forKey: id)
```

In the testing-seams block, beside `flushPendingResumePromptsForTesting`:

```swift
    /// Test seam, in the style of `flushPendingResumePromptsForTesting`. The registry tick is
    /// the production driver, and a test that wants a second pass without fabricating another
    /// registry scan says so here.
    func flushPromptQueueForTesting() { flushPromptQueue() }
```

- [ ] **Step 4: Run and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: cumulative baseline + 38, 0 failures. `SessionAutoResumeTests` and `AccountSignInTests` must be unchanged — they read `pendingPrompts`, which this task does not touch.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Add `promptQueue.removeValue(forKey: transition.id)` to `cancelSupersededPrompts`'s `.busy, .waiting` arm | `testAQueuedPromptSurvivesTheAgentGoingBusy` |
| Change `removeFirst()` to `removeLast()` in `onSent` | `testTwoPromptsAreTypedInOrderOneTickApart` |
| Loop `while let head = promptQueue[id]?.first` in `flushPromptQueue(_:)` | `testTwoPromptsAreTypedInOrderOneTickApart` (both land in one pass) |
| Delete the expiry `filter` | `testAnExpiredPromptIsDroppedUnsent` |
| Delete `flushPromptQueue()` from the `applyRegistry` defer | `testAQueuedPromptIsTypedOnceTheTurnEnds` |
| Delete `promptQueue.removeValue(forKey: id)` from `closeSession` | `testClosingATabDropsItsQueue` |
| Delete `pendingRenames[id] == nil` from the flush guard | `testAPendingRenameGoesFirst` |

- [ ] **Step 6: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/PhonePromptQueueTests.swift
git commit -m "feat: hold a phone's prompt until the agent's bar is free"
```

---

## Task 6: Wire `.prompt` to the store, over a real socket

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` — `apply(_:cid:)` (replace the Task 2 placeholder)
- Test: `Tests/FlightDeckTests/PhonePromptLoopbackTests.swift`

**Interfaces:**
- Consumes: `SessionStore.submitPrompt(_:token:to:)`, `PromptDispatch.errorCode` (Tasks 4-5); `FleetCommand.prompt` (Task 2); `FleetTestHarness` (existing)
- Produces: nothing new

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PhonePromptLoopbackTests.swift`:

```swift
import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The seam test for prompts: a real client, a real socket, a real `SessionStore` and a real
/// `inject` at the far end. This is what says a message typed on a phone reaches an agent.
@MainActor
final class PhonePromptLoopbackTests: XCTestCase {
    private var harness: FleetTestHarness?
    private var client: FleetClient?
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness?.service.stop()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private final class ScriptedCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private func entry(_ sid: UUID, cwd: String) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: .idle, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// A harness whose store can actually be typed into, and a client already attached.
    private func standUp() async throws -> (FleetTestHarness, SpyInjector, FleetClient, NWEndpoint.Port) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride =
            projectsRoot.appendingPathComponent("session_index.jsonl")
        harness.store.launchFailureReporter = SilentReporter()
        harness.store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport())),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        harness.store.injectorOverride = spy
        harness.store.injectionSettle = { $0() }
        let port = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)

        let attached = expectation(description: "attached")
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !harness.service.attachedSlots.isEmpty { attached.fulfill() }
            }
        }
        await fulfillment(of: [attached], timeout: 10)
        observer.invalidate()
        spy.events.removeAll()
        return (harness, spy, client, port)
    }

    /// Answers whichever reply frame lands on `cid`.
    private func answer(_ client: FleetClient, cid: Int) -> (XCTestExpectation, () -> ServerFrame?) {
        let landed = expectation(description: "reply for \(cid)")
        var frame: ServerFrame?
        client.onFrame = { received in
            switch received {
            case .ack(cid), .err(cid, _):
                frame = received
                landed.fulfill()
            default:
                break
            }
        }
        return (landed, { frame })
    }

    func testAPromptFromARealClientIsTypedIntoTheAgent() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let cid = client.send(.prompt(id: session.id, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(cid) = try XCTUnwrap(frame()) else {
            return XCTFail("an accepted prompt must ack on its own cid")
        }
        XCTAssertEqual(spy.sent, ["ship it"])
    }

    /// The other half, in the same store, so a Mac that refused EVERYTHING could not pass
    /// both tests. This one names the code, because `unsupported_agent` and `not_running`
    /// send the reader in opposite directions.
    func testACodexTabIsRefusedWithUnsupportedAgent() async throws {
        let (harness, spy, client, _) = try await standUp()
        guard case .success(let codexID) =
                await harness.store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()

        let cid = client.send(.prompt(id: codexID, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("a codex tab must be refused, not acked")
        }
        XCTAssertEqual(code, "unsupported_agent")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAControlCharacterIsRefusedWithItsOwnCode() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let cid = client.send(
            .prompt(id: session.id, token: UUID(), text: "go\u{1b}[201~ahead")
        )
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("hostile text must be refused on the wire, not typed")
        }
        XCTAssertEqual(code, PromptText.Rejection.controlCharacters.rawValue)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The socket survives it**, which is the whole reason `FleetCommand`'s decoder does not
    /// judge its own payload: `onUndecodable` salvages `t == "req"` only, so a throwing `cmd`
    /// decoder would hang up on the phone — and the phone, text still in its composer, would
    /// be one tap from doing it again.
    func testAPromptTheMacRefusesLeavesTheSocketUsable() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let refusedCID = client.send(
            .prompt(id: session.id, token: UUID(),
                    text: String(repeating: "x", count: PromptText.maxCharacters + 1))
        )
        let (refused, _) = answer(client, cid: refusedCID)
        await fulfillment(of: [refused], timeout: 10)

        let goodCID = client.send(.prompt(id: session.id, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: goodCID)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(goodCID) = try XCTUnwrap(frame()) else {
            return XCTFail("the connection must survive a refused prompt")
        }
        XCTAssertEqual(spy.sent, ["ship it"])
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PhonePromptLoopback"`
Expected: all four fail — the Task 2 placeholder answers `err`/`unhandled` for every prompt.

- [ ] **Step 3: Implement**

In `Sources/FlightDeck/Fleet/FleetService.swift`, replace `apply(_:cid:)` entirely:

```swift
    private func apply(_ command: FleetCommand, cid: Int) -> ServerFrame {
        switch command {
        case .markRead(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markRead(id)
        case .markUnread(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markUnread(id)
        case .prompt(let id, let token, let text):
            // Every refusal, "no such tab" included, is the store's to make: it is the only
            // thing that knows the tab's agent, its status and whether it has a surface, and
            // splitting the checks across two files is how they drift. `sessionExists` above
            // stays where it is for the two commands that have nothing else to check.
            //
            // No validation is repeated here and none should be added. §5's rule is that a
            // command with no existing store method gets one added to the store rather than a
            // special case in the replicator; this is that method.
            if let code = store.submitPrompt(text, token: token, to: id).errorCode {
                return .err(cid: cid, code: code)
            }
        }
        // `ack` means dispatched, not done. For the two read marks the observable effect is
        // the northbound `session.unread` event the store call just recorded; for a prompt it
        // is the `.userTurn` the agent writes into its own transcript, which the phone reads
        // back over the history channel. One rule for both, which is why they share a frame.
        return .ack(cid: cid)
    }
```

- [ ] **Step 4: Run and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: cumulative baseline + 42, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Discard `errorCode` and always `return .ack(cid: cid)` | `testACodexTabIsRefused…`, `testAControlCharacterIsRefused…` |
| Return `.err(cid: cid, code: "unknown_session")` for every refusal | `testACodexTabIsRefused…` (code mismatch), `testAControlCharacterIsRefused…` |
| Add `guard PromptText(text) != nil else { throw ... }` to `FleetCommand.init(from:)` | `testAPromptTheMacRefusesLeavesTheSocketUsable` (the socket dies and the second send never answers) |

- [ ] **Step 6: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/PhonePromptLoopbackTests.swift
git commit -m "feat: answer a phone's prompt over the fleet socket"
```

---

## Task 7: `PromptOutbox` — what the phone shows before the transcript agrees

**Files:**
- Create: `Sources/FleetKit/PromptOutbox.swift`
- Test: `Tests/FlightDeckTests/PromptOutboxTests.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `TimelineItem.Kind` (existing)
- Produces:
  - `public struct PromptOutboxEntry: Identifiable, Equatable, Sendable` with `public let id: UUID`, `public let text: String`, `public var state: State`
  - `public enum PromptOutboxEntry.State: Equatable, Sendable { case sending, accepted, failed(String) }`
  - `public struct PromptOutbox: Equatable, Sendable`, `public init()`
  - `public private(set) var entries: [PromptOutboxEntry]`
  - `public mutating func add(id: UUID, text: String, alreadyShowing items: [TimelineItem])`
  - `public mutating func accept(_ id: UUID)`
  - `public mutating func fail(_ id: UUID, _ message: String)`
  - `public mutating func dismiss(_ id: UUID)`
  - `public mutating func reconcile(with items: [TimelineItem])`
  - `public var isSending: Bool`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptOutboxTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// What the phone shows between tapping Send and the agent's own transcript agreeing.
final class PromptOutboxTests: XCTestCase {
    private func turn(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .userTurn, status: .complete, body: .init(text: text))
    }

    private func assistant(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete, body: .init(text: text))
    }

    /// **The fixture that distinguishes.** The conversation ALREADY holds a "yes", so an
    /// implementation matching on text alone retires the entry on the very first reconcile —
    /// before the Mac has read the frame. Only a turn that was not there when the entry was
    /// filed can retire it.
    func testAnEntryIsRetiredOnlyByATurnThatWasNotAlreadyThere() {
        let existing = [turn("10#0", "yes")]
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "yes", alreadyShowing: existing)
        outbox.accept(token)

        outbox.reconcile(with: existing)
        XCTAssertEqual(outbox.entries.map(\.id), [token],
                       "a turn that predates the send confirms nothing")

        outbox.reconcile(with: existing + [turn("90#0", "yes")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// One arriving turn retires at most one entry. Sending the same word twice is two
    /// messages and two turns are coming; clearing both on the first would erase a message
    /// the Mac has not typed yet.
    func testTwoIdenticalMessagesNeedTwoTurns() {
        var outbox = PromptOutbox()
        let first = UUID(), second = UUID()
        outbox.add(id: first, text: "yes", alreadyShowing: [])
        outbox.accept(first)
        outbox.add(id: second, text: "yes", alreadyShowing: [])
        outbox.accept(second)

        outbox.reconcile(with: [turn("10#0", "yes")])
        XCTAssertEqual(outbox.entries.map(\.id), [second], "in send order, oldest retired first")

        outbox.reconcile(with: [turn("10#0", "yes"), turn("50#0", "yes")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// A prompt whose ack was lost but whose text landed anyway must clear itself, not sit
    /// there accusing the Mac. This is the case the fifteen-second deadline creates and it
    /// is the reason reconcile does not look at `state`.
    func testAFailedEntryIsRetiredWhenItsTurnTurnsUpAfterAll() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "Your Mac didn't confirm this.")

        outbox.reconcile(with: [turn("10#0", "ship it")])
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// The agent quoting the message back is not the message landing.
    func testAssistantTextWithTheSameWordsConfirmsNothing() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.accept(token)

        outbox.reconcile(with: [assistant("10#0", "ship it")])
        XCTAssertEqual(outbox.entries.map(\.id), [token])
    }

    func testFailingAnEntryKeepsItVisibleWithItsReason() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "Not connected to your Mac, so this wasn't sent.")
        XCTAssertEqual(outbox.entries.first?.state,
                       .failed("Not connected to your Mac, so this wasn't sent."))
    }

    func testDismissingAFailedEntryRemovesIt() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        outbox.fail(token, "nope")
        outbox.dismiss(token)
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    /// Drives the composer's Send button. One entry in flight at a time is what stops a
    /// double-tap becoming two messages.
    func testIsSendingReportsOnlyTheUnansweredOnes() {
        var outbox = PromptOutbox()
        let token = UUID()
        outbox.add(id: token, text: "ship it", alreadyShowing: [])
        XCTAssertTrue(outbox.isSending)
        outbox.accept(token)
        XCTAssertFalse(outbox.isSending)
    }

    func testAcceptingAndFailingAnUnknownTokenDoNothing() {
        var outbox = PromptOutbox()
        outbox.accept(UUID())
        outbox.fail(UUID(), "nope")
        XCTAssertTrue(outbox.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PromptOutbox|error:"`
Expected: compile failure — `cannot find 'PromptOutbox' in scope`.

- [ ] **Step 3: Implement**

`Sources/FleetKit/PromptOutbox.swift`:

```swift
import Foundation

/// One message a client handed to the Mac, and how far it has got.
public struct PromptOutboxEntry: Identifiable, Equatable, Sendable {
    /// **Three states and no fourth.** "The Mac has it" is not distinguished from "the agent
    /// has it", because the Mac cannot tell you the difference — `ack` means dispatched, not
    /// done — and the transcript settles it either way within a turn.
    public enum State: Equatable, Sendable {
        /// Handed to the socket; no answer yet.
        case sending
        /// The Mac acked. It will be typed when the agent's input box is free, which may be
        /// a turn boundary away.
        case accepted
        /// It will not be typed, and this is why. Copy, not a code.
        case failed(String)
    }

    /// The idempotency token, which is also the identity: minted once per composed message
    /// and the thing `SessionStore.submitPrompt` dedupes on.
    public let id: UUID
    public let text: String
    public var state: State

    public init(id: UUID, text: String, state: State = .sending) {
        self.id = id
        self.text = text
        self.state = state
    }
}

/// The messages a session screen has sent and not yet seen come back.
///
/// **There is no optimistic echo into the timeline, and that is the design rather than a
/// simplification.** The timeline is answered from files on request (spec §6): every item in
/// it is a record the agent has already written. A row the phone drew for a prompt the agent
/// has not taken yet would be a claim the transcript does not support — carrying a
/// `"<offset>#<index>"` id no file produced, inside a `TimelineFeed` whose merge assumes
/// exactly the opposite. So an outbox entry is drawn *beside* the conversation, visibly not
/// part of it, and it disappears at the one moment it becomes true: when the agent's own
/// transcript comes back holding it.
///
/// **`TimelineItem.Kind.prompt` is NOT what this renders as**, and the temptation is worth
/// naming because the spec invites it. That case belongs to §9's prompt *bridging* — a
/// permission request the agent raised and is blocked on, travelling agent → user, which is
/// the opposite direction. Nothing emits it yet; squatting on it here would make it unusable
/// for the thing it was reserved for. A message a person typed is a `.userTurn`, which is
/// what both mappers already emit.
public struct PromptOutbox: Equatable, Sendable {
    public private(set) var entries: [PromptOutboxEntry] = []

    /// The ids of the `.userTurn` items already on screen when each entry was filed.
    ///
    /// This is what makes confirmation honest. Matching on text alone would let somebody
    /// else's older "yes", already sitting in the conversation, retire a "yes" the Mac has
    /// not even read — the send would look confirmed before the frame left the phone.
    private var witnessed: [UUID: Set<String>] = [:]

    public init() {}

    /// Whether anything is still waiting on the Mac. Drives the Send button, so a double tap
    /// cannot become two messages.
    public var isSending: Bool { entries.contains { $0.state == .sending } }

    /// Files a new entry and records what the conversation already held.
    public mutating func add(id: UUID, text: String, alreadyShowing items: [TimelineItem]) {
        witnessed[id] = Set(items.lazy.filter { $0.kind == .userTurn }.map(\.id))
        entries.append(PromptOutboxEntry(id: id, text: text))
    }

    /// The Mac acked. A token with no entry is a no-op — an entry can be dismissed while its
    /// answer is in flight.
    public mutating func accept(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .accepted
    }

    /// It will not be typed. The entry STAYS, carrying the reason: an outbox that cleared
    /// itself on failure would be a message that vanished, which is the failure this whole
    /// mechanism exists to prevent.
    public mutating func fail(_ id: UUID, _ message: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .failed(message)
    }

    /// The reader has read the failure and wants the row gone.
    public mutating func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
        witnessed.removeValue(forKey: id)
    }

    /// Retires every entry the transcript now holds.
    ///
    /// **Matched on kind, on text, AND on not-having-been-there.** Kind, because the agent
    /// quoting a message back is not the message landing. Text, because that is all the two
    /// sides share — the item's id is a byte offset the phone never predicted. And the
    /// witness set, because a conversation that already contains the same words would
    /// otherwise confirm a send the Mac has not read.
    ///
    /// **`state` is deliberately not consulted.** A prompt whose `ack` was lost — the exact
    /// case the screen model's deadline produces — may still have been typed, and when its
    /// turn appears the honest thing is to clear the row rather than leave it accusing the
    /// Mac of something that worked.
    ///
    /// One arriving turn retires at most one entry, in send order. Sending the same word
    /// twice is two messages and two turns are coming; clearing both on the first would erase
    /// a message the Mac has not typed yet.
    ///
    /// A `reset` page reissues every id, so an entry whose witness set no longer describes
    /// anything is retired by the next matching turn rather than stranded — which is why the
    /// test is "not in the recorded set" and not "after the recorded newest".
    public mutating func reconcile(with items: [TimelineItem]) {
        guard !entries.isEmpty else { return }
        var unclaimed = items.filter { $0.kind == .userTurn }
        var retired: Set<UUID> = []
        for entry in entries {
            let seen = witnessed[entry.id] ?? []
            guard let index = unclaimed.firstIndex(where: {
                $0.body.text == entry.text && !seen.contains($0.id)
            }) else { continue }
            unclaimed.remove(at: index)
            retired.insert(entry.id)
        }
        guard !retired.isEmpty else { return }
        entries.removeAll { retired.contains($0.id) }
        for id in retired { witnessed.removeValue(forKey: id) }
    }
}
```

- [ ] **Step 4: Run and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: cumulative baseline + 50, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Drop `&& !seen.contains($0.id)` from the match | `testAnEntryIsRetiredOnlyByATurnThatWasNotAlreadyThere` |
| Replace the loop with `entries.removeAll { entry in unclaimed.contains { $0.body.text == entry.text } }` | `testTwoIdenticalMessagesNeedTwoTurns` |
| Add `guard entry.state == .accepted else { continue }` to the loop | `testAFailedEntryIsRetiredWhenItsTurnTurnsUpAfterAll` |
| Drop `.filter { $0.kind == .userTurn }` from `unclaimed` | `testAssistantTextWithTheSameWordsConfirmsNothing` |
| Make `fail` call `entries.removeAll { $0.id == id }` | `testFailingAnEntryKeepsItVisibleWithItsReason` |
| Make `isSending` return `!entries.isEmpty` | `testIsSendingReportsOnlyTheUnansweredOnes` |

- [ ] **Step 6: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/PromptOutbox.swift Tests/FlightDeckTests/PromptOutboxTests.swift
git commit -m "feat: hold a sent message until the transcript agrees it landed"
```

---

## Task 8: The screen model sends, waits, and gives up on time

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift`
- Modify: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` (`StubPager` gains `PromptSending`)
- Test: `Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift`

**Interfaces:**
- Consumes: `PromptText` (Task 1), `FleetCommand.prompt` (Task 2), `FleetConnector.send(_:then:)` (Task 3), `PromptOutbox` (Task 7)
- Produces:
  - `@MainActor protocol PromptSending: AnyObject { func sendPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) }`
  - `SessionTimelineModel.init(sessionID: UUID, fleet: any TimelinePaging & PromptSending, timeout: Duration = .seconds(15))` — **changed signature**
  - `private(set) var SessionTimelineModel.outbox: PromptOutbox`
  - `func SessionTimelineModel.send(_ raw: String)`
  - `func SessionTimelineModel.dismiss(_ id: UUID)`
  - `static func SessionTimelineModel.promptMessage(for: FleetRequestError) -> String`
  - `static let SessionTimelineModel.noConfirmation: String`
  - `func FleetModel.sendPrompt(_:then:)`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A stand-in that answers both verbs on demand. The real `FleetModel` needs a pairing, a
/// Bonjour browse and a Mac to answer anything at all, so this is the only way a send that is
/// never answered — the case the deadline exists for — can be produced.
@MainActor
private final class StubFleet: TimelinePaging, PromptSending {
    private(set) var requests: [FleetRequest] = []
    private(set) var commands: [FleetCommand] = []
    private var pendingPages: [(Result<TimelinePage, FleetRequestError>) -> Void] = []
    private var pendingAcks: [(Result<Void, FleetRequestError>) -> Void] = []

    /// When set, every command is answered **before `sendPrompt` returns** — the
    /// `.disconnected` path `FleetConnector.send(_:then:)` takes deliberately.
    var answerCommandBeforeReturning: Result<Void, FleetRequestError>?

    var promptTexts: [String] {
        commands.compactMap { if case .prompt(_, _, let t) = $0 { return t } else { return nil } }
    }
    var promptTokens: [UUID] {
        commands.compactMap { if case .prompt(_, let t, _) = $0 { return t } else { return nil } }
    }

    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        requests.append(request)
        pendingPages.append(completion)
    }

    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        commands.append(command)
        if let answer = answerCommandBeforeReturning { return completion(answer) }
        pendingAcks.append(completion)
    }

    func answerPage(_ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line) {
        guard !pendingPages.isEmpty else {
            return XCTFail("no page was asked for", line: line)
        }
        pendingPages.removeFirst()(result)
    }

    func answerCommand(_ result: Result<Void, FleetRequestError>, line: UInt = #line) {
        guard !pendingAcks.isEmpty else {
            return XCTFail("no command was sent", line: line)
        }
        pendingAcks.removeFirst()(result)
    }
}

/// Sending a message from the phone: what is on screen while it is in flight, what happens
/// when it lands, and what happens when nothing ever comes back.
@MainActor
final class SessionTimelinePromptTests: XCTestCase {
    private let session = UUID()

    private func model(_ fleet: StubFleet, timeout: Duration = .seconds(15))
        -> SessionTimelineModel {
        SessionTimelineModel(sessionID: session, fleet: fleet, timeout: timeout)
    }

    /// Boundaries above and below the items' own offsets, in this file's house style: a page
    /// whose `start` equals its first item's offset cannot catch a cursor bug.
    private func page(_ items: [TimelineItem], start: Int = 1_000, end: Int = 9_000)
        -> TimelinePage {
        TimelinePage(session: session, items: items, start: start, end: end,
                     hasMore: false, reset: false)
    }

    private func turn(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .userTurn, status: .complete, body: .init(text: text))
    }

    func testASentPromptSitsInTheOutboxUntilTheMacAnswers() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")

        XCTAssertEqual(fleet.promptTexts, ["ship it"])
        XCTAssertEqual(model.outbox.entries.map(\.state), [.sending])
        XCTAssertTrue(model.outbox.isSending)
    }

    func testAnAckMovesTheEntryToAcceptedAndAsksForTheTranscript() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.success(()))

        XCTAssertEqual(model.outbox.entries.map(\.state), [.accepted])
        // Nothing else in this app polls a session screen — `loadNewer` has no other caller —
        // so without this fetch the transcript that would retire the entry is never re-read.
        XCTAssertEqual(fleet.requests.count, 1)
    }

    func testTheEntryIsRetiredWhenItsTurnComesBackInAPage() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.success(()))
        fleet.answerPage(.success(page([turn("2000#0", "ship it")])))

        XCTAssertTrue(model.outbox.entries.isEmpty)
    }

    /// **The deadline, and it is not belt-and-braces.** Nothing below this model runs a
    /// liveness timer: on a half-open socket — a phone that lost its network path without a
    /// FIN — a pending command sits for the TCP retransmit horizon, which is minutes. A fetch
    /// that vanishes leaves a spinner; a prompt that vanishes leaves a person believing they
    /// told an agent something.
    func testASendThatIsNeverAnsweredFailsAtItsDeadline() async {
        let fleet = StubFleet()
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        let failed = expectation(description: "the deadline fired")
        Task {
            while model.outbox.entries.first?.state == .sending { await Task.yield() }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(model.outbox.entries.map(\.state),
                       [.failed(SessionTimelineModel.noConfirmation)])
    }

    /// It does NOT retry, and the copy says so. A timeout cannot distinguish "the Mac never
    /// got it" from "the Mac got it and the ack was lost", and the second is where a silent
    /// retry types the message twice.
    func testATimedOutSendIsNotResent() async {
        let fleet = StubFleet()
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        let failed = expectation(description: "the deadline fired")
        Task {
            while model.outbox.entries.first?.state == .sending { await Task.yield() }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(fleet.promptTexts, ["ship it"], "exactly one send, ever")
    }

    /// Each refusal sends the reader somewhere different, which is why the wire distinguishes
    /// them at all. One generic message would leave someone retyping a message that will
    /// never be taken.
    func testARefusalCarriesTheMacsOwnReason() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.failure(.server(code: "unsupported_agent")))

        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Flight Deck can only type into a Claude session from here.")]
        )
    }

    func testEveryWireCodeThisChannelProducesHasItsOwnSentence() {
        let messages = [
            SessionTimelineModel.promptMessage(for: .disconnected),
            SessionTimelineModel.promptMessage(for: .server(code: "unknown_session")),
            SessionTimelineModel.promptMessage(for: .server(code: "unsupported_agent")),
            SessionTimelineModel.promptMessage(for: .server(code: "not_running")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_too_long")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_control_characters")),
            SessionTimelineModel.promptMessage(for: .server(code: "prompt_empty")),
        ]
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two codes sharing a sentence is two situations the reader cannot tell apart")
        XCTAssertTrue(
            SessionTimelineModel.promptMessage(for: .server(code: "invented_later"))
                .contains("invented_later"),
            "an unrecognised code must still name itself"
        )
    }

    /// Unsendable text never leaves the phone. The Mac would refuse it anyway; sending it
    /// spends a round trip to tell the user something the composer already knew.
    func testUnsendableTextIsNotSentAtAll() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("   \n  ")
        model.send("go\u{1b}[201~ahead")

        XCTAssertTrue(fleet.commands.isEmpty)
        XCTAssertTrue(model.outbox.entries.isEmpty)
    }

    /// The synchronous-completion path `FleetConnector.send(_:then:)` takes with no socket.
    /// The deadline is armed BEFORE the send for exactly this: armed afterwards it would
    /// outlive an entry that is already failed and fire over the top of it.
    func testADisconnectedSendIsAnsweredWithoutLeavingADeadlineArmed() async {
        let fleet = StubFleet()
        fleet.answerCommandBeforeReturning = .failure(.disconnected)
        let model = model(fleet, timeout: .milliseconds(10))
        model.send("ship it")

        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Not connected to your Mac, so this wasn't sent.")]
        )
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            model.outbox.entries.map(\.state),
            [.failed("Not connected to your Mac, so this wasn't sent.")],
            "a stale deadline must not overwrite the reason the reader is already looking at"
        )
    }

    func testEachSendCarriesItsOwnToken() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("one")
        fleet.answerCommand(.success(()))
        model.send("two")

        XCTAssertEqual(Set(fleet.promptTokens).count, 2,
                       "a shared token would have the Mac dedupe the second message away")
    }

    func testDismissingAFailedEntryClearsIt() {
        let fleet = StubFleet()
        let model = model(fleet)
        model.send("ship it")
        fleet.answerCommand(.failure(.server(code: "not_running")))
        let token = try? XCTUnwrap(model.outbox.entries.first?.id)
        model.dismiss(try! XCTUnwrap(token))

        XCTAssertTrue(model.outbox.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-ios.sh 2>&1 | grep -E "SessionTimelinePrompt|error:"`
Expected: compile failure — no `PromptSending`, no `send(_:)`.

- [ ] **Step 3: Implement the model**

In `Sources/FlightDeckMobile/SessionTimelineModel.swift`, after the `TimelinePaging` protocol:

```swift
/// The other half of `TimelinePaging`: asking the Mac to **do** something, and hearing that
/// it heard.
///
/// A second protocol rather than a second method on that one, for the reason that one is a
/// protocol at all: a screen model that took the concrete `FleetModel` could not be stood up
/// without a socket, a pairing and a real Mac, and the transitions worth asserting here — a
/// send that is never answered, a refusal delivered before the call returns — are exactly the
/// ones no real link produces on demand. Two protocols, so a stub can answer one verb and
/// leave the other outstanding.
@MainActor
protocol PromptSending: AnyObject {
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}
```

Change the stored property, the init, and add the new state:

```swift
    @ObservationIgnored private let fleet: any TimelinePaging & PromptSending
```

```swift
    init(
        sessionID: UUID,
        fleet: any TimelinePaging & PromptSending,
        timeout: Duration = .seconds(15)
    ) {
        self.sessionID = sessionID
        self.fleet = fleet
        self.timeout = timeout
    }
```

```swift
    /// Messages this screen has sent and not yet seen come back. Drawn beside the
    /// conversation, never inside it — see `PromptOutbox`, which is where the reasoning lives.
    private(set) var outbox = PromptOutbox()

    /// One deadline per send in flight, keyed by the send's own token.
    ///
    /// A table rather than the single `deadline` a fetch uses, because a person can tap Send
    /// twice before either answer lands and a shared slot would leave the first send with no
    /// deadline at all — the exact "waits forever" case this whole mechanism exists for.
    @ObservationIgnored private var promptDeadlines: [UUID: Task<Void, Never>] = [:]
```

The send:

```swift
    /// Hand a composed message to the Mac.
    ///
    /// **Validated here as well as on the Mac, and the two are not redundant.** The Mac's
    /// check is the guarantee — a client is not trusted to have checked anything — and this
    /// one is the difference between a composer that will not send and a round trip that
    /// comes back with an error for something the phone already knew.
    ///
    /// **The deadline is the same fifteen seconds a fetch gets, and it matters more here.**
    /// `FleetConnector` answers `.disconnected` synchronously when there is no socket and
    /// drains its tables when one dies — but a HALF-open socket, a phone that lost its
    /// network path without a FIN, reports nothing at all until the TCP retransmit horizon,
    /// which is minutes. A fetch that vanishes leaves a spinner. A prompt that vanishes
    /// leaves a person believing they told an agent something.
    ///
    /// **It does not retry, and the entry it leaves says so.** A timeout cannot distinguish
    /// "the Mac never got it" from "the Mac got it and the ack was lost", and the second is
    /// where a silent retry types the message twice into a live session. The token would make
    /// a retry safe — `SessionStore.submitPrompt` dedupes on it — but only by resending the
    /// SAME token, and a token whose first send may still be sitting in a queue on the Mac is
    /// a resend nobody can reason about. So the row stays visible and the human decides.
    func send(_ raw: String) {
        guard let text = PromptText(raw) else { return }
        let token = UUID()
        outbox.add(id: token, text: text.value, alreadyShowing: feed.items)

        // Armed BEFORE the send, because the send can complete before it returns:
        // `FleetConnector.send(_:then:)` answers `.disconnected` synchronously by design, the
        // same asymmetry `fetch` arms its own deadline ahead of. Armed afterwards, this task
        // would outlive an entry that is already failed and fire over the top of the reason
        // the reader is looking at.
        promptDeadlines[token] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self,
                  self.promptDeadlines.removeValue(forKey: token) != nil
            else { return }
            self.outbox.fail(token, Self.noConfirmation)
        }

        fleet.sendPrompt(.prompt(id: sessionID, token: token, text: text.value)) {
            [weak self] result in
            // The deadline is claimed here, exactly as `claim(_:)` claims a fetch's: whichever
            // of the answer and the deadline gets here first wins, and the loser finds nothing
            // filed and does nothing.
            guard let self, let deadline = self.promptDeadlines.removeValue(forKey: token)
            else { return }
            deadline.cancel()
            switch result {
            case .success:
                self.outbox.accept(token)
                // The one fetch this send causes. `loadNewer` has no other caller in this app
                // — see its own comment, which describes a poll that does not exist — so
                // without this the transcript that would retire the entry is never re-read
                // and the outbox row sits there until the reader leaves the screen.
                self.loadNewer()
            case .failure(let error):
                self.outbox.fail(token, Self.promptMessage(for: error))
            }
        }
    }

    /// The reader has read a failure and wants the row gone.
    func dismiss(_ id: UUID) { outbox.dismiss(id) }

    /// Deliberately not "try again": a retry after a timeout is the one action that can type
    /// the message twice. See `send(_:)`.
    static let noConfirmation =
        "Your Mac didn't confirm this. Check the conversation before sending it again."

    /// Copy for a prompt that did not land.
    ///
    /// **Deliberately NOT `message(for:)`.** The same wire code means a different thing on
    /// this channel: `unknown_session` on a fetch is "there is nothing to read", and on a
    /// prompt it is "the thing you were talking to is gone and your words did not reach it".
    /// Internal rather than private so the mapping can be asserted directly, the same way
    /// `message(for:)` is: several of these need a Mac in a state no test here can produce.
    static func promptMessage(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac, so this wasn't sent."
        case .server(let code):
            switch code {
            case "unknown_session":
                return "This session is no longer open on your Mac."
            case "unsupported_agent":
                return "Flight Deck can only type into a Claude session from here."
            case "not_running":
                return "There's no agent running in this tab right now."
            case PromptText.Rejection.tooLong.rawValue:
                return "That's longer than \(PromptText.maxCharacters) characters."
            case PromptText.Rejection.controlCharacters.rawValue:
                return "That text has characters Flight Deck won't type into a terminal."
            case PromptText.Rejection.empty.rawValue:
                return "There was nothing to send."
            default:
                return "Your Mac wouldn't send this (\(code))."
            }
        }
    }
```

In `fetch`'s success arm, immediately after `self.feed.merge(page)`:

```swift
                // The transcript is the only thing that confirms a sent message reached the
                // agent — see `PromptOutbox`. Done here rather than in `send` because the page
                // that holds it can arrive from any fetch: the `loadNewer` an ack triggers,
                // a reader scrolling, or a return to a screen kept in `FleetModel`.
                self.outbox.reconcile(with: self.feed.items)
```

- [ ] **Step 4: Implement the FleetModel forwarding**

In `Sources/FlightDeckMobile/FleetModel.swift`, change the declaration to
`final class FleetModel: TimelinePaging, PromptSending {` and add beside `timelinePage`:

```swift
    /// Ask the Mac to type something into a session's agent.
    ///
    /// Forwarded rather than absorbed, exactly as `timelinePage` is: the connector answers
    /// **exactly once**, including with `.disconnected` when nothing is connected or the
    /// socket dies mid-send, and a layer here that could swallow that would leave a person
    /// believing they told an agent something.
    ///
    /// The `guard` completes **synchronously**, the same asymmetry
    /// `FleetConnector.send(_:then:)` documents — a caller must expect its completion to run
    /// before this call returns, which is why `SessionTimelineModel.send` arms its deadline
    /// first.
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }
```

- [ ] **Step 5: Update the existing stub**

In `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift`, change
`private final class StubPager: TimelinePaging {` to
`private final class StubPager: TimelinePaging, PromptSending {` and add:

```swift
    /// This file's tests never send a prompt — `SessionTimelinePromptTests` owns that half —
    /// but `SessionTimelineModel` now requires both verbs from one object, so the stub has to
    /// answer this. Recorded rather than ignored, so a stray send from the paging path shows
    /// up here rather than disappearing.
    private(set) var commands: [FleetCommand] = []

    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        commands.append(command)
    }
```

- [ ] **Step 6: Run and verify they pass**

Run: `./scripts/test-ios.sh 2>&1 | tail -5`
Expected: iOS baseline + 11, 0 failures.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Delete the `promptDeadlines[token] = Task { … }` block | `testASendThatIsNeverAnsweredFailsAtItsDeadline` |
| Move the deadline arm to after `fleet.sendPrompt(…)` | `testADisconnectedSendIsAnsweredWithoutLeavingADeadlineArmed` |
| Delete `self.loadNewer()` from the success arm | `testAnAckMovesTheEntryToAcceptedAndAsksForTheTranscript`, `testTheEntryIsRetiredWhenItsTurnComesBackInAPage` |
| Delete `self.outbox.reconcile(with:)` from `fetch` | `testTheEntryIsRetiredWhenItsTurnComesBackInAPage` |
| Delete the `PromptText` guard in `send` | `testUnsendableTextIsNotSentAtAll` |
| Route the failure copy through `message(for:)` instead of `promptMessage(for:)` | `testARefusalCarriesTheMacsOwnReason`, `testEveryWireCodeThisChannelProducesHasItsOwnSentence` |
| Hoist `token` to a stored property assigned once | `testEachSendCarriesItsOwnToken` |
| Have the deadline task re-send instead of failing | `testATimedOutSendIsNotResent` |

- [ ] **Step 8: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeckMobile/SessionTimelineModel.swift \
        Sources/FlightDeckMobile/FleetModel.swift \
        Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift \
        Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift
git commit -m "feat: send a message from the phone and know whether it landed"
```

---

## Task 9: The composer

**Files:**
- Create: `Sources/FlightDeckMobile/PromptComposer.swift` (flat — `build-ios.sh` globs `Sources/FlightDeckMobile/*.swift` only)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `docs/MOBILE.md`
- Test: `Tests/FlightDeckMobileTests/PromptComposerTests.swift`

**Interfaces:**
- Consumes: `SessionTimelineModel.send(_:)`, `.dismiss(_:)`, `.outbox` (Task 8); `PromptText` (Task 1); `WireSession` (existing)
- Produces:
  - `struct PromptComposer: View`, `init(session: WireSession?, model: SessionTimelineModel)`
  - `static func PromptComposer.unavailable(for session: WireSession?) -> String?`
  - `static func PromptComposer.canSend(draft: String, unavailable: String?, isSending: Bool) -> Bool`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckMobileTests/PromptComposerTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The composer's two decisions, which are the only parts of it a simulator test can reach:
/// whether this tab can take a message at all, and whether this draft can be sent.
///
/// Nothing here asserts anything SwiftUI renders — layout, the keyboard, whether the field
/// grows — which stays in `docs/MOBILE.md`'s checklist, per this suite's own rule.
@MainActor
final class PromptComposerTests: XCTestCase {
    private func session(agent: String = "claude", activity: String? = "idle") -> WireSession {
        WireSession(id: UUID(), title: "t", agent: agent, activity: activity)
    }

    /// Refused on the phone as well as on the Mac, and the two are not redundant: the Mac's
    /// refusal is the guarantee, and this one is the difference between a disabled field with
    /// a sentence under it and a message someone typed, sent, and got an error for.
    func testACodexTabSaysWhyRatherThanOfferingAFieldThatWillFail() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(agent: "codex")),
            "Flight Deck can only type into a Claude session from here."
        )
    }

    /// An agent this build has never heard of is refused too. `WireSession.agent` is a
    /// `String` precisely so a new agent does not take the snapshot down — and an unknown
    /// agent has no known input box either.
    func testAnUnknownAgentIsAlsoRefused() {
        XCTAssertNotNil(PromptComposer.unavailable(for: session(agent: "gemini")))
    }

    /// Two fixtures, because `nil` and `"shell"` are different values and a check handling
    /// only one of them would pass a single-fixture test.
    func testAShellTabAndAStatuslessTabAreBothUnavailable() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(activity: "shell")),
            "There's no agent running in this tab right now."
        )
        XCTAssertEqual(
            PromptComposer.unavailable(for: session(activity: nil)),
            "There's no agent running in this tab right now."
        )
    }

    func testASessionTheFleetNoLongerListsSaysSo() {
        XCTAssertEqual(
            PromptComposer.unavailable(for: nil),
            "This session is no longer open on your Mac."
        )
    }

    /// The negative controls, and there are three because a composer that refused every
    /// non-idle state would silently stop working exactly when it is most wanted: mid-turn.
    func testAClaudeTabIsAvailableIdleBusyAndWaiting() {
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "idle")))
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "busy")))
        XCTAssertNil(PromptComposer.unavailable(for: session(activity: "waiting")))
    }

    func testSendIsRefusedForWhitespaceEvenOnAnAvailableTab() {
        XCTAssertFalse(PromptComposer.canSend(draft: "   \n ", unavailable: nil, isSending: false))
    }

    /// The same rule the Mac enforces, run here so the round trip is never spent teaching
    /// someone something the field already knew.
    func testSendIsRefusedForTextTheMacWouldRefuse() {
        XCTAssertFalse(
            PromptComposer.canSend(draft: "go\u{1b}[201~ahead", unavailable: nil, isSending: false)
        )
    }

    func testSendIsRefusedWhileAnEarlierMessageIsStillInFlight() {
        XCTAssertFalse(PromptComposer.canSend(draft: "ship it", unavailable: nil, isSending: true))
    }

    func testSendIsRefusedOnAnUnavailableTabEvenWithGoodText() {
        XCTAssertFalse(
            PromptComposer.canSend(draft: "ship it", unavailable: "nope", isSending: false)
        )
    }

    func testSendIsOfferedForOrdinaryTextOnAnAvailableIdleTab() {
        XCTAssertTrue(PromptComposer.canSend(draft: "ship it", unavailable: nil, isSending: false))
    }
}
```

- [ ] **Step 2: Run and verify they fail**

Run: `./scripts/test-ios.sh 2>&1 | grep -E "PromptComposer|error:"`
Expected: compile failure — `cannot find 'PromptComposer' in scope`.

- [ ] **Step 3: Implement the composer**

`Sources/FlightDeckMobile/PromptComposer.swift`:

```swift
import FleetKit
import SwiftUI

/// The field at the foot of a session screen, and the outbox above it.
///
/// **The outbox rows sit here rather than in the `List`**, and that is the same decision
/// `PromptOutbox`'s comment argues: the list is the conversation, every row of which is a
/// record the agent has written, and a message the agent has not taken yet does not belong in
/// it. Above the field, dimmed, with its own state, it reads as what it is — something on its
/// way — rather than as something that happened.
struct PromptComposer: View {
    /// Read live from the fleet by the screen above, so a session going to a shell, or
    /// closing on the Mac, disables this within a second rather than at the next push.
    let session: WireSession?
    let model: SessionTimelineModel

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    /// Why this tab cannot take a message right now, or `nil` when it can.
    ///
    /// **Refused here as well as on the Mac, and the two are not redundant.** The Mac's
    /// refusal is the guarantee — `SessionStore.submitPrompt` re-checks everything regardless
    /// of what a client claims — and this one is the difference between a disabled field with
    /// a sentence under it and a message someone composed, sent, and got an error for.
    ///
    /// `busy` and `waiting` are deliberately AVAILABLE. A prompt arriving mid-turn is the
    /// ordinary case — mid-turn is when a person reaches for their phone — and the Mac holds
    /// it in `promptQueue` until the input box is free. A composer that disabled itself
    /// during a turn would stop working exactly when it is most wanted.
    static func unavailable(for session: WireSession?) -> String? {
        guard let session else { return "This session is no longer open on your Mac." }
        // A string comparison, not an enum, for the reason `WireSession.agent` is a `String`:
        // a client-side enum would throw on an agent added after this build shipped. An
        // unrecognised agent falls here, which is right — an agent nobody has heard of has no
        // known input box either.
        guard session.agent == "claude" else {
            return "Flight Deck can only type into a Claude session from here."
        }
        // `nil` is "no agent process registered" and is NOT `idle`; `"shell"` is a bare
        // prompt where the text would be RUN rather than read. Neither resolves itself by
        // waiting, so neither is queued on the Mac and neither is offered here.
        guard let activity = session.activity, activity != "shell" else {
            return "There's no agent running in this tab right now."
        }
        return nil
    }

    /// Whether the Send button does anything.
    ///
    /// `isSending` is the double-tap guard: one message in flight at a time, so a second tap
    /// before the first ack cannot become two messages in the agent's queue.
    static func canSend(draft: String, unavailable: String?, isSending: Bool) -> Bool {
        unavailable == nil && !isSending && PromptText(draft) != nil
    }

    private var unavailableReason: String? { Self.unavailable(for: session) }

    private var sendable: Bool {
        Self.canSend(draft: draft, unavailable: unavailableReason, isSending: model.outbox.isSending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.outbox.entries) { entry in
                outboxRow(entry)
            }
            if let reason = unavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                field
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // `axis: .vertical` so a pasted paragraph grows the field instead of scrolling a
            // single line the writer cannot see the start of. `lineLimit` caps the growth so
            // a long message does not push the conversation off screen entirely.
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                // Off, both of them: this text is going into a terminal, and an autocorrected
                // file path or a capitalised flag is a message that means something else.
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
            Button {
                model.send(draft)
                draft = ""
                // Focus is kept deliberately: the next thing a person does after sending is
                // usually to send again, and dismissing the keyboard costs them a tap to say
                // one more thing.
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!sendable)
            // Stated rather than left to the glyph, which announces nothing useful.
            .accessibilityLabel("Send")
        }
    }

    @ViewBuilder
    private func outboxRow(_ entry: PromptOutboxEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
                .font(.footnote.monospaced())
                .lineLimit(3)
                .foregroundStyle(.secondary)
            switch entry.state {
            case .sending:
                Label("Sending…", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .accepted:
                // NOT "Sent to Claude". The Mac acked, which means dispatched and not done —
                // it may be queued behind a turn that is still running. This row disappears
                // when the agent's own transcript comes back holding the message, and that is
                // the only moment anything here can honestly claim it arrived.
                Label("Waiting for your Mac to type this", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Button {
                    model.dismiss(entry.id)
                } label: {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismisses this message")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 4: Mount it**

In `Sources/FlightDeckMobile/SessionTimelineScreen.swift`, after `.task(id: model.sessionID) { model.loadLatest() }`:

```swift
        // `safeAreaInset`, not a row in the `List` and not an overlay: the inset is what
        // reserves height so the last line of the conversation is not covered, and it is what
        // rides above the keyboard when the field takes focus. A row would scroll away from
        // the person typing into it.
        .safeAreaInset(edge: .bottom) {
            PromptComposer(session: session, model: model)
        }
```

- [ ] **Step 5: Run and verify they pass**

Run: `./scripts/test-ios.sh 2>&1 | tail -5`
Expected: iOS baseline + 22, 0 failures.

- [ ] **Step 6: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Delete the `session.agent == "claude"` guard | `testACodexTabSaysWhy…`, `testAnUnknownAgentIsAlsoRefused` |
| Change the guard to `session.agent != "codex"` | `testAnUnknownAgentIsAlsoRefused` |
| Change the activity guard to `activity != "shell"` only (drop the `let activity` unwrap) | `testAShellTabAndAStatuslessTabAreBothUnavailable` |
| Add `activity == "idle"` to the activity guard | `testAClaudeTabIsAvailableIdleBusyAndWaiting` |
| Drop `!isSending` from `canSend` | `testSendIsRefusedWhileAnEarlierMessageIsStillInFlight` |
| Replace `PromptText(draft) != nil` with `!draft.isEmpty` | `testSendIsRefusedForWhitespace…`, `testSendIsRefusedForTextTheMacWouldRefuse` |

- [ ] **Step 7: Add the manual checklist items**

Append to `docs/MOBILE.md`'s "The manual checklist" (numbering continues from the existing last item):

```markdown
15. **Type a message on the phone with the Mac's session idle.** It appears in the terminal's
    input box and submits, and the outbox row above the field disappears once the message
    comes back in the transcript. Nothing on the phone claims it landed before then.
16. **Type a message while the session is mid-turn.** The row says "Waiting for your Mac to
    type this" and stays there; when the turn ends the text is typed and the row goes. This
    is the ordinary case, not the edge one — it is when a person reaches for their phone.
17. **Type into the Mac's input box, leave the draft there, then send from the phone.** The
    draft is killed, the phone's message is submitted, and the draft is yanked back —
    unsubmitted. Nothing the user half-wrote is sent, and nothing is lost.
18. **Open a codex session on the phone.** There is no field, and the line under the
    conversation says Flight Deck can only type into a Claude session from here. Nothing is
    typed into the codex TUI — verify by watching it, not by trusting the phone.
19. **Send from the phone, then quit Flight Deck before the ack.** Within fifteen seconds the
    row turns orange and says the Mac didn't confirm it. It does not retry, and tapping it
    dismisses it.
```

- [ ] **Step 8: Verify everything**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`
Expected: four green runs. Report the unit and iOS counts against the baseline you measured before Task 1.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeckMobile/PromptComposer.swift \
        Sources/FlightDeckMobile/SessionTimelineScreen.swift \
        Tests/FlightDeckMobileTests/PromptComposerTests.swift docs/MOBILE.md
git commit -m "feat: a field to type into an agent from the phone"
```

---

## Self-Review

**Spec coverage.** §4's frame vocabulary: extended by Task 2 with a `cmd`, and the `ack`-means-dispatched rule is honoured rather than worked around (Tasks 2, 6). §5's "add a method to the store rather than special-case it in the replicator": Tasks 4-5 add `submitPrompt`, and `FleetService` is a three-line arm. §6's "the phone asks": no push, no new `FleetEvent`, no touch to `FleetReplicator`'s DEBUG drift check — the confirmation rides the existing history channel. §7's three screens: the composer is an inset on screen two, not a fourth screen. §11's "the phone is fully privileged once paired": addressed head-on in the Security section, with the widening named and one gap recorded. §9 is explicitly **not** implemented, and Task 7 documents why `.prompt` is left alone for it. §8, §10, §12: untouched, correctly.

**Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N", no "write tests for the above". Every code step carries the code. Every task's tests are written out in full, including the ones that repeat a helper (`entry`, `StubProvider`, `ScriptedCodexTransport`) across files — repeated deliberately, because a task's implementer sees only their own task.

**Type consistency.** `PromptText.Rejection.rawValue` is the wire code in Task 1, is returned through `PromptDispatch.errorCode` in Task 4, is emitted by `FleetService` in Task 6, and is matched by name in `SessionTimelineModel.promptMessage(for:)` in Task 8 — one string, four places, referenced through the enum rather than retyped in three of them. `FleetCommand.prompt(id:token:text:)`'s labels are identical in Tasks 2, 6, 8 and the tests. `SessionStore.PromptDispatch` cases are `sent`/`queued`/`duplicate`/`rejected`/`unknownSession`/`unsupportedAgent`/`notRunning` throughout. `PromptOutbox.add(id:text:alreadyShowing:)`, `.accept(_:)`, `.fail(_:_:)`, `.dismiss(_:)`, `.reconcile(with:)`, `.isSending` are used with exactly those signatures in Tasks 8 and 9. `SessionTimelineModel.init(sessionID:fleet:timeout:)`'s widened `fleet` type is changed in Task 8 and both stubs are updated in the same task, so no task leaves the suite uncompilable.

**One gap found and closed during review:** Task 2 leaves `FleetService.apply` non-exhaustive and therefore un-buildable. Step 4 of that task now adds the `err`/`unhandled` placeholder that Task 6 replaces, so every task is independently verifiable — and the placeholder refuses rather than acks, so no intermediate build can claim to have typed something it did not.

---
