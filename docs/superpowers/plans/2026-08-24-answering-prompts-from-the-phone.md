# Answering an Agent's Questions From the Phone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Claude session on the Mac is blocked on a question — an `AskUserQuestion` tool call, or a tool permission dialog — the paired phone draws it as a box in the conversation with controls that work. Tapping an option answers it. If the question is answered on the Mac first, the box goes away on the phone; if the phone answers first, the Mac's terminal moves.

**Architecture:** **This feature adds exactly one frame to the protocol, southbound.** Everything the phone needs in order to *know* a question is open and *what it says* is already on the wire: `WireSession.activity`/`waitingFor` ride the live snapshot and event stream, and the question's content is the tool call's own input, which the history channel already fetches and the timeline mapper already carries. So the open question is **derived independently on both ends** by one rule — the newest tool call with no `tool_result` for its `callID`, while the session is `waiting` — and nothing about it is transmitted. What is missing is only the write path: `FleetCommand.answerPrompt(id:token:call:answer:)`, answered `ack`/`err`, carrying `.option(index:label:)`, `.allow` or `.deny`. On the Mac, `SessionStore.answerPrompt` re-derives the open call from its own transcript, refuses one that is no longer newest, and then drives the terminal: arrows to the row, a second screen read to confirm the cursor landed, and only then Return — or, for `.deny`, a single Escape with no screen inference at all.

**Tech Stack:** Swift 6 (`FleetKit`, `FlightDeckMobile`), Swift 5 (`Sources/FlightDeck`), Network.framework, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` §9, §4, §6. **Read the next section before Task 1.** Five of §9's and §4's load-bearing claims are contradicted by the code and by this machine, and one of them is a JSON contract that could not have compiled against claude's own validator.

---

## Findings that change the spec, established from the source and from this machine

Each was checked on 2026-08-23 against this branch, against `~/.claude`, and against the `claude` binary at `~/.local/share/claude/versions/2.1.241`. None is inherited.

### 1. Nothing in §9 is built, and `.prompt` is still unused.

`rg 'PromptBroker|PendingPrompt|prompt\.opened|prompt\.closed' Sources/` returns nothing; the only hits anywhere are in the spec and in two plan documents. `SessionStore.flushPendingPrompts` is a false positive — it is the *resume* queue (`DeferredPrompt`, "Keep going" after a restore). `rg 'Kind.prompt|\.prompt\b' Sources/` finds `.prompt` only in `Timeline.swift:24` and in `TimelineStyle.swift`, which has been holding a heading ("Waiting for you"), a symbol (`questionmark.circle.fill`) and a colour (orange) for it since the timeline shipped, all unreached. **This plan is the first thing that emits it.**

### 2. The liveness §9 would have built already exists and already reaches the phone.

`WireSession` carries `activity` and `waitingFor` (`Sources/FleetKit/Wire.swift:51-56`). They are set on the Mac in `SessionStatus.swift` / `ClaudeStatusFile.swift` / `SessionStore.swift` / `FleetProjection.swift`, and emitted as `FleetEvent.activityChanged(id:activity:waitingFor:subagentCount:)` on every genuine transition. The phone renders them in three places already: `FleetListScreen.swift:171`, `SessionStatusGlyph.swift:121-125`, and `SessionTimelineScreen.swift:432-441`.

And the session screen already *acts* on them: `SessionTimelineScreen.swift:139` is

```swift
.onChange(of: session?.activity) { _, _ in model.loadNewer() }
```

So a session going blocked already pushes a fact to the phone **and** already triggers a fetch of the records that arrived with it. **`prompt.opened` / `prompt.closed` are redundant twice over** — once because the state is already pushed, and once because, per finding 3, the content needs no push either. Building them would cost a `FleetEvent` case, an arm in the replay fold, a field in `FleetProjection.snapshot`, and a new mutation site for the DEBUG drift check that §5 calls *"the only thing standing between a new mutation site and a stale phone"* — to announce something already on the wire.

> A note for whoever amends the spec: an earlier draft of *this* plan built a `FleetRequest.pendingPrompt` / `ServerFrame.prompt` pair to pull the question's content. That was deleted for the same reason. If you find yourself adding a channel here, check first whether the timeline already carries what you want.

### 3. A pending `AskUserQuestion` is already in the transcript the phone already fetches.

`~/.claude/projects/-Users-nate/f90f38e2-70a5-4d6f-b3d0-502633bfcc50.jsonl` is 38 lines. Line 21 is an `AskUserQuestion` `tool_use`; line 22 is its `tool_result` at `04:32:16`, 77 seconds after the call at `04:30:59` — the time a human took. Line 38 is another `AskUserQuestion` `tool_use` and is **the last line of the file**, and `~/.claude/sessions/71885.json` for that session reads `"status":"waiting","waitingFor":"input needed"`.

Three consequences:

- **The record is written before the tool runs**, so "waiting for an answer" and "in the transcript" are simultaneous, not sequential.
- **The rule for open-ness is exact**: no `tool_result` carries this `tool_use_id`. And it is a rule this codebase already computes — `SessionTimelineScreen.entries(from:)` (`:265-286`) folds results into calls on `body.callID` every time the screen draws.
- **The payload is real and rich**, and is what the control must be designed from (verbatim from line 21):
  `{"questions":[{"question":"…","header":"Random Q","multiSelect":false,"options":[{"label":"Playing jazz piano","description":"Sit down at any piano…"}, …]}]}`

**Free-text and multi-select are both real.** Line 219 of `8261151b-….jsonl` answers a `multiSelect: true` question with four option labels *plus* a string in no option — because, per the tool's own description in the binary, *"There should be no 'Other' option, that will be provided automatically."* This plan drives neither, and Task 1 refuses both explicitly; the shapes have to be known before deciding what to refuse.

### 4. A permission prompt carries no structured payload anywhere Flight Deck can read.

The `tool_use` record for a tool awaiting approval is written before the tool runs too — and is **byte-identical** to one for a tool that is merely running. There is no marker. The choices the human is offered are assembled in the TUI at display time from the live permission rule set: `"Do you want to proceed?"`, `"Yes, and don't ask again for "` and `"No, and tell Claude what to do differently "` sit next to a select component in 2.1.241, not in any record.

What the Mac does have is `waitingFor`, and it is a label lookup with a default: `dby(e) => qU0[e] ?? "permission prompt"`, over a map `{[k3t.kind]:"input needed", [Vxr.kind]:"sandbox request", [Ybt.kind]:"input needed", …}`. Two elicitation-shaped dialogs produce "input needed"; everything unmapped falls through to "permission prompt". **Do not branch behaviour on those strings.** They are copy, never a decision.

**So the two controls must differ, and that difference is the plan's shape rather than something smoothed over:**

| | `AskUserQuestion` | Permission prompt |
| --- | --- | --- |
| Payload the phone has | header, question, every option with its description | which tool, its whole input, and a reason string |
| Card | the question, one button per option | "Claude wants to run …", the input a tap away, **Allow / Deny** |
| Answer | `.option(index:label:)` | `.allow` / `.deny` |

### 5. There is no hook route to either case, and §9's hook contract is the wrong schema.

§1.1 states the decision contract as `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"allow"|"deny","permissionDecisionReason":"…"}}`. Extracted from 2.1.241, the real one is:

```
hookEventName: Ct("PermissionRequest"), decision: ks([
  ye({behavior: Ct("allow"), updatedInput: …optional, updatedPermissions: …optional}),
  ye({behavior: Ct("deny"),  message: …optional,      interrupt: …optional})
])
```

— a nested `decision` object with a `behavior` discriminant. The flat pair §9 quotes is the schema of a **different** event, `PreToolUse`, a few hundred bytes away in the same binary. **A helper built to §1.1 would have been rejected by claude's own validator.**

And for `AskUserQuestion` there is no hook at all. The `Elicitation` hook that looks like one (`action: "accept"|"decline"|"cancel"`, `content`) has input `{hook_event_name:"Elicitation", mcp_server_name, message, mode, url, elicitation_id, requested_schema}` and its own description reads *"Fired when an MCP server requests user input."* `AskUserQuestion` is a built-in tool and carries no `mcp_server_name`. **The pty is the only route in, for both cases** — which is what makes one delivery mechanism the right call rather than a compromise.

### 6. `inject`'s idle gate makes it the wrong funnel, in its own words.

`SessionStore.inject` documents: *"While `waiting` a Return answers a permission prompt or dialog instead of submitting."* That sentence describes the bug it avoids and describes the feature this plan wants. `inject` cannot be reused and must not be loosened — `submitPrompt`, `flushPendingRename` and `flushPendingPrompts` all depend on that gate. Task 6 adds `choose` and `deny`, siblings gated the other way, sharing only the `injecting` set and the `injectionSettle` seam.

---

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No AppKit, no UIKit, no SwiftUI, no Observation. `FleetKitiOS` compiles the same sources for iOS and is what enforces it.
- **`FleetKit` and `FlightDeckMobile` build in Swift 6 language mode. `Sources/FlightDeck` is Swift 5.** `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate — vendored Ghostty is not Swift-6 clean. Do not "fix" it.
- **`FleetSocketServer` and `FleetConnector` confine their state to `queue`** (`.main` in production) and assert it with `dispatchPrecondition`. Every closure added here keeps that discipline. No `nonisolated(unsafe)`, no `@unchecked Sendable`.
- **Sessions key on the tab `id`, never `conversationId`.** The one frame this plan adds carries a tab id.
- **Mobile sources stay flat.** `build-ios.sh`'s type-check fallback globs `Sources/FlightDeckMobile/*.swift` only; a file in a subdirectory is invisible to it on a machine with no iOS platform installed.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`.
- **`project.yml` needs no change.** `Sources/FleetKit`, `Sources/FlightDeck`, `Sources/FlightDeckMobile` and `Tests/FlightDeckTests/Fixtures` are recursive path / folder-reference entries. Leave it alone; another agent has touched it during this work.
- **`Sources/FlightDeckMobile/TimelineRow.swift` is being edited by another agent.** Task 10 touches it with exactly one added switch arm and nothing else. Run `git status` and re-read it immediately before editing; merge into what is there. **Never `git stash`, never `git checkout .`, never revert blind** — the stack is shared.
- **`vendor/ghostty` holds build artifacts, not sources.** No claim about what libghostty does with a byte sequence can be verified in this checkout. That is why Task 3 sends arrows and Escape as *key events* rather than as escape text, and why Task 6 confirms the effect on screen rather than assuming it.
- **Every fixture under `Tests/FlightDeckTests/Fixtures/` MUST be named `*.captured.*`** and sit beside a `*.captured.provenance.json` carrying `isVerbatimCapturedOutput`, `claudeVersion`, `capturedOn`, per-file `sha256`, `capturedBy` and `editingRule`. Lines may be dropped, never edited. `TimelineFixtureTests` asserts the checksum, so a semantic edit that still parses is caught rather than only a truncation. Tests reference captures by their documented name; if a test cannot find its fixture, **correct the lookup in the test, never add an undocumented copy under another name.**
- **Every test must be shown to fail against the bug it exists for.** Each task carries a **"prove it can fail"** step naming the exact mutation, and the result goes in the task report. **If a mutation produces zero failures, suspect the mutation and the fixture before you suspect the tests.** In the preceding plan, five of nine tasks found their own brief's mutation list defective: one mutation sat behind an early-return guard and was a no-op; one mutated nothing because Swift parses a bare `return` written above a comment as `return <the next expression>`; one killed 7 of 12 tests because the line it deleted was also the mechanism the others claimed against; one test could not pass at all. When you write a fixture, check that it *distinguishes* the failure — two values that differ, not two that happen to agree.
- **Verification per task:** `./scripts/build.sh`, `./scripts/test-unit.sh`, `./scripts/build-ios.sh`, `./scripts/test-ios.sh`. Baselines as this was written are **1560 unit / 116 iOS** — **measure your own before Task 1** and report deltas against what you measured, because every handed-down figure in this work has been wrong at least once.
- **Never run `./scripts/smoke.sh`** — it seizes the foreground for ~70s. **Never run `build.sh` while `test-unit.sh` is live** — they share `DerivedData`.

---

## Security: what this widens, stated plainly

**This grants a paired phone the authority to approve an agent's actions, and that is different in kind from everything before it.**

Trace the escalation honestly. Pairing let a phone read every transcript on the Mac — a large disclosure, and disclosure only. `FleetCommand.prompt`, shipped hours ago, let a phone cause arbitrary text to be typed into and submitted to a live Claude Code session: code execution by proxy, and its own plan said so. This adds the third thing: **a phone can press "Yes" on a permission dialog.**

The difference is not blast radius, it is *who decided*. A typed message is a request the agent may refuse, and every dangerous thing it leads to still stops at a permission prompt. A permission decision **is** the stopping point. There is no layer below it.

Five properties, and the first two are properties rather than limitations:

1. **The phone can answer a permission dialog only Allow or Deny, and "don't ask again" is structurally unreachable.** Claude's dialog puts *"Yes, and don't ask again for Bash commands in /Users/nate"* in its middle rows. That is a **durable grant** — it writes a rule that outlives the tap — made from a pocket, from a label a fixed-width terminal may have truncated mid-path. The phone cannot name it: `PromptAnswer` has no case for it, so there is no index a client could send and no button the card can draw. And the Mac never offers it: `SessionStore.answerPrompt`'s `.allow` arm targets the dialog's first row and nothing else. A phone cannot widen its own future authority.
2. **Deny is Escape, and involves no screen inference whatsoever.** The refusal path — the one a worried person reaches for from a pocket, on a train, having read four words of a command — sends one key event and reads nothing. It cannot be wrong about which row it is on, because it is not on a row. Every parsing risk in this plan lives on the *approval* side, which is the correct place for it.
3. **The Mac decides what the options are; the phone only names one.** For a question, `answerPrompt` re-derives the open call from its own transcript and takes the labels from *that*; the command's `label` is a cross-check, never an instruction. No string a phone sends reaches a keystroke.
4. **The open call is re-derived on the answer path, and a call that is no longer newest is refused.** See "Racing the Mac" below.
5. **Nothing is answered while the session is not `waiting`,** and the screen is re-read after the cursor moves and before Return. A failure there leaves a moved cursor and no answer — recoverable by the human at the terminal, which is where that failure belongs.

**Racing the Mac, and the harder race underneath it.** The obvious race is the user answering in the terminal while the phone shows the same question; the phone's tap then names a call that has a `tool_result`, the Mac's re-derivation returns a different call (or none), and the answer is refused `prompt_changed` with nothing typed. The **harder** race is the one worth naming, because an earlier draft of this plan survived it only by luck: the user approves prompt 1 in the terminal, claude raises prompt 2 immediately, and **the session never leaves `waiting`** — so no activity change is emitted, no fetch is triggered, and a card that looks live is describing a dialog that is gone. A stale tap would approve something nobody read. Re-derivation closes it: prompt 2 has a different `tool_use_id`, and the phone's tap names prompt 1's. A cache of "what I last served" would **not** have closed it, because the served entry would still be prompt 1 and would still match. **The guard is re-derivation from the transcript, not a cache, and it must stay that way.**

What this deliberately does not add: a Mac-side confirmation of each remote answer (a companion that must be confirmed on the Mac is not a companion), and any allow-list of which tools may be approved remotely. §11's named control is the right one and it is shipped: revocation, plus `DevicesSettingsTab` showing which device is attached while it does this.

**Two gaps, recorded rather than argued away.** A paired phone can approve a tool in a tab the user is not looking at, and the only Mac-side signal is the terminal moving. And the phone's permission card describes the *tool call* — which it has whole, from the transcript, so it is strictly more legible than the terminal's one-line summary — but it cannot show the dialog's own wording, because that wording exists nowhere it can read. Both belong in `docs/FOLLOWUPS.md` (Task 11).

---

## The wire shape, and why

**One new frame, southbound, and nothing else.** `FleetCommand.answerPrompt(id:token:call:answer:)`. No new request, no new server frame, no new event, no new connector table.

- **The question's existence** is `WireSession.activity == "waiting"`, already pushed (finding 2).
- **The question's content** is the tool call's input, already fetched by the history channel and already carried in `TimelineItem.Body.text` by `ClaudeTimelineMapper`. Task 9 changes only its `kind`.
- **Which call is open** is derived by one rule, run independently on both ends over the same transcript: the newest call with no `tool_result` for its `callID`, while `waiting`. The phone runs it over `feed.items`; the Mac runs it over its own tail. Nothing about it is transmitted, so nothing about it can be stale in transit.

**A `cmd`, not a `req`.** `ack` means dispatched, not done — and here that is the truth rather than a compromise: `choose` acts across an `injectionSettle`, so whether the Return landed is unknowable when the frame goes out. The observable effect arrives exactly the way §4 says it does, on the push channel: the session stops being `waiting`, and the transcript grows a `tool_result`. Refusals knowable *before* the settle — wrong agent, not waiting, changed call, unreadable screen, unanswerable shape — come back as `err` codes the phone renders into sentences. The one silent failure (the cursor did not land) is covered by the card's own 15-second deadline, with the same copy discipline `SessionTimelineModel.noConfirmation` established: never "try again".

**`FleetSocketServer.onUndecodable` salvages `t == "req"` and nothing else, deliberately.** A `cmd` this build cannot parse takes the socket down. So `FleetCommand`'s decoder must throw only over an unknown `op` or a missing key — never over a payload's *content*. There is nothing here to refuse on content (an index is an `Int`), which is itself a reason the answer names a choice rather than carrying one.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `Sources/FleetKit/OpenPrompt.swift` | Create | `PromptQuestion` parsing, and the one open-call rule both ends run |
| `Sources/FleetKit/Frames.swift` | Modify | `FleetCommand.answerPrompt` + `PromptAnswer` |
| `Sources/FleetKit/TimelineFrames.swift` | Modify | New `err` codes documented on `FleetRequestError` |
| `Sources/FlightDeck/TextInjecting.swift` | Modify | `sendArrowDown()`, `sendArrowUp()`, `sendEscape()` |
| `Sources/FlightDeck/ChoiceDialog.swift` | Create | `locate(labels:inViewport:)` — and nothing else |
| `Sources/FlightDeck/Agents/ClaudeOpenCall.swift` | Create | The Mac's half of the open-call rule, over a transcript tail |
| `Sources/FlightDeck/SessionStore.swift` | Modify | `viewport(of:)`, `AnswerDispatch`, `answerPrompt`, `choose`, `deny` |
| `Sources/FlightDeck/Fleet/PromptService.swift` | Create | Re-derive, verify, dispatch |
| `Sources/FlightDeck/Fleet/FleetService.swift` | Modify | One command arm |
| `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift` | Modify | `AskUserQuestion` → `TimelineItem.Kind.prompt` |
| `Sources/FlightDeckMobile/SessionTimelineModel.swift` | Modify | `PromptAnswering`, `blocked`, `answer`, deadline, copy |
| `Sources/FlightDeckMobile/FleetModel.swift` | Modify | `PromptAnswering` conformance |
| `Sources/FlightDeckMobile/PromptCard.swift` | Create | The box, both shapes, all four states |
| `Sources/FlightDeckMobile/SessionTimelineScreen.swift` | Modify | Mount the card; the one deferred retry |
| `Sources/FlightDeckMobile/TimelineRow.swift` | Modify | One switch arm for a historical `.prompt` |
| `Tests/FlightDeckTests/Fixtures/Claude/dialog-permission.captured.txt` | Create | Captured viewport |
| `Tests/FlightDeckTests/Fixtures/Claude/dialog-question.captured.txt` | Create | Captured viewport |
| `Tests/FlightDeckTests/Fixtures/Claude/dialogs.captured.provenance.json` | Create | Checksums and recipe |
| `Tests/FlightDeckTests/OpenPromptTests.swift` | Create | |
| `Tests/FlightDeckTests/AnswerFrameCodingTests.swift` | Create | |
| `Tests/FlightDeckTests/SpyInjectorOptionsTests.swift` | Create | |
| `Tests/FlightDeckTests/ChoiceDialogTests.swift` | Create | |
| `Tests/FlightDeckTests/ClaudeOpenCallTests.swift` | Create | |
| `Tests/FlightDeckTests/AnswerPromptTests.swift` | Create | |
| `Tests/FlightDeckTests/PromptServiceTests.swift` | Create | |
| `Tests/FlightDeckTests/AnswerLoopbackTests.swift` | Create | |
| `Tests/FlightDeckTests/TimelineFixtureTests.swift` | Modify | `text(_:in:)` loader + checksum assertion |
| `Tests/FlightDeckTests/SpyInjector.swift` | Modify | Model an option list |
| `Tests/FlightDeckTests/CodexResumeTests.swift` | Modify | Local `SpyInjector` conformance |
| `Tests/FlightDeckTests/CodexIntegrationTests.swift` | Modify | Local `SpyInjector` conformance |
| `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift` | Modify | `.prompt` mapping |
| `Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/PromptCardTests.swift` | Create | |
| `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` | Modify | `StubPager` gains `PromptAnswering` |
| `Tests/FlightDeckMobileTests/SessionTimelinePromptTests.swift` | Modify | Same |
| `docs/MOBILE.md` | Modify | Manual checklist |
| `docs/FOLLOWUPS.md` | Modify | The two recorded gaps |

