# Agent Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce an adapter layer so a Flight Deck tab can run any coding agent, and land `codex` as the second one alongside `claude`.

**Architecture:** An `AgentAdapter` protocol owns four responsibilities — *prepare* (establish conversation identity), *launch* (produce the pty command), *observe* (emit normalized `AgentEvent`s), *command* (rename). An app-wide `AgentRuntime` per agent kind fans events out by conversation id. Claude conforms over its existing file-polling and text-injection code; codex conforms over a single long-lived `codex app-server` JSON-RPC subprocess.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest (app-hosted, run headless via `scripts/test-unit.sh`), `codex app-server` newline-delimited JSON-RPC over stdio.

**Spec:** `docs/superpowers/specs/2026-08-18-agent-adapters-design.md`

## Global Constraints

- **Claude behaviour must not change.** The existing unit suite is the regression net; it must be green at the end of every task. Run `./scripts/test-unit.sh` — the full suite takes ~8s, so there is no reason to skip it.
- **Never run `scripts/smoke.sh` in a loop.** It steals focus for ~40s per run and the user's typing registers as test failures.
- **This checkout is shared with other sessions.** Never `git checkout .`, `git stash`, or rebase. Commit your own files by explicit path only (`git add <path>`), never `git add -A`.
- **Codex minimum version:** the app-server v2 protocol used here is present in `codex-cli` 0.142.4. Probe the version at startup and fail loudly below it.
- **Codex thread commit rule:** `thread/start` does NOT persist a thread. `thread/name/set`, issued to the *same* app-server process, commits it. Never type `codex resume <id>` for an uncommitted thread — it fails with `ERROR: No saved session found with ID …`.
- **Codex pty cwd rule:** always launch `codex resume <id>` with the pty's cwd set to the thread's own `cwd`, or the working-directory picker blocks the session.
- **No new external dependencies.** No JSON-RPC library; the protocol is newline-delimited JSON over a pipe.
- Swift files use `///` doc comments explaining *why*, matching the density of surrounding code.

---

## File Structure

**Phase 1 — the seam (claude behaviour unchanged)**

- `Sources/FlightDeck/Agents/AgentKind.swift` — `AgentID`, `AgentBinding`, `AgentEvent`, `AgentOptions`
- `Sources/FlightDeck/Agents/AgentAdapter.swift` — the protocol
- `Sources/FlightDeck/Agents/ClaudeAdapter.swift` — claude conformance over existing `ClaudeSession`
- `Sources/FlightDeck/Agents/AgentRuntime.swift` — runtime protocol
- `Sources/FlightDeck/Agents/ClaudeRuntime.swift` — owns `TranscriptWatcher` per attachment + shared `SessionStatusWatcher`

**Phase 2 — codex**

- `Sources/FlightDeck/Agents/Codex/CodexRPC.swift` — transport: spawn, framing, request/response, notification routing
- `Sources/FlightDeck/Agents/Codex/CodexProtocol.swift` — typed params/results and notification decoding
- `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` — the `thread/start` option payload
- `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` — prepare/launch/rename
- `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` — one app-server for the app, event mapping, reconcile-on-first-contact

**Phase 3 — model, preferences, UI**

- `Sources/FlightDeck/Preferences/AgentSettings.swift` — ordered agent list + migration
- `Sources/FlightDeck/Preferences/UI/AgentsSettingsTab.swift` — replaces `ClaudeSettingsTab`
- `Sources/FlightDeck/Preferences/UI/CodexOptionsForm.swift` — codex's typed options pane
- `Sources/FlightDeck/ModifierWatcher.swift` — published modifier state for the dynamic button

**Modified:** `SessionModel.swift`, `SessionPersistence.swift`, `SessionStore.swift`, `SessionCommands.swift`, `SessionSidebar.swift`, `Preferences.swift`, `PreferencesView.swift`, `project.yml` (new sources are globbed, verify).

**Tests:** one file per unit under `Tests/FlightDeckTests/`, plus `Tests/FlightDeckTests/Fixtures/Codex/*.json` for recorded notification payloads.

---

## Task 1: Core agent types

**Files:**
- Create: `Sources/FlightDeck/Agents/AgentKind.swift`
- Test: `Tests/FlightDeckTests/AgentKindTests.swift`

**Interfaces:**
- Consumes: `SessionActivity` (existing, `Sources/FlightDeck/SessionStatus.swift`), `FlagSet` (existing)
- Produces: `AgentID`, `AgentBinding`, `AgentEvent`, `AgentOptions` — used by every later task

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

