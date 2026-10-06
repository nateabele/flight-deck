# Subagents as First-Class Children — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A claude subagent's permission dialog is identified, shown and answerable on the phone, and every live subagent is a named child (running / blocked / done) of its session on Mac and phone.

**Architecture:** A pure `SubagentTree` is rebuilt from `<conversation>/subagents/` (`agent-<id>.meta.json` + `.jsonl` tails) by a per-conversation `SubagentWatcher` owned by `ClaudeRuntime`. A record-only `PermissionRequest` hook, parsed by `HookEventWatcher`, names which agent and call a dialog belongs to; the subagent's transcript confirms it is still open. The wire gains optional fields (`subagents`, `openPromptAgent`, `agent:` on `timeline.page` and `prompt.answer`); the phone fetches the blocked agent's tail and derives the card itself, so prompts stay derived on both ends and never sent.

**Tech Stack:** Swift 5 mode app (AppKit/SwiftUI), FleetKit (Swift 6, Foundation/Network/Security only), iOS SwiftUI companion, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-06-subagent-model-design.md`

## Global Constraints

- App target stays `SWIFT_VERSION: "5.0"`; FleetKit stays Foundation/Network/Security only (it compiles for iOS).
- `Sources/FlightDeckMobile/` stays flat — no subdirectories.
- Every new wire field is optional: encoded with `encodeIfPresent`, decoded with `decodeIfPresent`, so an older Mac or phone keeps today's behavior. No new `FleetEventTag` (an unknown tag throws on an older phone).
- A new wire field and every pattern-match / handler site for it land in ONE commit (`activityChanged` is matched positionally at ~13 sites).
- Comments explain *why* and name the failure they prevent (house style, `docs/CONVENTIONS.md`).
- Commits: lowercase imperative behavioral subject; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- TDD: run each new test against the unfixed code and see it fail before implementing.
- Fixtures copy real record shapes (`"isSidechain":true` on every subagent record; real `meta.json` keys) with invented content. Never copy a real transcript into the repo.
- Mac tests: `FD_TEST_FILTER=ClassA,ClassB ./scripts/test-unit.sh` (exits 0 even on failure — check the log for ` error: `). Full suite: `./scripts/test-unit.sh`. iOS: `./scripts/build-ios.sh` then `./scripts/test-ios.sh`. Never run `./scripts/smoke.sh` in a loop. Never launch a bundle from `DerivedData/`.
- Run tests in the foreground (a backgrounded run dies with a subagent's turn).
- The shared checkout has other sessions' uncommitted files (`project.yml`, `scripts/deploy-phone.sh`): never stage, stash or revert them. `git add` only the files your task names.
- A subagent agent id on the wire or from a hook is untrusted. Before it touches a path it must match `^a[0-9a-f]{6,40}$` (`SubagentID.isValid`, Task 2).

## Review Focus

1. **A phone-supplied agent id containing `../` or `/`.** Expected: refused (`unknown_agent`), no file outside `subagents/` is opened. Test in Task 5 (`testATraversalAgentIDIsRefusedBeforeAnyRead`) and Task 2 (`SubagentID` tests).
2. **Allow tapped for a subagent whose open call is a running tool, not a dialog.** Expected: refused `prompt_changed`, nothing typed. Test in Task 5 (`testAnAnswerForASubagentWithNoPendingDialogIsRefused`).
3. **No hook events at all** (plugin not loaded, log missing or rotated). Expected: no card, today's "Waiting for you — permission prompt", no crash. Tests in Task 4 (`testNoPermissionRequestMeansNoPendingDialog`) and Task 5 (`testWithoutAPendingDialogTheRefusalIsSubagentPrompt`).
4. **A subagent dialog answered in the terminal, or the session leaving `waiting`.** Expected: the attribution clears and the card goes. Tests in Task 5 (`testAResolvedSubagentCallIsNoLongerOffered`) and Task 4 (`testUserPromptSubmitClearsThePendingDialog`).
5. **Many sessions with large `subagents/` folders.** Expected: a steady tick stats only non-done files plus the folder; a full rescan at most every 10s. Test in Task 3 (`testASteadyTickStatsOnlyLiveFiles`).

---

### Task 1: Probe the `PermissionRequest` payload for a subagent's dialog

Throwaway probe; its output is facts written into the spec. No product code.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-06-subagent-model-design.md` (§3 "Not yet verified" → verified facts)
- Scratch only (not committed): a probe directory under the session scratchpad.

**Interfaces:**
- Produces: confirmed field list for `PermissionRequest` (does it carry `agent_id`, `tool_use_id`, `tool_input`?) and what a denied subagent call writes to its `agent-<id>.jsonl`. Task 4's code handles every outcome; this task only records which one is true.

- [ ] **Step 1: Build a probe plugin.** In a scratch dir create `probe-plugin/hooks/hooks.json` registering `PreToolUse`, `PermissionRequest`, `Notification`, `PostToolUse`, `SubagentStop` to `probe-plugin/scripts/rec.sh`:

```bash
#!/bin/bash
printf '%s\n' "$(cat | tr -d '\n')" >> "$PROBE_LOG"
exit 0
```

`chmod +x` it. Create an empty project dir `probe-proj/` and `git init` it.

- [ ] **Step 2: Trust the project once.** Run `claude` interactively in `probe-proj` with `env -u CLAUDE_CODE_CHILD_SESSION`, accept the trust prompt by selecting "Yes" (the prompt opens focused on "No, exit" — a bare Enter quits), then `/exit`. (Memory: no hook fires until the folder is trusted.)

- [ ] **Step 3: Drive one deny and one allow.** Using a Python `pty.fork` driver (pattern: earlier probes in `scripts/adapterprobe/`), start `env -u CLAUDE_CODE_CHILD_SESSION PROBE_LOG=$PWD/events.ndjson claude --plugin-dir ./probe-plugin --permission-mode default` in `probe-proj`, submit: `Use the Agent tool to launch one general-purpose subagent whose only job is to run the Bash command: touch /tmp/fd-probe-deny`. Wait until the screen shows `Esc to cancel` and `from the`, capture the screen, send `\x1b` (Esc). Wait for idle. Repeat with `touch /tmp/fd-probe-allow` and answer with `1` then `\r`.

- [ ] **Step 4: Record facts.** From `events.ndjson`: the full key list of each `PermissionRequest` record, whether `agent_id`/`agent_type`/`tool_use_id` are present, and whether its `tool_input` equals the preceding `PreToolUse.tool_input` byte-for-byte. From `~/.claude/projects/<probe-proj-dir>/<session>/subagents/agent-*.jsonl`: the record written after the deny (expect a `user` `tool_result` with `is_error: true`; record the real shape) and whether `meta.json` exists before the subagent's first tool call.

- [ ] **Step 5: Write them into spec §3**, replacing the "Not yet verified" list with the observed facts (version-stamped: `claude --version`). If `meta.json` appears only after the first record, add one line to §4.1 noting the fold count covers that gap (Task 3 already takes `max`).

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-10-06-subagent-model-design.md
git commit -m "docs: record the PermissionRequest payload for a subagent's dialog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `SubagentTree` — pure model built from a `subagents/` folder

**Files:**
- Create: `Sources/FlightDeck/Agents/SubagentTree.swift`
- Test: `Tests/FlightDeckTests/SubagentTreeTests.swift`

**Interfaces:**
- Consumes: `ClaudeTimelineMapper.items(inLine:at:sidechain:)`, `SourceLine`, `TranscriptStamp` (in `Fleet/PromptService.swift`).
- Produces:
  - `enum SubagentID { static func isValid(_ id: String) -> Bool }`
  - `struct SubagentNode: Equatable, Sendable { let id: String; let parentID: String?; let type: String; let description: String; var state: State; let modified: Date }` with `enum State: Equatable, Sendable { case running, blocked(callID: String), done }`
  - `struct SubagentTree: Equatable, Sendable { var nodes: [SubagentNode] }` with `static let empty`, `var liveTopLevelCount: Int`, `func node(_ id: String) -> SubagentNode?`, `func marking(blocked agentID: String, call: String) -> SubagentTree`, `func path(to id: String) -> [String]`
  - `enum SubagentFiles { static func meta(at url: URL) -> SubagentMeta?; static func state(ofTail lines: [SourceLine]) -> SubagentNode.State }` with `struct SubagentMeta: Equatable, Sendable { let type: String; let description: String; let parentID: String? }`
  - `static func SubagentTree.build(metas: [String: SubagentMeta], states: [String: (SubagentNode.State, Date)], keepDoneSince: Date?) -> SubagentTree`

