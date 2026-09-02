# Plan Review on the Phone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an open `ExitPlanMode` gate visible on the phone, readable as rendered markdown, annotatable by tapping a block, and resolvable with Approve or Request changes.

**Architecture:** The Mac discovers a live gate by reading Plannotator's own session registry (`~/.plannotator/sessions/*.json`) and attributing it to a Flight Deck tab by parent pid. It then speaks Plannotator's local HTTP API on the tab's behalf. The phone never talks to Plannotator; it receives a `planGate` on the session snapshot and sends two commands back. Block splitting lives in `FleetKit` so both ends compute identical annotation anchors.

**Tech Stack:** Swift 6, XCTest, `URLSession`, MarkdownUI (already vendored), xcodegen.

**Spec:** `docs/superpowers/specs/2026-08-29-plan-review-on-the-phone-design.md`

## Global Constraints

- **Swift 6 concurrency.** `FleetKit` types crossing actors are `Sendable`. UI types are `@MainActor`.
- **`FleetKit` holds every rule both ends run.** `PlanBlocks` goes there for the reason `OpenPrompt` is there: two implementations of one rule is how a comment detaches from the phrase it was written about.
- **Fixtures are captures.** Follow the existing `*.captured.*` convention. The capture for this feature is already taken and lives at
  `/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/46cb64be-7462-447c-a7a1-b021acf6c66c/scratchpad/plan-gate.captured.json`
  (a real `GET /api/plan` response, 7,002 bytes, plan body 6,342 chars, taken 2026-08-29 from `plannotator` pid 18418 port 54232). Task 1 moves it into the repo. **If it is gone, re-capture from a live gate — do not hand-write one.**
- **Nothing on this path becomes a keystroke.** The verdict is a two-value enum and annotations are content. No screen parsing, no injector, no interlock.
- **Never publish Plannotator's API beyond loopback.** It is unauthenticated by design. The Mac is the only client.
- **Build:** `scripts/build.sh`. **Test:** `scripts/test-unit.sh` (runs the whole bundle; it takes no filter argument). To run one class while iterating, use the bundle directly as that script does:
  ```bash
  scripts/test-unit.sh 2>&1 | tail -30
  ```
- **Do not run `scripts/smoke.sh` in a loop** — it steals focus for ~40s per run.
- **This checkout is shared.** Other sessions edit it concurrently. Never `git stash`, never revert another branch's work, and stage only the paths a task names.

---

### Task 1: `PlanBlocks` — the shared splitting rule

The one rule both ends run. The phone decides what to draw a tap target around; the Mac decides what `originalText` to POST. If they disagree, a comment silently pins to the wrong phrase or to nothing.

Measured over **120 archived plans** in `~/.plannotator/plans/` (6,442 blocks): thematic breaks 229, non-unique after that 109 (**1.7%**), **tappable 94.8%**, median target 77 chars. The rule below is what produced those numbers.

**Files:**
- Create: `Sources/FleetKit/PlanBlocks.swift`
- Create: `Tests/FlightDeckTests/PlanBlocksTests.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Plannotator/plan-gate.captured.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `PlanBlocks.split(_ plan: String) -> PlanBlocks`; `PlanBlocks.blocks: [PlanBlocks.Block]`; `Block.index: Int`, `Block.text: String`, `Block.isTarget: Bool`; `PlanBlocks.block(at: Int) -> Block?`.

- [ ] **Step 1: Install the captured fixture**

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck
mkdir -p Tests/FlightDeckTests/Fixtures/Plannotator
cp "/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/46cb64be-7462-447c-a7a1-b021acf6c66c/scratchpad/plan-gate.captured.json" \
   Tests/FlightDeckTests/Fixtures/Plannotator/plan-gate.captured.json
python3 -c "import json;d=json.load(open('Tests/FlightDeckTests/Fixtures/Plannotator/plan-gate.captured.json'));print('plan chars:',len(d['plan']));print('keys:',sorted(d.keys()))"
```

Expected: `plan chars: 6342` and keys including `plan`, `origin`, `permissionMode`, `previousPlan`, `versionInfo`, `projectRoot`. `Fixtures` is a folder reference in `project.yml`, so no project change is needed.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import FleetKit

/// The splitting rule, run over a real plan.
///
/// **The fixture is a capture**, per the `*.captured.*` convention: it is the verbatim
/// `GET /api/plan` response from `plannotator` pid 18418 on 2026-08-29, taken while the gate
/// was open. A plan authored by whoever wrote the splitter agrees with the splitter by
/// construction and proves nothing.
final class PlanBlocksTests: XCTestCase {

    private func capturedPlan() throws -> String {
        let url = try XCTUnwrap(Bundle(for: PlanBlocksTests.self).url(
            forResource: "plan-gate.captured", withExtension: "json",
            subdirectory: "Fixtures/Plannotator"
        ), "Fixtures/Plannotator/plan-gate.captured.json not found in the test bundle")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(root["plan"] as? String)
    }

    /// **The property the whole feature rests on.** Plannotator pins a comment by matching
    /// `originalText` as a verbatim substring of the plan. A block that is not one cannot be
    /// pinned, and the comment would silently fall back to sidebar-only.
    func testEveryBlockIsAVerbatimSubstringOfThePlan() throws {
        let plan = try capturedPlan()
        for block in PlanBlocks.split(plan).blocks {
            XCTAssertTrue(plan.contains(block.text),
                          "block \(block.index) is not a substring: \(block.text.prefix(60))")
        }
    }

    /// A target must occur exactly once, or the highlight lands on whichever copy the
    /// matcher happened to reach first.
    func testEveryTargetOccursExactlyOnce() throws {
        let plan = try capturedPlan()
        for block in PlanBlocks.split(plan).blocks where block.isTarget {
            XCTAssertEqual(PlanBlocks.occurrences(of: block.text, in: plan, stoppingAt: 2), 1,
                           "target \(block.index) is ambiguous: \(block.text.prefix(60))")
        }
    }

    /// The measured shape of this exact capture. Pins the rule against drift.
    func testCapturedPlanSplitsIntoTheMeasuredShape() throws {
        let plan = try capturedPlan()
        let split = PlanBlocks.split(plan)
        XCTAssertEqual(plan.count, 6342)
        XCTAssertEqual(split.blocks.count, 39)
        XCTAssertEqual(split.blocks.filter(\.isTarget).count, 38)
        XCTAssertEqual(split.blocks.first?.text, "# Surface Failure and Respawn — Plan 1 of 2")
    }