final class AgentKindTests: XCTestCase {
    func testAgentIDRoundTripsThroughItsRawValue() {
        // Persisted in sessions.json, so the raw values are a storage format, not a label.
        XCTAssertEqual(AgentID(rawValue: "claude"), .claude)
        XCTAssertEqual(AgentID(rawValue: "codex"), .codex)
        XCTAssertEqual(AgentID.claude.rawValue, "claude")
        XCTAssertNil(AgentID(rawValue: "cursor"), "unknown agents must not silently decode")
    }

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(AgentID.claude.displayName, "Claude")
        XCTAssertEqual(AgentID.codex.displayName, "Codex")
    }

    func testBindingCarriesIdentityAndOptionalTranscript() {
        let id = UUID()
        let bare = AgentBinding(conversationID: id, transcriptURL: nil)
        XCTAssertEqual(bare.conversationID, id)
        XCTAssertNil(bare.transcriptURL, "an agent that reports no path is legal")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AgentKindTests|error:"`
Expected: FAIL — compile error, `cannot find 'AgentID' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Which coding agent a tab runs. The raw value is a storage format — it is written into
/// `sessions.json` — so it is spelled explicitly rather than derived from the case name.
enum AgentID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// What a prepared session is bound to: the agent's own conversation identity, and where
/// its transcript lives when the agent reports one.
///
/// `transcriptURL` is optional because the two agents learn it differently. Claude derives
/// it from the cwd; codex returns it from `thread/start`. An agent that reports neither is
/// still usable — it just has no transcript to tail.
struct AgentBinding: Equatable, Sendable {
    let conversationID: UUID
    let transcriptURL: URL?
}

/// One state-bearing thing an agent reported. The single vocabulary `SessionStore` speaks;
/// it never learns whether this arrived by tailing a file or by JSON-RPC notification.
///
/// Widened from `ClaudeSession.TranscriptEvent`: `.activity` and `.subagentCount` are new,
/// because codex pushes both where claude makes them be inferred.
enum AgentEvent: Equatable, Sendable {
    case title(String)
    case activity(SessionActivity)
    case subagentCount(Int)
    case turnEnded
}

/// Per-agent settings payload.
///
/// A union rather than a shared bag: claude's options are a command line (`FlagSet`, with a
/// catalog, parser, serializer and shell quoting behind it) while codex's are typed
/// `thread/start` params with no command line at all. Neither shape belongs in the other.
enum AgentOptions: Equatable, Sendable {
    case claude(FlagSet)
    case codex(CodexThreadOptions)

    var agent: AgentID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}
```

Also create `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` with the minimum this compiles against; Task 7 fills it in:

```swift
import Foundation

/// The subset of codex's `thread/start` params Flight Deck exposes. Typed, not stringly:
/// codex takes these over JSON-RPC, so there is no command line to build or quote.
struct CodexThreadOptions: Codable, Equatable, Sendable {
    var model: String?
    var sandbox: String?
    var approvalPolicy: String?
    var addDirs: [String]

    init(model: String? = nil, sandbox: String? = nil, approvalPolicy: String? = nil, addDirs: [String] = []) {
        self.model = model
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.addDirs = addDirs
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, and the total test count has risen by 3 with 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentKind.swift \
        Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift \
        Tests/FlightDeckTests/AgentKindTests.swift
git commit -m "feat: add the core agent-adapter vocabulary"
```

---

## Task 2: AgentAdapter protocol and ClaudeAdapter

**Files:**
- Create: `Sources/FlightDeck/Agents/AgentAdapter.swift`, `Sources/FlightDeck/Agents/ClaudeAdapter.swift`
- Test: `Tests/FlightDeckTests/ClaudeAdapterTests.swift`

**Interfaces:**
- Consumes: `AgentID`, `AgentBinding`, `AgentOptions` (Task 1); `ClaudeSession` (existing)
- Produces: `protocol AgentAdapter` with `prepare(for:options:) async throws -> AgentBinding`, `launchCommand(_:_:_:) -> String`, `resumeCommand(_:_:_:) -> String`, `rename(_:to:) async throws`; `struct ClaudeAdapter: AgentAdapter`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()

    private func session(_ title: String = "work") -> Session {
        Session(title: title, workingDirectory: "/w/a")
    }

    func testPrepareMintsAConversationIDEqualToTheTabID() async throws {
        // Claude lets the caller choose the id (`--session-id`), and Flight Deck has always
        // used the tab's own id. Anything else would break every persisted session.
        let s = session()
        let binding = try await adapter.prepare(for: s, options: .claude(FlagSet()))
        XCTAssertEqual(binding.conversationID, s.id)
    }

    func testPrepareDerivesTheTranscriptPathFromTheWorkingDirectory() async throws {
        let s = session()
        let binding = try await adapter.prepare(for: s, options: .claude(FlagSet()))
        XCTAssertEqual(
            binding.transcriptURL,
            ClaudeSession.transcriptURL(sessionID: s.id, workingDirectory: "/w/a"),
            "the adapter must not invent a second path rule"
        )
    }

    func testLaunchCommandIsByteIdenticalToTodaysCommand() async throws {
        let s = session("my tab")
        let flags = FlagSet()
        let binding = try await adapter.prepare(for: s, options: .claude(flags))
        XCTAssertEqual(
            adapter.launchCommand(binding, s, .claude(flags)),
            ClaudeSession.launchCommand(sessionID: s.id, title: "my tab", flags: flags),
            "wrapping must not change what gets typed into the pty"
        )
    }

    func testResumeCommandIsByteIdenticalToTodaysCommand() async throws {
        let s = session("my tab")
        let flags = FlagSet()
        let binding = try await adapter.prepare(for: s, options: .claude(flags))
        XCTAssertEqual(
            adapter.resumeCommand(binding, s, .claude(flags)),
            ClaudeSession.resumeCommand(sessionID: s.id, title: "my tab", flags: flags)
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "ClaudeAdapterTests|error:"`
Expected: FAIL — `cannot find 'ClaudeAdapter' in scope`

- [ ] **Step 3: Write minimal implementation**

`AgentAdapter.swift`:

```swift
import Foundation

/// Everything `SessionStore` needs from an agent, and nothing about how that agent works.
///
/// Four responsibilities: establish identity, produce the text typed into the pty, and
/// rename. Observation is deliberately NOT here — it belongs to `AgentRuntime`, because
/// both agents multiplex one app-wide source across N tabs rather than owning a per-tab
/// channel. See the design doc §2.1.
@MainActor
protocol AgentAdapter {
    static var id: AgentID { get }

    /// Establishes conversation identity BEFORE anything is typed into a terminal.
    ///
    /// This is the load-bearing method. Claude satisfies it by minting a UUID and binding
    /// the process to it; codex satisfies it by asking its app-server and being told. Either
    /// way the caller knows the conversation id and transcript path before a pty exists,
    /// which is what makes title sync and status attribution possible from the first byte.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String

    /// Renames the agent's own conversation. Claude types `/rename` into the pty; codex
    /// sends a request. Throwing is legal — the caller keeps the local title either way.
    func rename(_ binding: AgentBinding, to title: String) async throws
}
```

`ClaudeAdapter.swift`:

```swift
import Foundation

/// Claude conformance. A thin shell over `ClaudeSession`, which stays the single source of
/// truth for command construction and path derivation.
///
/// `encodedProjectDirName` deliberately does NOT appear on `AgentAdapter`. It exists only
/// because claude has no index and must derive its transcript path from the cwd; codex is
/// handed the path outright. Putting it on the protocol would leak a claude implementation
/// detail into every future agent.
@MainActor
struct ClaudeAdapter: AgentAdapter {
    static let id: AgentID = .claude

    /// How a rename reaches `claude`: by typing `/rename <name>` into the tab's pty.
    /// Injected so tests need no terminal. Production wires this to `SessionStore.inject`.
    var injectRename: (UUID, String) async -> Void = { _, _ in }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        // Claude takes the id we choose, and Flight Deck has always chosen the tab's own.
        AgentBinding(
            conversationID: session.id,
            transcriptURL: ClaudeSession.transcriptURL(
                sessionID: session.id,
                workingDirectory: session.transcriptDirectory
            )
        )
    }

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.launchCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.resumeCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        await injectRename(binding.conversationID, title)
    }

    /// A codex payload here is a programming error, not a runtime condition: the store picks
    /// the adapter and the options together. Degrade to defaults rather than trap.
    private func flags(_ options: AgentOptions) -> FlagSet {
        if case .claude(let f) = options { return f }
        return FlagSet()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentAdapter.swift \
        Sources/FlightDeck/Agents/ClaudeAdapter.swift \
        Tests/FlightDeckTests/ClaudeAdapterTests.swift
git commit -m "feat: add the AgentAdapter protocol with a claude conformance"
```

---

## Task 3: AgentRuntime and ClaudeRuntime

**Files:**
- Create: `Sources/FlightDeck/Agents/AgentRuntime.swift`, `Sources/FlightDeck/Agents/ClaudeRuntime.swift`
- Test: `Tests/FlightDeckTests/ClaudeRuntimeTests.swift`

**Interfaces:**
- Consumes: `AgentBinding`, `AgentEvent` (Task 1); `TranscriptWatcher`, `SessionStatusWatcher`, `WatchClock`, `ClaudeStatusFile.Entry` (existing)
- Produces: `protocol AgentRuntime { func attach(_:onEvent:); func detach(_:) }`, `final class ClaudeRuntime: AgentRuntime` with `init(clock:statusRoot:)` and `func ingest(_ entries: [pid_t: ClaudeStatusFile.Entry])`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ClaudeRuntimeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func titleLine(_ title: String, _ id: UUID) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id.uuidString.lowercased())"}"# + "\n"
    }

    func testAttachForwardsATitleFromTheTranscript() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        let runtime = ClaudeRuntime()

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }

        try titleLine("renamed", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.title("renamed")])
    }

    func testDetachStopsForwarding() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        let runtime = ClaudeRuntime()

        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        runtime.attach(binding) { seen.append($0) }
        runtime.detach(binding)

        try titleLine("late", id).write(to: url, atomically: true, encoding: .utf8)
        runtime.drainForTesting()

        XCTAssertTrue(seen.isEmpty, "a detached binding must not receive events")
    }

    func testStatusEntriesBecomeActivityEvents() {
        let id = UUID()
        let runtime = ClaudeRuntime()
        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: nil)) { seen.append($0) }

        runtime.ingest([4242: ClaudeStatusFile.Entry(
            pid: 4242, sessionID: id, activity: .busy, waitingFor: nil, procStart: 1
        )])

        XCTAssertEqual(seen, [.activity(.busy)])
    }
}
```

> If `ClaudeStatusFile.Entry`'s memberwise initialiser differs from the call above, read
> `Sources/FlightDeck/ClaudeStatusFile.swift:12-50` and use its real signature — do not
> change the type to fit the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "ClaudeRuntimeTests|error:"`
Expected: FAIL — `cannot find 'ClaudeRuntime' in scope`

- [ ] **Step 3: Write minimal implementation**

`AgentRuntime.swift`:

```swift
import Foundation

/// The observation half of an agent integration, kept off `AgentAdapter` because both
/// agents multiplex ONE app-wide source across N tabs: claude's status registry is a single
/// flat pid-keyed directory, and a codex app-server owns every thread it created. A
/// per-session runtime would re-scan the registry N times for claude and, for codex, lose
/// every thread the moment its short-lived process exited.
@MainActor
protocol AgentRuntime: AnyObject {
    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void)
    func detach(_ binding: AgentBinding)
}
```

`ClaudeRuntime.swift`:

```swift
import Foundation

/// Claude's runtime: one `TranscriptWatcher` per attached tab (the transcript is per
/// conversation) plus the single shared `SessionStatusWatcher` (the registry is not).
@MainActor
final class ClaudeRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        let watcher: TranscriptWatcher?
    }

    private var attachments: [UUID: Attachment] = [:]
    private let clock: WatchClock?

    init(clock: WatchClock? = nil) {
        self.clock = clock
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        let id = binding.conversationID
        var watcher: TranscriptWatcher?
        if let url = binding.transcriptURL {
            watcher = TranscriptWatcher(
                sessionID: id,
                url: url,
                clock: clock,
                onTitle: { onEvent(.title($0)) },
                onSubagentCount: { onEvent(.subagentCount($0)) }
            )
            watcher?.start()
        }
        attachments[id] = Attachment(onEvent: onEvent, watcher: watcher)
    }

    func detach(_ binding: AgentBinding) {
        attachments[binding.conversationID]?.watcher?.stop()
        attachments[binding.conversationID] = nil
    }

    /// Fan-out point for the shared status watcher. `SessionStore` owns the one
    /// `SessionStatusWatcher` and hands its output here rather than this type owning a
    /// second one — the registry must be scanned once per tick, not once per tab.
    func ingest(_ entries: [pid_t: ClaudeStatusFile.Entry]) {
        for entry in entries.values {
            guard let attachment = attachments[entry.sessionID] else { continue }
            attachment.onEvent(.activity(entry.activity))
        }
    }

    /// Test seam mirroring `TranscriptWatcher.drain()`, so runtime tests need no clock.
    func drainForTesting() {
        for attachment in attachments.values { attachment.watcher?.drain() }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentRuntime.swift \
        Sources/FlightDeck/Agents/ClaudeRuntime.swift \
        Tests/FlightDeckTests/ClaudeRuntimeTests.swift
git commit -m "feat: add AgentRuntime with the claude observation path"
```

---

## Task 4: Session.agent and persistence migration

**Files:**
- Modify: `Sources/FlightDeck/SessionModel.swift:5-45`, `Sources/FlightDeck/SessionPersistence.swift:10-40`
- Test: `Tests/FlightDeckTests/AgentPersistenceTests.swift`

**Interfaces:**
- Consumes: `AgentID` (Task 1)
- Produces: `Session.agent: AgentID`, `Session.transcriptPath: String?`, and the matching optional fields on `SessionSnapshot.Entry`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

final class AgentPersistenceTests: XCTestCase {
    func testASessionDefaultsToClaude() {
        // Every session that exists today is a claude session; the default is what makes
        // the migration a no-op rather than a data change.
        XCTAssertEqual(Session(title: "t", workingDirectory: "/w").agent, .claude)
    }

    func testAnEntryWithNoAgentFieldDecodesAsClaude() throws {
        // Exactly the shape already on disk in sessions.json — no `agent` key at all.
        let json = """
        {"id":"\(UUID().uuidString)","title":"old","workingDirectory":"/w"}
        """
        let entry = try JSONDecoder().decode(SessionSnapshot.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.agent ?? .claude, .claude, "old snapshots must migrate by omission")
    }

    func testACodexEntryRoundTrips() throws {
        var entry = SessionSnapshot.Entry(id: UUID(), title: "t", workingDirectory: "/w")
        entry.agent = .codex
        entry.transcriptPath = "/Users/x/.codex/sessions/2026/08/18/rollout-abc.jsonl"

        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(SessionSnapshot.Entry.self, from: data)

        XCTAssertEqual(back.agent, .codex)
        XCTAssertEqual(back.transcriptPath, entry.transcriptPath)
    }
}
```

> `SessionSnapshot.Entry`'s real initialiser is at `SessionPersistence.swift:10-40`; read it
> and match, rather than adding a convenience init to satisfy the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AgentPersistenceTests|error:"`
Expected: FAIL — `value of type 'Session' has no member 'agent'`

- [ ] **Step 3: Write minimal implementation**

In `SessionModel.swift`, add to `Session` (and to its `init`, defaulted):

```swift
    /// Which coding agent this tab runs. Defaulted to `.claude` so every session that
    /// predates agent adapters keeps working: a snapshot with no `agent` key decodes to
    /// claude, which is what it has always been.
    var agent: AgentID = .claude

    /// An absolute transcript path reported by the agent, for agents that report one.
    ///
    /// Distinct from `transcriptDirectory`, which is claude's *input* to path derivation and
    /// follows the live cwd. Codex hands back a full path that does not move when the cwd
    /// changes, so there is nothing to derive and nothing to retarget.
    var transcriptPath: String?
```

In `SessionPersistence.swift`, add the mirrored optional fields to `Entry`:

```swift
        /// Absent in every snapshot written before agent adapters; `nil` means claude.
        var agent: AgentID?
        var transcriptPath: String?
```

Then thread both through wherever `Entry` is built from a `Session` and back — search with
`rg -n "SessionSnapshot.Entry\(|Session\(" Sources/FlightDeck/SessionStore.swift` and update
each site, mapping `entry.agent ?? .claude` on the way in.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures — including every existing `SessionPersistenceTests` case, which
is the check that the migration really is a no-op

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionModel.swift Sources/FlightDeck/SessionPersistence.swift \
        Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AgentPersistenceTests.swift
git commit -m "feat: record which agent a session runs, defaulting to claude"
```

---

## Task 5: Route SessionStore through the adapter

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — the ~20 `ClaudeSession.*` call sites plus watcher lifecycle
- Test: `Tests/FlightDeckTests/AgentRoutingTests.swift`

**Interfaces:**
- Consumes: `AgentAdapter`, `ClaudeAdapter` (Task 2), `AgentRuntime`, `ClaudeRuntime` (Task 3), `Session.agent` (Task 4)
- Produces: `SessionStore.adapter(for: AgentID) -> any AgentAdapter`, `SessionStore.runtime(for: AgentID) -> any AgentRuntime`, and a `FakeAgentRuntime` test double in `Tests/FlightDeckTests/FakeAgentRuntime.swift`

This is the highest-risk task in the plan: it moves a working path onto a new seam. The
existing suite is the safety net — it must be green before and after, with no test edited to
accommodate the refactor. If a test needs changing to pass, that is a behaviour change and
the refactor is wrong.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class AgentRoutingTests: XCTestCase {
    func testTheStoreSelectsAnAdapterByTheSessionsAgent() {
        let store = SessionStore()
        XCTAssertEqual(type(of: store.adapter(for: .claude)).id, .claude)
    }

    func testEventsFromARuntimeReachTheSessionTitle() async {
        let store = SessionStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude)

        let id = store.createSessionForTesting(title: "before", directory: "/w/a")
        fake.emit(.title("after"), for: id)

        XCTAssertEqual(store.session(id)?.title, "after",
                       "a runtime event must move the sidebar title")
    }
}
```

And `Tests/FlightDeckTests/FakeAgentRuntime.swift`:

```swift
import Foundation
@testable import FlightDeck

/// Lets store tests exercise both agents with no processes, no files and no clock —
/// the same role `SpyInjector` plays for text injection.
@MainActor
final class FakeAgentRuntime: AgentRuntime {
    private var handlers: [UUID: (AgentEvent) -> Void] = [:]
    private(set) var attached: [UUID] = []
    private(set) var detached: [UUID] = []

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        handlers[binding.conversationID] = onEvent
        attached.append(binding.conversationID)
    }

    func detach(_ binding: AgentBinding) {
        handlers[binding.conversationID] = nil
        detached.append(binding.conversationID)
    }

    func emit(_ event: AgentEvent, for conversationID: UUID) {
        handlers[conversationID]?(event)
    }
}
```

> `createSessionForTesting` and `session(_:)` may not exist under those names. Read
> `SessionStore.swift` and use the real seams the existing tests use (see
> `Tests/FlightDeckTests/SessionCreationTests.swift`); add a thin test-only helper only if
> there is genuinely none.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AgentRoutingTests|error:"`
Expected: FAIL — `value of type 'SessionStore' has no member 'adapter'`

- [ ] **Step 3: Write minimal implementation**

Add to `SessionStore`:

```swift
    // `injectRename` is wired to whatever `rename(_:to:)` already funnels through today —
    // read `SessionStore.swift:1096-1170` and reuse that path rather than adding a second
    // injection route. The single `injecting` guard there is load-bearing.
    private lazy var adapters: [AgentID: any AgentAdapter] = [.claude: ClaudeAdapter(
        injectRename: { [weak self] id, title in self?.injectPendingRename(id, title) ?? () }
    )]
    private lazy var runtimes: [AgentID: any AgentRuntime] = [.claude: ClaudeRuntime(clock: clock)]

    func adapter(for agent: AgentID) -> any AgentAdapter { adapters[agent] ?? ClaudeAdapter() }
    func runtime(for agent: AgentID) -> any AgentRuntime { runtimes[agent] ?? ClaudeRuntime() }

    /// Test seams, in the style of `injectorOverride`. Both are needed: runtime tests fake
    /// the event source, adapter tests fake identity negotiation.
    func overrideRuntime(_ runtime: any AgentRuntime, for agent: AgentID) {
        runtimes[agent] = runtime
    }

    func overrideAdapter(_ adapter: any AgentAdapter, for agent: AgentID) {
        adapters[agent] = adapter
    }
```

Then replace each `ClaudeSession.*` call site with the adapter equivalent, one site at a
time, running the suite between each:

- `SessionStore.swift:375` — `initialInput: ClaudeSession.launchCommand(...)` becomes
  `adapter.launchCommand(binding, session, options)`, with `binding` obtained from
  `await adapter.prepare(for:options:)` before the surface is created.
- `SessionStore.swift:594` — same substitution with `resumeCommand`.
- `startWatching(tabID:conversationID:url:)` becomes
  `runtime(for: session.agent).attach(binding) { [weak self] in self?.apply($0, to: tabID) }`,
  and `watchers[id]?.stop()` becomes `runtime.detach(binding)`.
- Route `SessionStatusWatcher`'s `onChange` into `ClaudeRuntime.ingest(_:)` instead of
  writing `statuses` directly.

Add the single fold that replaces the per-event handlers:

```swift
    /// One place where an agent's report becomes tab state, whichever agent reported it.
    private func apply(_ event: AgentEvent, to tabID: UUID) {
        switch event {
        case .title(let title):      applyExternalTitle(title, to: tabID)
        case .activity(let activity): applyActivity(activity, to: tabID)
        case .subagentCount(let n):   applySubagentCount(n, to: tabID)
        case .turnEnded:              applyTurnEnded(to: tabID)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures. Confirm the pre-existing test count is unchanged apart from the
new cases — a *dropped* test means a file stopped compiling and was silently excluded.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AgentRoutingTests.swift \
        Tests/FlightDeckTests/FakeAgentRuntime.swift
git commit -m "refactor: route session launch and observation through the agent seam"
```

---

## Task 6: Codex JSON-RPC transport

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexRPC.swift`
- Test: `Tests/FlightDeckTests/CodexRPCTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `protocol CodexTransport { func send(_ line: String); var onLine: ((String) -> Void)? { get set } }`, `final class CodexRPC` with `init(transport:)`, `func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any]`, `var onNotification: ((String, [String: Any]) -> Void)?`, and `enum CodexRPCError { case transportClosed, remote(code: Int, message: String), timeout }`

The wire format is newline-delimited JSON — one JSON object per line, no Content-Length
framing. Verified against `codex app-server` directly.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexRPCTests: XCTestCase {
    /// In-memory transport: no subprocess, no pipes, no timing.
    final class StubTransport: CodexTransport {
        var sent: [String] = []
        var onLine: ((String) -> Void)?
        func send(_ line: String) { sent.append(line) }
        func reply(_ json: String) { onLine?(json) }
    }

    func testARequestSerialisesAsOneJSONLine() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        Task { try? await rpc.request("thread/start", ["cwd": "/w/a"]) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let line = try XCTUnwrap(t.sent.first)
        XCTAssertFalse(line.dropLast().contains("\n"), "the frame is exactly one line")
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["method"] as? String, "thread/start")
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(obj["id"], "a request must be correlatable")
    }

    func testAResultResolvesTheMatchingRequest() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result = rpc.request("thread/start", ["cwd": "/w/a"])
        try await Task.sleep(nanoseconds: 50_000_000)
        t.reply(#"{"id":1,"result":{"thread":{"id":"abc"}}}"#)

        let thread = try await (result["thread"] as? [String: Any])
        XCTAssertEqual(thread?["id"] as? String, "abc")
    }

    func testAnErrorResponseThrowsWithTheRemoteMessage() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result: [String: Any] = rpc.request("thread/name/set", ["threadId": "nope"])
        try await Task.sleep(nanoseconds: 50_000_000)
        t.reply(#"{"id":1,"error":{"code":-32602,"message":"no such thread"}}"#)

        do {
            _ = try await result
            XCTFail("an error response must not resolve")
        } catch CodexRPCError.remote(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "no such thread")
        }
    }

    func testNotificationsAreDeliveredSeparatelyFromResponses() {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        var seen: [(String, [String: Any])] = []
        rpc.onNotification = { seen.append(($0, $1)) }
        t.reply(#"{"method":"thread/name/updated","params":{"threadId":"abc","threadName":"x"}}"#)

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "thread/name/updated")
        XCTAssertEqual(seen.first?.1["threadName"] as? String, "x")
    }

    func testAClosedTransportFailsPendingRequestsRatherThanHanging() async throws {
        let t = StubTransport()
        let rpc = CodexRPC(transport: t)

        async let result: [String: Any] = rpc.request("thread/start", ["cwd": "/w"])
        try await Task.sleep(nanoseconds: 50_000_000)
        rpc.transportClosed()

        do {
            _ = try await result
            XCTFail("a dead app-server must surface, not hang the tab forever")
        } catch CodexRPCError.transportClosed {}
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexRPCTests|error:"`
Expected: FAIL — `cannot find 'CodexRPC' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Byte plumbing, split from `CodexRPC` so the protocol logic is testable without a process.
@MainActor
protocol CodexTransport: AnyObject {
    func send(_ line: String)
    var onLine: ((String) -> Void)? { get set }
}

enum CodexRPCError: Error, Equatable {
    case transportClosed
    case remote(code: Int, message: String)
    case malformed(String)
}

/// Newline-delimited JSON-RPC 2.0 against `codex app-server`.
///
/// One object per line — NOT the Content-Length framing LSP and MCP use. Verified directly
/// against the binary; sending a length header gets no response at all.
@MainActor
final class CodexRPC {
    private let transport: CodexTransport
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    var onNotification: ((String, [String: Any]) -> Void)?

    init(transport: CodexTransport) {
        self.transport = transport
        transport.onLine = { [weak self] line in self?.receive(line) }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8)
        else { throw CodexRPCError.malformed(method) }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            transport.send(line + "\n")
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        transport.send(line + "\n")
    }

    /// Every in-flight request fails rather than hanging. A tab waiting forever on a dead
    /// app-server is indistinguishable from a hung agent, which is the worst failure mode.
    func transportClosed() {
        for continuation in pending.values { continuation.resume(throwing: CodexRPCError.transportClosed) }
        pending.removeAll()
    }

    private func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        else { return }   // codex emits non-JSON banners; they are not errors

        if let id = obj["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = obj["error"] as? [String: Any] {
                continuation.resume(throwing: CodexRPCError.remote(
                    code: error["code"] as? Int ?? 0,
                    message: error["message"] as? String ?? "unknown"
                ))
            } else {
                continuation.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
            return
        }

        if let method = obj["method"] as? String, obj["id"] == nil {
            onNotification?(method, obj["params"] as? [String: Any] ?? [:])
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRPC.swift Tests/FlightDeckTests/CodexRPCTests.swift
git commit -m "feat: add a newline-delimited JSON-RPC client for codex app-server"
```

---

## Task 7: CodexAdapter — the prepare transaction

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` (add `asThreadStartParams`)
- Test: `Tests/FlightDeckTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `CodexRPC` (Task 6), `AgentAdapter`, `AgentBinding` (Tasks 1-2)
- Produces: `struct CodexAdapter: AgentAdapter` with `init(rpc: CodexRPC)`; `CodexThreadOptions.asThreadStartParams(cwd:) -> [String: Any]`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexAdapterTests: XCTestCase {
    /// Records the call order and answers each method with a canned result.
    final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        var threadID = "01a01269-baa6-7493-8d15-8fa21bcb602b"
        var failNameSet = false

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            methods.append(method)
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(threadID)","cwd":"/w/a","path":"/r/\#(threadID).jsonl"}}}"#)
            case "thread/name/set":
                onLine?(failNameSet
                    ? #"{"id":\#(id),"error":{"code":-32000,"message":"boom"}}"#
                    : #"{"id":\#(id),"result":{}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private func makeAdapter() -> (CodexAdapter, ScriptedTransport) {
        let t = ScriptedTransport()
        return (CodexAdapter(rpc: CodexRPC(transport: t)), t)
    }

    func testPrepareStartsThenNamesTheThread() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        // Order is load-bearing: thread/start alone does NOT persist the thread, so naming
        // it is what commits it. Reversing these leaves a thread codex cannot resume.
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set"])
        XCTAssertEqual(binding.conversationID.uuidString.lowercased(), t.threadID)
        XCTAssertEqual(binding.transcriptURL?.path, "/r/\(t.threadID).jsonl")
    }

    func testPrepareFailsWhenTheThreadCannotBeCommitted() async {
        let (adapter, t) = makeAdapter()
        t.failNameSet = true
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("an uncommitted thread must not be handed back — `codex resume` would fail on it")
        } catch {}
    }

    func testLaunchCommandResumesTheBoundThread() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "my tab", workingDirectory: "/w/a")
        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(
            adapter.launchCommand(binding, session, .codex(CodexThreadOptions())),
            "codex resume \(t.threadID)\n"
        )
    }

    func testRenameSendsThreadNameSet() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "t", workingDirectory: "/w/a")
        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        try await adapter.rename(binding, to: "renamed")

        XCTAssertEqual(t.methods.last, "thread/name/set",
                       "rename is a request, not text typed into a pty")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexAdapterTests|error:"`