- [ ] **Step 1: Write the failing tests**

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Fixtures copy claude 2.1.289's real record shapes: every subagent record is a sidechain,
/// and `meta.json` carries `agentType`/`description`/`parentAgentId`. 7cdecd26 shipped a check
/// whose fixtures left `isSidechain` out and so passed while finding nothing live.
final class SubagentTreeTests: XCTestCase {
    private func assistantText(_ text: String) -> String {
        #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func toolUse(_ id: String) -> String {
        #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"ls"}}]}}"#
    }
    private func toolResult(_ id: String) -> String {
        #"{"isSidechain":true,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
    }
    private func userText(_ text: String) -> String {
        #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }
    private func lines(_ raw: [String]) -> [SourceLine] {
        raw.enumerated().map { SourceLine(offset: $0.offset * 100, text: $0.element) }
    }

    func testValidAgentIDs() {
        XCTAssertTrue(SubagentID.isValid("a28ad87bc9c01d113"))
        XCTAssertFalse(SubagentID.isValid("../etc/passwd"))
        XCTAssertFalse(SubagentID.isValid("a28ad87/../x"))
        XCTAssertFalse(SubagentID.isValid(""))
        XCTAssertFalse(SubagentID.isValid("A28AD87BC9"))
    }

    func testAFinishedTurnIsDone() {
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([toolUse("t1"), toolResult("t1"),
                                                         assistantText("All done.")])), .done)
    }

    func testAnOpenCallIsRunningNotBlocked() {
        // Blocked is attribution's call (Task 4/5), never the file's: a running Bash looks
        // identical to a call waiting on a dialog.
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([toolUse("t1")])), .running)
    }

    func testAResumeAfterDoneIsRunningAgain() {
        XCTAssertEqual(SubagentFiles.state(ofTail: lines([assistantText("done"),
                                                         userText("Also check X.")])), .running)
    }

    func testMetaParsesTheRealKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"implementer","description":"Implement Task 14","toolUseId":"toolu_1","parentAgentId":"a0","spawnDepth":2,"model":"sonnet","requestShape":"background","requestNonInteractive":true}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SubagentFiles.meta(at: url),
                       SubagentMeta(type: "implementer", description: "Implement Task 14", parentID: "a0"))
    }

    func testBuildNestsChildrenAndHangsOrphansFromTheRoot() {
        let now = Date()
        let tree = SubagentTree.build(
            metas: ["a0": .init(type: "general-purpose", description: "Controller", parentID: nil),
                    "a1": .init(type: "implementer", description: "Task 14", parentID: "a0"),
                    "a2": .init(type: "reviewer", description: "Review", parentID: "aGONE")],
            states: ["a0": (.running, now), "a1": (.running, now), "a2": (.running, now)],
            keepDoneSince: nil
        )
        XCTAssertEqual(tree.node("a1")?.parentID, "a0")
        XCTAssertNil(tree.node("a2")?.parentID, "a parent out of scope hangs the child from the root")
        XCTAssertEqual(tree.liveTopLevelCount, 2)
        XCTAssertEqual(tree.path(to: "a1"), ["a0", "a1"])
    }

    func testDoneNodesOlderThanTheCutoffAreDropped() {
        let cutoff = Date()
        let tree = SubagentTree.build(
            metas: ["old": .init(type: "t", description: "d", parentID: nil),
                    "new": .init(type: "t", description: "d", parentID: nil)],
            states: ["old": (.done, cutoff.addingTimeInterval(-60)),
                     "new": (.done, cutoff.addingTimeInterval(60))],
            keepDoneSince: cutoff
        )
        XCTAssertNil(tree.node("old"))
        XCTAssertEqual(tree.node("new")?.state, .done)
        XCTAssertEqual(tree.liveTopLevelCount, 0)
    }

    func testANodeWithoutMetaIsSkipped() {
        let tree = SubagentTree.build(metas: [:], states: ["a1": (.running, Date())],
                                      keepDoneSince: nil)
        XCTAssertTrue(tree.nodes.isEmpty)
    }

    func testMarkingBlockedOnlyTouchesThatNode() {
        let now = Date()
        let tree = SubagentTree.build(
            metas: ["a1": .init(type: "implementer", description: "d", parentID: nil),
                    "a2": .init(type: "reviewer", description: "d", parentID: nil)],
            states: ["a1": (.running, now), "a2": (.running, now)], keepDoneSince: nil
        ).marking(blocked: "a1", call: "toolu_X")
        XCTAssertEqual(tree.node("a1")?.state, .blocked(callID: "toolu_X"))
        XCTAssertEqual(tree.node("a2")?.state, .running)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `FD_TEST_FILTER=SubagentTreeTests ./scripts/test-unit.sh > /tmp/t.log 2>&1; rg ' error: ' /tmp/t.log | head`
Expected: build errors — `SubagentID`, `SubagentFiles`, `SubagentTree` not found.

- [ ] **Step 3: Implement `Sources/FlightDeck/Agents/SubagentTree.swift`**

```swift
import FleetKit
import Foundation

/// A claude agent id as it appears in `subagents/agent-<id>.jsonl`. Checked before an id from
/// the wire or a hook is joined onto a path: the phone's `timeline.page(agent:)` and
/// `prompt.answer(agent:)` would otherwise let `../` read any file this user can.
enum SubagentID {
    static func isValid(_ id: String) -> Bool {
        id.range(of: "^a[0-9a-f]{6,40}$", options: .regularExpression) != nil
    }
}

struct SubagentMeta: Equatable, Sendable {
    let type: String
    let description: String
    let parentID: String?
}

struct SubagentNode: Equatable, Sendable {
    enum State: Equatable, Sendable { case running, blocked(callID: String), done }
    let id: String
    let parentID: String?
    let type: String
    let description: String
    var state: State
    let modified: Date
}

/// One conversation's background agents, at every depth, rebuilt from files so it survives a
/// Flight Deck relaunch (the transcript fold it supplements starts at end of file on attach).
struct SubagentTree: Equatable, Sendable {
    var nodes: [SubagentNode]
    static let empty = SubagentTree(nodes: [])

    /// What `subagentCount` means: depth-1 agents still working. A blocked one is working.
    var liveTopLevelCount: Int {
        nodes.filter { $0.parentID == nil && $0.state != .done }.count
    }

    func node(_ id: String) -> SubagentNode? { nodes.first { $0.id == id } }

    func marking(blocked agentID: String, call: String) -> SubagentTree {
        SubagentTree(nodes: nodes.map { node in
            guard node.id == agentID else { return node }
            var copy = node
            copy.state = .blocked(callID: call)
            return copy
        })
    }

    /// Root-first ids down to `id`, for expanding the path to a blocked agent.
    func path(to id: String) -> [String] {
        var path: [String] = []
        var cursor = node(id)
        while let current = cursor, !path.contains(current.id) {
            path.insert(current.id, at: 0)
            cursor = current.parentID.flatMap(node)
        }
        return path
    }

    /// `keepDoneSince`: done agents last written before it are dropped, so the tree shows what
    /// is running plus what finished since the user last spoke, not the conversation's history.
    static func build(
        metas: [String: SubagentMeta],
        states: [String: (SubagentNode.State, Date)],
        keepDoneSince: Date?
    ) -> SubagentTree {
        var kept: [SubagentNode] = []
        for (id, (state, modified)) in states {
            // A file without its meta (or the reverse) is mid-creation: skip until both exist.
            guard let meta = metas[id] else { continue }
            if state == .done, let keepDoneSince, modified < keepDoneSince { continue }
            kept.append(SubagentNode(id: id, parentID: meta.parentID, type: meta.type,
                                     description: meta.description, state: state,
                                     modified: modified))
        }
        let ids = Set(kept.map(\.id))
        let rooted = kept.map { node -> SubagentNode in
            guard let parent = node.parentID, !ids.contains(parent) else { return node }
            return SubagentNode(id: node.id, parentID: nil, type: node.type,
                                description: node.description, state: node.state,
                                modified: node.modified)
        }
        return SubagentTree(nodes: rooted.sorted { ($0.modified, $0.id) < ($1.modified, $1.id) })
    }
}

enum SubagentFiles {
    static func meta(at url: URL) -> SubagentMeta? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["agentType"] as? String
        else { return nil }
        return SubagentMeta(type: type, description: obj["description"] as? String ?? "",
                            parentID: obj["parentAgentId"] as? String)
    }

    /// Done when the newest conversational item is assistant text with nothing after it: 268 of
    /// 268 finished files on 2026-10-05 ended that way. Everything else is running — including
    /// an open call, which only attribution may call blocked.
    static func state(ofTail lines: [SourceLine]) -> SubagentNode.State {
        let items = lines.flatMap {
            ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset, sidechain: true)
        }
        guard let last = items.last else { return .running }
        return last.kind == .assistantText ? .done : .running
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `FD_TEST_FILTER=SubagentTreeTests ./scripts/test-unit.sh > /tmp/t.log 2>&1; rg ' error: |Executed' /tmp/t.log | tail -3`
Expected: `Executed 9 tests, with 0 failures`. If `testAFinishedTurnIsDone` fails because thinking or other kinds trail the text, inspect `ClaudeTimelineMapper`'s kinds for the fixture and adjust `state(ofTail:)` to ignore `.thinking` only.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/SubagentTree.swift Tests/FlightDeckTests/SubagentTreeTests.swift
git commit -m "feat: model a conversation's subagents as a tree built from their files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `SubagentWatcher`, runtime wiring, store storage and the count

**Files:**
- Create: `Sources/FlightDeck/Agents/SubagentWatcher.swift`
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift` (add `case subagents(SubagentTree)` to `AgentEvent`)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift` (own a watcher per source; new init closure `agentStartedAt`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`subagentTrees: [UUID: SubagentTree]`, `apply(.subagents)`, runtime construction passes `agentStartedAt`, `lastPromptSubmit`)
- Test: `Tests/FlightDeckTests/SubagentWatcherTests.swift`, `Tests/FlightDeckTests/ClaudeRuntimeTests.swift`

**Interfaces:**
- Consumes: Task 2's `SubagentTree`, `SubagentFiles`, `SubagentID`; `TranscriptStamp(of:)`; `TranscriptPager.page(url:anchor:limit:)` (see `PromptService.tail`); `WatchClock`.
- Produces:
  - `final class SubagentWatcher` — `init(directory: URL, clock: WatchClock?, startedAt: @escaping () -> Date?, keepDoneSince: @escaping () -> Date?, onChange: @escaping (SubagentTree) -> Void)`, `start()`, `stop()`, `poll()`, `rescan()`, `var tree: SubagentTree`, test seam `var statCount: Int` (stats performed by the last `poll`), `static let fullRescanInterval: TimeInterval = 10`, `var now: () -> Date = Date.init`.
  - `AgentEvent.subagents(SubagentTree)`.
  - `SessionStore.subagentTree(for tab: UUID) -> SubagentTree` and `SessionStore.subagentTrees` (`private(set) var`).
  - `ClaudeRuntime.init(..., agentStartedAt: @escaping (UUID) -> Date? = { _ in nil }, lastPromptSubmit: @escaping (UUID) -> Date? = { _ in nil })` — keyed by conversation id.

- [ ] **Step 1: Write the failing watcher tests** (`SubagentWatcherTests.swift`)

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SubagentWatcherTests: XCTestCase {
    private var dir: URL!
    private var clockNow = Date(timeIntervalSince1970: 3_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ id: String, type: String = "implementer", parent: String? = nil,
                       records: [String]) throws {
        let parentKey = parent.map { #","parentAgentId":"\#($0)""# } ?? ""
        try #"{"agentType":"\#(type)","description":"d \#(id)","toolUseId":"toolu_\#(id)"\#(parentKey),"spawnDepth":1}"#
            .write(to: dir.appendingPathComponent("agent-\(id).meta.json"), atomically: true, encoding: .utf8)
        try (records.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("agent-\(id).jsonl"), atomically: false, encoding: .utf8)
    }
    private let open = #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#
    private let finished = #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#

    private func makeWatcher(_ seen: @escaping (SubagentTree) -> Void) -> SubagentWatcher {
        let w = SubagentWatcher(directory: dir, clock: nil, startedAt: { nil },
                                keepDoneSince: { nil }, onChange: seen)
        w.now = { [unowned self] in self.clockNow }
        return w
    }

    func testAScanBuildsTheTreeAndReportsIt() throws {
        try write("a0aaaaaa", type: "general-purpose", records: [open])
        try write("a1bbbbbb", parent: "a0aaaaaa", records: [open])
        var seen: [SubagentTree] = []
        let w = makeWatcher { seen.append($0) }
        w.rescan()
        XCTAssertEqual(seen.last?.nodes.count, 2)
        XCTAssertEqual(seen.last?.node("a1bbbbbb")?.parentID, "a0aaaaaa")
        XCTAssertEqual(seen.last?.liveTopLevelCount, 1)
    }

    func testAnAppendThatFinishesAnAgentIsReported() throws {
        try write("a0aaaaaa", records: [open])
        var seen: [SubagentTree] = []
        let w = makeWatcher { seen.append($0) }
        w.rescan()
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("agent-a0aaaaaa.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data((finished + "\n").utf8)); try h.close()
        w.poll()
        XCTAssertEqual(seen.last?.node("a0aaaaaa")?.state, .done)
    }

    func testFilesFromBeforeTheProcessStartedAreIgnored() throws {
        try write("a0aaaaaa", records: [open])
        let w = SubagentWatcher(directory: dir, clock: nil,
                                startedAt: { Date().addingTimeInterval(60) },
                                keepDoneSince: { nil }, onChange: { _ in })
        w.rescan()
        XCTAssertTrue(w.tree.nodes.isEmpty)
    }

    /// Review Focus 5: a steady tick must not stat every file in a 200-file folder.
    func testASteadyTickStatsOnlyLiveFiles() throws {
        for i in 0..<20 { try write(String(format: "a%07x", i + 0x100), records: [finished]) }
        try write("a0aaaaaa", records: [open])
        let w = makeWatcher { _ in }
        w.rescan()
        w.poll()
        XCTAssertLessThanOrEqual(w.statCount, 2, "the live file plus the folder, not 21 files")
        clockNow = clockNow.addingTimeInterval(SubagentWatcher.fullRescanInterval + 1)
        w.poll()
        XCTAssertGreaterThanOrEqual(w.statCount, 21, "a periodic full rescan still runs")
    }

    func testANewFileIsFoundOnTheNextTick() throws {
        let w = makeWatcher { _ in }
        w.rescan()
        // Folder mtime has 1s granularity on some filesystems: the watcher must not miss a file
        // created in the same second as its last look.
        try write("a0aaaaaa", records: [open])
        w.poll()
        XCTAssertEqual(w.tree.nodes.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `FD_TEST_FILTER=SubagentWatcherTests ./scripts/test-unit.sh`; expected: `SubagentWatcher` not found.

- [ ] **Step 3: Implement `Sources/FlightDeck/Agents/SubagentWatcher.swift`**

```swift
import FleetKit
import Foundation

/// Keeps one conversation's `SubagentTree` current from its `subagents/` folder.
///
/// **A steady tick touches only live files.** A conversation can hold hundreds of finished
/// agents (238 on 2026-10-05); stat-ing all of them every 500ms for every session is the cost
/// this avoids. Each tick stats the folder (a new file changes its mtime) and the non-done
/// files; every `fullRescanInterval` it stats everything, which is what notices a finished
/// agent resumed by `SendMessage`. A new file is also caught when the folder's mtime is
/// unchanged at 1s granularity, because any second in which the folder changed is rescanned.
@MainActor
final class SubagentWatcher {
    static let fullRescanInterval: TimeInterval = 10

    private let directory: URL
    private weak var clock: WatchClock?
    private let startedAt: () -> Date?
    private let keepDoneSince: () -> Date?
    private let onChange: (SubagentTree) -> Void
    var now: () -> Date = Date.init

    private(set) var tree = SubagentTree.empty
    private(set) var statCount = 0
    private var metas: [String: SubagentMeta] = [:]
    private var scans: [String: (stamp: TranscriptStamp, state: SubagentNode.State)] = [:]
    private var folderStamp: TranscriptStamp?
    private var lastFullRescan = Date.distantPast

    init(directory: URL, clock: WatchClock?, startedAt: @escaping () -> Date?,
         keepDoneSince: @escaping () -> Date?, onChange: @escaping (SubagentTree) -> Void) {
        self.directory = directory
        self.clock = clock
        self.startedAt = startedAt
        self.keepDoneSince = keepDoneSince
        self.onChange = onChange
    }

    func start() { clock?.add(self) { [weak self] in self?.poll() } }
    func stop() { clock?.remove(self) }

    /// One tick. Cheap unless the folder or a live file changed.
    func poll() {
        statCount = 0
        let folder = TranscriptStamp(of: directory)
        statCount += 1
        let folderChanged = folder != folderStamp
        let due = now().timeIntervalSince(lastFullRescan) >= Self.fullRescanInterval
        if folderChanged || due || folderStampIsThisSecond(folder) {
            rescan()
            return
        }
        var changed = false
        for (id, scan) in scans where scan.state != .done {
            let file = jsonl(id)
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if stamp != scan.stamp {
                scans[id] = (stamp, Self.state(of: file))
                changed = true
            }
        }
        if changed { publish() }
    }

    /// Everything, from scratch: listing plus one stat per file, re-reading only what changed.
    func rescan() {
        statCount = 1
        folderStamp = TranscriptStamp(of: directory)
        lastFullRescan = now()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let since = startedAt()
        var seen: Set<String> = []
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("agent-") else { continue }
            let id = String(name.dropFirst("agent-".count))
            guard SubagentID.isValid(id) else { continue }
            statCount += 1
            guard let stamp = TranscriptStamp(of: file) else { continue }
            if let since, stamp.modified < since { continue }
            seen.insert(id)
            if metas[id] == nil {
                metas[id] = SubagentFiles.meta(at: directory.appendingPathComponent("agent-\(id).meta.json"))
            }
            if let previous = scans[id], previous.stamp == stamp { continue }
            scans[id] = (stamp, Self.state(of: file))
        }
        scans = scans.filter { seen.contains($0.key) }
        metas = metas.filter { seen.contains($0.key) }
        publish()
    }

    private func publish() {
        let states = scans.mapValues { ($0.state, $0.stamp.modified) }
        let next = SubagentTree.build(metas: metas.compactMapValues { $0 }, states: states,
                                      keepDoneSince: keepDoneSince())
        guard next != tree else { return }
        tree = next
        onChange(next)
    }

    private func folderStampIsThisSecond(_ stamp: TranscriptStamp?) -> Bool {
        guard let stamp else { return false }
        return Int(now().timeIntervalSince1970) <= stamp.mtimeSeconds
    }

    private func jsonl(_ id: String) -> URL { directory.appendingPathComponent("agent-\(id).jsonl") }

    private static func state(of file: URL) -> SubagentNode.State {
        let lines = TranscriptPager.page(url: file, anchor: .latest,
                                         limit: PromptService.tailRecords)?.lines ?? []
        return SubagentFiles.state(ofTail: lines)
    }
}
```

Note: `metas` is `[String: SubagentMeta?]` in effect because `SubagentFiles.meta` can fail (meta not yet written). Declare it as `private var metas: [String: SubagentMeta?] = [:]` and retry a nil entry on the next rescan (`if metas[id] == nil || metas[id]! == nil`). Keep `compactMapValues { $0 }` in `publish()`.

- [ ] **Step 4: Run** `FD_TEST_FILTER=SubagentWatcherTests ./scripts/test-unit.sh` — expected PASS (5 tests).

- [ ] **Step 5: Add the event and runtime wiring, with a failing runtime test.** In `ClaudeRuntimeTests.swift` add:

```swift
    func testAttachReportsTheSubagentTreeAndCountsAgentsStartedBeforeAttach() throws {
        let id = UUID()
        let url = dir.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let sub = url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try #"{"agentType":"implementer","description":"d","spawnDepth":1}"#
            .write(to: sub.appendingPathComponent("agent-a0aaaaaa.meta.json"), atomically: true, encoding: .utf8)
        try #"{"isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}"#
            .write(to: sub.appendingPathComponent("agent-a0aaaaaa.jsonl"), atomically: true, encoding: .utf8)

        let runtime = ClaudeRuntime()
        var seen: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: url), for: UUID()) {
            seen.append($0)
        }
        runtime.drainForTesting()
        guard case .subagents(let tree)? = seen.first(where: {
            if case .subagents = $0 { return true } else { return false }
        }) else { return XCTFail("no tree reported: \(seen)") }
        XCTAssertEqual(tree.node("a0aaaaaa")?.type, "implementer")
        XCTAssertTrue(seen.contains(.subagentCount(1)),
                      "an agent launched before attach is counted — the fold alone reads 0")
    }