`OpenPrompt` lives in `FleetKit` for the reason `PromptOutbox` and `TimelineFeed` do: it is a pure value computation over `[TimelineItem]`, and there the macOS unit suite covers it rather than only a simulator run — **and because the Mac and the phone must not run two different versions of the open-call rule.** They share this file.

---

## Task 1: `OpenPrompt` — the one rule, and the question it finds

**Files:**
- Create: `Sources/FleetKit/OpenPrompt.swift`
- Test: `Tests/FlightDeckTests/OpenPromptTests.swift`

**Interfaces:**
- Consumes: `JSONValue.parse(_:maxDepth:)` (`Sources/FleetKit/JSONValue.swift:88`), `TimelineItem` (`Sources/FleetKit/Timeline.swift:14`)
- Produces:
  - `public struct PromptQuestion: Equatable, Hashable, Sendable` — `header: String?`, `question: String`, `options: [Option]`, `unanswerable: String?`, `var isAnswerable: Bool`
  - `public struct PromptQuestion.Option: Equatable, Hashable, Sendable` — `label: String`, `detail: String?`
  - `public init?(toolInput: String)`
  - `public static let PromptQuestion.multiSelectReason: String`, `.multiQuestionReason: String`
  - `public enum OpenPrompt: Equatable, Sendable { case question(callID: String, PromptQuestion); case permission(callID: String, tool: String?, summary: String?) }`
  - `public var OpenPrompt.callID: String`
  - `public static func OpenPrompt.find(in items: [TimelineItem], activity: String?) -> OpenPrompt?`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/OpenPromptTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The rule both ends run, and the question it produces.
///
/// **This file is the single most load-bearing thing in the feature**, because the Mac and the
/// phone derive the open call independently and a disagreement between them is an answer typed
/// at the wrong dialog. They share this code precisely so they cannot disagree; these tests are
/// what say the shared code is right.
final class OpenPromptTests: XCTestCase {
    private func call(
        _ id: String, tool: String, kind: TimelineItem.Kind = .toolCall,
        text: String = "{}", summary: String? = nil, offset: Int
    ) -> TimelineItem {
        TimelineItem(
            id: TimelineItem.identifier(offset: offset, index: 0), kind: kind, status: .complete,
            body: .init(text: text, summary: summary, tool: tool, callID: id)
        )
    }

    private func result(_ id: String, offset: Int) -> TimelineItem {
        TimelineItem(
            id: TimelineItem.identifier(offset: offset, index: 0), kind: .toolResult,
            status: .complete, body: .init(text: "done", callID: id)
        )
    }

    /// Captured verbatim from `~/.claude/projects/-Users-nate/f90f38e2-….jsonl` line 21 on
    /// 2026-08-23. This is the shape the control is designed from; if it stops parsing, the
    /// phone stops showing questions.
    private let realInput = """
    {"questions":[{"question":"If you could instantly become world-class at one skill you've \
    never practiced, which would you pick?","header":"Random Q","multiSelect":false,\
    "options":[{"label":"Playing jazz piano","description":"Sit down at any piano and \
    improvise fluently with a band."},{"label":"Speaking 10 languages","description":"Drop \
    into any country and converse like a local."},{"label":"Freehand drawing",\
    "description":"Sketch anything you can picture."},{"label":"Woodworking",\
    "description":"Build furniture with hand-cut joinery."}]}]}
    """

    // MARK: The rule

