# Answering an Agent's Questions From the Phone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Claude session on the Mac is blocked on a question — an `AskUserQuestion` tool call, or a tool permission dialog — the paired phone draws it as a box in the conversation with real controls, and tapping one answers it. If the question is answered on the Mac first, the box goes away on the phone; if the phone answers first, the Mac's terminal moves.

**Architecture:** Liveness rides the channel that already carries it — `activityChanged`'s `waiting` — and **no new northbound frame is added**. The question's *content* is pulled, like history: a new `FleetRequest.pendingPrompt(session:)` answered by a new `ServerFrame.prompt(cid:PendingPrompt?)`. The Mac builds a `PendingPrompt` from two sources, because the evidence forces two: an `AskUserQuestion` comes from the transcript (structured, exact, with descriptions), and a permission dialog comes from the terminal viewport (the only place it exists). Answering is one mechanism for both: `FleetCommand.answerPrompt` → `PromptService` re-validates the question against the screen → `SessionStore.choose`, a sibling of `inject` gated on `.waiting` rather than `.idle`, which moves the TUI's selection with arrow keys, **re-reads the screen to confirm the cursor landed on the intended label, and only then presses Return.**

**Tech Stack:** Swift 6 (`FleetKit`, `FlightDeckMobile`), Swift 5 (`Sources/FlightDeck`), Network.framework, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` §9, §4, §6. **Read the next section before Task 1.** Three of §9's load-bearing claims are contradicted by the code and by this machine, and one of them is a JSON contract that would not have worked.

---

## Findings that change the spec, established from the source and from this machine

Each was checked on 2026-08-23 against this branch and against real data in `~/.claude`, not inherited from the spec or from the preceding plan.

### 1. Nothing in §9 is built. Confirmed, and `.prompt` is still unused.

`rg 'PromptBroker|PendingPrompt|prompt\.opened|prompt\.closed' Sources/` returns **nothing** — the only hits anywhere are in the spec and in two plan documents. `SessionStore.flushPendingPrompts` is a false positive: it is the *resume* queue (`DeferredPrompt`, "Keep going" after a restore), unrelated. `rg 'Kind.prompt|\.prompt\b' Sources/` finds `.prompt` only in `Timeline.swift:24` and in `TimelineStyle.swift` — which already gives it a heading ("Waiting for you"), a symbol (`questionmark.circle.fill`) and a colour (orange), all unreached. **Nothing emits it. This plan is the first thing that does.**

### 2. §9's hook JSON is wrong, and it is the *`PreToolUse`* schema wearing `PermissionRequest`'s name.

§1.1 states the decision contract as:

```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
    "permissionDecision": "allow" | "deny", "permissionDecisionReason": "…" } }