```

Run it; expected FAIL (`.subagents` does not exist).

- [ ] **Step 6: Implement the wiring.**
  - `AgentKind.swift`: add to `AgentEvent`, with a doc line saying it is claude-only and rebuilt from files:

    ```swift
    /// This conversation's background agents at every depth, rebuilt from `subagents/`. Claude
    /// only; `.subagentCount` stays the number every other reader uses.
    case subagents(SubagentTree)
    ```
  - `ClaudeRuntime.swift`: `Source` gains `let subagents: SubagentWatcher?` and `var foldCount: Int`. Add init params `agentStartedAt: @escaping (UUID) -> Date? = { _ in nil }` and `lastPromptSubmit: @escaping (UUID) -> Date? = { _ in nil }`, stored. In `attach`, when `binding.transcriptURL` is non-nil create:

    ```swift
    let directory = url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    let subagents = SubagentWatcher(
        directory: directory, clock: clock,
        startedAt: { [weak self] in self?.agentStartedAt(id) },
        keepDoneSince: { [weak self] in self?.lastPromptSubmit(id) ?? self?.agentStartedAt(id) },
        onChange: { [weak self] tree in self?.publish(tree, for: id) }
    )
    ```
    Replace `onSubagentCount: { subscribers.emit(.subagentCount($0)) }` with `onSubagentCount: { [weak self] in self?.fold($0, for: id) }`. Add:

    ```swift
    /// The count is the larger of the transcript fold and the tree. The fold sees a launch
    /// the instant it is written, before the agent's own file exists; the tree sees agents
    /// launched before this attach, which the fold (it starts at end of file) never will.
    private func fold(_ count: Int, for id: UUID) {
        sources[id]?.foldCount = count
        sources[id]?.subagents?.rescan()
        emitCount(for: id)
    }
    private func publish(_ tree: SubagentTree, for id: UUID) {
        sources[id]?.subscribers.emit(.subagents(tree))
        emitCount(for: id)
    }
    private func emitCount(for id: UUID) {
        guard let source = sources[id] else { return }
        let count = max(source.foldCount, source.subagents?.tree.liveTopLevelCount ?? 0)
        source.subscribers.emit(.subagentCount(count))
    }
    ```
    `sources` must become a dictionary of a class or be mutated through `sources[id]?.foldCount = …` (make `Source` a struct with `var foldCount`). Call `subagents.start()` and an initial `subagents.rescan()` after `sources[id] = …`. `detach` calls `source.subagents?.stop()`. `drainForTesting()` also calls `source.subagents?.rescan()`. Duplicate `.subagentCount` emissions are harmless: `SessionStore.applySubagentCount` returns early on an unchanged count.
  - `SessionStore.swift`: add `private(set) var subagentTrees: [UUID: SubagentTree] = [:]` beside `subagentCounts` (~line 1130), `func subagentTree(for tab: UUID) -> SubagentTree { subagentTrees[tab] ?? .empty }`, and in `apply(_:to:)` add `case .subagents(let tree): applySubagents(tabID, tree)` with:

    ```swift
    /// Stored per tab and pushed as an `activityChanged` so the phone's tree updates without
    /// waiting for an activity edge. The wire half lands in Task 6; until then this only stores.
    func applySubagents(_ id: UUID, _ tree: SubagentTree) {
        guard subagentTrees[id] != tree else { return }
        subagentTrees[id] = tree
    }
    ```
    Clear `subagentTrees[id]` wherever `subagentCounts.removeValue(forKey:)` / `subagentCounts[tabID] = 0` run (lines ~4313, 8274, 8639, 8702).
    Where `ClaudeRuntime(` is constructed in `SessionStore`, pass `agentStartedAt:` resolving conversation → tab (`tab(forConversation:)` or the loop the store already uses for `attachments`) → `claudePID(of:)` → `ProcessTree().startTime(of:)` → `Date`, and `lastPromptSubmit:` reading `lastPromptSubmits[conversationID]` (a `[UUID: Date]` the store fills in Task 4; declare it now, empty).

- [ ] **Step 7: Run** `FD_TEST_FILTER=SubagentWatcherTests,ClaudeRuntimeTests,TranscriptWatcherTests,SessionStoreAnswerlessTests ./scripts/test-unit.sh`; expected PASS. Then the full suite `./scripts/test-unit.sh` (any `subagentCount` expectation that changed means an existing test relied on the fold alone — read it before touching it; never weaken an assertion).

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Agents/SubagentWatcher.swift Sources/FlightDeck/Agents/AgentKind.swift \
  Sources/FlightDeck/Agents/ClaudeRuntime.swift Sources/FlightDeck/SessionStore.swift \
  Tests/FlightDeckTests/SubagentWatcherTests.swift Tests/FlightDeckTests/ClaudeRuntimeTests.swift
git commit -m "feat: track every subagent from its own files and count agents started before attach

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Record `PermissionRequest` and attribute the dialog to an agent and call

**Files:**
- Modify: `Resources/ClaudePlugin/hooks/hooks.json` (add `PermissionRequest`)
- Modify: `Sources/FlightDeck/Agents/ComposerReadiness.swift` (`HookEventRecord` gains optional fields)
- Create: `Sources/FlightDeck/Agents/DialogAttribution.swift` (pure fold)
- Modify: `Sources/FlightDeck/HookEventWatcher.swift` (second callback)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`pendingDialogs`, `lastPromptSubmits`)
- Test: `Tests/FlightDeckTests/DialogAttributionTests.swift`, `Tests/FlightDeckTests/HookEventWatcherTests.swift` (extend; create if absent)

**Interfaces:**
- Consumes: Task 3's `SessionStore.lastPromptSubmits`.
- Produces:
  - `struct PendingDialog: Equatable, Sendable { let agentID: String?; let callID: String }`
  - `struct DialogAttribution` with `mutating func apply(_ record: HookEventRecord) -> Change?` where `enum Change: Equatable { case raised(UUID, PendingDialog), cleared(UUID), promptSubmitted(UUID, Date) }`.
  - `HookEventRecord` new optional fields: `agentID: String?`, `toolUseID: String?`, `toolName: String?`, `toolInput: String?` (canonical JSON, keys sorted).
  - `HookEventWatcher.init(directory:clock:onChange:onDialog:)` with `onDialog: @escaping ([DialogAttribution.Change]) -> Void = { _ in }`.
  - `SessionStore.pendingDialog(forConversation: UUID) -> PendingDialog?`; `SessionStore.pendingDialog(for tab: UUID) -> PendingDialog?`.

- [ ] **Step 1: Register the hook.** Add to `Resources/ClaudePlugin/hooks/hooks.json` `"hooks"`:

```json
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
```

`record.sh` prints nothing to stdout, so the hook makes no permission decision and cannot race Plannotator's `PermissionRequest` hook. Add that sentence to the file's `description`.

- [ ] **Step 2: Write the failing tests** (`DialogAttributionTests.swift`)

```swift
import XCTest
@testable import FlightDeck

final class DialogAttributionTests: XCTestCase {
    private let sid = UUID()
    private func line(_ event: String, agent: String? = nil, tool: String = "Bash",
                      input: String = #"{"command":"rm -rf x"}"#, toolUseID: String? = nil) -> HookEventRecord {
        var obj = #"{"session_id":"\#(sid.uuidString.lowercased())","hook_event_name":"\#(event)","tool_name":"\#(tool)","tool_input":\#(input)"#
        if let agent { obj += #","agent_id":"\#(agent)","agent_type":"implementer""# }
        if let toolUseID { obj += #","tool_use_id":"\#(toolUseID)""# }
        return HookEventRecord.decode(obj + "}")!
    }

    func testAPermissionRequestCarryingItsIDsIsAttributedDirectly() {
        var a = DialogAttribution()
        XCTAssertEqual(a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X")),
                       .raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X")))
    }

    func testWithoutIDsItMatchesThePrecedingPreToolUse() {
        var a = DialogAttribution()
        _ = a.apply(line("PreToolUse", agent: "a1111111", input: #"{"command":"ls"}"#, toolUseID: "toolu_OTHER"))
        _ = a.apply(line("PreToolUse", agent: "a28ad87b", toolUseID: "toolu_X"))
        XCTAssertEqual(a.apply(line("PermissionRequest")),
                       .raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X")))
    }

    func testTheMainAgentsDialogHasNoAgentID() {
        var a = DialogAttribution()
        _ = a.apply(line("PreToolUse", toolUseID: "toolu_MAIN"))
        XCTAssertEqual(a.apply(line("PermissionRequest")),
                       .raised(sid, PendingDialog(agentID: nil, callID: "toolu_MAIN")))
    }

    /// Review Focus 3: never guess.
    func testNoPermissionRequestMeansNoPendingDialog() {
        var a = DialogAttribution()
        XCTAssertNil(a.apply(line("PreToolUse", agent: "a28ad87b", toolUseID: "toolu_X")))
        XCTAssertNil(a.apply(line("PermissionRequest", agent: "a28ad87b",
                                  input: #"{"command":"never seen"}"#)),
                     "no matching PreToolUse and no tool_use_id: nothing is attributed")
    }

    /// Review Focus 4: a new user turn means the old dialog is gone.
    func testUserPromptSubmitClearsThePendingDialog() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        guard case .promptSubmitted(let id, _)? = a.apply(line("UserPromptSubmit")) else {
            return XCTFail("expected promptSubmitted")
        }
        XCTAssertEqual(id, sid)
    }

    func testPostToolUseForTheAttributedCallClearsIt() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        XCTAssertEqual(a.apply(line("PostToolUse", agent: "a28ad87b", toolUseID: "toolu_X")), .cleared(sid))
    }
}
```

Also extend (or create) `HookEventWatcherTests` with one test: write two lines (`PreToolUse` with ids, `PermissionRequest` without) into `events.ndjson` after constructing the watcher, `drain()`, and assert `onDialog` received `[.raised(sid, PendingDialog(agentID:"a28ad87b", callID:"toolu_X"))]`.

- [ ] **Step 3: Run to verify failure** — `FD_TEST_FILTER=DialogAttributionTests,HookEventWatcherTests ./scripts/test-unit.sh`; expected: missing types.

- [ ] **Step 4: Implement.**
  - `HookEventRecord` (in `ComposerReadiness.swift`): add the optional fields and fill them in `decode`. `toolInput` is canonical JSON so equality is stable:

    ```swift
    // `var … = nil`, not `let`: Swift's memberwise init skips a `let` that has a default, and
    // existing `HookEventRecord(sessionID:event:)` call sites must keep compiling.
    var agentID: String? = nil
    var toolUseID: String? = nil
    var toolName: String? = nil
    var toolInput: String? = nil
    // in decode, after sessionID/event:
    let input = obj["tool_input"].flatMap {
        try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])
    }.flatMap { String(data: $0, encoding: .utf8) }
    return HookEventRecord(sessionID: sessionID, event: event,
                           agentID: (obj["agent_id"] as? String).flatMap { SubagentID.isValid($0) ? $0 : nil },
                           toolUseID: obj["tool_use_id"] as? String,
                           toolName: obj["tool_name"] as? String, toolInput: input)
    ```
    Timestamps come from `DialogAttribution.now`, not from the record.
  - `Sources/FlightDeck/Agents/DialogAttribution.swift`:

    ```swift
    import Foundation

    struct PendingDialog: Equatable, Sendable {
        let agentID: String?
        let callID: String
    }

    /// Which agent and call the dialog on screen belongs to, from the hook log.
    ///
    /// claude draws a background subagent's permission dialog in the parent's TUI, so the
    /// screen and the registry cannot say whose it is. `PermissionRequest` fires at raise; if it
    /// does not carry `tool_use_id` itself, the `PreToolUse` that preceded it for the same tool
    /// and input does (verified: `PreToolUse` carries `agent_id` and `tool_use_id`). Esc fires
    /// no hook, so this never decides a dialog is still open: `PromptService` confirms against
    /// the transcript.
    struct DialogAttribution {
        enum Change: Equatable {
            case raised(UUID, PendingDialog)
            case cleared(UUID)
            case promptSubmitted(UUID, Date)
        }
        private struct Pre { let agentID: String?; let toolUseID: String; let tool: String?; let input: String? }
        private var recent: [UUID: [Pre]] = [:]
        private var pending: [UUID: PendingDialog] = [:]
        var now: () -> Date = Date.init

        mutating func apply(_ r: HookEventRecord) -> Change? {
            switch r.event {
            case "PreToolUse":
                guard let id = r.toolUseID else { return nil }
                var list = recent[r.sessionID] ?? []
                list.append(Pre(agentID: r.agentID, toolUseID: id, tool: r.toolName, input: r.toolInput))
                recent[r.sessionID] = Array(list.suffix(32))
                return nil
            case "PermissionRequest":
                let callID = r.toolUseID ?? recent[r.sessionID]?.last(where: {
                    $0.tool == r.toolName && $0.input == r.toolInput
                        && (r.agentID == nil || $0.agentID == r.agentID)
                })?.toolUseID
                guard let callID else { return nil }
                let agent = r.agentID ?? recent[r.sessionID]?.last { $0.toolUseID == callID }?.agentID
                let dialog = PendingDialog(agentID: agent, callID: callID)
                pending[r.sessionID] = dialog
                return .raised(r.sessionID, dialog)
            case "PostToolUse":
                guard let id = r.toolUseID, pending[r.sessionID]?.callID == id else { return nil }
                pending[r.sessionID] = nil
                return .cleared(r.sessionID)
            case "UserPromptSubmit":
                pending[r.sessionID] = nil
                return .promptSubmitted(r.sessionID, now())
            case "SessionEnd":
                pending[r.sessionID] = nil
                recent[r.sessionID] = nil
                return .cleared(r.sessionID)
            default:
                return nil
            }
        }
    }
    ```
  - `HookEventWatcher`: add `private var attribution = DialogAttribution()` and `private let onDialog: ([DialogAttribution.Change]) -> Void` (init param defaulted to `{ _ in }`). In `drain()`'s loop, `if let change = attribution.apply(record) { dialogChanges.append(change) }`; after the loop, `if !dialogChanges.isEmpty { onDialog(dialogChanges) }`. This runs before the existing `guard !changes.isEmpty` early return.
  - `SessionStore`: `private(set) var pendingDialogs: [UUID: PendingDialog] = [:]` (keyed by conversation id) and `var lastPromptSubmits: [UUID: Date] = [:]` (from Task 3). Pass `onDialog: { [weak self] in self?.ingestDialogChanges($0) }` in `startHookEventWatching`:

    ```swift
    private func ingestDialogChanges(_ changes: [DialogAttribution.Change]) {
        for change in changes {
            switch change {
            case .raised(let conversation, let dialog): pendingDialogs[conversation] = dialog
            case .cleared(let conversation): pendingDialogs[conversation] = nil
            case .promptSubmitted(let conversation, let at):
                pendingDialogs[conversation] = nil
                lastPromptSubmits[conversation] = at
            }
        }
        recommitStatuses()
    }

    func pendingDialog(for tab: UUID) -> PendingDialog? {
        guard let at = locate(tab) else { return nil }
        return pendingDialogs[repos[at.repo].sessions[at.session].pinnedConversationID]
    }
    ```
    Also clear `pendingDialogs[conversation]` where `hookEventWatcher?.forget(conversation)` is called (~7432, ~7507).

- [ ] **Step 5: Run** `FD_TEST_FILTER=DialogAttributionTests,HookEventWatcherTests,ComposerReadinessTests ./scripts/test-unit.sh` — PASS.

- [ ] **Step 6: Commit**

```bash
git add Resources/ClaudePlugin/hooks/hooks.json Sources/FlightDeck/Agents/ComposerReadiness.swift \
  Sources/FlightDeck/Agents/DialogAttribution.swift Sources/FlightDeck/HookEventWatcher.swift \
  Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/DialogAttributionTests.swift \
  Tests/FlightDeckTests/HookEventWatcherTests.swift
git commit -m "feat: name the agent and call behind a permission dialog from a record-only hook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Derive, page and answer a subagent's dialog on the Mac

**Files:**
- Modify: `Sources/FlightDeck/Fleet/PromptService.swift`
- Modify: `Sources/FlightDeck/Fleet/TimelineService.swift`, `Sources/FlightDeck/Timeline/TimelineReader.swift` (sidechain flag), and the adapter's `timelineItems(inLine:at:)` path
- Modify: `Sources/FlightDeck/SessionStore.swift` (`openPromptAgents`, probe for the agent)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (wire the agent probe; pass `agent: nil` to the new signatures until Task 6)
- Test: `Tests/FlightDeckTests/PromptServiceTests.swift`, `Tests/FlightDeckTests/TimelineServiceTests.swift`

**Interfaces:**
- Consumes: Task 4's `SessionStore.pendingDialog(for:)`; Task 2's `SubagentID.isValid`; `AgentOpenPromptReader.subagentTranscripts(for:)` / `openPrompt(inSubagentTail:)`.
- Produces:
  - `PromptService.answer(session: UUID, agent: String?, call: String, answer: PromptAnswer, token: UUID) -> Result<Void, TimelineErrorCode>` (old 4-arg form removed; callers pass `agent: nil`).
  - `PromptService.openPromptAgent(inSession:) -> String?` — the agent whose file holds the call the last push/poll derivation returned.
  - `TimelineService.page(session: UUID, agent: String?, anchor: TimelineAnchor, limit: Int) async -> Result<TimelinePage, TimelineErrorCode>`; new refusal code `"unknown_agent"`.
  - `SessionStore.openPromptAgents: [UUID: String]` and `var openPromptAgentProbe: ((UUID) -> String?)?`.

- [ ] **Step 1: Write the failing tests** in `PromptServiceTests.swift`, under the existing `// MARK: Background subagents` (reuse `writeSubagent`, `sidechain`, `bashLine`, `resultLine`, `makeService`). Add a test seam `service.pendingDialog: (UUID) -> PendingDialog?` (defaulted in `init` to `{ [weak store] in store?.pendingDialog(for: $0) }`).

```swift
    func testAnAttributedSubagentCallIsTheOpenPrompt() throws {
        let (service, store, _, id) = makeService(activity: .waiting)
        try writeTranscript(for: store, id, [bookkeepingLine()])
        try writeSubagent(for: store, id, agent: "a28ad87b", [sidechain(bashLine("toolu_SUB"))])
        service.pendingDialog = { _ in PendingDialog(agentID: "a28ad87b", callID: "toolu_SUB") }
        let parent = [SourceLine(offset: 0, text: bookkeepingLine())]
        let sub = [SourceLine(offset: 0, text: sidechain(bashLine("toolu_SUB")))]
        service.tail = { url, _ in (url.path.contains("/subagents/") ? sub : parent, false) }
        XCTAssertEqual(try service.pushedOpenPrompt(inSession: id).get().callID, "toolu_SUB")
        XCTAssertEqual(service.openPromptAgent(inSession: id), "a28ad87b")
    }

    /// Review Focus 3.
    func testWithoutAPendingDialogTheRefusalIsSubagentPrompt() throws {
        let (service, store, _, id) = makeService(activity: .waiting)
        try writeTranscript(for: store, id, [bookkeepingLine()])
        try writeSubagent(for: store, id, agent: "a28ad87b", [sidechain(bashLine("toolu_SUB"))])
        service.pendingDialog = { _ in nil }
        let parent = [SourceLine(offset: 0, text: bookkeepingLine())]
        let sub = [SourceLine(offset: 0, text: sidechain(bashLine("toolu_SUB")))]
        service.tail = { url, _ in (url.path.contains("/subagents/") ? sub : parent, false) }
        XCTAssertEqual(try? failureCode(service.pushedOpenPrompt(inSession: id)), "subagent_prompt")
    }

    /// Review Focus 4.
    func testAResolvedSubagentCallIsNoLongerOffered() throws {
        let (service, store, _, id) = makeService(activity: .waiting)
        try writeTranscript(for: store, id, [bookkeepingLine()])
        try writeSubagent(for: store, id, agent: "a28ad87b",
                          [sidechain(bashLine("toolu_SUB")), sidechain(resultLine("toolu_SUB"))])
        service.pendingDialog = { _ in PendingDialog(agentID: "a28ad87b", callID: "toolu_SUB") }
        let parent = [SourceLine(offset: 0, text: bookkeepingLine())]
        let sub = [SourceLine(offset: 0, text: sidechain(bashLine("toolu_SUB"))),
                   SourceLine(offset: 1, text: sidechain(resultLine("toolu_SUB")))]
        service.tail = { url, _ in (url.path.contains("/subagents/") ? sub : parent, false) }
        XCTAssertEqual(try? failureCode(service.pushedOpenPrompt(inSession: id)), "prompt_changed")
    }

    func testAnsweringASubagentsDialogDrivesTheTerminal() throws {
        let (service, store, spy, id) = makeService(activity: .waiting)
        try writeTranscript(for: store, id, [bookkeepingLine()])
        try writeSubagent(for: store, id, agent: "a28ad87b", [sidechain(bashLine("toolu_SUB"))])
        service.pendingDialog = { _ in PendingDialog(agentID: "a28ad87b", callID: "toolu_SUB") }
        let parent = [SourceLine(offset: 0, text: bookkeepingLine())]
        let sub = [SourceLine(offset: 0, text: sidechain(bashLine("toolu_SUB")))]
        service.tail = { url, _ in (url.path.contains("/subagents/") ? sub : parent, false) }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertNil(code(service.answer(session: id, agent: "a28ad87b", call: "toolu_SUB",
                                         answer: .allow, token: UUID())))
        XCTAssertFalse(spy.events.isEmpty, "the dialog was driven")
    }

    /// Review Focus 2: an open call that no PermissionRequest named is a running tool.
    func testAnAnswerForASubagentWithNoPendingDialogIsRefused() throws {
        let (service, store, spy, id) = makeService(activity: .waiting)
        try writeTranscript(for: store, id, [bookkeepingLine()])
        try writeSubagent(for: store, id, agent: "a28ad87b", [sidechain(bashLine("toolu_SUB"))])
        service.pendingDialog = { _ in PendingDialog(agentID: "a9999999", callID: "toolu_OTHER") }
        let sub = [SourceLine(offset: 0, text: sidechain(bashLine("toolu_SUB")))]
        service.tail = { _, _ in (sub, false) }
        spy.showOptions(["Yes", "No"], selected: 0)
        XCTAssertEqual(code(service.answer(session: id, agent: "a28ad87b", call: "toolu_SUB",
                                           answer: .allow, token: UUID())), "prompt_changed")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// Review Focus 1.
    func testATraversalAgentIDIsRefusedBeforeAnyRead() {
        let (service, _, spy, id) = makeService(activity: .waiting)
        let reads = ReadCount()
        service.tail = { _, _ in reads.value += 1; return ([], false) }
        XCTAssertEqual(code(service.answer(session: id, agent: "../../etc", call: "toolu_X",
                                           answer: .allow, token: UUID())), "unknown_agent")
        XCTAssertEqual(reads.value, 0)
        XCTAssertTrue(spy.events.isEmpty)
    }
```

In `TimelineServiceTests.swift` add a test that `page(session:agent:"../x",anchor:.latest,limit:8)` returns `.failure("unknown_agent")` without calling `reader`, and one that `agent: "a28ad87b"` calls `reader` with the URL `<transcript without .jsonl>/subagents/agent-a28ad87b.jsonl` and `sidechain: true` (extend the `reader` seam signature to carry `sidechain: Bool`).

- [ ] **Step 2: Run to verify failure** — `FD_TEST_FILTER=PromptServiceTests,TimelineServiceTests ./scripts/test-unit.sh`.

- [ ] **Step 3: Implement in `PromptService`.**
  - Replace `attributingSubagents` with an attribution-first version:

    ```swift
    /// The tab's own derivation missed. If the hook log named a subagent's call and that
    /// call is still unresolved in the subagent's file, THAT is the open prompt. If a subagent
    /// holds an open call the hook did not name, refuse `subagent_prompt` (never `answerless`).
    private func attributingSubagents(
        _ session: UUID, _ result: Result<OpenPrompt, TimelineErrorCode>?
    ) -> Result<OpenPrompt, TimelineErrorCode>? {
        guard case .failure(let code)? = result, code.code == "prompt_changed" else {
            if case .success? = result { attributedAgents[session] = nil }
            return result
        }
        if let dialog = pendingDialog(session), let agent = dialog.agentID,
           let open = subagentOpenPrompt(session, agent: agent), open.callID == dialog.callID {
            attributedAgents[session] = agent
            return .success(open)
        }
        attributedAgents[session] = nil
        return subagentHoldsOpenCall(session) ? .failure("subagent_prompt") : result
    }

    private var attributedAgents: [UUID: String] = [:]
    func openPromptAgent(inSession session: UUID) -> String? { attributedAgents[session] }

    /// One window of the subagent's own file, read as `waiting`. Nil for an invalid id, a tab
    /// that is not waiting, or no transcript.
    private func subagentOpenPrompt(_ session: UUID, agent: String) -> OpenPrompt? {
        guard SubagentID.isValid(agent), case .success(let read) = preflight(session),
              let dir = read.reader.subagentTranscripts(for: read.url) else { return nil }
        let lines = tail(dir.appendingPathComponent("agent-\(agent).jsonl"), Self.tailRecords).lines
        return read.reader.openPrompt(inSubagentTail: lines)
    }
    ```
    Prune `attributedAgents` alongside `derived` (`filter` on `.waiting`).
  - New `answer`:

    ```swift
    func answer(
        session: UUID, agent: String?, call: String, answer: PromptAnswer, token: UUID
    ) -> Result<Void, TimelineErrorCode> {
        let derived: Result<OpenPrompt, TimelineErrorCode>
        if let agent {
            // Checked before any path is built: this id came off the wire.
            guard SubagentID.isValid(agent) else {
                record(session, sent: call, open: nil, code: "unknown_agent")
                return .failure("unknown_agent")
            }
            // A subagent's open call is only a dialog if the hook log named it.
            guard let dialog = pendingDialog(session), dialog.agentID == agent,
                  dialog.callID == call else {
                record(session, sent: call, open: nil, code: "prompt_changed")
                return .failure("prompt_changed")
            }
            switch preflight(session) {
            case .failure(let code): derived = .failure(code)
            case .success:
                derived = subagentOpenPrompt(session, agent: agent)
                    .map { .success($0) } ?? .failure("prompt_changed")
            }
        } else {
            derived = openPrompt(inSession: session)
        }
        switch derived {
        case .failure(let code):
            record(session, sent: call, open: nil, code: code.code)
            return .failure(code)
        case .success(let open):
            guard open.callID == call else {
                record(session, sent: call, open: open.callID, code: "prompt_changed")
                return .failure("prompt_changed")
            }
            let outcome = store.answerPrompt(open, with: answer, in: session, token: token)
            record(session, sent: call, open: open.callID, code: outcome.errorCode)
            if let code = outcome.errorCode { return .failure(TimelineErrorCode(code)) }
            return .success(())
        }
    }
    ```
    Update every existing caller (`FleetService.swift:1291` arm, `AnswerTrigger.swift`, tests) to pass `agent: nil` for now.
  - `SessionStore`: add `var openPromptAgentProbe: ((UUID) -> String?)?` and `private(set) var openPromptAgents: [UUID: String] = [:]`; in `derivedOpenPromptCalls`'s `.success` arm also record `agents[id] = openPromptAgentProbe?(id)`; return and assign `openPromptAgents` beside `openPromptCalls` in `commitStatuses`; include it in the "changed" comparison so a change of agent re-emits. `FleetService` sets `store.openPromptAgentProbe = { [weak prompts] in prompts?.openPromptAgent(inSession: $0) }`.
- [ ] **Step 4: Implement `TimelineService.page(session:agent:anchor:limit:)`.** After resolving `.file(agent, url)`: if `agent` (the subagent id param — name it `subagent` locally to avoid shadowing `AgentID`) is non-nil, require `SubagentID.isValid` else `.failure("unknown_agent")`; resolve the directory through `resolvedAgent.openPromptReader?.subagentTranscripts(for: url)` (nil → `"unknown_agent"`); read `dir/agent-<id>.jsonl` with `sidechain: true`. Thread a `sidechain: Bool` parameter through `reader` and `TimelineReader.page(session:agent:url:anchor:limit:sidechain:)` down to `ClaudeTimelineMapper.items(inLine:at:sidechain:)` (the adapter's `timelineItems(inLine:at:)` gets a `sidechain:` variant; codex ignores it). `FleetService`'s `.timeline` arm passes `agent: nil` until Task 6.
- [ ] **Step 5: Run** `FD_TEST_FILTER=PromptServiceTests,TimelineServiceTests,SessionStoreAnswerlessTests,PromptLifecycleTests,PromptIdentityWireTests,AnswerPromptTests ./scripts/test-unit.sh` — PASS. Then `./scripts/test-unit.sh`.
- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/PromptService.swift Sources/FlightDeck/Fleet/TimelineService.swift \
  Sources/FlightDeck/Timeline/TimelineReader.swift Sources/FlightDeck/SessionStore.swift \
  Sources/FlightDeck/Fleet/FleetService.swift Sources/FlightDeck/Fleet/AnswerTrigger.swift \
  Sources/FlightDeck/Agents Tests/FlightDeckTests
git commit -m "feat: derive and answer a subagent's permission dialog once the hook names it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
(Stage only files you changed — check `git status` first; `Sources/FlightDeck/Agents` and `Tests/FlightDeckTests` above are directories, so list the touched files instead if anything unrelated is modified there.)

---

### Task 6: Wire fields, projection and emission (one commit)

**Files:**
- Create: `Sources/FleetKit/WireSubagent.swift`
- Modify: `Sources/FleetKit/Wire.swift` (`WireSession.subagents`, `openPromptAgent`), `Sources/FleetKit/FleetEvent.swift` (`activityChanged` + 2 params), `Sources/FleetKit/WireCoding.swift`, `Sources/FleetKit/SnapshotApplication.swift`, `Sources/FleetKit/FleetReplay.swift`, `Sources/FleetKit/TimelineFrames.swift` (`timeline(... agent:)`), `Sources/FleetKit/Frames.swift` (`answerPrompt(... agent:)`)
- Modify (match sites): `Sources/FlightDeck/Fleet/PromptLifecycleObserver.swift`, `Sources/FlightDeckCLI/CLIRunner.swift`, `Sources/FlightDeckCLI/CLIOutput.swift` (find with `rg -n 'activityChanged\(|\.timeline\(|answerPrompt\(' Sources Tests`)
- Modify: `Sources/FlightDeck/Fleet/FleetProjection.swift`, `Sources/FlightDeck/SessionStore.swift` (`emitActivity`, `applySubagentCount`, `applySubagents`), `Sources/FlightDeck/Fleet/FleetService.swift` (pass `agent` through)
- Test: `Tests/FlightDeckTests/FleetWireTests.swift`, `Tests/FlightDeckTests/TimelineFrameCodingTests.swift`, `Tests/FlightDeckTests/FleetFieldEmissionTests.swift`

**Interfaces:**
- Consumes: Task 3 `subagentTrees`, Task 5 `openPromptAgents`, `PromptService.answer(session:agent:...)`, `TimelineService.page(session:agent:...)`.
- Produces (FleetKit, public):

  ```swift
  public struct WireSubagent: Codable, Equatable, Sendable, Identifiable {
      public let id: String
      public let parent: String?
      public let type: String
      public let description: String
      public let state: String   // "running" | "blocked" | "done"; unknown → render as running
      public init(id: String, parent: String?, type: String, description: String, state: String)
  }
  ```
  - `WireSession.subagents: [WireSubagent]?` (nil = Mac does not model them), `WireSession.openPromptAgent: String?`.
  - `FleetEvent.activityChanged(id:activity:waitingFor:subagentCount:hasBackgroundWork:openPromptCall:answerless:subagents:openPromptAgent:)` — last two `= nil`.
  - `FleetRequest.timeline(session:anchor:limit:agent:)` with `agent: String? = nil`; `FleetCommand.answerPrompt(id:token:call:answer:agent:)` with `agent: String? = nil`. Swift enum cases accept default arguments for construction; every `case .timeline(let s, let a, let l)` pattern must add a fourth binding.
  - `extension WireSession { public var blockedSubagent: WireSubagent? }` — the node whose `id == openPromptAgent`.

- [ ] **Step 1: Write failing wire tests** in `FleetWireTests.swift`:

```swift
    func testWireSessionRoundTripsSubagentsAndTheirPromptAgent() throws {
        let tree = [WireSubagent(id: "a0aaaaaa", parent: nil, type: "general-purpose",
                                 description: "Controller", state: "running"),
                    WireSubagent(id: "a28ad87b", parent: "a0aaaaaa", type: "implementer",
                                 description: "Task 14", state: "blocked")]
        let s = WireSession(id: UUID(), title: "t", agent: "claude", activity: "waiting",
                            openPromptCall: .call("toolu_SUB"), subagents: tree,
                            openPromptAgent: "a28ad87b")
        let back = try roundTrip(s)
        XCTAssertEqual(back.subagents, tree)
        XCTAssertEqual(back.openPromptAgent, "a28ad87b")
        XCTAssertEqual(back.blockedSubagent?.type, "implementer")
    }

    func testAnOlderMacsSessionHasNoSubagentModel() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","title":"t","agent":"claude","subagentCount":2,"isUnread":false}"#.utf8)
        let s = try JSONDecoder().decode(WireSession.self, from: json)
        XCTAssertNil(s.subagents)
        XCTAssertNil(s.openPromptAgent)
    }

    func testActivityChangedCarriesSubagentsAndDecodesWithoutThem() throws {
        let tree = [WireSubagent(id: "a28ad87b", parent: nil, type: "implementer",
                                 description: "d", state: "blocked")]
        let event = FleetEvent.activityChanged(
            id: UUID(), activity: "waiting", waitingFor: "permission prompt", subagentCount: 1,
            hasBackgroundWork: false, openPromptCall: .call("toolu_SUB"), answerless: false,
            subagents: tree, openPromptAgent: "a28ad87b")
        XCTAssertEqual(try roundTrip(event), event)
        let old = Data(#"{"t":"session.activity","id":"\#(UUID().uuidString)","activity":"busy","subagentCount":0}"#.utf8)
        guard case .activityChanged(_, _, _, _, _, _, _, let subs, let agent) =
                try JSONDecoder().decode(FleetEvent.self, from: old) else { return XCTFail() }
        XCTAssertNil(subs); XCTAssertNil(agent)
    }
```

In `TimelineFrameCodingTests.swift`: round-trip `.req(cid: 7, .timeline(session: session, anchor: .latest, limit: 8, agent: "a28ad87b"))` and assert `fields(of:)["agent"] as? String == "a28ad87b"`; a request without agent has no `"agent"` key; same pair for `.cmd(cid: 3, .answerPrompt(id:token:call:answer: .allow, agent: "a28ad87b"))`.

In `FleetFieldEmissionTests.swift`: a store with `subagentTrees[tab]` set via `applySubagents` emits an `activityChanged` whose `subagents` maps the tree (`state` strings `"running"`/`"blocked"`/`"done"`), and the snapshot `WireSession.subagents` matches; with `openPromptAgents[tab] = "a28ad87b"` and `openPromptCalls[tab] = "toolu_SUB"`, that node's state is `"blocked"` and `openPromptAgent == "a28ad87b"`.

- [ ] **Step 2: Run to verify failure** — compile errors on the new parameters.

- [ ] **Step 3: Implement FleetKit.**
  - `WireSubagent.swift` with the struct above plus `extension WireSession { public var blockedSubagent: WireSubagent? { guard let a = openPromptAgent else { return nil }; return subagents?.first { $0.id == a } } }`.
  - `Wire.swift`: add `public var subagents: [WireSubagent]?` and `public var openPromptAgent: String?` to properties, init (defaults `nil`, last), `CodingKeys`, `encode` (`encodeIfPresent`), `init(from:)` (`decodeIfPresent`). The CodingKeys doc warns a member left out of the enum silently never reaches the wire — add both.
  - `FleetEvent.swift`: append `subagents: [WireSubagent]? = nil, openPromptAgent: String? = nil` to `activityChanged`; update `:104`, `:122` patterns.
  - `WireCoding.swift`: add `subagents, openPromptAgent` to `CodingKeys`; encode with `encodeIfPresent`; decode with `decodeIfPresent`.
  - `SnapshotApplication.swift:62`: bind both and assign `$0.subagents = subagents; $0.openPromptAgent = openPromptAgent` (overwritten unconditionally, same rule as `openPromptCall`).
  - `FleetReplay.swift:109`, and every other positional match: add two `_`.
  - `TimelineFrames.swift`: `case timeline(session: UUID, anchor: TimelineAnchor, limit: Int, agent: String? = nil)`; `CodingKeys` gains `agent`; encode `encodeIfPresent(agent, forKey: .agent)`; decode `decodeIfPresent`.
  - `Frames.swift`: `case answerPrompt(id: UUID, token: UUID, call: String, answer: PromptAnswer, agent: String? = nil)`; `CodingKeys` already has `agent` (used by session creation) — reuse it; encode `encodeIfPresent`; decode `decodeIfPresent`.
- [ ] **Step 4: Implement the Mac side.**
  - `FleetProjection.project(session...)`: new params `subagents: SubagentTree?` and `openPromptAgent: String?`; map with a helper:

    ```swift
    static func wire(_ tree: SubagentTree, blocked agent: String?, call: String?) -> [WireSubagent] {
        let marked = (agent != nil && call != nil) ? tree.marking(blocked: agent!, call: call!) : tree
        return marked.nodes.map { node in
            let state: String
            switch node.state {
            case .running: state = "running"
            case .blocked: state = "blocked"
            case .done: state = "done"
            }
            return WireSubagent(id: node.id, parent: node.parentID, type: node.type,
                                description: node.description, state: state)
        }
    }
    ```
    For a claude session pass `store.subagentTrees[$0.id] ?? .empty` (so `subagents` is `[]`, not nil, meaning "modelled, none"); for codex pass nil.
  - `SessionStore.emitActivity` and `applySubagentCount`: pass `subagents:` (same helper, from `subagentTrees`, `openPromptAgents`, `openPromptCalls`) and `openPromptAgent: openPromptAgents[id]`. `applySubagents` (Task 3) now emits `.activityChanged` with the current status fields, like `applySubagentCount` does, when `statuses[id]` exists.
  - `FleetService`: `.timeline(let session, let anchor, let limit, let agent)` → `timeline.page(session:agent:anchor:limit:)`; `.answerPrompt(let id, let token, let call, let answer, let agent)` → `prompts.answer(session: id, agent: agent, call:...)`.
- [ ] **Step 5: Run** `./scripts/test-unit.sh` (full: positional matches are everywhere) and `./scripts/build-ios.sh` (FleetKit compiles for iOS; the phone still compiles because it only pattern-matches through `SnapshotApplication`). Both clean.
- [ ] **Step 6: Commit** (all wire + handler sites together)

```bash
git add Sources/FleetKit Sources/FlightDeck/Fleet Sources/FlightDeck/SessionStore.swift \
  Sources/FlightDeckCLI Tests/FlightDeckTests
git commit -m "feat: put subagents and the blocked agent on the wire, and accept an agent on answers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
(Check `git status` first and add individual files if any listed directory holds another session's edits.)

---

### Task 7: Phone — tree, subagent card, caption

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift`
- Modify: `Sources/FlightDeckMobile/PromptCard.swift`
- Create: `Sources/FlightDeckMobile/SubagentTreeSection.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `Sources/FlightDeckMobile/SessionStatusGlyph.swift`
- Test: `Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift`, `Tests/FlightDeckMobileTests/PromptCardTests.swift`, `Tests/FlightDeckMobileTests/SessionStatusGlyphTests.swift`, `Tests/FlightDeckMobileTests/SubagentTreeSectionTests.swift`

**Interfaces:**
- Consumes: Task 6 `WireSession.subagents`, `openPromptAgent`, `blockedSubagent`, `FleetRequest.timeline(...agent:)`, `FleetCommand.answerPrompt(...agent:)`.
- Produces:
  - `SessionTimelineModel.updateStatus(agent:activity:call:promptAgent:)` (old 3-arg form forwards with `promptAgent: nil`).
  - `SessionTimelineModel.subagentPage: [TimelineItem]` (the blocked agent's tail); `blocked(...)` derives from it when `promptAgent` is set.
  - `PromptCard` new stored property `fromSubagent: WireSubagent?` and `static func origin(_ s: WireSubagent?) -> String?` returning `"From \(type) — \(description)"`.
  - `enum SubagentRows { static func visible(_ nodes: [WireSubagent], expanded: Set<String>) -> [(node: WireSubagent, depth: Int)]; static func autoExpanded(_ nodes: [WireSubagent]) -> Set<String> }`.
  - `SessionStatusGlyph` waiting label: `"Waiting for you — \(type): \(waitingFor)"` when `blockedSubagent` is set.

- [ ] **Step 1: Write failing tests.**
  - `SessionTimelineBlockedTests`:

    ```swift
    func testASubagentsDialogIsDerivedFromItsOwnPage() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([], session: model.sessionID)))
        model.updateStatus(agent: "claude", activity: "waiting", call: .call("toolu_SUB"),
                           promptAgent: "a28ad87b")
        guard case .timeline(_, .latest, _, let agent)? = stub.requests.last else {
            return XCTFail("expected a subagent page request, got \(stub.requests)")
        }
        XCTAssertEqual(agent, "a28ad87b")
        stub.answer(.success(page([permissionItem(callID: "toolu_SUB")], session: model.sessionID)))
        XCTAssertEqual(model.blockedPrompt?.callID, "toolu_SUB")
        model.answer(.allow, to: "toolu_SUB")
        guard case .answerPrompt(_, _, "toolu_SUB", .allow, let sentAgent)? = stub.sent else {
            return XCTFail("expected an answer naming the agent")
        }
        XCTAssertEqual(sentAgent, "a28ad87b")
    }

    func testTheMainFeedIsNotTreatedAsTheSubagentsPage() {
        let (model, stub) = makeModel()
        model.loadLatest()
        stub.answer(.success(page([permissionItem(callID: "toolu_MAIN")], session: model.sessionID)))
        model.updateStatus(agent: "claude", activity: "waiting", call: .call("toolu_SUB"),
                           promptAgent: "a28ad87b")
        XCTAssertNil(model.blockedPrompt, "the main feed's call is not the subagent's")
    }
    ```
    Add a `permissionItem(callID:)` helper next to `askItem` building a `.toolCall` `TimelineItem` (`tool: "Bash"`, `callID`, summary `"rm -rf x"`) — copy `askItem`'s construction and change `kind` and body.
  - `PromptCardTests`: `XCTAssertEqual(PromptCard.origin(WireSubagent(id: "a1", parent: nil, type: "implementer", description: "Task 14", state: "blocked")), "From implementer — Task 14")` and `XCTAssertNil(PromptCard.origin(nil))`.
  - `SessionStatusGlyphTests`: a waiting session with `waitingFor: "permission prompt"`, `subagents` containing a blocked implementer and `openPromptAgent` naming it labels `"Waiting for you — implementer: permission prompt"`; `waitingCaption` returns `"implementer: permission prompt"`.
  - `SubagentTreeSectionTests`: given controller `a0` (running) → implementer `a1` (blocked) and reviewer `a2` (running, parent `a0`), `autoExpanded` is `["a0"]`; `visible(nodes, expanded: [])` is `[a0]` at depth 0; `visible(nodes, expanded: ["a0"])` is `[a0 d0, a1 d1, a2 d1]`.
- [ ] **Step 2: Run** `./scripts/build-ios.sh && ./scripts/test-ios.sh` — expected failures/compile errors.
- [ ] **Step 3: Implement the model.** In `SessionTimelineModel`:
  - Add `@ObservationIgnored private var statusPromptAgent: String?` and `private(set) var subagentPage: [TimelineItem] = []`.
  - `func updateStatus(agent: String?, activity: String?, call: OpenPromptIdentity, promptAgent: String? = nil)`: include `promptAgent` in the unchanged-guard; on a change to a non-nil `promptAgent` (or a new `call` while it is set) call `fetchSubagentPage()`; when it becomes nil clear `subagentPage`; then `rebuild()`.
  - `fetchSubagentPage()`:

    ```swift
    /// The blocked agent's own tail. Not merged into `feed`: it is another file with its own
    /// offsets, and its records would read as the parent's conversation.
    private func fetchSubagentPage() {
        guard let agent = statusPromptAgent else { return }
        let requested = agent
        fleet.timelinePage(.timeline(session: sessionID, anchor: .latest,
                                     limit: TimelineLimits.defaultLimit, agent: agent)) { [weak self] result in
            guard let self, self.statusPromptAgent == requested else { return }
            if case .success(let page) = result { self.subagentPage = page.items }
            self.rebuild()
        }
    }
    ```
  - `blocked(agent:activity:call:)`: `let items = statusPromptAgent == nil ? feed.items : subagentPage` then `OpenPrompt.find(in: items, ...)`.
  - `answer(_:to:)`: send `.answerPrompt(id: sessionID, token: token, call: call, answer: answer, agent: statusPromptAgent)`.
  - Every other construction of `.timeline(` in the phone keeps working (default `agent: nil`); patterns over `FleetRequest` in test stubs that bind positions need a fourth `_`.
- [ ] **Step 4: Implement the views.**
  - `SubagentTreeSection.swift`:

    ```swift
    import FleetKit
    import SwiftUI

    /// Pure row decisions, testable without rendering.
    enum SubagentRows {
        /// Ancestors of a blocked agent start expanded, so the agent asking for you is visible.
        static func autoExpanded(_ nodes: [WireSubagent]) -> Set<String> {
            var open: Set<String> = []
            let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for node in nodes where node.state == "blocked" {
                var cursor = node.parent.flatMap { byID[$0] }
                while let current = cursor, !open.contains(current.id) {
                    open.insert(current.id)
                    cursor = current.parent.flatMap { byID[$0] }
                }
            }
            return open
        }

        static func visible(_ nodes: [WireSubagent], expanded: Set<String>)
            -> [(node: WireSubagent, depth: Int)] {
            var rows: [(WireSubagent, Int)] = []
            func walk(_ parent: String?, _ depth: Int) {
                for node in nodes where node.parent == parent {
                    rows.append((node, depth))
                    if expanded.contains(node.id) { walk(node.id, depth + 1) }
                }
            }
            walk(nil, 0)
            return rows
        }
    }

    struct SubagentTreeSection: View {
        let nodes: [WireSubagent]
        @State private var expanded: Set<String> = []
        @State private var seeded = false

        var body: some View {
            Section("Subagents") {
                ForEach(SubagentRows.visible(nodes, expanded: expanded), id: \.node.id) { row in
                    HStack(spacing: 6) {
                        if nodes.contains(where: { $0.parent == row.node.id }) {
                            Image(systemName: expanded.contains(row.node.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Circle().fill(color(row.node.state)).frame(width: 7, height: 7)
                        Text(row.node.type).font(.footnote.weight(.medium))
                        Text(row.node.description).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(row.node.id) }
                    .accessibilityLabel("\(row.node.type), \(row.node.description), \(row.node.state)")
                }
            }
            .onAppear { seed() }
            .onChange(of: nodes) { _, _ in seed() }
        }

        private func seed() { expanded.formUnion(SubagentRows.autoExpanded(nodes)) }
        private func toggle(_ id: String) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
        private func color(_ state: String) -> Color {
            switch state {
            case "blocked": return .orange
            case "done": return .secondary
            default: return .accentColor
            }
        }
    }
    ```
    (Remove the unused `seeded` if the compiler warns.)
  - `SessionTimelineScreen`: at the head of the `List`, `if let subs = session?.subagents, !subs.isEmpty { SubagentTreeSection(nodes: subs) }`. In `.task`, both `.onChange` handlers and a new `.onChange(of: session?.openPromptAgent)`, call `model.updateStatus(agent:activity:call:promptAgent: session?.openPromptAgent)`. Pass `fromSubagent: session?.blockedSubagent` to `PromptCard`. Read the `BlockedState` region (~:840-870) first; add `promptAgent` to `BlockedState` if it keys a `.task(id:)` on `(activity, openPromptCall)`.
  - `PromptCard`: add `let fromSubagent: WireSubagent?` (update `PromptCard(` call sites and `PromptCardTests` constructions), `static func origin(_ s: WireSubagent?) -> String? { s.map { "From \($0.type) — \($0.description)" } }`, and render it above the title as `.caption2.weight(.semibold)`, orange, like the question header.
  - `SessionStatusGlyph.baseLabel` `"waiting"` branch, after the `answerless` guard:

    ```swift
            if let sub = session.blockedSubagent, let waitingFor = session.waitingFor, !waitingFor.isEmpty {
                return "Waiting for you — \(sub.type): \(waitingFor)"
            }
    ```
    and `waitingCaption` returns `"\(sub.type): \(waitingFor)"` in that case. Task 8 makes the Mac's `SessionStatus.tooltip` say the identical string.
- [ ] **Step 5: Run** `./scripts/build-ios.sh && ./scripts/test-ios.sh` — PASS. Run `./scripts/test-unit.sh` too if any FleetKit file changed.
- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeckMobile Tests/FlightDeckMobileTests
git commit -m "feat: show a session's subagents on the phone and answer the one asking for you

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Mac — tooltip parity and the subagent popover

**Files:**
- Modify: `Sources/FlightDeck/SessionStatus.swift` (`blockedSubagentType: String?`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (set it in `commitStatuses` from `openPromptAgents` + `subagentTrees`)
- Modify: `Sources/FlightDeck/SessionStatusIcon.swift` (`SubagentCount` popover)
- Modify: `Sources/FlightDeck/SessionSidebar.swift:197` (pass the tree)
- Test: `Tests/FlightDeckTests/SessionStatusTests.swift`, `Tests/FlightDeckTests/SubagentTreeTests.swift`

**Interfaces:**
- Consumes: Task 3 `subagentTree(for:)`, Task 5 `openPromptAgents`, Task 2 `SubagentTree`.
- Produces: `SessionStatus.blockedSubagentType: String?`; `SubagentCount(status:tree:)`; `enum SubagentOutline { static func rows(_ tree: SubagentTree) -> [(node: SubagentNode, depth: Int)] }` (all rows, depth-first, for the popover).

- [ ] **Step 1: Failing tests.** `SessionStatusTests`:

```swift
    func testABlockedSubagentNamesItsTypeInTheWaitingTooltip() {
        var s = SessionStatus(activity: .waiting, waitingFor: "permission prompt")
        s.blockedSubagentType = "implementer"
        XCTAssertEqual(s.tooltip, "Waiting for you — implementer: permission prompt")
    }
```
`SubagentTreeTests`: `SubagentOutline.rows` of controller→(implementer, reviewer) is `[a0 d0, a1 d1, a2 d1]`.
- [ ] **Step 2: Run** `FD_TEST_FILTER=SessionStatusTests,SubagentTreeTests ./scripts/test-unit.sh` — FAIL.
- [ ] **Step 3: Implement.**
  - `SessionStatus`: `var blockedSubagentType: String? = nil` (keep `init` signature; default it). In `tooltip`'s `.waiting` branch after the `answerless` guard:

    ```swift
            if let blockedSubagentType, let waitingFor, !waitingFor.isEmpty {
                return "Waiting for you — \(blockedSubagentType): \(waitingFor)"
            }
    ```
  - `SessionStore.commitStatuses`: after `derivedOpenPromptCalls`, set `next[id]?.blockedSubagentType = openPromptAgents[id].flatMap { subagentTrees[id]?.node($0)?.type }` for waiting ids (nil otherwise) before the second `statuses` assignment.
  - `SubagentOutline.rows` in `SubagentTree.swift` (depth-first by `parentID`, same walk as the phone's `visible` with everything expanded).
  - `SubagentCount`: take `tree: SubagentTree`; wrap the count `Text` in a `Button` (plain style) toggling `@State var showing`, with `.popover(isPresented: $showing)` listing `SubagentOutline.rows(tree)`: indent `depth * 12`, an SF symbol per state (`circle.fill` tinted for running, `exclamationmark.circle.fill` orange for blocked, `checkmark.circle` secondary for done), type in medium weight, description secondary, `.frame(minWidth: 260)`. Keep `.help(status.tooltip)`.
  - `SessionSidebar.swift:197`: `SubagentCount(status: store.status(for: session.id), tree: store.subagentTree(for: session.id))`.
- [ ] **Step 4: Run** `FD_TEST_FILTER=SessionStatusTests,SubagentTreeTests,SessionStoreAnswerlessTests ./scripts/test-unit.sh`, then `./scripts/test-unit.sh` and `./scripts/build.sh` — clean.
- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStatus.swift Sources/FlightDeck/SessionStore.swift \
  Sources/FlightDeck/SessionStatusIcon.swift Sources/FlightDeck/SessionSidebar.swift \
  Sources/FlightDeck/Agents/SubagentTree.swift Tests/FlightDeckTests/SessionStatusTests.swift \
  Tests/FlightDeckTests/SubagentTreeTests.swift
git commit -m "feat: name the blocked subagent in the Mac tooltip and list subagents from the count

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Docs and final verification

**Files:**
- Modify: `docs/ARCHITECTURE.md` (subagent section ~:529-543), `docs/FOLLOWUPS.md` (2026-10-05 "Open-prompt probe CPU" → close the "cannot be answered from the phone" bullet; add any new limitation found), `docs/MOBILE.md` (manual checklist: subagent card + tree)

- [ ] **Step 1: ARCHITECTURE.md** — replace the count-only description with: the tree's source (`subagents/` files, `SubagentWatcher` polling policy), count = max(fold, tree), attribution (record-only `PermissionRequest` → `DialogAttribution` → `PromptService` confirmation against the subagent's file), the wire fields, and the rule that the phone derives the card from `timeline.page(agent:)`.
- [ ] **Step 2: FOLLOWUPS.md** — mark the 2026-10-05 phone-answer gap fixed with the commit range; keep `subagent_prompt` documented as the no-hook fallback; record anything Task 1 found that is still open.
- [ ] **Step 3: MOBILE.md** — add a manual check: "A background subagent hits a Bash permission dialog → the session's Subagents section expands to it (orange), the card reads 'From <type> — <description>', Allow from the phone resolves it and the card goes."
- [ ] **Step 4: Verify everything** — `./scripts/test-unit.sh` (grep the log for ` error: `), `./scripts/build-ios.sh`, `./scripts/test-ios.sh`, `./scripts/build.sh`. All clean.
- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md docs/FOLLOWUPS.md docs/MOBILE.md
git commit -m "docs: describe subagents as modelled children and close the phone-answer gap

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