Expected: FAIL — `cannot find 'CodexAdapter' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Codex conformance, driven over `codex app-server` JSON-RPC rather than by typing at a pty.
///
/// The inversion versus claude is deliberate and forced by the tool: codex assigns thread
/// ids itself, so identity is *returned* rather than minted. What matters is that it is
/// still known before a terminal exists, which is the property the rest of the app relies on.
@MainActor
struct CodexAdapter: AgentAdapter {
    static let id: AgentID = .codex

    let rpc: CodexRPC

    /// Start, then name. NOT optional and NOT reorderable.
    ///
    /// `thread/start` does not persist anything: no `threads` row, no rollout file, even
    /// with the app-server left alive. `thread/name/set` — issued to the same app-server
    /// process — commits it. Skip the name and `codex resume <id>` dies with
    /// `ERROR: No saved session found with ID …`, which is a tab that can never launch.
    /// Naming costs nothing anyway: the tab already has the title we want to set.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let params = threadOptions(options).asThreadStartParams(cwd: session.transcriptDirectory)
        let result = try await rpc.request("thread/start", params)

        guard let thread = result["thread"] as? [String: Any],
              let raw = thread["id"] as? String,
              let id = UUID(uuidString: raw)
        else { throw CodexRPCError.malformed("thread/start returned no usable thread id") }

        // Commit. A failure here must propagate: a bound-but-uncommitted thread is worse
        // than no tab, because it looks fine until the terminal reports it cannot resume.
        _ = try await rpc.request("thread/name/set", ["threadId": raw, "name": session.title])

        return AgentBinding(
            conversationID: id,
            transcriptURL: (thread["path"] as? String).map { URL(fileURLWithPath: $0) }
        )
    }

    /// Launch and resume are the same command: the thread already exists by the time any
    /// terminal opens, so there is no "first run" to distinguish.
    ///
    /// The caller MUST spawn this with the pty's cwd set to the thread's own cwd. Codex
    /// otherwise opens a "Choose working directory" picker that blocks the session behind a
    /// prompt with one sane answer.
    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        "codex resume \(binding.conversationID.uuidString.lowercased())\n"
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        launchCommand(binding, session, options)
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        _ = try await rpc.request("thread/name/set", [
            "threadId": binding.conversationID.uuidString.lowercased(),
            "name": title,
        ])
    }

    private func threadOptions(_ options: AgentOptions) -> CodexThreadOptions {
        if case .codex(let o) = options { return o }
        return CodexThreadOptions()
    }
}
```