    /// **`activity` is not optional and not decorative.** An unanswered call on an idle session
    /// is a call whose RESULT has not been fetched yet — the ordinary state of a feed a beat
    /// behind the file — and offering buttons for it would put a control on a conversation
    /// nobody is blocked on.
    func testAnUnansweredCallOnAnIdleSessionIsNotOpen() {
        let items = [call("toolu_A", tool: "Bash", offset: 0)]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "idle"))
        XCTAssertNil(OpenPrompt.find(in: items, activity: "busy"))
        XCTAssertNil(OpenPrompt.find(in: items, activity: nil))
    }

    func testAnUnansweredToolCallWhileWaitingIsAPermissionRequest() {
        let items = [call("toolu_A", tool: "Bash", summary: "rm -rf build", offset: 0)]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting"),
            .permission(callID: "toolu_A", tool: "Bash", summary: "rm -rf build")
        )
    }

    func testAnUnansweredPromptCallWhileWaitingIsAQuestion() throws {
        let items = [call("toolu_A", tool: "AskUserQuestion", kind: .prompt,
                          text: realInput, offset: 0)]
        guard case .question("toolu_A", let question)? =
            OpenPrompt.find(in: items, activity: "waiting")
        else { return XCTFail("expected a question") }
        XCTAssertEqual(question.header, "Random Q")
        XCTAssertEqual(question.options.count, 4)
    }

    /// **The pairing rule, and the fixture that distinguishes it.** Two calls, the newer one
    /// answered — so a finder that took "the last call" without checking results would return
    /// `toolu_NEW`, and one that stopped at the first unanswered from the front would return
    /// `toolu_OLD` when it should return nothing. The tools differ so the assertion can tell
    /// which mistake was made.
    func testACallWithAResultIsNotOpen() {
        let items = [
            call("toolu_OLD", tool: "Read", offset: 0),
            result("toolu_OLD", offset: 100),
            call("toolu_NEW", tool: "Bash", offset: 200),
            result("toolu_NEW", offset: 300),
        ]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    /// A result can arrive out of order in a merged feed — `TimelineFeed` orders by byte
    /// offset, but a page boundary can put a result above its call in what the phone holds.
    /// The set of answered ids is therefore built from the WHOLE feed before anything is
    /// judged, not from what follows a given call.
    func testAResultAnywhereInTheFeedClosesItsCall() {
        let items = [
            result("toolu_A", offset: 0),
            call("toolu_A", tool: "Bash", offset: 100),
        ]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    func testTheNewestUnansweredCallWins() {
        let items = [
            call("toolu_OLD", tool: "Read", offset: 0),
            call("toolu_NEW", tool: "Bash", offset: 100),
        ]
        XCTAssertEqual(
            OpenPrompt.find(in: items, activity: "waiting")?.callID, "toolu_NEW"
        )
    }

    /// A `.prompt` row whose body the reader truncated is a question this build cannot
    /// reconstruct. It is NOT silently downgraded to a permission card — that would offer
    /// Allow/Deny for a dialog whose first row is "Playing jazz piano".
    func testAPromptRowWhoseBodyWillNotParseIsNoOpenPromptAtAll() {
        let items = [call("toolu_A", tool: "AskUserQuestion", kind: .prompt,
                          text: String(realInput.prefix(120)), offset: 0)]
        XCTAssertNil(OpenPrompt.find(in: items, activity: "waiting"))
    }

    /// Prose rows carry no `callID` and must not be considered at all — including a `.userTurn`
    /// that happens to be the newest thing in the feed.
    func testProseIsNeverAnOpenCall() {
        let items = [
            call("toolu_A", tool: "Bash", offset: 0),
            TimelineItem(id: "100#0", kind: .userTurn, status: .complete, body: .init(text: "hi")),
        ]
        XCTAssertEqual(OpenPrompt.find(in: items, activity: "waiting")?.callID, "toolu_A")
    }

    // MARK: The question

    func testARealAskUserQuestionInputParses() throws {
        let question = try XCTUnwrap(PromptQuestion(toolInput: realInput))
        XCTAssertTrue(question.question.hasPrefix("If you could instantly become"))
        XCTAssertEqual(
            question.options.map(\.label),
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"]
        )
        XCTAssertEqual(question.options[1].detail, "Drop into any country and converse like a local.")
        XCTAssertTrue(question.isAnswerable)
    }

    /// **Carried, drawn, and not answerable.** A multi-select question is answered in the TUI
    /// with Space to toggle and then Enter — a second key protocol this build has never
    /// observed and must not guess at. Showing it with an explanation is strictly better than
    /// hiding it: the reader learns there is something waiting and where to go.
    func testAMultiSelectQuestionIsCarriedButNotAnswerable() throws {
        let input = realInput.replacingOccurrences(
            of: "\"multiSelect\":false", with: "\"multiSelect\":true"
        )
        let question = try XCTUnwrap(PromptQuestion(toolInput: input))
        XCTAssertEqual(question.options.count, 4, "the options are still shown")
        XCTAssertFalse(question.isAnswerable)
        XCTAssertEqual(question.unanswerable, PromptQuestion.multiSelectReason)
    }

    func testACallCarryingTwoQuestionsIsNotAnswerable() throws {
        let two = """
        {"questions":[{"question":"First?","header":"A","multiSelect":false,\
        "options":[{"label":"x"}]},{"question":"Second?","header":"B","multiSelect":false,\
        "options":[{"label":"y"}]}]}
        """
        let question = try XCTUnwrap(PromptQuestion(toolInput: two))
        XCTAssertEqual(question.question, "First?")
        XCTAssertFalse(question.isAnswerable)
        XCTAssertEqual(question.unanswerable, PromptQuestion.multiQuestionReason)
    }

    func testATruncatedInputProducesNoQuestionRatherThanAPartialOne() {
        XCTAssertNil(PromptQuestion(toolInput: String(realInput.prefix(120))))
    }

    func testAQuestionWithNoOptionsIsNotAQuestion() {
        XCTAssertNil(PromptQuestion(toolInput: #"{"questions":[{"question":"Well?","options":[]}]}"#))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | grep -E "OpenPrompt|error:"`
Expected: compile failure — `cannot find 'OpenPrompt' in scope`.

- [ ] **Step 3: Create `Sources/FleetKit/OpenPrompt.swift`**

```swift
import Foundation

/// An `AskUserQuestion`'s input, read.
///
/// **Not a wire type, and that is the design.** An earlier draft of this feature transmitted a
/// `PendingPrompt` over a new request/response pair. It was deleted: the payload is the tool
/// call's own input, the history channel already fetches it, and `ClaudeTimelineMapper` already
/// carries it in `TimelineItem.Body.text`. So this is a *derivation* both ends run over data
/// they already hold — which is also why it lives in `FleetKit` and not in either app. The Mac
/// and the phone must not run two versions of this rule.
public struct PromptQuestion: Equatable, Hashable, Sendable {
    public struct Option: Equatable, Hashable, Sendable {
        public var label: String
        /// The option's `description`. Frequently a line and a half, and the only thing on the
        /// card that says what the option MEANS.
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    /// `AskUserQuestion`'s `header` — a short label above the question.
    public var header: String?
    public var question: String
    public var options: [Option]
    /// Why this cannot be answered from a phone, or `nil` when it can.
    ///
    /// A sentence rather than a code, because the reasons are facts about what the *Mac* can
    /// drive: this build has never observed the key protocol for a multi-select list, and a
    /// call carrying two questions shows them in sequence so answering the first would leave
    /// the second up with the reader believing they were done.
    public var unanswerable: String?

    public init(
        header: String? = nil, question: String, options: [Option], unanswerable: String? = nil
    ) {
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

    /// Reads an `AskUserQuestion` tool input.
    ///
    /// `toolInput` is the input object's JSON text — on the phone that is
    /// `TimelineItem.Body.text` for a `.prompt` row, and on the Mac it is the record's own
    /// `input` re-serialized. One parser, two entry points, by construction.
    ///
    /// **Nil rather than a partial read.** `JSONValue.parse` is strict and refuses trailing
    /// content, which is what makes a body cut at `TimelineLimits.maxItemBytes` — the ordinary
    /// state of a large tool input, per `TimelineItem.Body.text` — return nothing here instead
    /// of a question missing its last two options. Three of four choices is worse than none.
    ///
    /// The shape, captured from a real transcript on 2026-08-23:
    /// `{"questions":[{"question":…,"header":…,"multiSelect":false,
    ///   "options":[{"label":…,"description":…}]}]}`
    public init?(toolInput: String) {
        guard let root = JSONValue.parse(toolInput),
              case .array(let questions)? = root.member("questions"),
              let first = questions.first,
              case .string(let text)? = first.member("question"),
              case .array(let rawOptions)? = first.member("options")
        else { return nil }

        let options: [Option] = rawOptions.compactMap { option in
            guard case .string(let label)? = option.member("label"), !label.isEmpty
            else { return nil }
            if case .string(let detail)? = option.member("description"), !detail.isEmpty {
                return Option(label: label, detail: detail)
            }
            return Option(label: label)
        }
        // A question with nothing to pick is not one this feature can show, and is not a shape
        // the tool produces. Refusing keeps a malformed record off the screen.
        guard !options.isEmpty else { return nil }

        var header: String?
        if case .string(let raw)? = first.member("header"), !raw.isEmpty { header = raw }

        // Order decides only which sentence is shown; several questions is the more surprising
        // fact, so it wins.
        var unanswerable: String?
        if questions.count > 1 {
            unanswerable = Self.multiQuestionReason
        } else if case .bool(true)? = first.member("multiSelect") {
            unanswerable = Self.multiSelectReason
        }

        self.init(header: header, question: text, options: options, unanswerable: unanswerable)
    }
}

/// What a session is blocked on, derived rather than transmitted.
public enum OpenPrompt: Equatable, Sendable {
    /// An `AskUserQuestion`. Structured, exact, with descriptions.
    case question(callID: String, PromptQuestion)
    /// Any other tool awaiting approval. **There is no structured payload for this case and
    /// there is nowhere to get one**: the `tool_use` record is byte-identical to one for a
    /// tool that is merely running, and the dialog's own wording ("Yes, and don't ask again
    /// for Bash commands in …") is assembled in the TUI at display time from the live
    /// permission rule set. What is available is the call itself, which is *more* than the
    /// terminal shows — the whole input, not a one-line summary — and the reason string
    /// `WireSession.waitingFor` already carries.
    case permission(callID: String, tool: String?, summary: String?)

    public var callID: String {
        switch self {
        case .question(let id, _), .permission(let id, _, _): return id
        }
    }

    /// The one open-call rule. **Run identically on the Mac and on the phone, over the same
    /// transcript, and never sent between them** — which is what closes the race where a user
    /// answers in the terminal, or where claude answers one dialog and raises the next without
    /// the session ever leaving `waiting`. A cache of "what was last served" would still match
    /// in that second case; a re-derivation cannot.
    ///
    /// Two conditions, and both are necessary:
    ///
    /// - **`activity == "waiting"`.** An unanswered call on an idle or busy session is a call
    ///   whose result has not been read yet, which is the ordinary state of any feed a beat
    ///   behind the file.
    /// - **No `tool_result` carries this `callID`.** The same pairing
    ///   `SessionTimelineScreen.entries(from:)` already does to fold output into a command.
    ///
    /// For `AskUserQuestion` the pair is exact, because that tool's *execution is the human
    /// answering*. For every other tool it means "approving or running", and `waiting` is what
    /// separates the two.
    public static func find(in items: [TimelineItem], activity: String?) -> OpenPrompt? {
        guard activity == "waiting" else { return nil }

        // Built from the WHOLE feed first. A merged feed can hold a result above its own call
        // when a page boundary landed between them, so "what follows this call" is not a safe
        // question to ask.
        var answered: Set<String> = []
        for item in items where item.kind == .toolResult {
            if let id = item.body.callID { answered.insert(id) }
        }

        for item in items.reversed() {
            guard let id = item.body.callID, !answered.contains(id) else { continue }
            switch item.kind {
            case .prompt:
                // A body that will not parse is NOT downgraded to a permission card: that
                // would draw Allow/Deny for a dialog whose first row is "Playing jazz piano".
                guard let question = PromptQuestion(toolInput: item.body.text) else { return nil }
                return .question(callID: id, question)
            case .toolCall:
                return .permission(callID: id, tool: item.body.tool, summary: item.body.summary)
            default:
                continue
            }
        }
        return nil
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
Expected: your measured baseline + 14, 0 failures.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Delete `guard activity == "waiting"` | `testAnUnansweredCallOnAnIdleSessionIsNotOpen` |
| Build `answered` only from items *after* the candidate | `testAResultAnywhereInTheFeedClosesItsCall` |
| Iterate `items` forwards instead of `items.reversed()` | `testTheNewestUnansweredCallWins` — the fixture's two calls have different tools *and* different ids, so the assertion distinguishes either mistake |
| In the `.prompt` arm, fall through to `.permission` when `PromptQuestion` returns nil | `testAPromptRowWhoseBodyWillNotParseIsNoOpenPromptAtAll` |
| Delete the `questions.count > 1` branch **and** its `else if` together | `testACallCarryingTwoQuestionsIsNotAnswerable`. **Deleting only the body leaves a dangling `if` that will not compile** — remove both arms and re-add the `multiSelect` one alone |
| Delete the `multiSelect` branch | `testAMultiSelectQuestionIsCarriedButNotAnswerable` |
| Replace `guard !options.isEmpty else { return nil }` with nothing | `testAQuestionWithNoOptionsIsNotAQuestion` |
| Use `JSONSerialization.jsonObject` instead of `JSONValue.parse` | `testATruncatedInputProducesNoQuestion…` — **verify first**: `prefix(120)` cuts inside a string literal, which both parsers refuse, so this should fail. If it does not, lengthen the prefix until it cuts mid-object rather than mid-string and re-check |
| In `find`, drop the `default: continue` and match `.toolResult` as a call | `testProseIsNeverAnOpenCall` — **check this**: that fixture's prose row has no `callID` and is skipped by the `guard`, so the mutation may be a no-op. If so, add a result row *after* the call in that fixture and re-run |

- [ ] **Step 6: Verify**

Run: `./scripts/build.sh && ./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/OpenPrompt.swift Tests/FlightDeckTests/OpenPromptTests.swift
git commit -m "feat: one rule for what an agent is blocked on, shared by both ends"
```

---

## Task 2: The answer on the wire

**Files:**
- Modify: `Sources/FleetKit/Frames.swift` (`FleetCommand`, lines 19-97)
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequestError.server`'s doc comment, ~line 193)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (one placeholder arm)
- Test: `Tests/FlightDeckTests/AnswerFrameCodingTests.swift`

**Interfaces:**
- Produces:
  - `public enum PromptAnswer: Codable, Equatable, Sendable { case option(index: Int, label: String); case allow; case deny }`
  - `case FleetCommand.answerPrompt(id: UUID, token: UUID, call: String, answer: PromptAnswer)`, wire `op` `"prompt.answer"`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/AnswerFrameCodingTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The one frame this feature adds, and the properties that are not obvious from its shape:
/// that it names a choice rather than carrying one, that `deny` carries nothing at all, and
/// that the vocabulary already on the wire still decodes beside it.
final class AnswerFrameCodingTests: XCTestCase {
    private let session = UUID()
    private let token = UUID()

    private func object(_ frame: ClientFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Flattened into the frame's own object, exactly as `markRead` and `session.prompt` are:
    /// one command reads as one line, which is what makes a packet dump usable.
    func testAnOptionAnswerReadsAsOneFlatObject() throws {
        let json = try object(.cmd(cid: 41, .answerPrompt(
            id: session, token: token, call: "toolu_A",
            answer: .option(index: 1, label: "Speaking 10 languages")
        )))
        XCTAssertEqual(json["t"] as? String, "cmd")
        XCTAssertEqual(json["op"] as? String, "prompt.answer")
        XCTAssertEqual(json["call"] as? String, "toolu_A")
        XCTAssertEqual(json["answer"] as? String, "option")
        XCTAssertEqual(json["index"] as? Int, 1)
        XCTAssertEqual(json["label"] as? String, "Speaking 10 languages")
        XCTAssertEqual(
            Set(json.keys), ["t", "cid", "op", "id", "token", "call", "answer", "index", "label"]
        )
    }

    /// **Deny carries nothing, and that is the point.** It is delivered as a single Escape on
    /// the Mac with no screen read, so there is nothing for it to name and nothing a client
    /// could get wrong about it.
    func testDenyCarriesNoIndexAndNoLabel() throws {
        let json = try object(.cmd(cid: 4, .answerPrompt(
            id: session, token: token, call: "toolu_A", answer: .deny
        )))
        XCTAssertEqual(json["answer"] as? String, "deny")
        XCTAssertNil(json["index"])
        XCTAssertNil(json["label"])
    }

    /// **Allow carries nothing either**, because it means "the dialog's first row" and the Mac
    /// is the only thing entitled to say which row that is. A phone that could send an index
    /// here could reach the middle rows — "Yes, and don't ask again for Bash commands in
    /// /Users/nate" — which is a durable grant this design puts out of reach by construction.
    func testAllowCarriesNoIndexAndNoLabel() throws {
        let json = try object(.cmd(cid: 4, .answerPrompt(
            id: session, token: token, call: "toolu_A", answer: .allow
        )))
        XCTAssertEqual(json["answer"] as? String, "allow")
        XCTAssertNil(json["index"])
        XCTAssertNil(json["label"])
    }

    func testEachAnswerRoundTripsThroughClientFrame() throws {
        for answer: PromptAnswer in [.option(index: 0, label: "Yes"), .allow, .deny] {
            let sent = ClientFrame.cmd(cid: 9, .answerPrompt(
                id: session, token: token, call: "toolu_A", answer: answer
            ))
            let data = try JSONEncoder().encode(sent)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), sent)
        }
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

    func testMarkReadStillDecodesFromTheShapeAlreadyOnTheWire() throws {
        let line = #"{"t":"cmd","cid":7,"op":"session.markRead","id":"\#(session.uuidString)"}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)),
            .cmd(cid: 7, .markRead(id: session))
        )
    }

    /// An answer with no call id is an intent with nothing to apply it to, and accepting it
    /// would act on whatever happened to be up. Refused as the command it claimed to be,
    /// which is what reading `op` before `id` buys.
    func testAnAnswerWithoutACallIDThrows() {
        let line = #"""
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\#(session.uuidString)",\
        "token":"\#(token.uuidString)","answer":"deny"}
        """#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// An `option` with no index is not an option. The three-case codec must not silently read
    /// it as `allow`.
    func testAnOptionAnswerWithoutAnIndexThrows() {
        let line = #"""
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\#(session.uuidString)",\
        "token":"\#(token.uuidString)","call":"toolu_A","answer":"option","label":"Yes"}
        """#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    /// **An unknown answer throws, unlike `TimelineItem.Kind`'s decode-unknown rule, and the
    /// difference is direction.** Phone → Mac is executed, not rendered; there is no fallback
    /// for "an intent I do not understand" that is not a wrong answer, and here a wrong answer
    /// is a keystroke in a live terminal.
    func testAnUnknownAnswerThrows() {
        let line = #"""
        {"t":"cmd","cid":7,"op":"prompt.answer","id":"\#(session.uuidString)",\
        "token":"\#(token.uuidString)","call":"toolu_A","answer":"allow_always"}
        """#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }

    func testAnUnknownOpStillThrows() {
        let line = #"{"t":"cmd","cid":7,"op":"session.detonate","id":"\#(session.uuidString)"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ClientFrame.self, from: Data(line.utf8)))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail** — `type 'FleetCommand' has no member 'answerPrompt'`.

- [ ] **Step 3: Add `PromptAnswer` and the case in `Sources/FleetKit/Frames.swift`**

Above `FleetCommand`:

```swift
/// What a client chose, in the one dialog a session is blocked on.
///
/// **Three cases, and the absence of a fourth is a security property rather than an
/// omission.** Claude's permission dialog puts *"Yes, and don't ask again for Bash commands in
/// /Users/nate"* in its middle rows — a **durable grant**, one that outlives the tap, made from
/// a phone, from a label a fixed-width terminal may have truncated mid-path. There is no case
/// here that names it, so there is no index a client can send and no button a card can draw;
/// and `SessionStore.answerPrompt`'s `.allow` arm targets the dialog's FIRST row and nothing
/// else. A phone cannot widen its own future authority. Do not add a case for it.
///
/// **`deny` is Escape, and that is the point.** The refusal path — the one a worried person
/// reaches for from a pocket, having read four words of a command — sends one key event and
/// reads nothing off the screen. It carries no index and no label because it needs none: it
/// cannot be wrong about which row it is on, because it is not on a row. Every parsing risk in
/// this feature therefore lives on the approval side, which is where it belongs.
///
/// `option` is for `AskUserQuestion` only, where the Mac has the real labels from its own
/// transcript. `label` is a **cross-check**, never an instruction: the Mac matches its own copy
/// on screen and refuses when the client's disagrees. Nothing a client sends becomes a keystroke.
public enum PromptAnswer: Codable, Equatable, Sendable {
    case option(index: Int, label: String)
    /// A permission dialog's first row.
    case allow
    /// Escape.
    case deny

    enum CodingKeys: String, CodingKey { case answer, index, label }

    private enum Tag: String, Codable { case option, allow, deny }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .option(let index, let label):
            try c.encode(Tag.option, forKey: .answer)
            try c.encode(index, forKey: .index)
            try c.encode(label, forKey: .label)
        case .allow:
            try c.encode(Tag.allow, forKey: .answer)
        case .deny:
            try c.encode(Tag.deny, forKey: .answer)
        }
    }

    /// An unrecognised value throws, like `FleetCommand`'s `op` and unlike
    /// `TimelineItem.Kind`'s. Direction decides: this travels phone → Mac and is *executed*,
    /// and there is no default that is not a wrong answer — here, a keystroke in a live
    /// terminal. `TimelineAnchor.init(name:cursor:)` makes the same argument at length.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .answer) {
        case .option:
            self = .option(
                index: try c.decode(Int.self, forKey: .index),
                label: try c.decode(String.self, forKey: .label)
            )
        case .allow: self = .allow
        case .deny: self = .deny
        }
    }
}
```

In `FleetCommand`, add the case after `.prompt`:

```swift
    /// Answer the dialog that tab `id` is blocked on.
    ///
    /// `call` is the blocked tool call's `tool_use_id`, and it is **derived independently on
    /// both ends** — the phone from the timeline it already holds, the Mac from its own
    /// transcript — rather than served by one and echoed by the other. That is what closes the
    /// race: the Mac re-derives on this path and refuses a call that is no longer the newest
    /// unanswered one (`prompt_changed`), typing nothing.
    ///
    /// It closes the harder race too, which a served-and-echoed id would not: the user approves
    /// in the terminal, claude raises the next dialog immediately, and the session **never
    /// leaves `waiting`** — so no activity change is emitted and a card that looks live is
    /// describing a dialog that is gone. A cache of "what I last served" still matches there.
    /// A re-derivation does not, because the new dialog is a different call.
    ///
    /// `token` is the client's own idempotency key, minted once per tap, for the reason
    /// `.prompt`'s is: the socket can drop between the command landing and its `ack` being
    /// read, so a retry must be free.
    case answerPrompt(id: UUID, token: UUID, call: String, answer: PromptAnswer)
```

Extend `CodingKeys` and `Op`:

```swift
    enum CodingKeys: String, CodingKey { case op, id, token, text, call, answer, index, label }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
        case prompt = "session.prompt"
        case answerPrompt = "prompt.answer"
    }
```

Encode arm:

```swift
        case .answerPrompt(let id, let token, let call, let answer):
            try c.encode(Op.answerPrompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(call, forKey: .call)
            // Flattened into the same object rather than nested, exactly as `ClientFrame`
            // flattens a command into a frame: two keyed containers over one encoder merge
            // into a single JSON object, and one command reading as one line is what makes a
            // dump usable.
            try answer.encode(to: encoder)
```

Decode arm:

```swift
        case .answerPrompt:
            self = .answerPrompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                call: try c.decode(String.self, forKey: .call),
                answer: try PromptAnswer(from: decoder)
            )
```

- [ ] **Step 4: Document the new codes on `FleetRequestError.server`**

Append to its doc comment in `TimelineFrames.swift`:

```swift
    /// The answer channel adds four, all refusals a person can act on: `prompt_changed` (your
    /// Mac has moved on — what is up now is not what you tapped), `not_waiting` (nothing is
    /// blocked on this tab), `unreadable_screen` (the terminal could not be read, or another
    /// injection is resolving — try again in a moment), and `unanswerable` (a shape this Mac
    /// will not drive; see `PromptQuestion.unanswerable`). `unsupported_agent` and
    /// `unknown_session` keep the meanings `FleetCommand.prompt` gave them.
```

- [ ] **Step 5: Add the placeholder arm so the app target still compiles**

`FleetCommand` is exhaustively switched in `FleetService.apply`. Add now, refusing rather than acking, so an intermediate build cannot silently claim to have answered something:

```swift
        case .answerPrompt:
            // Wired for real in Task 8.
            return .err(cid: cid, code: "unhandled")
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `./scripts/build.sh && ./scripts/test-unit.sh 2>&1 | tail -5`
Expected: baseline + 23 cumulative. `FleetFrameCodingTests` and `PromptCommandCodingTests` must pass unchanged.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Add `case allowAlways` to `PromptAnswer` and to `Tag` | **This is the mutation that guards the security property.** No existing test fails, and that is the finding — add `testThereIsNoCaseThatReachesTheDontAskAgainRow`, asserting `PromptAnswer.Tag.allCases.count == 3` via a `CaseIterable` conformance on `Tag`, before you rely on this row |
| In `PromptAnswer.encode`'s `.deny` arm, also write `index`/`label` | `testDenyCarriesNoIndexAndNoLabel` |
| In `PromptAnswer.init(from:)`, use `decodeIfPresent(Int.self, forKey: .index) ?? 0` | `testAnOptionAnswerWithoutAnIndexThrows` |
| Add `default: self = .deny` to the `Tag` switch | `testAnUnknownAnswerThrows` — **and check it compiles**: an exhaustive switch over a `Codable` enum will warn that `default` is unreachable, so write the mutation as `Tag(rawValue:) ?? .deny` instead |
| In `FleetCommand.init(from:)`'s arm, `decodeIfPresent(String.self, forKey: .call) ?? ""` | `testAnAnswerWithoutACallIDThrows` |
| In `FleetCommand.encode`, nest the answer under an `"answer"` object | `testAnOptionAnswerReadsAsOneFlatObject` (the `Set(json.keys)` assertion) |

- [ ] **Step 8: Verify** — full four scripts.

- [ ] **Step 9: Commit**

```bash
git add Sources/FleetKit/Frames.swift Sources/FleetKit/TimelineFrames.swift \
        Sources/FlightDeck/Fleet/FleetService.swift \
        Tests/FlightDeckTests/AnswerFrameCodingTests.swift
git commit -m "feat: an answer is a command, and it names a choice rather than carrying one"
```

---

## Task 3: Arrows, Escape, and every fake that has to grow them

**Files:**
- Modify: `Sources/FlightDeck/TextInjecting.swift`
- Modify: `Tests/FlightDeckTests/SpyInjector.swift`
- Modify: `Tests/FlightDeckTests/CodexResumeTests.swift` (private `SpyInjector`, ~line 277)
- Modify: `Tests/FlightDeckTests/CodexIntegrationTests.swift` (private `SpyInjector`, ~line 477)
- Test: `Tests/FlightDeckTests/SpyInjectorOptionsTests.swift`

**Interfaces:**
- Produces: `func TextInjecting.sendArrowDown()`, `func TextInjecting.sendArrowUp()`, `func TextInjecting.sendEscape()`; `SpyInjector.Event.arrow(Int)`, `.escape`; `SpyInjector.showOptions(_:selected:)`, `.options`, `.selected`, `.ignoreArrowsAfter`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/SpyInjectorOptionsTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The fake **models** the option list rather than merely recording against it — the same
/// decision `SpyInjector`'s input-bar modelling documents, and for the same reason: a fake that
/// ignored what a keystroke DOES would let the dangerous case pass. `SessionStore.choose`
/// re-reads the screen after moving and refuses Return unless the marker landed, so a fake
/// whose screen never changed would make that check untestable.
@MainActor
final class SpyInjectorOptionsTests: XCTestCase {
    func testAnArrowMovesTheMarkerOnTheModelledScreen() throws {
        let spy = SpyInjector()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.sendArrowDown()
        let viewport = try XCTUnwrap(spy.readViewport())
        XCTAssertEqual(
            ChoiceDialog.locate(labels: ["Yes", "No", "Maybe"], inViewport: viewport), .success(1)
        )
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

    func testEscapeIsItsOwnEventAndMovesNothing() {
        let spy = SpyInjector()
        spy.showOptions(["a", "b"], selected: 1)
        spy.sendEscape()
        XCTAssertEqual(spy.events, [.escape])
        XCTAssertEqual(spy.selected, 1, "escape is a refusal, not a movement")
    }

    /// A tab showing the input bar rather than a dialog must still render as it always did —
    /// every rename and typed-prompt test in the suite reads that shape.
    func testAnInjectorWithNoOptionsStillDrawsTheInputBar() throws {
        let spy = SpyInjector()
        spy.typeDraft(["some draft"])
        XCTAssertTrue(try XCTUnwrap(spy.readViewport()).contains("❯"))
        XCTAssertNil(ChoiceDialog.locate(labels: ["a"], inViewport: try XCTUnwrap(spy.readViewport())).success)
    }
}

private extension Result {
    var success: Success? { try? get() }
}
```

- [ ] **Step 2: Run and verify they fail** — `value of type 'SpyInjector' has no member 'showOptions'`.

- [ ] **Step 3: Extend the protocol in `Sources/FlightDeck/TextInjecting.swift`**

```swift
    /// Move a full-screen TUI's option list down one row, as a real key event.
    ///
    /// A key event and not text, for exactly the reason `sendReturn()` is one: `sendText` is a
    /// paste, ghostty wraps a paste in bracketed-paste markers, and an escape sequence inside
    /// those markers is inserted as literal *content* rather than acted on. An arrow written
    /// as `ESC [ B` through `sendText` would put five visible characters into a dialog.
    func sendArrowDown()

    /// The same, upwards. Both directions exist because a list's cursor can start below the
    /// target — Claude Code focuses a "(Recommended)" option when it has one — so a driver
    /// that could only go down would wrap or stall.
    func sendArrowUp()

    /// Escape: refuse the dialog outright.
    ///
    /// **This is the whole delivery mechanism for a denial, and it reads nothing.** No
    /// viewport parse, no marker, no row arithmetic, no confirmation pass — one key event.
    /// It is the path a worried person reaches for from a pocket, and it is deliberately the
    /// one path in this feature that cannot be wrong about which row it is on, because it is
    /// not on a row. See `PromptAnswer.deny`.
    func sendEscape()
```

And on the `Ghostty.SurfaceView` extension:

```swift
    func sendArrowDown() { sendBareKey(.arrowDown) }
    func sendArrowUp() { sendBareKey(.arrowUp) }
    func sendEscape() { sendBareKey(.escape) }

    /// No `text:`, deliberately: none of these has a textual form, and ghostty's own key
    /// encoder is what turns the keycode into whatever the running program expects — which
    /// differs by keyboard protocol and is not this file's business to reproduce. Contrast
    /// `sendControl`, which states its byte because there the mapping is the thing worth
    /// reading beside the key.
    private func sendBareKey(_ key: Ghostty.Input.Key) {
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
        /// `+1` down, `-1` up. One case rather than two so a test can assert a run of movement
        /// as a list of numbers.
        case arrow(Int)
        case escape
    }

    /// The option list on screen, when one is up. Empty means the input bar is showing
    /// instead, which is what `renderedRows` models — and which every rename and typed-prompt
    /// test in this suite depends on.
    private(set) var options: [String] = []
    private(set) var selected = 0
    /// After this many arrows, record the event but stop moving the marker — a TUI that
    /// ignored a keystroke, repainted late, or was never the list we thought. `nil` moves for
    /// every arrow.
    var ignoreArrowsAfter: Int?
    private var arrowsSeen = 0

    func sendArrowDown() { move(by: 1) }
    func sendArrowUp() { move(by: -1) }
    func sendEscape() { events.append(.escape) }

    private func move(by step: Int) {
        events.append(.arrow(step))
        arrowsSeen += 1
        guard !options.isEmpty, arrowsSeen <= (ignoreArrowsAfter ?? .max) else { return }
        selected = min(max(selected + step, 0), options.count - 1)
    }

    /// Puts a numbered option list on screen, in the shape claude draws and `ChoiceDialog`
    /// reads. Task 4 replaces this rendering with whatever the captured fixture shows.
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

- [ ] **Step 5: Add the three methods to the two private `SpyInjector`s**

In `CodexResumeTests.swift:277` and `CodexIntegrationTests.swift:477`, add `func sendArrowDown() {}`, `func sendArrowUp() {}`, `func sendEscape() {}`. Nothing else in those files changes.

- [ ] **Step 6: Run and verify they pass** — baseline + 28 cumulative. **Every existing injection test must be unchanged.**

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Drop the `min(max(...))` clamp in `move(by:)` | `testTheMarkerDoesNotRunOffEitherEnd` |
| In `readViewport()`, draw option rows without the `❯`/space prefix | `testAnArrowMovesTheMarkerOnTheModelledScreen` |
| In `sendEscape`, also apply a movement | `testEscapeIsItsOwnEventAndMovesNothing` |
| Delete `events.append(.arrow(step))` | `testTheOrderOfEveryEventIsRecorded` |
| In `readViewport()`, return the option rendering even when `options.isEmpty` | `testAnInjectorWithNoOptionsStillDrawsTheInputBar`, plus **a large number of rename and typed-prompt tests**. If it kills more than about five, that is expected and is what the guard is for — record the count |
| In `Ghostty.SurfaceView.sendBareKey`, send `.press` and no `.release` | **Nothing fails, and cannot** — no test stands on the real surface. Record that; Task 11's manual checklist is the only cover |

- [ ] **Step 8: Verify** — full four scripts.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeck/TextInjecting.swift Tests/FlightDeckTests/SpyInjector.swift \
        Tests/FlightDeckTests/SpyInjectorOptionsTests.swift \
        Tests/FlightDeckTests/CodexResumeTests.swift Tests/FlightDeckTests/CodexIntegrationTests.swift
git commit -m "feat: move a TUI's selection, and refuse a dialog, with real key events"
```

---

## AMENDMENT 2 — the keystroke path is proven, and it left Task 4 a trap

Task 3 shipped and settled the one thing this feature had no evidence for. Against real claude
2.1.241 on a real `Ghostty.SurfaceView`, read in-process through `TextInjecting.readViewport()`:

```
folder trust:    ' ❯ 1. Yes, I trust this folder' → sendArrowDown() → ' ❯ 2. No, exit'
                                                  → sendArrowUp()   → back to row 1
Bash permission: ' ❯ 1. Yes' / '   2. No' → down → ' ❯ 2. No' → up → ' ❯ 1. Yes'
                                          → sendEscape() → no option rows; input bar restored
```

**Escape is a real denial, not merely a dismissal** — the session's transcript closes the call
`is_error=True "The user doesn't want to proceed with this tool use. The tool use was
rejected"`. Nothing in this plan had established that, and it is what makes Deny the safe half.

**A trap for Task 4, from a real screen.** claude echoes the user's own prompt as
`❯ Run this exact bash command …` — **a `❯` at column 1 with no number after it**. Any
`locate` keying on `❯` alone reads that as a focused option and answers the wrong row. Combined
with AMENDMENT 1's finding that options *are* numbered in both dialog kinds, the marker test
must be `❯` **and** a number, never the marker alone.

**Two smaller results, both measurements rather than assumptions.** A press-only key build moves
the dialog identically — libghostty encodes on press under the legacy protocol — so the
release half is for the Kitty protocol and is not load-bearing today; that is now recorded at
`sendBareKey` as a measurement. And `--permission-mode manual` is required to get a dialog at
all: 2.1.241 defaults to `auto` and draws none.

**And a trap in the harness itself, worth more than any of the above.**
`xctest -XCTest FlightDeckTests/SpyInjectorOptionsTests` — the xcodebuild spelling of a filter —
**runs zero tests and reports success**. A mutation verified through that filter would produce
no failures and be believed. Every mutation result in this plan must be reported with the
executed test count beside it.

---

## AMENDMENT — the captures landed, and they refute three of Task 4's premises

Real dialogs were captured before this task was executed, from claude 2.1.241, and committed
under `Tests/FlightDeckTests/Fixtures/Claude/` with `dialogs.captured.provenance.json`. The
capture route is recorded there: `Ghostty.SurfaceView.accessibilityValue()` and
`TextInjecting.readViewport()` return the **same** `CachedValue<String>`, so an out-of-process
accessibility read is byte-for-byte what an in-app parser sees.

**Task 4 must be rewritten against those fixtures, not executed as written.** What the captures
settled:

- **`❯` marks the focused row — CONFIRMED.** But its column varies by dialog kind (column 2 for
  a permission, column 1 for a question); claude positions with absolute column moves
  (`ESC[2G❯ESC[4G1.ESC[7GYes`). A parser pinned to one indent reads only one kind.
- **Options are numbered — CONFIRMED, and further than assumed: `AskUserQuestion` options are
  numbered too.** `locate` as specified does not strip a leading `N. `, so **it returns
  `.noDialog` for every real question**. This alone is the silent-never-works outcome this
  capture existed to catch, and it was found before a line of the parser was written.
- **A description inline on a permission option — REFUTED.** A Bash permission in 2.1.241
  offers **two** options, not three, and no "don't ask again for X in Y" row appeared at all.
  Option labels *are* byte-identical to the transcript's, same session, in the committed
  `.jsonl` — so the cross-check the answer path relies on holds.
- **`Space to toggle, Enter to confirm, a to select all` — REFUTED, and instructively.** That
  string occurs once in the claude binary, between `bun upgrade --stable` and
  `missing package.json`: it is **Bun's** prompt, statically linked in. It describes no dialog
  claude draws. The real footer is `Enter to select · ↑/↓ to navigate · Esc to cancel`. Reading
  behaviour out of a binary's string table attributes other programs' strings to this one.
- **Labels wrap at narrow widths; they do not elide.** No ellipsis appears anywhere in the
  captures, so the `matchPrefix`/truncation premise has nothing behind it — and the
  FOLLOWUPS entry about approving a grant off a truncated label does not apply as written.
- The question sits directly above the options for permission and question dialogs, but **not**
  for folder-trust, where the adjacent line is ` Security guide`.
- Every permission frame ends `ESC ] 777 ; notify ; Claude Code ; Claude needs your permission
  BEL`, which is worth considering as the detector.

**Still uncaptured, so still unproven:** a moved cursor (needs a keystroke; the accessibility
grant lapsed mid-capture, so `sendArrowDown` has *zero* evidence behind it), a durable
"don't ask again" grant, a truncated label, and a multi-question `questions[]`.

---

## Task 4: `ChoiceDialog.locate` — against a captured screen

**Files:**
- Create: `Sources/FlightDeck/ChoiceDialog.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Claude/dialog-permission.captured.txt`
- Create: `Tests/FlightDeckTests/Fixtures/Claude/dialog-question.captured.txt`
- Create: `Tests/FlightDeckTests/Fixtures/Claude/dialogs.captured.provenance.json`
- Modify: `Tests/FlightDeckTests/TimelineFixtureTests.swift` (a `text(_:in:)` loader and a checksum assertion)
- Test: `Tests/FlightDeckTests/ChoiceDialogTests.swift`

**Interfaces:**
- Produces:
  - `enum ChoiceDialog.Failure: Error, Equatable { case noDialog, noSelection, ambiguous }`
  - `static func ChoiceDialog.locate(labels: [String], inViewport: String) -> Result<Int, Failure>`
  - `static func ChoiceDialog.rowCount(inViewport: String) -> Int?` — used only by `.allow`
  - `static let ChoiceDialog.marker: Character`, `.matchPrefix: Int`
  - `static func TimelineFixtureTests.text(_ name: String, in directory: String) throws -> String`

> **This is the task carrying the most risk in the plan, and its ordering is unusual because of that.** A capture of real Claude Code dialogs is being made from a live harness; the fixtures below are **verbatim captured viewport text**, not authored. Step 1 is therefore *read the capture*, and it comes before any parser exists.

- [ ] **Step 1: Read the capture before writing a line of the parser**

The capture lands as `dialog-permission.captured.txt` and `dialog-question.captured.txt` under `Tests/FlightDeckTests/Fixtures/Claude/`, with `dialogs.captured.provenance.json` beside them. **Open them and check the parser's three assumptions against what is actually there, before Step 3:**

1. **`❯` (U+276F) marks the focused row**, and unfocused rows are prefixed with spaces of the same width. `InputBar` already keys on this glyph for the input box, so the codebase has one prior for it — but a dialog is a different component and may use a different marker (`>`, `●`, `▸`) or reverse video, which `ghostty_surface_read_text` does not return at all.
2. **Option labels appear verbatim on their own line**, so a known label can be found by prefix. Check what truncation looks like — `…`, `...`, or a hard cut with nothing.
3. **The permission dialog's rows are ordered allow-first, refuse-last**, and the first row is the plain "Yes". This is what `.allow` targets and it is stated in `SessionStore.answerPrompt` as an assumption.

**If the capture disagrees with any of the three, rewrite the parser to match the capture — never the fixture to match the parser.** Record what you found in the task report either way, and if assumption 3 is wrong, say so loudly: `.allow` targeting the first row is a security-relevant claim and Task 6's code comment asserts it.

If the capture shows the viewport cannot be read while a dialog is up at all — an alternate screen buffer, an empty read — **stop and escalate**. That is a different feature and the coordinator has said they will handle it.

- [ ] **Step 2: Write the failing tests**

`Tests/FlightDeckTests/ChoiceDialogTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Finding a known option on a terminal screen.
///
/// **Two of these fixtures are captured, not authored** — `dialog-permission.captured.txt` and
/// `dialog-question.captured.txt` are verbatim `readViewport()` output from a live Claude Code
/// dialog; see `dialogs.captured.provenance.json` for the recipe and the checksums. The rest
/// are hand-written degenerate cases the capture cannot produce on demand: a screen with no
/// marker, a screen with two, labels that collide.
///
/// The bias throughout is refusal. A wrong answer here becomes a keystroke in someone's live
/// terminal, so every path returns a `.failure` rather than a best guess, and
/// `SessionStore.choose` re-reads and re-locates after moving before it will press Return.
final class ChoiceDialogTests: XCTestCase {
    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    /// The labels in `dialog-question.captured.txt`, as the capture recipe asked for them.
    /// If the capture is remade with different wording, these change with it — they are the
    /// ground truth the parser is checked against, not an independent claim.
    private let questionLabels = ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing"]
    private let permissionLabels = [
        "Yes",
        "Yes, and don't ask again for Bash commands in /Users/nate",
        "No, and tell Claude what to do differently",
    ]

    // MARK: Against the captures

    func testAKnownQuestionsOptionsAreLocatedOnARealScreen() throws {
        let located = ChoiceDialog.locate(
            labels: questionLabels, inViewport: try captured("dialog-question.captured")
        )
        XCTAssertEqual(located, .success(0), "a fresh dialog focuses its first row")
    }

    func testAPermissionDialogsOptionsAreLocatedOnARealScreen() throws {
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: permissionLabels, inViewport: try captured("dialog-permission.captured")
            ),
            .success(0)
        )
    }

    /// **The claim `SessionStore.answerPrompt`'s `.allow` arm rests on**, asserted here rather
    /// than assumed there: a permission dialog has a row count this build can read, and Allow
    /// means row 0. If the capture shows a different ordering, this test is where that is
    /// discovered and `.allow` must be rewritten.
    func testAPermissionDialogsRowCountIsReadable() throws {
        XCTAssertEqual(
            ChoiceDialog.rowCount(inViewport: try captured("dialog-permission.captured")),
            permissionLabels.count
        )
    }

    /// Labels that are not on the screen at all — the case that arises constantly, because
    /// this is asked on every answer of a dialog that may already be gone.
    func testLabelsFromADifferentDialogAreRefused() throws {
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: ["Something else entirely", "And another"],
                inViewport: try captured("dialog-question.captured")
            ),
            .failure(.noDialog)
        )
    }

    // MARK: Degenerate screens the capture cannot produce

    private func viewport(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    /// Terminal width truncates a long label, so an exact match would refuse every real dialog
    /// with a sentence in it — and `AskUserQuestion`'s descriptions run to a line and a half.
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

    /// **The fixture that makes prefix matching safe.** Two labels sharing their visible prefix
    /// are the same row on screen, so the answer is a refusal rather than a coin flip.
    func testTwoLabelsSharingTheirVisiblePrefixAreRefusedRatherThanGuessed() {
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: ["Deploy to production and notify", "Deploy to production and wait"],
                inViewport: viewport(["❯ Deploy to production and…", "  Deploy to production and…"])
            ),
            .failure(.ambiguous)
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

    /// The scrollback holds an echo of an earlier, identical dialog. The LAST occurrence is the
    /// live one — the same rule, and the same reason, as `InputBar.read` taking the last box.
    func testTheLastOccurrenceOfALabelWins() {
        XCTAssertEqual(
            ChoiceDialog.locate(
                labels: ["Yes", "No"],
                inViewport: viewport(["❯ Yes", "  No", "", "  Yes", "❯ No"])
            ),
            .success(1)
        )
    }

    func testAnEmptyViewportIsRefused() {
        XCTAssertEqual(ChoiceDialog.locate(labels: ["Yes"], inViewport: ""), .failure(.noDialog))
        XCTAssertNil(ChoiceDialog.rowCount(inViewport: ""))
    }
}
```

Add to `Tests/FlightDeckTests/TimelineFixtureTests.swift`, beside `lines(_:in:)`:

```swift
    /// A captured fixture that is not JSONL — a terminal viewport, verbatim.
    static func text(_ name: String, in directory: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: TimelineFixtureTests.self).url(
                forResource: name, withExtension: "txt", subdirectory: "Fixtures/\(directory)"
            ),
            "Fixtures/\(directory)/\(name).txt not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The dialog captures are checksummed like every other capture, so a semantic edit that
    /// still looks like a terminal screen is caught rather than only a truncation. This is the
    /// only guard against the parser and its fixture being "fixed" together into agreement.
    func testTheDialogCapturesMatchTheirRecordedChecksums() throws {
        let provenance = try Self.provenance("dialogs.captured", in: "Claude")
        let sums = try XCTUnwrap(provenance["sha256"] as? [String: String])
        XCTAssertEqual(provenance["isVerbatimCapturedOutput"] as? Bool, true)
        for (file, expected) in sums {
            let name = String(file.dropLast(".txt".count))
            let data = Data(try Self.text(name, in: "Claude").utf8)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, expected, "\(file) has been edited since it was captured")
        }
    }
```

- [ ] **Step 3: Run and verify they fail** — `cannot find 'ChoiceDialog' in scope`.

- [ ] **Step 4: Create `Sources/FlightDeck/ChoiceDialog.swift`**

**Write this to match what you read in Step 1.** The version below encodes the three assumptions listed there; if the capture disagreed, change this and say so in the report.

```swift
import Foundation

/// Finds a known option on a terminal screen.
///
/// **Narrow on purpose, and it used to be wider.** An earlier draft also parsed a dialog
/// *blind* — inferring the option list from a numbered run of lines — so that a permission
/// prompt's wording could be shipped to the phone. That whole path is gone: nothing about a
/// dialog is transmitted now, so nothing needs to be inferred from the screen. What remains is
/// the one question the terminal driver actually has to answer: **given labels I already know,
/// which row is selected right now?** That is a far smaller claim to make about a screen, and
/// it is checked against a captured one (`dialog-*.captured.txt`).
///
/// The same distrust `InputBar` documents applies one level up. `ghostty_surface_read_text`
/// returns plain text with no cell attributes, so this cannot tell a dialog from a paragraph
/// that happens to contain the same words, and it cannot tell a truncation from a short label.
/// Every rule below is chosen so that being wrong produces a `.failure` rather than a
/// keystroke, and `SessionStore.choose` re-reads and re-locates *after* moving before it will
/// press Return — so a parser wrong in a new way stops at a moved cursor.
///
/// **`.deny` does not come through here at all.** A refusal is one Escape with no read; see
/// `PromptAnswer.deny`.
enum ChoiceDialog {
    enum Failure: Error, Equatable {
        /// The labels are not on this screen. The ordinary outcome when the dialog has moved
        /// on, and the reason `answerPrompt` refuses rather than guessing.
        case noDialog
        /// They are, and none is marked. A list with no cursor cannot be moved from.
        case noSelection
        /// Two rows are indistinguishable, or two are marked. Either way there is no answer
        /// that is not a guess.
        case ambiguous
    }

    /// U+276F, the marker Claude Code draws on the focused row.
    ///
    /// The same glyph `InputBar` keys on — which is precisely why that type must never be
    /// pointed at a dialog: it would read the selected option as a draft and Ctrl-U it.
    /// Verified against `dialog-permission.captured.txt`; if a future Claude Code changes it,
    /// that fixture is what fails first.
    static let marker: Character = "❯"

    /// How many characters of a label must match for a row to be that label.
    ///
    /// A prefix, because a terminal truncates; a *bounded* prefix, because the comparison has
    /// to be symmetric across the two reads `choose` makes. Long enough that two real options
    /// rarely collide, short enough to survive an 80-column window. `locate` refuses when two
    /// labels do collide, which keeps this number a tuning choice rather than a correctness one.
    static let matchPrefix = 24

    /// Which of `labels` is selected on this screen.
    static func locate(labels: [String], inViewport viewport: String) -> Result<Int, Failure> {
        let keys = labels.map(key(of:))
        guard !keys.isEmpty, !keys.contains(where: \.isEmpty) else { return .failure(.noDialog) }
        guard Set(keys).count == keys.count else { return .failure(.ambiguous) }

        var found: [Int: Bool] = [:]     // label index → is this the marked row
        for line in viewport.components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let isSelected = trimmed.first == marker
            let content = key(of: String(trimmed.drop(while: { $0 == " " || $0 == marker })))
            guard !content.isEmpty else { continue }
            for (index, expected) in keys.enumerated() where content.hasPrefix(expected) {
                // The LAST occurrence wins: a label can appear both in the live dialog and in
                // a scrollback echo of an earlier one above it. Same rule, same reason, as
                // `InputBar.read` locking onto the last box.
                found[index] = isSelected
            }
        }
        guard found.count == labels.count else { return .failure(.noDialog) }
        let marked = found.filter(\.value).keys
        guard marked.count <= 1 else { return .failure(.ambiguous) }
        guard let selected = marked.first else { return .failure(.noSelection) }
        return .success(selected)
    }

    /// How many rows the dialog on screen has, or nil when none can be found.
    ///
    /// **Used by `.allow` and by nothing else**, because that is the one case with no labels to
    /// check against: a permission dialog's wording is built in the TUI and exists nowhere
    /// Flight Deck reads. It counts the run of lines that carry the marker or its blank
    /// equivalent at the same indent — a much weaker signal than a known label, which is why
    /// `.allow` also re-reads and confirms before Return, and why `.deny` avoids this entirely.
    static func rowCount(inViewport viewport: String) -> Int? {
        var run = 0
        var best = 0
        for line in viewport.components(separatedBy: "\n") {
            if isRow(line) {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        // One row is not a list. Two is the floor for anything worth a choice.
        return best >= 2 ? best : nil
    }

    /// A row of a select list: `❯ …` or `  …` with content after it.
    private static func isRow(_ line: String) -> Bool {
        guard line.hasPrefix("\(marker) ") || line.hasPrefix("  ") else { return false }
        return !line.drop(while: { $0 == " " || $0 == marker }).isEmpty
    }

    /// What two strings are compared as: the first `matchPrefix` characters, whitespace
    /// normalized, with a trailing ellipsis stripped.
    ///
    /// The ellipsis matters. A truncated row ends `…` (or `...`), and comparing that against
    /// the label's own characters at the same position fails on exactly the rows truncation
    /// affects — which is to say, on the long ones this rule exists for.
    private static func key(of text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\u{a0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("…") || normalized.hasSuffix(".") { normalized.removeLast() }
        return String(normalized.prefix(matchPrefix))
    }
}
```

- [ ] **Step 5: Write the provenance file**

`Tests/FlightDeckTests/Fixtures/Claude/dialogs.captured.provenance.json`, following the shape of `transcript.captured.provenance.json` exactly:

```json
{
  "files": ["dialog-permission.captured.txt", "dialog-question.captured.txt"],
  "isVerbatimCapturedOutput": true,
  "claudeVersion": "<fill from the capture harness>",
  "capturedOn": "2026-08-23",
  "sha256": {
    "dialog-permission.captured.txt": "<fill>",
    "dialog-question.captured.txt": "<fill>"
  },
  "capturedBy": [
    "`TextInjecting.readViewport()` on a live Flight Deck tab, with a Claude Code dialog on",
    "screen, written out verbatim. Two captures:",
    "",
    "  dialog-permission — a Bash permission prompt, raised by asking claude to run a command",
    "                      outside the allow-list, captured while the dialog was up.",
    "  dialog-question   — an AskUserQuestion with three single-select options, captured the",
    "                      same way. The option labels are the ones ChoiceDialogTests names.",
    "",
    "A multi-select capture was attempted and is recorded here whether or not it succeeded;",
    "nothing in this plan drives one, so its absence costs no coverage."
  ],
  "editingRule": [
    "Lines may be DROPPED, never EDITED. The sha256 above is of each file as committed and",
    "TimelineFixtureTests asserts it, so an edit that still looks like a terminal screen is",
    "caught rather than only a truncation. That guard exists for one specific failure: a",
    "parser and its fixture being 'fixed' together into agreement about a screen neither",
    "matches.",
    "",
    "If a future Claude Code changes the selection marker, the row layout, or the ordering of",
    "a permission dialog's options, these files are what fail first — and the correct response",
    "is a fresh capture and a rewritten parser, never an edited fixture.",
    "",
    "Every fixture in Fixtures/ MUST be named *.captured.* to signal that it is verbatim",
    "captured output, not authored."
  ]
}
```

- [ ] **Step 6: Run and verify they pass** — baseline + 39 cumulative.

- [ ] **Step 7: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Change `marker` to `">"` | Both captured-fixture tests (`…LocatedOnARealScreen`) — **this is the single most valuable row here**, because it is what says the captures actually exercise the marker rule rather than passing by coincidence |
| Delete `guard Set(keys).count == keys.count` | `testTwoLabelsSharingTheirVisiblePrefix…` |
| Change `marked.count <= 1` to `>= 1` | `testTwoMarkedRowsAreRefused` |
| In `key(of:)`, stop stripping the ellipsis | `testATruncatedLabelIsStillLocated` |
| In the inner loop, `if found[index] == nil { found[index] = isSelected }` (first occurrence wins) | `testTheLastOccurrenceOfALabelWins` |
| Change `guard found.count == labels.count` to `found.count >= 1` | `testLabelsFromADifferentDialogAreRefused` — **check it**: those labels match nothing, so `found` is empty and both versions refuse. If the mutation is a no-op, change that fixture to labels where **one** matches and one does not, which is the real partial-match hazard |
| In `rowCount`, `best >= 1` instead of `>= 2` | **No current test fails.** Add `testASingleRowIsNotAList` with viewport `["❯ Continue"]` before relying on this row |
| Hand-edit one character of `dialog-question.captured.txt` | `testTheDialogCapturesMatchTheirRecordedChecksums` |

- [ ] **Step 8: Verify** — full four scripts, and confirm the two `.txt` files land in the test bundle (`Fixtures/` is a folder reference; a file that fails to copy shows up as the loader's `XCTUnwrap` message, which is why that message names the path).

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeck/ChoiceDialog.swift Tests/FlightDeckTests/ChoiceDialogTests.swift \
        Tests/FlightDeckTests/TimelineFixtureTests.swift Tests/FlightDeckTests/Fixtures/Claude/
git commit -m "feat: find a known option on a real terminal screen, and refuse otherwise"
```

---

## Task 5: `ClaudeOpenCall` — the Mac's half of the same rule

**Files:**
- Create: `Sources/FlightDeck/Agents/ClaudeOpenCall.swift`
- Test: `Tests/FlightDeckTests/ClaudeOpenCallTests.swift`

**Interfaces:**
- Consumes: `SourceLine` (`Sources/FlightDeck/Timeline/TranscriptPager.swift:11`), `ClaudeTimelineMapper.items(inLine:at:)`, `OpenPrompt.find(in:activity:)` (Task 1)
- Produces: `enum ClaudeOpenCall { static func find(in lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? }`

> **The Mac derives the open call by mapping its tail through the same `ClaudeTimelineMapper` the phone's page went through, then running the same `OpenPrompt.find`.** That is the point: two derivations of one rule over one file, with the mapper as the only thing between the bytes and the answer on both sides. A second, hand-written record walker here would be a second rule, and a second rule is how the Mac types an answer at a dialog the phone was not looking at.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/ClaudeOpenCallTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// The Mac's derivation, and the property that matters most: **it is the phone's derivation.**
/// Both sides map transcript lines with `ClaudeTimelineMapper` and then run
/// `OpenPrompt.find`; nothing here re-implements the pairing rule, and a test that this file
/// agrees with `OpenPromptTests` on the same records is the guard against it drifting.
final class ClaudeOpenCallTests: XCTestCase {
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

    private func bash(_ id: String, command: String = "ls") -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"\(command)"}}]}}
        """
    }

    private func answer(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    func testAnOpenAskIsAQuestion() throws {
        guard case .question("toolu_A", let question)? =
            ClaudeOpenCall.find(in: [line(0, ask("toolu_A"))], activity: .waiting)
        else { return XCTFail("expected a question") }
        XCTAssertEqual(question.question, "Which?")
        XCTAssertEqual(question.options.map(\.label), ["a", "b"])
    }

    func testAnOpenBashIsAPermissionRequest() {
        XCTAssertEqual(
            ClaudeOpenCall.find(in: [line(0, bash("toolu_B", command: "rm -rf build"))],
                                activity: .waiting),
            .permission(callID: "toolu_B", tool: "Bash", summary: "rm -rf build")
        )
    }

    /// The fixture that distinguishes the failure: an answered call and an open one, with
    /// different tools AND different ids, so the assertion catches either mistake.
    func testAnAnsweredCallIsSkippedAndTheOpenOneIsFound() {
        let lines = [
            line(0, ask("toolu_OLD", question: "Old?")),
            line(100, answer("toolu_OLD")),
            line(200, bash("toolu_NEW")),
        ]
        XCTAssertEqual(ClaudeOpenCall.find(in: lines, activity: .waiting)?.callID, "toolu_NEW")
    }

    func testEverythingAnsweredIsNoOpenCall() {
        XCTAssertNil(
            ClaudeOpenCall.find(in: [line(0, ask("toolu_A")), line(100, answer("toolu_A"))],
                                activity: .waiting)
        )
    }

    /// **`activity` is carried through and is not optional.** An unanswered `Bash` on a busy
    /// session is a command that is running, and answering "Allow" at it would press Return
    /// into a live input bar.
    func testAnOpenCallOnANonWaitingSessionIsNotOpen() {
        for activity: SessionActivity? in [.idle, .busy, .shell, nil] {
            XCTAssertNil(
                ClaudeOpenCall.find(in: [line(0, bash("toolu_B"))], activity: activity),
                "\(String(describing: activity)) must not produce an open call"
            )
        }
    }

    /// Sidechain records are dropped by the mapper before this sees them, which is the reason
    /// the mapper is in the path rather than a bespoke walker: a sub-agent's question is not
    /// the one the person in front of this tab is being asked, and that rule already exists in
    /// exactly one place.
    func testASidechainQuestionIsNotThisTabsQuestion() {
        let sidechain = ask("toolu_S")
            .replacingOccurrences(of: #""type":"assistant""#,
                                  with: #""type":"assistant","isSidechain":true"#)
        XCTAssertNil(ClaudeOpenCall.find(in: [line(0, sidechain)], activity: .waiting))
    }

    func testAMalformedLineIsSkippedRatherThanFailingTheWholeTail() {
        XCTAssertEqual(
            ClaudeOpenCall.find(in: [line(0, "{not json"), line(20, ask("toolu_A"))],
                                activity: .waiting)?.callID,
            "toolu_A"
        )
    }

    /// The offsets a mapper needs are the lines' own, so a tail read from the middle of a file
    /// produces the same answer as one from the start. Nothing here depends on an id's value,
    /// only on their order — and this asserts the order survives a non-zero base offset.
    func testATailStartingPartwayThroughAFileStillOrdersCorrectly() {
        let lines = [
            line(90_000, bash("toolu_OLD")),
            line(90_500, answer("toolu_OLD")),
            line(91_000, ask("toolu_NEW")),
        ]
        XCTAssertEqual(ClaudeOpenCall.find(in: lines, activity: .waiting)?.callID, "toolu_NEW")
    }
}
```

- [ ] **Step 2: Run and verify they fail** — `cannot find 'ClaudeOpenCall' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeck/Agents/ClaudeOpenCall.swift`**

```swift
import FleetKit
import Foundation

/// What a claude session is blocked on, derived on the Mac from a window of its transcript.
///
/// **Deliberately the phone's derivation and not a second one.** The lines are mapped with
/// `ClaudeTimelineMapper` — the same mapper whose output the phone receives as a page — and
/// then handed to `OpenPrompt.find`, the same function the phone runs over its feed. Nothing
/// here re-implements the call/result pairing or the question parse. Two implementations of
/// one rule is how the Mac ends up typing an answer at a dialog the phone was not looking at,
/// which is the specific failure this whole feature has to not have.
///
/// **The window is a tail, and that is exact rather than a shortcut.** Claude cannot proceed
/// past a dialog, so the open call is always among the last records; a read of a handful of
/// them either finds it or proves there is none. A few rather than one, so that a
/// `tool_result` for an *earlier* call is in the window and cannot make an already-answered
/// call look open — the only way this can be wrong in the dangerous direction.
enum ClaudeOpenCall {
    static func find(in lines: [SourceLine], activity: SessionActivity?) -> OpenPrompt? {
        let items = lines.flatMap { ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset) }
        return OpenPrompt.find(in: items, activity: activity?.rawValue)
    }
}
```

- [ ] **Step 4: Run and verify they pass** — baseline + 47 cumulative.

> If `testAnOpenAskIsAQuestion` fails with `.permission(callID: "toolu_A", tool: "AskUserQuestion", …)`, that is Task 9 not being done yet: the mapper still emits `.toolCall` for `AskUserQuestion`. **Do not work around it here.** Either move Task 9 ahead of this one, or mark that single test `XCTSkip` with the reason and un-skip it in Task 9 — and say which you did in the report.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Pass `activity?.rawValue` as a literal `"waiting"` | `testAnOpenCallOnANonWaitingSessionIsNotOpen` |
| Reverse `lines` before mapping | `testAnAnsweredCallIsSkippedAndTheOpenOneIsFound` and `testATailStartingPartwayThrough…` — **check both**: `OpenPrompt.find` iterates `items.reversed()`, so reversing the input reverses the answer, and the differing tools in those fixtures are what make it visible |
| Map with `$0.text` and a constant offset of 0 | **No test fails**, because `OpenPrompt.find` uses array order and not the id. That is a real finding about the coupling — record it, and note that `TimelineItem.id` uniqueness within a tail is relied on by nothing here |
| Filter to `item.kind == .prompt` before calling `find` | `testAnOpenBashIsAPermissionRequest` |
| Write a bespoke record walker instead of using the mapper | Not a mutation — but if you are tempted, `testASidechainQuestionIsNotThisTabsQuestion` is the test that will pass in your walker and fail in production, because the sidechain rule lives in the mapper |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeOpenCall.swift \
        Tests/FlightDeckTests/ClaudeOpenCallTests.swift
git commit -m "feat: the Mac derives the open call with the phone's own rule"
```

---

## Task 6: `SessionStore.answerPrompt` — the funnel that presses Return, and the one that does not

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (new section after `submitPrompt`'s, ~line 2960; `viewport(of:)` beside `status(for:)` at ~3129; `holdInjectionForTesting` beside `flushPendingResumePromptsForTesting` at ~2583; `answeredPromptTokens` cleanup in `closeSession` ~2113)
- Test: `Tests/FlightDeckTests/AnswerPromptTests.swift`

**Interfaces:**
- Consumes: `ChoiceDialog.locate(labels:inViewport:)`, `ChoiceDialog.rowCount(inViewport:)` (Task 4), `TextInjecting.sendArrowDown/Up/Escape` (Task 3), `OpenPrompt`, `PromptAnswer` (Tasks 1-2), `SessionStore.injectionSettle`, `.injecting`, `.now`
- Produces:
  - `enum SessionStore.AnswerDispatch: Equatable { case dispatched, duplicate, unknownSession, unsupportedAgent, notWaiting, unanswerable, unreadableScreen; var errorCode: String? }`
  - `func SessionStore.answerPrompt(_ open: OpenPrompt, with answer: PromptAnswer, in id: UUID, token: UUID) -> AnswerDispatch`
  - `func SessionStore.viewport(of id: UUID) -> String?`
  - `func SessionStore.holdInjectionForTesting(_ id: UUID)`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/AnswerPromptTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Answering a dialog by driving the terminal.
///
/// **The ORDER of the events is the contract**, exactly as it is for `inject`: arrows first,
/// screen re-read, Return only if the marker landed where it was sent. A test asserting only
/// "Return was pressed" would pass against a driver that pressed it blind, which is the failure
/// mode with someone's `rm -rf` on the other side.
@MainActor
final class AnswerPromptTests: XCTestCase {
    // `makeStore` / `makeCodexStore`: one tab of the given agent, an `injectorOverride`, a
    // status, and a synchronous `injectionSettle`. Lift the helper from
    // `PhonePromptDispatchTests` rather than rewriting it; if it is private there, make it
    // internal in this same commit.

    private func question(labels: [String], unanswerable: String? = nil) -> OpenPrompt {
        .question(callID: "toolu_A", PromptQuestion(
            header: "Pick", question: "Which?",
            options: labels.map { .init(label: $0) }, unanswerable: unanswerable
        ))
    }

    private var permission: OpenPrompt {
        .permission(callID: "toolu_B", tool: "Bash", summary: "rm -rf build")
    }

    // MARK: option — an AskUserQuestion

    func testChoosingTheRowBelowSendsOneArrowThenReturn() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testChoosingTheRowAlreadySelectedSendsReturnAndNoArrows() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(question(labels: ["Yes", "No"]),
                           with: .option(index: 0, label: "Yes"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.ret])
    }

    func testChoosingARowAboveSendsUpArrows() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 2)
        store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                           with: .option(index: 0, label: "Yes"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1), .ret])
    }

    /// **The test this whole funnel exists for.** The fake stops moving after one row —
    /// modelling a TUI that dropped a keystroke, repainted late, or was never the list we
    /// thought — and the driver must send nothing further. A moved cursor is recoverable by
    /// the person at the keyboard; a Return on the wrong row is not.
    func testReturnIsNotPressedWhenTheMarkerDidNotLandOnTheChosenRow() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 1
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No", "Maybe"]),
                               with: .option(index: 2, label: "Maybe"), in: id, token: UUID()),
            .dispatched, "dispatched; whether it landed is a later fact"
        )
        XCTAssertFalse(spy.events.contains(.ret), "no Return on an unconfirmed selection")
    }

    /// The label is a cross-check on the Mac's own copy, not an instruction. A client naming
    /// words the Mac never drew is a reader looking at something else.
    func testAnOptionWhoseLabelDisagreesWithTheMacsCopyIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "Absolutely"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnIndexOutsideTheOptionsIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 7, label: "Yes"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnanswerableQuestionIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["a", "b"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(
                question(labels: ["a", "b"], unanswerable: PromptQuestion.multiSelectReason),
                with: .option(index: 0, label: "a"), in: id, token: UUID()
            ),
            .unanswerable
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A screen showing a different dialog than the one derived. Nothing sent — the second
    /// half of the racing guard, below `PromptService`'s re-derivation.
    func testADialogThatIsNoLongerOnScreenIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Something else entirely", "And another"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    // MARK: deny — one Escape, no read

    /// **The property, asserted rather than described.** A denial reads nothing off the screen,
    /// so it works on a screen that cannot be read at all — which is exactly the state a person
    /// is in when they want to refuse something and the terminal is mid-repaint.
    func testDenyIsOneEscapeAndReadsNothing() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.escape])
    }

    func testDenyWorksForAQuestionToo() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(question(labels: ["Yes", "No"]), with: .deny, in: id, token: UUID())
        XCTAssertEqual(spy.events, [.escape])
    }

    // MARK: allow — the first row

    func testAllowMovesToTheFirstRowAndReturns() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "Yes, and don't ask again", "No"], selected: 2)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .dispatched
        )
        XCTAssertEqual(spy.events, [.arrow(-1), .arrow(-1), .ret])
    }

    /// **The security property, as a test.** There is no answer that reaches row 1 — the
    /// "don't ask again" row — and this asserts it from the outside: `.allow` on a three-row
    /// dialog leaves the marker at row 0, never row 1.
    func testNoAnswerCanReachTheDontAskAgainRow() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "Yes, and don't ask again", "No"], selected: 0)
        store.answerPrompt(permission, with: .allow, in: id, token: UUID())
        XCTAssertEqual(spy.selected, 0)
        XCTAssertEqual(spy.events, [.ret])
    }

    func testAllowOnAScreenWithNoReadableDialogIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.viewportIsReadable = false
        XCTAssertEqual(
            store.answerPrompt(permission, with: .allow, in: id, token: UUID()), .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    // MARK: The gates

    /// **`inject`'s gate, inverted, and the inversion is the point.** An idle session has no
    /// dialog up, and a Return there submits whatever is in the input bar.
    func testANonWaitingSessionIsRefused() {
        for activity in [SessionActivity.idle, .busy, .shell] {
            let (store, spy, id) = makeStore(activity: activity)
            spy.showOptions(["Yes"], selected: 0)
            XCTAssertEqual(
                store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .notWaiting
            )
            XCTAssertTrue(spy.events.isEmpty, "\(activity) must send nothing, not even Escape")
        }
    }

    /// A codex tab that is ALSO waiting — so a store checking status first would get past the
    /// gate and reach the injector.
    func testACodexTabIsRefusedBeforeItsStatusIsConsulted() {
        let (store, spy, id) = makeCodexStore(activity: .waiting)
        spy.showOptions(["Yes"], selected: 0)
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: UUID()), .unsupportedAgent
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The same token twice, with the screen reset between, so a store that forgot the token
    /// would send a second Escape.
    func testTheSameTokenTwiceAnswersOnce() {
        let (store, spy, id) = makeStore(activity: .waiting)
        let token = UUID()
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: token), .dispatched
        )
        let before = spy.events.count
        XCTAssertEqual(
            store.answerPrompt(permission, with: .deny, in: id, token: token), .duplicate
        )
        XCTAssertEqual(spy.events.count, before, "a repeat types nothing")
    }

    /// A rename or a queued phone prompt mid-settle must not interleave with this. Both use
    /// the same `injecting` set; this asserts the shared gate rather than trusting it.
    func testATabAlreadyInjectingIsRefused() {
        let (store, spy, id) = makeStore(activity: .waiting)
        spy.showOptions(["Yes", "No"], selected: 0)
        store.holdInjectionForTesting(id)
        XCTAssertEqual(
            store.answerPrompt(question(labels: ["Yes", "No"]),
                               with: .option(index: 1, label: "No"), in: id, token: UUID()),
            .unreadableScreen
        )
        XCTAssertTrue(spy.events.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify they fail** — `value of type 'SessionStore' has no member 'answerPrompt'`.

- [ ] **Step 3: Add `viewport(of:)` beside `status(for:)` (~3129)**

```swift
    /// The tab's terminal screen, or nil when there is no surface or it cannot be read.
    ///
    /// A read and only a read: it changes no fleet state and adds no mutation site for
    /// `FleetReplicator`'s DEBUG drift check.
    func viewport(of id: UUID) -> String? { injector(for: id)?.readViewport() }
```

- [ ] **Step 4: Add the answer section after `submitPrompt`'s**

```swift
    // MARK: - Answering a dialog from a paired phone

    /// What a client's answer did.
    ///
    /// **`dispatched` is the ceiling, and that is honest rather than lazy.** The option and
    /// allow paths act across `injectionSettle` — move, wait for claude to repaint, re-read,
    /// then Return — so whether the answer LANDED is not knowable when this returns. §4's rule
    /// is the same one: `ack` means dispatched, and the observable effect arrives separately.
    /// Here it arrives twice over — the session stops being `waiting`, which the phone is
    /// pushed, and the transcript grows a `tool_result`, which the phone's next fetch reads.
    ///
    /// Everything knowable BEFORE the settle is a distinct refusal, because each sends the
    /// reader somewhere different.
    enum AnswerDispatch: Equatable {
        /// Accepted, and the driver has started. `ack`.
        case dispatched
        /// This token has already been answered for this tab. `ack`, because from the client's
        /// side a retry that lands is an answer that landed.
        case duplicate
        case unknownSession
        /// This tab's agent has no dialog Flight Deck can drive. Codex, and anything newer.
        case unsupportedAgent
        /// Nothing is blocked on this tab right now.
        case notWaiting
        /// A shape this build will not drive — see `PromptQuestion.unanswerable`.
        case unanswerable
        /// The terminal could not be read, the dialog was not on it, the index or the label
        /// named nothing, or another injection is already resolving for this tab.
        ///
        /// **One code for five states deliberately.** Every one means "not right now, and the
        /// phone should look again", and splitting them would invite a client to treat some as
        /// permanent and stop asking. The distinctions are worth a log line, not a wire code.
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
    /// reasoning as `acceptedPromptTokens` — see it for why a retry has to be free. A separate
    /// list, because a typed prompt's token and an answer's token are minted by different taps
    /// and a shared list would let one silence the other.
    private var answeredPromptTokens: [UUID: [UUID]] = [:]

    /// A client answered the dialog tab `id` is blocked on.
    ///
    /// `open` is the Mac's **own** derivation, from `PromptService`, never the client's claim.
    /// The command from the phone contributes a tab, a call id (already checked against this
    /// derivation by the caller), an intent, and a token. Nothing a phone sends becomes a label
    /// matched on screen. That is the difference between a remote control and a remote keyboard.
    ///
    /// **The order of the checks is load-bearing twice**, as `submitPrompt`'s is. The agent
    /// test precedes the status test, so a codex tab that happens to be `waiting` is told
    /// `unsupportedAgent` — never on this tab — rather than being let through to a terminal
    /// whose dialogs this build has never read. And the token test precedes anything being
    /// typed, so a retry types nothing even if the screen has moved on.
    ///
    /// Changes no fleet state and emits no `FleetEvent`: what the phone answered becomes
    /// visible through the status the agent writes and the transcript it appends.
    @discardableResult
    func answerPrompt(
        _ open: OpenPrompt, with answer: PromptAnswer, in id: UUID, token: UUID
    ) -> AnswerDispatch {
        guard let at = locate(id) else { return .unknownSession }
        guard repos[at.repo].sessions[at.session].agent == .claude else {
            return .unsupportedAgent
        }
        if answeredPromptTokens[id, default: []].contains(token) { return .duplicate }
        // `inject`'s gate, inverted. A session that is not `waiting` has no dialog up, and a
        // Return there submits whatever is in the input bar — the exact failure `inject`'s own
        // comment describes from the other side. Escape is gated too: a stray Escape into a
        // live TUI is not free either.
        guard statuses[id]?.activity == .waiting else { return .notWaiting }
        guard let injector = injector(for: id) else { return .unreadableScreen }
        // The same set the other two users of this terminal hold, so a rename or a queued
        // phone prompt mid-settle cannot interleave with a dialog being driven.
        guard !injecting.contains(id) else { return .unreadableScreen }

        switch answer {
        case .deny:
            // **One key event, and nothing is read.** No viewport, no marker, no row
            // arithmetic, no settle, no confirmation pass. This is the path a worried person
            // reaches for, and it is deliberately the one that cannot be wrong about which row
            // it is on. It is also therefore the only answer that works on a screen this build
            // cannot parse at all.
            remember(answered: token, for: id)
            injector.sendEscape()
            return .dispatched

        case .allow:
            // **The first row, and only ever the first row.** Claude's permission dialog is
            // ordered "Yes" / "Yes, and don't ask again for …" / "No, and tell Claude …", so
            // row 0 is the plain approval and the middle rows are DURABLE GRANTS. There is no
            // `PromptAnswer` case that names one and no arithmetic here that can reach one:
            // the target index is the literal 0. See `PromptAnswer`'s own comment.
            //
            // The ordering claim is checked against `dialog-permission.captured.txt` by
            // `ChoiceDialogTests.testAPermissionDialogsRowCountIsReadable` and by the capture's
            // provenance. If a future Claude Code reorders the dialog, that fixture fails
            // first — and this arm must be rewritten, not the fixture.
            guard let viewport = injector.readViewport(),
                  let rows = ChoiceDialog.rowCount(inViewport: viewport)
            else { return .unreadableScreen }
            return drive(
                to: 0, amongRows: rows, currentFrom: { _ in nil },
                confirm: { screen in ChoiceDialog.rowCount(inViewport: screen) == rows },
                injector: injector, id: id, token: token
            )

        case .option(let index, let label):
            guard case .question(_, let question) = open else { return .unreadableScreen }
            guard question.isAnswerable else { return .unanswerable }
            guard question.options.indices.contains(index),
                  question.options[index].label == label
            else { return .unreadableScreen }
            let labels = question.options.map(\.label)
            guard let viewport = injector.readViewport(),
                  case .success(let current) = ChoiceDialog.locate(
                      labels: labels, inViewport: viewport
                  )
            else { return .unreadableScreen }
            return drive(
                to: index, amongRows: labels.count, currentFrom: { _ in current },
                confirm: { screen in
                    ChoiceDialog.locate(labels: labels, inViewport: screen) == .success(index)
                },
                injector: injector, id: id, token: token
            )
        }
    }

    /// Move the selection, wait for the repaint, confirm, and only then submit.
    ///
    /// **Measured, not assumed.** `inject` kills first and compares because the screen cannot
    /// be trusted to say whether the buffer was empty; this moves first and confirms because
    /// the screen cannot be trusted to say whether the keystroke arrived. Same idiom, same
    /// reason, and the consequence of skipping it is a Return on a row nobody chose.
    ///
    /// `currentFrom` returning nil means "the current row is unknown" — the `.allow` case,
    /// which has no labels to locate. There the move is `rows - 1` presses of Up, which is
    /// bounded, idempotent at the top, and lands on row 0 from anywhere: the one movement that
    /// is correct without knowing where it started.
    private func drive(
        to index: Int,
        amongRows rows: Int,
        currentFrom: (String) -> Int?,
        confirm: @escaping (String) -> Bool,
        injector: TextInjecting,
        id: UUID,
        token: UUID
    ) -> AnswerDispatch {
        guard let viewport = injector.readViewport() else { return .unreadableScreen }
        remember(answered: token, for: id)
        injecting.insert(id)

        if let current = currentFrom(viewport) {
            let steps = index - current
            for _ in 0..<abs(steps) {
                if steps > 0 { injector.sendArrowDown() } else { injector.sendArrowUp() }
            }
        } else {
            // Unknown start, known destination: walk to the top. `sendArrowUp` at row 0 is a
            // no-op in every list, so over-pressing is safe and under-pressing is impossible.
            for _ in 0..<max(rows - 1, 0) { injector.sendArrowUp() }
        }

        // Claude Code repaints asynchronously — the same seam, and the same 120ms in
        // production, that a kill waits out.
        injectionSettle { [weak self] in
            defer { self?.injecting.remove(id) }
            guard let screen = injector.readViewport(), confirm(screen) else { return }
            injector.sendReturn()
        }
        return .dispatched
    }

    private func remember(answered token: UUID, for id: UUID) {
        var tokens = answeredPromptTokens[id, default: []]
        tokens.append(token)
        if tokens.count > Self.maxRememberedPromptTokens {
            tokens.removeFirst(tokens.count - Self.maxRememberedPromptTokens)
        }
        answeredPromptTokens[id] = tokens
    }
```

In `closeSession`, beside `promptQueue.removeValue(forKey: id)` (~2113), add `answeredPromptTokens.removeValue(forKey: id)`.

Beside `flushPendingResumePromptsForTesting` (~2583):

```swift
    /// Marks a tab as mid-injection so a test can assert the shared gate refuses a second
    /// driver. There is no production caller and there must not be one.
    func holdInjectionForTesting(_ id: UUID) { injecting.insert(id) }
```

- [ ] **Step 5: Run and verify they pass** — baseline + 64 cumulative.

- [ ] **Step 6: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `drive`'s settle, delete the whole `guard let screen … else { return }` and call `sendReturn()` unconditionally | `testReturnIsNotPressedWhenTheMarkerDidNotLandOnTheChosenRow`. **Do not delete only the guard's body** — `guard` requires an exiting `else`, so a body-only edit will not compile |
| In the `.allow` arm, target `1` instead of `0` | `testNoAnswerCanReachTheDontAskAgainRow` — **the security assertion**, and the row to run first if you change anything in that arm |
| In the `.deny` arm, read the viewport and refuse when it is nil | `testDenyIsOneEscapeAndReadsNothing` |
| Move the `statuses[id]?.activity == .waiting` check above the agent check | `testACodexTabIsRefusedBeforeItsStatusIsConsulted` — that fixture is a codex tab that IS waiting, the only one that distinguishes the order |
| Change `.waiting` to `!= .shell` | `testANonWaitingSessionIsRefused` (the `.idle` and `.busy` iterations) |
| Delete the token check | `testTheSameTokenTwiceAnswersOnce` — **assert the event count, not only the return value**: a mutant that returned `.dispatched` and typed nothing would pass a value-only check |
| In the `.option` arm, drop the `question.options[index].label == label` half | `testAnOptionWhoseLabelDisagreesWithTheMacsCopyIsRefused` |
| In `drive`, use `0..<steps` without `abs()` | `testChoosingARowAboveSendsUpArrows` — a negative range traps; record it as a failure rather than "the test crashed" |
| Delete `guard !injecting.contains(id)` | `testATabAlreadyInjectingIsRefused` |
| In the `.allow` fallback, press Up `rows` times instead of `rows - 1` | **No test fails** — an extra Up at row 0 is a no-op in the fake and in every real list. Record that the bound is deliberately loose in the safe direction |

- [ ] **Step 7: Verify** — full four scripts. Every existing `PhonePromptDispatchTests` and rename test must be untouched.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AnswerPromptTests.swift
git commit -m "feat: answer a dialog by driving the terminal, and deny it with one Escape"
```

---

## Task 7: `PromptService` — re-derive, verify, dispatch

**Files:**
- Create: `Sources/FlightDeck/Fleet/PromptService.swift`
- Test: `Tests/FlightDeckTests/PromptServiceTests.swift`

**Interfaces:**
- Consumes: `SessionStore.timelineSource(of:)`, `.status(for:)`, `.answerPrompt(_:with:in:token:)`, `TranscriptPager.page(url:anchor:limit:)`, `ClaudeOpenCall.find(in:activity:)`
- Produces:
  - `@MainActor final class PromptService`, `init(store: SessionStore)`
  - `var tail: @Sendable (URL, Int) -> [SourceLine]`
  - `static let PromptService.tailRecords: Int`
  - `func answer(session: UUID, call: String, answer: PromptAnswer, token: UUID) -> Result<Void, TimelineErrorCode>`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/PromptServiceTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// The type that turns "a phone tapped a button" into "the Mac drove its own terminal".
///
/// **Its entire job is the re-derivation**, and that is the property most of this file asserts:
/// the open call is recomputed from the transcript on every answer, and a call that is no
/// longer the newest unanswered one is refused. A cache would be faster and would not close
/// the race this exists for.
@MainActor
final class PromptServiceTests: XCTestCase {
    // `makeService` returns a `PromptService`, its `SessionStore`, the `SpyInjector` behind the
    // tab, and the tab id — the same helper shape `AnswerPromptTests` uses, plus the service.

    private func askLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]}}]}}
        """
    }

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    private func resultLine(_ id: String) -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"\(id)","content":"done"}]}}
        """
    }

    func testAnsweringTheOpenQuestionDrivesTheTerminal() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [SourceLine(offset: 0, text: self.askLine("toolu_A"))] }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(
            service.answer(session: id, call: "toolu_A",
                           answer: .option(index: 1, label: "No"), token: UUID()),
            .success(())
        )
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// **Racing the Mac, the simple case.** The user answered in the terminal, so the call the
    /// phone named now has a result and the newest unanswered call is something else.
    func testAnAnswerToACallThatHasSinceBeenAnsweredIsRefused() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [
            SourceLine(offset: 0, text: self.askLine("toolu_A")),
            SourceLine(offset: 100, text: self.resultLine("toolu_A")),
        ] }
        XCTAssertEqual(
            service.answer(session: id, call: "toolu_A",
                           answer: .option(index: 0, label: "Yes"), token: UUID()),
            .failure("prompt_changed")
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **Racing the Mac, the hard case — and the one a cache would not have caught.** The user
    /// approves prompt 1 in the terminal, claude raises prompt 2 immediately, and the session
    /// NEVER leaves `waiting`: no activity change is emitted, so the phone's card still shows
    /// prompt 1. A stale tap must not approve prompt 2, which nobody read.
    func testAnAnswerToASupersededCallIsRefusedEvenWhileStillWaiting() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        service.tail = { _, _ in [
            SourceLine(offset: 0, text: self.bashLine("toolu_ONE")),
            SourceLine(offset: 100, text: self.resultLine("toolu_ONE")),
            SourceLine(offset: 200, text: self.bashLine("toolu_TWO")),
        ] }
        XCTAssertEqual(
            service.answer(session: id, call: "toolu_ONE", answer: .allow, token: UUID()),
            .failure("prompt_changed")
        )
        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog nobody read")
    }

    func testAnAnswerWhileNothingIsOpenIsRefused() {
        let (service, _, spy, id) = makeService(activity: .idle)
        service.tail = { _, _ in [SourceLine(offset: 0, text: self.bashLine("toolu_A"))] }
        XCTAssertEqual(
            service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID()),
            .failure("not_waiting")
        )
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnknownSessionIsRefused() {
        let (service, _, _, _) = makeService(activity: .waiting)
        XCTAssertEqual(
            service.answer(session: UUID(), call: "toolu_A", answer: .deny, token: UUID()),
            .failure("unknown_session")
        )
    }

    /// **The re-derivation happens on every answer, not once.** Two answers, two reads. A
    /// service that cached the first derivation would read once and would then be answering
    /// from a picture of the past — which is the whole failure the hard-race test above
    /// describes.
    func testTheOpenCallIsRederivedOnEveryAnswer() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        var reads = 0
        service.tail = { _, _ in
            reads += 1
            return [SourceLine(offset: 0, text: self.bashLine("toolu_A"))]
        }
        _ = service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID())
        _ = service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID())
        XCTAssertEqual(reads, 2)
        _ = spy
    }

    /// A codex tab reaches the store's own refusal — the service does not duplicate the agent
    /// check, because splitting a check across two files is how the two drift.
    func testACodexTabIsRefusedByTheStore() {
        let (service, _, _, id) = makeCodexService(activity: .waiting)
        service.tail = { _, _ in [] }
        XCTAssertEqual(
            service.answer(session: id, call: "toolu_A", answer: .deny, token: UUID()),
            .failure("prompt_changed"),
            "no transcript source for a codex tab means no open call to match"
        )
    }
}
```

- [ ] **Step 2: Run and verify they fail** — `cannot find 'PromptService' in scope`.

- [ ] **Step 3: Create `Sources/FlightDeck/Fleet/PromptService.swift`**

```swift
import FleetKit
import Foundation