    /// A fence's own blank lines are not block separators. Splitting inside one would produce
    /// two halves of a code block, neither of which reads as code.
    func testFencedCodeSurvivesItsBlankLines() {
        let plan = """
        Intro paragraph.

        ```swift
        let a = 1

        let b = 2
        ```

        Outro paragraph.
        """
        let blocks = PlanBlocks.split(plan).blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[1].text.contains("let a = 1"))
        XCTAssertTrue(blocks[1].text.contains("let b = 2"))
    }

    /// List items split individually. Measured better on real plans than keeping a list whole:
    /// 4.9% non-unique versus 6.5%, at finer granularity.
    func testListItemsAreSeparateBlocks() {
        let plan = """
        Preamble here.

        - first item
        - second item
        - third item
        """
        let blocks = PlanBlocks.split(plan).blocks
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[1].text, "- first item")
        XCTAssertEqual(blocks[3].text, "- third item")
    }

    /// 229 of 6,442 blocks across 120 real plans were thematic breaks. There is no prose on
    /// one to comment about, and `---` is the single most common non-unique block by far.
    func testThematicBreakIsNeverATarget() {
        let plan = "One paragraph.\n\n---\n\nAnother paragraph.\n\n---\n\nA third."
        let blocks = PlanBlocks.split(plan).blocks
        for block in blocks where block.text.trimmingCharacters(in: .whitespaces) == "---" {
            XCTAssertFalse(block.isTarget)
        }
        XCTAssertEqual(blocks.filter(\.isTarget).count, 3)
    }

    /// A repeated block is refused rather than pinned to an arbitrary copy — the same
    /// "refuse rather than improvise" ruling `AnswerPlan.plan(for:answers:)` makes.
    func testARepeatedBlockIsNotATarget() {
        let plan = "**Assertions:**\n\nSomething unique.\n\n**Assertions:**\n\nSomething else."
        let blocks = PlanBlocks.split(plan).blocks
        let repeated = blocks.filter { $0.text == "**Assertions:**" }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated.allSatisfy { !$0.isTarget })
        XCTAssertEqual(blocks.filter(\.isTarget).count, 2)
    }

    /// Index lookup is bounds-checked, because it is reached from a wire command.
    func testBlockAtIndexRefusesOutOfRange() {
        let split = PlanBlocks.split("Only one block.")
        XCTAssertEqual(split.block(at: 0)?.text, "Only one block.")
        XCTAssertNil(split.block(at: 1))
        XCTAssertNil(split.block(at: -1))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PlanBlocks' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

/// A plan, split into the units a reader can pin a comment to.
///
/// **In `FleetKit` for `OpenPrompt`'s reason.** The phone decides what to draw a tap target
/// around and the Mac decides what `originalText` to POST to Plannotator. Two implementations
/// of this rule is how a comment detaches from the phrase it was written about — silently,
/// because Plannotator falls back to sidebar-only when a substring does not match.
///
/// **The rule was measured, not chosen.** Over 120 archived plans in `~/.plannotator/plans/`
/// (6,442 blocks): 229 thematic breaks, 109 further non-unique blocks (1.7%), leaving 94.8%
/// tappable at a median of 77 characters. Splitting list items individually beat keeping a
/// list whole on both axes — 4.9% non-unique against 6.5%, at finer granularity — which is why
/// the list rule is here despite adding a case.
public struct PlanBlocks: Equatable, Sendable {

    /// One annotatable unit.
    ///
    /// `text` is **verbatim source**, never trimmed or re-wrapped: Plannotator matches it as a
    /// substring of the plan, so any normalisation here is a comment that does not pin.
    public struct Block: Equatable, Sendable {
        public let index: Int
        public let text: String
        /// Whether a comment may be pinned here. A non-target still renders — it just takes no
        /// tap, and anything a reader wants to say about it goes in a global comment.
        public let isTarget: Bool

        public init(index: Int, text: String, isTarget: Bool) {
            self.index = index
            self.text = text
            self.isTarget = isTarget
        }
    }

    public let blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// Bounds-checked, because the caller is a wire command. A phone naming a block this plan
    /// does not have is refused, not clamped.
    public func block(at index: Int) -> Block? {
        guard blocks.indices.contains(index) else { return nil }
        return blocks[index]
    }

    public static func split(_ plan: String) -> PlanBlocks {
        var raw: [String] = []
        var current: [String] = []
        var inFence = false

        func flush() {
            guard !current.isEmpty else { return }
            raw.append(current.joined(separator: "\n"))
            current.removeAll()
        }

        let lines = plan
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            // A fence's own blank lines are not separators, and the closing fence ends the
            // block — otherwise the prose after it joins the code.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                current.append(line)
                if !inFence { flush() }
                continue
            }
            if inFence { current.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if isListItem(line) { flush(); current.append(line); continue }
            current.append(line)
        }
        flush()

        let blocks = raw.enumerated().map { index, text in
            Block(
                index: index,
                text: text,
                isTarget: !isThematicBreak(text)
                    && occurrences(of: text, in: plan, stoppingAt: 2) == 1
            )
        }
        return PlanBlocks(blocks: blocks)
    }

    /// Counts occurrences, stopping once `limit` is reached.
    ///
    /// The early stop is the point: every caller only asks "exactly one, or more than one?",
    /// and a full count over a 6 KB plan for each of 39 blocks would be work done to be
    /// thrown away.
    static func occurrences(of needle: String, in haystack: String, stoppingAt limit: Int) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            if count >= limit { return count }
            searchStart = found.lowerBound < found.upperBound
                ? found.upperBound
                : haystack.index(after: found.lowerBound)
        }
        return count
    }

    /// `- `, `* `, `+ `, `1. `, `1) ` — the marker must be followed by a space, so `---` is a
    /// thematic break and not a list item with an empty label.
    static func isListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return rest.dropFirst().first == " "
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        rest = rest.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// Three or more of one of `-`, `*`, `_`, and nothing else.
    static func isThematicBreak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_"
        else { return false }
        return trimmed.allSatisfy { $0 == first }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all eight `PlanBlocksTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/PlanBlocks.swift \
        Tests/FlightDeckTests/PlanBlocksTests.swift \
        Tests/FlightDeckTests/Fixtures/Plannotator/plan-gate.captured.json
git commit -m "feat: split a plan into the blocks a comment can pin to"
```

---

### Task 2: `PlannotatorRegistry` — find the live gate

Discovery reads Plannotator's own registry rather than installing a competing hook. The 2026-08-18 mobile companion spec (§9) flagged the cost of the alternative: registering a hook "writes to claude's settings, which is a side effect on the user's environment." Two `PermissionRequest` hooks on one matcher is also a decision race.

**Files:**
- Create: `Sources/FlightDeck/Fleet/PlannotatorRegistry.swift`
- Create: `Tests/FlightDeckTests/PlannotatorRegistryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PlannotatorRegistry.Entry` with `pid: pid_t`, `port: Int`, `url: String`, `mode: String`, `project: String`, `startedAt: String`; `PlannotatorRegistry.decode(_ data: Data) -> Entry?`; `PlannotatorRegistry.planGates(in: URL, isAlive: (pid_t) -> Bool, parentOf: (pid_t) -> pid_t?) -> [pid_t: Entry]` keyed by **owning `claude` pid**.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

/// Reading Plannotator's session registry.
///
/// The shape is undocumented and unversioned, so every rule fails closed — the same discipline
/// `ClaudeStatusFile` applies to claude's registry, and for the same reason: a guess here
/// attaches a plan gate to the wrong tab.
final class PlannotatorRegistryTests: XCTestCase {

    /// Verbatim from `~/.plannotator/sessions/18418.json`, captured 2026-08-29 while the gate
    /// was open. Hand-editing this defeats the point of having captured it.
    private let captured = Data("""
    {"pid":18418,"port":54232,"url":"http://localhost:54232","mode":"plan",\
    "project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z","label":"plan-flight-deck"}
    """.utf8)

    func testDecodesTheCapturedEntry() throws {
        let entry = try XCTUnwrap(PlannotatorRegistry.decode(captured))
        XCTAssertEqual(entry.pid, 18418)
        XCTAssertEqual(entry.port, 54232)
        XCTAssertEqual(entry.mode, "plan")
        XCTAssertEqual(entry.project, "flight-deck")
    }

    func testRefusesAnEntryMissingAField() {
        XCTAssertNil(PlannotatorRegistry.decode(Data(#"{"pid":1,"mode":"plan"}"#.utf8)))
        XCTAssertNil(PlannotatorRegistry.decode(Data("not json".utf8)))
    }

    /// A `review` or `annotate` server is a real Plannotator session and is not a plan gate.
    /// Treating one as a gate would offer Approve for a document no agent is blocked on.
    func testKeepsOnlyPlanMode() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan"),
            "2.json": entryJSON(pid: 2, mode: "review"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { $0 + 100 }
        )
        XCTAssertEqual(Set(gates.keys), [101])
    }

    /// A crashed hook leaves its file behind. A dead pid is not a gate — the phone would draw
    /// an Approve button wired to nothing.
    func testDropsDeadProcesses() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan"),
            "2.json": entryJSON(pid: 2, mode: "plan"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { $0 == 1 }, parentOf: { $0 + 100 }
        )
        XCTAssertEqual(Set(gates.keys), [101])
    }

    /// **Attribution is by parent pid, never by `project` or `cwd`.** This checkout runs many
    /// sessions from one directory; two gates that share a project name belong to different
    /// tabs and must not collapse into one.
    func testTwoGatesInOneProjectAttributeToDifferentSessions() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan", project: "flight-deck"),
            "2.json": entryJSON(pid: 2, mode: "plan", project: "flight-deck"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { $0 == 1 ? 900 : 901 }
        )
        XCTAssertEqual(Set(gates.keys), [900, 901])
        XCTAssertEqual(gates[900]?.port, 1 + 50000)
        XCTAssertEqual(gates[901]?.port, 2 + 50000)
    }

