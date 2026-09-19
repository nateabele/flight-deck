# Hook-fed composer state — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the screen-grammar gate in front of pty injection with a hook-fed liveness signal plus a narrow `Esc to cancel` dialog veto.

**Architecture:** Flight Deck ships a Claude Code plugin in its app bundle, loaded per-session via `--plugin-dir`. Its hook scripts append one JSON line per lifecycle event to a shared NDJSON log. A single `HookEventWatcher` (mirroring `SessionStatusWatcher`) tails that log and fans `AgentEvent.lifecycle` out per conversation. `injectionGate` then consults hook-derived readiness plus a dialog veto, instead of parsing the composer's box-drawing.

**Tech Stack:** Swift 6 / macOS, XcodeGen (`project.yml`, no SwiftPM), XCTest, bash hook scripts.

**Spec:** `docs/superpowers/specs/2026-09-19-hook-fed-composer-state-design.md` — read it first; every design decision here is argued there, most of them from probe evidence.

## Global Constraints

- **Swift tests are XCTest**, never swift-testing. `@MainActor final class <Type>Tests: XCTestCase`, flat in `Tests/FlightDeckTests/`, `@testable import FlightDeck`.
- **`./scripts/test-unit.sh` ignores `-only-testing:`** and runs the whole macOS suite. Budget ~8 minutes per run. It runs `xcodegen generate` itself, so `project.yml` edits need no extra step.
- **`Bundle.main` under the test runner is the `xctest` tool, not `Flight Deck.app`.** Any bundle lookup must be an injectable seam with a `Bundle.main` default — the pattern `SessionDaemon.bundledBinary` already uses.
- **This checkout is shared with other sessions.** Never `git add -A`; stage only the files a task names. Never revert or stash other work.
- **Hooks block the agent.** Every hook script is a single append and `exit 0` on every path.
- **Never wire `PermissionRequest` or `Notification`** as state transitions. Spec §3 finding 2: deny fires no hook, so `PermissionRequest` has no observable clear; `Notification` fires for permission prompts as well as idle.
- Env var name: `FLIGHT_DECK_EVENT_DIR`. Log file name: `events.ndjson`.

---

### Task 1: The plugin payload, bundled

**Files:**
- Create: `Resources/ClaudePlugin/.claude-plugin/plugin.json`
- Create: `Resources/ClaudePlugin/hooks/hooks.json`
- Create: `Resources/ClaudePlugin/scripts/record.sh`
- Modify: `project.yml` (app target sources, and test target resources)
- Test: `Tests/FlightDeckTests/ClaudePluginPayloadTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a bundled directory locatable as `Bundle.<x>.url(forResource: "ClaudePlugin", withExtension: nil)`, containing `hooks/hooks.json` naming exactly the six lifecycle events.

- [ ] **Step 1: Write the plugin manifest**

`Resources/ClaudePlugin/.claude-plugin/plugin.json`:

```json
{
  "name": "flight-deck",
  "version": "1.0.0",
  "description": "Reports Claude Code lifecycle events to Flight Deck."
}
```

- [ ] **Step 2: Write the hooks manifest**

`Resources/ClaudePlugin/hooks/hooks.json`. Six events only — see Global Constraints for why `PermissionRequest` and `Notification` are absent.

```json
{
  "description": "Flight Deck lifecycle reporting",
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/record.sh"}]}]
  }
}
```

- [ ] **Step 3: Write the recorder script**

`Resources/ClaudePlugin/scripts/record.sh`. **One** `printf`, not two appends — two would let a concurrent hook interleave its payload between another's body and its newline.

```bash
#!/bin/bash
# Appends one JSON line per Claude Code lifecycle event for Flight Deck to tail.
#
# The payload already carries `hook_event_name` and `session_id`, so this takes
# no arguments and parses nothing — no `jq` dependency. `tr` removes only
# pretty-printing newlines; JSON strings escape their own as \n.
#
# No FLIGHT_DECK_EVENT_DIR means no Flight Deck (a user running `claude` with
# this plugin by hand). Exit 0 on every path: a hook that fails blocks the agent.
[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0
printf '%s\n' "$(cat | tr -d '\n')" >> "$FLIGHT_DECK_EVENT_DIR/events.ndjson" 2>/dev/null
exit 0
```

Then: `chmod +x Resources/ClaudePlugin/scripts/record.sh`

- [ ] **Step 4: Bundle it**

In `project.yml`, add to the **FlightDeck** target's `sources:` (a folder reference — a plain group flattens subdirectories, which would destroy `.claude-plugin/` and `hooks/`):

```yaml
      - path: Resources/ClaudePlugin
        type: folder
        buildPhase: resources
```

And the same entry to the **FlightDeckTests** target's `sources:`, so `Bundle(for:)` finds it under `xctest` (same reason `GhosttyDefaults.conf` is listed twice today).

- [ ] **Step 5: Write the failing test**

`Tests/FlightDeckTests/ClaudePluginPayloadTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Guards the shipped plugin payload. It is data, not code, so nothing else would
/// catch a malformed manifest until a live session silently reported nothing.
final class ClaudePluginPayloadTests: XCTestCase {
    private func pluginRoot() throws -> URL {
        let url = Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil)
        return try XCTUnwrap(url, "ClaudePlugin must be bundled as a folder reference")
    }

    func testHooksManifestNamesExactlyTheSixLifecycleEvents() throws {
        let url = try pluginRoot().appendingPathComponent("hooks/hooks.json")
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"],
            "PermissionRequest has no observable clear and Notification fires for permission "
                + "prompts too — see the spec. Neither may be wired."
        )
    }

    func testRecorderScriptIsExecutable() throws {
        let url = try pluginRoot().appendingPathComponent("scripts/record.sh")
        let perms = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((try XCTUnwrap(perms).intValue) & 0o111, 0o111, "must survive bundling +x")
    }

    func testRecorderIsSilentWithoutTheEnvironmentVariable() throws {
        let script = try pluginRoot().appendingPathComponent("scripts/record.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"x"}"#.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "a failing hook blocks the agent")
    }
}
```

- [ ] **Step 6: Run and verify it fails**

Run: `./scripts/test-unit.sh`
Expected: `ClaudePluginPayloadTests` fails to find `ClaudePlugin` until Step 4's `project.yml` edit is in place. If Step 4 is already done, these pass immediately — that is fine; the value is the regression guard.

- [ ] **Step 7: Verify the recorder actually appends, by hand**

```bash
mkdir -p /tmp/fd-ev && FLIGHT_DECK_EVENT_DIR=/tmp/fd-ev \
  bash Resources/ClaudePlugin/scripts/record.sh <<< '{"hook_event_name":"Stop","session_id":"a"}'