/// Carries out a phone's answer to the dialog a session is blocked on.
///
/// The only type that knows a `SessionStore` and a transcript on this path — the role
/// `TimelineService` plays for history, split from it for the same reason it is split from the
/// store: each stays testable without the other, and the thing needing both is here.
///
/// **There is no cache and there must not be one.** The open call is re-derived from the
/// transcript on every answer. A `served` table would be faster and would fail the case this
/// service exists for: the user approves a dialog in the terminal, claude raises the next one
/// immediately, and the session **never leaves `waiting`** — so no event is emitted, the
/// phone's card still shows the old dialog, and a cached entry still matches it. The
/// re-derivation does not match, because the new dialog is a different call.
///
/// The read is a tail — `TimelineLimits.window` at most, `tailRecords` records — done once per
/// human tap, on the main queue, inside `FleetSocketServer`'s synchronous `onCommand`. That is
/// a deliberate trade against a cache and it is the cheaper of the two: `TimelineService` takes
/// its read off the main actor because a *page* is parsed on every activity change, which is
/// two orders of magnitude more often and larger.
@MainActor
final class PromptService {
    private let store: SessionStore

    /// Test seam, in the shape and for the reason `TimelineService.reader` is one: the file
    /// read is the thing tests must substitute, and `@Sendable` and free of `self` so what
    /// crosses is a function value and two values, never the service or the store.
    var tail: @Sendable (URL, Int) -> [SourceLine] = { url, limit in
        TranscriptPager.page(url: url, anchor: .latest, limit: limit)?.lines ?? []
    }