    /// An orphaned hook whose parent has gone belongs to no tab.
    func testDropsAnEntryWithNoResolvableParent() throws {
        let dir = try makeRegistry(["1.json": entryJSON(pid: 1, mode: "plan")])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { _ in nil }
        )
        XCTAssertTrue(gates.isEmpty)
    }

    // MARK: Helpers

    private func entryJSON(pid: Int, mode: String, project: String = "p") -> String {
        """
        {"pid":\(pid),"port":\(pid + 50000),"url":"http://localhost:\(pid + 50000)",\
        "mode":"\(mode)","project":"\(project)","startedAt":"2026-08-29T17:40:36.186Z",\
        "label":"\(mode)-\(project)"}
        """
    }

    private func makeRegistry(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PlannotatorRegistry' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Plannotator's own session registry, read rather than replaced.
///
/// Plannotator writes `~/.plannotator/sessions/<pid>.json` for every server it starts and
/// removes it on exit. A gate is therefore discoverable with a directory read and no side
/// effects — no hook of ours in the user's `settings.json`, and no second
/// `PermissionRequest` handler racing Plannotator's for the decision.
///
/// The format is undocumented and unversioned. Every rule fails closed, exactly as
/// `ClaudeStatusFile`'s do: anything unrecognised yields nil and the caller sees no gate,
/// which is the safe direction — a missing gate is invisible, an invented one offers Approve
/// for a session nothing is blocking.
enum PlannotatorRegistry {

    struct Entry: Equatable {
        /// `plannotator`'s pid, not `claude`'s.
        let pid: pid_t
        let port: Int
        let url: String
        /// `"plan"`, `"review"`, `"annotate"`, `"archive"`. Only `"plan"` is a gate.
        let mode: String
        let project: String
        let startedAt: String
    }

    static func decode(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let pid = root["pid"] as? Int,
              let port = root["port"] as? Int,
              let url = root["url"] as? String,
              let mode = root["mode"] as? String,
              let project = root["project"] as? String,
              let startedAt = root["startedAt"] as? String
        else { return nil }
        return Entry(pid: pid_t(pid), port: port, url: url,
                     mode: mode, project: project, startedAt: startedAt)
    }

    /// Every live plan gate in `directory`, keyed by the **`claude` pid that owns it**.
    ///
    /// **Attribution is by parent pid and nothing else.** `plannotator` is spawned by the
    /// `claude` process whose `ExitPlanMode` call it is gating (verified: 18418 → 66955 →
    /// `claude`), and `SessionStore` already keys tabs by that pid through
    /// `ClaudeStatusFile.Entry.pid`. Matching on `project` or `cwd` instead would collapse two
    /// gates in this shared checkout onto one tab.
    ///
    /// `isAlive` and `parentOf` are injected for the reason `PromptService.tail` is: the
    /// process table is the thing a test must substitute, and passing functions keeps this
    /// enum free of both a store and a `FileManager` policy.
    static func planGates(
        in directory: URL,
        isAlive: (pid_t) -> Bool,
        parentOf: (pid_t) -> pid_t?
    ) -> [pid_t: Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var gates: [pid_t: Entry] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let entry = decode(data),
                  entry.mode == "plan",
                  isAlive(entry.pid),
                  let owner = parentOf(entry.pid)
            else { continue }
            gates[owner] = entry
        }
        return gates
    }

    /// The default registry location.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".plannotator/sessions", isDirectory: true)
    }

    /// `kill(pid, 0)` succeeds for a live process we may signal, and sets `EPERM` for one we
    /// may not — which is still alive. Only `ESRCH` means gone.
    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The parent pid, via `sysctl`. `ps` would be a subprocess per poll.
    static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all six `PlannotatorRegistryTests` cases.

- [ ] **Step 5: Verify parent-pid resolution against the real process table**

```bash
cat > /tmp/ppid-check.swift <<'SWIFT'
import Foundation
func parent(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}
print(parent(of: pid_t(CommandLine.arguments[1])!) ?? -1)
SWIFT
swift /tmp/ppid-check.swift $$ ; echo "shell's real parent: $(ps -o ppid= -p $$ | tr -d ' ')"
```

Expected: the two numbers match. If `sysctl` returns nothing, fall back to `parentOf` reading `ps -o ppid= -p <pid>` and note the cost in a comment — but prefer `sysctl`, since this runs on a poll.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/PlannotatorRegistry.swift \
        Tests/FlightDeckTests/PlannotatorRegistryTests.swift
git commit -m "feat: find a live plan gate in plannotator's session registry"
```

---

### Task 3: `PlanGateClient` — speak Plannotator's API

The contract was read off the `plannotator` binary and confirmed against a running server. **One thing was not verified and this task must settle it:** the response body of `POST /api/external-annotations`. Spec §7 says the phone must not claim a pin it cannot confirm until that shape is known.

**Files:**
- Create: `Sources/FlightDeck/Fleet/PlanGateClient.swift`
- Create: `Tests/FlightDeckTests/PlanGateClientTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PlanGateClient(port: Int, transport: PlanGateClient.Transport)`; `func plan() async -> String?`; `func annotate(text: String, originalText: String?) async -> Bool`; `func resolve(approved: Bool, feedback: String?) async -> Bool`; `typealias Transport = @Sendable (URLRequest) async -> (Data, Int)?` where the `Int` is the HTTP status.

- [ ] **Step 1: Settle the unverified response shape**

Start a throwaway gate and POST one annotation to it. **Do not use a gate another session is waiting on** — start your own:

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck
printf '# Throwaway\n\nA paragraph to pin a comment to.\n' > /tmp/throwaway-plan.md
PLANNOTATOR_SKIP_BROWSER_OPEN=1 plannotator annotate /tmp/throwaway-plan.md --gate --json &
sleep 3
PORT=$(python3 -c "
import glob,json
for f in glob.glob('$HOME/.plannotator/sessions/*.json'):
    d=json.load(open(f))
    if d.get('project')!='flight-deck' or d.get('mode')!='plan': print(d['port'])
" | tail -1)
echo "port: $PORT"
curl -s -i -X POST "http://127.0.0.1:$PORT/api/external-annotations" \
  -H 'Content-Type: application/json' \
  -d '{"source":"flight-deck","type":"COMMENT","text":"note","originalText":"A paragraph to pin a comment to."}' | head -20
curl -s "http://127.0.0.1:$PORT/api/external-annotations" | head -c 500
```

Record the status code and body in a comment on `annotate(text:originalText:)`. Then kill the throwaway server (`kill %1`). **If the body does not report whether the substring matched, `annotate` returns "sent" and the phone must say "sent", never "pinned"** — which is what spec §7 requires.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

/// The Plannotator HTTP contract, against a recorded transport.
///
/// A double rather than a live gate: a test that needs a four-day hook running is a test that
/// does not run. The shapes encoded here were read off the `plannotator` binary and confirmed
/// against a live server on 2026-08-29.
final class PlanGateClientTests: XCTestCase {

    private actor Recorder {
        var requests: [URLRequest] = []
        var responses: [(Data, Int)] = []
        func push(_ response: (Data, Int)) { responses.append(response) }
        func record(_ request: URLRequest) -> (Data, Int)? {
            requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        func all() -> [URLRequest] { requests }
    }

    private func client(_ recorder: Recorder) -> PlanGateClient {
        PlanGateClient(port: 54232, transport: { request in await recorder.record(request) })
    }

    func testPlanReadsTheBodyField() async throws {
        let recorder = Recorder()
        await recorder.push((Data(#"{"plan":"# Title\n\nBody."}"#.utf8), 200))
        let plan = await client(recorder).plan()
        XCTAssertEqual(plan, "# Title\n\nBody.")
        let request = try XCTUnwrap(await recorder.all().first)
        XCTAssertEqual(request.url?.path, "/api/plan")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
    }

    /// Loopback, always. The API is unauthenticated; a hostname that could resolve off-machine
    /// would be a way to reach someone else's gate.
    func testEveryRequestGoesToLoopback() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        await recorder.push((Data("{}".utf8), 200))
        _ = await client(recorder).annotate(text: "n", originalText: "phrase")
        _ = await client(recorder).resolve(approved: true, feedback: nil)
        for request in await recorder.all() {
            XCTAssertEqual(request.url?.host, "127.0.0.1")
        }
    }

    func testAnnotatePostsAnInlineComment() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        let ok = await client(recorder).annotate(text: "needs a rollback",
                                                 originalText: "open the file")
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(await recorder.all().first)
        XCTAssertEqual(request.url?.path, "/api/external-annotations")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "COMMENT")
        XCTAssertEqual(json["source"] as? String, "flight-deck")
        XCTAssertEqual(json["text"] as? String, "needs a rollback")
        XCTAssertEqual(json["originalText"] as? String, "open the file")
    }

    /// A comment with no anchor is a `GLOBAL_COMMENT` and must carry no `originalText` —
    /// an empty string would be matched as a substring and pin to the first character.
    func testAnnotateWithoutAnAnchorIsGlobal() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        _ = await client(recorder).annotate(text: "missing a rollback section",
                                            originalText: nil)
        let request = try XCTUnwrap(await recorder.all().first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "GLOBAL_COMMENT")
        XCTAssertNil(json["originalText"])
    }