cat /tmp/fd-ev/events.ndjson
```
Expected: exactly one line, the JSON, unchanged.

- [ ] **Step 8: Commit**

```bash
git add Resources/ClaudePlugin project.yml Tests/FlightDeckTests/ClaudePluginPayloadTests.swift
git commit -m "Add the Claude Code plugin Flight Deck loads into its own sessions"
```

---

### Task 2: `ComposerReadiness` and its reducer

**Files:**
- Create: `Sources/FlightDeck/Agents/ComposerReadiness.swift`
- Test: `Tests/FlightDeckTests/ComposerReadinessTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `enum ComposerReadiness: Equatable, Sendable { case unknown, live, absent }`
  - `struct HookEventRecord: Equatable { let sessionID: UUID; let event: String; static func decode(_ line: String) -> HookEventRecord? }`
  - `static func ComposerReadiness.applying(_ event: String, to: ComposerReadiness) -> ComposerReadiness`

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/ComposerReadinessTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ComposerReadinessTests: XCTestCase {
    private let id = UUID(uuidString: "b16a1e73-b93e-4493-a396-46adc4cf02ee")!

    func testDecodesSessionIDAndEventName() {
        let line = #"{"hook_event_name":"Stop","session_id":"b16a1e73-b93e-4493-a396-46adc4cf02ee","cwd":"/w"}"#
        XCTAssertEqual(
            HookEventRecord.decode(line),
            HookEventRecord(sessionID: id, event: "Stop")
        )
    }

    func testRejectsGarbageRatherThanGuessing() {
        XCTAssertNil(HookEventRecord.decode(""))
        XCTAssertNil(HookEventRecord.decode("not json"))
        XCTAssertNil(HookEventRecord.decode(#"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(HookEventRecord.decode(#"{"session_id":"not-a-uuid","hook_event_name":"Stop"}"#))
    }

    func testEveryNonTerminalLifecycleEventMeansLive() {
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            XCTAssertEqual(
                ComposerReadiness.applying(event, to: .unknown), .live,
                "\(event) should mean the session is up"
            )
        }
    }

    func testSessionEndMeansAbsent() {
        XCTAssertEqual(ComposerReadiness.applying("SessionEnd", to: .live), .absent)
    }

    /// A renamed or newly-added upstream event must not move readiness. Degrading to the
    /// previous value keeps a Claude Code release from silently changing the gate.
    func testUnknownEventNamesAreIgnored() {
        XCTAssertEqual(ComposerReadiness.applying("SomethingNew", to: .live), .live)
        XCTAssertEqual(ComposerReadiness.applying("SomethingNew", to: .unknown), .unknown)
    }

    /// A session that ended and then reported again is a resume, not a zombie.
    func testAnEventAfterSessionEndRevivesTheSession() {
        XCTAssertEqual(ComposerReadiness.applying("SessionStart", to: .absent), .live)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'HookEventRecord' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/Agents/ComposerReadiness.swift`:

```swift
import Foundation

/// Whether an agent's own input box is there to be typed into, derived from the agent's
/// lifecycle rather than from its pixels.
///
/// **Busy versus idle is deliberately absent.** Mid-turn injection is fine — Claude queues
/// it — so every non-terminal event collapses to `.live`. Activity already has an owner
/// (`ClaudeStatusFile` → `AgentEvent.activity`); a second, differently-derived answer to
/// the same question would be free to disagree with it.
///
/// **A dialog state is deliberately absent too.** Denying a permission prompt with Esc
/// fires no hook at all (probe, 2026-09-19), so a `.dialog` entered by `PermissionRequest`
/// would have no observable clear: it would refuse injection, and the only event that
/// would clear it — `UserPromptSubmit` — is the one being refused. Dialogs are answered by
/// `AgentTextChannel.isKnownNonComposer` instead.
enum ComposerReadiness: Equatable, Sendable {
    /// No events seen for this session. Falls back to the legacy screen grammar, which is
    /// what a session restored from an older build, or one in an untrusted folder, gets.
    case unknown
    case live
    case absent
}

/// One line of the hook event log, reduced to the two fields that matter.
struct HookEventRecord: Equatable {
    let sessionID: UUID
    let event: String

    /// Fails closed: anything unrecognised yields nil and the caller keeps its last state.
    static func decode(_ line: String) -> HookEventRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = obj["session_id"] as? String,
              let sessionID = UUID(uuidString: rawID),
              let event = obj["hook_event_name"] as? String
        else { return nil }
        return HookEventRecord(sessionID: sessionID, event: event)
    }
}

extension ComposerReadiness {
    /// The whole state machine. Unknown names return `current` unchanged, so an upstream
    /// rename degrades to the previous answer rather than to a wrong one.
    static func applying(_ event: String, to current: ComposerReadiness) -> ComposerReadiness {
        switch event {
        case "SessionEnd":
            return .absent
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop":
            return .live
        default:
            return current
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/ComposerReadiness.swift Tests/FlightDeckTests/ComposerReadinessTests.swift
git commit -m "Add ComposerReadiness, derived from agent lifecycle rather than pixels"
```

---

### Task 3: `HookEventWatcher`

**Files:**
- Create: `Sources/FlightDeck/HookEventWatcher.swift`
- Test: `Tests/FlightDeckTests/HookEventWatcherTests.swift`

**Interfaces:**
- Consumes: `HookEventRecord.decode`, `ComposerReadiness.applying` (Task 2); `TailReader.read(url:offset:hasChosenStart:truncation:)` and `WatchClock` (existing).
- Produces: `final class HookEventWatcher { init(directory: URL, clock: WatchClock?, onChange: @escaping ([UUID: ComposerReadiness]) -> Void); func start(); func stop(); func drain() }` — `onChange` receives only sessions whose readiness *changed* on that read.

Model this on `TranscriptWatcher` (`Sources/FlightDeck/TranscriptWatcher.swift`): register with the shared `WatchClock` rather than owning a timer, and expose a synchronous `drain()` so tests need no expectations.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/HookEventWatcherTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class HookEventWatcherTests: XCTestCase {
    private var dir: URL!
    private let a = UUID(uuidString: "b16a1e73-b93e-4493-a396-46adc4cf02ee")!
    private let b = UUID(uuidString: "c27b2f84-c04f-45a4-b407-57bed5df13ff")!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fd-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func append(_ event: String, _ id: UUID) throws {
        let line = #"{"hook_event_name":"\#(event)","session_id":"\#(id.uuidString.lowercased())"}"# + "\n"
        let url = dir.appendingPathComponent("events.ndjson")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: url)
        }
    }

    func testReportsReadinessPerSession() throws {
        var seen: [UUID: ComposerReadiness] = [:]
        let watcher = HookEventWatcher(directory: dir, clock: nil) { changes in
            seen.merge(changes) { _, new in new }
        }
        try append("SessionStart", a)
        try append("SessionStart", b)
        try append("SessionEnd", b)
        watcher.drain()

        XCTAssertEqual(seen[a], .live)
        XCTAssertEqual(seen[b], .absent, "two sessions must not blur together")
    }

    func testOnlyReportsChanges() throws {
        var batches: [[UUID: ComposerReadiness]] = []
        let watcher = HookEventWatcher(directory: dir, clock: nil) { batches.append($0) }
        try append("SessionStart", a)
        watcher.drain()
        try append("PostToolUse", a)
        try append("Stop", a)
        watcher.drain()

        XCTAssertEqual(batches.first?[a], .live)
        XCTAssertEqual(
            batches.count, 1,
            "a second read that only reconfirms .live must not re-emit"
        )
    }

    func testAMissingDirectoryIsNotAnError() {
        let watcher = HookEventWatcher(
            directory: dir.appendingPathComponent("nope"), clock: nil
        ) { _ in XCTFail("nothing to report") }
        watcher.drain()
    }

    func testGarbageLinesAreSkippedWithoutLosingLaterOnes() throws {
        var seen: [UUID: ComposerReadiness] = [:]
        let watcher = HookEventWatcher(directory: dir, clock: nil) { seen.merge($0) { _, n in n } }
        let url = dir.appendingPathComponent("events.ndjson")
        try Data("garbage\n".utf8).write(to: url)
        try append("SessionStart", a)
        watcher.drain()

        XCTAssertEqual(seen[a], .live)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'HookEventWatcher' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/HookEventWatcher.swift`:

```swift
import Foundation

/// Tails the shared hook-event log and reports each session's `ComposerReadiness`.
///
/// **One watcher for the whole app, not one per tab** — the same shape as
/// `SessionStatusWatcher`, and for the same reason: the log is a single shared file, so a
/// per-tab watcher would re-read it N times per tick. Fan-out happens downstream, keyed by
/// the `session_id` in each record.
///
/// `TailTruncationPolicy.resumeAtEnd` is the policy for a shared append-only log: a shrink
/// means the file was rotated by another writer, and restarting from zero would replay
/// every session's history as if it were new.
@MainActor
final class HookEventWatcher {
    private let url: URL
    private weak var clock: WatchClock?
    private let onChange: ([UUID: ComposerReadiness]) -> Void

    private var offset: UInt64 = 0
    private var hasChosenStart = false
    private var readiness: [UUID: ComposerReadiness] = [:]

    init(
        directory: URL,
        clock: WatchClock?,
        onChange: @escaping ([UUID: ComposerReadiness]) -> Void
    ) {
        self.url = directory.appendingPathComponent("events.ndjson")
        self.clock = clock
        self.onChange = onChange
    }

    func start() {
        clock?.add(self) { [weak self] in self?.drain() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// Reads everything appended since the last call. Synchronous, so tests need no
    /// expectations — the seam `TranscriptWatcher.drain()` establishes.
    func drain() {
        let tail = TailReader.read(
            url: url, offset: offset, hasChosenStart: hasChosenStart, truncation: .resumeAtEnd
        )
        offset = tail.offset
        hasChosenStart = true

        var changes: [UUID: ComposerReadiness] = [:]
        for line in tail.lines {
            guard let record = HookEventRecord.decode(line) else { continue }
            let current = readiness[record.sessionID] ?? .unknown
            let next = ComposerReadiness.applying(record.event, to: current)
            guard next != current else { continue }
            readiness[record.sessionID] = next
            changes[record.sessionID] = next
        }
        guard !changes.isEmpty else { return }
        onChange(changes)
    }
}
```

> **Note for the implementer:** confirm `TailRead`'s member names against
> `Sources/FlightDeck/TailReader.swift` before writing this — the plan assumes
> `.offset` and `.lines`. If they differ, match the file, not the plan.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/HookEventWatcher.swift Tests/FlightDeckTests/HookEventWatcherTests.swift
git commit -m "Add HookEventWatcher, one shared tail over the hook event log"
```

---

### Task 4: `AgentEvent.lifecycle` and the store's readiness

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift` (the `AgentEvent` enum, ~line 48)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift` (add an `ingest` overload beside the existing one, ~line 123)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`apply(_:to:)` at ~line 6872; add stored property and watcher ownership)
- Test: `Tests/FlightDeckTests/SessionStoreComposerReadinessTests.swift`

**Interfaces:**
- Consumes: `ComposerReadiness` (Task 2), `HookEventWatcher` (Task 3).
- Produces: `AgentEvent.lifecycle(ComposerReadiness)`; `SessionStore.composerReadiness(for tabID: UUID) -> ComposerReadiness`; `ClaudeRuntime.ingest(readiness: [UUID: ComposerReadiness])`.

`SessionStore.apply(_:to:)` is the **only** exhaustive switch over `AgentEvent` in the repo — verified. Adding the case and its arm in one commit satisfies exhaustiveness everywhere.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionStoreComposerReadinessTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStoreComposerReadinessTests: XCTestCase {
    /// Follow the `makeStore` helper pattern used across the store suites (see
    /// `SessionStoreAbortTests.swift`); reuse that file's construction verbatim.
    private func makeStore() -> (SessionStore, UUID) {
        let store = SessionStore(/* match SessionStoreAbortTests.makeStore */)
        let tab = store.sessions.first!.id
        return (store, tab)
    }

    func testReadinessStartsUnknown() {
        let (store, tab) = makeStore()
        XCTAssertEqual(store.composerReadiness(for: tab), .unknown)
    }

    func testLifecycleEventUpdatesReadiness() {
        let (store, tab) = makeStore()
        store.apply(.lifecycle(.live), to: tab)
        XCTAssertEqual(store.composerReadiness(for: tab), .live)
        store.apply(.lifecycle(.absent), to: tab)
        XCTAssertEqual(store.composerReadiness(for: tab), .absent)
    }

    /// Readiness is in-memory only. Persisting it would let a crash leave a tab refusing
    /// injection forever, with no event coming to correct it.
    func testReadinessIsNotPersisted() {
        let (store, tab) = makeStore()
        store.apply(.lifecycle(.absent), to: tab)
        XCTAssertFalse(
            store.pendingPersistContainsReadiness,
            "readiness must never reach sessions.json"
        )
    }
}
```

> **Implementer:** drop the third test if no such persistence seam exists; instead assert
> by inspecting the encoded session, or delete it and rely on the fact that no `Codable`
> field was added. Do **not** invent a property to make it pass.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `lifecycle` case, no `composerReadiness(for:)`.

- [ ] **Step 3: Add the event case**

In `Sources/FlightDeck/Agents/AgentKind.swift`, inside `enum AgentEvent`:

```swift
    /// What this tab's agent lifecycle says about whether its input box is there to type
    /// into. Unlike `.activity`, which reports what the agent is *doing*, this reports
    /// whether there is anything to talk to at all. See `ComposerReadiness`.
    case lifecycle(ComposerReadiness)
```

- [ ] **Step 4: Handle it in the store**

In `SessionStore`, add the stored property beside the other per-tab maps:

```swift
    /// Hook-derived composer readiness per tab. In memory only: a persisted value could
    /// outlive the process that could correct it and leave a tab refusing injection.
    private var composerReadinessByTab: [UUID: ComposerReadiness] = [:]

    func composerReadiness(for tabID: UUID) -> ComposerReadiness {
        composerReadinessByTab[tabID] ?? .unknown
    }
```

And the arm in `apply(_:to:)`:

```swift
        case .lifecycle(let readiness):
            composerReadinessByTab[tabID] = readiness
```

- [ ] **Step 5: Fan the watcher's output out through the runtime**

In `ClaudeRuntime`, beside the existing `ingest(_ entries:)`:

```swift
    /// Fan-out point for the shared hook-event watcher, mirroring `ingest(_ entries:)` for
    /// the status registry. `SessionStore` owns the one watcher; this maps its per-session
    /// report onto the tabs subscribed to that conversation.
    func ingest(readiness: [UUID: ComposerReadiness]) {
        for (sessionID, value) in readiness {
            sources[sessionID]?.subscribers.emit(.lifecycle(value))
        }
    }
```

In `SessionStore`, own and start one watcher wherever `SessionStatusWatcher` is started, passing the same directory `ClaudeAdapter.environment(for:)` will name in Task 5.

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS, and the whole suite still green — the new case compiles everywhere because `apply` is the only exhaustive switch.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentKind.swift Sources/FlightDeck/Agents/ClaudeRuntime.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreComposerReadinessTests.swift
git commit -m "Carry ComposerReadiness through AgentEvent into the store"
```

---

### Task 5: Launch sessions with the plugin and the event directory

**Files:**
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift` (add an `environment(for:)` override)
- Create: `Sources/FlightDeck/Agents/ClaudePluginLocation.swift`
- Modify: wherever claude options are resolved — `SessionStore.swift:382` / `PreferencesStore.resolvedOptions(for:project:)`
- Test: `Tests/FlightDeckTests/ClaudePluginLocationTests.swift`

**Interfaces:**
- Consumes: `FlagSet` / `FlagValue.list` (existing); `Resources/ClaudePlugin` (Task 1).
- Produces: `enum ClaudePluginLocation { static func directory(bundle: Bundle) -> URL?; static var eventDirectory: URL }` and a `FlagSet` carrying `--plugin-dir`.

**`--plugin-dir` is already in `ClaudeFlagCatalog` as a `.list` flag**, so no serializer change is needed — inject by appending to `flags.values["--plugin-dir"]`.

**Inject at flag resolution, NOT in `ClaudeAdapter.launchCommand`.** `ClaudeAdapterTests.testLaunchCommandIsByteIdenticalToTodaysCommand` asserts the adapter is a pure pass-through to `ClaudeSession`; that property is worth keeping.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/ClaudePluginLocationTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudePluginLocationTests: XCTestCase {
    func testFindsTheBundledPluginDirectory() throws {
        let url = try XCTUnwrap(ClaudePluginLocation.directory(bundle: Bundle(for: Self.self)))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("hooks/hooks.json").path
            )
        )
    }

    /// Under `xctest`, `Bundle.main` is the test runner, not the app — so a hard-coded
    /// `Bundle.main` lookup would silently return nil in the suite and pass anyway.
    func testAnswersNilForABundleWithoutThePlugin() {
        XCTAssertNil(ClaudePluginLocation.directory(bundle: Bundle(for: NSString.self)))
    }

    func testDebugAndReleaseDoNotShareAnEventDirectory() {
        XCTAssertTrue(
            ClaudePluginLocation.eventDirectory.path.contains(ClaudePluginLocation.buildTag),
            "a shared directory would let a debug build read the real fleet's events"
        )
    }

    func testInjectingThePluginFlagPreservesUserEntries() {
        var flags = FlagSet()
        flags.values["--plugin-dir"] = .list(["/user/one"])
        let out = ClaudePluginLocation.injecting(into: flags, pluginDirectory: URL(fileURLWithPath: "/app/ClaudePlugin"))
        guard case .list(let items)? = out.values["--plugin-dir"] else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items, ["/user/one", "/app/ClaudePlugin"])
    }

    func testInjectingIsIdempotent() {
        let dir = URL(fileURLWithPath: "/app/ClaudePlugin")
        let once = ClaudePluginLocation.injecting(into: FlagSet(), pluginDirectory: dir)
        let twice = ClaudePluginLocation.injecting(into: once, pluginDirectory: dir)
        guard case .list(let items)? = twice.values["--plugin-dir"] else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items, ["/app/ClaudePlugin"], "a resume must not accumulate duplicates")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'ClaudePluginLocation' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/Agents/ClaudePluginLocation.swift`:

```swift
import Foundation

/// Where Flight Deck's own Claude Code plugin lives, and where its sessions report to.
///
/// `bundle` is a parameter rather than `Bundle.main` because under `scripts/test-unit.sh`
/// the main bundle is the `xctest` tool, not `Flight Deck.app` — the same seam
/// `SessionDaemon.bundledBinary` exists for.
enum ClaudePluginLocation {
    /// Separates a debug build's event stream from the real fleet's. Sharing one directory
    /// is the trap `sessions.json` already has.
    static var buildTag: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    static func directory(bundle: Bundle) -> URL? {
        guard let url = bundle.url(forResource: "ClaudePlugin", withExtension: nil),
              FileManager.default.fileExists(
                  atPath: url.appendingPathComponent("hooks/hooks.json").path
              )
        else { return nil }
        return url
    }

    static var eventDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("hook-events-\(buildTag)", isDirectory: true)
    }

    /// Appends the bundled plugin to whatever `--plugin-dir` entries the user already set.
    /// Idempotent: a resume re-resolves options and must not accumulate duplicates.
    static func injecting(into flags: FlagSet, pluginDirectory: URL) -> FlagSet {
        var out = flags
        var items: [String]
        if case .list(let existing)? = flags.values["--plugin-dir"] {
            items = existing
        } else {
            items = []
        }
        let path = pluginDirectory.path
        guard !items.contains(path) else { return out }
        items.append(path)
        out.values["--plugin-dir"] = .list(items)
        return out
    }
}
```

- [ ] **Step 4: Set the environment variable**

In `ClaudeAdapter`, override the protocol default (which supplies only `CLAUDE_CONFIG_DIR`):

```swift
    /// Adds the hook-event directory to claude's default home binding. Creating it here
    /// rather than at launch keeps the hook script's single append from ever hitting a
    /// missing directory.
    func environment(for account: AgentAccount) -> [String: String] {
        let events = ClaudePluginLocation.eventDirectory
        try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        return [
            account.agent.homeEnvironmentKey: account.home.path,
            "FLIGHT_DECK_EVENT_DIR": events.path,
        ]
    }
```

- [ ] **Step 5: Inject the flag at option resolution**

At the site that produces claude options for a launch (`SessionStore.swift:382`, `preferences?.resolvedOptions(for:project:)`), wrap the `.claude(FlagSet)` case:

```swift
        // The bundled plugin rides in as an ordinary `--plugin-dir` entry so it serialises,
        // quotes and round-trips exactly like a user's own. Done here rather than in
        // `ClaudeAdapter` so `launchCommand`/`resumeCommand` stay byte-identical
        // pass-throughs to `ClaudeSession` — a property `ClaudeAdapterTests` pins.
        if case .claude(let flags) = options,
           let plugin = ClaudePluginLocation.directory(bundle: .main) {
            options = .claude(ClaudePluginLocation.injecting(into: flags, pluginDirectory: plugin))
        }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the untouched `ClaudeAdapterTests` byte-identical assertions.

- [ ] **Step 7: Verify end-to-end by hand**

Launch the app from Xcode (a debug build — never swap `/Applications`), open a claude tab, then:

```bash
ls ~/Library/Application\ Support/Flight\ Deck/hook-events-debug/
cut -c1-120 ~/Library/Application\ Support/Flight\ Deck/hook-events-debug/events.ndjson
```
Expected: `events.ndjson` exists and carries `SessionStart` for the new tab's `session_id`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudePluginLocation.swift Sources/FlightDeck/Agents/ClaudeAdapter.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ClaudePluginLocationTests.swift
git commit -m "Load the bundled plugin and name the event directory at launch"
```

---

### Task 6: The dialog veto

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift` (`AgentTextChannel`, ~line 260)
- Modify: `Sources/FlightDeck/Agents/ClaudeTextChannel.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Claude/nudge-auto-mode.captured.txt`
- Test: `Tests/FlightDeckTests/ClaudeDialogVetoTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AgentTextChannel.isKnownNonComposer(_ injector: TextInjecting) -> Bool` and `static ClaudeTextChannel.isKnownNonComposer(_ viewport: String) -> Bool`.

`hasComposerBox` stays for now — Task 8 keeps it as the `.unknown` legacy path.

- [ ] **Step 1: Capture the nudge fixture**

Reproduce the dialog the probe caught and capture it in the same format as the existing
`Fixtures/Claude/*.captured.txt`. If it will not reproduce on demand, hand-author the
fixture from the probe transcript in the spec — the rows and the
`Enter to confirm · Esc to cancel` footer are what matter:

```
  Teach auto mode about your environment?

  Auto mode works better when it knows your environment. Takes about a minute.

  ❯ 1. Yes
    2. Not now
    3. Don't show again

  Enter to confirm · Esc to cancel
```

- [ ] **Step 2: Write the failing test**

`Tests/FlightDeckTests/ClaudeDialogVetoTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The veto is now the ONLY thing standing between an injection and a dialog — see the
/// spec: `.dialog` was removed because denying a permission prompt fires no hook. So this
/// corpus is load-bearing, not illustrative.
final class ClaudeDialogVetoTests: XCTestCase {
    private func viewport(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "\(name).captured", withExtension: "txt", subdirectory: "Fixtures/Claude"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let dialogs = [
        "permission-bash", "permission-write", "permission-write-60col", "permission-write-row2",
        "question-single", "question-single-247", "question-two", "question-two-answered",
        "question-two-review", "question-multi", "question-checkbox", "question-checkbox-toggled",
        "question-checkbox-submit-focused", "question-set-with-checkbox",
        "workspace-trust", "nudge-auto-mode",
    ]

    private static let composers = [
        "idle-empty-box", "busy-echo-only", "busy-draft-below-echo",
        "busy-queued-message", "busy-streaming-no-box", "busy-streaming-no-marker",
    ]

    func testEveryDialogCaptureVetoes() throws {
        for name in Self.dialogs {
            XCTAssertTrue(
                ClaudeTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) must veto — an injection here lands in a dialog"
            )
        }
    }

    /// The whole point of allowing mid-turn injection is that Claude queues it. A running
    /// turn shows `esc to interrupt`, which must not be confused with `Esc to cancel`.
    func testNoComposerCaptureVetoes() throws {
        for name in Self.composers {
            XCTAssertFalse(
                ClaudeTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) is a composer — vetoing it would refuse legitimate injection"
            )
        }
    }

    func testEscToInterruptIsNotEscToCancel() {
        XCTAssertFalse(ClaudeTextChannel.isKnownNonComposer("  esc to interrupt\n"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `isKnownNonComposer` does not exist.

- [ ] **Step 4: Add the protocol member**

In `AgentTextChannel` (`AgentAdapter.swift`):

```swift
    /// Whether the screen positively shows a dialog covering this agent's composer.
    ///
    /// **The inversion of `hasComposerBox`, and that is the point.** A predicate that must
    /// recognise a *composer* fails closed when the rendering drifts: injection stops
    /// working on a Claude Code update, silently, in production. A predicate that only
    /// fires on a positively-recognised *dialog* fails open instead — an unfamiliar
    /// composer variant still gets typed into.
    ///
    /// It is nevertheless load-bearing rather than a backstop: Claude Code raises
    /// select-list dialogs of its own right after `Stop`, and denying a permission prompt
    /// fires no hook at all, so the event stream cannot cover either case.
    func isKnownNonComposer(_ injector: TextInjecting) -> Bool
```

- [ ] **Step 5: Implement it for claude**

In `ClaudeTextChannel`:

```swift
    /// Both of Claude Code's dialog families carry this footer token, and a composer never
    /// does: a permission prompt shows `Esc to cancel · Tab to amend`, an unprompted nudge
    /// `Enter to confirm · Esc to cancel`. Matching user-facing copy with a fixed meaning
    /// is markedly more stable than matching box-drawing geometry.
    ///
    /// Case-sensitive on purpose: a running turn shows lowercase `esc to interrupt`, and
    /// mid-turn injection must stay allowed because Claude queues it.
    static let dialogFooterToken = "Esc to cancel"

    static func isKnownNonComposer(_ viewport: String) -> Bool {
        viewport.contains(dialogFooterToken)
    }

    func isKnownNonComposer(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isKnownNonComposer(viewport)
    }
```

> **Implementer:** if any fixture in `Self.dialogs` lacks the token, do **not** weaken the
> composer assertions to compensate. Add a second recognised shape (e.g. a numbered
> `❯ 1.` row) and keep both corpora passing.

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS — 16 dialog captures veto, 6 composer captures do not.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentAdapter.swift Sources/FlightDeck/Agents/ClaudeTextChannel.swift Tests/FlightDeckTests/ClaudeDialogVetoTests.swift Tests/FlightDeckTests/Fixtures/Claude/nudge-auto-mode.captured.txt
git commit -m "Add the Esc-to-cancel dialog veto, proved against the capture corpus"
```

---

### Task 7: Codex parity

**Files:**
- Modify: `Sources/FlightDeck/Agents/CodexTextChannel.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift`
- Test: `Tests/FlightDeckTests/CodexDialogVetoTests.swift`

**Interfaces:**
- Consumes: `ComposerReadiness` (Task 2), `isKnownNonComposer` (Task 6).
- Produces: `CodexTextChannel.isKnownNonComposer`; `CodexRuntime` emitting `.lifecycle`.

A UI-surfaced capability lands through the adapter for **every** adapter. Codex's readiness comes from its app-server thread status, not from hooks — an agent-specific signal is a reason to put detection behind the adapter, never to scope the feature to one agent.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/CodexDialogVetoTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class CodexDialogVetoTests: XCTestCase {
    private func viewport(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "\(name).captured", withExtension: "txt", subdirectory: "Fixtures/Codex"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Enumerate from `Fixtures/Codex/` — approval-list captures veto, composer captures
    /// do not. Mirror `ClaudeDialogVetoTests`' two-corpus shape exactly.
    func testApprovalListsVeto() throws {
        for name in try Self.approvalFixtures() {
            XCTAssertTrue(CodexTextChannel.isKnownNonComposer(try viewport(name)), name)
        }
    }

    func testComposersDoNotVeto() throws {
        for name in try Self.composerFixtures() {
            XCTAssertFalse(CodexTextChannel.isKnownNonComposer(try viewport(name)), name)
        }
    }
}
```

> **Implementer:** `Fixtures/Codex/` holds 18 entries; open it and split them into the two
> corpora by inspection, replacing `approvalFixtures()`/`composerFixtures()` with literal
> arrays exactly as `ClaudeDialogVetoTests` does. Do not invent fixtures.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `isKnownNonComposer` is not implemented for codex.

- [ ] **Step 3: Implement the codex veto**

Derive codex's own footer token from the fixtures, following `CodexTextChannel.composer(_:)`'s existing grammar. Keep the doc comment honest about which captures prove it.

- [ ] **Step 4: Emit readiness from the app-server**

In `CodexRuntime`, emit `.lifecycle(.live)` when a thread is known to the app-server and `.lifecycle(.absent)` when it ends, alongside the existing event emission.

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/CodexTextChannel.swift Sources/FlightDeck/Agents/Codex/CodexRuntime.swift Tests/FlightDeckTests/CodexDialogVetoTests.swift
git commit -m "Give codex the same readiness and veto, fed by its app-server"
```

---

### Task 8: Wire the gate

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`injectionGate`, ~line 5430)
- Test: `Tests/FlightDeckTests/SessionStoreInjectionGateTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the behaviour change. **This is the only task that alters what the app does.**

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionStoreInjectionGateTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStoreInjectionGateTests: XCTestCase {
    /// Reuse the store-suite `makeStore` helper and the existing fake `TextInjecting`
    /// (see `MidTurnDraftTests.swift` for the injector stub this suite should share).

    func testLiveAndNoDialogInjects() { /* readiness .live, viewport = idle-empty-box → injects */ }

    func testLiveButDialogOnScreenRefuses() { /* readiness .live, viewport = permission-bash → refuses */ }

    func testAbsentRefuses() { /* readiness .absent → refuses without reading the viewport */ }

    /// The migration guarantee: a session that never reported takes exactly today's path.
    func testUnknownUsesTheLegacyGrammar() { /* readiness .unknown, viewport = idle-empty-box → injects */ }

    func testUnknownWithABareShellRefuses() { /* readiness .unknown, no composer → refuses */ }

    /// The regression the design exists to avoid: a denied permission prompt fires no hook,
    /// so readiness stays .live and the tab must remain injectable once the dialog is gone.
    func testATabStaysInjectableAfterADeniedPermissionPrompt() {
        // readiness .live throughout; viewport permission-bash → refuses;
        // viewport idle-empty-box → injects. No event in between.
    }
}
```

> **Implementer:** fill each body using the suite's existing helpers. The comments state the
> exact arrangement and expectation for each; do not change them.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — the gate still calls `hasComposerBox` unconditionally.

- [ ] **Step 3: Rewrite the gate**

```swift
    private func injectionGate(
        _ id: UUID
    ) -> (channel: AgentTextChannel, injector: TextInjecting)? {
        guard let channel = session(for: id)?.agent.textChannel,
              let injector = injector(for: id)
        else { return nil }

        // Two questions, each asked of the source that can actually answer it. Whether the
        // session is up at all is a durable fact the agent reports through its own
        // lifecycle; whether a dialog is covering the composer right now is a property of
        // this instant, which only the screen knows. `.unknown` means nothing has reported
        // yet — a session restored from an older build's snapshot, one whose plugin failed
        // to load, or one in an untrusted folder — so it takes exactly the path it took
        // before this existed.
        switch composerReadiness(for: id) {
        case .absent:
            return nil
        case .live:
            if channel.isKnownNonComposer(injector) { return nil }
        case .unknown:
            if !channel.hasComposerBox(injector) { return nil }
        }

        // See `injecting`'s doc comment: this is the one place every caller funnels
        // through, so it is the one place that can refuse a second injection for a tab that
        // already has one resolving.
        guard !injecting.contains(id) else { return nil }
        return (channel, injector)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS — the whole suite, including the existing injection, rename and prompt suites.

- [ ] **Step 5: Verify end-to-end in a running app**

Launch a debug build from Xcode (never swap `/Applications` — that kills other sessions). Then, in one claude tab:

1. Idle, no dialog → send a phone prompt. **Expect:** lands as a real user turn.
2. Mid-turn → send a phone prompt. **Expect:** lands, queued by Claude.
3. Trigger a permission prompt, leave it open → send a phone prompt. **Expect:** refused.
4. Deny that prompt with Esc, then send a phone prompt. **Expect:** lands. *This is the deadlock the design was reworked to avoid — if it hangs, stop and re-read spec §3.*
5. Rename the tab from the sidebar. **Expect:** works. *(Renames were broken 100% by an earlier change in this area; treat any failure here as a P0.)*

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreInjectionGateTests.swift
git commit -m "Gate injection on hook-fed readiness plus a dialog veto"
```

---

## Self-review notes

- **Spec coverage.** §4.1 plugin → Task 1. §4.2 transport → Tasks 1, 3, 5. §4.3 readiness → Task 2. §4.4 gate → Task 8. §4.5 veto → Task 6. §4.6 codex → Task 7. §4.7 wiring → Tasks 4, 5. §5 error handling → Tasks 2, 3, 8 (`.unknown` fallback). §6 testing → every task.
- **Deliberately deferred**, both spec §8 open questions: re-introducing `PermissionRequest` as a veto strengthener, and deferring on recent keystrokes. Neither is needed for the gate to be correct.
- **Behaviour changes only in Task 8.** Tasks 1–7 are additive and independently revertible.
- **Two tasks carry implementer judgement rather than literal code** — Task 7's codex fixture split and Task 8's test bodies — because the exact fixture inventory and store-test helpers must be read from the tree. Both say explicitly what to do and what not to invent.