    /// How many records back to look.
    ///
    /// **Small on purpose.** An open call is always among the last records — claude cannot
    /// proceed past a dialog — so one would nearly always do. A handful is read so that a
    /// `tool_result` for an *earlier* call is inside the window and cannot make an
    /// already-answered call look open, which is the only way this can be wrong in the
    /// dangerous direction.
    static let tailRecords = 8

    init(store: SessionStore) {
        self.store = store
    }

    /// Answer the dialog `session` is blocked on, if `call` still names it.
    ///
    /// Two refusals before anything is typed. `not_waiting` — nothing is blocked, so there is
    /// nothing to answer and a keystroke would land in the input bar. `prompt_changed` — the
    /// newest unanswered call is not the one named, which covers both the user answering in
    /// the terminal and the agent having moved to its next dialog.
    func answer(
        session: UUID, call: String, answer: PromptAnswer, token: UUID
    ) -> Result<Void, TimelineErrorCode> {
        // Resolved once, up front. A tab closed between the tap and here is the ordinary case,
        // not an edge one — the same ruling `TimelineService.page` makes.
        let source = store.timelineSource(of: session)
        if case .unknownSession = source { return .failure("unknown_session") }
        // Checked before any read, because it is the answer most of the time and costs nothing.
        // `SessionStore.answerPrompt` re-checks it — a client is not trusted, and neither is a
        // caller — but refusing here keeps `not_waiting` distinguishable from `prompt_changed`,
        // which are different sentences on the phone.
        guard store.status(for: session)?.activity == .waiting else {
            return .failure("not_waiting")
        }

        guard case .file(.claude, let url) = source else { return .failure("prompt_changed") }
        let lines = tail(url, Self.tailRecords)
        guard let open = ClaudeOpenCall.find(in: lines, activity: store.status(for: session)?.activity),
              open.callID == call
        else { return .failure("prompt_changed") }

        let outcome = store.answerPrompt(open, with: answer, in: session, token: token)
        if let code = outcome.errorCode { return .failure(TimelineErrorCode(code)) }
        return .success(())
    }
}