Add to `CodexThreadOptions`:

```swift
    /// Typed params, not a command line. Omitted keys mean "codex's own default" — sending
    /// an explicit null would pin the value and defeat the user's `config.toml`.
    func asThreadStartParams(cwd: String) -> [String: Any] {
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if !addDirs.isEmpty { params["addDirs"] = addDirs }
        return params
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexAdapter.swift \
        Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift \
        Tests/FlightDeckTests/CodexAdapterTests.swift
git commit -m "feat: add the codex adapter with its start-then-name commit transaction"
```

---

## Task 8: Map codex notifications to AgentEvent

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Codex/notifications.json`
- Test: `Tests/FlightDeckTests/CodexEventMapperTests.swift`

**Interfaces:**
- Consumes: `AgentEvent` (Task 1)
- Produces: `enum CodexEventMapper { static func events(method: String, params: [String: Any], state: inout CodexThreadState) -> [AgentEvent] }` and `struct CodexThreadState { var subagents: [String: String] }`

- [ ] **Step 1: Write the fixture and the failing test**

`Tests/FlightDeckTests/Fixtures/Codex/notifications.json` — payload shapes captured from a
real `codex app-server` (0.147.0). Keep them verbatim; they are the contract:

```json
{
  "nameUpdated": {"threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b", "threadName": "flight-deck spike"},
  "turnStarted": {"threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b", "turnId": "t1"},
  "turnCompleted": {"threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b", "turnId": "t1"},
  "spawnTwo": {
    "threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b",
    "turnId": "t1",
    "startedAtMs": 1787015279623,
    "item": {
      "type": "collabAgentToolCall",
      "id": "c1",
      "tool": "spawnAgent",
      "status": "inProgress",
      "senderThreadId": "01a01269-baa6-7493-8d15-8fa21bcb602b",
      "receiverThreadIds": ["sub-a", "sub-b"],
      "agentsStates": {"sub-a": "running", "sub-b": "running"}
    }
  },
  "oneFinished": {
    "threadId": "01a01269-baa6-7493-8d15-8fa21bcb602b",
    "turnId": "t1",
    "startedAtMs": 1787015280000,
    "item": {
      "type": "collabAgentToolCall",
      "id": "c1",
      "tool": "closeAgent",
      "status": "completed",
      "senderThreadId": "01a01269-baa6-7493-8d15-8fa21bcb602b",
      "receiverThreadIds": ["sub-a"],
      "agentsStates": {"sub-a": "completed", "sub-b": "running"}
    }
  }
}
```

```swift
import XCTest
@testable import FlightDeck