    func testResolveApproveHitsApproveWithFeedback() async throws {
        let recorder = Recorder()
        await recorder.push((Data(#"{"ok":true}"#.utf8), 200))
        let ok = await client(recorder).resolve(approved: true, feedback: "ship it, but rename X")
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(await recorder.all().first)
        XCTAssertEqual(request.url?.path, "/api/approve")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["feedback"] as? String, "ship it, but rename X")
    }

    func testResolveDenyHitsDeny() async throws {
        let recorder = Recorder()
        await recorder.push((Data(#"{"ok":true}"#.utf8), 200))
        _ = await client(recorder).resolve(approved: false, feedback: "step 3 is wrong")
        let request = try XCTUnwrap(await recorder.all().first)
        XCTAssertEqual(request.url?.path, "/api/deny")
    }

    /// A gate that closed between the tap and the request. The transport returns nothing;
    /// the caller must learn that, not read `false` as "the server said no".
    func testATransportFailureIsNotSuccess() async {
        let recorder = Recorder()   // no queued response
        let ok = await client(recorder).resolve(approved: true, feedback: nil)
        XCTAssertFalse(ok)
    }

    func testANon2xxIsNotSuccess() async {
        let recorder = Recorder()
        await recorder.push((Data("gone".utf8), 404))
        let ok = await client(recorder).resolve(approved: true, feedback: nil)
        XCTAssertFalse(ok)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PlanGateClient' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

/// Flight Deck's client for one Plannotator plan gate.
///
/// **Loopback only, and that is a security property rather than a default.** Plannotator's API
/// is unauthenticated by design — its own generated docs say so — which is safe exactly as
/// long as the only thing that can reach it is a process on this machine. The Mac is that
/// process; the phone talks to the Mac. Nothing here takes a host.
///
/// The contract was read off the `plannotator` binary (v0.27.8) and confirmed against a
/// running server on 2026-08-29:
///
/// - `GET  /api/plan` → `{plan, origin, permissionMode, previousPlan, versionInfo, …}`
/// - `POST /api/external-annotations` → `{source, type, text, originalText}`
/// - `POST /api/approve` → `{feedback?}`, resolves the hook `allow`
/// - `POST /api/deny`    → `{feedback}`,  resolves it `deny`, feedback becomes the reason
struct PlanGateClient {
    /// Test seam, in the shape `PromptService.tail` is one: the network is the thing a test
    /// must substitute. The `Int` is the HTTP status; `nil` is a transport failure, which is
    /// a different fact from a server that answered badly.
    typealias Transport = @Sendable (URLRequest) async -> (Data, Int)?

    let port: Int
    let transport: Transport

    /// The `source` every annotation carries, so `DELETE ?source=flight-deck` can retract
    /// exactly what this Mac posted and nothing a person typed in the browser.
    static let source = "flight-deck"

    init(port: Int, transport: @escaping Transport = PlanGateClient.urlSession) {
        self.port = port
        self.transport = transport
    }

    static let urlSession: Transport = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Bool {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, status) = await transport(request) else { return false }
        return (200..<300).contains(status)
    }

    func plan() async -> String? {
        var request = URLRequest(url: url("/api/plan"))
        request.httpMethod = "GET"
        guard let (data, status) = await transport(request), (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["plan"] as? String
    }

    /// Post one comment.
    ///
    /// **The return value means "sent", never "pinned".** Plannotator matches `originalText`
    /// as a substring and falls back to sidebar-only when it does not match — silently, and
    /// the POST succeeds either way. `PlanBlocks` guarantees a verbatim unique substring so
    /// this should not arise; the phone still says "sent", because claiming a pin this call
    /// cannot confirm would be a lie the reader has no way to check. See Step 1 for the
    /// response shape actually observed.
    func annotate(text: String, originalText: String?) async -> Bool {
        var body: [String: Any] = [
            "source": Self.source,
            "text": text,
            "type": originalText == nil ? "GLOBAL_COMMENT" : "COMMENT",
        ]
        // Absent rather than empty: an empty string is a substring of everything and would
        // pin the comment to the first character of the plan.
        if let originalText { body["originalText"] = originalText }
        return await post("/api/external-annotations", body)
    }

    /// Resolve the gate. **Approve carries feedback too** — reading a plan, marking it up and
    /// saying yes anyway is a first-class outcome, not a workaround.
    func resolve(approved: Bool, feedback: String?) async -> Bool {
        var body: [String: Any] = [:]
        if let feedback, !feedback.isEmpty { body["feedback"] = feedback }
        return await post(approved ? "/api/approve" : "/api/deny", body)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all eight `PlanGateClientTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/PlanGateClient.swift \
        Tests/FlightDeckTests/PlanGateClientTests.swift
git commit -m "feat: drive a plannotator plan gate over its local API"
```

---

### Task 4: Wire types — `planGate` northbound, two commands southbound

**Files:**
- Modify: `Sources/FleetKit/Wire.swift` (add `planGate` to `WireSession`)
- Modify: `Sources/FleetKit/Frames.swift` (add two `FleetCommand` cases and their `Op`s)
- Create: `Tests/FlightDeckTests/PlanFrameCodingTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `WirePlanGate` with `callID: String`, `tier: String` (`"annotate"` | `"verdict"`), `plan: String?`, `startedAt: String`, `annotationCount: Int`; `WireSession.planGate: WirePlanGate?`; `FleetCommand.annotatePlan(id: UUID, token: UUID, call: String, text: String, block: Int?)`; `FleetCommand.resolvePlan(id: UUID, token: UUID, call: String, approve: Bool, feedback: String?)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FleetKit

/// The wire shapes this feature adds, both directions.
///
/// `WireSession` decoding is additive on purpose — a phone built before this feature must
/// still decode a snapshot from a Mac built after it. The commands throw on an unrecognised
/// value, exactly as `PromptAnswer` does and for the same reason: they travel phone → Mac and
/// are *executed*, and there is no default that is not a wrong action.
final class PlanFrameCodingTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testPlanGateRoundTrips() throws {
        let gate = WirePlanGate(
            callID: "toolu_01ABC", tier: "annotate", plan: "# Title\n\nBody.",
            startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 2
        )
        XCTAssertEqual(try roundTrip(gate), gate)
    }

    /// A session with no gate is the ordinary case and must not grow a key.
    func testSessionWithoutAGateEncodesNoKey() throws {
        let session = WireSession(id: UUID(), title: "t", agent: "claude")
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["planGate"])
    }

    /// **A phone that predates this feature must still read the snapshot.** The absence of the
    /// key decodes as no gate, not as a failure that takes the whole fleet down — the ruling
    /// `WireSession.agent` already makes for an unknown agent string.
    func testASnapshotWithAnUnknownExtraKeyStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","agent":"claude","subagentCount":0,
         "isUnread":false,"hasBackgroundWork":false,"somethingNewer":42}
        """
        XCTAssertNoThrow(try JSONDecoder().decode(WireSession.self, from: Data(json.utf8)))
    }

    func testAnnotateCommandRoundTrips() throws {
        let id = UUID(), token = UUID()
        let command = FleetCommand.annotatePlan(
            id: id, token: token, call: "toolu_01ABC", text: "needs a rollback", block: 7
        )
        XCTAssertEqual(try roundTrip(command), command)
    }

    /// A global comment carries no block. `nil` and "block 0" are different requests.
    func testAnnotateWithoutABlockRoundTrips() throws {
        let command = FleetCommand.annotatePlan(
            id: UUID(), token: UUID(), call: "c", text: "high-level note", block: nil
        )
        XCTAssertEqual(try roundTrip(command), command)
    }

    func testResolveCommandRoundTrips() throws {
        for approve in [true, false] {
            let command = FleetCommand.resolvePlan(
                id: UUID(), token: UUID(), call: "c", approve: approve, feedback: "why"
            )
            XCTAssertEqual(try roundTrip(command), command)
        }
    }

    func testCommandOpsAreTheNamesOnTheWire() throws {
        let annotate = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                FleetCommand.annotatePlan(id: UUID(), token: UUID(), call: "c",
                                          text: "t", block: 1)
            )
        ) as? [String: Any]
        XCTAssertEqual(annotate?["op"] as? String, "plan.annotate")

        let resolve = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                FleetCommand.resolvePlan(id: UUID(), token: UUID(), call: "c",
                                         approve: true, feedback: nil)
            )
        ) as? [String: Any]
        XCTAssertEqual(resolve?["op"] as? String, "plan.resolve")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'WirePlanGate' in scope`.

- [ ] **Step 3: Add `WirePlanGate` and the `WireSession` field**

In `Sources/FleetKit/Wire.swift`, above `WireSession`:

```swift
/// An open `ExitPlanMode` gate, as it goes on the wire.
///
/// **This is carried, not derived, and that is the one place this feature departs from
/// `OpenPrompt`.** Every other blocked state is re-derived on both ends from a transcript they
/// both hold, precisely so a cache cannot disagree with a screen. A plan gate cannot be: while
/// one is open, claude's registry reports `status: "busy"` — measured over 33 minutes against
/// pid 66955 on 2026-08-29 — so there is nothing in the transcript or the status file that
/// says a human is needed. Only the Mac can know, because only the Mac can read Plannotator's
/// session registry. So the fact travels.
public struct WirePlanGate: Codable, Equatable, Sendable {
    /// The `ExitPlanMode` call this gate is for. The phone sends it back with every command,
    /// and the Mac refuses anything naming a different one — the check `PromptService` makes
    /// for a dialog, made here for a gate.
    public let callID: String
    /// `"annotate"` when Plannotator is live and inline comments will pin; `"verdict"` when it
    /// is not and only a whole-plan reply is possible. A `String` rather than an enum for
    /// `WireSession.agent`'s reason: a tier added later must render degraded, not throw.
    public let tier: String
    /// The plan markdown, when the Mac read it from `GET /api/plan`. Absent in the `verdict`
    /// tier, where the phone reads it from the transcript body it already holds.
    public let plan: String?
    public let startedAt: String
    public let annotationCount: Int

    public init(callID: String, tier: String, plan: String?,
                startedAt: String, annotationCount: Int) {
        self.callID = callID
        self.tier = tier
        self.plan = plan
        self.startedAt = startedAt
        self.annotationCount = annotationCount
    }
}
```

Add the stored property to `WireSession` after `hasBackgroundWork`:

```swift
    /// The plan gate this tab is blocked on, or `nil`. See `WirePlanGate` for why this is
    /// carried rather than derived.
    public var planGate: WirePlanGate?
```

Give it a defaulted parameter at the end of `init` (`planGate: WirePlanGate? = nil`), assign it, add `case planGate` to `CodingKeys`, and in `init(from:)`:

```swift
        planGate = try c.decodeIfPresent(WirePlanGate.self, forKey: .planGate)
```

If `WireSession` has a hand-written `encode(to:)`, use `encodeIfPresent` so an absent gate writes no key.

- [ ] **Step 4: Add the two commands**

In `Sources/FleetKit/Frames.swift`, add to `FleetCommand`:

```swift
    /// One comment on an open plan gate. `block` is an **index into the Mac's own
    /// `PlanBlocks.split` of the plan**, never the text: the Mac resolves it against its own
    /// copy, so a phone cannot name a phrase this plan never held. Same principle as
    /// `PromptAnswer.option` carrying a label the Mac cross-checks — applied one level up,
    /// where the payload is prose rather than a keystroke.
    ///
    /// `nil` is a global comment, which needs no anchor.
    case annotatePlan(id: UUID, token: UUID, call: String, text: String, block: Int?)

    /// Approve or request changes. **Both carry feedback**, because approving with notes is a
    /// real outcome — `POST /api/approve` takes a `feedback` field for exactly that.
    case resolvePlan(id: UUID, token: UUID, call: String, approve: Bool, feedback: String?)
```

Extend `CodingKeys` with `case text, block, approve, feedback` (reuse `text` if it exists), and `Op` with:

```swift
        case annotatePlan = "plan.annotate"
        case resolvePlan = "plan.resolve"
```

In `encode(to:)`:

```swift
        case .annotatePlan(let id, let token, let call, let text, let block):
            try c.encode(Op.annotatePlan, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(call, forKey: .call)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(block, forKey: .block)
        case .resolvePlan(let id, let token, let call, let approve, let feedback):
            try c.encode(Op.resolvePlan, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(call, forKey: .call)
            try c.encode(approve, forKey: .approve)
            try c.encodeIfPresent(feedback, forKey: .feedback)
```

In `init(from:)`, alongside the other ops:

```swift
        case .annotatePlan:
            self = .annotatePlan(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                call: try c.decode(String.self, forKey: .call),
                text: try c.decode(String.self, forKey: .text),
                block: try c.decodeIfPresent(Int.self, forKey: .block)
            )
        case .resolvePlan:
            self = .resolvePlan(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                call: try c.decode(String.self, forKey: .call),
                approve: try c.decode(Bool.self, forKey: .approve),
                feedback: try c.decodeIfPresent(String.self, forKey: .feedback)
            )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all seven `PlanFrameCodingTests` cases, and **the existing suite still green** — `AnswerFrameCodingTests` counts `PromptAnswer`'s cases and must be unaffected, since nothing here touches that enum.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/Wire.swift Sources/FleetKit/Frames.swift \
        Tests/FlightDeckTests/PlanFrameCodingTests.swift
git commit -m "feat: put an open plan gate and its two commands on the wire"
```

---

### Task 5: `PlanGateService` — watch, project, and resolve

The Mac half joined up: poll the registry, fetch the plan once per gate, expose it on the projection, and carry out the phone's two commands.

**Files:**
- Create: `Sources/FlightDeck/Fleet/PlanGateService.swift`
- Create: `Tests/FlightDeckTests/PlanGateServiceTests.swift`
- Modify: `Sources/FlightDeck/Fleet/FleetProjection.swift:53` (populate `planGate`)

**Interfaces:**
- Consumes: `PlannotatorRegistry.planGates(in:isAlive:parentOf:)`, `PlanGateClient`, `PlanBlocks.split(_:)`, `WirePlanGate`, `FleetCommand`.
- Produces: `@MainActor final class PlanGateService` with `func refresh() async`, `func gate(for session: UUID) -> WirePlanGate?`, `func annotate(session:call:text:block:token:) async -> Result<Void, TimelineErrorCode>`, `func resolve(session:call:approve:feedback:token:) async -> Result<Void, TimelineErrorCode>`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck
@testable import FleetKit

/// The Mac half of a plan gate.
final class PlanGateServiceTests: XCTestCase {

    /// A gate the phone never saw. Answering it would resolve a plan the reader did not read.
    @MainActor
    func testRefusesACallItDoesNotHave() async {
        let service = PlanGateService.stub(plan: "# A\n\nB.", callID: "toolu_REAL")
        await service.refresh()
        let result = await service.resolve(
            session: service.knownSession, call: "toolu_OTHER",
            approve: true, feedback: nil, token: UUID()
        )
        XCTAssertEqual(result.failureCode, "prompt_changed")
    }

    /// A retry that lands is an answer that landed — the ruling `answeredPromptTokens` makes
    /// for `prompt.answer`, applied here so a flaky link cannot double-resolve.
    @MainActor
    func testTheSameTokenResolvesOnlyOnce() async {
        let service = PlanGateService.stub(plan: "# A\n\nB.", callID: "c")
        await service.refresh()
        let token = UUID()
        let first = await service.resolve(session: service.knownSession, call: "c",
                                          approve: true, feedback: nil, token: token)
        let second = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: token)
        XCTAssertNil(first.failureCode)
        XCTAssertNil(second.failureCode, "a duplicate is an ack, not an error")
        XCTAssertEqual(service.resolveCallCount, 1, "the gate must be resolved exactly once")
    }

    /// The block index is resolved against the Mac's own split. A phone naming a block this
    /// plan does not have gets nothing pinned.
    @MainActor
    func testAnnotateResolvesTheBlockIndexLocally() async {
        let service = PlanGateService.stub(plan: "First block.\n\nSecond block.", callID: "c")
        await service.refresh()
        let ok = await service.annotate(session: service.knownSession, call: "c",
                                        text: "note", block: 1, token: UUID())
        XCTAssertNil(ok.failureCode)
        XCTAssertEqual(service.lastAnnotation?.originalText, "Second block.")
    }

    @MainActor
    func testAnnotateRefusesAnOutOfRangeBlock() async {
        let service = PlanGateService.stub(plan: "Only one.", callID: "c")
        await service.refresh()
        let result = await service.annotate(session: service.knownSession, call: "c",
                                            text: "note", block: 9, token: UUID())
        XCTAssertEqual(result.failureCode, "unreadable_screen")
        XCTAssertNil(service.lastAnnotation)
    }

    /// A non-target block cannot be pinned; the comment goes global rather than pinning to an
    /// arbitrary copy.
    @MainActor
    func testANonTargetBlockBecomesAGlobalComment() async {
        let service = PlanGateService.stub(plan: "A.\n\n---\n\nB.", callID: "c")
        await service.refresh()
        let breakIndex = PlanBlocks.split("A.\n\n---\n\nB.").blocks
            .firstIndex { !$0.isTarget }!
        _ = await service.annotate(session: service.knownSession, call: "c",
                                   text: "note", block: breakIndex, token: UUID())
        XCTAssertNil(service.lastAnnotation?.originalText,
                     "a non-target must not be sent as an anchor")
    }

    /// The gate closed between the tap and the command — hook killed, or answered on the Mac.
    @MainActor
    func testAVanishedGateRefuses() async {
        let service = PlanGateService.stub(plan: "# A", callID: "c")
        await service.refresh()
        service.killGate()
        await service.refresh()
        let result = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: UUID())
        XCTAssertEqual(result.failureCode, "not_waiting")
    }

    /// The plan is fetched once, not on every poll: a 4-day gate polled every 2s would be
    /// 170,000 requests for a document that cannot change without the callID changing.
    @MainActor
    func testThePlanIsFetchedOncePerGate() async {
        let service = PlanGateService.stub(plan: "# A", callID: "c")
        await service.refresh()
        await service.refresh()
        await service.refresh()
        XCTAssertEqual(service.planFetchCount, 1)
    }
}
```

Add the stub factory in the same file — a real `PlanGateService` with its registry read and transport substituted, never a parallel implementation:

```swift
extension PlanGateService {
    /// A service wired to an in-memory registry and a recording transport.
    @MainActor
    static func stub(plan: String, callID: String) -> PlanGateService { /* see Step 3 */ }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PlanGateService' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import FleetKit
import Foundation

/// Everything the Mac does about plan gates: find them, describe them, act on them.
///
/// **Polled rather than pushed, because there is nothing to push.** A blocking
/// `PermissionRequest` hook writes a registry file and then waits; nothing signals Flight
/// Deck. The poll is a directory read of a handful of small files, and the cost is bounded by
/// caching the plan per call id — see `planFetchCount` in the tests.
///
/// **The plan is fetched once per gate.** A gate can stay open for four days; the plan behind
/// one call id cannot change, because a revision is a *new* `ExitPlanMode` call with a new id.
@MainActor
final class PlanGateService {

    struct Gate {
        let entry: PlannotatorRegistry.Entry
        let callID: String
        let plan: String
        let blocks: PlanBlocks
        var annotationCount: Int
    }

    /// Test seams, in the shape `PromptService.tail` is one.
    var registryDirectory: URL = PlannotatorRegistry.defaultDirectory
    var isAlive: (pid_t) -> Bool = PlannotatorRegistry.processIsAlive
    var parentOf: (pid_t) -> pid_t? = PlannotatorRegistry.parentProcess
    var makeClient: (Int) -> PlanGateClient = { PlanGateClient(port: $0) }
    /// The `ExitPlanMode` call id for a session, from the transcript. Injected rather than
    /// reached for, so this class needs neither a store nor a pager.
    var callID: (UUID) -> String?
    /// The `claude` pid backing a session.
    var pid: (UUID) -> pid_t?
    /// Every session this Mac knows.
    var sessions: () -> [UUID]

    private var gates: [UUID: Gate] = [:]
    private var resolvedTokens: [UUID: [UUID]] = [:]

    init(callID: @escaping (UUID) -> String?,
         pid: @escaping (UUID) -> pid_t?,
         sessions: @escaping () -> [UUID]) {
        self.callID = callID
        self.pid = pid
        self.sessions = sessions
    }

    /// Re-read the registry. Gates that vanished are dropped; new ones have their plan
    /// fetched exactly once.
    func refresh() async {
        let live = PlannotatorRegistry.planGates(
            in: registryDirectory, isAlive: isAlive, parentOf: parentOf
        )
        var next: [UUID: Gate] = [:]
        for session in sessions() {
            guard let claudePID = pid(session), let entry = live[claudePID] else { continue }
            guard let call = callID(session) else { continue }
            // Already held, and the call has not moved: keep it, plan and all.
            if let existing = gates[session], existing.callID == call,
               existing.entry.pid == entry.pid {
                next[session] = existing
                continue
            }
            guard let plan = await makeClient(entry.port).plan() else { continue }
            next[session] = Gate(entry: entry, callID: call, plan: plan,
                                 blocks: PlanBlocks.split(plan), annotationCount: 0)
        }
        gates = next
    }

    func gate(for session: UUID) -> WirePlanGate? {
        guard let gate = gates[session] else { return nil }
        return WirePlanGate(
            callID: gate.callID, tier: "annotate", plan: gate.plan,
            startedAt: gate.entry.startedAt, annotationCount: gate.annotationCount
        )
    }

    /// Post one comment. `block` is resolved against **this** Mac's split of the plan.
    func annotate(
        session: UUID, call: String, text: String, block: Int?, token: UUID
    ) async -> Result<Void, TimelineErrorCode> {
        guard let gate = gates[session] else { return .failure("not_waiting") }
        guard gate.callID == call else { return .failure("prompt_changed") }

        var originalText: String?
        if let block {
            // Out of range is a refusal, not a silent downgrade: the phone drew a target this
            // Mac does not have, so the two disagree about the plan and nothing should pin.
            guard let resolved = gate.blocks.block(at: block) else {
                return .failure("unreadable_screen")
            }
            // A non-target IS a silent downgrade to global, deliberately: the phone should not
            // have offered a tap, but the reader's words are real and a global comment carries
            // them without pinning to an arbitrary copy.
            originalText = resolved.isTarget ? resolved.text : nil
        }

        let ok = await makeClient(gate.entry.port)
            .annotate(text: text, originalText: originalText)
        guard ok else { return .failure("unreadable_screen") }
        gates[session]?.annotationCount += 1
        return .success(())
    }

    /// Approve or request changes, once.
    func resolve(
        session: UUID, call: String, approve: Bool, feedback: String?, token: UUID
    ) async -> Result<Void, TimelineErrorCode> {
        // Before anything is sent, exactly as `answerPrompt`'s token test precedes any
        // keystroke: a retry resolves nothing twice.
        if resolvedTokens[session, default: []].contains(token) { return .success(()) }
        guard let gate = gates[session] else { return .failure("not_waiting") }
        guard gate.callID == call else { return .failure("prompt_changed") }

        resolvedTokens[session, default: []].append(token)
        let ok = await makeClient(gate.entry.port)
            .resolve(approved: approve, feedback: feedback)
        guard ok else {
            // The gate did not take it — let a retry through rather than swallowing the tap.
            resolvedTokens[session]?.removeAll { $0 == token }
            return .failure("unreadable_screen")
        }
        gates[session] = nil
        return .success(())
    }
}
```

- [ ] **Step 4: Populate the projection**

In `Sources/FlightDeck/Fleet/FleetProjection.swift`, where `WireSession` is built (line ~53, beside `waitingFor: status?.waitingFor`), add:

```swift
            planGate: planGates?.gate(for: session.id)
```

Thread a `PlanGateService?` into the projection the way `status` is already threaded. **Optional on purpose:** a projection built in a test with no service must still produce a `WireSession`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all seven `PlanGateServiceTests` cases, and every existing `FleetProjection` test still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/PlanGateService.swift \
        Sources/FlightDeck/Fleet/FleetProjection.swift \
        Tests/FlightDeckTests/PlanGateServiceTests.swift
git commit -m "feat: watch plan gates and carry out the phone's verdict"
```

---

### Task 6: Route the two commands, and stop calling a blocked session busy

Wires `PlanGateService` into the socket server's `onCommand`, drives the poll, and fixes the presentation bug: a session with a gate is **blocked**, not busy.

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetSocketServer.swift` (route `plan.annotate` / `plan.resolve`)
- Modify: `Sources/FlightDeck/SessionNotificationPolicy.swift` (notify on a gate opening)
- Create: `Tests/FlightDeckTests/PlanGateNotificationTests.swift`

**Interfaces:**
- Consumes: `PlanGateService`, `FleetCommand.annotatePlan`, `FleetCommand.resolvePlan`.
- Produces: no new public API.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck
@testable import FleetKit

/// A plan gate is a call for a human, and must reach one.
///
/// **This is the defect the whole feature exists for.** While a gate is open, claude's
/// registry reports `status: "busy"` — measured over 33 minutes against pid 66955 on
/// 2026-08-29 — so every existing "you are needed" path is silent. `SessionNotificationPolicy`
/// keys off a `waiting` transition that never comes.
final class PlanGateNotificationTests: XCTestCase {

    func testAGateOpeningNotifiesEvenThoughTheStatusSaysBusy() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let before = SessionNotificationPolicy.Input(status: busy, planGate: nil)
        let after = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        XCTAssertTrue(SessionNotificationPolicy.shouldNotify(from: before, to: after))
    }

    /// A poll that re-reports the same gate is not a new event. A four-day gate polled every
    /// two seconds would otherwise be 170,000 notifications.
    func testTheSameGateNotifiesOnlyOnce() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let open = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        XCTAssertFalse(SessionNotificationPolicy.shouldNotify(from: open, to: open))
    }

    /// A revised plan is a new call id and a genuinely new thing to read.
    func testANewCallIDNotifiesAgain() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let first = SessionNotificationPolicy.Input(status: busy, planGate: .stub(call: "c1"))
        let second = SessionNotificationPolicy.Input(status: busy, planGate: .stub(call: "c2"))
        XCTAssertTrue(SessionNotificationPolicy.shouldNotify(from: first, to: second))
    }

    func testAGateClosingDoesNotNotify() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let open = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        let closed = SessionNotificationPolicy.Input(status: busy, planGate: nil)
        XCTAssertFalse(SessionNotificationPolicy.shouldNotify(from: open, to: closed))
    }
}

private extension WirePlanGate {
    static func stub(call: String = "toolu_01ABC") -> WirePlanGate {
        WirePlanGate(callID: call, tier: "annotate", plan: "# Plan",
                     startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `SessionNotificationPolicy.Input` does not exist / no `planGate` parameter.

- [ ] **Step 3: Extend the notification policy**

`SessionNotificationPolicy` currently compares `old?.activity == .waiting` against `new?.activity == .waiting` (`SessionNotificationPolicy.swift:22-23`). Introduce an `Input` that carries both the status and the gate, and make the "wants you" test the **disjunction** of the two:

```swift
    /// What decides a notification. A struct rather than two parameters, because "wants you"
    /// is now two independent facts and a caller passing one of them is a caller that will
    /// eventually pass only one.
    struct Input: Equatable {
        let status: SessionStatus?
        let planGate: WirePlanGate?

        /// **`waiting` OR a gate.** A gate reports `busy`, so the existing test alone is blind
        /// to the longest block in the system.
        var wantsYou: Bool { status?.activity == .waiting || planGate != nil }

        /// What is being asked, so a re-poll of one gate is not a second event and a revised
        /// plan is.
        var subject: String? { planGate?.callID }
    }

    static func shouldNotify(from old: Input, to new: Input) -> Bool {
        guard new.wantsYou else { return false }
        if !old.wantsYou { return true }
        // Both want you: only a change of subject is a new thing to read.
        return old.subject != new.subject && new.subject != nil
    }
```

Update the existing call site to build an `Input`, and keep every existing `SessionNotificationPolicy` test passing — if one calls the old signature, adapt the call, not the assertion.

- [ ] **Step 4: Route the commands**

In `FleetSocketServer`'s `onCommand`, beside the `answerPrompt` arm. Both are `async` while the surrounding switch is synchronous, so hop through a `Task` and reply on completion, the way any other async command reply is sent:

```swift
        case .annotatePlan(let id, let token, let call, let text, let block):
            Task { @MainActor in
                let result = await planGates.annotate(
                    session: id, call: call, text: text, block: block, token: token
                )
                reply(result)
            }
        case .resolvePlan(let id, let token, let call, let approve, let feedback):
            Task { @MainActor in
                let result = await planGates.resolve(
                    session: id, call: call, approve: approve, feedback: feedback, token: token
                )
                reply(result)
            }
```

Drive `PlanGateService.refresh()` from the same timer that already re-reads claude's registry. **Do not add a second timer** — one poll of two directories is cheaper than two polls, and two would let the gate and the status be read at different instants.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, four `PlanGateNotificationTests` cases plus the existing `SessionNotificationPolicy` suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetSocketServer.swift \
        Sources/FlightDeck/SessionNotificationPolicy.swift \
        Tests/FlightDeckTests/PlanGateNotificationTests.swift
git commit -m "feat: notify on an open plan gate and route its two commands"
```

---

### Task 7: The phone — read the plan, tap a block, send a verdict

**Files:**
- Create: `Sources/FlightDeckMobile/PlanReviewScreen.swift`
- Create: `Sources/FlightDeckMobile/PlanReviewModel.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (banner into the screen)
- Create: `Tests/FlightDeckTests/PlanReviewModelTests.swift`

**Interfaces:**
- Consumes: `WirePlanGate`, `PlanBlocks`, `FleetCommand.annotatePlan`, `FleetCommand.resolvePlan`, `TimelineMarkdown.theme`.
- Produces: `@MainActor final class PlanReviewModel` with `blocks: [PlanBlocks.Block]`, `notes: [Int: String]`, `globalNotes: [String]`, `func comment(on block: Int?, text: String)`, `func resolve(approve: Bool)`, `var feedback: String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FleetKit

/// The phone's half. Logic only — the view is exercised by `scripts/smoke.sh`.
@MainActor
final class PlanReviewModelTests: XCTestCase {

    private func model(plan: String) -> PlanReviewModel {
        PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: plan,
                               startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 0),
            send: { _ in }
        )
    }

    /// **Both ends split identically.** The phone draws a tap target per target block; the Mac
    /// resolves the index it is sent. A disagreement here is a comment on the wrong phrase.
    func testTheSameBlocksTheMacWouldCompute() {
        let plan = "# Title\n\nFirst.\n\n---\n\nSecond."
        XCTAssertEqual(model(plan: plan).blocks, PlanBlocks.split(plan).blocks)
    }

    func testOnlyTargetsAreTappable() {
        let model = model(plan: "A.\n\n---\n\nB.")
        XCTAssertEqual(model.blocks.filter(\.isTarget).count, 2)
        XCTAssertFalse(model.canComment(on: model.blocks.first { !$0.isTarget }!.index))
        XCTAssertTrue(model.canComment(on: 0))
    }

    func testACommentSendsAnnotateWithItsBlockIndex() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.\n\nB.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.comment(on: 1, text: "needs a rollback")
        guard case .annotatePlan(_, _, let call, let text, let block) = sent.first else {
            return XCTFail("expected annotatePlan, got \(String(describing: sent.first))")
        }
        XCTAssertEqual(call, "c")
        XCTAssertEqual(text, "needs a rollback")
        XCTAssertEqual(block, 1)
    }

    func testAGlobalCommentCarriesNoBlock() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.comment(on: nil, text: "missing a rollback section")
        guard case .annotatePlan(_, _, _, _, let block) = sent.first else {
            return XCTFail("expected annotatePlan")
        }
        XCTAssertNil(block)
    }

    /// Approving with notes is one action, not "send notes, then approve" — `POST /api/approve`
    /// takes the feedback itself, so the reader's words and their verdict cannot separate.
    func testApproveCarriesTheTypedFeedback() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.feedback = "ship it, but rename X"
        model.resolve(approve: true)
        guard case .resolvePlan(_, _, _, let approve, let feedback) = sent.last else {
            return XCTFail("expected resolvePlan")
        }
        XCTAssertTrue(approve)
        XCTAssertEqual(feedback, "ship it, but rename X")
    }

    /// One tap, one verdict. A double tap on Approve must not send two.
    func testResolvingTwiceSendsOneCommand() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.resolve(approve: true)
        model.resolve(approve: false)
        XCTAssertEqual(sent.filter { if case .resolvePlan = $0 { return true }; return false }.count, 1)
    }

    /// In the `verdict` tier the gate carries no plan and pinning is impossible. The screen
    /// must say so rather than draw taps that go nowhere.
    func testVerdictTierOffersNoInlineComments() {
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "verdict", plan: nil,
                               startedAt: "t", annotationCount: 0),
            transcriptPlan: "A.\n\nB.",
            send: { _ in }
        )
        XCTAssertFalse(model.canComment(on: 0))
        XCTAssertEqual(model.blocks.count, 2, "it still renders, it just takes no taps")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PlanReviewModel' in scope`.

- [ ] **Step 3: Write the model**

```swift
import FleetKit
import Foundation

/// What the phone knows about the gate it is showing.
///
/// **Splits with `PlanBlocks`, never its own rule** — the whole reason that type is in
/// `FleetKit`. The index this model sends is meaningful only because the Mac computes the
/// same list from the same text.
@MainActor
final class PlanReviewModel: ObservableObject {
    let session: UUID
    let gate: WirePlanGate
    let blocks: [PlanBlocks.Block]

    /// Typed into the box above the verdict buttons, and carried by whichever one is pressed.
    @Published var feedback: String = ""
    /// Comments already sent, by block index, so the row can show a marker.
    @Published private(set) var sent: [Int: [String]] = [:]
    @Published private(set) var globalSent: [String] = []
    @Published private(set) var resolved = false

    private let send: (FleetCommand) -> Void

    /// `transcriptPlan` is the `verdict` tier's source: there, the gate carries no plan and the
    /// phone reads `ExitPlanMode`'s own `input.plan` out of the timeline body it already holds.
    init(session: UUID, gate: WirePlanGate, transcriptPlan: String? = nil,
         send: @escaping (FleetCommand) -> Void) {
        self.session = session
        self.gate = gate
        self.send = send
        self.blocks = PlanBlocks.split(gate.plan ?? transcriptPlan ?? "").blocks
    }

    /// Inline pinning needs a live Plannotator gate. In the `verdict` tier the plan still
    /// renders — it just takes no taps, and the screen says why once.
    func canComment(on block: Int) -> Bool {
        guard gate.tier == "annotate", !resolved else { return false }
        return blocks.first { $0.index == block }?.isTarget == true
    }

    func comment(on block: Int?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !resolved else { return }
        if let block { guard canComment(on: block) else { return } }
        send(.annotatePlan(id: session, token: UUID(), call: gate.callID,
                           text: trimmed, block: block))
        if let block { sent[block, default: []].append(trimmed) }
        else { globalSent.append(trimmed) }
    }

    /// One tap, one verdict. Latched here as well as tokened on the Mac, because a double tap
    /// should not even reach the socket.
    func resolve(approve: Bool) {
        guard !resolved else { return }
        resolved = true
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.resolvePlan(id: session, token: UUID(), call: gate.callID,
                          approve: approve, feedback: trimmed.isEmpty ? nil : trimmed))
    }
}
```

- [ ] **Step 4: Write the screen**

`PlanReviewScreen.swift`. Draw each block with `TimelineMarkdown.theme` — the same theme the timeline uses, so a plan cannot look like a different app two taps away. A target block gets a `contentShape(Rectangle())` and an `onTapGesture` presenting a comment sheet; a non-target draws identically with no gesture. Requirements:

- Blocks in a `LazyVStack`, each in a rounded container that highlights on press.
- A block with sent comments shows a count badge (`💬 2`).
- Sizes come from Dynamic Type — **no absolute point sizes**, per `TimelineMarkdown`'s own rule.
- A footer with the feedback field and two buttons: **Approve** and **Request changes**.
- In the `verdict` tier, one line above the plan stating that inline comments need Plannotator on the Mac. Say it once, not per block.
- When `resolved`, the whole screen goes read-only with the verdict shown.

- [ ] **Step 5: Reach it from the timeline**

In `SessionTimelineScreen`, when the session's `planGate != nil`, show a banner above the timeline — "Waiting on your review of a plan" plus elapsed time from `startedAt` — pushing `PlanReviewScreen`. This is the affordance that replaces a spinner that says nothing.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all seven `PlanReviewModelTests` cases.

- [ ] **Step 7: Build the phone target**

Run: `scripts/build-ios.sh`
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeckMobile/PlanReviewScreen.swift \
        Sources/FlightDeckMobile/PlanReviewModel.swift \
        Sources/FlightDeckMobile/SessionTimelineScreen.swift \
        Tests/FlightDeckTests/PlanReviewModelTests.swift
git commit -m "feat: read and annotate a plan from the phone"
```

---

### Task 8: End-to-end against a real gate

The tests use doubles. This task proves the contract against the real binary once.

**Files:** none — verification only.

- [ ] **Step 1: Start a throwaway gate**

**Never test against a gate another session is waiting on.** Start your own:

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck
printf '# Throwaway plan\n\nA paragraph to pin a comment to.\n\n- a list item\n' \
  > /tmp/e2e-plan.md
PLANNOTATOR_SKIP_BROWSER_OPEN=1 plannotator annotate /tmp/e2e-plan.md --gate --json &
sleep 3
```

- [ ] **Step 2: Confirm the registry, the plan and an annotation**

```bash
PORT=$(python3 -c "
import glob,json,os
best=None
for f in glob.glob(os.path.expanduser('~/.plannotator/sessions/*.json')):
    d=json.load(open(f))
    if d.get('mode')=='plan' and d.get('project')!='flight-deck': best=d
print(best['port'] if best else '')
")
echo "port: $PORT"
curl -s "http://127.0.0.1:$PORT/api/plan" | python3 -c "import json,sys;print(repr(json.load(sys.stdin)['plan'][:60]))"
curl -s -X POST "http://127.0.0.1:$PORT/api/external-annotations" \
  -H 'Content-Type: application/json' \
  -d '{"source":"flight-deck","type":"COMMENT","text":"e2e","originalText":"A paragraph to pin a comment to."}'
curl -s "http://127.0.0.1:$PORT/api/external-annotations" | head -c 300
```

Expected: the plan text comes back; the annotation lands and appears in the list with its `originalText` intact.

- [ ] **Step 3: Resolve it and confirm the hook's output**

```bash
curl -s -X POST "http://127.0.0.1:$PORT/api/deny" \
  -H 'Content-Type: application/json' -d '{"feedback":"e2e denial"}'
wait %1
```

Expected: the backgrounded `plannotator` exits, having printed a decision JSON whose feedback contains `e2e denial`. **If the shape differs from `PlanGateClient`'s expectation, fix the client and its tests — the binary is the authority, not this plan.**

- [ ] **Step 4: Confirm the real end-to-end on device**

With Flight Deck running and a phone paired, trigger a real `ExitPlanMode` in any session and confirm on the phone: the session shows the plan banner rather than a spinner, the plan renders, tapping a block posts a comment that appears in the Mac's browser, and Approve closes the gate.

- [ ] **Step 5: Commit any corrections**

```bash
git add -u && git commit -m "fix: correct the plan gate contract against the real binary"
```

(Skip if nothing needed correcting.)

---

## Self-Review

**Spec coverage.** §1.1 busy-not-waiting → Task 6. §1.2 API contract → Tasks 3, 8. §1.3 registry + parent pid → Task 2. §1.4 plan already on the phone → Task 7's `transcriptPlan`. §1.5 block-tap → Task 1. §1.6 no remote publishing → Task 3's loopback test. §2 deliverables → Tasks 6, 7. §3 two tiers → Tasks 5, 7. §4 discovery → Task 2. §5 annotation model → Task 1. §6 wire → Task 4. §7 failure modes → Tasks 5 (vanished, duplicate), 3 (unmatched comment). §8 testing → every task.

**One gap, stated rather than hidden.** Spec §3's Tier 2 ordering — Escape first, then notes as a `session.prompt` — is **not implemented by any task above.** Tasks 5 and 7 carry the `verdict` tier through the wire and the UI, but the Mac-side two-step reuses `answerPrompt(.deny)` and `submitPrompt`, which already exist and are already tested. If Tier 2 turns out to need its own sequencing on the Mac, that is a ninth task; it is deliberately not invented here, because a machine without Plannotator is not this machine and the path cannot be exercised.

**Placeholders:** none. Every code step carries the code.

**Type consistency:** `PlanBlocks.Block.isTarget` is used identically in Tasks 1, 5, 7. `PlanGateClient.annotate(text:originalText:)` matches its Task 5 call site. `WirePlanGate`'s five fields are constructed identically in Tasks 4, 5, 6, 7. `TimelineErrorCode` values (`not_waiting`, `prompt_changed`, `unreadable_screen`) reuse the existing vocabulary rather than adding codes.