extension TimelineErrorCode {
    /// A code built at runtime rather than written as a literal. `ExpressibleByStringLiteral`
    /// covers every call site in `TimelineService`; this covers the one place a code arrives
    /// from `AnswerDispatch` as a `String`.
    init(_ code: String) { self.init(stringLiteral: code) }
}
```

- [ ] **Step 4: Run and verify they pass** — baseline + 71 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Cache the derivation: hold `[UUID: OpenPrompt]`, populate on first answer, reuse after | `testTheOpenCallIsRederivedOnEveryAnswer` **and** `testAnAnswerToASupersededCallIsRefusedEvenWhileStillWaiting` — the second is the one that matters, and if it passes under the mutation your fixture is wrong: check that the tail returns *both* calls, with a result for the first |
| Delete `guard open.callID == call` | `testAnAnswerToACallThatHasSinceBeenAnswered…` and the superseded-call test |
| Delete the `.waiting` guard | `testAnAnswerWhileNothingIsOpenIsRefused` — **check the fixture supplies a tail that WOULD find a call when idle**; it does |
| Return `.failure("prompt_changed")` for an unknown session | `testAnUnknownSessionIsRefused` |
| Duplicate the agent check here (`guard agent == .claude`) | Not a mutation, but if you add it, `testACodexTabIsRefusedByTheStore` still passes and you have created the split-check drift the comment warns about. Do not |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Fleet/PromptService.swift Tests/FlightDeckTests/PromptServiceTests.swift
git commit -m "feat: re-derive the open call on every answer, and refuse a stale one"
```

---

## Task 8: One command arm, over a real socket

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift`
- Test: `Tests/FlightDeckTests/AnswerLoopbackTests.swift`

**Interfaces:**
- Consumes: `PromptService` (Task 7), `FleetCommand.answerPrompt` (Task 2)
- Produces: `FleetService`'s `.answerPrompt` arm becomes real; `var FleetService.promptTailForTesting`

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/AnswerLoopbackTests.swift`:

```swift
import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The whole path over a real TLS-PSK socket on loopback: a phone answers a dialog and the
/// Mac's terminal moves.
///
/// The same shape as `PhonePromptLoopbackTests`, and it exists for the same reason: every layer
/// below is unit-tested against a fake, and this is the only test that would catch a frame
/// wired to the wrong handler.
@MainActor
final class AnswerLoopbackTests: XCTestCase {
    func testAPhoneAnswersAQuestionAndTheTerminalMoves() async throws {
        let (service, _, spy, id) = try await makeLoopbackFleet(activity: .waiting)
        service.promptTailForTesting = { _, _ in
            [SourceLine(offset: 0, text: askUserQuestionLine)]
        }
        spy.showOptions(
            ["Playing jazz piano", "Speaking 10 languages", "Freehand drawing", "Woodworking"],
            selected: 0
        )
        let client = try await connectLoopbackClient(to: service)

        let answered = expectation(description: "answered")
        client.send(.answerPrompt(
            id: id, token: UUID(), call: "toolu_01TAgqjgnNES8BUtNAenrPnB",
            answer: .option(index: 1, label: "Speaking 10 languages")
        )) { result in
            XCTAssertNoThrow(try result.get())
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    func testAPhoneDeniesADialogWithOneEscape() async throws {
        let (service, _, spy, id) = try await makeLoopbackFleet(activity: .waiting)
        service.promptTailForTesting = { _, _ in [SourceLine(offset: 0, text: bashLine)] }
        let client = try await connectLoopbackClient(to: service)
        let answered = expectation(description: "answered")
        client.send(.answerPrompt(id: id, token: UUID(), call: "toolu_BASH", answer: .deny)) {
            XCTAssertNoThrow(try $0.get())
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(spy.events, [.escape])
    }

    func testAStaleAnswerComesBackAsAnErrorAndTypesNothing() async throws {
        let (service, _, spy, id) = try await makeLoopbackFleet(activity: .waiting)
        service.promptTailForTesting = { _, _ in [SourceLine(offset: 0, text: bashLine)] }
        let client = try await connectLoopbackClient(to: service)
        let refused = expectation(description: "refused")
        var code: String?
        client.send(.answerPrompt(id: id, token: UUID(), call: "toolu_GONE", answer: .allow)) {
            if case .failure(.server(let value)) = $0 { code = value }
            refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(code, "prompt_changed")
        XCTAssertTrue(spy.events.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify it fails** — the Task 2 placeholder answers `err`/`unhandled`, so the first two tests fail on `XCTAssertNoThrow` and the third on the code.

- [ ] **Step 3: Wire the arm in `Sources/FlightDeck/Fleet/FleetService.swift`**

Beside `timeline`:

```swift
    /// Carries out a phone's answer to a blocked dialog. Held here rather than built per
    /// command for the reason `timeline` is: it holds the store, and there is exactly one of
    /// it — a command carries its own session id, so nothing about it is per-connection.
    private let prompts: PromptService
```

In `init`, beside `self.timeline = TimelineService(store: store)`:

```swift
        self.prompts = PromptService(store: store)
```

Replace the placeholder in `apply(_:cid:)`:

```swift
        case .answerPrompt(let id, let token, let call, let answer):
            // Every refusal is the service's and the store's to make, for the reason `.prompt`
            // states: they are the only things that know the tab's agent, its status, its
            // transcript and its screen, and splitting the checks across two files is how they
            // drift. Synchronous, and it must stay synchronous — `onCommand` answers inline,
            // and `PromptService.answer`'s read is a tail sized for exactly that.
            if case .failure(let code) = prompts.answer(
                session: id, call: call, answer: answer, token: token
            ) {
                return .err(cid: cid, code: code.code)
            }