final class CodexEventMapperTests: XCTestCase {
    private func fixture(_ key: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: "notifications", withExtension: "json", subdirectory: "Fixtures/Codex")
            ?? Bundle(for: Self.self).url(forResource: "notifications", withExtension: "json"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try XCTUnwrap(root[key] as? [String: Any])
    }

    func testNameUpdatedBecomesATitleEvent() throws {
        var state = CodexThreadState()
        let events = CodexEventMapper.events(
            method: "thread/name/updated", params: try fixture("nameUpdated"), state: &state
        )
        XCTAssertEqual(events, [.title("flight-deck spike")])
    }

    func testTurnStartedAndCompletedDriveActivityAndTurnEnd() throws {
        var state = CodexThreadState()
        XCTAssertEqual(
            CodexEventMapper.events(method: "turn/started", params: try fixture("turnStarted"), state: &state),
            [.activity(.busy)]
        )
        // `.turnEnded` is what `SessionReadPolicy` marks unread from, so it must accompany idle.
        XCTAssertEqual(
            CodexEventMapper.events(method: "turn/completed", params: try fixture("turnCompleted"), state: &state),
            [.activity(.idle), .turnEnded]
        )
    }

    func testSubagentCountIsRecomputedFromAgentsStates() throws {
        var state = CodexThreadState()

        XCTAssertEqual(
            CodexEventMapper.events(method: "item/started", params: try fixture("spawnTwo"), state: &state),
            [.subagentCount(2)]
        )
        // Recomputed from the payload's own map, not decremented. `agentsStates` carries the
        // full current state every time, so the count cannot drift and needs no turn-boundary
        // clearing — which is exactly the fragile part of claude's `outstandingAgents`.
        XCTAssertEqual(
            CodexEventMapper.events(method: "item/completed", params: try fixture("oneFinished"), state: &state),
            [.subagentCount(1)]
        )
    }

    func testUnrelatedNotificationsProduceNothing() {
        var state = CodexThreadState()
        XCTAssertTrue(CodexEventMapper.events(
            method: "mcpServer/startupStatus/updated", params: [:], state: &state
        ).isEmpty)
    }
}
```

> Add `Tests/FlightDeckTests/Fixtures/` to the test target's resources in `project.yml` if
> the bundle lookup fails, then re-run `xcodegen generate` via `scripts/test-unit.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexEventMapperTests|error:"`
Expected: FAIL — `cannot find 'CodexEventMapper' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Per-thread state the mapper carries between notifications. Small on purpose: codex
/// pushes enough that almost nothing needs remembering.
struct CodexThreadState: Equatable {
    /// Last known state of each sub-agent, keyed by its thread id. Replaced wholesale from
    /// every `collabAgentToolCall.agentsStates`, never incremented.
    var subagents: [String: String] = [:]
}

/// Translates codex app-server notifications into the app's own vocabulary.
///
/// Pure and static so every mapping is testable from a recorded payload with no process,
/// no socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` is pure.
enum CodexEventMapper {
    /// States that mean a sub-agent is still occupying a slot. Anything else — completed,
    /// failed, cancelled — is finished. Listing the *live* states rather than the dead ones
    /// means an unfamiliar state reads as finished, so an unknown value cannot pin the
    /// spinner on forever.
    private static let liveStates: Set<String> = ["running", "inProgress", "started", "interacted"]