```

Extracted from `~/.local/share/claude/versions/2.1.241`, the real `PermissionRequest` output schema is:

```
hookEventName: Ct("PermissionRequest"), decision: ks([
  ye({behavior: Ct("allow"),  updatedInput: …optional, updatedPermissions: …optional}),
  ye({behavior: Ct("deny"),   message: …optional,      interrupt: …optional})
])
```

— a nested `decision` object with a `behavior` discriminant. The flat `permissionDecision` / `permissionDecisionReason` pair the spec quotes is the schema of a *different* event, `PreToolUse`, which sits a few hundred bytes away in the same binary. **A hook helper built to §1.1 would have been rejected by claude's own validator.** This is the fourth spec contradiction this workstream has found by reading a binary and it is the reason this plan does not build a hook helper: the contract §9 rests on had never been exercised.

### 3. A pending `AskUserQuestion` is *already fully in the transcript*, and "still awaiting an answer" is decidable from the file.

`~/.claude/projects/-Users-nate/f90f38e2-70a5-4d6f-b3d0-502633bfcc50.jsonl` is 38 lines. Line 21 is an `AskUserQuestion` `tool_use`; line 22 is its `tool_result`, 77 seconds later, carrying `toolUseResult.answers`. Line 38 is another `AskUserQuestion` `tool_use` and is **the last line of the file** — and `~/.claude/sessions/71885.json` for that same session reads `"status":"waiting","waitingFor":"input needed"`.

So the record is written when the assistant message completes, *before* the tool runs, and the human's answer arrives later as a `tool_result` on the same `tool_use_id`. Three consequences:

- **The rule is exact:** an `AskUserQuestion` is open iff no `tool_result` for its `tool_use_id` follows it. Because claude cannot proceed past an unanswered question, an open one is always the final record — so this is a tail read, not a whole-file scan.
- **The payload is real and rich**, and this is the shape to design the control from (verbatim from line 21):
  `{"questions":[{"question":"…","header":"Random Q","multiSelect":false,"options":[{"label":"Playing jazz piano","description":"Sit down at any piano…"}, …]}]}`
- **Free-text and multi-select are both real.** Line 219 of `8261151b-…jsonl` answers a `multiSelect: true` question with four option labels *plus* a string appearing in no option — because, per the tool's own description in the binary, *"There should be no 'Other' option, that will be provided automatically."* The TUI appends an Other row. This plan does not drive it (Task 1 refuses multi-select and Other explicitly) but the shape has to be known before deciding what to refuse.

**The spec's §4 `prompt.opened` carries `"tool": "Bash", "input": {…}` — a permission-shaped payload only.** It has no field for a question, a header, or options, so it could not have carried the case that turns out to be the easy one.

### 4. Permission prompts have **no structured source at all**, which is why this is two mechanisms.

The `tool_use` record for a tool awaiting permission is in the transcript too — but it is byte-identical to the record for a tool that is merely *running*. There is no marker. And the thing the human is actually answering — "1. Yes / 2. Yes, and don't ask again for Bash commands in /Users/nate / 3. No, and tell Claude what to do differently" — is constructed in the TUI at display time from the permission rule set. It is in no file Flight Deck reads.

What the Mac does have is `waitingFor`. Extracted from 2.1.241, the dialog-kind→label map is
`{[k3t.kind]:"input needed", [Vxr.kind]:"sandbox request", [Ybt.kind]:"input needed", …}` with `dby(e) => qU0[e] ?? "permission prompt"` — so *"permission prompt" is the fallback for every unmapped dialog kind*, and "input needed" is what the two elicitation-shaped dialogs (one of which is `AskUserQuestion`, per the live correlation above) produce. **Do not branch behaviour on those strings.** They are a hint for copy, never a decision.

So: **detection and payload are two mechanisms** (transcript vs. screen). **Transport, rendering and answering are one** (Tasks 2, 3, 5, 6, 7, 11, 12 serve both).

### 5. There is no `Elicitation` hook route to `AskUserQuestion` either, so the pty is the only way in.

The binary does carry an `Elicitation` hook with `action: "accept"|"decline"|"cancel"` and a `content` object — which reads, at first, like exactly the lever this feature wants. It is not: its input schema is `{hook_event_name:"Elicitation", mcp_server_name, message, mode, url, elicitation_id, requested_schema}` and its own description says *"Fired when an MCP server requests user input."* `AskUserQuestion` is a built-in tool, not an MCP elicitation, and carries no `mcp_server_name`. **There is no hook that can supply an answer to it.** The terminal is the only route, for both cases, which is what makes one delivery mechanism the right call rather than a compromise.

### 6. The liveness channel is already shipped and already wired, and the preceding plan's finding #4 is stale.

That plan recorded "`loadNewer()` has no caller". It has two now, both added since, in `SessionTimelineScreen`:

```swift
.onChange(of: session?.activity) { _, _ in model.loadNewer() }
.task(id: session?.activity) { /* 1.5s poll while busy */ }
```

`session` is read live from the fleet snapshot, and `WireSession.activity`/`waitingFor` are pushed by `FleetEvent.activityChanged` on every genuine transition. **So "a question appeared" and "a question went away" are already arriving on the phone, for free, on the existing event stream.** This is the whole justification for not building `prompt.opened`/`prompt.closed`: the *fact* of a pending question is fleet state and is already replicated; only its *content* is missing, and content is what §6's pull channel is for. One rule, stated once: **state is pushed, content is pulled.** A new `FleetEvent` case would also have meant a new arm in the fold, in `FleetProjection.snapshot`, and in the DEBUG drift check — for a fact already on the wire.

### 7. `inject`'s idle gate makes it the wrong funnel, in its own words.

`SessionStore.inject` documents: *"While `waiting` a Return answers a permission prompt or dialog instead of submitting."* That sentence is a description of the bug it avoids and a description of the feature this plan wants. `inject` cannot be reused and must not be loosened — `submitPrompt`, `flushPendingRename` and `flushPendingPrompts` all depend on that gate. Task 7 adds `choose`, a sibling, gated the other way, sharing only the `injecting` set and the `injectionSettle` seam.

---

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No AppKit, no UIKit, no SwiftUI, no Observation. `FleetKitiOS` compiles the same sources for iOS and is what enforces it. (CryptoKit is already imported and is what Task 1's fingerprint uses.)
- **`FleetKit` and `FlightDeckMobile` build in Swift 6 language mode. `Sources/FlightDeck` is Swift 5.** `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate — vendored Ghostty is not Swift-6 clean. Do not "fix" it.
- **`FleetSocketServer` and `FleetConnector` confine their state to `queue`** (`.main` in production) and assert it with `dispatchPrecondition`. Every closure added here keeps that discipline. No `nonisolated(unsafe)`, no `@unchecked Sendable`.
- **Sessions key on the tab `id`, never `conversationId`.** Every frame added here carries a tab id.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`.
- **Mobile sources stay flat.** `build-ios.sh`'s type-check fallback globs `Sources/FlightDeckMobile/*.swift` only; a file in a subdirectory is invisible to it on a machine with no iOS platform installed.
- **`project.yml` needs no change.** `Sources/FleetKit`, `Sources/FlightDeck` and `Sources/FlightDeckMobile` are recursive path entries. Leave it alone; another agent has touched it during this work.
- **`Sources/FlightDeckMobile/TimelineRow.swift` is being edited by another agent right now.** Task 12 touches it with exactly one added switch arm and nothing else. Run `git status` and re-read it immediately before editing; merge into what is there. **Never `git stash`, never `git checkout .`, never revert blind** — the stack is shared.
- **`vendor/ghostty` holds build artifacts, not sources.** No claim about what libghostty does with a byte sequence can be verified in this checkout. That is why Task 6 sends arrows as *key events* rather than as escape text, and why Task 7 confirms the effect on screen rather than assuming it.
- **Every test must be shown to fail against the bug it exists for.** Each task carries a **"prove it can fail"** step naming the exact mutation, and the result goes in the task report. **If a mutation produces zero failures, suspect the mutation and the fixture before you suspect the tests.** During the preceding plan, five of nine tasks found their own brief's mutation list defective: one mutation sat behind an early-return guard and was a no-op; one mutated nothing because Swift parses a bare `return` written above a comment as `return <the next expression>`; one killed 7 of 12 tests because the line it deleted was also the mechanism the other tests claimed against; one test could not pass at all. When you write a fixture, check that it *distinguishes* the failure — two values that differ, not two that happen to agree.
- **Verification per task:** `./scripts/build.sh`, `./scripts/test-unit.sh`, `./scripts/build-ios.sh`, `./scripts/test-ios.sh`. Baselines as this was written are **1560 unit / 116 iOS** — **measure your own before Task 1** and report deltas against what you measured, because every handed-down figure in this work has been wrong at least once.
- **Never run `./scripts/smoke.sh`** — it seizes the foreground for ~70s. **Never run `build.sh` while `test-unit.sh` is live** — they share `DerivedData`.

---

## Security: what this widens, stated plainly

**This grants a paired phone the authority to approve an agent's actions, and that is a different kind of thing from everything before it.**

Trace the escalation honestly. Before pairing shipped, nothing. After pairing, a phone could read every transcript on the Mac — a large disclosure, and disclosure only. An hour ago, `FleetCommand.prompt` let a phone cause arbitrary text to be typed into a live Claude session: that is code execution by proxy, and its own plan said so. This adds the third thing: **a phone can now press "Yes" on a permission dialog.**

The difference is not blast radius, it is *who decided*. A typed message is a request the agent may refuse, and every dangerous thing it leads to still stops at a permission prompt. A permission decision **is** the stopping point. "Yes, and don't ask again for Bash commands in /Users/nate" is a durable grant written into the user's settings, made from a device in a pocket, possibly from a lock-screen glance at a truncated question. There is no layer below this one.

Four guards, and each exists because of a specific way this goes wrong:

1. **The Mac decides what the options are; the phone only picks an index.** The `answerPrompt` command carries a session, a prompt id, an index and a label — never text, never a keystroke, never an option list. `PromptService` looks up the `PendingPrompt` *it* served and takes the labels from there. A phone cannot name a button that the Mac did not draw.
2. **The prompt id is a content fingerprint, and a mismatch refuses.** For an `AskUserQuestion` it is the `tool_use_id`; for a screen-read dialog it is a SHA-256 over the question and every label. Answer a question the Mac has moved on from, and the id no longer matches: `prompt_changed`, nothing typed. This is the whole answer to racing the Mac, and it is stronger than a timestamp because it keys on *what was asked*.
3. **The screen is re-read after the cursor moves and before Return.** Task 7's `choose` will not press Return unless the selection marker is confirmed sitting on the label the phone chose. A failure there leaves a moved cursor and no answer — recoverable by the human in front of the terminal, which is the correct place for the failure to land.
4. **Nothing is ever answered while the session is not `waiting`.** `choose` gates on it, and a session that is `idle` or `busy` has no dialog up; a Return sent there submits an empty prompt or does nothing.

What this deliberately does **not** add: a Mac-side confirmation of each remote answer (a companion that has to be confirmed on the Mac is not a companion), a distinction between "allow once" and "allow always" beyond what the dialog itself offers, and any allow-list of which tools may be approved remotely. §11's named control is the right one and it is shipped: revocation, plus `DevicesSettingsTab` showing which device is attached while it does this.

**Two gaps, recorded rather than argued away.** A paired phone can approve a prompt in a tab the user is not looking at, and the only signal on the Mac is the terminal itself moving. And the phone renders the question the Mac read; for a screen-read permission dialog, a label truncated by terminal width is truncated on the phone too, so a long "don't ask again for X in Y" can be approved without its scope being fully legible. Both belong in `docs/FOLLOWUPS.md` (Task 13) if anyone disagrees with them.

---

## The wire shape, and why

**No new northbound frame.** §4 designs `prompt.opened` / `prompt.closed`. They are not built, and the reason is finding 6: the fact that a session is blocked already travels as `FleetEvent.activityChanged(id:activity:waitingFor:subagentCount:)`, and `SessionTimelineScreen` already refetches on it. A `prompt.opened` event would be a second, redundant announcement of a state change the phone is already told about — and it would cost a `FleetEvent` case, an arm in the replay fold, a field in `FleetProjection.snapshot`, and a new mutation site for the DEBUG drift check the spec's §5 calls *"the only thing standing between a new mutation site and a stale phone."*

**One rule, stated once: state is pushed, content is pulled.** The push channel says a session is `waiting`. The pull channel — the same `cid`-correlated request/response the history channel already runs on — says what it is waiting for. A question is exactly as much bulk content as a transcript page and is subject to the same §6 argument about not pushing unasked.

**The reply needs a second payload shape, and `ServerFrame` was left open for it.** `ServerFrame.page` hard-codes `try c.decode(TimelinePage.self, forKey: .page)`, so `PendingPrompt` gets its own case, `ServerFrame.prompt(cid: Int, PendingPrompt?)`. That is safe in the direction it travels: an older phone never sends `pendingPrompt`, so it never receives the reply, and an older *Mac* answers a request it cannot parse with `err`/`unsupported` through `FleetSocketServer.onUndecodable`, which salvages `t == "req"` for precisely this. The optional is load-bearing: "there is no question right now" is a real, common answer and must not be an error.

**A third pending table on the connector, which its own comment invited.** `FleetConnector.apply`'s `.err` arm says the two-table order *"is stated so a future third table is added deliberately rather than by accident."* This is that third table. `FleetClient.nextCID` mints one `cid` space for both verbs, so a number lands in at most one table and `apply` tries each in turn.

**Answering is a `cmd`, not a `req`.** `ack` means dispatched, not done — and here that is not a compromise, it is the truth: `choose` acts across an `injectionSettle`, so whether the Return landed is knowable only after the frame has gone. The observable effect arrives the way §4 says it does, on the push channel: the session stops being `waiting`, and the transcript grows a `tool_result`. Refusals that are knowable *before* the settle — wrong agent, not waiting, unknown prompt, changed prompt, unreadable screen, unanswerable shape — come back as `err` codes the phone renders into sentences. The one silent failure (the cursor did not land) is covered by the card's own 15-second deadline, with the same copy discipline `SessionTimelineModel.noConfirmation` established: never "try again".

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `Sources/FleetKit/PendingPrompt.swift` | Create | The value type, `AskUserQuestion` parsing, the fingerprint rule |
| `Sources/FleetKit/TimelineFrames.swift` | Modify | `FleetRequest.pendingPrompt`; new `err` codes documented |
| `Sources/FleetKit/Frames.swift` | Modify | `FleetCommand.answerPrompt`; `ServerFrame.prompt` |
| `Sources/FleetKit/FleetConnector.swift` | Modify | `pendingPrompts` table, `pendingPrompt(_:then:)`, routing, drain |
| `Sources/FlightDeck/Agents/ClaudePendingQuestion.swift` | Create | Finds the unresolved `AskUserQuestion` in a transcript tail |
| `Sources/FlightDeck/ChoiceDialog.swift` | Create | Reads a TUI option list off a viewport |
| `Sources/FlightDeck/TextInjecting.swift` | Modify | `sendArrowDown()` / `sendArrowUp()` |
| `Sources/FlightDeck/SessionStore.swift` | Modify | `viewport(of:)`, `AnswerDispatch`, `answerPrompt`, `choose` |
| `Sources/FlightDeck/Fleet/PromptService.swift` | Create | Composes and caches a `PendingPrompt`; answers one |
| `Sources/FlightDeck/Fleet/FleetService.swift` | Modify | Wires the request and the command |
| `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift` | Modify | `AskUserQuestion` → `TimelineItem.Kind.prompt` |
| `Sources/FlightDeckMobile/SessionTimelineModel.swift` | Modify | `PromptAnswering`, `pending`, fetch/answer/deadline/copy |
| `Sources/FlightDeckMobile/FleetModel.swift` | Modify | `PromptAnswering` conformance and forwarding |
| `Sources/FlightDeckMobile/PromptCard.swift` | Create | The box, the buttons, the states |
| `Sources/FlightDeckMobile/SessionTimelineScreen.swift` | Modify | Mount the card; fetch on activity change |
| `Sources/FlightDeckMobile/TimelineRow.swift` | Modify | One switch arm for a historical `.prompt` |
| `Tests/FlightDeckTests/PendingPromptTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptFrameCodingTests.swift` | Create | |
| `Tests/FlightDeckTests/FleetConnectorPromptTests.swift` | Create | |
| `Tests/FlightDeckTests/ClaudePendingQuestionTests.swift` | Create | |
| `Tests/FlightDeckTests/ChoiceDialogTests.swift` | Create | |
| `Tests/FlightDeckTests/AnswerPromptTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptServiceTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptLoopbackTests.swift` | Create | |
| `Tests/FlightDeckTests/SpyInjector.swift` | Modify | Model an option list |
| `Tests/FlightDeckTests/CodexResumeTests.swift` | Modify | Local `SpyInjector` conformance |
| `Tests/FlightDeckTests/CodexIntegrationTests.swift` | Modify | Local `SpyInjector` conformance |
| `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift` | Modify | `.prompt` mapping |
| `Tests/FlightDeckMobileTests/SessionTimelinePendingTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/PromptCardTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` | Modify | `StubPager` gains `PromptAnswering` |
| `Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift` | Modify | Same |
| `docs/MOBILE.md` | Modify | Manual checklist items, including the one capture this build cannot make |
| `docs/FOLLOWUPS.md` | Modify | The two recorded security gaps |

`PendingPrompt` lives in `FleetKit` for the reason `PromptOutbox` and `TimelineFeed` do: it is a pure value computation, and there the macOS unit suite covers it rather than only a simulator run.

---

## Task 1: `PendingPrompt` — the question, as a value

**Files:**
- Create: `Sources/FleetKit/PendingPrompt.swift`
- Test: `Tests/FlightDeckTests/PendingPromptTests.swift`

**Interfaces:**
- Consumes: `JSONValue.parse(_:maxDepth:)` (`Sources/FleetKit/JSONValue.swift:88`)
- Produces:
  - `public struct PendingPrompt: Codable, Equatable, Hashable, Sendable` with `id: String`, `kind: Kind`, `session: UUID`, `header: String?`, `question: String`, `options: [Option]`, `unanswerable: String?`
  - `public enum PendingPrompt.Kind: String, Codable, Hashable, Sendable { case question, permission, unknown }`
  - `public struct PendingPrompt.Option: Codable, Equatable, Hashable, Sendable { public var label: String; public var detail: String? }`
  - `public var PendingPrompt.isAnswerable: Bool`
  - `public static func PendingPrompt.question(session: UUID, callID: String, toolInput: String) -> PendingPrompt?`
  - `public static func PendingPrompt.permission(session: UUID, question: String, labels: [String]) -> PendingPrompt`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PendingPromptTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The question a phone is asked to answer, and the three properties that are not obvious
/// from its shape: that it is built from a real `AskUserQuestion` input verbatim, that its
/// id changes when the question changes, and that the shapes this build cannot drive say so
/// rather than offering buttons that would do the wrong thing.
final class PendingPromptTests: XCTestCase {
    private let session = UUID()

    /// Captured verbatim from `~/.claude/projects/-Users-nate/f90f38e2-….jsonl` line 21 on
    /// 2026-08-23, trimmed of nothing that matters. This is the shape the control is designed
    /// from; if it stops parsing, the phone stops showing questions.
    private let realInput = """
    {"questions":[{"question":"If you could instantly become world-class at one skill you've \
    never practiced, which would you pick?","header":"Random Q","multiSelect":false,\
    "options":[{"label":"Playing jazz piano","description":"Sit down at any piano and \
    improvise fluently with a band."},{"label":"Speaking 10 languages","description":"Drop \
    into any country and converse like a local."},{"label":"Freehand drawing",\
    "description":"Sketch anything you can picture."},{"label":"Woodworking",\
    "description":"Build furniture with hand-cut joinery."}]}]}
    """

    func testARealAskUserQuestionInputBecomesAnAnswerablePrompt() throws {
        let prompt = try XCTUnwrap(
            PendingPrompt.question(
                session: session, callID: "toolu_01TAgqjgnNES8BUtNAenrPnB", toolInput: realInput
            )
        )
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.header, "Random Q")
        XCTAssertTrue(prompt.question.hasPrefix("If you could instantly become"))
        XCTAssertEqual(
            prompt.options.map(\.label),
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"]
        )
        XCTAssertEqual(prompt.options[1].detail, "Drop into any country and converse like a local.")
        XCTAssertTrue(prompt.isAnswerable)
    }

    /// **The identity rule, and the whole answer to racing the Mac.** A question read from a
    /// transcript is identified by the agent's own `tool_use_id`, which is unique per call and
    /// stable for its life. Deriving it instead would make two identical questions asked twice
    /// in one conversation indistinguishable, and answering the older one would type into the
    /// newer.
    func testAQuestionIsIdentifiedByTheAgentsOwnCallID() throws {
        let prompt = try XCTUnwrap(
            PendingPrompt.question(session: session, callID: "toolu_ABC", toolInput: realInput)
        )
        XCTAssertEqual(prompt.id, "toolu_ABC")
    }

    /// A screen-read dialog has no id to borrow, so it gets one computed from what it SAYS.
    /// The two fixtures share a question and differ in one label — which is exactly the case a
    /// hash over the question alone would miss, and exactly the case that matters: "Yes, and
    /// don't ask again for Bash in /tmp" is not "Yes, and don't ask again for Bash in /".
    func testTwoDialogsDifferingOnlyInALabelGetDifferentIds() {
        let a = PendingPrompt.permission(
            session: session, question: "Do you want to proceed?",
            labels: ["Yes", "Yes, and don't ask again for Bash commands in /tmp", "No"]
        )
        let b = PendingPrompt.permission(
            session: session, question: "Do you want to proceed?",
            labels: ["Yes", "Yes, and don't ask again for Bash commands in /", "No"]
        )
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("screen:"), "the source of an id is part of the id")
    }

    func testTheSameDialogReadTwiceGetsTheSameId() {
        let labels = ["Yes", "No"]
        XCTAssertEqual(
            PendingPrompt.permission(session: session, question: "Run it?", labels: labels).id,
            PendingPrompt.permission(session: session, question: "Run it?", labels: labels).id
        )
    }

    /// **Carried, drawn, and not answerable.** A multi-select question is answered in the TUI
    /// with Space to toggle and then Enter — a second key protocol this build has never
    /// observed and must not guess at. Showing the question with an explanation is strictly
    /// better than hiding it: the reader learns there is something waiting and where to go.
    func testAMultiSelectQuestionIsCarriedButNotAnswerable() throws {
        let input = realInput.replacingOccurrences(
            of: "\"multiSelect\":false", with: "\"multiSelect\":true"
        )
        let prompt = try XCTUnwrap(
            PendingPrompt.question(session: session, callID: "toolu_A", toolInput: input)
        )
        XCTAssertEqual(prompt.options.count, 4, "the options are still shown")
        XCTAssertFalse(prompt.isAnswerable)
        XCTAssertEqual(prompt.unanswerable, PendingPrompt.multiSelectReason)
    }

    /// One call may carry several questions; the TUI shows them one after another. Answering
    /// the first from a phone would leave the second up with the reader believing they were
    /// done.
    func testACallCarryingTwoQuestionsIsNotAnswerable() throws {
        let two = """
        {"questions":[{"question":"First?","header":"A","multiSelect":false,\
        "options":[{"label":"x"}]},{"question":"Second?","header":"B","multiSelect":false,\
        "options":[{"label":"y"}]}]}
        """
        let prompt = try XCTUnwrap(
            PendingPrompt.question(session: session, callID: "toolu_A", toolInput: two)
        )
        XCTAssertEqual(prompt.question, "First?")
        XCTAssertFalse(prompt.isAnswerable)
        XCTAssertEqual(prompt.unanswerable, PendingPrompt.multiQuestionReason)
    }

    /// A truncated body is the ordinary state of a large tool input (`TimelineItem.Body.text`
    /// says so), and this parser is run over one on the phone. It must return nil, not a
    /// half-read question with three of its four options.
    func testATruncatedInputProducesNoPromptRatherThanAPartialOne() {
        let cut = String(realInput.prefix(120))
        XCTAssertNil(
            PendingPrompt.question(session: session, callID: "toolu_A", toolInput: cut)
        )
    }

    func testAQuestionWithNoOptionsIsNotAPromptAtAll() {
        let none = #"{"questions":[{"question":"Well?","options":[]}]}"#
        XCTAssertNil(
            PendingPrompt.question(session: session, callID: "toolu_A", toolInput: none)
        )
    }

    /// The decode-unknown rule, in the direction it applies: a `kind` this build has never
    /// heard of arrives from a newer Mac and must render as "answer this on your Mac" rather
    /// than ending the socket. Same rule, same reason, as `TimelineItem.Kind.unknown`.
    func testAnUnknownKindDecodesRatherThanThrowing() throws {
        let json = #"""
        {"id":"x","kind":"biometric","session":"\#(session.uuidString)","question":"?",\
        "options":[{"label":"a"}]}
        """#
        let decoded = try JSONDecoder().decode(PendingPrompt.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.kind, .unknown)
    }

    func testItRoundTrips() throws {
        let prompt = try XCTUnwrap(
            PendingPrompt.question(session: session, callID: "toolu_A", toolInput: realInput)
        )
        let data = try JSONEncoder().encode(prompt)
        XCTAssertEqual(try JSONDecoder().decode(PendingPrompt.self, from: data), prompt)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PendingPrompt|error:"`
Expected: compile failure — `cannot find 'PendingPrompt' in scope`.

- [ ] **Step 3: Create `Sources/FleetKit/PendingPrompt.swift`**

```swift
import CryptoKit
import Foundation

/// A question an agent is blocked on, as a phone sees it.
///
/// **Built from two sources, and the asymmetry is forced by the evidence rather than chosen.**
/// An `AskUserQuestion` is written into claude's transcript as an ordinary `tool_use` before
/// it runs, carrying its whole structured input — question, header, options, descriptions — so
/// that case is read from a file, exactly, with the agent's own `tool_use_id` for identity. A
/// tool *permission* dialog has no such record: the `tool_use` for a tool awaiting approval is
/// byte-identical to one for a tool that is merely running, and the choices the human is
/// offered are built in the TUI at display time from the permission rule set. That case is
/// read off the terminal screen, and its identity has to be computed from what it says.
///
/// One type for both because everything downstream of here is the same: one wire shape, one
/// card, one answer command, one keystroke driver.
public struct PendingPrompt: Codable, Equatable, Hashable, Sendable {
    /// Where this came from, which is also how much to trust it.
    ///
    /// `unknown` is not a case any builder emits — it is what a build decodes when a newer Mac
    /// sends a kind it has not heard of. Decoding rather than throwing is the same load-bearing
    /// rule `TimelineItem.Kind` states: `FleetSocket.receive` ends the connection on a frame it
    /// cannot parse, so a strict enum here would let one new Mac silently and permanently
    /// disconnect every phone built before it.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// An `AskUserQuestion` call, read from the transcript. Exact.
        case question
        /// A dialog read off the terminal screen. Best effort — see `ChoiceDialog`.
        case permission
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// One choice. `detail` is the option's description where the source had one — the
    /// transcript does, a screen read does not.
    public struct Option: Codable, Equatable, Hashable, Sendable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }

        enum CodingKeys: String, CodingKey { case label, detail }

        /// Hand-written so `detail` is ABSENT rather than null, for the reason
        /// `TimelineItem.Body`'s codec is hand-written: these travel over a cellular link.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(detail, forKey: .detail)
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    /// **What is being asked, not who is asking it, and this is the anti-race key.**
    ///
    /// For a `.question` it is the agent's own `tool_use_id`: unique per call, stable for its
    /// life, and already in the transcript. For a `.permission` it is `"screen:"` plus a
    /// digest of the question and every label, because a screen read has no id to borrow.
    ///
    /// The Mac re-derives this at answer time and refuses a mismatch (`prompt_changed`). That
    /// is what makes "the user answered in the terminal while the phone showed the same
    /// question" safe rather than a double answer: whatever the terminal is showing a moment
    /// later either has a different id or is not there, and the phone's answer is refused with
    /// nothing typed. A timestamp would not do this — it would let a *different* question that
    /// happened to arrive within the window be answered by a stale tap.
    public let id: String
    public var kind: Kind
    /// The tab. Never a conversation id.
    public var session: UUID
    /// A short label above the question where the source gave one — `AskUserQuestion`'s
    /// `header`. Nil for a screen read.
    public var header: String?
    public var question: String
    public var options: [Option]
    /// Why this cannot be answered from a phone, or `nil` when it can.
    ///
    /// A sentence rather than a code, and it travels rather than being computed on the phone,
    /// because the reasons are facts about what the MAC can drive: this build has never
    /// observed the key protocol for a multi-select list, and a call carrying two questions
    /// shows them in sequence so answering the first would leave the second up. A newer Mac
    /// that learns to drive one of them stops sending the sentence, with no phone change.
    public var unanswerable: String?

    public init(
        id: String, kind: Kind, session: UUID, header: String? = nil,
        question: String, options: [Option], unanswerable: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.session = session
        self.header = header
        self.question = question
        self.options = options
        self.unanswerable = unanswerable
    }

    public var isAnswerable: Bool { unanswerable == nil && !options.isEmpty }

    public static let multiSelectReason =
        "This question takes more than one answer. Answer it on your Mac."
    public static let multiQuestionReason =
        "This is several questions at once. Answer them on your Mac."

    enum CodingKeys: String, CodingKey {
        case id, kind, session, header, question, options, unanswerable
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(session, forKey: .session)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(question, forKey: .question)
        try c.encode(options, forKey: .options)
        try c.encodeIfPresent(unanswerable, forKey: .unanswerable)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        session = try c.decode(UUID.self, forKey: .session)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decode([Option].self, forKey: .options)
        unanswerable = try c.decodeIfPresent(String.self, forKey: .unanswerable)
    }
}

// MARK: - Building one from an AskUserQuestion

extension PendingPrompt {
    /// Reads an `AskUserQuestion` tool input.
    ///
    /// `toolInput` is the input object's JSON text — which on the Mac is the record's own
    /// `input` re-serialized, and on the phone is `TimelineItem.Body.text` for a `.prompt`
    /// row, since that field already holds the pretty-printed input. One parser for both.
    ///
    /// **Nil rather than a partial read.** `JSONValue.parse` is strict and refuses trailing
    /// content, which is what makes a body cut at `TimelineLimits.maxItemBytes` — the ordinary
    /// state of a large tool input — return nothing here instead of a question missing its
    /// last two options. A question with three of its four choices is worse than no question.
    ///
    /// The shape, captured from a real transcript on 2026-08-23:
    /// `{"questions":[{"question":…,"header":…,"multiSelect":false,
    ///   "options":[{"label":…,"description":…}]}]}`
    public static func question(
        session: UUID, callID: String, toolInput: String
    ) -> PendingPrompt? {
        guard let root = JSONValue.parse(toolInput),
              case .array(let questions)? = root.member("questions"),
              let first = questions.first,
              case .string(let text)? = first.member("question")
        else { return nil }

        guard case .array(let rawOptions)? = first.member("options") else { return nil }
        let options: [Option] = rawOptions.compactMap { option in
            guard case .string(let label)? = option.member("label"), !label.isEmpty
            else { return nil }
            if case .string(let detail)? = option.member("description"), !detail.isEmpty {
                return Option(label: label, detail: detail)
            }
            return Option(label: label)
        }
        // A question with nothing to pick is not a prompt this feature can show. It is also not
        // a shape the tool produces; refusing it keeps a malformed record off the screen.
        guard !options.isEmpty else { return nil }

        var header: String?
        if case .string(let raw)? = first.member("header"), !raw.isEmpty { header = raw }

        // Order matters only for which sentence is shown, and several questions is the more
        // surprising fact, so it wins.
        var unanswerable: String?
        if questions.count > 1 {
            unanswerable = multiQuestionReason
        } else if case .bool(true)? = first.member("multiSelect") {
            unanswerable = multiSelectReason
        }

        return PendingPrompt(
            id: callID, kind: .question, session: session, header: header,
            question: text, options: options, unanswerable: unanswerable
        )
    }

    /// Builds one from a dialog read off the screen, computing an id from what it says.
    ///
    /// The digest covers the question AND every label, separated by a byte no label can
    /// contain, so that two dialogs asking the same thing about different scopes are different
    /// prompts. Truncated to 32 hex characters: this is a change detector across seconds, not
    /// a security primitive, and 128 bits is far past what a collision would need.
    public static func permission(
        session: UUID, question: String, labels: [String]
    ) -> PendingPrompt {
        let material = ([question] + labels).joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return PendingPrompt(
            id: "screen:\(hex)", kind: .permission, session: session,
            question: question, options: labels.map { Option(label: $0) }
        )
    }
}

extension JSONValue {
    /// The first member with this key, or nil. Linear, which is right: a tool input has a
    /// handful of keys and `JSONValue` keeps them in document order deliberately (see its own
    /// comment), so there is no dictionary to consult and nothing to gain from building one.
    func member(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: your measured baseline + 10, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `permission(session:question:labels:)`, hash `question` alone instead of `([question] + labels)` | `testTwoDialogsDifferingOnlyInALabelGetDifferentIds` — the two fixtures share a question, so a question-only hash makes them equal |
| In `question(...)`, replace the `questions.count > 1` branch with nothing (delete the whole `if`, not just its body) | `testACallCarryingTwoQuestionsIsNotAnswerable`. **Deleting only the body leaves the `else if` attached to a dangling `if` and will not compile — delete both arms and re-add the `multiSelect` one on its own.** |
| In `question(...)`, drop the `multiSelect` branch | `testAMultiSelectQuestionIsCarriedButNotAnswerable` |
| Replace `guard !options.isEmpty else { return nil }` with `options.isEmpty ? [] : options` (i.e. remove the refusal) | `testAQuestionWithNoOptionsIsNotAPromptAtAll` |
| In `Kind.init(from:)`, `self = try Kind(rawValue: raw) ?? { throw … }()` — i.e. throw on unknown | `testAnUnknownKindDecodesRatherThanThrowing` |
| Use `JSONSerialization.jsonObject` instead of `JSONValue.parse` in `question(...)` | `testATruncatedInputProducesNoPromptRatherThanAPartialOne` **only if** `JSONSerialization` also refuses the truncated fixture — check this: if it does not fail, the fixture is the problem, so lengthen the prefix to cut *inside* a string literal (`prefix(120)` cuts mid-`"question"` value, which both parsers refuse; verify before relying on it) |

- [ ] **Step 6: Verify**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/PendingPrompt.swift Tests/FlightDeckTests/PendingPromptTests.swift
git commit -m "feat: a blocked agent's question, as a value both ends share"
```

---

## Task 2: The question on the wire, and the answer

**Files:**
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequest`, lines ~142-188; `FleetRequestError` doc, ~190)
- Modify: `Sources/FleetKit/Frames.swift` (`FleetCommand`, lines 19-97; `ServerFrame`, 163-230)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (placeholder arms only)
- Test: `Tests/FlightDeckTests/PromptFrameCodingTests.swift`

**Interfaces:**
- Consumes: `PendingPrompt` (Task 1)
- Produces:
  - `case FleetRequest.pendingPrompt(session: UUID)`, wire `op` `"prompt.pending"`
  - `case ServerFrame.prompt(cid: Int, PendingPrompt?)`, wire `t` `"prompt"`
  - `case FleetCommand.answerPrompt(id: UUID, token: UUID, prompt: String, index: Int, label: String)`, wire `op` `"prompt.answer"`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptFrameCodingTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The two new frames, and the properties that are not obvious from their shape: that "no
/// question right now" is a successful answer rather than an error, that an answer never
/// carries anything the Mac would execute, and that the existing vocabulary still decodes.
final class PromptFrameCodingTests: XCTestCase {
    private let session = UUID()
    private let token = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAPendingPromptRequestReadsAsOneFlatObject() throws {
        let json = try object(.req(cid: 3, .pendingPrompt(session: session)))
        XCTAssertEqual(json["t"] as? String, "req")
        XCTAssertEqual(json["cid"] as? Int, 3)
        XCTAssertEqual(json["op"] as? String, "prompt.pending")
        XCTAssertEqual(json["session"] as? String, session.uuidString)
        XCTAssertEqual(Set(json.keys), ["t", "cid", "op", "session"])
    }

    func testATimelineRequestStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"""
        {"t":"req","cid":7,"op":"timeline.page","session":"\#(session.uuidString)",\
        "anchor":"latest","limit":40}
        """#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .req(cid: 7, .timeline(session: session, anchor: .latest, limit: 40))
        )
    }

    /// **`nil` is a success, not an error.** "There is nothing to answer" is the ordinary
    /// answer and arrives constantly — every activity change on an idle session asks. Making
    /// it an `err` would have the phone render "your Mac couldn't read this" over a perfectly
    /// healthy conversation.
    func testAnAbsentPromptEncodesAsAPromptFrameWithNoPrompt() throws {
        let data = try JSONEncoder().encode(ServerFrame.prompt(cid: 9, nil))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["t"] as? String, "prompt")
        XCTAssertEqual(json["cid"] as? Int, 9)
        XCTAssertNil(json["prompt"], "absent, not null")
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), .prompt(cid: 9, nil))
    }

    func testAPresentPromptRoundTrips() throws {
        let prompt = PendingPrompt(
            id: "toolu_A", kind: .question, session: session, header: "Pick",
            question: "Which?", options: [.init(label: "a", detail: "the first")]
        )
        let frame = ServerFrame.prompt(cid: 4, prompt)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
    }

    /// `ServerFrame` reads its own tags first and falls through to an event's tag, which is why
    /// the two namespaces must never collide. This is the test that says adding `prompt` did
    /// not shadow an event.
    func testAnEventStillDecodesBesideTheNewTag() throws {
        let line = #"""
        {"seq":812,"t":"session.unread","id":"\#(session.uuidString)","isUnread":true}
        """#
        guard case .event(812, .unreadChanged(session, true)) =
            try JSONDecoder().decode(ServerFrame.self, from: Data(line.utf8))
        else { return XCTFail("a fleet event must still decode with `prompt` in the tag table") }
    }

    /// **An answer names a choice; it never carries one.** The Mac takes the labels from the
    /// `PendingPrompt` it served and uses `label` only as a cross-check, so nothing a client
    /// sends here reaches a keystroke. This test is what says the frame has no field that
    /// could.
    func testAnAnswerCarriesAnIndexAndALabelAndNothingElse() throws {
        let json = try object(
            .cmd(cid: 41, .answerPrompt(
                id: session, token: token, prompt: "toolu_A", index: 1, label: "Speaking 10 languages"
            ))
        )
        XCTAssertEqual(json["op"] as? String, "prompt.answer")
        XCTAssertEqual(json["index"] as? Int, 1)
        XCTAssertEqual(json["label"] as? String, "Speaking 10 languages")
        XCTAssertEqual(json["prompt"] as? String, "toolu_A")
        XCTAssertEqual(
            Set(json.keys), ["t", "cid", "op", "id", "token", "prompt", "index", "label"]
        )
    }

    func testAnAnswerRoundTripsThroughClientFrame() throws {
        let sent = ClientFrame.cmd(cid: 9, .answerPrompt(
            id: session, token: token, prompt: "screen:abc", index: 0, label: "Yes"
        ))
        let data = try JSONEncoder().encode(sent)
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
    }

    func testAPromptStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"""
        {"t":"cmd","cid":7,"op":"session.prompt","id":"\#(session.uuidString)",\
        "token":"\#(token.uuidString)","text":"hi"}
        """#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .prompt(id: session, token: token, text: "hi"))
        )
    }

    /// An answer missing its prompt id is not an answer — it is an index with nothing to index
    /// into, and accepting it would type into whatever happened to be up. Refused as the
    /// command it claimed to be, which is what reading `op` first buys.
    func testAnAnswerWithoutAPromptIDThrows() {
        let line = #"""
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\#(session.uuidString)",\
        "token":"\#(token.uuidString)","index":0,"label":"Yes"}
        """#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "PromptFrameCoding|error:"`
Expected: compile failure — `type 'FleetRequest' has no member 'pendingPrompt'`.

- [ ] **Step 3: Add `FleetRequest.pendingPrompt` in `Sources/FleetKit/TimelineFrames.swift`**

Replace the `FleetRequest` enum body (keeping its doc comment, extending it):

```swift
public enum FleetRequest: Codable, Equatable, Sendable {
    /// `limit` counts source **records**, not items — one record can carry several. Clamped
    /// to `TimelineLimits.maxLimit` by the reader rather than refused here.
    case timeline(session: UUID, anchor: TimelineAnchor, limit: Int)

    /// What this session is blocked on, or nothing.
    ///
    /// **A request and not an event, and that is the one protocol decision this feature
    /// makes.** Spec §4 designs `prompt.opened`/`prompt.closed` as northbound events. They are
    /// not built, because the fact they would announce is already on the wire: a blocked
    /// session emits `activityChanged` with `activity == "waiting"`, and the session screen
    /// already refetches on it. What is missing is the question's CONTENT, and content is
    /// exactly what §6 put on this channel rather than pushing unasked.
    ///
    /// One rule for both, stated once: **state is pushed, content is pulled.**
    case pendingPrompt(session: UUID)

    enum CodingKeys: String, CodingKey { case op, session, anchor, cursor, limit }

    private enum Op: String, Codable {
        case timeline = "timeline.page"
        case pendingPrompt = "prompt.pending"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timeline(let session, let anchor, let limit):
            try c.encode(Op.timeline, forKey: .op)
            try c.encode(session, forKey: .session)
            try c.encode(anchor.name, forKey: .anchor)
            // `encodeIfPresent`: `.latest` genuinely has no cursor, and an explicit null
            // would invite a reader to treat it as offset 0 — the opposite end of the file.
            try c.encodeIfPresent(anchor.cursor, forKey: .cursor)
            try c.encode(limit, forKey: .limit)
        case .pendingPrompt(let session):
            try c.encode(Op.pendingPrompt, forKey: .op)
            try c.encode(session, forKey: .session)
        }
    }

    /// An unrecognised `op` throws, like `FleetCommand`'s and unlike `TimelineItem.Kind`'s.
    /// See `TimelineAnchor.init(name:cursor:)` for the direction argument: a request that
    /// cannot be understood cannot be answered, and guessing at it answers the wrong question.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .timeline:
            let name = try c.decode(String.self, forKey: .anchor)
            let cursor = try c.decodeIfPresent(Int.self, forKey: .cursor)
            guard let anchor = TimelineAnchor(name: name, cursor: cursor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .anchor, in: c,
                    debugDescription: "unknown anchor \"\(name)\""
                        + (cursor == nil ? " (or a cursor was required and absent)" : "")
                )
            }
            self = .timeline(
                session: try c.decode(UUID.self, forKey: .session),
                anchor: anchor,
                limit: try c.decode(Int.self, forKey: .limit)
            )
        case .pendingPrompt:
            self = .pendingPrompt(session: try c.decode(UUID.self, forKey: .session))
        }
    }
}
```

In `FleetRequestError.server`'s doc comment, extend the code list — append after the existing sentence about `unhandled`/`unsupported`:

```swift
    /// The prompt channel adds five, all refusals a person can act on: `prompt_unknown` (this
    /// Mac is not holding the question you named — refetch), `prompt_changed` (it moved on;
    /// what is up now is not what you tapped), `not_waiting` (nothing is blocked on this tab),
    /// `unreadable_screen` (the terminal could not be read, or the dialog on it was not one
    /// this build recognises), and `unanswerable` (a shape this Mac cannot drive — see
    /// `PendingPrompt.unanswerable`). `unsupported_agent`, `unknown_session` and `duplicate`
    /// keep the meanings `FleetCommand.prompt` gave them.
```

- [ ] **Step 4: Add `ServerFrame.prompt` and `FleetCommand.answerPrompt` in `Sources/FleetKit/Frames.swift`**

In `FleetCommand`, add the case after `.prompt`:

```swift
    /// Answer the question `prompt` on tab `id` by choosing option `index`.
    ///
    /// **The client names a choice and never carries one.** `label` is the option's text as
    /// the phone drew it, and it is used for exactly one thing: a cross-check against the
    /// `PendingPrompt` the Mac itself served. Nothing here reaches a keystroke — the labels
    /// the driver matches on the screen come from the Mac's own copy. A phone cannot invent a
    /// button.
    ///
    /// `prompt` is the question's id (`PendingPrompt.id`), and it is the whole answer to
    /// racing the Mac: the user answering in the terminal changes what is up, which changes
    /// the id, which refuses this with `prompt_changed` and types nothing.
    ///
    /// `token` is the client's own idempotency key, minted once per tap, for the reason
    /// `.prompt`'s is: the socket can drop between the command landing and its `ack` being
    /// read, and a retry must be free.
    case answerPrompt(id: UUID, token: UUID, prompt: String, index: Int, label: String)
```

Extend `CodingKeys` and `Op`:

```swift
    enum CodingKeys: String, CodingKey { case op, id, token, text, prompt, index, label }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
        case prompt = "session.prompt"
        case answerPrompt = "prompt.answer"
    }
```

Add the encode arm:

```swift
        case .answerPrompt(let id, let token, let prompt, let index, let label):
            try c.encode(Op.answerPrompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(index, forKey: .index)
            try c.encode(label, forKey: .label)
```

and the decode arm:

```swift
        case .answerPrompt:
            self = .answerPrompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                prompt: try c.decode(String.self, forKey: .prompt),
                index: try c.decode(Int.self, forKey: .index),
                label: try c.decode(String.self, forKey: .label)
            )
```

In `ServerFrame`, add the case after `.page`:

```swift
    /// The reply to `FleetRequest.pendingPrompt`. Correlated by `cid` and, like `page`,
    /// deliberately **not** sequenced: a question is not fleet state — the fleet state that
    /// says a session is blocked is `activityChanged`, and it already has a `seq`.
    ///
    /// The optional is the point. `nil` means "nothing is waiting on this tab", which is the
    /// answer most of the time and is a success. An `err` there would put "your Mac couldn't
    /// read this" over a healthy conversation every time a session went idle.
    case prompt(cid: Int, PendingPrompt?)
```

Extend its `CodingKeys` with `case prompt` (reusing the name is safe — `.page` uses `page`), its `Tag` with `case prompt`, and add:

```swift
        case .prompt(let cid, let prompt):
            try c.encode(Tag.prompt, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // `encodeIfPresent`, so "nothing is waiting" is an absent key rather than an
            // explicit null — the same rule `TimelineItem.Body` follows, for the same reason.
            try c.encodeIfPresent(prompt, forKey: .prompt)
```

```swift
            case .prompt:
                self = .prompt(cid: try c.decode(Int.self, forKey: .cid),
                               try c.decodeIfPresent(PendingPrompt.self, forKey: .prompt))
```

- [ ] **Step 5: Add placeholder arms so the app target still compiles**

`FleetCommand` and `FleetRequest` are exhaustively switched in `Sources/FlightDeck/Fleet/FleetService.swift`. Add both now, refusing rather than acking, so an intermediate build cannot silently claim to have answered something:

In `apply(_:cid:)`:

```swift
        case .answerPrompt:
            // Wired for real in Task 9.
            return .err(cid: cid, code: "unhandled")
```

In `wireHandlers()`'s `server.onRequest` switch:

```swift
            case .pendingPrompt:
                // Wired for real in Task 9.
                reply(.err(cid: cid, code: "unhandled"))
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `./scripts/build.sh && ./scripts/test-unit.sh 2>&1 | tail -5`
Expected: baseline + 19 cumulative, 0 failures. `FleetFrameCodingTests` and the existing timeline frame tests must pass unchanged.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `ServerFrame.encode`'s `.prompt` arm, use `try c.encode(prompt, forKey: .prompt)` instead of `encodeIfPresent` | `testAnAbsentPromptEncodesAsAPromptFrameWithNoPrompt` — asserts `json["prompt"]` is nil, and `encode` of a nil optional writes `NSNull` |
| Remove `case prompt` from `ServerFrame.Tag` and decode `prompt` in the event fallthrough | `testAPresentPromptRoundTrips` and `testAnAbsentPromptEncodes…` |
| In `FleetCommand.encode`'s `.answerPrompt` arm, nest the three new keys under a `"choice"` object | `testAnAnswerCarriesAnIndexAndALabelAndNothingElse` (the `Set(json.keys)` assertion) |
| In `FleetCommand.init(from:)`'s `.answerPrompt` arm, use `decodeIfPresent(String.self, forKey: .prompt) ?? ""` | `testAnAnswerWithoutAPromptIDThrows` |
| Give `ServerFrame.Tag` the raw value `"session.unread"` for `prompt` | `testAnEventStillDecodesBesideTheNewTag` — this is the namespace collision the frame's own comment warns about, and this is the test that guards it |

- [ ] **Step 8: Verify**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 9: Commit**

```bash
git add Sources/FleetKit/Frames.swift Sources/FleetKit/TimelineFrames.swift \
        Sources/FlightDeck/Fleet/FleetService.swift \
        Tests/FlightDeckTests/PromptFrameCodingTests.swift
git commit -m "feat: a pending question is a request, and an answer is a command"
```

---

## Task 3: The phone can ask, and can hear the refusal

**Files:**
- Modify: `Sources/FleetKit/FleetConnector.swift` (add `pendingPrompts` beside `pendingAcks` ~line 100; `pendingPrompt(_:then:)` after `request(_:then:)` ~line 210; `resolvePrompt` after `resolveAck` ~line 240; extend `apply`'s `.err`/`.ack` arms ~line 372; extend `drainPending` ~line 531)
- Test: `Tests/FlightDeckTests/FleetConnectorPromptTests.swift`

**Interfaces:**
- Consumes: `FleetRequest.pendingPrompt`, `ServerFrame.prompt`, `PendingPrompt`
- Produces: `public func FleetConnector.pendingPrompt(_ session: UUID, then completion: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void)`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/FleetConnectorPromptTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit

/// The third pending table, and the invariant that matters more than the feature: **every
/// entry is resolved exactly once**, including when the socket dies with a fetch outstanding.
/// A prompt fetch that never answers leaves a card stuck mid-load beside a live conversation.
///
/// Driven against a real loopback listener, as `FleetConnectorAckTests` is, because the
/// interesting transitions are ones no fake produces: an `err` on a `cid` this table owns, and
/// a teardown with something filed.
@MainActor
final class FleetConnectorPromptTests: XCTestCase {
    // Harness identical in shape to FleetConnectorAckTests.makeConnectedPair(); reuse it
    // verbatim rather than reimplementing, and if that helper is private, lift it to internal
    // in the same commit rather than copying it.

    func testAPromptFrameResolvesTheFetchThatAskedForIt() async throws {
        let (connector, server, session) = try await makeConnectedPair()
        let prompt = PendingPrompt(
            id: "toolu_A", kind: .question, session: session,
            question: "Which?", options: [.init(label: "a")]
        )
        server.onRequest = { _, cid, request, reply in
            guard case .pendingPrompt = request else { return reply(.err(cid: cid, code: "x")) }
            reply(.prompt(cid: cid, prompt))
        }
        let answered = expectation(description: "answered")
        var received: PendingPrompt??
        connector.pendingPrompt(session) { result in
            received = try? result.get()
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertEqual(received ?? nil, prompt)
    }

    /// The common answer, and it must not look like a failure.
    func testNoPendingPromptIsASuccessCarryingNothing() async throws {
        let (connector, server, session) = try await makeConnectedPair()
        server.onRequest = { _, cid, _, reply in reply(.prompt(cid: cid, nil)) }
        let answered = expectation(description: "answered")
        var isSuccess = false
        var value: PendingPrompt?
        connector.pendingPrompt(session) { result in
            if case .success(let prompt) = result { isSuccess = true; value = prompt }
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertTrue(isSuccess)
        XCTAssertNil(value)
    }

    /// **The three tables share one `cid` space**, so an `err` has to find the right one. This
    /// is the test that says adding a third did not send a prompt's refusal to a page's caller.
    func testAnErrForAPromptFetchReachesThePromptCallerAndNotAPageCaller() async throws {
        let (connector, server, session) = try await makeConnectedPair()
        server.onRequest = { _, cid, request, reply in
            switch request {
            case .pendingPrompt: reply(.err(cid: cid, code: "not_waiting"))
            case .timeline: reply(.err(cid: cid, code: "unreadable"))
            }
        }
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        var promptCode: String?
        var pageCode: String?
        connector.pendingPrompt(session) { result in
            if case .failure(.server(let code)) = result { promptCode = code }
            both.fulfill()
        }
        connector.request(.timeline(session: session, anchor: .latest, limit: 10)) { result in
            if case .failure(.server(let code)) = result { pageCode = code }
            both.fulfill()
        }
        await fulfillment(of: [both], timeout: 5)
        XCTAssertEqual(promptCode, "not_waiting")
        XCTAssertEqual(pageCode, "unreadable")
    }

    /// The exactly-once rule, at the moment it is hardest to keep.
    func testAFetchOutstandingWhenTheSocketDiesIsFailedRatherThanDropped() async throws {
        let (connector, server, session) = try await makeConnectedPair()
        server.onRequest = { _, _, _, _ in }   // never replies
        let failed = expectation(description: "failed")
        var error: FleetRequestError?
        connector.pendingPrompt(session) { result in
            if case .failure(let reason) = result { error = reason }
            failed.fulfill()
        }
        connector.stop()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(error, .disconnected)
    }

    /// An `ack` correlated to a prompt FETCH is a server that answered the wrong verb —
    /// "dispatched, not done" is no answer to a question whose whole point is the data it
    /// carries back. Released as an error, so the caller is freed either way.
    func testAnAckForAPromptFetchFreesTheCallerRatherThanStranding It() async throws {
        let (connector, server, session) = try await makeConnectedPair()
        server.onRequest = { _, cid, _, reply in reply(.ack(cid: cid)) }
        let answered = expectation(description: "answered")
        var code: String?
        connector.pendingPrompt(session) { result in
            if case .failure(.server(let value)) = result { code = value }
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertEqual(code, "unexpected_ack")
    }
}
```

> **Note for the executor:** the last test's name has a space in it in this brief — rename it `testAnAckForAPromptFetchFreesTheCallerRatherThanStranding`. That is a typo in the plan, not a Swift feature.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "FleetConnectorPrompt|error:"`
Expected: compile failure — `value of type 'FleetConnector' has no member 'pendingPrompt'`.

- [ ] **Step 3: Add the third table in `Sources/FleetKit/FleetConnector.swift`**

Beside `pendingAcks`:

```swift
    /// Outstanding **prompt fetches**, by correlation id.
    ///
    /// The third table `apply`'s `.err` arm invited: *"it is stated so a future third table is
    /// added deliberately rather than by accident."* Safe for the same reason the second was —
    /// `FleetClient.nextCID` mints one space for both verbs, so a number is filed in at most
    /// one of these three and `apply` can try each in turn.
    ///
    /// Same exactly-once rule, and here the cost of breaking it is a card that spins forever
    /// beside a conversation the reader can otherwise use. `drainPending()` empties this too.
    private var pendingPrompts: [Int: (Result<PendingPrompt?, FleetRequestError>) -> Void] = [:]
```

After `request(_:then:)`:

```swift
    /// Ask what this session is blocked on. Answers **exactly once**, with a prompt, with
    /// `nil` for "nothing is waiting", or with a failure.
    ///
    /// Answers **synchronously with `.disconnected`** when nothing is connected, the same
    /// asymmetry `request(_:then:)` documents and for the same reason — a caller waiting
    /// forever is worse than a command quietly not happening. `SessionTimelineModel` arms its
    /// deadline before calling this for exactly that reason.
    public func pendingPrompt(
        _ session: UUID,
        then completion: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.pendingPrompt(session: session))
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingPrompts[cid] = completion
    }
```

After `resolveAck`:

```swift
    /// Resolves one outstanding prompt fetch, reporting whether there was one.
    ///
    /// Removed before it is invoked, exactly as `resolve` and `resolveAck` are, and for the
    /// same reason: a completion is free to re-enter — `stop()` from inside one is ordinary —
    /// and whatever it does next must find nothing left filed under this number.
    @discardableResult
    private func resolvePrompt(
        _ cid: Int, with result: Result<PendingPrompt?, FleetRequestError>
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingPrompts.removeValue(forKey: cid) else { return false }
        completion(result)
        return true
    }
```

In `apply`, add the new frame arm and extend the two existing ones:

```swift
        case .prompt(let cid, let prompt):
            // Resolved WITHOUT touching `lastSeq`, for the reason `.page` is: this frame
            // carries no sequence, and advancing from it would let a card refresh rewrite how
            // much fleet history the phone believes it has applied.
            resolvePrompt(cid, with: .success(prompt))
            return
```

```swift
        case .err(let cid, let code):
            // Commands, then prompt fetches, then page requests. The three tables share one
            // `cid` space, so a number is in at most one and the order cannot cross an answer.
            if resolveAck(cid, with: .failure(.server(code: code))) { return }
            if resolvePrompt(cid, with: .failure(.server(code: code))) { return }
            resolve(cid, with: .failure(.server(code: code)))
            return
        case .ack(let cid):
            if resolveAck(cid, with: .success(())) { return }
            // An `ack` correlated to either kind of REQUEST is a server that answered the
            // wrong verb. Released as a server error rather than dropped, so the caller is
            // freed either way.
            if resolvePrompt(cid, with: .failure(.server(code: "unexpected_ack"))) { return }
            resolve(cid, with: .failure(.server(code: "unexpected_ack")))
            return
```

In `drainPending()`, beside the existing two drains:

```swift
        let outstandingPrompts = pendingPrompts
        pendingPrompts.removeAll()
        for completion in outstandingPrompts.values { completion(.failure(.disconnected)) }
```

**Place it in the same order the existing drains use, and empty the dictionary before invoking anything** — a completion may call `stop()`, which re-enters `teardown()`, and a table not yet cleared would be drained twice.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: baseline + 24 cumulative, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `drainPending()`, delete the three added lines | `testAFetchOutstandingWhenTheSocketDiesIsFailedRatherThanDropped` (it will time out, which is the failure) |
| In `apply`'s `.err` arm, put `resolve(...)` before `resolvePrompt(...)` | Nothing — **and that is expected**, because the tables are disjoint. Do not use this as a mutation; use the next row instead |
| In `apply`'s `.err` arm, call `resolve(cid, …)` *only* (delete the `resolvePrompt` line) | `testAnErrForAPromptFetchReachesThePromptCaller…` — the prompt caller is never freed and the expectation times out |
| In `pendingPrompt(_:then:)`, file into `pending` instead of `pendingPrompts` | Compile error (`Result<TimelinePage,…>` vs `Result<PendingPrompt?,…>`) — that is a valid proof; record it as one |
| In `apply`'s `.prompt` arm, add `advance(to: cid)` before resolving | No test here fails; **check `FleetConnectorTests`' resume assertions instead** — if none fails either, the resume invariant is untested for this frame and you should add the assertion rather than shrug |

- [ ] **Step 6: Verify**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Tests/FlightDeckTests/FleetConnectorPromptTests.swift
git commit -m "feat: the phone can ask what an agent is waiting for"
```

---

## Task 4: `ClaudePendingQuestion` — the unanswered call in a transcript tail

**Files:**
- Create: `Sources/FlightDeck/Agents/ClaudePendingQuestion.swift`
- Test: `Tests/FlightDeckTests/ClaudePendingQuestionTests.swift`

**Interfaces:**
- Consumes: `SourceLine` (`Sources/FlightDeck/Timeline/TranscriptPager.swift:11`), `PendingPrompt.question(session:callID:toolInput:)` (Task 1)
- Produces: `enum ClaudePendingQuestion { static func find(in lines: [SourceLine], session: UUID) -> PendingPrompt? }`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/ClaudePendingQuestionTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Finding the question a claude session is actually blocked on.
///
/// **The rule this file exists to hold: a tool call is open iff no result for its id follows
/// it.** For every other tool that rule would be useless — a `Bash` record with no result yet
/// is a command that is merely *running* — but `AskUserQuestion` is the tool whose execution
/// IS the human answering, so for this one tool the rule is exactly "waiting for you". That
/// asymmetry is the whole reason a phone can show this case without a hook.
final class ClaudePendingQuestionTests: XCTestCase {
    private let session = UUID()

    private func line(_ offset: Int, _ json: String) -> SourceLine {
        SourceLine(offset: offset, text: json)
    }

    private func ask(_ id: String, question: String = "Which?") -> String {
        """
        {"type":"assistant","timestamp":"2026-08-21T04:30:59.425Z","message":{"role":\
        "assistant","content":[{"type":"tool_use","id":"\(id)","name":"AskUserQuestion",\
        "input":{"questions":[{"question":"\(question)","header":"H","multiSelect":false,\
        "options":[{"label":"a","description":"first"},{"label":"b"}]}]}}]}}
        """
    }

    private func answer(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"Your questions have been answered."}]}}
        """
    }

    func testAnAskWithNoResultAfterItIsTheOpenQuestion() throws {
        let found = try XCTUnwrap(
            ClaudePendingQuestion.find(in: [line(0, ask("toolu_A"))], session: session)
        )
        XCTAssertEqual(found.id, "toolu_A")
        XCTAssertEqual(found.question, "Which?")
        XCTAssertEqual(found.options.map(\.label), ["a", "b"])
    }

    /// The fixture that distinguishes the failure: an answered call and an open one, in that
    /// order, with DIFFERENT question text. A finder that returned the first `AskUserQuestion`
    /// it saw would return "Old?" and this asserts "New?".
    func testAnAnsweredCallIsSkippedAndTheOpenOneIsFound() throws {
        let lines = [
            line(0, ask("toolu_OLD", question: "Old?")),
            line(100, answer("toolu_OLD")),
            line(200, ask("toolu_NEW", question: "New?")),
        ]
        let found = try XCTUnwrap(ClaudePendingQuestion.find(in: lines, session: session))
        XCTAssertEqual(found.id, "toolu_NEW")
        XCTAssertEqual(found.question, "New?")
    }

    func testEverythingAnsweredIsNoOpenQuestion() {
        let lines = [line(0, ask("toolu_A")), line(100, answer("toolu_A"))]
        XCTAssertNil(ClaudePendingQuestion.find(in: lines, session: session))
    }

    /// A running `Bash` is not a question, and this is the test that says the rule is scoped
    /// to the one tool it is true for. Without it, every long-running command on the machine
    /// would render as a prompt with no options.
    func testAnUnansweredCallToAnyOtherToolIsNotAQuestion() {
        let bash = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_B","name":"Bash","input":{"command":"sleep 600"}}]}}
        """
        XCTAssertNil(ClaudePendingQuestion.find(in: [line(0, bash)], session: session))
    }

    /// Sub-agent records are skipped for the reason `ClaudeTimelineMapper` skips them: a
    /// sidechain in the main transcript is claude having moved them, and a sub-agent's own
    /// question is not the one the user in front of this tab is being asked.
    func testASidechainQuestionIsNotThisTabsQuestion() {
        let sidechain = ask("toolu_S")
            .replacingOccurrences(of: #""type":"assistant""#, with: #""type":"assistant","isSidechain":true"#)
        XCTAssertNil(ClaudePendingQuestion.find(in: [line(0, sidechain)], session: session))
    }

    func testAMalformedLineIsSkippedRatherThanFailingTheWholeTail() throws {
        let lines = [line(0, "{not json"), line(20, ask("toolu_A"))]
        XCTAssertEqual(
            ClaudePendingQuestion.find(in: lines, session: session)?.id, "toolu_A"
        )
    }

    /// The result for a call can be in the same *record* as nothing else — but a record can
    /// also carry several blocks. A result block sitting beside a text block must still close
    /// its call.
    func testAResultBesideOtherBlocksStillClosesItsCall() {
        let mixed = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"ok"},\
        {"type":"tool_result","tool_use_id":"toolu_A","content":"done"}]}}
        """
        XCTAssertNil(
            ClaudePendingQuestion.find(in: [line(0, ask("toolu_A")), line(100, mixed)],
                                       session: session)
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Expected: `cannot find 'ClaudePendingQuestion' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeck/Agents/ClaudePendingQuestion.swift`**

```swift
import FleetKit
import Foundation

/// Finds the `AskUserQuestion` a claude session is blocked on, in a window of its transcript.
///
/// **Why this is not part of `ClaudeTimelineMapper`.** That type answers "what does this line
/// mean" one line at a time, statelessly, and it must stay that way — `TimelineReader` maps a
/// page's lines independently and budgets whole records. This answers a question about the
/// *relationship* between lines, which no per-line mapper can, and it needs no page budget and
/// no offsets. Separate function, separate file, same fixtures-not-processes discipline.
///
/// **The window is a tail, and that is exact rather than a shortcut.** Claude cannot proceed
/// past an unanswered question, so an open one is always the last record of the file. A read
/// of the last few records therefore either finds it or proves there is none — see
/// `PromptService`, which asks `TranscriptPager` for `.latest`.
enum ClaudePendingQuestion {
    /// The tool whose *execution* is a human answering. The rule below is true for this name
    /// and false for every other one, which is why it is a constant rather than a parameter.
    static let toolName = "AskUserQuestion"

    /// The open question in these lines, or nil.
    ///
    /// Two passes, and one pass would be wrong: the result for a call can only appear after
    /// it, but there may be several calls in the window and only the last is interesting, so
    /// the set of closed ids has to be complete before any call is judged.
    static func find(in lines: [SourceLine], session: UUID) -> PendingPrompt? {
        var closed: Set<String> = []
        var calls: [(id: String, input: Any)] = []

        for line in lines {
            guard let data = line.text.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            // A sidechain record in the main transcript is claude having moved a sub-agent's
            // conversation into it. The sub-agent's question is not the one the person looking
            // at this tab is being asked. Same guard, same reason, as `ClaudeTimelineMapper`'s.
            guard record["isSidechain"] as? Bool != true else { continue }
            guard let message = record["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }

            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { closed.insert(id) }
                case "tool_use":
                    guard block["name"] as? String == toolName,
                          let id = block["id"] as? String,
                          let input = block["input"]
                    else { continue }
                    calls.append((id, input))
                default:
                    continue
                }
            }
        }

        // Last first: several may be open in a window only if the file is malformed, and the
        // newest is the one the terminal is showing.
        for call in calls.reversed() where !closed.contains(call.id) {
            // Re-serialized rather than passed as `Any`, because `PendingPrompt.question` reads
            // JSON text — the same text the phone reads out of a `.prompt` row's body, which is
            // what keeps one parser for both entry points. `sortedKeys` is not needed here (the
            // result is parsed, not shown) but is harmless and matches `ToolInputSummary.pretty`.
            guard JSONSerialization.isValidJSONObject(input(of: call)),
                  let data = try? JSONSerialization.data(withJSONObject: input(of: call)),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            if let prompt = PendingPrompt.question(
                session: session, callID: call.id, toolInput: text
            ) {
                return prompt
            }
        }
        return nil
    }

    private static func input(of call: (id: String, input: Any)) -> Any { call.input }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Expected: baseline + 31 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Iterate `calls` forwards instead of `calls.reversed()` | **Check this one.** With the current fixtures the answered call is filtered by `closed` either way, so it may produce zero failures — if it does, that is the fixture's fault: add a test with *two* open calls (`toolu_1` then `toolu_2`, neither answered) asserting `toolu_2` is returned, then re-run the mutation |
| Delete `guard block["name"] as? String == toolName` | `testAnUnansweredCallToAnyOtherToolIsNotAQuestion` |
| Delete the `isSidechain` guard | `testASidechainQuestionIsNotThisTabsQuestion` |
| Collect `closed` and `calls` in one pass, judging each call as it is seen | `testAnAnsweredCallIsSkippedAndTheOpenOneIsFound` **only if** the answered call precedes the open one in the fixture — it does; confirm the assertion is on `question` text and not just on `id`, since both distinguish it |
| In the `tool_result` arm, `break` out of the block loop after the first result | `testAResultBesideOtherBlocksStillClosesItsCall` — **verify the fixture puts the text block FIRST**, which it does; if the result were first, `break` after it would be harmless and the mutation would be a no-op |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudePendingQuestion.swift \
        Tests/FlightDeckTests/ClaudePendingQuestionTests.swift
git commit -m "feat: find the question a claude session is blocked on"
```

---

## Task 5: `ChoiceDialog` — reading an option list off the screen

**Files:**
- Create: `Sources/FlightDeck/ChoiceDialog.swift`
- Test: `Tests/FlightDeckTests/ChoiceDialogTests.swift`

**Interfaces:**
- Produces:
  - `struct ChoiceDialog: Equatable { let question: String; let labels: [String]; let selected: Int }`
  - `enum ChoiceDialog.Failure: Error, Equatable { case noDialog, noSelection, ambiguous }`
  - `static func ChoiceDialog.read(fromViewport: String) -> ChoiceDialog?`
  - `static func ChoiceDialog.locate(labels: [String], inViewport: String) -> Result<Int, Failure>`

> **Read this before writing a line of it.** No capture of a real Claude Code dialog exists in this repository and none can be made from this branch — `vendor/ghostty` holds artifacts, not sources, and no live claude session is reachable from a test. **Every fixture in this task is synthetic**, built from what the 2.1.241 binary shows of the dialog's construction (`"Do you want to proceed?"` rendered above an option list; the focused row prefixed `❯` and unfocused rows prefixed with spaces; permission options numbered). Task 13 puts a manual capture on the `docs/MOBILE.md` checklist and it is the one item in this plan that must be done by hand before this feature is believed. **Design for the parse failing**: every path here returns nil or a failure rather than a guess, and Task 7 refuses to press Return on one.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/ChoiceDialogTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Reading a TUI option list off a plain-text viewport.
///
/// **Every fixture here is synthetic and that is stated rather than hidden.** libghostty
/// returns plain text with no cell attributes (`TextInjecting.readViewport`), so a dialog and
/// a paragraph of prose are the same bytes with different shapes, and the shapes below were
/// built from the 2.1.241 binary's construction of the prompt rather than captured from a
/// running session. The manual checklist item in `docs/MOBILE.md` is what makes them true.
///
/// The bias throughout is refusal. A wrong answer here becomes a keystroke in someone's live
/// terminal.
final class ChoiceDialogTests: XCTestCase {
    private func viewport(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    private let permission = [
        "  ⏺ Bash(rm -rf build)",
        "",
        "  Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for Bash commands in /Users/nate",
        "  3. No, and tell Claude what to do differently (esc)",
        "",
    ]

    // MARK: read — the permission case, where nothing else knows the labels

    func testANumberedListUnderAQuestionIsADialog() throws {
        let dialog = try XCTUnwrap(ChoiceDialog.read(fromViewport: viewport(permission)))
        XCTAssertEqual(dialog.question, "Do you want to proceed?")
        XCTAssertEqual(dialog.labels, [
            "Yes",
            "Yes, and don't ask again for Bash commands in /Users/nate",
            "No, and tell Claude what to do differently (esc)",
        ])
        XCTAssertEqual(dialog.selected, 0)
    }

    func testTheSelectedRowIsTheOneMarked() throws {
        var lines = permission
        lines[3] = "  1. Yes"
        lines[4] = "❯ 2. Yes, and don't ask again for Bash commands in /Users/nate"
        let dialog = try XCTUnwrap(ChoiceDialog.read(fromViewport: viewport(lines)))
        XCTAssertEqual(dialog.selected, 1)
    }

    /// **Numbering is required for a blind read, and this is the guard that earns it.** With
    /// no transcript to check against, indentation alone is not a signal — a wrapped paragraph
    /// under a rhetorical question is indented too. Refusing here costs a card the phone
    /// cannot draw; accepting would cost a Return pressed at a conversation.
    func testAnIndentedParagraphUnderAQuestionIsNotADialog() {
        XCTAssertNil(ChoiceDialog.read(fromViewport: viewport([
            "  So what happens next?",
            "  We run the suite and see.",
            "  Then we decide.",
        ])))
    }

    func testAListWithNothingSelectedIsNotADialog() {
        var lines = permission
        lines[3] = "  1. Yes"
        XCTAssertNil(ChoiceDialog.read(fromViewport: viewport(lines)))
    }

    func testTheLastDialogOnScreenWinsOverAnEarlierOne() throws {
        let dialog = try XCTUnwrap(ChoiceDialog.read(fromViewport: viewport(
            ["  Older question?", "❯ 1. Old A", "  2. Old B", ""] + permission
        )))
        XCTAssertEqual(dialog.question, "Do you want to proceed?")
    }

    func testAnEmptyViewportIsNotADialog() {
        XCTAssertNil(ChoiceDialog.read(fromViewport: ""))
    }

    // MARK: locate — the question case, where the labels are known exactly

    func testKnownLabelsAreLocatedAndTheSelectionReported() {
        let lines = [
            "  Which skill?",
            "❯ Playing jazz piano",
            "  Speaking 10 languages",
            "  Woodworking",
        ]
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: ["Playing jazz piano", "Speaking 10 languages", "Woodworking"],
                inViewport: viewport(lines)
            ),
            .success(0)
        )
    }

    /// Terminal width truncates a long label, so an exact match would refuse every real
    /// dialog with a sentence in it. A prefix is matched instead — and the prefix must be
    /// unique among the labels, which the next test is about.
    func testATruncatedLabelIsStillLocated() {
        let lines = [
            "  Pick one",
            "❯ Sit down at any piano and improvise fluently with a ba…",
            "  Drop into any country and converse like a local, catch…",
        ]
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: [
                    "Sit down at any piano and improvise fluently with a band, for free.",
                    "Drop into any country and converse like a local, catching subtext.",
                ],
                inViewport: viewport(lines)
            ),
            .success(0)
        )
    }

    /// **The fixture that makes prefix matching safe.** Two labels sharing the visible prefix
    /// cannot be told apart on screen, so the answer is a refusal rather than a coin flip.
    func testTwoLabelsSharingTheirVisiblePrefixAreRefusedRatherThanGuessed() {
        let lines = ["❯ Deploy to production and…", "  Deploy to production and…"]
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: ["Deploy to production and notify", "Deploy to production and wait"],
                inViewport: viewport(lines)
            ),
            .failure(.ambiguous)
        )
    }

    func testLabelsThatAreNotOnScreenAreRefused() {
        XCTAssertEqual(
            ChoiceDialog.locate(labels: ["a", "b"], inViewport: "nothing like that here"),
            .failure(.noDialog)
        )
    }

    func testLabelsOnScreenWithNoMarkerAreRefused() {
        XCTAssertEqual(
            ChoiceDialog.locate(labels: ["Yes", "No"], inViewport: viewport(["  Yes", "  No"])),
            .failure(.noSelection)
        )
    }

    func testTwoMarkedRowsAreRefused() {
        XCTAssertEqual(
            ChoiceDialog.locate(labels: ["Yes", "No"], inViewport: viewport(["❯ Yes", "❯ No"])),
            .failure(.ambiguous)
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail** — `cannot find 'ChoiceDialog' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeck/ChoiceDialog.swift`**

```swift
import Foundation

/// An option list as it appears on a terminal screen.
///
/// **Two entry points, because the two callers know different amounts.** `locate` is used when
/// the labels are already known exactly — an `AskUserQuestion` read from the transcript — and
/// its job is only to find them and say which is selected. `read` is used when nothing else
/// knows: a tool permission dialog exists nowhere but here, so the labels have to be inferred
/// from the shape, and the bar for believing a shape is correspondingly higher.
///
/// **Nothing here is verified against a captured screen.** libghostty returns plain text with
/// no cell attributes (`TextInjecting.readViewport`), and `vendor/ghostty` in this checkout
/// holds artifacts rather than sources, so this parser was written from the 2.1.241 binary's
/// construction of the dialog and not from a picture of one. `docs/MOBILE.md` carries the
/// manual capture that makes it true. Until then, treat every `nil` and every `.failure` here
/// as the expected outcome rather than the exceptional one — and note that `SessionStore.choose`
/// re-reads and re-locates *after* moving the cursor and refuses to press Return unless the
/// second read agrees, so a parser that is wrong in a new way stops at a moved cursor.
///
/// The same distrust `InputBar` documents applies, one level up: this cannot tell a hint from
/// a draft, a dialog from a paragraph, or a truncation from a short label, and every rule below
/// is chosen so that being wrong produces a refusal rather than a keystroke.
struct ChoiceDialog: Equatable {
    /// The line above the list, verbatim and trimmed.
    let question: String
    /// The options, in screen order, with the marker and any `N.` prefix removed.
    let labels: [String]
    /// Which one carries the marker.
    let selected: Int

    enum Failure: Error, Equatable {
        /// The labels are not on this screen at all, or nothing dialog-shaped is.
        case noDialog
        /// They are, and none of them is marked. A list with no cursor cannot be moved from.
        case noSelection
        /// Two rows are indistinguishable, or two are marked. Either way there is no answer
        /// that is not a guess.
        case ambiguous
    }

    /// U+276F, the marker Claude Code draws on the focused row. The same glyph `InputBar`
    /// keys on, which is why that type must never be pointed at a dialog: it would read the
    /// selected option as a draft.
    static let marker: Character = "❯"

    /// How many characters of a label have to match for a row to be that label.
    ///
    /// A prefix rather than the whole string because a terminal truncates, and a *bounded*
    /// prefix rather than "as much as fits" because the comparison has to be symmetric across
    /// the two reads `choose` makes. Long enough that two real options rarely collide; short
    /// enough to survive an 80-column window. `locate` refuses when two labels do collide,
    /// which is what keeps the number a tuning choice rather than a correctness one.
    static let matchPrefix = 24

    // MARK: A blind read, for a dialog nothing else describes

    /// The last dialog on screen, or nil.
    ///
    /// **Numbering is required.** With no labels to check against, `^\s*[❯ ]\s*\d+\.\s+\S` is
    /// the strongest signal available that a run of lines is an option list rather than a
    /// wrapped paragraph, and a wrapped paragraph is what the weaker rule (indentation) would
    /// accept. Claude Code numbers its permission options; if a dialog it does not number ever
    /// needs this path, widen it deliberately with a captured fixture in hand, not by relaxing
    /// this to "indented lines".
    static func read(fromViewport viewport: String) -> ChoiceDialog? {
        let lines = viewport.components(separatedBy: "\n")
        var rows: [(index: Int, label: String, isSelected: Bool)] = []
        var lastRun: [(index: Int, label: String, isSelected: Bool)] = []

        for (index, line) in lines.enumerated() {
            if let row = numberedRow(line) {
                rows.append((index, row.label, row.isSelected))
            } else if !rows.isEmpty {
                lastRun = rows
                rows = []
            }
        }
        if !rows.isEmpty { lastRun = rows }
        // One option is not a list, and a "dialog" of one is far more likely to be a numbered
        // line of prose. Two is the floor for anything worth offering a choice about.
        guard lastRun.count >= 2 else { return nil }
        guard lastRun.filter(\.isSelected).count == 1,
              let selected = lastRun.firstIndex(where: \.isSelected)
        else { return nil }

        // The question is the nearest non-empty line above the run. Absent is not fatal —
        // "Do you want to proceed?" is not the information, the options are — so an empty
        // string is carried rather than refusing.
        let above = lines[..<lastRun[0].index].reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ChoiceDialog(
            question: above?.trimmingCharacters(in: .whitespaces) ?? "",
            labels: lastRun.map(\.label),
            selected: selected
        )
    }

    /// `  1. Yes` / `❯ 2. No` → its label and whether it is marked. Nil for anything else.
    private static func numberedRow(_ line: String) -> (label: String, isSelected: Bool)? {
        var rest = Substring(line)
        let isSelected = rest.drop(while: { $0 == " " }).first == marker
        rest = rest.drop(while: { $0 == " " || $0 == marker })
        rest = rest.drop(while: { $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        let label = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (label, isSelected)
    }

    // MARK: A checked read, for a dialog whose labels are already known

    /// Which of `labels` is currently selected on this screen.
    ///
    /// Matching is by bounded prefix, so a label the terminal truncated is still found — and
    /// two labels whose prefixes collide are `.ambiguous` rather than a guess, because on
    /// screen they genuinely are the same row.
    static func locate(labels: [String], inViewport viewport: String) -> Result<Int, Failure> {
        let keys = labels.map(key(of:))
        guard Set(keys).count == keys.count else { return .failure(.ambiguous) }

        var found: [Int: Bool] = [:]     // label index → is it the marked row
        for line in viewport.components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let isSelected = trimmed.first == marker
            let content = key(of: String(trimmed.drop(while: { $0 == " " || $0 == marker })))
            guard !content.isEmpty else { continue }
            for (index, expected) in keys.enumerated() where content.hasPrefix(expected) {
                // A row already found on an earlier line means the label appears twice — in
                // the list and in the scrollback echo above it, say. The LAST occurrence wins,
                // for the reason `InputBar.read` takes the last box: earlier ones are history.
                found[index] = isSelected
            }
        }
        guard found.count == labels.count else { return .failure(.noDialog) }
        let marked = found.filter(\.value).keys
        guard marked.count <= 1 else { return .failure(.ambiguous) }
        guard let selected = marked.first else { return .failure(.noSelection) }
        return .success(selected)
    }

    /// What two strings are compared as: the first `matchPrefix` characters, whitespace
    /// collapsed, with a trailing ellipsis stripped.
    ///
    /// The ellipsis matters: a truncated row ends `…` (or `...`), and comparing that against
    /// the label's own characters at the same position would fail on exactly the rows
    /// truncation affects — which is to say, on the long ones this rule exists for.
    private static func key(of text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\u{a0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("…") || normalized.hasSuffix(".") { normalized.removeLast() }
        return String(normalized.prefix(matchPrefix))
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass** — baseline + 44 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `numberedRow`, drop the `guard rest.first == "."` and accept a bare leading digit | `testAnIndentedParagraphUnderAQuestionIsNotADialog` — **check the fixture first: none of its lines starts with a digit, so this mutation may be a no-op.** If so, add a line `"  2 things could happen."` to that fixture, which the current parser rejects (no `.`) and the mutant accepts |
| In `read`, change `lastRun.filter(\.isSelected).count == 1` to `>= 0` | `testAListWithNothingSelectedIsNotADialog` |
| In `read`, keep the *first* run rather than the last | `testTheLastDialogOnScreenWinsOverAnEarlierOne` |
| In `locate`, delete `guard Set(keys).count == keys.count` | `testTwoLabelsSharingTheirVisiblePrefixAreRefusedRatherThanGuessed` |
| In `locate`, change `marked.count <= 1` to `marked.count >= 1` | `testTwoMarkedRowsAreRefused` |
| In `key(of:)`, stop stripping the ellipsis | `testATruncatedLabelIsStillLocated` |
| In `read`, change `lastRun.count >= 2` to `>= 1` | **No current test fails.** Add `testASingleNumberedLineIsNotADialog` with viewport `["❯ 1. Continue"]` before relying on this row |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/ChoiceDialog.swift Tests/FlightDeckTests/ChoiceDialogTests.swift
git commit -m "feat: read a terminal's option list, and refuse when it cannot be read"
```

---

## Task 6: Arrow keys, and every fake that has to grow one

**Files:**
- Modify: `Sources/FlightDeck/TextInjecting.swift`
- Modify: `Tests/FlightDeckTests/SpyInjector.swift`
- Modify: `Tests/FlightDeckTests/CodexResumeTests.swift` (its private `SpyInjector`, ~line 277)
- Modify: `Tests/FlightDeckTests/CodexIntegrationTests.swift` (its private `SpyInjector`, ~line 477)

**Interfaces:**
- Produces: `func TextInjecting.sendArrowDown()`, `func TextInjecting.sendArrowUp()`; `SpyInjector.Event.arrow(Int)`; `SpyInjector.options`/`selected` modelling.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/ChoiceDialogTests.swift` — no, put it in its own file so Task 5's file stays about parsing. Create the assertion inside Task 7's `AnswerPromptTests`; **this task's proof is the compile**, plus one behavioural test on the fake:

Add to `Tests/FlightDeckTests/SpyInjector.swift`'s companion — create `Tests/FlightDeckTests/SpyInjectorOptionsTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The fake models the option list, it does not merely record against it — the same decision
/// `SpyInjector`'s input-bar modelling documents, and for the same reason: a fake that ignored
/// what a keystroke DOES would let the dangerous case pass. `SessionStore.choose` re-reads the
/// screen after moving and refuses to press Return unless the marker landed on the intended
/// row, so a fake whose screen never changed would make that check untestable.
@MainActor
final class SpyInjectorOptionsTests: XCTestCase {
    func testAnArrowMovesTheMarkerOnTheModelledScreen() throws {
        let spy = SpyInjector()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.sendArrowDown()
        let dialog = try XCTUnwrap(ChoiceDialog.read(fromViewport: XCTUnwrap(spy.readViewport())))
        XCTAssertEqual(dialog.selected, 1)
        XCTAssertEqual(dialog.labels, ["Yes", "No", "Maybe"])
    }

    func testTheMarkerDoesNotRunOffEitherEnd() {
        let spy = SpyInjector()
        spy.showOptions(["Yes", "No"], selected: 0)
        spy.sendArrowUp()
        XCTAssertEqual(spy.selected, 0)
        spy.sendArrowDown()
        spy.sendArrowDown()
        XCTAssertEqual(spy.selected, 1)
    }

    func testTheOrderOfEveryEventIsRecorded() {
        let spy = SpyInjector()
        spy.showOptions(["a", "b"], selected: 0)
        spy.sendArrowDown()
        spy.sendReturn()
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }
}
```

- [ ] **Step 2: Run and verify it fails** — `value of type 'SpyInjector' has no member 'showOptions'`.

- [ ] **Step 3: Extend the protocol in `Sources/FlightDeck/TextInjecting.swift`**

Add to the protocol:

```swift
    /// Move a full-screen TUI's option list down one row, as a real key event.
    ///
    /// A key event and not text, for exactly the reason `sendReturn()` is one: `sendText` is a
    /// paste, ghostty wraps a paste in bracketed-paste markers, and an escape sequence inside
    /// those markers is inserted as literal *content* rather than acted on. An arrow written as
    /// `ESC [ B` through `sendText` would put five visible characters in a dialog.
    func sendArrowDown()

    /// The same, upwards. Both directions exist because a list's cursor can start below the
    /// target — Claude Code remembers a "recommended" option and focuses it — so a driver that
    /// could only go down would wrap or stall.
    func sendArrowUp()
```

And to the `Ghostty.SurfaceView` extension:

```swift
    func sendArrowDown() { sendArrow(.arrowDown) }
    func sendArrowUp() { sendArrow(.arrowUp) }

    /// No `text:`, deliberately: an arrow has no textual form, and ghostty's own key encoder
    /// is what turns the keycode into whatever the running program expects — which differs by
    /// keyboard protocol and is not this file's business to reproduce. Contrast `sendControl`,
    /// which states its byte because the mapping there is the thing worth reading.
    private func sendArrow(_ key: Ghostty.Input.Key) {
        guard let surfaceModel else { return }
        surfaceModel.sendKeyEvent(.init(key: key, action: .press))
        surfaceModel.sendKeyEvent(.init(key: key, action: .release))
    }
```

- [ ] **Step 4: Extend `Tests/FlightDeckTests/SpyInjector.swift`**

```swift
    enum Event: Equatable {
        case text(String)
        case ret
        case killLine
        case yank
        /// `+1` for down, `-1` for up. One case rather than two so a test can assert a run of
        /// movement as a list of numbers.
        case arrow(Int)
    }

    /// The option list on screen, when one is up. Empty means the input bar is showing
    /// instead, which is what `renderedRows` models.
    private(set) var options: [String] = []
    private(set) var selected = 0

    func sendArrowDown() {
        events.append(.arrow(1))
        guard !options.isEmpty else { return }
        selected = min(selected + 1, options.count - 1)
    }

    func sendArrowUp() {
        events.append(.arrow(-1))
        guard !options.isEmpty else { return }
        selected = max(selected - 1, 0)
    }

    /// Puts a numbered option list on screen, in the shape `ChoiceDialog` parses.
    func showOptions(_ labels: [String], selected: Int = 0) {
        options = labels
        self.selected = selected
    }
```

and make `readViewport()` draw whichever is up:

```swift
    func readViewport() -> String? {
        guard viewportIsReadable else { return nil }
        let rule = String(repeating: "─", count: 92)
        guard options.isEmpty else {
            let rows = options.enumerated().map { index, label in
                "\(index == selected ? "❯" : " ") \(index + 1). \(label)"
            }
            return (["  Do you want to proceed?"] + rows + [""]).joined(separator: "\n")
        }
        return ([rule] + renderedRows + [rule, "  Opus 5 (1M context)  ⎇ master"])
            .joined(separator: "\n")
    }
```

- [ ] **Step 5: Add the two methods to the two private `SpyInjector`s**

In `CodexResumeTests.swift:277` and `CodexIntegrationTests.swift:477`, add:

```swift
        func sendArrowDown() {}
        func sendArrowUp() {}
```

Nothing else in those files changes.

- [ ] **Step 6: Run the tests and verify they pass** — baseline + 47 cumulative. **Every existing injection test must be unchanged**: `rename`, `submitPrompt` and the resume queue all read `renderedRows`, and `options` is empty for all of them.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `SpyInjector.sendArrowDown`, drop the `min(...)` clamp | `testTheMarkerDoesNotRunOffEitherEnd` — the second down would reach index 2 of a 2-element list |
| In `readViewport()`, draw the option rows without the `❯`/space prefix | `testAnArrowMovesTheMarkerOnTheModelledScreen` (via `ChoiceDialog.read` returning nil, so the `XCTUnwrap` fails) |
| In `readViewport()`, drop the `\(index + 1). ` numbering | Same test — and this is the mutation that proves Task 5's numbering rule is actually load-bearing rather than decorative |
| Delete `events.append(.arrow(1))` | `testTheOrderOfEveryEventIsRecorded` |
| In `Ghostty.SurfaceView.sendArrow`, send only `.press` and no `.release` | **Nothing fails, and cannot** — no test stands on the real surface. Record that in the task report; the manual checklist in Task 13 is the only cover for it |

- [ ] **Step 8: Verify** — full four scripts.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeck/TextInjecting.swift Tests/FlightDeckTests/SpyInjector.swift \
        Tests/FlightDeckTests/SpyInjectorOptionsTests.swift \
        Tests/FlightDeckTests/CodexResumeTests.swift Tests/FlightDeckTests/CodexIntegrationTests.swift
git commit -m "feat: move a TUI's selection with real key events"
```

---

## Task 7: `SessionStore.answerPrompt` — the funnel that presses Return

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (new section after `submitPrompt`'s, ~line 2960; `viewport(of:)` beside `status(for:)` at ~3129)
- Test: `Tests/FlightDeckTests/AnswerPromptTests.swift`

**Interfaces:**
- Consumes: `ChoiceDialog.locate(labels:inViewport:)` (Task 5), `TextInjecting.sendArrowDown/Up` (Task 6), `PendingPrompt` (Task 1), `SessionStore.injectionSettle`, `SessionStore.injecting`, `SessionStore.now`
- Produces:
  - `enum SessionStore.AnswerDispatch: Equatable { case dispatched, duplicate, unknownSession, unsupportedAgent, notWaiting, unanswerable, unreadableScreen; var errorCode: String? }`
  - `func SessionStore.answerPrompt(_ prompt: PendingPrompt, choosing index: Int, token: UUID) -> AnswerDispatch`
  - `func SessionStore.viewport(of id: UUID) -> String?`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/AnswerPromptTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Answering a dialog by driving the terminal.
///
/// **The ordering of the events is the contract**, exactly as it is for `inject`: the arrows
/// go first, the screen is re-read, and Return is pressed only if the marker landed where it
/// was sent. A test that asserted only "Return was pressed" would pass against a driver that
/// pressed it blind, which is the failure mode with a person's `rm -rf` on the other side.
@MainActor
final class AnswerPromptTests: XCTestCase {
    private func makeStore(activity: SessionActivity = .waiting)
        -> (SessionStore, SpyInjector, UUID) {
        // Same shape as PhonePromptDispatchTests' helper: one claude tab, an injector
        // override, a status, and a synchronous `injectionSettle`. Lift that helper rather
        // than rewriting it if it is already internal.
        …
    }

    private func prompt(_ id: UUID, labels: [String]) -> PendingPrompt {
        PendingPrompt(
            id: "toolu_A", kind: .question, session: id,
            question: "Which?", options: labels.map { .init(label: $0) }
        )
    }

    func testChoosingTheRowBelowSendsOneArrowThenReturn() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No", "Maybe"]),
                               choosing: 1, token: UUID()),
            .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testChoosingTheRowAlreadySelectedSendsReturnAndNoArrows() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 0, token: UUID())
        XCTAssertEqual(spy.events, [.ret])
    }

    func testChoosingARowAboveSendsUpArrows() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 2)
        store.answerPrompt(prompt(id, labels: ["Yes", "No", "Maybe"]), choosing: 0, token: UUID())
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1), .ret])
    }

    /// **The test this whole funnel exists for.** The fake's list stops moving after one row —
    /// modelling a TUI that ignored a keystroke, repainted late, or is not the list we thought
    /// — and the driver must notice and send NOTHING further. A moved cursor is recoverable by
    /// the person at the keyboard; a Return on the wrong row is not.
    func testReturnIsNotPressedWhenTheMarkerDidNotLandOnTheChosenRow() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 1
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No", "Maybe"]),
                               choosing: 2, token: UUID()),
            .dispatched, "the command was dispatched; whether it landed is a later fact"
        )
        XCTAssertFalse(spy.events.contains(.ret), "no Return on an unconfirmed selection")
    }

    func testAnUnreadableScreenIsRefusedBeforeAnythingIsSent() {
        let (store, spy, id) = makeStore()
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes"]), choosing: 0, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A screen showing a different dialog than the one the phone was looking at. The labels
    /// are not there, so nothing is sent — this is the second half of the racing guard, below
    /// `PromptService`'s id check.
    func testADialogThatIsNoLongerOnScreenIsRefused() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Something else entirely", "And another"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 1, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **`inject`'s gate, inverted, and the inversion is the point.** A session that is idle
    /// has no dialog up; a Return there submits whatever is in the input bar.
    func testAnIdleSessionIsRefused() {
        let (store, spy, id) = makeStore(activity: .idle)
        spy.showOptions(["Yes"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes"]), choosing: 0, token: UUID()),
            .notWaiting
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testACodexTabIsRefusedBeforeItsStatusIsConsulted() {
        // A codex tab that is ALSO waiting — so a store that checked status first would get
        // past the gate and reach the injector.
        let (store, spy, id) = makeCodexStore(activity: .waiting)
        spy.showOptions(["Yes"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes"]), choosing: 0, token: UUID()),
            .unsupportedAgent
        )
    }

    func testAnUnanswerableShapeIsRefused() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["a", "b"], selected: 0)
        var multi = prompt(id, labels: ["a", "b"])
        multi.unanswerable = PendingPrompt.multiSelectReason
        XCTAssertEqual(store.answerPrompt(multi, choosing: 0, token: UUID()), .unanswerable)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnIndexOutsideTheOptionsIsRefused() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 7, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The retry rule, and the fixture that distinguishes it: the SAME token twice, with the
    /// screen reset between, so a store that forgot the token would send a second Return.
    func testTheSameTokenTwiceAnswersOnce() {
        let (store, spy, id) = makeStore()
        let token = UUID()
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 1, token: token),
            .dispatched
        )
        spy.showOptions(["Yes", "No"], selected: 0)
        let before = spy.events.count
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 1, token: token),
            .duplicate
        )
        XCTAssertEqual(spy.events.count, before, "a repeat types nothing")
    }

    /// A rename or a queued phone prompt mid-settle must not interleave with this. Both use
    /// the same `injecting` set, and this asserts the shared gate rather than trusting it.
    func testATabAlreadyInjectingIsRefused() {
        let (store, spy, id) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.holdInjectionForTesting(id)
        XCTAssertEqual(
            store.answerPrompt(prompt(id, labels: ["Yes", "No"]), choosing: 1, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }
}
```

> `SpyInjector.ignoreArrowsAfter` and `SessionStore.holdInjectionForTesting(_:)` are two small seams this task adds — the first to `SpyInjector` (count arrows, stop moving after N), the second beside `flushPendingResumePromptsForTesting` at `SessionStore.swift:2583`.

- [ ] **Step 2: Run the tests and verify they fail** — `value of type 'SessionStore' has no member 'answerPrompt'`.

- [ ] **Step 3: Add `viewport(of:)` beside `status(for:)` (~line 3129)**

```swift
    /// The tab's terminal screen, or nil when there is no surface or it cannot be read.
    ///
    /// Internal rather than private because `PromptService` needs it: a permission dialog
    /// exists nowhere but on this screen, so composing a `PendingPrompt` for one means reading
    /// it. A read and only a read — it changes no fleet state and adds no mutation site for
    /// `FleetReplicator`'s drift check.
    func viewport(of id: UUID) -> String? { injector(for: id)?.readViewport() }
```

- [ ] **Step 4: Add the answer section after `submitPrompt`'s**

```swift
    // MARK: - Answering a question from a paired phone

    /// What a client's answer did.
    ///
    /// **`dispatched` is the ceiling, and that is honest rather than lazy.** The driver acts
    /// across `injectionSettle` — it moves the cursor, waits for claude to repaint, re-reads
    /// the screen, and only then presses Return — so whether the answer LANDED is not knowable
    /// when this returns. §4's rule is the same one: `ack` means dispatched, and the observable
    /// effect arrives separately. Here it arrives twice over: the session stops being
    /// `waiting`, which the phone is pushed, and the transcript grows a `tool_result`, which
    /// the phone pulls.
    ///
    /// Everything knowable BEFORE the settle is a distinct refusal, because each sends the
    /// reader somewhere different: `unsupportedAgent` means never on this tab,
    /// `notWaiting` means nothing is up, `unreadableScreen` means try again in a moment, and
    /// `unanswerable` means walk to the Mac.
    enum AnswerDispatch: Equatable {
        /// Accepted, and the driver has started. `ack`.
        case dispatched
        /// This token has already been accepted for this tab. `ack`, because from the client's
        /// side a retry that lands is an answer that landed.
        case duplicate
        case unknownSession
        /// This tab's agent has no dialog Flight Deck can drive. Codex, and anything newer.
        case unsupportedAgent
        /// Nothing is blocked on this tab right now.
        case notWaiting
        /// A shape this build will not drive — see `PendingPrompt.unanswerable`.
        case unanswerable
        /// The terminal could not be read, the dialog was not on it, the index named no
        /// option, or another injection is already resolving for this tab. **One code for
        /// four states deliberately**: every one of them means "not right now, and the phone
        /// should refetch", and splitting them would invite a client to treat some as
        /// permanent. The distinctions are worth a log line and not a wire code.
        case unreadableScreen

        var errorCode: String? {
            switch self {
            case .dispatched, .duplicate: return nil
            case .unknownSession: return "unknown_session"
            case .unsupportedAgent: return "unsupported_agent"
            case .notWaiting: return "not_waiting"
            case .unanswerable: return "unanswerable"
            case .unreadableScreen: return "unreadable_screen"
            }
        }
    }

    /// Tokens this store has already answered with, per tab. Same shape, same bound and same
    /// reasoning as `acceptedPromptTokens` — see it for why a retry has to be free.
    private var answeredPromptTokens: [UUID: [UUID]] = [:]

    /// A client chose option `index` of `prompt`. Drive the terminal to it.
    ///
    /// **`prompt` is the Mac's own copy, never the client's.** `PromptService` looks up the
    /// `PendingPrompt` it served and passes it here; the command from the phone contributes a
    /// tab, a prompt id, an index and a token. Nothing a phone sends becomes a label this
    /// function matches on screen. That is the difference between a remote control and a
    /// remote keyboard.
    ///
    /// **The order of the checks is load-bearing twice**, exactly as `submitPrompt`'s is. The
    /// agent test comes before the status test, so a codex tab that happens to be `waiting` is
    /// told `unsupportedAgent` — never on this tab — rather than being let through to a
    /// terminal whose dialogs this build has never read. And the token test comes before
    /// anything is typed, so a retry of something already answered types nothing even if the
    /// screen has moved on.
    ///
    /// Changes no fleet state and emits no `FleetEvent`: what the phone answered becomes
    /// visible through the status the agent itself writes and the transcript it appends, not
    /// through a mirrored field.
    @discardableResult
    func answerPrompt(
        _ prompt: PendingPrompt, choosing index: Int, token: UUID
    ) -> AnswerDispatch {
        let id = prompt.session
        guard let at = locate(id) else { return .unknownSession }
        guard repos[at.repo].sessions[at.session].agent == .claude else {
            return .unsupportedAgent
        }
        if answeredPromptTokens[id, default: []].contains(token) { return .duplicate }
        guard prompt.isAnswerable else { return .unanswerable }
        guard prompt.options.indices.contains(index) else { return .unreadableScreen }
        // `inject`'s gate, inverted. A session that is not `waiting` has no dialog up, and a
        // Return there submits whatever is in the input bar — which is the exact failure
        // `inject`'s own comment describes from the other side.
        guard statuses[id]?.activity == .waiting else { return .notWaiting }
        guard let injector = injector(for: id) else { return .unreadableScreen }
        // The same set both other users of this terminal hold, so a rename or a queued phone
        // prompt mid-settle cannot interleave with a dialog being driven. See `injecting`.
        guard !injecting.contains(id) else { return .unreadableScreen }

        let labels = prompt.options.map(\.label)
        guard let viewport = injector.readViewport(),
              case .success(let current) = ChoiceDialog.locate(labels: labels, inViewport: viewport)
        else { return .unreadableScreen }

        remember(answered: token, for: id)
        injecting.insert(id)
        // Nothing moves? Then nothing needs a settle either — but the confirm read still runs,
        // because "the marker is where I think it is" is the claim being checked, and it can be
        // false with zero arrows if the screen changed between the two reads.
        let steps = index - current
        for _ in 0..<abs(steps) {
            if steps > 0 { injector.sendArrowDown() } else { injector.sendArrowUp() }
        }
        // Claude Code repaints asynchronously, exactly as it does for a kill — the same seam,
        // and the same 120ms in production.
        injectionSettle { [weak self] in
            defer { self?.injecting.remove(id) }
            // **Measured, not assumed.** `inject` kills first and compares because the screen
            // cannot be trusted to say whether the buffer was empty; this moves first and
            // compares because the screen cannot be trusted to say whether the keystroke
            // arrived. Same idiom, same reason, and the consequence of skipping it here is a
            // Return pressed on a row nobody chose.
            guard let confirmed = injector.readViewport(),
                  case .success(index) = ChoiceDialog.locate(
                      labels: labels, inViewport: confirmed
                  )
            else { return }
            injector.sendReturn()
        }
        return .dispatched
    }

    /// Files an answered token against a tab, oldest evicted first. A twin of `remember(_:for:)`
    /// rather than a shared helper, because the two lists must not collide: a prompt's token
    /// and an answer's token are minted by different taps and a shared list would let one
    /// silence the other.
    private func remember(answered token: UUID, for id: UUID) {
        var tokens = answeredPromptTokens[id, default: []]
        tokens.append(token)
        if tokens.count > Self.maxRememberedPromptTokens {
            tokens.removeFirst(tokens.count - Self.maxRememberedPromptTokens)
        }
        answeredPromptTokens[id] = tokens
    }
```

In `closeSession`, beside the existing `promptQueue.removeValue(forKey: id)` at ~line 2113, add `answeredPromptTokens.removeValue(forKey: id)`.

Add the test seam beside `flushPendingResumePromptsForTesting`:

```swift
    /// Marks a tab as mid-injection, so a test can assert that the shared gate refuses a
    /// second driver. There is no production caller and there must not be one.
    func holdInjectionForTesting(_ id: UUID) { injecting.insert(id) }
```

- [ ] **Step 5: Add `ignoreArrowsAfter` to `SpyInjector`**

```swift
    /// After this many arrows, stop moving the marker while still recording the event —
    /// a TUI that ignored a keystroke, repainted late, or was never the list we thought.
    /// `nil` moves for every arrow.
    var ignoreArrowsAfter: Int?
    private var arrowsSeen = 0
```

and gate the two movers on `arrowsSeen < (ignoreArrowsAfter ?? .max)`, incrementing `arrowsSeen` in both.

- [ ] **Step 6: Run the tests and verify they pass** — baseline + 59 cumulative.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In the settle closure, delete the `guard let confirmed … else { return }` and call `sendReturn()` unconditionally | `testReturnIsNotPressedWhenTheMarkerDidNotLandOnTheChosenRow`. **Do not delete only the `guard`'s body** — `guard` requires an `else` that exits, so a body-only deletion will not compile; delete the whole statement |
| Move the `statuses[id]?.activity == .waiting` check above the agent check | `testACodexTabIsRefusedBeforeItsStatusIsConsulted` — that fixture is a codex tab that IS waiting, which is the only fixture that distinguishes the order |
| Change `.waiting` to `!= .shell` | `testAnIdleSessionIsRefused` |
| Delete `if answeredPromptTokens[…].contains(token) { return .duplicate }` | `testTheSameTokenTwiceAnswersOnce` — **and check the count assertion, not just the return value**: a mutant that returned `.dispatched` but typed nothing would pass a value-only assertion |
| Send `steps` arrows without `abs()` (i.e. `for _ in 0..<steps`) | `testChoosingARowAboveSendsUpArrows` — a negative range traps, which is a failure, and record it as one rather than "the test crashed" |
| Delete `guard !injecting.contains(id)` | `testATabAlreadyInjectingIsRefused` |
| Delete `guard prompt.options.indices.contains(index)` | `testAnIndexOutsideTheOptionsIsRefused` — **check this**: `ChoiceDialog.locate` would still succeed and the arrow loop would run `7 - 0` times, so the mutant sends arrows and the `spy.events.isEmpty` assertion fails. Good |

- [ ] **Step 8: Verify** — full four scripts. Every existing `PhonePromptDispatchTests` and rename test must be untouched.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AnswerPromptTests.swift \
        Tests/FlightDeckTests/SpyInjector.swift
git commit -m "feat: answer a dialog by driving the terminal, and refuse when the screen disagrees"
```

---

## Task 8: `PromptService` — compose, cache, answer

**Files:**
- Create: `Sources/FlightDeck/Fleet/PromptService.swift`
- Test: `Tests/FlightDeckTests/PromptServiceTests.swift`

**Interfaces:**
- Consumes: `SessionStore.timelineSource(of:)`, `SessionStore.status(for:)`, `SessionStore.viewport(of:)`, `SessionStore.answerPrompt(_:choosing:token:)`, `TranscriptPager.page(url:anchor:limit:)`, `ClaudePendingQuestion.find(in:session:)`, `ChoiceDialog.read(fromViewport:)`, `PendingPrompt.permission(session:question:labels:)`
- Produces:
  - `@MainActor final class PromptService`
  - `init(store: SessionStore)`
  - `var tail: @Sendable (URL, Int) -> [SourceLine]` (test seam)
  - `func pending(session: UUID) async -> Result<PendingPrompt?, TimelineErrorCode>`
  - `func answer(session: UUID, prompt: String, index: Int, label: String, token: UUID) -> Result<Void, TimelineErrorCode>`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptServiceTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// The one type that knows a store, a transcript and a screen — in the same spirit as
/// `TimelineService` being the only type that knows a store and a reader.
///
/// Two properties are worth more than the rest and are what most of this file is about: the
/// answer path does **no file I/O**, and it will not answer a question the Mac did not itself
/// serve.
@MainActor
final class PromptServiceTests: XCTestCase {

    func testAWaitingClaudeSessionWithAnOpenAskReturnsTheQuestion() async throws {
        let (service, store, id) = makeService(activity: .waiting, waitingFor: "input needed")
        service.tail = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        let prompt = try XCTUnwrap(try await service.pending(session: id).get())
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.id, "toolu_01TAgqjgnNES8BUtNAenrPnB")
    }

    /// The common case, and it must be a success rather than an error — every activity change
    /// on the phone asks this question.
    func testAnIdleSessionHasNoPendingPromptAndThatIsNotAnError() async throws {
        let (service, _, id) = makeService(activity: .idle)
        let result = await service.pending(session: id)
        XCTAssertEqual(try result.get(), nil)
    }

    /// **The transcript is consulted first and the screen is the fallback**, because the
    /// transcript is exact and the screen is inferred. This fixture has BOTH — an open
    /// `AskUserQuestion` in the tail and a numbered dialog on screen with different labels —
    /// and asserts the transcript won.
    func testTheTranscriptWinsOverTheScreenWhenBothDescribeAQuestion() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        store.injectorOverrideForTesting?.showOptions(["Screen A", "Screen B"], selected: 0)
        let prompt = try XCTUnwrap(try await service.pending(session: id).get())
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.options.map(\.label).first, "Playing jazz piano")
    }

    func testAWaitingSessionWithNoOpenAskFallsBackToTheScreen() async throws {
        let (service, store, id) = makeService(activity: .waiting, waitingFor: "permission prompt")
        service.tail = { _, _ in [] }
        store.injectorOverrideForTesting?.showOptions(
            ["Yes", "Yes, and don't ask again", "No"], selected: 0
        )
        let prompt = try XCTUnwrap(try await service.pending(session: id).get())
        XCTAssertEqual(prompt.kind, .permission)
        XCTAssertEqual(prompt.options.map(\.label), ["Yes", "Yes, and don't ask again", "No"])
        XCTAssertTrue(prompt.id.hasPrefix("screen:"))
    }

    /// Waiting, and neither source can say why. `nil` and not an error: the phone renders "your
    /// Mac is waiting for you" from `waitingFor`, which it already has, and offers no buttons.
    func testAWaitingSessionNeitherSourceUnderstandsIsNoPromptRatherThanAFailure() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [] }
        store.injectorOverrideForTesting?.viewportIsReadable = false
        XCTAssertEqual(try await service.pending(session: id).get(), nil)
    }

    func testAnUnknownSessionFails() async {
        let (service, _, _) = makeService(activity: .waiting)
        let result = await service.pending(session: UUID())
        XCTAssertEqual(result, .failure("unknown_session"))
    }

    // MARK: The answer path

    /// **No file is read on this path, and this is the test that says so.** The answer runs
    /// inside a synchronous `onCommand`, so a transcript read here would be main-thread file
    /// I/O on the Mac's UI in the middle of an agent producing output — the exact stall
    /// `TimelineService` takes its own read off the main actor to avoid.
    func testAnsweringReadsNoFile() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        var reads = 0
        service.tail = { _, _ in reads += 1; return [SourceLine(offset: 0, text: askUserQuestionLine)] }
        _ = await service.pending(session: id)
        XCTAssertEqual(reads, 1)
        store.injectorOverrideForTesting?.showOptions(
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"],
            selected: 0
        )
        _ = service.answer(
            session: id, prompt: "toolu_01TAgqjgnNES8BUtNAenrPnB",
            index: 1, label: "Speaking 10 languages", token: UUID()
        )
        XCTAssertEqual(reads, 1, "the answer path must not read the transcript")
    }

    /// **Racing the Mac.** The phone answers a question the Mac has moved past. Nothing is
    /// typed and the phone is told to refetch.
    func testAnswerToAPromptTheMacHasMovedPastIsRefused() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        _ = await service.pending(session: id)
        XCTAssertEqual(
            service.answer(session: id, prompt: "toolu_SOMETHING_ELSE", index: 0,
                           label: "Playing jazz piano", token: UUID()),
            .failure("prompt_changed")
        )
        XCTAssertTrue(store.injectorOverrideForTesting?.events.isEmpty == true)
    }

    /// The label is a cross-check, not an instruction. A phone whose card was built from an
    /// older serve names the right index and the wrong words, and that is a mismatch worth
    /// refusing — its reader is looking at something else.
    func testAnAnswerWhoseLabelDisagreesWithTheServedOptionIsRefused() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        _ = await service.pending(session: id)
        XCTAssertEqual(
            service.answer(session: id, prompt: "toolu_01TAgqjgnNES8BUtNAenrPnB",
                           index: 0, label: "Something the Mac never drew", token: UUID()),
            .failure("prompt_changed")
        )
    }

    /// A phone reconnecting to a Mac that restarted holds a prompt id nothing here has served.
    /// Refetch, do not guess.
    func testAnAnswerForAPromptThisMacNeverServedIsRefused() {
        let (service, _, id) = makeService(activity: .waiting)
        XCTAssertEqual(
            service.answer(session: id, prompt: "toolu_A", index: 0, label: "x", token: UUID()),
            .failure("prompt_unknown")
        )
    }

    /// The served copy is dropped once it is answered, so a second tap on the same card cannot
    /// arrive as a fresh answer with a new token after the dialog is gone.
    func testAServedPromptIsForgottenOnceAnswered() async throws {
        let (service, store, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        _ = await service.pending(session: id)
        store.injectorOverrideForTesting?.showOptions(
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"],
            selected: 0
        )
        _ = service.answer(session: id, prompt: "toolu_01TAgqjgnNES8BUtNAenrPnB",
                           index: 1, label: "Speaking 10 languages", token: UUID())
        XCTAssertEqual(
            service.answer(session: id, prompt: "toolu_01TAgqjgnNES8BUtNAenrPnB",
                           index: 1, label: "Speaking 10 languages", token: UUID()),
            .failure("prompt_unknown")
        )
    }
}
```

- [ ] **Step 2: Run and verify they fail** — `cannot find 'PromptService' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeck/Fleet/PromptService.swift`**

```swift
import FleetKit
import Foundation

/// Answers "what is this session blocked on", and carries out an answer to it.
///
/// The only type that knows a `SessionStore`, a transcript and a terminal screen — the same
/// role `TimelineService` plays for history, and split from it for the same reason it is split
/// from `SessionStore`: each of the three stays testable without the others, and the thing
/// that needs all three is here where it can be read at once.
///
/// **Two sources, and the order between them is a statement about trust.** The transcript is
/// consulted first because an `AskUserQuestion` is written into it exactly, with descriptions
/// and with the agent's own id; the screen is consulted only when the transcript has nothing,
/// because a permission dialog exists nowhere else and reading it is inference. A session that
/// is waiting and that neither source explains is `nil` — the phone still knows it is waiting,
/// from `waitingFor`, and simply offers no buttons.
///
/// **The read runs off the main actor and the answer does not**, and that asymmetry is
/// deliberate. `pending` parses transcript records, which is the work `TimelineService` takes
/// off the main thread because it stalls the Mac's own UI; `answer` runs inside
/// `FleetSocketServer`'s synchronous `onCommand` and must not do file I/O at all, which is why
/// it uses the copy `pending` already served. `served` is that copy.
@MainActor
final class PromptService {
    private let store: SessionStore

    /// The last `PendingPrompt` handed to a client, per tab.
    ///
    /// **This is what makes the answer path both safe and cheap.** Safe, because the labels
    /// the terminal driver matches come from here — the Mac's own reading — and never from the
    /// command; a phone contributes an index, not a button. Cheap, because it removes the only
    /// file read the answer path would otherwise need, inside a handler that runs on the main
    /// queue.
    ///
    /// One entry per tab, replaced on every serve, and dropped when an answer is dispatched:
    /// a card that has been answered must not be answerable again with a fresh token after the
    /// dialog is gone. Bounded by the number of open tabs, and cleared with the tab by
    /// `forget(_:)`.
    private var served: [UUID: PendingPrompt] = [:]

    /// Test seam, in the same shape and for the same reason as `TimelineService.reader`: the
    /// actor boundary in `pending` is worth asserting and no test can stand on both sides of
    /// it without a substitutable read. `@Sendable` and free of `self` — what crosses into the
    /// detached task is this function value and two values, never the service or the store.
    var tail: @Sendable (URL, Int) -> [SourceLine] = { url, limit in
        TranscriptPager.page(url: url, anchor: .latest, limit: limit)?.lines ?? []
    }

    /// How many records back to look for an unanswered call.
    ///
    /// **Small on purpose.** An open `AskUserQuestion` is always the LAST record — claude
    /// cannot proceed past an unanswered question — so one record would nearly always do. A
    /// handful is read anyway so that a `tool_result` for an *earlier* call is in the window
    /// and cannot make an already-answered question look open, which is the only way this can
    /// be wrong in the dangerous direction.
    static let tailRecords = 8

    init(store: SessionStore) {
        self.store = store
    }

    func pending(session: UUID) async -> Result<PendingPrompt?, TimelineErrorCode> {
        // Resolved once, up front. A tab closed while the read is in flight is the ordinary
        // case rather than an edge one — the same ruling `TimelineService.page` makes.
        let source = store.timelineSource(of: session)
        if case .unknownSession = source { return .failure("unknown_session") }
        // Not `waiting` means nothing is up. Checked before any read, because this is the
        // answer almost every time and it costs nothing.
        guard store.status(for: session)?.activity == .waiting else { return .success(nil) }

        if case .file(.claude, let url) = source {
            let tail = self.tail
            let records = Self.tailRecords
            let lines = await Task.detached(priority: .utility) { tail(url, records) }.value
            if let prompt = ClaudePendingQuestion.find(in: lines, session: session) {
                served[session] = prompt
                return .success(prompt)
            }
        }

        // The fallback, and the only source a permission dialog has. Main-actor and free —
        // `readViewport` returns ghostty's own accessibility cache.
        if let viewport = store.viewport(of: session),
           let dialog = ChoiceDialog.read(fromViewport: viewport) {
            let prompt = PendingPrompt.permission(
                session: session, question: dialog.question, labels: dialog.labels
            )
            served[session] = prompt
            return .success(prompt)
        }

        // Waiting, and neither source explains it. Not an error: `waitingFor` already tells the
        // phone that much, and a card with no buttons and an honest sentence beats a spinner.
        served[session] = nil
        return .success(nil)
    }

    /// Carry out an answer to a question this service served.
    ///
    /// Synchronous, no I/O, and it refuses three ways before anything is typed: a prompt this
    /// Mac is not holding (`prompt_unknown` — the phone should refetch), one whose id has moved
    /// (`prompt_changed` — someone answered in the terminal, or the agent moved on), and one
    /// whose label disagrees with what was served (`prompt_changed` too, because a phone
    /// showing different words is a reader looking at something else).
    func answer(
        session: UUID, prompt id: String, index: Int, label: String, token: UUID
    ) -> Result<Void, TimelineErrorCode> {
        guard let prompt = served[session] else { return .failure("prompt_unknown") }
        guard prompt.id == id else { return .failure("prompt_changed") }
        guard prompt.options.indices.contains(index),
              prompt.options[index].label == label
        else { return .failure("prompt_changed") }

        let outcome = store.answerPrompt(prompt, choosing: index, token: token)
        if let code = outcome.errorCode { return .failure(TimelineErrorCode(code)) }
        // Dropped on the way out: this card is spent. A later tap on it arrives as
        // `prompt_unknown` and the phone refetches, which is the right answer whether the
        // dialog is gone or a new one has replaced it.
        served[session] = nil
        return .success(())
    }

    /// Drops a tab's served prompt. Called when a session closes.
    func forget(_ session: UUID) { served.removeValue(forKey: session) }
}

extension TimelineErrorCode {
    /// A code built at runtime rather than written as a literal. `ExpressibleByStringLiteral`
    /// covers every call site in `TimelineService`; this covers the one place a code arrives
    /// from `AnswerDispatch` as a `String`.
    init(_ code: String) { self.init(stringLiteral: code) }
}
```

> `SessionStore.injectorOverrideForTesting` in the tests is `injectorOverride as? SpyInjector`; add a one-line internal computed property beside `injectorOverride` (`SessionStore.swift:2600`) if one does not already exist.

- [ ] **Step 4: Run the tests and verify they pass** — baseline + 69 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Consult the screen before the transcript | `testTheTranscriptWinsOverTheScreenWhenBothDescribeAQuestion` — that fixture is the only one with both |
| Delete `guard store.status(for: session)?.activity == .waiting` | `testAnIdleSessionHasNoPendingPromptAndThatIsNotAnError` — **check the fixture supplies a tail that WOULD find a question when idle**; if `service.tail` defaults to empty there, the mutation is a no-op, so set it explicitly in that test |
| In `answer`, drop `guard prompt.id == id` | `testAnswerToAPromptTheMacHasMovedPastIsRefused` |
| In `answer`, drop the `label ==` half of the index guard | `testAnAnswerWhoseLabelDisagreesWithTheServedOptionIsRefused` |
| In `answer`, delete `served[session] = nil` on success | `testAServedPromptIsForgottenOnceAnswered` |
| In `answer`, call `pending(session:)` first to refresh | `testAnsweringReadsNoFile` — **and it cannot compile as written** (`answer` is not `async`); that compile failure is itself the proof, and record it as one |
| Return `.failure("no_prompt")` instead of `.success(nil)` when neither source explains | `testAWaitingSessionNeitherSourceUnderstands…` |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Fleet/PromptService.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/PromptServiceTests.swift
git commit -m "feat: one place that knows the transcript, the screen and the store"
```

---

## Task 9: Wire it to a real socket

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (`prompts` property; the two placeholder arms from Task 2)
- Test: `Tests/FlightDeckTests/PromptLoopbackTests.swift`

**Interfaces:**
- Consumes: `PromptService` (Task 8), `FleetRequest.pendingPrompt`, `FleetCommand.answerPrompt`, `ServerFrame.prompt`
- Produces: nothing new; the two handlers become real.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/PromptLoopbackTests.swift`:

```swift
import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The whole path, over a real TLS-PSK socket on loopback: a phone asks what a session is
/// waiting for, gets the question, answers it, and the Mac's terminal moves.
///
/// The same shape as `PhonePromptLoopbackTests`, and it exists for the same reason: every
/// layer below is unit-tested against a fake, and this is the only test that would catch a
/// frame wired to the wrong handler.
@MainActor
final class PromptLoopbackTests: XCTestCase {
    func testAPhoneAsksWhatASessionIsWaitingForAndAnswersIt() async throws {
        let (service, store, spy, id) = try await makeLoopbackFleet(activity: .waiting)
        service.promptTailForTesting = { _, _ in [SourceLine(offset: 0, text: askUserQuestionLine)] }
        spy.showOptions(
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"],
            selected: 0
        )
        let client = try await connectLoopbackClient(to: service)

        let fetched = expectation(description: "fetched")
        var prompt: PendingPrompt?
        client.pendingPrompt(id) { result in
            prompt = try? result.get() ?? nil
            fetched.fulfill()
        }
        await fulfillment(of: [fetched], timeout: 10)
        let question = try XCTUnwrap(prompt)
        XCTAssertEqual(question.options[1].label, "Speaking 10 languages")

        let answered = expectation(description: "answered")
        client.send(.answerPrompt(
            id: id, token: UUID(), prompt: question.id, index: 1,
            label: "Speaking 10 languages"
        )) { result in
            XCTAssertNoThrow(try result.get())
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// An idle session, asked the same question. The frame comes back with nothing in it and
    /// the phone draws no card — the single most common exchange this feature will ever have.
    func testAnIdleSessionAnswersWithNoPromptRatherThanAnError() async throws {
        let (service, _, _, id) = try await makeLoopbackFleet(activity: .idle)
        let client = try await connectLoopbackClient(to: service)
        let fetched = expectation(description: "fetched")
        var outcome: Result<PendingPrompt?, FleetRequestError>?
        client.pendingPrompt(id) { outcome = $0; fetched.fulfill() }
        await fulfillment(of: [fetched], timeout: 10)
        XCTAssertEqual(try outcome?.get() ?? nil, nil)
    }

    func testAnAnswerToAPromptThatWasNeverServedComesBackAsAnError() async throws {
        let (service, _, spy, id) = try await makeLoopbackFleet(activity: .waiting)
        let client = try await connectLoopbackClient(to: service)
        let refused = expectation(description: "refused")
        var code: String?
        client.send(.answerPrompt(id: id, token: UUID(), prompt: "toolu_X", index: 0, label: "Yes")) {
            if case .failure(.server(let value)) = $0 { code = value }
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(code, "prompt_unknown")
        XCTAssertTrue(spy.events.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify it fails** — the `unhandled` placeholders answer `err`, so `testAPhoneAsks…` fails on the `XCTUnwrap`.

- [ ] **Step 3: Wire the handlers in `Sources/FlightDeck/Fleet/FleetService.swift`**

Add beside `timeline`:

```swift
    /// Answers "what is this blocked on", and carries out the answer. Held here rather than
    /// built per request for the reason `timeline` is: it holds the store, and it holds the
    /// per-tab record of what has been served — which is the thing that makes an answer safe,
    /// and which a per-request instance would throw away between the serve and the answer.
    private let prompts: PromptService
```

initialize it in `init` next to `self.timeline = TimelineService(store: store)`:

```swift
        self.prompts = PromptService(store: store)
```

Replace the Task 2 placeholder in `onRequest`:

```swift
            case .pendingPrompt(let session):
                // A `Task` for the same reason the timeline's is: composing this may read
                // transcript records, which `PromptService` hands to a detached task and
                // resumes here on the main actor — which is `queue`. `reply` is therefore
                // called on `queue`, as `onRequest` requires, and after an await, which is
                // exactly the case `FleetSocketServer`'s deferred-send guard is written for.
                //
                // Nothing here writes: the answer is composed from the transcript on disk and
                // from ghostty's own screen cache. No `FleetEvent`, no broadcast, and nothing
                // new for `FleetReplicator`'s drift check to guard.
                Task { @MainActor in
                    switch await self.prompts.pending(session: session) {
                    case .success(let prompt): reply(.prompt(cid: cid, prompt))
                    case .failure(let code): reply(.err(cid: cid, code: code.code))
                    }
                }
```

Replace the placeholder in `apply(_:cid:)`:

```swift
        case .answerPrompt(let id, let token, let prompt, let index, let label):
            // Every refusal is the service's and the store's to make, for the reason `.prompt`
            // states: they are the only things that know the tab's agent, its status, its
            // screen and what was served, and splitting the checks across two files is how
            // they drift. Synchronous, and it must stay synchronous — `onCommand` answers
            // inline, and `PromptService.answer` reads no file precisely so that it can.
            if case .failure(let code) = prompts.answer(
                session: id, prompt: prompt, index: index, label: label, token: token
            ) {
                return .err(cid: cid, code: code.code)
            }
```

Add a test seam beside the others:

```swift
    /// Test seam, forwarding to `PromptService.tail`. There is no production caller.
    var promptTailForTesting: (@Sendable (URL, Int) -> [SourceLine])? {
        get { nil }
        set { if let newValue { prompts.tail = newValue } }
    }
```

**And clear the served prompt when a tab closes.** In `SessionStore`, the close path already clears `promptQueue` and (from Task 7) `answeredPromptTokens`; `PromptService.served` is not reachable from there. Wire it in `wireHandlers()` instead, where `FleetService` already observes the store's events:

```swift
        replicator.onEvents = { [weak self] batch in
            for entry in batch {
                if case .sessionRemoved(let id) = entry.event { self?.prompts.forget(id) }
                self?.server.broadcast(.event(seq: entry.seq, entry.event))
            }
        }
```

- [ ] **Step 4: Run the tests and verify they pass** — baseline + 72 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Revert `onRequest`'s `.pendingPrompt` arm to `reply(.err(cid: cid, code: "unhandled"))` | `testAPhoneAsksWhatASessionIsWaitingForAndAnswersIt` and `testAnIdleSessionAnswersWithNoPrompt…` |
| Revert `apply`'s `.answerPrompt` arm to `return .err(cid: cid, code: "unhandled")` | `testAPhoneAsks…` (the answer expectation asserts no throw) |
| In `apply`'s arm, ignore the failure and always `ack` | `testAnAnswerToAPromptThatWasNeverServedComesBackAsAnError` |
| Build a fresh `PromptService()` per request instead of holding one | `testAPhoneAsks…` — the answer would find nothing served and refuse `prompt_unknown` |
| Delete the `sessionRemoved` → `forget` line | **No test fails.** Add one: serve a prompt, remove the session, assert `answer` returns `prompt_unknown`. Do not leave this row unproven |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/PromptLoopbackTests.swift
git commit -m "feat: a question and its answer over a real socket"
```

---

## Task 10: A historical question is a question, not a JSON blob

**Files:**
- Modify: `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift` (`assistantItem`'s `tool_use` arm, ~line 128)
- Test: `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`

**Interfaces:**
- Consumes: `ClaudePendingQuestion.toolName` (Task 4), `TimelineItem.Kind.prompt`
- Produces: an `AskUserQuestion` `tool_use` maps to `kind: .prompt` rather than `.toolCall`.

> This is half of what the user actually saw. An `AskUserQuestion` already in the conversation currently renders as a `.toolCall` — a JSON tree of `{"questions":[…]}` — which is the machine's view of a question a person answered. `TimelineStyle` has been holding a heading, a symbol and a colour for `.prompt` since the timeline shipped, unreached. This reaches it.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`:

```swift
    /// **`.prompt`, the case reserved for this since the timeline shipped.** Everything else
    /// about the row is a `.toolCall`'s — the tool name, the call id that pairs it with its
    /// result, the whole input in `text` — so a detail screen and the call/result folding both
    /// keep working. Only the KIND changes, which is what tells the phone to draw the question
    /// instead of the JSON.
    func testAnAskUserQuestionIsAPromptRatherThanAToolCall() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-08-21T04:30:59.425Z","message":{"role":\
        "assistant","content":[{"type":"tool_use","id":"toolu_A","name":"AskUserQuestion",\
        "input":{"questions":[{"question":"Which?","header":"H","multiSelect":false,\
        "options":[{"label":"a"},{"label":"b"}]}]}}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.kind, .prompt)
        XCTAssertEqual(item.body.tool, "AskUserQuestion")
        XCTAssertEqual(item.body.callID, "toolu_A")
        XCTAssertTrue(item.body.text.contains("\"question\""),
                      "the input still travels, so the phone can rebuild the question from it")
    }

    /// A one-line preview drawn from the question, not from `ToolInputSummary`'s key table —
    /// which has no entry that would find it and would leave the row saying nothing.
    func testAPromptRowPreviewsItsQuestion() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_A","name":"AskUserQuestion","input":{"questions":[{"question":\
        "Which skill?","options":[{"label":"a"}]}]}}]}}
        """
        let item = try XC
`Assert(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.body.summary, "Which skill?")
    }

    /// Every other tool is untouched. The fixture is a `Bash` call, because that is the row
    /// this rule would break if it were scoped by anything other than the tool's name.
    func testEveryOtherToolIsStillAToolCall() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_B","name":"Bash","input":{"command":"ls"}}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.body.summary, "ls")
    }

    /// The result of an `AskUserQuestion` stays a `.toolResult`, so `entries(from:)` still
    /// folds it into the prompt row on `callID`. Changing it too would leave the answer
    /// stranded as its own row below the question.
    func testTheAnswerToAQuestionIsStillAToolResult() throws {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"toolu_A","content":"Your questions have been answered: \\"Which?\\"=\\"a\\"."}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.body.callID, "toolu_A")
    }
```

- [ ] **Step 2: Run and verify they fail** — `XCTAssertEqual failed: ("toolCall") is not equal to ("prompt")`.

- [ ] **Step 3: Change `assistantItem`'s `tool_use` arm**

```swift
        case "tool_use":
            let input = block["input"] as? [String: Any]
            let tool = block["name"] as? String
            // **The one tool whose call is a question rather than a command**, and the one
            // place `TimelineItem.Kind.prompt` is emitted. Everything else about the row is
            // unchanged — same tool name, same `callID` so `entries(from:)` still folds the
            // answer into it, same whole input in `text` so the phone can rebuild the
            // question from it with the same parser the live card uses. Only the kind moves,
            // and the kind is what stops a question a person answered from rendering as a
            // JSON tree of `{"questions":[…]}`.
            let isQuestion = tool == ClaudePendingQuestion.toolName
            return TimelineItem(
                id: id, kind: isQuestion ? .prompt : .toolCall, status: .complete,
                body: TimelineItem.Body(
                    text: ToolInputSummary.pretty(input),
                    // `ToolInputSummary`'s key table has no entry that would find a question
                    // — it lives two levels down, inside `questions[0]` — so a prompt row
                    // would preview as nothing at all. Bounded by the same `preview(of:)`,
                    // which is the ONLY bound `summary` gets anywhere.
                    summary: isQuestion
                        ? questionPreview(input) ?? input.flatMap(ToolInputSummary.text(for:))
                        : input.flatMap(ToolInputSummary.text(for:)),
                    tool: tool,
                    callID: block["id"] as? String
                ),
                at: at
            )
```

and beside it:

```swift
    /// The first question's text, for a row preview. Nil for any shape that is not the one
    /// `AskUserQuestion` writes, which falls back to the ordinary key table.
    private static func questionPreview(_ input: [String: Any]?) -> String? {
        guard let questions = input?["questions"] as? [[String: Any]],
              let text = questions.first?["question"] as? String
        else { return nil }
        return ToolInputSummary.preview(of: text)
    }
```

- [ ] **Step 4: Run and verify they pass.** Existing mapper tests must be unchanged — check `TimelineStyleTests` too, which switches exhaustively on `Kind` and already has a `.prompt` arm.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Set `isQuestion` from `tool != nil` instead of the name comparison | `testEveryOtherToolIsStillAToolCall` |
| Delete the `summary:` ternary, using `ToolInputSummary.text(for:)` for both | `testAPromptRowPreviewsItsQuestion` — verify the fixture's input has **no** `command`/`file_path`/`prompt`/`description` key, or the key table would find one and the mutation would be a no-op. It does not |
| Also map `tool_result` to `.prompt` when its call was one | Not reachable from `userItem`, which has no tool name — **skip this row**; the pairing is asserted by `testTheAnswerToAQuestionIsStillAToolResult` against the unmutated code, which is weaker and is worth saying so in the report |
| In `questionPreview`, return the raw `text` without `preview(of:)` | **No test fails.** Add one with a 400-character question asserting `summary!.utf8.count <= ToolInputSummary.maxSummaryBytes` before relying on this row — that cap is the only bound `summary` has |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift \
        Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift
git commit -m "feat: a question in the conversation reads as a question"
```

---

## Task 11: The phone asks, waits, and answers

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift`
- Modify: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` (`StubPager`)
- Modify: `Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift` (same stub)
- Test: `Tests/FlightDeckMobileTests/SessionTimelinePendingTests.swift`

**Interfaces:**
- Consumes: `FleetConnector.pendingPrompt(_:then:)` (Task 3), `FleetCommand.answerPrompt` (Task 2), `PendingPrompt` (Task 1)
- Produces:
  - `@MainActor protocol PromptAnswering: AnyObject { func pendingPrompt(_ session: UUID, then: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void); func answerPrompt(_ command: FleetCommand, then: @escaping (Result<Void, FleetRequestError>) -> Void) }`
  - `enum SessionTimelineModel.Pending: Equatable { case none, asking(PendingPrompt), sent(PendingPrompt), failed(PendingPrompt, String) }`
  - `SessionTimelineModel.pending: Pending` (private(set))
  - `func SessionTimelineModel.refreshPending()`, `func SessionTimelineModel.answer(_ index: Int)`
  - `SessionTimelineModel.init(sessionID:fleet: any TimelinePaging & PromptSending & PromptAnswering, timeout:)`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckMobileTests/SessionTimelinePendingTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The live card's state machine. Four states, and the two that are not obvious are the
/// interesting ones: a question that has been answered but not yet confirmed by the Mac, and
/// one whose answer was never confirmed at all.
@MainActor
final class SessionTimelinePendingTests: XCTestCase {
    private let session = UUID()

    private func question(_ id: String = "toolu_A") -> PendingPrompt {
        PendingPrompt(
            id: id, kind: .question, session: session, header: "Pick",
            question: "Which?", options: [.init(label: "Yes"), .init(label: "No")]
        )
    }

    func testAFetchThatFindsAQuestionShowsIt() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        XCTAssertEqual(model.pending, .asking(question()))
    }

    func testAFetchThatFindsNothingClearsTheCard() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.refreshPending()
        stub.answerPending(.success(nil))
        XCTAssertEqual(model.pending, .none)
    }

    /// **The Mac answered first.** A different question arrives; the card must become that
    /// one rather than keeping a stale `sent`/`failed` state hanging off the old id.
    func testADifferentQuestionReplacesTheCardWhole() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question("toolu_OLD")))
        model.answer(0)
        stub.answerAnswer(.success(()))
        XCTAssertEqual(model.pending, .sent(question("toolu_OLD")))
        model.refreshPending()
        stub.answerPending(.success(question("toolu_NEW")))
        XCTAssertEqual(model.pending, .asking(question("toolu_NEW")))
    }

    /// A failed fetch is quiet: it must not replace a card the reader is looking at, and it
    /// must not put an error where a conversation is. The connection banner on the list
    /// already says the phone is offline.
    func testAFailedFetchLeavesTheCardAlone() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.refreshPending()
        stub.answerPending(.failure(.disconnected))
        XCTAssertEqual(model.pending, .asking(question()))
    }

    func testTappingAnOptionSendsAnAnswerNamingItByIndexAndLabel() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.answer(1)
        guard case .answerPrompt(let id, _, let prompt, let index, let label)? = stub.sent
        else { return XCTFail("expected an answer command") }
        XCTAssertEqual(id, session)
        XCTAssertEqual(prompt, "toolu_A")
        XCTAssertEqual(index, 1)
        XCTAssertEqual(label, "No")
    }

    /// One in flight at a time. A second tap before the first ack must not become two answers.
    func testASecondTapWhileOneIsInFlightSendsNothing() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.answer(0)
        stub.sent = nil
        model.answer(1)
        XCTAssertNil(stub.sent)
    }

    func testAnAckLeavesTheCardSayingItWasSent() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.answer(0)
        stub.answerAnswer(.success(()))
        XCTAssertEqual(model.pending, .sent(question()))
    }

    func testARefusalIsShownOnTheCardWithTheOptionsStillThere() {
        let (model, stub) = makeModel()
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.answer(0)
        stub.answerAnswer(.failure(.server(code: "prompt_changed")))
        XCTAssertEqual(
            model.pending,
            .failed(question(), SessionTimelineModel.answerMessage(for: .server(code: "prompt_changed")))
        )
    }

    /// **The silent failure this deadline exists for.** `ack` means dispatched, and the Mac's
    /// driver refuses to press Return on a screen it cannot confirm — so a dispatched answer
    /// that never landed produces no frame at all. A half-open socket produces none either.
    /// Without this the card sits saying "sent" forever.
    func testAnAnswerNobodyConfirmsBecomesAFailureOnTheDeadline() async {
        let (model, stub) = makeModel(timeout: .milliseconds(20))
        model.refreshPending()
        stub.answerPending(.success(question()))
        model.answer(0)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            model.pending, .failed(question(), SessionTimelineModel.noAnswerConfirmation)
        )
    }

    /// Deliberately not "try again". A retry after a timeout is the one action that can press
    /// Return twice — the same ruling `noConfirmation` makes for a typed message.
    func testTheUnconfirmedCopyDoesNotInviteARetry() {
        XCTAssertFalse(SessionTimelineModel.noAnswerConfirmation.lowercased().contains("again"))
    }

    func testAnUnanswerableQuestionIsShownAndOffersNothingToTap() {
        let (model, stub) = makeModel()
        var multi = question()
        multi.unanswerable = PendingPrompt.multiSelectReason
        model.refreshPending()
        stub.answerPending(.success(multi))
        model.answer(0)
        XCTAssertNil(stub.sent, "an unanswerable card sends nothing even if a tap reaches it")
    }
}
```

`StubPager` in both existing mobile test files gains:

```swift
    var sent: FleetCommand?
    private var pendingCompletion: ((Result<PendingPrompt?, FleetRequestError>) -> Void)?
    private var answerCompletion: ((Result<Void, FleetRequestError>) -> Void)?

    func pendingPrompt(
        _ session: UUID, then completion: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void
    ) { pendingCompletion = completion }

    func answerPrompt(
        _ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) { sent = command; answerCompletion = completion }

    /// Held rather than answered, so a test can assert what happens WHILE one is outstanding —
    /// which is where a second tap and a deadline both live. Same reason the existing stub
    /// holds its page completion.
    func answerPending(_ result: Result<PendingPrompt?, FleetRequestError>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    func answerAnswer(_ result: Result<Void, FleetRequestError>) {
        let completion = answerCompletion
        answerCompletion = nil
        completion?(result)
    }
```

- [ ] **Step 2: Run and verify they fail** — `./scripts/test-ios.sh`; expect `type 'StubPager' does not conform to protocol 'PromptAnswering'` once Step 3 lands, and before it, `cannot find 'PromptAnswering'`.

- [ ] **Step 3: Add `PromptAnswering` and the state to `SessionTimelineModel.swift`**

After `PromptSending`:

```swift
/// The third verb a session screen needs: what is this session blocked on, and here is an
/// answer to it.
///
/// A third protocol rather than a third method on either existing one, for the reason there
/// are two already: a stub must be able to leave one verb outstanding while answering another,
/// and the transitions worth asserting here — an answer nobody confirms, a question that
/// changes under a card — are exactly the ones no real link produces on demand.
@MainActor
protocol PromptAnswering: AnyObject {
    func pendingPrompt(
        _ session: UUID,
        then completion: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void
    )

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}
```

In the model:

```swift
    /// What the card at the foot of the conversation is showing.
    ///
    /// **Four states, and collapsing any two of them lies.** "Nothing is waiting" and "the Mac
    /// did not answer" are the same absent card and different facts — the second must not
    /// silently hide a question. "Asked" and "answered, not yet confirmed" are the same
    /// question and different affordances: the second must not offer buttons, because tapping
    /// twice presses Return twice.
    enum Pending: Equatable {
        case none
        /// A live question with its buttons.
        case asking(PendingPrompt)
        /// An answer is dispatched. The Mac acked, which means *dispatched, not done* — the
        /// confirmation is the session leaving `waiting`, which arrives on the fleet stream and
        /// clears this card through the next `refreshPending`.
        case sent(PendingPrompt)
        /// The Mac refused, or nobody confirmed. The question stays visible with the reason
        /// under it, because the reader has to be able to see what they were being asked.
        case failed(PendingPrompt, String)
    }

    private(set) var pending = Pending.none

    @ObservationIgnored private var pendingInFlight = false
    @ObservationIgnored private var answerInFlight: UUID?
    @ObservationIgnored private var answerDeadline: Task<Void, Never>?
```

```swift
    /// Ask what this session is blocked on.
    ///
    /// **Called from the same two triggers `loadNewer` has** — an `activity` change and the
    /// busy poll — and that is the whole liveness story. `activityChanged` is pushed by the Mac
    /// on every genuine transition, so a question appearing takes one event, and a question
    /// answered in the terminal takes one more. No new frame, no timer of its own.
    ///
    /// **Quiet on failure.** A fetch that fails leaves whatever is on screen alone: the
    /// connection banner on the list already says the phone is offline, and replacing a live
    /// question with an error is worse than showing one a second late.
    func refreshPending() {
        guard !pendingInFlight else { return }
        pendingInFlight = true
        fleet.pendingPrompt(sessionID) { [weak self] result in
            guard let self else { return }
            self.pendingInFlight = false
            guard case .success(let prompt) = result else { return }
            self.adopt(prompt)
        }
    }

    /// Fold a fetched answer into the card.
    ///
    /// **Identity decides, not presence.** The same question arriving again must not reset a
    /// `sent` card to `asking` — the Mac has not confirmed anything yet, and re-offering the
    /// buttons is how a reader presses Return twice. A *different* id replaces the card whole,
    /// which is the case where someone answered on the Mac and the agent asked the next thing.
    private func adopt(_ prompt: PendingPrompt?) {
        guard let prompt else {
            answerDeadline?.cancel()
            answerDeadline = nil
            answerInFlight = nil
            pending = .none
            return
        }
        if current?.id == prompt.id { return }
        answerDeadline?.cancel()
        answerDeadline = nil
        answerInFlight = nil
        pending = .asking(prompt)
    }

    private var current: PendingPrompt? {
        switch pending {
        case .none: return nil
        case .asking(let p), .sent(let p), .failed(let p, _): return p
        }
    }

    /// Answer the live question by choosing option `index`.
    ///
    /// Refuses three ways before anything goes on the wire, and each is a state the card can
    /// genuinely be in when a finger lands: nothing is asked, one answer is already in flight,
    /// or the shape is one the Mac said it will not drive. The Mac re-checks all three
    /// regardless — a client is not trusted to have checked anything — and this is the
    /// difference between a dead button and a round trip that comes back with an error.
    func answer(_ index: Int) {
        guard case .asking(let prompt) = pending else { return }
        guard answerInFlight == nil, prompt.isAnswerable,
              prompt.options.indices.contains(index)
        else { return }

        let token = UUID()
        answerInFlight = token
        pending = .sent(prompt)

        // Armed BEFORE the send, because the send can complete before it returns:
        // `FleetConnector.send(_:then:)` answers `.disconnected` synchronously by design, the
        // same asymmetry `fetch` and `send(_:)` both arm ahead of.
        let timeout = self.timeout
        answerDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.claimAnswer(token) else { return }
            self.pending = .failed(prompt, Self.noAnswerConfirmation)
        }

        fleet.answerPrompt(.answerPrompt(
            id: sessionID, token: token, prompt: prompt.id,
            index: index, label: prompt.options[index].label
        )) { [weak self] result in
            guard let self, self.claimAnswer(token) else { return }
            switch result {
            case .success:
                // Stays `.sent`. `ack` means dispatched, and the Mac's driver deliberately
                // refuses to press Return on a screen it cannot confirm — so "acked" is not
                // "answered". What clears this card is the session leaving `waiting`, which
                // arrives on the fleet stream and reaches `adopt` through `refreshPending`.
                self.refreshPending()
            case .failure(let error):
                self.pending = .failed(prompt, Self.answerMessage(for: error))
            }
        }
    }

    /// Whichever of the ack and the deadline gets here first wins; the loser finds nothing
    /// filed and does nothing. The same rule, and the same reason, as `claim(_:)`.
    private func claimAnswer(_ token: UUID) -> Bool {
        guard answerInFlight == token else { return false }
        answerInFlight = nil
        answerDeadline?.cancel()
        answerDeadline = nil
        return true
    }

    /// Deliberately not "try again": a retry after a timeout is the one action that can press
    /// Return twice in a live terminal. Same ruling, same wording discipline, as
    /// `noConfirmation`.
    static let noAnswerConfirmation =
        "Your Mac didn't confirm this. Check the terminal before answering again."

    /// Copy for an answer that did not land. **Deliberately not `promptMessage(for:)`** — the
    /// same wire code means a different thing on this channel: `not_running` on a typed message
    /// is "there is no agent", and here it does not arise at all, while `prompt_changed` has no
    /// meaning on that one.
    static func answerMessage(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac, so this wasn't sent."
        case .server(let code):
            switch code {
            case "prompt_changed", "prompt_unknown":
                return "Your Mac has moved on from this question."
            case "not_waiting":
                return "Your Mac isn't waiting on anything right now."
            case "unreadable_screen":
                return "Flight Deck couldn't read your Mac's screen. Try again in a moment."
            case "unanswerable":
                return "This one has to be answered on your Mac."
            case "unsupported_agent":
                return "Flight Deck can only answer a Claude session from here."
            case "unknown_session":
                return "This session is no longer open on your Mac."
            default:
                return "Your Mac wouldn't answer this (\(code))."
            }
        }
    }
```

Widen the initializer and the stored property to `any TimelinePaging & PromptSending & PromptAnswering`.

In `FleetModel.swift`, add `PromptAnswering` to the conformance list and:

```swift
    /// Ask what a session is blocked on, and answer it. Forwarded rather than absorbed,
    /// exactly as `timelinePage` and `sendPrompt` are, and for the same reason: the connector
    /// answers **exactly once**, including with `.disconnected`, and a layer here that could
    /// swallow that would leave a card spinning beside a conversation the reader can use.
    func pendingPrompt(
        _ session: UUID,
        then completion: @escaping (Result<PendingPrompt?, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.pendingPrompt(session, then: completion)
    }

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }
```

- [ ] **Step 4: Run and verify they pass** — `./scripts/test-ios.sh`, iOS baseline + 11.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `adopt`, delete `if current?.id == prompt.id { return }` | `testADifferentQuestionReplacesTheCardWhole` — **check it**: that test asserts `.sent` survives a re-serve of the OLD id, then `.asking` on the NEW one, so a mutant that always replaces fails the first assertion. If the test only asserted the second, it would pass; keep both |
| In `refreshPending`'s completion, adopt on `.failure` too (`self.adopt(nil)`) | `testAFailedFetchLeavesTheCardAlone` |
| In `answer`, drop `guard answerInFlight == nil` | `testASecondTapWhileOneIsInFlightSendsNothing` |
| In `answer`, set `pending = .asking(prompt)` after the send instead of `.sent` | `testAnAckLeavesTheCardSayingItWasSent` |
| Arm `answerDeadline` *after* `fleet.answerPrompt(...)` | **No test fails with this stub**, because it holds the completion rather than answering synchronously. Record that; the asymmetry is documented on `FleetConnector.send(_:then:)` and covered by `FleetConnectorPromptTests` instead |
| Delete the whole `answerDeadline` task | `testAnAnswerNobodyConfirmsBecomesAFailureOnTheDeadline` |
| In `answer`, drop `prompt.isAnswerable` | `testAnUnanswerableQuestionIsShownAndOffersNothingToTap` |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeckMobile/SessionTimelineModel.swift Sources/FlightDeckMobile/FleetModel.swift \
        Tests/FlightDeckMobileTests/
git commit -m "feat: the phone holds a live question and one answer at a time"
```

---

## Task 12: The box

**Files:**
- Create: `Sources/FlightDeckMobile/PromptCard.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `Sources/FlightDeckMobile/TimelineRow.swift` (one arm)
- Test: `Tests/FlightDeckMobileTests/PromptCardTests.swift`

**Interfaces:**
- Consumes: `SessionTimelineModel.Pending`, `PendingPrompt`, `PendingPrompt.question(session:callID:toolInput:)`
- Produces: `struct PromptCard: View`; `static func PromptCard.footnote(for:) -> String?`; `static func PromptCard.showsOptions(for:) -> Bool`; `struct HistoricalPromptBody: View`

> **`TimelineRow.swift` is being edited by another agent.** Re-read it immediately before this step. The change to it is exactly one arm in the `switch item.kind` at ~line 124 and nothing else. If the file has moved on, merge into what is there; do not paste over it.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckMobileTests/PromptCardTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The card's decisions, extracted from the view so they can be asserted without a render —
/// the same shape `PromptComposerTests` uses, and for the same reason: a `View` has no
/// testable surface and the interesting rules here are about what is offered to a finger.
@MainActor
final class PromptCardTests: XCTestCase {
    private func question(unanswerable: String? = nil) -> PendingPrompt {
        PendingPrompt(
            id: "toolu_A", kind: .question, session: UUID(), header: "Pick",
            question: "Which?", options: [.init(label: "Yes"), .init(label: "No")],
            unanswerable: unanswerable
        )
    }

    /// **Buttons in exactly one state.** `sent` must not offer them — tapping twice presses
    /// Return twice — and `failed` must not either, because the reason a phone-side retry is
    /// refused is that a Return may already be on its way.
    func testOptionsAreOfferedOnlyWhileTheQuestionIsUnanswered() {
        XCTAssertTrue(PromptCard.showsOptions(for: .asking(question())))
        XCTAssertFalse(PromptCard.showsOptions(for: .sent(question())))
        XCTAssertFalse(PromptCard.showsOptions(for: .failed(question(), "nope")))
        XCTAssertFalse(PromptCard.showsOptions(for: .none))
    }

    func testAnUnanswerableQuestionShowsItsReasonAndNoOptions() {
        let pending = SessionTimelineModel.Pending.asking(
            question(unanswerable: PendingPrompt.multiSelectReason)
        )
        XCTAssertFalse(PromptCard.showsOptions(for: pending))
        XCTAssertEqual(PromptCard.footnote(for: pending), PendingPrompt.multiSelectReason)
    }

    func testASentAnswerSaysSoRatherThanSayingNothing() {
        XCTAssertEqual(PromptCard.footnote(for: .sent(question())), PromptCard.sentFootnote)
    }

    func testAFailureShowsTheMacsOwnReason() {
        XCTAssertEqual(
            PromptCard.footnote(for: .failed(question(), "Your Mac has moved on.")),
            "Your Mac has moved on."
        )
    }

    func testAnAskedQuestionHasNoFootnote() {
        XCTAssertNil(PromptCard.footnote(for: .asking(question())))
    }

    /// A historical row rebuilds its question from the body the mapper carried, with the same
    /// parser the live card uses. A body the parser refuses — a truncated one — falls back to
    /// the raw text rather than showing nothing.
    func testAHistoricalRowRebuildsItsQuestionFromTheBody() throws {
        let body = """
        {"questions":[{"question":"Which?","header":"H","options":[{"label":"a"}]}]}
        """
        let rebuilt = try XCTUnwrap(
            PendingPrompt.question(session: UUID(), callID: "toolu_A", toolInput: body)
        )
        XCTAssertEqual(rebuilt.question, "Which?")
    }
}
```

- [ ] **Step 2: Run and verify they fail** — `cannot find 'PromptCard' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeckMobile/PromptCard.swift`**

```swift
import FleetKit
import SwiftUI

/// The live question, at the foot of the conversation.
///
/// **Above the composer and inside the safe-area inset, not a row in the `List`.** The list is
/// the conversation, every row of which is a record the agent has written; a question the
/// agent is *currently blocked on* is not a record, it is a state — and it must not scroll
/// away from the finger that has to answer it. Same placement decision, and the same reasoning,
/// as `PromptComposer`'s outbox rows.
///
/// **Nothing here is monospaced.** The screen's rule reserves monospace for machine text
/// (`TimelineRow`), and a question written for a person to read is prose. The option labels
/// are prose too, and they are frequently a sentence — the descriptions in a real
/// `AskUserQuestion` run to a line and a half.
struct PromptCard: View {
    let pending: SessionTimelineModel.Pending
    let model: SessionTimelineModel

    /// Whether a finger can change anything.
    ///
    /// One state only. `sent` withholds them because `ack` means *dispatched* and the Mac may
    /// already have pressed Return; `failed` withholds them for the same reason, which is why
    /// there is no Retry on this card at all — the same ruling `noConfirmation` makes for a
    /// typed message, and here the stakes are a permission grant rather than a duplicate
    /// sentence. What clears a stuck card is the Mac: the session leaves `waiting`, the fetch
    /// returns a different question or none, and the card follows.
    static func showsOptions(for pending: SessionTimelineModel.Pending) -> Bool {
        guard case .asking(let prompt) = pending else { return false }
        return prompt.isAnswerable
    }

    /// The sentence under the question, or nil.
    static func footnote(for pending: SessionTimelineModel.Pending) -> String? {
        switch pending {
        case .none:
            return nil
        case .asking(let prompt):
            // A shape this Mac will not drive says so in the Mac's own words, so a newer Mac
            // that learns to drive one simply stops sending the sentence.
            return prompt.unanswerable
        case .sent:
            return sentFootnote
        case .failed(_, let reason):
            return reason
        }
    }

    static let sentFootnote = "Sent to your Mac."

    var body: some View {
        guard case .none = pending else { return AnyView(card) }
        return AnyView(EmptyView())
    }

    @ViewBuilder
    private var card: some View {
        if let prompt = Self.prompt(of: pending) {
            VStack(alignment: .leading, spacing: 10) {
                if let header = prompt.header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(prompt.question).font(.callout.weight(.medium))

                if Self.showsOptions(for: pending) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        Button { model.answer(index) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.footnote.weight(.medium))
                                if let detail = option.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        // Three lines, not one: a real description is a
                                        // sentence and a half, and it is the only thing on the
                                        // card that says what the option MEANS. Clamped rather
                                        // than unbounded so four options still fit above the
                                        // keyboard.
                                        .lineLimit(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.tertiarySystemBackground))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Still shown, never hidden: the reader has to be able to see what they
                    // are being asked even when this build cannot answer it for them.
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                        Text("• \(option.label)").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let footnote = Self.footnote(for: pending) {
                    Text(footnote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    static func prompt(of pending: SessionTimelineModel.Pending) -> PendingPrompt? {
        switch pending {
        case .none: return nil
        case .asking(let p), .sent(let p), .failed(let p, _): return p
        }
    }
}

/// A question already in the conversation, drawn as the question it was rather than as the
/// JSON of the call that asked it.
///
/// Rebuilt with the same parser the live card uses (`PendingPrompt.question`), over the body
/// the mapper already carries. `nil` from that parser is the ordinary outcome for a truncated
/// body — see `TimelineItem.Body.text` — and the fallback is the text, which is exactly what
/// this row did before.
struct HistoricalPromptBody: View {
    let item: TimelineItem

    var body: some View {
        if let prompt = PendingPrompt.question(
            session: UUID(), callID: item.body.callID ?? "", toolInput: item.body.text
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.question).font(.footnote.weight(.medium))
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                    Text("• \(option.label)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(item.body.text).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Mount it in `SessionTimelineScreen.swift`**

Change the bottom inset to stack the card above the composer, and add the fetch trigger beside the two that already exist:

```swift
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                PromptCard(pending: model.pending, model: model)
                PromptComposer(session: session, model: model)
            }
        }
        // The same trigger `loadNewer` uses, and that is the whole liveness story: a question
        // appearing and a question being answered on the Mac are both an `activity` change,
        // and the Mac pushes those already. No new frame and no timer of this card's own.
        .onChange(of: session?.activity) { _, _ in model.refreshPending() }
```

and in the existing busy-poll `.task(id: session?.activity)` loop, add `model.refreshPending()` beside `model.loadNewer()` — **but only while `waiting`**, not while busy:

```swift
        .task(id: session?.activity) {
            guard session?.activity == "waiting" else { return }
            // A dialog can be replaced without the activity changing at all — claude answers
            // one permission prompt and immediately raises the next, and both are `waiting`,
            // so `emitActivity`'s transition filter emits nothing between them. This is the
            // only thing that notices. Slower than the busy poll because a question changing
            // under a reader is rarer than a turn producing output, and because each of these
            // may read the transcript tail on the Mac.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                model.refreshPending()
            }
        }
```

> The existing `.task(id: session?.activity)` guards on `"busy"`. **Two `.task(id:)` modifiers with the same id on one view is legal and both run**, but keep them as two separate modifiers with distinct guards rather than merging into one loop with a branch — a merged loop would tie the two cadences together.

And in `model.open()`, add `refreshPending()` after `loadLatest()`, so a screen opened onto an already-blocked session shows its question without waiting for a transition.

- [ ] **Step 5: One arm in `TimelineRow.swift`**

Re-read the file first. In the `switch item.kind` at ~line 124, add:

```swift
        case .prompt:
            // A question the agent asked, rebuilt from the input the mapper carried. The
            // answer, when the feed holds one, is already folded in as `result` by
            // `entries(from:)` on `callID` — unchanged, because the RESULT is still a
            // `.toolResult`.
            HistoricalPromptBody(item: item)
```

- [ ] **Step 6: Run and verify they pass** — iOS baseline + 17.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `showsOptions`, return `true` for `.sent` as well | `testOptionsAreOfferedOnlyWhileTheQuestionIsUnanswered` |
| In `showsOptions`, drop `prompt.isAnswerable` | `testAnUnanswerableQuestionShowsItsReasonAndNoOptions` |
| In `footnote`, return `nil` for `.sent` | `testASentAnswerSaysSoRatherThanSayingNothing` |
| In `footnote`'s `.asking` arm, return `nil` unconditionally | `testAnUnanswerableQuestionShows…` — **and confirm `testAnAskedQuestionHasNoFootnote` still passes**, since that arm legitimately returns nil for an answerable one; two tests on one arm is what distinguishes them |
| In `SessionTimelineScreen`, delete `.onChange(of: session?.activity) { model.refreshPending() }` | **No unit test fails** — this is view wiring. It is item 3 of the manual checklist in Task 13, and it is the single most important thing to check by hand |

- [ ] **Step 8: Verify** — full four scripts, and `./scripts/build-ios.sh` specifically, since `PromptCard.swift` is a new flat mobile source.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeckMobile/PromptCard.swift Sources/FlightDeckMobile/SessionTimelineScreen.swift \
        Sources/FlightDeckMobile/TimelineRow.swift Tests/FlightDeckMobileTests/PromptCardTests.swift
git commit -m "feat: a blocked agent's question, as a box you can answer"
```

---

## Task 13: The checklist, and the two gaps

**Files:**
- Modify: `docs/MOBILE.md`
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:** none.

> **This task is not paperwork.** Two things in this plan are covered by no automated test and cannot be: `Ghostty.SurfaceView.sendArrow` never runs under XCTest, and every `ChoiceDialog` fixture is synthetic. The checklist is the only cover either has.

- [ ] **Step 1: Add to `docs/MOBILE.md`'s "The manual checklist"**

```markdown
### Answering a question from the phone

**Item 1 — capture a real dialog, and check the parser against it.** This is the one item that
must be done before the feature is believed. In a Flight Deck tab, get a claude session to a
permission prompt (`Bash(ls /)` with permissions on) and to an `AskUserQuestion` (ask it to
ask you something). For each, with the dialog on screen, note the exact shape: is the focused
row prefixed `❯`? Are the options numbered `1.`, `2.`? Is the question the line directly above?
`ChoiceDialog` was written from the claude binary's construction of these dialogs and **from no
capture at all** — if any of those three is wrong, `ChoiceDialogTests`' fixtures are wrong with
it and the parser refuses every real dialog (which is the safe direction, and is what "the card
never appears" will look like).

**Item 2 — arrows reach the pty.** With a permission prompt up, answer it from the phone,
choosing the SECOND option. The Mac's terminal must move its selection down one row and then
submit. `sendArrowDown` runs against `Ghostty.SurfaceView` and against nothing else in any
test; this is the only check that it is a key event and not five visible characters.

**Item 3 — the card appears and goes away on its own.** Open a session on the phone. On the
Mac, get it to a permission prompt: the card must appear within a second or two, without
touching the phone. Answer it *in the terminal*: the card must go away, again without touching
the phone. Both directions ride `activityChanged`; if either fails, the `.onChange` in
`SessionTimelineScreen` is the first place to look.

**Item 4 — racing.** Get a prompt up, let the phone show it, answer it in the terminal, then
tap an option on the phone before it refreshes. The phone must say "Your Mac has moved on from
this question" and the terminal must not move.

**Item 5 — two prompts in a row.** Answer a permission prompt on the Mac and let claude raise
the next one immediately. The card must change to the new question. This is the case
`activityChanged` does NOT cover — both states are `waiting`, so no transition is emitted — and
the 3-second `waiting` poll is what catches it.

**Item 6 — a multi-select question.** Ask claude something with `multiSelect: true`. The card
must show the question and the options with no buttons, and the sentence "This question takes
more than one answer. Answer it on your Mac."

**Item 7 — a historical question reads as one.** Scroll back to an answered `AskUserQuestion`.
It must render as the question and its options, not as a JSON tree.
```

- [ ] **Step 2: Add to `docs/FOLLOWUPS.md`**

```markdown
## Answering prompts from the phone — two accepted gaps

Both are scope decisions from `2026-08-24-answering-prompts-from-the-phone.md`, recorded here
so that disagreeing with them is a change to a decision rather than the discovery of a bug.

- **A paired phone can approve a tool in a tab nobody is looking at**, and the only signal on
  the Mac is the terminal moving. There is no per-tab opt-in and no Mac-side notification that
  a phone just answered something. The control §11 names — revocation, plus the attached-device
  badge in Settings → Devices — is the only one.
- **A screen-read permission label is truncated on the phone exactly as it is on the terminal.**
  `ChoiceDialog` reads plain text from a fixed-width screen, so "Yes, and don't ask again for
  Bash commands in /Users/nate/Projects/…" arrives elided, and the scope of a durable grant can
  be approved without being fully legible. An `AskUserQuestion` does not have this problem — it
  comes from the transcript, whole.
```

- [ ] **Step 3: Verify** — `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`, and run the checklist above by hand.

- [ ] **Step 4: Commit**

```bash
git add docs/MOBILE.md docs/FOLLOWUPS.md
git commit -m "docs: what to check by hand, and what this deliberately does not do"
```

---

## Self-Review

**Spec coverage.** §9's four named artefacts: `PendingPrompt` is built (Task 1) and is the type §9 asked for; `PromptBroker` is built as `PromptService` (Task 8) and normalizes two sources rather than two agents, because codex has no route (finding 5 of the preceding plan, unchanged); `prompt.opened`/`prompt.closed` are **deliberately not built**, with the reason argued from finding 6 and stated in `FleetRequest.pendingPrompt`'s doc comment so a future reader meets the argument at the code rather than in a plan; the **hook helper is not built**, because §1.1's contract is wrong (finding 2) and because there is no hook route to `AskUserQuestion` at all (finding 5). §9's two "must get right" points are both answered: a prompt outliving a connection needs nothing here, because nothing on the Mac blocks — the dialog stays on the terminal exactly as it would have — and no settings file is written, so §9's second point and §11's second open question are both moot for this plan and should be struck from the spec by whoever amends it. §5's rule holds: every command routes through a `SessionStore` method, and the Mac's own UI could call `answerPrompt` today. §4's `ack` rule holds and is load-bearing rather than tolerated. §6's `.prompt` kind is finally emitted, by the thing it was reserved for. §10's testing rule holds: every mapping is from a fixture, the loopback test is the only one with a socket, nothing touches `UITests`.

**Placeholder scan.** Three deliberate ellipses remain and each is a helper that already exists in a neighbouring test file: `AnswerPromptTests.makeStore` / `makeCodexStore` (lift from `PhonePromptDispatchTests`), `PromptServiceTests.makeService` and `askUserQuestionLine` (a shared fixture — put it in one place and reference it from three files), and `PromptLoopbackTests.makeLoopbackFleet` / `connectLoopbackClient` (lift from `PhonePromptLoopbackTests`). **Every one is a test harness, none is production code, and each names the file to lift it from.** No production code in this plan is elided. One known typo is flagged in place: `testAnAckForAPromptFetchFreesTheCallerRatherThanStranding It` in Task 3.

**Type consistency across tasks.** `PendingPrompt.id` is a `String` at every boundary — the transcript's `tool_use_id`, the `screen:` digest, `FleetCommand.answerPrompt`'s `prompt:`, `PromptService.served`'s comparison. `PendingPrompt?` is the reply type end to end: `PromptService.pending` → `ServerFrame.prompt(cid:_:)` → `FleetConnector.pendingPrompt`'s `Result<PendingPrompt?, _>` → `SessionTimelineModel.adopt`. `TimelineErrorCode` is the Mac's failure type in both services; the `init(_:)` extension in Task 8 is the only new spelling of it. `SessionStore.AnswerDispatch.errorCode` produces exactly the seven codes `SessionTimelineModel.answerMessage(for:)` reads, plus `prompt_unknown`/`prompt_changed` from `PromptService` — nine codes, all nine handled, with a `default` that names the unrecognised one. `SourceLine` crosses from `TranscriptPager` to `ClaudePendingQuestion` to `PromptService.tail` unchanged. Three tasks widen `SessionTimelineModel`'s `fleet` parameter and all three stub updates are named in Task 11.

**Ordering.** Tasks 1–3 are FleetKit and land before anything consumes them. Task 2 leaves the app target compiling via two placeholder arms, replaced in Task 9. Tasks 4–8 are Mac-side and each is independently testable. Task 9 is the only task that needs a socket. Tasks 10–12 are the phone and the historical row. Task 6 is the only task that touches files other tasks do not, and it touches them by adding two empty methods.

---

## Answers to your questions

**Path:** `docs/superpowers/plans/2026-08-24-answering-prompts-from-the-phone.md` — **not written**; save the text above to it.

**Task count:** 13.

**One mechanism or two:** **Two, and the split is not where §9 put it.** Detection and payload are genuinely two mechanisms, because the evidence forces it: a pending `AskUserQuestion` is fully in the transcript — structured input, exact option labels, descriptions, and the agent's own `tool_use_id` — while a permission dialog exists *nowhere but on the terminal screen*. The `tool_use` record for a tool awaiting approval is byte-identical to one for a tool merely running, and the choices ("Yes / Yes, and don't ask again for X in Y / No") are constructed in the TUI at display time. So: transcript for one, viewport scrape for the other. **Transport, rendering, racing-guard and delivery are one mechanism** — one request, one reply type, one card, one `answerPrompt` command, one keystroke driver — because both dialogs are drawn by the same select component in claude and both are answered the same way.

**What §9 the code contradicts:**
1. **The hook JSON in §1.1 is the wrong schema.** Real `PermissionRequest` output in claude 2.1.241 is `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",…}}}` — a nested discriminated object. §1.1's flat `permissionDecision`/`permissionDecisionReason` is the **`PreToolUse`** schema, sitting a few hundred bytes away in the same binary. A helper built to the spec would have been rejected by claude's own validator.
2. **§9 assumes a hook is the route for claude and the *only* asymmetry is plumbing.** For permission prompts, yes. For `AskUserQuestion` there is **no hook at all** — the `Elicitation` hook that looks like one is scoped to MCP servers (`mcp_server_name` is required in its input) and never fires for a built-in tool. The pty is the only route in, for both.
3. **§4's `prompt.opened` payload (`"tool": "Bash", "input": {…}`) has no room for a question.** No header, no options, no multi-select. It was designed for the permission case only and could not have carried the case that turns out to be the easy one.
4. **`prompt.opened`/`prompt.closed` are redundant.** `activityChanged` already pushes `waiting`/`waitingFor` to the phone, and `SessionTimelineScreen` already refetches on it — a fact the preceding plan recorded as *absent* ("`loadNewer()` has no caller"), which has since become stale. Two new event cases would announce something already on the wire, at the cost of a fold arm, a projection field, and a drift-check mutation site.

**How a pending question is distinguished from an answered one:** a tool call is open iff **no `tool_result` for its `tool_use_id` follows it** — and for `AskUserQuestion` specifically, that means "waiting for you", because that tool's *execution is the human answering*. (For every other tool the same condition means "running", which is why the rule is scoped by name.) Because claude cannot proceed past an unanswered question, an open one is always the last record, so it is a tail read of ~8 records, not a file scan. Verified against real data: `f90f38e2-….jsonl` line 21 has its result at line 22 seventy-seven seconds later; line 38 is another `AskUserQuestion` with no result and is the last line of the file, and that session's status file reads `"status":"waiting","waitingFor":"input needed"`. The Mac gates on the live status too, so a stale transcript cannot produce a phantom card.

**The three decisions I am least sure about:**

1. **The `ChoiceDialog` parser, by a wide margin.** It is written from the claude binary's *construction* of the dialog — I confirmed the select renders `❯` for the focused row and `" "` otherwise, that permission options carry an inline description, that a "Do you want to proceed?" heading sits above them — but **I never saw a rendered screen**, and `vendor/ghostty` holds artifacts so no capture can be made from this branch. Every fixture in Task 5 is synthetic. I mitigated it three ways (numbering required for a blind read, known labels as ground truth for the question case, and a re-read confirmation before Return) so that being wrong yields a card that never appears rather than a Return in the wrong place — but "the feature silently never works" is a real possible outcome and Task 13 item 1 is the only thing standing between that and a merge.

2. **Refusing multi-select rather than driving it.** The binary shows a `"Space to toggle, Enter to confirm, a to select all"` string, which is probably that list's key protocol — but "probably" is how the codex `/rename` incident started. I chose to show the question with no buttons. If Space-toggle is right, this leaves a common case unanswerable for no reason; if it is wrong, driving it would toggle options nobody chose and submit them.

3. **Scraping the screen for permission prompts at all, instead of building the hook helper.** The hook is the structurally correct answer for that case — it bypasses the TUI entirely and gets a typed decision with an `updatedPermissions` field this design cannot reach. I did not build it because its documented contract was wrong, because registering it mutates the user's `settings.json` (which already carries a `PermissionRequest` hook with `matcher: "*"`, and I could not establish how two registered hooks arbitrate a decision), and because it would need a helper binary in the app bundle and a unix socket server — a plan of its own. The screen route ships today and covers both cases with one driver; the hook remains the right follow-up, and if anyone builds it, **re-extract the schema first**.