```

And the test seam beside the others:

```swift
    /// Test seam, forwarding to `PromptService.tail`. No production caller.
    var promptTailForTesting: (@Sendable (URL, Int) -> [SourceLine])? {
        get { nil }
        set { if let newValue { prompts.tail = newValue } }
    }
```

- [ ] **Step 4: Run and verify they pass** — baseline + 74 cumulative.

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Revert the arm to `return .err(cid: cid, code: "unhandled")` | All three |
| Ignore the failure and always `ack` | `testAStaleAnswerComesBackAsAnErrorAndTypesNothing` |
| Build a fresh `PromptService(store:)` inside the arm | **No test fails** — the service is stateless now, by design. Record that; it is the difference the cache removal made, and it means the held instance is a convenience rather than a correctness requirement |
| Pass `answer: .deny` regardless of the frame | `testAPhoneAnswersAQuestionAndTheTerminalMoves` |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/AnswerLoopbackTests.swift
git commit -m "feat: a phone's answer reaches the terminal over a real socket"
```

---

## Task 9: A question in the conversation reads as a question

**Files:**
- Modify: `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift` (`assistantItem`'s `tool_use` arm, ~line 128)
- Test: `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`

**Interfaces:**
- Produces: an `AskUserQuestion` `tool_use` maps to `kind: .prompt` rather than `.toolCall`; everything else about the row is unchanged.

> This is half of what the user actually reported. An `AskUserQuestion` in the conversation currently renders as a `.toolCall` — a JSON tree of `{"questions":[…]}` — which is the machine's view of a question a person answered. And `.prompt` is what `OpenPrompt.find` switches on, so this task is also what makes Task 1's question arm reachable in production.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`:

```swift
    /// **`.prompt`, the case reserved for this since the timeline shipped.** Everything else
    /// about the row is a `.toolCall`'s — the tool name, the `callID` that pairs it with its
    /// result, the whole input in `text` — so the detail screen and `entries(from:)`'s folding
    /// both keep working. Only the kind changes, and the kind is what tells `OpenPrompt.find`
    /// this is a question rather than a permission request, and tells the phone to draw the
    /// question rather than the JSON.
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
        XCTAssertNotNil(
            PromptQuestion(toolInput: item.body.text),
            "the input travels whole, so both ends can rebuild the question from this row"
        )
    }

    /// A one-line preview drawn from the question, not from `ToolInputSummary`'s key table —
    /// which has no entry reaching two levels into `questions[0]` and would leave the row
    /// saying nothing at all.
    func testAPromptRowPreviewsItsQuestion() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_A","name":"AskUserQuestion","input":{"questions":[{"question":\
        "Which skill?","options":[{"label":"a"}]}]}}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.body.summary, "Which skill?")
    }

    /// `summary` escapes `TimelineReader.capped` entirely — `ToolInputSummary.maxSummaryBytes`
    /// is the only bound it gets anywhere — so a long question must still be cut here.
    func testALongQuestionsPreviewIsStillBounded() throws {
        let long = String(repeating: "why ", count: 200)
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_A","name":"AskUserQuestion","input":{"questions":[{"question":"\(long)",\
        "options":[{"label":"a"}]}]}}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(item.body.summary).utf8.count, ToolInputSummary.maxSummaryBytes
        )
    }

    /// Every other tool is untouched. A `Bash` call, because that is the row this rule would
    /// break if it were scoped by anything other than the tool's name — and because
    /// `OpenPrompt` reads a `.toolCall` as a permission request.
    func testEveryOtherToolIsStillAToolCall() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_B","name":"Bash","input":{"command":"ls"}}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.body.summary, "ls")
    }

    /// The answer stays a `.toolResult`, so `entries(from:)` still folds it into the question
    /// on `callID` and `OpenPrompt.find` still counts it as closing the call. Changing it too
    /// would strand every answered question as an open one.
    func testTheAnswerToAQuestionIsStillAToolResult() throws {
        let line = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"toolu_A","content":"Your questions have been answered."}]}}
        """
        let item = try XCTUnwrap(ClaudeTimelineMapper.items(inLine: line, at: 0).first)
        XCTAssertEqual(item.kind, .toolResult)
        XCTAssertEqual(item.body.callID, "toolu_A")
    }
```

- [ ] **Step 2: Run and verify they fail** — `("toolCall") is not equal to ("prompt")`.

- [ ] **Step 3: Change `assistantItem`'s `tool_use` arm**

```swift
        case "tool_use":
            let input = block["input"] as? [String: Any]
            let tool = block["name"] as? String
            // **The one tool whose call is a question rather than a command**, and the only
            // place `TimelineItem.Kind.prompt` is emitted. Everything else about the row is
            // unchanged — same tool name, same `callID` so `entries(from:)` still folds the
            // answer in and `OpenPrompt.find` still sees it closed, same whole input in `text`
            // so both ends can rebuild the question with `PromptQuestion(toolInput:)`.
            //
            // Only the kind moves, and it does two jobs: it stops a question a person answered
            // from rendering as a JSON tree of `{"questions":[…]}`, and it is what
            // `OpenPrompt.find` switches on to tell a question from a permission request.
            let isQuestion = tool == "AskUserQuestion"
            return TimelineItem(
                id: id, kind: isQuestion ? .prompt : .toolCall, status: .complete,
                body: TimelineItem.Body(
                    text: ToolInputSummary.pretty(input),
                    // `ToolInputSummary`'s key table has no entry that reaches a question — it
                    // lives two levels down, inside `questions[0]` — so a prompt row would
                    // preview as nothing. Bounded by the same `preview(of:)`, which is the ONLY
                    // bound `summary` gets anywhere: `TimelineReader.capped` cuts `text` and
                    // never touches this.
                    summary: (isQuestion ? questionPreview(input) : nil)
                        ?? input.flatMap(ToolInputSummary.text(for:)),
                    tool: tool,
                    callID: block["id"] as? String
                ),
                at: at
            )
```

Beside it:

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

- [ ] **Step 4: Run and verify they pass.** Existing mapper tests must be unchanged; `TimelineStyleTests` switches exhaustively on `Kind` and already has a `.prompt` arm. **If you skipped a test in Task 5, un-skip it now.**

- [ ] **Step 5: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| Set `isQuestion` from `tool != nil` | `testEveryOtherToolIsStillAToolCall` |
| Drop the `questionPreview` half of the `summary` expression | `testAPromptRowPreviewsItsQuestion` — **verify the fixture's input has no `command`/`file_path`/`prompt`/`description` key**, or the key table finds one and the mutation is a no-op. It does not |
| In `questionPreview`, return `text` without `ToolInputSummary.preview(of:)` | `testALongQuestionsPreviewIsStillBounded` |
| Also map `tool_result` to `.prompt` | Not reachable — `userItem` has no tool name, so this cannot be written. `testTheAnswerToAQuestionIsStillAToolResult` asserts the outcome against unmutated code, which is weaker; say so in the report |

- [ ] **Step 6: Verify** — full four scripts.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift \
        Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift
git commit -m "feat: a question in the conversation reads as a question"
```

---

## Task 10: The phone derives, draws, and answers

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift`
- Create: `Sources/FlightDeckMobile/PromptCard.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `Sources/FlightDeckMobile/TimelineRow.swift` (one arm)
- Modify: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift`, `SessionTimelinePromptTests.swift` (`StubPager`)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift`, `PromptCardTests.swift`

**Interfaces:**
- Consumes: `OpenPrompt.find(in:activity:)`, `PromptQuestion(toolInput:)`, `FleetCommand.answerPrompt`, `PromptAnswer`
- Produces:
  - `@MainActor protocol PromptAnswering: AnyObject { func answerPrompt(_ command: FleetCommand, then: @escaping (Result<Void, FleetRequestError>) -> Void) }`
  - `enum SessionTimelineModel.AnswerState: Equatable { case idle, sent(call: String), failed(call: String, String) }`
  - `SessionTimelineModel.answerState: AnswerState` (private(set))
  - `func SessionTimelineModel.blocked(activity: String?) -> OpenPrompt?`
  - `func SessionTimelineModel.answer(_ answer: PromptAnswer, to call: String)`
  - `static SessionTimelineModel.noAnswerConfirmation`, `static answerMessage(for:)`
  - `struct PromptCard: View`, `static PromptCard.showsControls(for:state:) -> Bool`, `static PromptCard.footnote(for:state:) -> String?`
  - `struct HistoricalPromptBody: View`

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's half of the feature: derive from what it already holds, send one answer at a
/// time, and never claim more than it knows.
@MainActor
final class SessionTimelineBlockedTests: XCTestCase {

    private func page(_ items: [TimelineItem], session: UUID) -> TimelinePage {
        TimelinePage(session: session, items: items, start: 0, end: 1_000,
                     hasMore: false, reset: false)
    }

    /// **Derived, not fetched.** The whole question comes out of the feed the screen already
    /// has — this test would need a second round trip if any of it were transmitted.
    func testAQuestionIsDerivedFromTheFeedTheScreenAlreadyHolds() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        guard case .question("toolu_A", let question)? = model.blocked(activity: "waiting")
        else { return XCTFail("expected a question") }
        XCTAssertEqual(question.options.map(\.label), ["Yes", "No"])
    }

    func testNothingIsBlockedWhileTheSessionIsNotWaiting() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNil(model.blocked(activity: "busy"))
        XCTAssertNil(model.blocked(activity: nil))
    }

    /// **The Mac answered first.** The result arrives on the next fetch, and the card is gone
    /// — with no new frame, no push, and nothing to invalidate.
    func testAResultArrivingOnALaterPageClearsTheBlock() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([askItem(callID: "toolu_A")], session: model.sessionID)))
        XCTAssertNotNil(model.blocked(activity: "waiting"))
        model.loadNewer()
        stub.answer(.success(page(
            [askItem(callID: "toolu_A"), resultItem(callID: "toolu_A")], session: model.sessionID
        )))
        XCTAssertNil(model.blocked(activity: "waiting"))
    }

    func testTappingAnOptionSendsAnAnswerNamingTheCall() {
        let (model, stub) = makeModel()
        model.answer(.option(index: 1, label: "No"), to: "toolu_A")
        guard case .answerPrompt(let id, _, let call, let answer)? = stub.sent
        else { return XCTFail("expected an answer command") }
        XCTAssertEqual(id, model.sessionID)
        XCTAssertEqual(call, "toolu_A")
        XCTAssertEqual(answer, .option(index: 1, label: "No"))
        XCTAssertEqual(model.answerState, .sent(call: "toolu_A"))
    }

    /// One in flight at a time. A second tap before the first ack must not become two answers
    /// — which, on a permission dialog, is two decisions.
    func testASecondTapWhileOneIsInFlightSendsNothing() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_A")
        stub.sent = nil
        model.answer(.deny, to: "toolu_A")
        XCTAssertNil(stub.sent)
    }

    /// A new call clears a stuck state, so a card that failed on the previous dialog does not
    /// suppress the next one's controls.
    func testAnAnswerToANewCallIsAllowedAfterAFailure() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_ONE")
        stub.answerCommand(.failure(.server(code: "prompt_changed")))
        stub.sent = nil
        model.answer(.allow, to: "toolu_TWO")
        XCTAssertNotNil(stub.sent)
    }

    func testAnAckLeavesTheCardSayingItWasSent() {
        let (model, stub) = makeModel()
        model.answer(.deny, to: "toolu_A")
        stub.answerCommand(.success(()))
        XCTAssertEqual(model.answerState, .sent(call: "toolu_A"))
    }

    func testARefusalIsShownWithTheMacsOwnReason() {
        let (model, stub) = makeModel()
        model.answer(.allow, to: "toolu_A")
        stub.answerCommand(.failure(.server(code: "prompt_changed")))
        XCTAssertEqual(
            model.answerState,
            .failed(call: "toolu_A",
                    SessionTimelineModel.answerMessage(for: .server(code: "prompt_changed")))
        )
    }

    /// **The silent failure this deadline exists for.** `ack` means dispatched, and the Mac's
    /// driver refuses to press Return on a screen it cannot confirm — so a dispatched answer
    /// that never landed produces no frame at all. A half-open socket produces none either.
    func testAnAnswerNobodyConfirmsBecomesAFailureOnTheDeadline() async {
        let (model, _) = makeModel(timeout: .milliseconds(20))
        model.answer(.allow, to: "toolu_A")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            model.answerState,
            .failed(call: "toolu_A", SessionTimelineModel.noAnswerConfirmation)
        )
    }

    /// Deliberately not "try again". A retry after a timeout is the one action that can press
    /// Return twice — and on a permission dialog, approve twice.
    func testTheUnconfirmedCopyDoesNotInviteARetry() {
        XCTAssertFalse(SessionTimelineModel.noAnswerConfirmation.lowercased().contains("again"))
    }
}
```

`Tests/FlightDeckMobileTests/PromptCardTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The card's decisions, extracted from the view so they can be asserted without a render —
/// the same shape `PromptComposerTests` uses, and for the same reason.
@MainActor
final class PromptCardTests: XCTestCase {
    private func question(unanswerable: String? = nil) -> OpenPrompt {
        .question(callID: "toolu_A", PromptQuestion(
            header: "Pick", question: "Which?",
            options: [.init(label: "Yes"), .init(label: "No")], unanswerable: unanswerable
        ))
    }

    private let permission = OpenPrompt.permission(
        callID: "toolu_B", tool: "Bash", summary: "rm -rf build"
    )

    /// **Controls in exactly one state.** `sent` must not offer them — tapping twice answers
    /// twice — and `failed` must not either, because a Return may already be on its way.
    func testControlsAreOfferedOnlyBeforeAnAnswerIsSent() {
        XCTAssertTrue(PromptCard.showsControls(for: question(), state: .idle))
        XCTAssertFalse(PromptCard.showsControls(for: question(), state: .sent(call: "toolu_A")))
        XCTAssertFalse(
            PromptCard.showsControls(for: question(), state: .failed(call: "toolu_A", "nope"))
        )
    }

    /// A state left over from a PREVIOUS dialog must not suppress this one's controls — the
    /// harder race, seen from the phone: the session never left `waiting`, so the card was
```swift
    /// A state left over from a PREVIOUS dialog must not suppress this one's controls — the
    /// harder race, seen from the phone: the session never left `waiting`, so the card was
    /// never torn down, and a failure filed against `toolu_ONE` would silently disable the
    /// buttons for `toolu_TWO`. Keyed on the call for exactly that reason.
    func testAStateFromADifferentCallDoesNotSuppressThisOnesControls() {
        XCTAssertTrue(
            PromptCard.showsControls(for: question(), state: .sent(call: "toolu_OTHER"))
        )
    }

    func testAnUnanswerableQuestionShowsItsReasonAndNoControls() {
        let multi = question(unanswerable: PromptQuestion.multiSelectReason)
        XCTAssertFalse(PromptCard.showsControls(for: multi, state: .idle))
        XCTAssertEqual(
            PromptCard.footnote(for: multi, state: .idle), PromptQuestion.multiSelectReason
        )
    }

    /// A permission card always has controls, because Allow and Deny do not come from a payload
    /// — they are the two intents `PromptAnswer` names. There is nothing to be unanswerable
    /// about.
    func testAPermissionCardAlwaysHasControls() {
        XCTAssertTrue(PromptCard.showsControls(for: permission, state: .idle))
        XCTAssertNil(PromptCard.footnote(for: permission, state: .idle))
    }

    func testASentAnswerSaysSoRatherThanSayingNothing() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .sent(call: "toolu_A")),
            PromptCard.sentFootnote
        )
    }

    func testAFailureShowsTheMacsOwnReason() {
        XCTAssertEqual(
            PromptCard.footnote(for: question(), state: .failed(call: "toolu_A", "Moved on.")),
            "Moved on."
        )
    }

    /// A permission card names the tool and shows its command, which is more than the terminal
    /// shows — and it is all the phone has, because the dialog's own wording exists nowhere it
    /// can read.
    func testAPermissionCardIsTitledFromTheToolAndItsSummary() {
        XCTAssertEqual(PromptCard.title(for: permission), "Claude wants to run Bash")
        XCTAssertEqual(PromptCard.subtitle(for: permission), "rm -rf build")
    }

    func testAPermissionCardForAToolWithNoSummaryStillHasATitle() {
        XCTAssertEqual(
            PromptCard.title(for: .permission(callID: "x", tool: nil, summary: nil)),
            "Claude is waiting for you"
        )
    }

    /// A historical row rebuilds its question with the same parser the live card uses. A body
    /// the parser refuses — a truncated one — falls back to the raw text rather than nothing.
    func testAHistoricalRowRebuildsItsQuestionFromTheBody() throws {
        let body = #"{"questions":[{"question":"Which?","options":[{"label":"a"}]}]}"#
        XCTAssertEqual(try XCTUnwrap(PromptQuestion(toolInput: body)).question, "Which?")
        XCTAssertNil(PromptQuestion(toolInput: String(body.prefix(20))))
    }
}
```

`StubPager` in both existing mobile test files gains:

```swift
    var sent: FleetCommand?
    private var answerCompletion: ((Result<Void, FleetRequestError>) -> Void)?

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        sent = command
        answerCompletion = completion
    }

    /// Held rather than answered, so a test can assert what happens WHILE one is outstanding —
    /// which is where a second tap and a deadline both live. The same reason the existing stub
    /// holds its page completion.
    func answerCommand(_ result: Result<Void, FleetRequestError>) {
        let completion = answerCompletion
        answerCompletion = nil
        completion?(result)
    }
```

- [ ] **Step 2: Run and verify they fail** — `./scripts/test-ios.sh`; `cannot find 'PromptAnswering'`, then `type 'StubPager' does not conform`.

- [ ] **Step 3: Add `PromptAnswering` and the state to `SessionTimelineModel.swift`**

After `PromptSending`:

```swift
/// The third verb a session screen needs: here is an answer to the dialog this session is
/// blocked on.
///
/// **There is no `pendingPrompt` verb beside it, and that absence is the design.** What the
/// session is blocked on is *derived* from the feed this model already holds and the `activity`
/// the fleet already pushes — see `blocked(activity:)`. Nothing about a question is fetched,
/// so there is nothing here to fetch it with.
///
/// A third protocol rather than a third method on either existing one, for the reason there are
/// two already: a stub must be able to leave one verb outstanding while answering another, and
/// the transition worth asserting here — an answer nobody confirms — is one no real link
/// produces on demand.
@MainActor
protocol PromptAnswering: AnyObject {
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}
```

In the model:

```swift
    /// Where the one answer this screen may have in flight has got to.
    ///
    /// **Keyed on the call, not a bare enum**, and that is what makes the harder race safe on
    /// this side: the user approves in the terminal, claude raises the next dialog, and the
    /// session never leaves `waiting` — so this state is never torn down by a screen
    /// transition. Filed against `toolu_ONE`, it must not disable the buttons for `toolu_TWO`.
    enum AnswerState: Equatable {
        case idle
        /// Dispatched. `ack` means *dispatched, not done* — the Mac's driver refuses to press
        /// Return on a screen it cannot confirm — so what clears this card is the transcript:
        /// the `tool_result` arrives, `blocked(activity:)` returns nil, and the card goes.
        case sent(call: String)
        /// The Mac refused, or nobody confirmed. The question stays visible with the reason
        /// under it, because the reader has to see what they were being asked.
        case failed(call: String, String)

        var call: String? {
            switch self {
            case .idle: return nil
            case .sent(let call), .failed(let call, _): return call
            }
        }
    }

    private(set) var answerState = AnswerState.idle

    @ObservationIgnored private var answerInFlight: UUID?
    @ObservationIgnored private var answerDeadline: Task<Void, Never>?
```

```swift
    /// What this session is blocked on, or nil.
    ///
    /// **Derived, never fetched.** `OpenPrompt.find` is the same function the Mac runs over the
    /// same transcript — shared in `FleetKit` precisely so the two cannot drift — and it runs
    /// here over `feed.items`, which the history channel has already delivered. That is why
    /// this feature adds no request, no reply frame and no event: a question appearing is an
    /// `activity` change (already pushed) plus records (already fetched on that change), and a
    /// question being answered on the Mac is a `tool_result` arriving on the next fetch.
    ///
    /// A function of `activity` rather than a stored property, so it cannot go stale: the
    /// screen passes the live `WireSession.activity` it is already reading.
    func blocked(activity: String?) -> OpenPrompt? {
        OpenPrompt.find(in: feed.items, activity: activity)
    }

    /// Answer the dialog `call` names.
    ///
    /// One in flight at a time, and on a permission dialog that guard is the difference between
    /// one decision and two. A state left over from a different call does not block this one —
    /// see `AnswerState`.
    func answer(_ answer: PromptAnswer, to call: String) {
        guard answerInFlight == nil else { return }
        let token = UUID()
        answerInFlight = token
        answerState = .sent(call: call)

        // Armed BEFORE the send, because the send can complete before it returns:
        // `FleetConnector.send(_:then:)` answers `.disconnected` synchronously by design, the
        // same asymmetry `fetch` and `send(_:)` both arm ahead of.
        let timeout = self.timeout
        answerDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.claimAnswer(token) else { return }
            self.answerState = .failed(call: call, Self.noAnswerConfirmation)
        }

        fleet.answerPrompt(
            .answerPrompt(id: sessionID, token: token, call: call, answer: answer)
        ) { [weak self] result in
            guard let self, self.claimAnswer(token) else { return }
            switch result {
            case .success:
                // Stays `.sent`. What retires the card is the transcript — so pull it, for the
                // same reason `send(_:)` does: the Mac emits no frame when a Return lands.
                self.loadNewer()
            case .failure(let error):
                self.answerState = .failed(call: call, Self.answerMessage(for: error))
            }
        }
    }

    /// Whichever of the ack and the deadline arrives first wins; the loser finds nothing filed
    /// and does nothing. The same rule, and the same reason, as `claim(_:)`.
    private func claimAnswer(_ token: UUID) -> Bool {
        guard answerInFlight == token else { return false }
        answerInFlight = nil
        answerDeadline?.cancel()
        answerDeadline = nil
        return true
    }

    /// Deliberately not "try again": a retry after a timeout is the one action that can press
    /// Return twice in a live terminal — and on a permission dialog, approve twice. Same
    /// ruling, same wording discipline, as `noConfirmation`.
    static let noAnswerConfirmation =
        "Your Mac didn't confirm this. Check the terminal before answering again."

    /// Copy for an answer that did not land. **Deliberately not `promptMessage(for:)`** — the
    /// same wire code means a different thing on this channel, and `prompt_changed` has no
    /// meaning on that one at all.
    static func answerMessage(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac, so this wasn't sent."
        case .server(let code):
            switch code {
            case "prompt_changed":
                return "Your Mac has moved on from this."
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

Widen the stored property and initializer to `any TimelinePaging & PromptSending & PromptAnswering`.

In `FleetModel.swift`, add `PromptAnswering` to the conformance list and:

```swift
    /// Answer a blocked dialog. Forwarded rather than absorbed, exactly as `sendPrompt` is:
    /// the connector answers **exactly once**, including with `.disconnected`, and a layer here
    /// that could swallow that would leave a person believing they told an agent to proceed.
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }
```

- [ ] **Step 4: Create `Sources/FlightDeckMobile/PromptCard.swift`**

```swift
import FleetKit
import SwiftUI

/// What the agent is blocked on, at the foot of the conversation.
///
/// **Above the composer and inside the safe-area inset, not a row in the `List`.** The list is
/// the conversation, every row of which is a record the agent has written; a dialog the agent
/// is *currently blocked on* is a state, and it must not scroll away from the finger that has
/// to answer it. The same placement decision, and the same reasoning, as `PromptComposer`'s
/// outbox rows.
///
/// **Two shapes, because the payloads genuinely differ.** A question has its own words and its
/// own options, read from the transcript. A permission request has none — the dialog's wording
/// is built in claude's TUI and exists nowhere Flight Deck reads — so its card describes the
/// *tool call*, which the phone has whole and which is more than the terminal's own one-line
/// summary shows, and offers the two intents `PromptAnswer` names.
///
/// **Allow and Deny, and no third button.** Claude's dialog offers "Yes, and don't ask again
/// for Bash commands in /Users/nate" in its middle rows — a durable grant, from a pocket, off a
/// possibly-truncated label. `PromptAnswer` has no case that names one, so there is nothing to
/// draw. See its own comment; this is not a `TODO`.
///
/// **Nothing here is monospaced** except a command, which is machine text. The screen's rule
/// (`TimelineRow`) reserves monospace for that, and a question written for a person is prose.
struct PromptCard: View {
    let open: OpenPrompt?
    let state: SessionTimelineModel.AnswerState
    let model: SessionTimelineModel

    /// Whether a finger can change anything.
    ///
    /// **Keyed on the call**, so a failure filed against a dialog that has since been replaced
    /// does not disable the replacement's buttons — the case where the session never left
    /// `waiting` and nothing tore the card down.
    static func showsControls(
        for open: OpenPrompt, state: SessionTimelineModel.AnswerState
    ) -> Bool {
        if let pending = state.call, pending == open.callID { return false }
        switch open {
        case .question(_, let question): return question.isAnswerable
        // Allow and Deny are intents, not payload, so there is nothing to be unanswerable
        // about.
        case .permission: return true
        }
    }

    static func footnote(
        for open: OpenPrompt, state: SessionTimelineModel.AnswerState
    ) -> String? {
        if state.call == open.callID {
            switch state {
            case .sent: return sentFootnote
            case .failed(_, let reason): return reason
            case .idle: break
            }
        }
        // A shape this Mac will not drive says so in the Mac's own words, so a newer Mac that
        // learns to drive one simply stops producing the sentence.
        if case .question(_, let question) = open { return question.unanswerable }
        return nil
    }

    static let sentFootnote = "Sent to your Mac."

    static func title(for open: OpenPrompt) -> String {
        switch open {
        case .question(_, let question): return question.question
        case .permission(_, let tool, _):
            guard let tool, !tool.isEmpty else { return "Claude is waiting for you" }
            return "Claude wants to run \(tool)"
        }
    }

    /// The second line: an option's own words have their descriptions instead, so this is only
    /// ever a tool's command.
    static func subtitle(for open: OpenPrompt) -> String? {
        guard case .permission(_, _, let summary) = open, let summary, !summary.isEmpty
        else { return nil }
        return summary
    }

    var body: some View {
        if let open {
            VStack(alignment: .leading, spacing: 10) {
                if case .question(_, let question) = open, let header = question.header,
                   !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(Self.title(for: open)).font(.callout.weight(.medium))
                if let subtitle = Self.subtitle(for: open) {
                    Text(subtitle)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        // Three lines: a command is the thing being approved and clipping it to
                        // one is how a phone approves something nobody read. Beyond three, the
                        // full input is one tap away on the row above in the conversation.
                        .lineLimit(3)
                }

                controls(for: open)

                if let footnote = Self.footnote(for: open, state: state) {
                    Text(footnote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.orange.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func controls(for open: OpenPrompt) -> some View {
        let enabled = Self.showsControls(for: open, state: state)
        switch open {
        case .question(let call, let question):
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    model.answer(.option(index: index, label: option.label), to: call)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).font(.footnote.weight(.medium))
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                // A real description runs to a line and a half and is the only
                                // thing saying what the option MEANS. Clamped so four options
                                // still fit above the keyboard.
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        case .permission(let call, _, _):
            HStack(spacing: 8) {
                // Deny first, and leading. It is the safe answer, it is one Escape with no
                // screen inference behind it, and it is the one a thumb should reach without
                // aiming.
                Button(role: .destructive) { model.answer(.deny, to: call) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                Button { model.answer(.allow, to: call) } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// A question already in the conversation, drawn as the question it was rather than as the
/// JSON of the call that asked it.
///
/// Rebuilt with the same parser the live card uses, over the body the mapper already carries.
/// `nil` from that parser is the ordinary outcome for a truncated body — see
/// `TimelineItem.Body.text` — and the fallback is the text, which is what this row did before.
struct HistoricalPromptBody: View {
    let item: TimelineItem

    var body: some View {
        if let question = PromptQuestion(toolInput: item.body.text) {
            VStack(alignment: .leading, spacing: 6) {
                Text(question.question).font(.footnote.weight(.medium))
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    Text("• \(option.label)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(item.body.text).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 5: Mount it in `SessionTimelineScreen.swift`**

```swift
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                PromptCard(
                    open: model.blocked(activity: session?.activity),
                    state: model.answerState,
                    model: model
                )
                PromptComposer(session: session, model: model)
            }
        }
```

The existing `.onChange(of: session?.activity) { _, _ in model.loadNewer() }` at `:139` **already covers the appearing case and needs no change** — the fetch it fires is what brings in the `tool_use` record, and the card is derived from the feed. Add one thing beside it:

```swift
        // **A retry, not a poll**, and it exists for one race. The status file and the
        // transcript are written by independent paths in claude, so a fetch fired the instant
        // `waiting` arrives can beat the record to disk — leaving a session the phone knows is
        // blocked with nothing in the feed to say on what. One deferred fetch closes it.
        //
        // Deliberately NOT a loop. A `waiting` session can sit for an hour, and a screen that
        // polled through it would spend a battery to re-read a file that changes when the
        // human moves. If the manual checklist finds this flaky, the fix is a SECOND retry at
        // a longer delay, not a `while`.
        .task(id: session?.activity) {
            guard session?.activity == "waiting" else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            model.loadNewer()
        }
```

> Two `.task(id:)` modifiers with the same id on one view both run. Keep this separate from the existing busy-poll `.task` rather than merging them into one loop with a branch — merging ties the two cadences together, and they are different decisions.

- [ ] **Step 6: One arm in `TimelineRow.swift`**

Re-read the file first. In the `switch item.kind` at ~line 124, add:

```swift
        case .prompt:
            // A question the agent asked, rebuilt from the input the mapper carried. The
            // answer, when the feed holds one, is already folded in as `result` by
            // `entries(from:)` on `callID` — unchanged, because the RESULT is still a
            // `.toolResult`.
            HistoricalPromptBody(item: item)
```

- [ ] **Step 7: Run and verify they pass** — `./scripts/test-ios.sh`, iOS baseline + 20.

- [ ] **Step 8: Prove each test can fail**

| Mutation | Must fail |
| --- | --- |
| In `blocked(activity:)`, pass `"waiting"` literally instead of `activity` | `testNothingIsBlockedWhileTheSessionIsNotWaiting` |
| In `answer`, drop `guard answerInFlight == nil` | `testASecondTapWhileOneIsInFlightSendsNothing` |
| Make `AnswerState` a bare enum without `call`, and have `showsControls` check only the case | `testAStateFromADifferentCallDoesNotSuppressThisOnesControls` and `testAnAnswerToANewCallIsAllowedAfterAFailure` — **the harder race, from the phone's side** |
| Delete the whole `answerDeadline` task | `testAnAnswerNobodyConfirmsBecomesAFailureOnTheDeadline` |
| In `answer`'s success arm, set `answerState = .idle` | `testAnAckLeavesTheCardSayingItWasSent` |
| In `showsControls`'s `.permission` arm, return `question.isAnswerable`-style false | `testAPermissionCardAlwaysHasControls` |
| Arm `answerDeadline` after `fleet.answerPrompt(...)` | **No test fails with this stub**, which holds its completion. Record it; the asymmetry is documented on `FleetConnector.send(_:then:)` and covered by `FleetConnectorAckTests` |
| Delete the `.onChange(of: session?.activity)` line in the screen | **No unit test fails** — view wiring. It is checklist item 3 in Task 11 and the single most important thing to check by hand |

- [ ] **Step 9: Verify** — full four scripts, and `./scripts/build-ios.sh` specifically, since `PromptCard.swift` is a new flat mobile source.

- [ ] **Step 10: Commit**

```bash
git add Sources/FlightDeckMobile/ Tests/FlightDeckMobileTests/
git commit -m "feat: a blocked agent's question, as a box you can answer"
```

---

## Task 11: The checklist, and the two gaps

**Files:**
- Modify: `docs/MOBILE.md`
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:** none.

> **Not paperwork.** Three things here are covered by no automated test and cannot be: `Ghostty.SurfaceView.sendBareKey` never runs under XCTest; `.allow` targeting the dialog's first row is a convention read off one capture; and the status-file/transcript write race is timing no fake reproduces.

- [ ] **Step 1: Add to `docs/MOBILE.md`'s "The manual checklist"**

```markdown
### Answering a question from the phone

**Item 1 — Deny, first, on a permission prompt.** Get a claude tab to a Bash permission
prompt. From the phone, tap **Deny**. The terminal must dismiss the dialog and claude must
report the tool refused. This is one Escape with no screen parsing behind it, so if anything in
this feature works, it is this; if it does NOT work, `sendEscape` is not reaching the pty and
nothing else here will work either.

**Item 2 — Allow, and check which row it landed on.** Same dialog. Tap **Allow**. The terminal
must select the FIRST option ("Yes") and submit — **not** "Yes, and don't ask again". Watch the
selection move. If it lands anywhere but the first row, stop: `SessionStore.answerPrompt`'s
`.allow` arm and `dialog-permission.captured.txt` disagree about the dialog's ordering, and the
fix is a fresh capture and a rewritten arm, never an edited fixture.

**Item 3 — the card appears and goes away on its own.** Open a session on the phone. On the
Mac, get it to a permission prompt: the card must appear within a second or two without
touching the phone. Answer it *in the terminal*: the card must go away, again untouched. Both
directions ride `activityChanged` plus the fetch it triggers; if either fails, the `.onChange`
in `SessionTimelineScreen` is the first place to look.

**Item 4 — an AskUserQuestion, answered from the phone.** Ask claude to ask you something with
three options. The card must show the question, the header, and each option with its
description. Tap the third. The terminal's selection must move down twice and submit.

**Item 5 — the simple race.** Get a dialog up, let the phone show it, answer it *in the
terminal*, then tap on the phone before it refreshes. The phone must say "Your Mac has moved on
from this" and the terminal must not move.

**Item 6 — the hard race.** Answer a permission prompt on the Mac and let claude raise the next
one immediately, so the session never leaves `waiting`. Then tap the phone's stale card. It
must be refused, and **the second dialog must not be answered**. This is the case a cache would
have got wrong and re-derivation gets right; it is the most important item on this list.

**Item 7 — the write race.** Watch the moment a session goes `waiting`. If the card appears
blank or shows the previous call for a beat and then corrects itself, that is the deferred
retry in `SessionTimelineScreen` doing its job. If it stays wrong, add a SECOND retry at a
longer delay — do not turn it into a loop.

**Item 8 — a multi-select question.** Ask claude something with `multiSelect: true`. The card
must show the question and options with no buttons, and the sentence "This question takes more
than one answer. Answer it on your Mac."

**Item 9 — a historical question reads as one.** Scroll back to an answered `AskUserQuestion`.
It must render as the question and its options, not as a JSON tree.
```

- [ ] **Step 2: Add to `docs/FOLLOWUPS.md`**

```markdown
## Answering prompts from the phone — two accepted gaps

Both are scope decisions from `2026-08-24-answering-prompts-from-the-phone.md`, recorded so
that disagreeing with them is a change to a decision rather than the discovery of a bug.

- **A paired phone can approve a tool in a tab nobody is looking at**, and the only Mac-side
  signal is the terminal moving. There is no per-tab opt-in and no notification. The control
  §11 names — revocation, plus the attached-device badge in Settings → Devices — is the only
  one.
- **The permission card cannot show the dialog's own wording**, because that wording is built
  in claude's TUI from the live permission rule set and exists in no file. The card describes
  the tool call instead — which it has whole, so it is more legible than the terminal's own
  one-line summary — and offers Allow and Deny. The middle "don't ask again" rows are
  unreachable by construction (`PromptAnswer` has no case for one); that is deliberate and is
  argued in the plan's Security section, not a missing feature.
```

- [ ] **Step 3: Verify** — full four scripts, then run the checklist by hand.

- [ ] **Step 4: Commit**

```bash
git add docs/MOBILE.md docs/FOLLOWUPS.md
git commit -m "docs: what to check by hand, and what this deliberately does not do"
```

---

## Self-Review

**Spec coverage.** §9's four artefacts: `PendingPrompt` exists as `PromptQuestion`/`OpenPrompt`, but as a **local derivation on both ends rather than a wire type** — the spec assumed it would be transmitted, and finding 2 shows there is nothing to transmit. `PromptBroker` exists as `PromptService`, normalizing two *sources* rather than two agents, because codex has no route (unchanged from the preceding plan's finding 5). `prompt.opened`/`prompt.closed` are **not built**, argued from findings 2 and 3 and stated in `OpenPrompt.find`'s doc comment so a future reader meets the argument at the code. The **hook helper is not built**: §1.1's contract is the `PreToolUse` schema mislabelled, and there is no hook route to `AskUserQuestion` at all. §9's two "must get right" points are moot for this design and should be struck when the spec is amended — nothing on the Mac blocks (the dialog sits on the terminal exactly as it would have), and no settings file is written, which also closes §11's second open question. §5's rule holds: the one command routes through a `SessionStore` method the Mac's own UI could call. §4's `ack` rule holds and is load-bearing. §6's `.prompt` kind is emitted at last, by the thing it was reserved for. §10's testing rule holds: every mapping is from a fixture, two of them now captured; one loopback test has a socket; nothing touches `UITests`.

**Placeholder scan.** Test harnesses are elided in four places and each names the file to lift from: `AnswerPromptTests.makeStore`/`makeCodexStore` and `PromptServiceTests.makeService`/`makeCodexService` (from `PhonePromptDispatchTests`), `AnswerLoopbackTests.makeLoopbackFleet`/`connectLoopbackClient` and the `askUserQuestionLine`/`bashLine` constants (from `PhonePromptLoopbackTests` — put the lines in one shared file, referenced by three), and `SessionTimelineBlockedTests.makeModel`/`askItem`/`resultItem` (from `SessionTimelineModelTests` and `TimelineFixtures`). **No production code is elided.** Task 4's provenance JSON has four `<fill>` values, which are the capture's own outputs and cannot be known before it lands; Step 5 of that task is where they are written.

**Type consistency.** `OpenPrompt` is the currency end to end: `ClaudeOpenCall.find` → `PromptService.answer` → `SessionStore.answerPrompt`, and independently `OpenPrompt.find(in: feed.items,…)` → `PromptCard`. Both paths call the same `OpenPrompt.find`, which is the point. `callID` is a `String` at every boundary — `TimelineItem.Body.callID`, `OpenPrompt.callID`, `FleetCommand.answerPrompt`'s `call:`, `AnswerState.call`. `PromptAnswer` crosses unchanged from `PromptCard`'s buttons through `FleetCommand` to `SessionStore.answerPrompt`'s switch; its three cases are exhaustively handled in exactly one place. `SessionStore.AnswerDispatch.errorCode` produces six codes, `PromptService` adds `prompt_changed`, `not_waiting` and `unknown_session` — eight, all eight in `SessionTimelineModel.answerMessage(for:)`, with a `default` that names the unrecognised one. `TimelineErrorCode` is the Mac's failure type in both services; the `init(_:)` extension in Task 7 is the only new spelling. `SourceLine` crosses from `TranscriptPager` to `ClaudeOpenCall` to `PromptService.tail` unchanged.

**Ordering, and the one wrinkle.** Tasks 1–2 are FleetKit and land before anything consumes them. Task 2 leaves the app target compiling via one placeholder arm, replaced in Task 8. **Task 5's `testAnOpenAskIsAQuestion` depends on Task 9's mapper change**; that task says so and gives two acceptable resolutions with the instruction to report which was taken. Everything else is independently testable. Task 3 is the only task touching files other tasks do not, and it touches them by adding three empty methods.

**Uncertainties, carried into the code rather than left in a report.** Three, each documented at the line it affects: `ChoiceDialog.marker` rests on `❯` marking the focused row, now checked against a capture with a mutation that proves the capture exercises it; `SessionStore.answerPrompt`'s `.allow` arm rests on the dialog's first row being the plain approval, with checklist item 2 as the only real proof and an explicit instruction to rewrite the arm rather than the fixture if they disagree; and the status-file/transcript write race is named in `SessionTimelineScreen`'s deferred fetch with the ruling that the fix is a second retry, not a loop.