    static func events(
        method: String, params: [String: Any], state: inout CodexThreadState
    ) -> [AgentEvent] {
        switch method {
        case "thread/name/updated":
            guard let name = params["threadName"] as? String else { return [] }
            return [.title(name)]

        case "turn/started":
            return [.activity(.busy)]

        case "turn/completed", "turn/aborted":
            return [.activity(.idle), .turnEnded]

        case "thread/status/changed":
            guard let raw = (params["status"] as? [String: Any])?["type"] as? String,
                  let activity = activity(forThreadStatus: raw)
            else { return [] }
            return [.activity(activity)]

        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any],
                  item["type"] as? String == "collabAgentToolCall",
                  let states = item["agentsStates"] as? [String: String]
            else { return [] }
            state.subagents = states
            let live = states.values.filter { liveStates.contains($0) }.count
            return [.subagentCount(live)]

        default:
            return []
        }
    }

    private static func activity(forThreadStatus raw: String) -> SessionActivity? {
        switch raw {
        case "running", "busy": .busy
        case "idle", "notLoaded": .idle
        default: nil   // an unknown status must not overwrite a known one
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift \
        Tests/FlightDeckTests/CodexEventMapperTests.swift \
        Tests/FlightDeckTests/Fixtures/Codex/notifications.json project.yml
git commit -m "feat: map codex notifications onto the shared agent event vocabulary"
```

---

## Task 9: CodexRuntime — process lifecycle, routing, reconcile

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift`
- Test: `Tests/FlightDeckTests/CodexRuntimeTests.swift`

**Interfaces:**
- Consumes: `CodexRPC`, `CodexTransport` (Task 6), `CodexEventMapper` (Task 8), `AgentRuntime` (Task 3)
- Produces: `final class CodexRuntime: AgentRuntime` with `init(rpc: CodexRPC)`, `func handle(method:params:)`, and `var reconcile: (UUID) async -> Void`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexRuntimeTests: XCTestCase {
    final class NullTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}
    }

    private func makeRuntime() -> CodexRuntime {
        CodexRuntime(rpc: CodexRPC(transport: NullTransport()))
    }

    private let threadID = UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b")!

    func testNotificationsReachOnlyTheMatchingAttachment() {
        let runtime = makeRuntime()
        var mine: [AgentEvent] = []
        var theirs: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: threadID, transcriptURL: nil)) { mine.append($0) }
        runtime.attach(AgentBinding(conversationID: UUID(), transcriptURL: nil)) { theirs.append($0) }

        runtime.handle(method: "thread/name/updated",
                       params: ["threadId": threadID.uuidString.lowercased(), "threadName": "x"])

        XCTAssertEqual(mine, [.title("x")])
        XCTAssertTrue(theirs.isEmpty, "notifications are multiplexed by threadId, not broadcast")
    }

    func testFirstContactTriggersExactlyOneReconcile() async {
        let runtime = makeRuntime()
        var reconciled: [UUID] = []
        runtime.reconcile = { reconciled.append($0) }
        runtime.attach(AgentBinding(conversationID: threadID, transcriptURL: nil)) { _ in }

        let id = threadID.uuidString.lowercased()
        // A session that launched behind the hooks-review prompt reports nothing until the
        // user clears it. The first notification of ANY kind is the cue to re-read
        // authoritative title and status — once, not on every notification.
        runtime.handle(method: "turn/started", params: ["threadId": id])
        runtime.handle(method: "turn/completed", params: ["threadId": id])
        await Task.yield()

        XCTAssertEqual(reconciled, [threadID])
    }

    func testDetachStopsRouting() {
        let runtime = makeRuntime()
        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: threadID, transcriptURL: nil)
        runtime.attach(binding) { seen.append($0) }
        runtime.detach(binding)

        runtime.handle(method: "thread/name/updated",
                       params: ["threadId": threadID.uuidString.lowercased(), "threadName": "x"])

        XCTAssertTrue(seen.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexRuntimeTests|error:"`
Expected: FAIL — `cannot find 'CodexRuntime' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Codex's observation half: one app-server for the whole app, notifications routed by
/// `threadId`.
///
/// One connection rather than one per tab is not an optimisation — a thread lives in the
/// app-server process that created it, so a per-call process would lose every thread it
/// made the moment it exited.
@MainActor
final class CodexRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        var state = CodexThreadState()
        var hasReconciled = false
    }

    private var attachments: [UUID: Attachment] = [:]
    private let rpc: CodexRPC

    /// Re-reads authoritative title and status for a thread. Injected so tests need no
    /// server; production wires it to `thread/read`.
    var reconcile: (UUID) async -> Void = { _ in }

    init(rpc: CodexRPC) {
        self.rpc = rpc
        rpc.onNotification = { [weak self] method, params in
            self?.handle(method: method, params: params)
        }
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        attachments[binding.conversationID] = Attachment(onEvent: onEvent)
    }

    func detach(_ binding: AgentBinding) {
        attachments[binding.conversationID] = nil
    }

    func handle(method: String, params: [String: Any]) {
        guard let raw = params["threadId"] as? String,
              let id = UUID(uuidString: raw),
              var attachment = attachments[id]
        else { return }

        // Reconcile-on-first-contact. A tab whose codex sat behind the directory-trust or
        // hooks-review prompt produced nothing until the user cleared it, so its title and
        // status are stale by exactly one read. Doing this on first contact rather than on a
        // timer means no polling and no arbitrary delay.
        if !attachment.hasReconciled {
            attachment.hasReconciled = true
            Task { await self.reconcile(id) }
        }

        let events = CodexEventMapper.events(method: method, params: params, state: &attachment.state)
        attachments[id] = attachment
        for event in events { attachment.onEvent(event) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRuntime.swift Tests/FlightDeckTests/CodexRuntimeTests.swift
git commit -m "feat: route codex notifications per thread, reconciling on first contact"
```

---

## Task 10: Spawn the app-server, probe the version, fail loudly

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` — register the codex adapter/runtime; handle `prepare` failure
- Test: `Tests/FlightDeckTests/CodexLaunchFailureTests.swift`

**Interfaces:**
- Consumes: `CodexTransport` (Task 6), `CodexAdapter` (Task 7), `CodexRuntime` (Task 9)
- Produces: `final class CodexProcessTransport: CodexTransport` with `init(executable:)` and `func start() throws`; `SessionStore.createSession(agent:in:) async -> Result<UUID, AgentLaunchError>`; `enum AgentLaunchError: LocalizedError { case notInstalled, versionTooOld(found: String, minimum: String), prepareFailed(String) }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexLaunchFailureTests: XCTestCase {
    final class DeadTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}   // never answers
    }

    func testAHardPrepareFailureCreatesNoTab() async {
        let store = SessionStore()
        let rpc = CodexRPC(transport: DeadTransport())
        store.overrideAdapter(CodexAdapter(rpc: rpc), for: .codex)
        rpc.transportClosed()   // app-server is gone before we start

        let before = store.allSessionIDs.count
        let result = await store.createSession(agent: .codex, in: "/w/a")

        // A tab bound to a thread that was never committed looks fine until the terminal
        // says it cannot resume. No tab plus a named error beats a tab that silently
        // degrades — the exact failure class this codebase keeps fixing.
        guard case .failure = result else { return XCTFail("expected a hard failure") }
        XCTAssertEqual(store.allSessionIDs.count, before, "no tab may survive a failed prepare")
    }

    func testTheErrorNamesTheCause() {
        XCTAssertTrue(
            AgentLaunchError.versionTooOld(found: "0.140.0", minimum: "0.142.4")
                .errorDescription?.contains("0.142.4") ?? false,
            "the alert must say what to do, not just that something failed"
        )
    }
}
```

> `allSessionIDs` and `createSession(agent:in:)` may not exist under those names. Read
> `SessionStore.swift` and reuse the seams the existing creation tests use
> (`Tests/FlightDeckTests/SessionCreationTests.swift`); add a thin test-only accessor only if
> there is genuinely none.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexLaunchFailureTests|error:"`
Expected: FAIL — `cannot find 'AgentLaunchError' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum AgentLaunchError: LocalizedError, Equatable {
    case notInstalled(String)
    case versionTooOld(found: String, minimum: String)
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "\(name) is not installed or not on PATH."
        case .versionTooOld(let found, let minimum):
            "Codex \(found) is too old; the app-server protocol Flight Deck uses needs \(minimum) or newer."
        case .prepareFailed(let why):
            "Could not start a Codex session: \(why)"
        }
    }
}

/// Spawns `codex app-server` and pumps newline-delimited JSON both ways.
///
/// Long-lived and app-wide: a codex thread belongs to the app-server process that created
/// it, so restarting per session would discard threads.
@MainActor
final class CodexProcessTransport: CodexTransport {
    static let minimumVersion = "0.142.4"

    var onLine: ((String) -> Void)?

    private let executable: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()

    init(executable: String = "codex") { self.executable = executable }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }

        do { try process.run() } catch { throw AgentLaunchError.notInstalled("Codex") }
    }

    func send(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        process.terminate()
    }

    /// Reassembles lines across chunk boundaries — a read can land mid-line, and half a
    /// JSON object parses as nothing.
    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if let text = String(data: Data(line), encoding: .utf8) { onLine?(text) }
        }
    }
}
```

In `SessionStore`, register codex and make creation fallible:

```swift
    /// Creation is fallible for agents whose identity is negotiated. Claude cannot fail here
    /// (it mints its own id); codex can, and a half-created tab is worse than none.
    func createSession(agent: AgentID, in directory: String) async -> Result<UUID, AgentLaunchError> {
        let draft = Session(title: nextSessionTitle(), workingDirectory: directory)
        do {
            let binding = try await adapter(for: agent).prepare(for: draft, options: options(for: agent, in: directory))
            return .success(insertSession(draft, agent: agent, binding: binding))
        } catch {
            return .failure(.prepareFailed(error.localizedDescription))
        }
    }
```

Callers present the error with `NSAlert`, matching `NSAlertProjectCloseConfirmer`'s style in
`SessionSidebar.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift \
        Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/CodexLaunchFailureTests.swift
git commit -m "feat: spawn the codex app-server and refuse to create a half-bound tab"
```

---

## Task 11: Ordered agent preferences and migration

**Files:**
- Create: `Sources/FlightDeck/Preferences/AgentSettings.swift`
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift:53-70`
- Test: `Tests/FlightDeckTests/AgentSettingsTests.swift`

**Interfaces:**
- Consumes: `AgentID`, `AgentOptions` (Task 1)
- Produces: `struct AgentSettings: Codable, Equatable { var id: AgentID; var options: AgentOptions }`, `Preferences.agents: [AgentSettings]`, `Preferences.agent(at: Int) -> AgentSettings?`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

final class AgentSettingsTests: XCTestCase {
    func testPreferencesWithNoAgentListDefaultToClaudeThenCodex() {
        // Position is meaning: index 0 is ⌘N. An upgrade must leave ⌘N on claude, which is
        // what every existing user's muscle memory expects.
        let prefs = Preferences()
        XCTAssertEqual(prefs.agents.map(\.id), [.claude, .codex])
    }

    func testExistingGlobalFlagsMigrateIntoTheClaudeEntry() {
        var prefs = Preferences()
        var flags = FlagSet()
        flags.values["--model"] = .string("opus")
        prefs.globalFlags = flags

        prefs.migrateAgentsIfNeeded()

        guard case .claude(let migrated)? = prefs.agents.first(where: { $0.id == .claude })?.options
        else { return XCTFail("claude's options must be a FlagSet") }
        XCTAssertEqual(migrated.values["--model"], .string("opus"),
                       "an upgrade must not silently drop the user's flags")
    }

    func testOrderRoundTripsThroughCoding() throws {
        var prefs = Preferences()
        prefs.agents = [AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
                        AgentSettings(id: .claude, options: .claude(FlagSet()))]

        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))

        XCTAssertEqual(back.agents.map(\.id), [.codex, .claude], "reordering must persist")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AgentSettingsTests|error:"`
Expected: FAIL — `value of type 'Preferences' has no member 'agents'`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One agent's row in the Agents preferences list.
///
/// The array's ORDER is semantic, not cosmetic: index 0 is ⌘N, index 1 ⌘⇧N, index 2 ⌘⇧⌥N.
/// Reordering the list rebinds the shortcuts, which is the whole interaction.
struct AgentSettings: Codable, Equatable {
    var id: AgentID
    var options: AgentOptions
}

extension AgentOptions: Codable {
    private enum CodingKeys: String, CodingKey { case agent, flags, codex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(AgentID.self, forKey: .agent) {
        case .claude: self = .claude(try c.decode(FlagSet.self, forKey: .flags))
        case .codex:  self = .codex(try c.decode(CodexThreadOptions.self, forKey: .codex))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        switch self {
        case .claude(let f): try c.encode(f, forKey: .flags)
        case .codex(let o):  try c.encode(o, forKey: .codex)
        }
    }
}
```

In `Preferences`:

```swift
    /// Ordered; position binds the New Session shortcuts. Optional in storage so a snapshot
    /// written before agent adapters decodes cleanly and is filled in by
    /// `migrateAgentsIfNeeded()`.
    var storedAgents: [AgentSettings]?

    var agents: [AgentSettings] {
        get { storedAgents ?? Self.defaultAgents }
        set { storedAgents = newValue }
    }

    static let defaultAgents: [AgentSettings] = [
        AgentSettings(id: .claude, options: .claude(FlagSet())),
        AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
    ]

    /// Folds today's single-agent settings into the list. Idempotent: safe to call on
    /// every load.
    mutating func migrateAgentsIfNeeded() {
        guard storedAgents == nil else { return }
        storedAgents = [
            AgentSettings(id: .claude, options: .claude(globalFlags)),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
    }
```

Call `migrateAgentsIfNeeded()` where `PreferencesStore` loads.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures, including existing `PreferencesStoreTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/AgentSettings.swift \
        Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Tests/FlightDeckTests/AgentSettingsTests.swift
git commit -m "feat: store an ordered agent list, migrating today's flags into claude"
```

---

## Task 12: Shortcut mapping and the dynamic New Session affordance

**Files:**
- Create: `Sources/FlightDeck/Agents/NewSessionAffordance.swift`, `Sources/FlightDeck/ModifierWatcher.swift`
- Modify: `Sources/FlightDeck/SessionCommands.swift:15-25`, `Sources/FlightDeck/SessionSidebar.swift:315-335`
- Test: `Tests/FlightDeckTests/NewSessionAffordanceTests.swift`

**Interfaces:**
- Consumes: `AgentSettings` (Task 11)
- Produces: `enum NewSessionAffordance { static func slots(for: [AgentSettings]) -> [Slot]; static func resolve(_ modifiers: NSEvent.ModifierFlags, in: [AgentSettings]) -> Slot? }`, `struct Slot { let agent: AgentID; let label: String; let shortcutDisplay: String; let modifiers: NSEvent.ModifierFlags }`, `final class ModifierWatcher: ObservableObject { @Published var flags: NSEvent.ModifierFlags }`

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import XCTest
@testable import FlightDeck

final class NewSessionAffordanceTests: XCTestCase {
    private let two: [AgentSettings] = [
        AgentSettings(id: .claude, options: .claude(FlagSet())),
        AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
    ]

    func testSlotsBindShortcutsByListPosition() {
        let slots = NewSessionAffordance.slots(for: two)
        XCTAssertEqual(slots.map(\.agent), [.claude, .codex])
        XCTAssertEqual(slots[0].modifiers, [.command])
        XCTAssertEqual(slots[1].modifiers, [.command, .shift])
    }

    func testAThirdAgentTakesCommandShiftOption() {
        var three = two
        three.append(AgentSettings(id: .claude, options: .claude(FlagSet())))
        XCTAssertEqual(NewSessionAffordance.slots(for: three)[2].modifiers, [.command, .shift, .option])
    }

    func testReorderingRebindsTheShortcuts() {
        // The whole point of the drag-to-reorder list: position IS the binding.
        let slots = NewSessionAffordance.slots(for: two.reversed())
        XCTAssertEqual(slots[0].agent, .codex)
        XCTAssertEqual(slots[0].modifiers, [.command])
    }

    func testLabelNamesTheAgentThatWouldLaunch() {
        XCTAssertEqual(NewSessionAffordance.slots(for: two)[1].label, "New Codex Session")
    }

    func testHeldModifiersResolveToTheSlotTheyWouldTrigger() {
        // Drives the live button label: holding ⇧ while ⌘ is down must read "New Codex Session".
        XCTAssertEqual(NewSessionAffordance.resolve([.command, .shift], in: two)?.agent, .codex)
        XCTAssertEqual(NewSessionAffordance.resolve([.shift], in: two)?.agent, .codex,
                       "the button shows the shift variant even before ⌘ goes down")
        XCTAssertEqual(NewSessionAffordance.resolve([], in: two)?.agent, .claude)
    }

    func testUnboundModifierCombinationsFallBackToTheFirstSlot() {
        XCTAssertEqual(NewSessionAffordance.resolve([.control], in: two)?.agent, .claude)
    }

    func testShortcutDisplayUsesTheStandardGlyphs() {
        let slots = NewSessionAffordance.slots(for: two)
        XCTAssertEqual(slots[0].shortcutDisplay, "⌘N")
        XCTAssertEqual(slots[1].shortcutDisplay, "⇧⌘N")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "NewSessionAffordanceTests|error:"`
Expected: FAIL — `cannot find 'NewSessionAffordance' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import AppKit

/// Maps the ordered agent list onto New Session shortcuts, labels and glyphs.
///
/// Pure so the binding rules are testable without a window: the interesting behaviour is
/// that ORDER decides the shortcut, and that has nothing to do with SwiftUI.
enum NewSessionAffordance {
    struct Slot: Equatable {
        let agent: AgentID
        let label: String
        let shortcutDisplay: String
        let modifiers: NSEvent.ModifierFlags
    }

    /// Escalating modifiers, in the order macOS conventionally stacks them. Beyond three
    /// agents there is no further shortcut: extra rows are reachable from the menu only,
    /// which is better than inventing bindings that collide with system shortcuts.
    private static let ladder: [NSEvent.ModifierFlags] = [
        [.command], [.command, .shift], [.command, .shift, .option],
    ]

    static func slots(for agents: [AgentSettings]) -> [Slot] {
        agents.enumerated().compactMap { index, settings in
            guard index < ladder.count else { return nil }
            let modifiers = ladder[index]
            return Slot(
                agent: settings.id,
                label: "New \(settings.id.displayName) Session",
                shortcutDisplay: display(modifiers),
                modifiers: modifiers
            )
        }
    }

    /// Which slot the currently-held modifiers would trigger.
    ///
    /// `.command` is ignored when matching: the user is holding ⇧ on the way to ⌘⇧N, and the
    /// button must already read "New Codex Session" at that moment — that live feedback is
    /// the point of the affordance.
    static func resolve(_ held: NSEvent.ModifierFlags, in agents: [AgentSettings]) -> Slot? {
        let all = slots(for: agents)
        let significant = held.intersection([.shift, .option])
        return all.first { $0.modifiers.intersection([.shift, .option]) == significant } ?? all.first
    }

    private static func display(_ modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + "N"
    }
}
```

`ModifierWatcher.swift`:

```swift
import AppKit
import Combine

/// Publishes the currently-held modifier keys so the sidebar button can relabel itself
/// mid-chord. A local monitor (not global) because this only matters while Flight Deck is
/// frontmost, and a global monitor would need accessibility permission for no benefit.
@MainActor
final class ModifierWatcher: ObservableObject {
    @Published private(set) var flags: NSEvent.ModifierFlags = []
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flags = event.modifierFlags
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
```

In `SessionCommands.swift`, replace the single New Session button with one item per slot —
menu shortcuts are static, so each slot gets its own item:

```swift
            ForEach(Array(NewSessionAffordance.slots(for: preferences.agents).enumerated()), id: \.offset) { _, slot in
                Button(slot.label) { store.createFromMenu(agent: slot.agent) }
                    .keyboardShortcut("n", modifiers: slot.modifiers)
            }
```

In `SessionSidebar.swift`, drive the existing button's label and shortcut from the watcher
(`@StateObject private var modifiers = ModifierWatcher()`, `.onAppear { modifiers.start() }`),
resolving with `NewSessionAffordance.resolve(modifiers.flags, in: preferences.agents)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/NewSessionAffordance.swift Sources/FlightDeck/ModifierWatcher.swift \
        Sources/FlightDeck/SessionCommands.swift Sources/FlightDeck/SessionSidebar.swift \
        Tests/FlightDeckTests/NewSessionAffordanceTests.swift
git commit -m "feat: bind New Session shortcuts to agent list order, live-labelled"
```

---

## Task 13: The Agents preferences tab

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/AgentsSettingsTab.swift`, `Sources/FlightDeck/Preferences/UI/CodexOptionsForm.swift`
- Delete: `Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift` (its body moves into the claude pane)
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`
- Test: `Tests/FlightDeckTests/AgentReorderTests.swift`

**Interfaces:**
- Consumes: `AgentSettings` (Task 11), `NewSessionAffordance` (Task 12)
- Produces: `AgentsSettingsTab` view; `Preferences.moveAgents(fromOffsets:toOffset:)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

final class AgentReorderTests: XCTestCase {
    func testMovingAnAgentReordersTheList() {
        var prefs = Preferences()
        prefs.agents = Preferences.defaultAgents          // claude, codex

        prefs.moveAgents(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(prefs.agents.map(\.id), [.codex, .claude])
    }

    func testReorderingChangesWhichAgentOwnsCommandN() {
        var prefs = Preferences()
        prefs.agents = Preferences.defaultAgents
        prefs.moveAgents(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(NewSessionAffordance.slots(for: prefs.agents).first?.agent, .codex,
                       "the list is the shortcut binding; moving a row must rebind ⌘N")
    }

    func testAgentOptionsSurviveAReorder() {
        var prefs = Preferences()
        var flags = FlagSet()
        flags.values["--model"] = .string("opus")
        prefs.agents = [AgentSettings(id: .claude, options: .claude(flags)),
                        AgentSettings(id: .codex, options: .codex(CodexThreadOptions()))]

        prefs.moveAgents(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        guard case .claude(let moved)? = prefs.agents.last?.options else {
            return XCTFail("claude's options must travel with its row")
        }
        XCTAssertEqual(moved.values["--model"], .string("opus"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AgentReorderTests|error:"`
Expected: FAIL — `value of type 'Preferences' has no member 'moveAgents'`

- [ ] **Step 3: Write minimal implementation**

In `Preferences`:

```swift
    /// Reorders the agent list, which rebinds the New Session shortcuts (`NewSessionAffordance`).
    mutating func moveAgents(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = agents
        list.move(fromOffsets: source, toOffset: destination)
        agents = list
    }
```

`AgentsSettingsTab.swift`:

```swift
import SwiftUI

/// Replaces the old single-agent Claude tab. The list on the left is both the agent
/// registry and the shortcut binding — row 1 is ⌘N — so the shortcut is shown inline on each
/// row rather than hidden in a help string.
struct AgentsSettingsTab: View {
    @ObservedObject var store: PreferencesStore
    @State private var selection: AgentID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(store.preferences.agents, id: \.id) { settings in
                    HStack {
                        Text(settings.id.displayName)
                        Spacer()
                        Text(shortcut(for: settings.id))
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    .tag(settings.id)
                }
                .onMove { store.preferences.moveAgents(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minWidth: 160)

            Group {
                switch selection ?? store.preferences.agents.first?.id {
                case .codex: CodexOptionsForm(store: store)
                default:     ClaudeOptionsPane(store: store)   // the old ClaudeSettingsTab body
                }
            }
            .frame(minWidth: 380)
        }
    }

    private func shortcut(for agent: AgentID) -> String {
        NewSessionAffordance.slots(for: store.preferences.agents)
            .first { $0.agent == agent }?.shortcutDisplay ?? ""
    }
}
```

`CodexOptionsForm.swift` is a plain `Form` binding `CodexThreadOptions.model`, `.sandbox`
(picker: `read-only`, `workspace-write`, `danger-full-access`), `.approvalPolicy` (picker:
`untrusted`, `on-request`, `never`) and `.addDirs`. No flag catalog, parser or quoting —
these go over JSON-RPC as typed params.

Rename `ClaudeSettingsTab` to `ClaudeOptionsPane` (same body) and point `PreferencesView` at
`AgentsSettingsTab` with the label "Agents".

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/ Tests/FlightDeckTests/AgentReorderTests.swift
git commit -m "feat: replace the Claude settings tab with a reorderable Agents tab"
```

---

## Task 14: Opt-in integration test against a real codex

**Files:**
- Create: `Tests/FlightDeckTests/CodexIntegrationTests.swift`
- Test: itself

**Interfaces:**
- Consumes: everything from Tasks 6-10

This is the only test that runs a real `codex`. It is skipped unless
`FLIGHT_DECK_CODEX_INTEGRATION=1` is set, so the default suite stays hermetic and fast. It
exists to catch codex changing the undocumented behaviour the design leans on — above all
the start-then-name commit rule.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FLIGHT_DECK_CODEX_INTEGRATION"] == "1",
            "set FLIGHT_DECK_CODEX_INTEGRATION=1 to run against a real codex"
        )
    }

    func testThreadStartAloneDoesNotPersistButNamingCommits() async throws {
        let transport = CodexProcessTransport()
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)
        _ = try await rpc.request("initialize", ["clientInfo": ["name": "flight-deck-test", "version": "0"]])

        let dir = NSTemporaryDirectory()
        let started = try await rpc.request("thread/start", ["cwd": dir])
        let id = try XCTUnwrap((started["thread"] as? [String: Any])?["id"] as? String)

        // The rule the whole codex adapter is built on. If this assertion ever flips,
        // CodexAdapter.prepare can be simplified — and if the second one flips, every
        // codex tab silently stops being resumable.
        XCTAssertFalse(try threadRowExists(id), "thread/start is expected NOT to persist")
        _ = try await rpc.request("thread/name/set", ["threadId": id, "name": "integration probe"])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(try threadRowExists(id), "thread/name/set is expected to commit")
    }

    private func threadRowExists(_ id: String) throws -> Bool {
        let db = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/state_5.sqlite").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, "select count(*) from threads where id='\(id)';"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "0"
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
```

- [ ] **Step 2: Run it opted-in**

Run: `FLIGHT_DECK_CODEX_INTEGRATION=1 ./scripts/test-unit.sh 2>&1 | rg "CodexIntegrationTests" -A3`
Expected: PASS (needs `codex` on PATH and a logged-in account)

- [ ] **Step 3: Run the default suite and confirm it skips**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, and the skip count has risen by one

- [ ] **Step 4: Commit**

```bash
git add Tests/FlightDeckTests/CodexIntegrationTests.swift
git commit -m "test: pin codex's start-then-name commit rule behind an opt-in flag"
```

---

## Task 15: Codex auto-resume, re-pinning, and reconcile wiring

Covers spec §4.5, and finishes the `reconcile` hook Task 9 left injectable. Depends on
Tasks 9 and 10; may be done before or after Tasks 11-14.

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` (add `read`), `Sources/FlightDeck/SessionStore.swift` (restore path)
- Test: `Tests/FlightDeckTests/CodexResumeTests.swift`

**Interfaces:**
- Consumes: `CodexAdapter` (Task 7), `CodexRuntime.reconcile` (Task 9)
- Produces: `CodexAdapter.read(_ binding: AgentBinding) async throws -> (title: String?, activity: SessionActivity?)`, `CodexAdapter.rebind(for: Session, options: AgentOptions) async throws -> AgentBinding`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexResumeTests: XCTestCase {
    final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        var threadMissing = false

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/read" where threadMissing:
                onLine?(#"{"id":\#(id),"error":{"code":-32602,"message":"no such thread"}}"#)
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"restored","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01705-bd49-7b70-a0a1-4514d4bda5dd","cwd":"/w/a","path":"/r/y.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private let existing = UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b")!

    func testReadReturnsTheAuthoritativeTitleAndStatus() async throws {
        let t = ScriptedTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let state = try await adapter.read(AgentBinding(conversationID: existing, transcriptURL: nil))

        // This is what reconcile-on-first-contact applies for a tab that launched behind
        // the hooks prompt and therefore reported nothing until the user cleared it.
        XCTAssertEqual(state.title, "restored")
        XCTAssertEqual(state.activity, .idle)
    }

    func testRebindReusesAThreadThatStillExists() async throws {
        let t = ScriptedTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(binding.conversationID, existing, "a live thread must be reused, not replaced")
        XCTAssertFalse(t.methods.contains("thread/start"))
    }

    func testRebindStartsAFreshThreadWhenTheOldOneIsGone() async throws {
        let t = ScriptedTransport()
        t.threadMissing = true
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))

        // Mirrors claude's `--resume || --session-id` fallback: a deleted or archived thread
        // must not strand the tab. Re-pinning is the caller's job once this returns.
        XCTAssertNotEqual(binding.conversationID, existing)
        XCTAssertEqual(t.methods, ["thread/read", "thread/start", "thread/name/set"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "CodexResumeTests|error:"`
Expected: FAIL — `value of type 'CodexAdapter' has no member 'read'`

- [ ] **Step 3: Write minimal implementation**

Add to `CodexAdapter`:

```swift
    /// Authoritative title and status for an already-bound thread.
    ///
    /// Used by reconcile-on-first-contact: a session whose codex sat behind the
    /// directory-trust or hooks-review prompt emits nothing until the user clears it, so its
    /// title is stale by exactly one read rather than by a stream of missed notifications.
    func read(_ binding: AgentBinding) async throws -> (title: String?, activity: SessionActivity?) {
        let result = try await rpc.request(
            "thread/read", ["threadId": binding.conversationID.uuidString.lowercased()]
        )
        let thread = result["thread"] as? [String: Any] ?? [:]
        let status = (thread["status"] as? [String: Any])?["type"] as? String
        return (
            thread["name"] as? String,
            status.flatMap { $0 == "running" || $0 == "busy" ? .busy : .idle }
        )
    }

    /// Re-attaches a restored tab to its thread, starting a fresh one if that thread is gone.
    ///
    /// The codex counterpart of `claude --resume <id> || claude --session-id <id>`: a thread
    /// the user archived or deleted between launches must not strand the tab. The caller
    /// re-pins `pinnedConversationID` when the returned id differs.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let existing = AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        do {
            _ = try await read(existing)
            return AgentBinding(
                conversationID: session.pinnedConversationID,
                transcriptURL: session.transcriptPath.map { URL(fileURLWithPath: $0) }
            )
        } catch {
            return try await prepare(for: session, options: options)
        }
    }
```

Wire the runtime's hook where codex is registered (Task 10):

```swift
        codexRuntime.reconcile = { [weak self] id in
            guard let self, let tabID = self.tabID(forConversation: id) else { return }
            guard let state = try? await self.codexAdapter.read(
                AgentBinding(conversationID: id, transcriptURL: nil)
            ) else { return }
            if let title = state.title { self.applyExternalTitle(title, to: tabID) }
            if let activity = state.activity { self.applyActivity(activity, to: tabID) }
        }
```

And in the restore path (`SessionStore.swift:594`), use `rebind` for codex sessions,
re-pinning when the id changes, before building the resume command.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexAdapter.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/CodexResumeTests.swift
git commit -m "feat: resume codex threads across relaunch, re-pinning when one is gone"
```

---

## Notes for the executor

- **Task 5 is the risky one.** It moves a working path onto a new seam. Run the suite after
  every individual call-site substitution, not just at the end. If an existing test fails,
  the refactor changed behaviour — fix the code, never the test.
- **Order matters through Task 10.** Tasks 6-9 build the codex path in isolation with no
  process; Task 10 is the first that spawns anything.
- **Tasks 11-13 are UI** and have thin automated coverage by nature. After Task 13, verify
  by hand: open Preferences, drag Codex above Claude, confirm the row shortcuts swap and
  ⌘N opens a Codex tab. That is a single manual run, not the smoke suite.
- If a signature in this plan disagrees with the code you find, the code wins — read it and
  adapt. Every code block here was written against `1d2865c` and the tree moves.
