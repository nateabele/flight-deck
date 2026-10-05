# Flight Control L3-0 Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the shared Level 3 shapes — the execution block, task kinds, dimensions, the
routing/usage/swarm protocols, adapter routing capabilities, fakes and fixtures — so L3-R, L3-I,
L3-U and L3-S can be built in parallel worktrees without colliding.

**Architecture:** Pure value types, the codec and the protocols go in `IntakeKit` (Foundation
only, Swift 6), in a new `Sources/IntakeKit/FlightControl/` folder. The adapter-facing
capability protocol, its registry and the `SwarmSpawner` protocol go in the app target
(`Sources/FlightDeck/FlightControl/`), because they touch `Session` and `AgentOptions`. Fakes
for every protocol and the shared fixtures live in the unit test target, so every later branch
tests against the same doubles.

**Tech Stack:** Swift 6 (IntakeKit), Swift 5 mode (app target), XCTest, XcodeGen, `br` 0.6.0.

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md`

## Global Constraints

- IntakeKit is Foundation-only, `SWIFT_VERSION: "6.0"`. Every new IntakeKit type is `Sendable`.
- The app target keeps `SWIFT_VERSION: "5.0"`. Don't "fix" it.
- The execution block lives at `agent_context.flight_deck.execution`. Writers preserve every
  other key of `agent_context` and of `flight_deck`.
- `br ready --json` does not carry `agent_context`; readers use `br list --json`, which returns an envelope `{"issues":[…],"total":N}` (probed, br 0.6.0).
- `harness` is a string validated against a registry, never a hard-coded enum. IntakeKit cannot
  import the app's `AgentID`, so IntakeKit uses `HarnessID` (a string wrapper) and the app maps
  `AgentID.rawValue` to it.
- A reader rejects a block whose `v` is higher than `ExecutionBlock.currentVersion` and leaves
  the task alone. An invalid block is reported, never silently repaired.
- UI copy says *tasks*, *agent*, *Flight Control* — never "beads"/"seat"/"flywheel". (L3-0 has no
  UI, but error messages surfaced later come from here.)
- Commits: lowercase, behavioral, imperative; trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit by path; never `git stash`.
- Tests: TDD, confirm each new test fails first. Run one class with
  `FD_TEST_FILTER=<Class> ./scripts/test-unit.sh`. A filtered run exits early and ends with
  xctest's own `Executed N tests, with M failures` line (no `SHARDED UNIT RUN` banner); only the
  unfiltered run prints `SHARDED UNIT RUN PASSED|FAILED`. Either way the script can exit 0 on
  failure: read that final line and `rg -n "error:"` the output. Test classes must be declared
  `final class X: XCTestCase` with any attribute on its own line, or the runner silently skips them. Subagents run tests
  in the foreground.
- Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts`
  and `vendor/boringssl-artifacts` into it before the first build, and never commit those
  symlinks.
- Never launch a bundle from `DerivedData/`.

**Deviations from the spec decided while planning (Task 6 records them in the spec):**
1. The spec says the capabilities are "added to `AgentAdapter` as a new protocol". Adapters are
   built per account (`SessionStore.makeClaudeAdapter(account:)`), so capabilities are a
   **separate** `@MainActor` protocol with one conformer per agent, held in a
   `RoutingCapabilityRegistry`. Session-specific calls take the `Session` as a parameter.
2. `SwarmSpawner.spawn` takes a `firstPrompt: String`, because L3-U's hand-off spawns with a
   different first prompt than L3-S's task prompt.
3. `Router` also carries `spill(...)` in the contract (spec L3-R §5), so L3-S can call it
   through the protocol.
4. `FakeAdapter` from the spec is a fake `AgentRoutingCapabilities` with harness `"fake"`, not a
   full `AgentAdapter` conformer: adding an `AgentID` case would change every exhaustive switch
   in the app for a test double.

## Review Focus

- **`agent_context` that is not a JSON object** (a bare string written by another tool): the
  encoder must throw rather than overwrite it. Pinned by `testEncodeRefusesNonObjectContext`.
- **A merge cycle in the kind registry** (`a` merged into `b`, `b` into `a`): resolution must
  terminate and return nil. Pinned by `testResolveTerminatesOnMergeCycle`.
- **A block from a newer Flight Deck** (`v: 2`): readers must report it, not decode a partial
  block. Pinned by `testDecodeRejectsNewerVersion`.
- **Foreign keys inside `flight_deck`** (a later feature's `flight_deck.notes`): writing the
  execution block must keep them. Pinned by `testEncodePreservesSiblingFlightDeckKeys`.
- **Kind weights out of range or naming an unknown dimension**: validation must name the bad
  key. Pinned by `testValidateRejectsUnknownDimensionAndOutOfRangeWeight`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IntakeKit/FlightControl/Identifiers.swift` | `HarnessID`, `PoolID`, `KindID` string wrappers |
| `Sources/IntakeKit/FlightControl/ExecutionBlock.swift` | `ExecutionBlock`, `AssignmentSource`, `ModelRef` |
| `Sources/IntakeKit/FlightControl/ExecutionBlockCodec.swift` | decode from / merge into `agent_context` JSON |
| `Sources/IntakeKit/FlightControl/Dimensions.swift` | the capability dimension list |
| `Sources/IntakeKit/FlightControl/TaskKind.swift` | `TaskKind`, status/origin, resolution, validation, seed set, registry file |
| `Sources/IntakeKit/FlightControl/ContractValues.swift` | catalogs, scores, headroom, leases, readings, hand-off, refs |
| `Sources/IntakeKit/FlightControl/ContractProtocols.swift` | `KindRegistry`, `Router`, `CapabilityIndex`, `CapacityReader`, `PoolAllocator`, `HandoffPlanner`, `UsageMeterSource` |
| `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` | capability protocol, `RoutingCapability`, `AccountModel`, `LaunchOverrides`, registry, claude/codex stubs, `SwarmSpawner` |
| `Tests/FlightDeckTests/FlightControlL3/Fakes/*.swift` | one fake per protocol |
| `Tests/FlightDeckTests/Fixtures/FlightControlL3/*.json` | br rows with blocks, kind registry, usage timeline |
| `Tests/FlightDeckTests/FlightControlL3/*Tests.swift` | the tests below |

`project.yml` needs no edit: `Sources/IntakeKit` and `Sources/FlightDeck` are globbed
recursively, and `Tests/FlightDeckTests/Fixtures` is already a folder reference (`project.yml:150-158`).

---

### Task 1: Identifiers, execution block and its codec

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Identifiers.swift`
- Create: `Sources/IntakeKit/FlightControl/ExecutionBlock.swift`
- Create: `Sources/IntakeKit/FlightControl/ExecutionBlockCodec.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/ExecutionBlockCodecTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct HarnessID/PoolID/KindID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible` with `rawValue: String`.
  - `public struct ModelRef: Codable, Hashable, Sendable { harness: HarnessID; model: String; knobs: [String: String] }`
  - `public enum AssignmentSourceKind: String { rule, index, default, spill, manual }`
  - `public struct AssignmentSource { by; ruleId: String?; reason: String; at: Date }`
  - `public struct ExecutionBlock { v, kind, harness, model, knobs, pool, source, pinned, host; static currentVersion = 1; var modelRef: ModelRef }`
  - `public enum ExecutionBlockError: Error, Equatable { notJSONObject, missingField(String), invalidField(String, String), unsupportedVersion(Int) }` with `var message: String`
  - `public enum ExecutionBlockCodec { static func decode(agentContext: String?) -> Result<ExecutionBlock?, ExecutionBlockError>; static func encode(_:into:) throws -> String; static func dictionary(_:) -> [String: Any] }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The execution block is the one shape every Level 3 branch reads and writes, and it lives
/// inside br's `agent_context`, a field other tools also write. These tests pin the two promises
/// the rest of Level 3 leans on: a block round-trips exactly, and writing one never destroys
/// anything else stored in `agent_context`.
final class ExecutionBlockCodecTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func block(pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-sol",
                       knobs: ["effort": "high"], pool: "codex-subs",
                       source: AssignmentSource(by: .rule, ruleId: "r3",
                                                reason: "test-authoring 0.8 → codex", at: at),
                       pinned: pinned)
    }

    func testRoundTripsEveryField() throws {
        let json = try ExecutionBlockCodec.encode(block(pinned: true), into: nil)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: json).get(), block(pinned: true))
    }

    func testNilOrAbsentBlockDecodesToNil() throws {
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: nil).get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: "").get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: #"{"instructions":"x"}"#).get())
        XCTAssertNil(try ExecutionBlockCodec.decode(agentContext: #"{"flight_deck":{}}"#).get())
    }

    func testEncodePreservesForeignTopLevelKeys() throws {
        let json = try ExecutionBlockCodec.encode(block(), into: #"{"instructions":"keep me","n":3}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["instructions"] as? String, "keep me")
        XCTAssertEqual(obj["n"] as? Int, 3)
    }

    func testEncodePreservesSiblingFlightDeckKeys() throws {
        let json = try ExecutionBlockCodec.encode(block(), into: #"{"flight_deck":{"notes":"keep"}}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fd = try XCTUnwrap(obj["flight_deck"] as? [String: Any])
        XCTAssertEqual(fd["notes"] as? String, "keep")
        XCTAssertNotNil(fd["execution"])
    }

    func testEncodeReplacesAnExistingBlock() throws {
        let first = try ExecutionBlockCodec.encode(block(), into: nil)
        var changed = block(); changed.model = "gpt-6-terra"
        let second = try ExecutionBlockCodec.encode(changed, into: first)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: second).get()?.model, "gpt-6-terra")
    }

    func testEncodeRefusesNonObjectContext() {
        XCTAssertThrowsError(try ExecutionBlockCodec.encode(block(), into: #""a bare string""#)) {
            XCTAssertEqual($0 as? ExecutionBlockError, .notJSONObject)
        }
        XCTAssertThrowsError(try ExecutionBlockCodec.encode(block(), into: "not json")) {
            XCTAssertEqual($0 as? ExecutionBlockError, .notJSONObject)
        }
    }

    func testDecodeRejectsNewerVersion() {
        let ctx = #"{"flight_deck":{"execution":{"v":2,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}}}}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx), .failure(.unsupportedVersion(2)))
    }

    func testDecodeNamesEachMissingOrInvalidField() {
        func ctx(_ exec: String) -> String { #"{"flight_deck":{"execution":"# + exec + "}}" }
        let src = #""source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"}"#
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"kind":"k"}"#)), .failure(.missingField("v")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.missingField("kind")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"","harness":"h","model":"m","pool":"p","# + src + "}")),
                       .failure(.invalidField("kind", "empty")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","knobs":{"effort":3},"# + src + "}")),
                       .failure(.invalidField("knobs", "values must be strings")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#"{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"vibes","reason":"r","at":"2026-10-04T18:00:00Z"}}"#)),
                       .failure(.invalidField("source.by", "unknown value vibes")))
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: ctx(#""oops""#)),
                       .failure(.invalidField("execution", "not an object")))
    }

    func testPinnedAndHostDefault() throws {
        let ctx = #"{"flight_deck":{"execution":{"v":1,"kind":"k","harness":"h","model":"m","pool":"p","source":{"by":"manual","reason":"r","at":"2026-10-04T18:00:00Z"}}}}"#
        let b = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: ctx).get())
        XCTAssertFalse(b.pinned); XCTAssertNil(b.host); XCTAssertEqual(b.knobs, [:])
        XCTAssertEqual(b.modelRef, ModelRef(harness: "h", model: "m", knobs: [:]))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ExecutionBlockCodecTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ExecutionBlock' in scope`.

- [ ] **Step 3: Implement `Identifiers.swift`**

```swift
import Foundation

/// Names an agent harness (`claude`, `codex`, `opencode`, …) by its adapter's raw id.
///
/// A string, not an enum, on purpose: IntakeKit cannot see the app's `AgentID`, and Level 3 must
/// route to any registered adapter — a new adapter becomes routable without touching this type.
public struct HarnessID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// Names a capacity pool (L3-U). A block names a pool, never an account, so rollover never
/// has to rewrite tasks.
public struct PoolID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// Names a task kind in a project's kind registry.
public struct KindID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}
```

- [ ] **Step 4: Implement `ExecutionBlock.swift`**

```swift
import Foundation

/// A model as a harness names it, with the knobs it runs at.
public struct ModelRef: Codable, Hashable, Sendable {
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    public init(harness: HarnessID, model: String, knobs: [String: String] = [:]) {
        self.harness = harness; self.model = model; self.knobs = knobs
    }
}

/// Who chose a block's assignment. `manual` always comes with `pinned`.
public enum AssignmentSourceKind: String, Codable, Sendable, CaseIterable {
    case rule, index, `default`, spill, manual
}

public struct AssignmentSource: Codable, Equatable, Sendable {
    public var by: AssignmentSourceKind
    public var ruleId: String?
    public var reason: String
    public var at: Date
    public init(by: AssignmentSourceKind, ruleId: String? = nil, reason: String, at: Date) {
        self.by = by; self.ruleId = ruleId; self.reason = reason; self.at = at
    }
}

/// How to run one task: stored at `agent_context.flight_deck.execution` on its br task.
///
/// Classification (`kind`) comes from the planning LLM; everything else is a deterministic
/// routing result. `pool` names capacity, not an account — the account is leased at spawn.
public struct ExecutionBlock: Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var kind: KindID
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    public var pool: PoolID
    public var source: AssignmentSource
    /// Set by a manual edit. The router never overwrites a pinned block, and it never spills.
    public var pinned: Bool
    /// Reserved for remote hosts; always nil in v1.
    public var host: String?

    public init(v: Int = ExecutionBlock.currentVersion, kind: KindID, harness: HarnessID, model: String,
                knobs: [String: String] = [:], pool: PoolID, source: AssignmentSource,
                pinned: Bool = false, host: String? = nil) {
        self.v = v; self.kind = kind; self.harness = harness; self.model = model; self.knobs = knobs
        self.pool = pool; self.source = source; self.pinned = pinned; self.host = host
    }

    public var modelRef: ModelRef { ModelRef(harness: harness, model: model, knobs: knobs) }
}
```

- [ ] **Step 5: Implement `ExecutionBlockCodec.swift`**

```swift
import Foundation

public enum ExecutionBlockError: Error, Equatable, Sendable {
    case notJSONObject
    case missingField(String)
    case invalidField(String, String)
    case unsupportedVersion(Int)

    /// The one-line reason shown as "unroutable: <message>".
    public var message: String {
        switch self {
        case .notJSONObject: "agent_context is not a JSON object"
        case .missingField(let f): "missing \(f)"
        case .invalidField(let f, let why): "\(f): \(why)"
        case .unsupportedVersion(let v): "written by a newer Flight Deck (v\(v))"
        }
    }
}

/// Reads and writes the execution block inside br's `agent_context` JSON.
///
/// Hand-rolled over `JSONSerialization` rather than `Codable` so a bad block names the exact
/// field that is wrong, and so writing merges into whatever else `agent_context` holds instead
/// of replacing it — br's governing instructions live in the same field.
public enum ExecutionBlockCodec {
    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }

    public static func decode(agentContext: String?) -> Result<ExecutionBlock?, ExecutionBlockError> {
        guard let text = agentContext, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(nil)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
            return .failure(.notJSONObject)
        }
        guard let fd = root["flight_deck"] as? [String: Any], let raw = fd["execution"] else { return .success(nil) }
        guard let e = raw as? [String: Any] else { return .failure(.invalidField("execution", "not an object")) }

        guard let v = e["v"] as? Int else { return .failure(.missingField("v")) }
        if v > ExecutionBlock.currentVersion { return .failure(.unsupportedVersion(v)) }

        func string(_ key: String) -> Result<String, ExecutionBlockError> {
            guard let value = e[key] else { return .failure(.missingField(key)) }
            guard let s = value as? String else { return .failure(.invalidField(key, "not a string")) }
            return s.isEmpty ? .failure(.invalidField(key, "empty")) : .success(s)
        }
        let kind: String, harness: String, model: String, pool: String
        switch string("kind") { case .success(let s): kind = s; case .failure(let x): return .failure(x) }
        switch string("harness") { case .success(let s): harness = s; case .failure(let x): return .failure(x) }
        switch string("model") { case .success(let s): model = s; case .failure(let x): return .failure(x) }
        switch string("pool") { case .success(let s): pool = s; case .failure(let x): return .failure(x) }

        var knobs: [String: String] = [:]
        if let rawKnobs = e["knobs"], !(rawKnobs is NSNull) {
            guard let dict = rawKnobs as? [String: Any] else { return .failure(.invalidField("knobs", "not an object")) }
            for (k, value) in dict {
                guard let s = value as? String else { return .failure(.invalidField("knobs", "values must be strings")) }
                knobs[k] = s
            }
        }

        guard let s = e["source"] else { return .failure(.missingField("source")) }
        guard let src = s as? [String: Any] else { return .failure(.invalidField("source", "not an object")) }
        guard let byRaw = src["by"] as? String else { return .failure(.missingField("source.by")) }
        guard let by = AssignmentSourceKind(rawValue: byRaw) else {
            return .failure(.invalidField("source.by", "unknown value \(byRaw)"))
        }
        guard let reason = src["reason"] as? String else { return .failure(.missingField("source.reason")) }
        guard let atRaw = src["at"] as? String else { return .failure(.missingField("source.at")) }
        guard let at = iso().date(from: atRaw) else { return .failure(.invalidField("source.at", "not ISO 8601")) }
        let ruleId = src["ruleId"] as? String

        let pinned: Bool
        if let p = e["pinned"], !(p is NSNull) {
            guard let b = p as? Bool else { return .failure(.invalidField("pinned", "not a boolean")) }
            pinned = b
        } else { pinned = false }
        let host = e["host"] as? String

        return .success(ExecutionBlock(v: v, kind: KindID(kind), harness: HarnessID(harness), model: model,
                                       knobs: knobs, pool: PoolID(pool),
                                       source: AssignmentSource(by: by, ruleId: ruleId, reason: reason, at: at),
                                       pinned: pinned, host: host))
    }

    /// The block as a JSON-ready dictionary — exposed so `br --agent-context` callers and
    /// fixtures build the exact same shape.
    public static func dictionary(_ b: ExecutionBlock) -> [String: Any] {
        var source: [String: Any] = ["by": b.source.by.rawValue, "reason": b.source.reason,
                                     "at": iso().string(from: b.source.at)]
        if let r = b.source.ruleId { source["ruleId"] = r }
        return ["v": b.v, "kind": b.kind.rawValue, "harness": b.harness.rawValue, "model": b.model,
                "knobs": b.knobs, "pool": b.pool.rawValue, "source": source, "pinned": b.pinned,
                "host": b.host as Any? ?? NSNull()]
    }

    /// Writes `block` into `agentContext`, keeping every other key. Throws `.notJSONObject`
    /// rather than overwrite a context that is not a JSON object — another tool owns it.
    public static func encode(_ block: ExecutionBlock, into agentContext: String?) throws -> String {
        var root: [String: Any] = [:]
        if let text = agentContext, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
                throw ExecutionBlockError.notJSONObject
            }
            root = obj
        }
        var fd = root["flight_deck"] as? [String: Any] ?? [:]
        fd["execution"] = dictionary(block)
        root["flight_deck"] = fd
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=ExecutionBlockCodecTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed N tests, with 0 failures` and no `error:` lines.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Identifiers.swift Sources/IntakeKit/FlightControl/ExecutionBlock.swift Sources/IntakeKit/FlightControl/ExecutionBlockCodec.swift Tests/FlightDeckTests/FlightControlL3/ExecutionBlockCodecTests.swift
git commit -m "feat: add the level 3 execution block and its agent_context codec" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Dimensions, task kinds, resolution and the seed set

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Dimensions.swift`
- Create: `Sources/IntakeKit/FlightControl/TaskKind.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/TaskKindTests.swift`

**Interfaces:**
- Consumes: `KindID` (Task 1).
- Produces:
  - `public struct Dimension: Codable, Hashable, Sendable { id: String; summary: String }`
  - `public enum Dimensions { static let all: [Dimension]; static let ids: Set<String>; static func isKnown(_:) -> Bool }`
  - `public enum KindOrigin: String { seed, planning, user }`
  - `public enum KindStatus: Equatable, Sendable, Codable { active, proposed, merged(into: KindID) }` — coded as `"active"`, `"proposed"`, `"merged:<id>"`
  - `public struct TaskKind: Codable, Equatable, Sendable, Identifiable { id: KindID; name; description; dimensions: [String: Double]; origin; status; createdAt: Date }`
  - `public enum KindValidationError: Error, Equatable { unknownDimension(String), weightOutOfRange(String, Double), emptyName }`
  - `TaskKind.validate() throws`
  - `public enum KindResolution { static func resolve(_ id: KindID, in kinds: [TaskKind]) -> TaskKind? }`
  - `public enum SeedKinds { static func all(createdAt: Date) -> [TaskKind] }`
  - `public struct KindRegistryFile: Codable, Equatable, Sendable { v: Int; kinds: [TaskKind] }` — the `.flightdeck/kinds.json` shape
  - `public static func KindID.normalized(_ name: String) -> KindID` — lowercase, runs of non-alphanumerics → single `-`, trimmed

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Kinds are dynamic per project, so the only fixed ground is the dimension list. These tests
/// pin what routing relies on: weights only ever name real dimensions, merges always resolve
/// (even when someone builds a cycle), and the seed set is valid on its own.
final class TaskKindTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func kind(_ id: KindID, _ dims: [String: Double] = ["agentic-coding": 0.5],
                      status: KindStatus = .active) -> TaskKind {
        TaskKind(id: id, name: id.rawValue, description: "d", dimensions: dims, origin: .user, status: status, createdAt: at)
    }

    func testDimensionListIsTheSpecsTen() {
        XCTAssertEqual(Dimensions.all.map(\.id), [
            "agentic-coding", "algorithmic-reasoning", "test-authoring", "frontend-ui",
            "large-context-refactor", "debugging", "docs-prose", "tool-use-reliability",
            "speed", "cost-efficiency"])
    }

    func testValidateRejectsUnknownDimensionAndOutOfRangeWeight() {
        XCTAssertThrowsError(try kind("a", ["vibes": 0.5]).validate()) {
            XCTAssertEqual($0 as? KindValidationError, .unknownDimension("vibes"))
        }
        XCTAssertThrowsError(try kind("a", ["debugging": 1.5]).validate()) {
            XCTAssertEqual($0 as? KindValidationError, .weightOutOfRange("debugging", 1.5))
        }
        var unnamed = kind("a"); unnamed.name = "  "
        XCTAssertThrowsError(try unnamed.validate()) { XCTAssertEqual($0 as? KindValidationError, .emptyName) }
    }

    func testStatusCodesAsSpecStrings() throws {
        let k = kind("snap", status: .merged(into: "tests"))
        let data = try JSONEncoder().encode(k)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "merged:tests")
        XCTAssertEqual(try JSONDecoder().decode(TaskKind.self, from: data), k)
    }

    func testResolveFollowsMergeChain() {
        let kinds = [kind("a", status: .merged(into: "b")), kind("b", status: .merged(into: "c")), kind("c")]
        XCTAssertEqual(KindResolution.resolve("a", in: kinds)?.id, "c")
        XCTAssertEqual(KindResolution.resolve("c", in: kinds)?.id, "c")
        XCTAssertNil(KindResolution.resolve("missing", in: kinds))
    }

    func testResolveTerminatesOnMergeCycle() {
        let kinds = [kind("a", status: .merged(into: "b")), kind("b", status: .merged(into: "a"))]
        XCTAssertNil(KindResolution.resolve("a", in: kinds))
    }

    func testSeedSetIsValidAndNamed() throws {
        let seeds = SeedKinds.all(createdAt: at)
        XCTAssertEqual(seeds.map(\.id.rawValue), ["implement-simple", "implement-complex", "algorithm", "tests",
                                                  "refactor", "docs", "investigate", "review", "ui"])
        for s in seeds { XCTAssertNoThrow(try s.validate()); XCTAssertEqual(s.origin, .seed) }
    }

    func testNormalizedKindID() {
        XCTAssertEqual(KindID.normalized("  Snapshot Tests!! "), "snapshot-tests")
        XCTAssertEqual(KindID.normalized("UI/UX work"), "ui-ux-work")
    }

    func testRegistryFileRoundTrips() throws {
        let file = KindRegistryFile(v: 1, kinds: SeedKinds.all(createdAt: at))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(KindRegistryFile.self, from: enc.encode(file)), file)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=TaskKindTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'TaskKind' in scope`.

- [ ] **Step 3: Implement `Dimensions.swift`**

```swift
import Foundation

/// One axis benchmarks measure. Kinds are dynamic per project; dimensions are the stable ground
/// they are weighted against, so a rule compiled to a dimension routes kinds that did not exist
/// when it was written. L3-I owns changes to this list.
public struct Dimension: Codable, Hashable, Sendable {
    public var id: String
    public var summary: String
    public init(id: String, summary: String) { self.id = id; self.summary = summary }
}

public enum Dimensions {
    public static let all: [Dimension] = [
        Dimension(id: "agentic-coding", summary: "multi-step repo tasks end to end"),
        Dimension(id: "algorithmic-reasoning", summary: "hard algorithm and competitive-programming problems"),
        Dimension(id: "test-authoring", summary: "writing tests that are correct and catch bugs"),
        Dimension(id: "frontend-ui", summary: "web and UI work"),
        Dimension(id: "large-context-refactor", summary: "changes across many files and long context"),
        Dimension(id: "debugging", summary: "finding and fixing a failure from evidence"),
        Dimension(id: "docs-prose", summary: "technical writing"),
        Dimension(id: "tool-use-reliability", summary: "correct tool calls and terminal use"),
        Dimension(id: "speed", summary: "output tokens per second and time to first token"),
        Dimension(id: "cost-efficiency", summary: "inverse of cost per task"),
    ]
    public static let ids: Set<String> = Set(all.map(\.id))
    public static func isKnown(_ id: String) -> Bool { ids.contains(id) }
}
```

- [ ] **Step 4: Implement `TaskKind.swift`**

```swift
import Foundation

public enum KindOrigin: String, Codable, Sendable { case seed, planning, user }

/// `merged` keeps the old id resolvable, so merging two kinds never rewrites a task.
public enum KindStatus: Equatable, Sendable, Codable {
    case active, proposed, merged(into: KindID)

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s {
        case "active": self = .active
        case "proposed": self = .proposed
        case _ where s.hasPrefix("merged:") && s.count > 7: self = .merged(into: KindID(String(s.dropFirst(7))))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown kind status \(s)"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .active: try c.encode("active")
        case .proposed: try c.encode("proposed")
        case .merged(let id): try c.encode("merged:\(id.rawValue)")
        }
    }
}

public enum KindValidationError: Error, Equatable, Sendable {
    case unknownDimension(String), weightOutOfRange(String, Double), emptyName
}

public struct TaskKind: Codable, Equatable, Sendable, Identifiable {
    public var id: KindID
    public var name: String
    public var description: String
    /// Dimension id → weight in 0...1. Missing dimensions weigh 0.
    public var dimensions: [String: Double]
    public var origin: KindOrigin
    public var status: KindStatus
    public var createdAt: Date

    public init(id: KindID, name: String, description: String, dimensions: [String: Double],
                origin: KindOrigin, status: KindStatus = .active, createdAt: Date) {
        self.id = id; self.name = name; self.description = description; self.dimensions = dimensions
        self.origin = origin; self.status = status; self.createdAt = createdAt
    }

    public func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw KindValidationError.emptyName }
        for (dim, w) in dimensions.sorted(by: { $0.key < $1.key }) {
            guard Dimensions.isKnown(dim) else { throw KindValidationError.unknownDimension(dim) }
            guard (0...1).contains(w) else { throw KindValidationError.weightOutOfRange(dim, w) }
        }
    }
}

extension KindID {
    /// The id a proposed kind name maps to, so "Snapshot Tests" and "snapshot-tests" are one kind.
    public static func normalized(_ name: String) -> KindID {
        var out = ""; var pendingDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.append(ch); pendingDash = false
            } else { pendingDash = true }
        }
        return KindID(out)
    }
}

public enum KindResolution {
    /// Follows `merged:` links to the live kind. Bounded by the registry size, so a cycle
    /// resolves to nil instead of spinning.
    public static func resolve(_ id: KindID, in kinds: [TaskKind]) -> TaskKind? {
        var current = id
        for _ in 0...kinds.count {
            guard let k = kinds.first(where: { $0.id == current }) else { return nil }
            guard case .merged(let next) = k.status else { return k }
            current = next
        }
        return nil
    }
}

/// `.flightdeck/kinds.json`.
public struct KindRegistryFile: Codable, Equatable, Sendable {
    public var v: Int
    public var kinds: [TaskKind]
    public init(v: Int = 1, kinds: [TaskKind]) { self.v = v; self.kinds = kinds }
}

public enum SeedKinds {
    public static func all(createdAt: Date) -> [TaskKind] {
        func k(_ id: String, _ name: String, _ d: String, _ w: [String: Double]) -> TaskKind {
            TaskKind(id: KindID(id), name: name, description: d, dimensions: w, origin: .seed, createdAt: createdAt)
        }
        return [
            k("implement-simple", "Simple implementation", "Small, well-specified code changes",
              ["agentic-coding": 0.5, "speed": 0.5, "cost-efficiency": 0.6]),
            k("implement-complex", "Complex implementation", "Multi-file features with design judgment",
              ["agentic-coding": 0.9, "large-context-refactor": 0.5, "tool-use-reliability": 0.5]),
            k("algorithm", "Algorithm", "Non-trivial algorithms and data structures",
              ["algorithmic-reasoning": 0.9, "agentic-coding": 0.3]),
            k("tests", "Tests", "Unit and integration tests",
              ["test-authoring": 0.9, "agentic-coding": 0.4]),
            k("refactor", "Refactor", "Behavior-preserving restructuring",
              ["large-context-refactor": 0.9, "agentic-coding": 0.5]),
            k("docs", "Docs", "Documentation and prose",
              ["docs-prose": 0.9, "cost-efficiency": 0.4]),
            k("investigate", "Investigate", "Find a root cause from evidence",
              ["debugging": 0.9, "tool-use-reliability": 0.5]),
            k("review", "Review", "Review code or a plan for defects",
              ["debugging": 0.6, "large-context-refactor": 0.5, "algorithmic-reasoning": 0.4]),
            k("ui", "UI", "User-interface work",
              ["frontend-ui": 0.9, "agentic-coding": 0.4]),
        ]
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=TaskKindTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed N tests, with 0 failures` and no `error:` lines.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Dimensions.swift Sources/IntakeKit/FlightControl/TaskKind.swift Tests/FlightDeckTests/FlightControlL3/TaskKindTests.swift
git commit -m "feat: add capability dimensions and dynamic task kinds with merge resolution" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Contract values and protocols, with fakes

**Files:**
- Create: `Sources/IntakeKit/FlightControl/ContractValues.swift`
- Create: `Sources/IntakeKit/FlightControl/ContractProtocols.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Fakes/ContractFakes.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/ContractValuesTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces (all `public`, `Sendable`):
  - `ModelEntry { id: String; displayName: String; knobs: [String] }` (Codable, Hashable)
  - `AdapterCatalog { harness: HarnessID; models: [ModelEntry]; knobSchema: [String: [String]]; defaultModel: String?; enabled: Bool }`
  - `AdapterCatalogs { byHarness: [HarnessID: AdapterCatalog]; init(_ catalogs: [AdapterCatalog]); func contains(_ ref: ModelRef) -> Bool; func knobsValid(_ ref: ModelRef) -> Bool; var enabledModels: [ModelRef] }`
  - `Assignment { block: ExecutionBlock }`
  - `ScoredModel { model: ModelRef; score: Double; confidence: Double }`
  - `HeadroomState: String { underSoft, overSoft, overHard, unknown }`
  - `AccountRef { harness: HarnessID; id: UUID?; label: String }` (Codable, Hashable; `id == nil` is a local-pool slot)
  - `AccountHeadroom { account: AccountRef; worstUtilization: Double?; state: HeadroomState; resetsAt: Date? }`
  - `AccountLease { id: UUID; pool: PoolID; account: AccountRef }` (Hashable)
  - `UsageWindow { name: String; utilization: Double; resetsAt: Date? }` (Codable)
  - `UsageReading { account: AccountRef; windows: [UsageWindow]; readAt: Date; source: String; hardRejection: Bool; var worstWindow: UsageWindow? }` (Codable)
  - `TranscriptPointer { enum Locator: Codable, Equatable, Sendable { path(String), command(String) }; locator; format: String; howToRead: String }`
  - `TaskRef { id: String; project: URL }`, `SessionRef { id: UUID; agentName: String? }` (Codable, Hashable)
  - `SwarmAgentSnapshot { session: SessionRef; agentName: String; block: ExecutionBlock; lease: AccountLease?; task: TaskRef? }`
  - `HandoffRequest { task: TaskRef; block: ExecutionBlock; oldAgent: String; oldSession: SessionRef; transcript: TranscriptPointer?; reservedFiles: [String]; fromAccount: AccountRef }`
  - `SpawnError: Error, Equatable { launchFailed(String), composerTimeout, unsupportedHarness(HarnessID), claimConflict(String) }`
  - protocols `KindRegistry`, `Router`, `CapabilityIndex`, `CapacityReader`, `PoolAllocator`, `HandoffPlanner`, `UsageMeterSource` exactly as in Step 4.
  - Test fakes: `FakeKindRegistry`, `FakeRouter`, `FakeCapabilityIndex`, `FakeCapacityReader`, `FakePoolAllocator`, `FakeHandoffPlanner`, `FakeUsageMeterSource`, each `final class … @unchecked Sendable` with an `NSLock`, scriptable `var` results and a `calls` log.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The contract's value types carry the few rules every branch must agree on: what counts as
/// an account's worst window, which models a catalog admits, and that each fake really stands
/// in for its protocol. Each later branch tests against these fakes, so a fake that silently
/// ignored its script would make four branches' tests lie at once.
final class ContractValuesTests: XCTestCase {
    func testWorstWindowIsHighestUtilization() {
        let r = UsageReading(account: AccountRef(harness: "claude", id: UUID(), label: "Work"),
                             windows: [UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: nil),
                                       UsageWindow(name: "seven_day", utilization: 0.91, resetsAt: nil)],
                             readAt: Date(), source: "test", hardRejection: false)
        XCTAssertEqual(r.worstWindow?.name, "seven_day")
        XCTAssertNil(UsageReading(account: r.account, windows: [], readAt: Date(), source: "t", hardRejection: false).worstWindow)
    }

    func testCatalogsAdmitOnlyKnownModelsAndKnobs() {
        let cats = AdapterCatalogs([AdapterCatalog(harness: "codex",
            models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6 Sol", knobs: ["effort"])],
            knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true)])
        XCTAssertTrue(cats.contains(ModelRef(harness: "codex", model: "gpt-6-sol")))
        XCTAssertFalse(cats.contains(ModelRef(harness: "codex", model: "nope")))
        XCTAssertFalse(cats.contains(ModelRef(harness: "claude", model: "opus")))
        XCTAssertTrue(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "max"])))
        XCTAssertFalse(cats.knobsValid(ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["agent": "x"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(harness: "codex", model: "gpt-6-sol")])
    }

    func testDisabledCatalogContributesNoModels() {
        let cats = AdapterCatalogs([AdapterCatalog(harness: "opencode", models: [ModelEntry(id: "ollama/q", displayName: "q", knobs: [])],
                                                   knobSchema: [:], defaultModel: nil, enabled: false)])
        XCTAssertEqual(cats.enabledModels, [])
    }

    func testFakesFollowTheirScripts() {
        let alloc = FakePoolAllocator()
        let lease = AccountLease(id: UUID(), pool: "p", account: AccountRef(harness: "codex", id: UUID(), label: "A"))
        alloc.leases["p"] = [lease]
        XCTAssertEqual(alloc.lease(pool: "p"), lease)
        XCTAssertNil(alloc.lease(pool: "p"), "a scripted lease is handed out once")
        alloc.release(lease)
        XCTAssertEqual(alloc.released, [lease])

        let reader = FakeCapacityReader()
        reader.byPool["p"] = [AccountHeadroom(account: lease.account, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)]
        XCTAssertEqual(reader.headroom(pool: "p").first?.state, .overSoft)
        XCTAssertEqual(reader.headroom(pool: "other"), [])
    }

    func testFakeUsageMeterSourceStreamsWhatItIsFed() async {
        let src = FakeUsageMeterSource()
        let reading = UsageReading(account: AccountRef(harness: "claude", id: nil, label: "x"), windows: [],
                                   readAt: Date(timeIntervalSince1970: 1), source: "fake", hardRejection: true)
        src.send(reading); src.finish()
        var got: [UsageReading] = []
        for await r in src.readings { got.append(r) }
        XCTAssertEqual(got, [reading])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ContractValuesTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'UsageReading' in scope`.

- [ ] **Step 3: Implement `ContractValues.swift`**

```swift
import Foundation

public struct ModelEntry: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    /// Knob names this model accepts; values come from the catalog's `knobSchema`.
    public var knobs: [String]
    public init(id: String, displayName: String, knobs: [String]) { self.id = id; self.displayName = displayName; self.knobs = knobs }
}

public struct AdapterCatalog: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var models: [ModelEntry]
    /// Knob name → allowed values, as the adapter declares them.
    public var knobSchema: [String: [String]]
    public var defaultModel: String?
    public var enabled: Bool
    public init(harness: HarnessID, models: [ModelEntry], knobSchema: [String: [String]], defaultModel: String?, enabled: Bool) {
        self.harness = harness; self.models = models; self.knobSchema = knobSchema
        self.defaultModel = defaultModel; self.enabled = enabled
    }
}

public struct AdapterCatalogs: Equatable, Sendable {
    public var byHarness: [HarnessID: AdapterCatalog]
    /// Insertion order, so "ties go to catalog order" (L3-I §6) is stable.
    public var order: [HarnessID]

    public init(_ catalogs: [AdapterCatalog]) {
        byHarness = Dictionary(catalogs.map { ($0.harness, $0) }, uniquingKeysWith: { a, _ in a })
        order = catalogs.map(\.harness)
    }

    public func contains(_ ref: ModelRef) -> Bool {
        byHarness[ref.harness]?.models.contains { $0.id == ref.model } ?? false
    }

    public func knobsValid(_ ref: ModelRef) -> Bool {
        guard let cat = byHarness[ref.harness], let entry = cat.models.first(where: { $0.id == ref.model }) else { return false }
        for (k, v) in ref.knobs {
            guard entry.knobs.contains(k), cat.knobSchema[k]?.contains(v) == true else { return false }
        }
        return true
    }

    public var enabledModels: [ModelRef] {
        order.compactMap { byHarness[$0] }.filter(\.enabled)
            .flatMap { cat in cat.models.map { ModelRef(harness: cat.harness, model: $0.id) } }
    }
}

public struct Assignment: Equatable, Sendable {
    public var block: ExecutionBlock
    public init(block: ExecutionBlock) { self.block = block }
}

public struct ScoredModel: Equatable, Sendable {
    public var model: ModelRef
    public var score: Double
    public var confidence: Double
    public init(model: ModelRef, score: Double, confidence: Double) { self.model = model; self.score = score; self.confidence = confidence }
}

public enum HeadroomState: String, Codable, Sendable { case underSoft, overSoft, overHard, unknown }

/// An account as Level 3 sees it. `id == nil` is a slot in a local pool, which has no account.
public struct AccountRef: Codable, Hashable, Sendable {
    public var harness: HarnessID
    public var id: UUID?
    public var label: String
    public init(harness: HarnessID, id: UUID?, label: String) { self.harness = harness; self.id = id; self.label = label }
}

public struct AccountHeadroom: Equatable, Sendable {
    public var account: AccountRef
    public var worstUtilization: Double?
    public var state: HeadroomState
    public var resetsAt: Date?
    public init(account: AccountRef, worstUtilization: Double?, state: HeadroomState, resetsAt: Date?) {
        self.account = account; self.worstUtilization = worstUtilization; self.state = state; self.resetsAt = resetsAt
    }
}

public struct AccountLease: Hashable, Sendable {
    public var id: UUID
    public var pool: PoolID
    public var account: AccountRef
    public init(id: UUID = UUID(), pool: PoolID, account: AccountRef) { self.id = id; self.pool = pool; self.account = account }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var name: String
    /// 0...1; may exceed 1 on an exceeded spend limit.
    public var utilization: Double
    public var resetsAt: Date?
    public init(name: String, utilization: Double, resetsAt: Date?) { self.name = name; self.utilization = utilization; self.resetsAt = resetsAt }
}

public struct UsageReading: Codable, Equatable, Sendable {
    public var account: AccountRef
    public var windows: [UsageWindow]
    public var readAt: Date
    public var source: String
    /// A real rejection (429, `rate_limit_exceeded`, a non-allowed `rate_limit_event`). It puts
    /// the account over hard whatever its windows say.
    public var hardRejection: Bool
    public init(account: AccountRef, windows: [UsageWindow], readAt: Date, source: String, hardRejection: Bool) {
        self.account = account; self.windows = windows; self.readAt = readAt; self.source = source; self.hardRejection = hardRejection
    }
    public var worstWindow: UsageWindow? { windows.max { $0.utilization < $1.utilization } }
}

public struct TranscriptPointer: Codable, Equatable, Sendable {
    public enum Locator: Codable, Equatable, Sendable { case path(String), command(String) }
    public var locator: Locator
    public var format: String
    public var howToRead: String
    public init(locator: Locator, format: String, howToRead: String) { self.locator = locator; self.format = format; self.howToRead = howToRead }
}

public struct TaskRef: Codable, Hashable, Sendable {
    public var id: String
    public var project: URL
    public init(id: String, project: URL) { self.id = id; self.project = project }
}

public struct SessionRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var agentName: String?
    public init(id: UUID, agentName: String?) { self.id = id; self.agentName = agentName }
}

public struct SwarmAgentSnapshot: Equatable, Sendable {
    public var session: SessionRef
    public var agentName: String
    public var block: ExecutionBlock
    public var lease: AccountLease?
    public var task: TaskRef?
    public init(session: SessionRef, agentName: String, block: ExecutionBlock, lease: AccountLease?, task: TaskRef?) {
        self.session = session; self.agentName = agentName; self.block = block; self.lease = lease; self.task = task
    }
}

public struct HandoffRequest: Equatable, Sendable {
    public var task: TaskRef
    public var block: ExecutionBlock
    public var oldAgent: String
    public var oldSession: SessionRef
    public var transcript: TranscriptPointer?
    public var reservedFiles: [String]
    public var fromAccount: AccountRef
    public init(task: TaskRef, block: ExecutionBlock, oldAgent: String, oldSession: SessionRef,
                transcript: TranscriptPointer?, reservedFiles: [String], fromAccount: AccountRef) {
        self.task = task; self.block = block; self.oldAgent = oldAgent; self.oldSession = oldSession
        self.transcript = transcript; self.reservedFiles = reservedFiles; self.fromAccount = fromAccount
    }
}

public enum SpawnError: Error, Equatable, Sendable {
    case launchFailed(String), composerTimeout, unsupportedHarness(HarnessID), claimConflict(String)
}
```

- [ ] **Step 4: Implement `ContractProtocols.swift`**

```swift
import Foundation

/// The five Level 3 specs meet only here. Each branch implements its own protocols and tests
/// against fakes of the others; integration swaps the fakes for real conformers.

/// Owned by L3-R. Backed by `.flightdeck/kinds.json`.
public protocol KindRegistry: Sendable {
    func kinds(project: URL) throws -> [TaskKind]
    /// Adds a proposal, or returns the existing kind whose id the name normalizes to.
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind
}

/// Owned by L3-R. Pure: no I/O, no clock beyond `now`.
public protocol Router: Sendable {
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment
    /// Re-routes with `exhausted` pools removed, for one spawn. Nil when the block is pinned or
    /// nothing else fits. Never rewrites the stored block.
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment?
}

/// Owned by L3-I.
public protocol CapabilityIndex: Sendable {
    /// Best first. Unknown models are omitted, never scored zero.
    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel]
    var snapshotDate: Date? { get }
}

/// Owned by L3-U.
public protocol CapacityReader: Sendable {
    /// In pool order.
    func headroom(pool: PoolID) -> [AccountHeadroom]
}

/// Owned by L3-U. First account in order under soft, then the first unknown, else nil.
public protocol PoolAllocator: Sendable {
    func lease(pool: PoolID) -> AccountLease?
    func release(_ lease: AccountLease)
}

/// Owned by L3-U. Nil when the agent's account is not over hard.
public protocol HandoffPlanner: Sendable {
    func request(for agent: SwarmAgentSnapshot) -> HandoffRequest?
}

/// Owned by L3-U; one per (adapter, account) or per session, as the adapter provides.
public protocol UsageMeterSource: Sendable {
    var readings: AsyncStream<UsageReading> { get }
}
```

- [ ] **Step 5: Implement `Tests/FlightDeckTests/FlightControlL3/Fakes/ContractFakes.swift`**

```swift
import Foundation
import IntakeKit

/// Scriptable doubles for every Level 3 protocol. Shared by all four parallel branches, so keep
/// them dumb: each returns what it was scripted with and records what it was asked.

final class FakeKindRegistry: KindRegistry, @unchecked Sendable {
    private let lock = NSLock()
    var byProject: [URL: [TaskKind]] = [:]
    private(set) var proposals: [TaskKind] = []
    func kinds(project: URL) throws -> [TaskKind] { lock.withLock { byProject[project] ?? [] } }
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind {
        lock.withLock {
            proposals.append(kind)
            if let existing = byProject[project]?.first(where: { $0.id == kind.id }) { return existing }
            byProject[project, default: []].append(kind)
            return kind
        }
    }
}

final class FakeRouter: Router, @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by kind id. Falls back to `defaultAssignment`.
    var assignments: [KindID: Assignment] = [:]
    var defaultAssignment: Assignment?
    var spills: [KindID: Assignment] = [:]
    private(set) var assignCalls: [KindID] = []
    private(set) var spillCalls: [(KindID, Set<PoolID>)] = []
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        lock.withLock {
            assignCalls.append(kind.id)
            guard let a = assignments[kind.id] ?? defaultAssignment else { fatalError("FakeRouter: no assignment scripted for \(kind.id)") }
            return a
        }
    }
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment? {
        lock.withLock { spillCalls.append((kind.id, exhausted)); return block.pinned ? nil : spills[kind.id] }
    }
}

final class FakeCapabilityIndex: CapabilityIndex, @unchecked Sendable {
    private let lock = NSLock()
    var scores: [ModelRef: ScoredModel] = [:]
    var snapshotDate: Date?
    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] {
        lock.withLock { candidates.compactMap { scores[$0] }.sorted { $0.score > $1.score } }
    }
}

final class FakeCapacityReader: CapacityReader, @unchecked Sendable {
    private let lock = NSLock()
    var byPool: [PoolID: [AccountHeadroom]] = [:]
    func headroom(pool: PoolID) -> [AccountHeadroom] { lock.withLock { byPool[pool] ?? [] } }
}

final class FakePoolAllocator: PoolAllocator, @unchecked Sendable {
    private let lock = NSLock()
    /// Each scripted lease is handed out once, in order.
    var leases: [PoolID: [AccountLease]] = [:]
    private(set) var released: [AccountLease] = []
    private(set) var leaseCalls: [PoolID] = []
    func lease(pool: PoolID) -> AccountLease? {
        lock.withLock {
            leaseCalls.append(pool)
            guard var queue = leases[pool], !queue.isEmpty else { return nil }
            let l = queue.removeFirst(); leases[pool] = queue; return l
        }
    }
    func release(_ lease: AccountLease) { lock.withLock { released.append(lease) } }
}

final class FakeHandoffPlanner: HandoffPlanner, @unchecked Sendable {
    private let lock = NSLock()
    var requests: [UUID: HandoffRequest] = [:]
    func request(for agent: SwarmAgentSnapshot) -> HandoffRequest? { lock.withLock { requests[agent.session.id] } }
}

final class FakeUsageMeterSource: UsageMeterSource, @unchecked Sendable {
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation
    init() { (readings, continuation) = AsyncStream.makeStream(of: UsageReading.self) }
    func send(_ r: UsageReading) { continuation.yield(r) }
    func finish() { continuation.finish() }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=ContractValuesTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed N tests, with 0 failures` and no `error:` lines.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/ContractValues.swift Sources/IntakeKit/FlightControl/ContractProtocols.swift Tests/FlightDeckTests/FlightControlL3/Fakes/ContractFakes.swift Tests/FlightDeckTests/FlightControlL3/ContractValuesTests.swift
git commit -m "feat: add the level 3 contract protocols, values and shared fakes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Adapter routing capabilities, registry and the spawner protocol

**Files:**
- Create: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Fakes/FakeRoutingCapabilities.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift`

**Interfaces:**
- Consumes: Task 3 values; app types `Session`, `AgentOptions`, `AgentAccount`, `AgentID` (`Sources/FlightDeck/Agents/AgentKind.swift:6`, `:89`; `Agents/AgentAccount.swift:45`).
- Produces:
  - `enum RoutingCapability<Value> { case supported(Value), unsupported(reason: String); var value: Value? }`
  - `enum AccountModel: String, Sendable { case login, providerKeys, none }`
  - `struct LaunchOverrides: Equatable, Sendable { var model: String?; var knobs: [String: String] }`
  - `@MainActor protocol AgentRoutingCapabilities: AnyObject` with: `var harness: HarnessID`, `func modelCatalog() async -> RoutingCapability<[ModelEntry]>`, `var knobSchema: [String: [String]]`, `var accountModel: AccountModel`, `func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource>`, `func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer>`, `func resetContext(_ session: Session) async throws -> RoutingCapability<Void>`, `func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions>`
  - `@MainActor final class RoutingCapabilityRegistry { init(_ entries: [any AgentRoutingCapabilities]); func capabilities(for: HarnessID) -> (any AgentRoutingCapabilities)?; var harnesses: [HarnessID]; func catalogs(enabled: Set<HarnessID>) async -> AdapterCatalogs; static func standard() -> RoutingCapabilityRegistry }`
  - `extension AgentID { var harnessID: HarnessID }`
  - `final class ClaudeRoutingCapabilities`, `final class CodexRoutingCapabilities` — `accountModel = .login`, everything else `.unsupported(reason: "filled in by L3-R/L3-U/L3-S")`, `knobSchema = [:]`
  - `@MainActor protocol SwarmSpawner { func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> }`
  - Test fakes: `FakeRoutingCapabilities` (harness `"fake"`, scriptable catalog/pointer/reset, records calls) and `FakeSwarmSpawner` (scriptable results, records calls).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// "Harness is any registered adapter" is only true if nothing between a block and a spawn
/// knows the adapter list. These tests register a third, fake harness and route it end to end
/// through the registry — the same path claude and codex take.
@MainActor
final class RoutingCapabilityRegistryTests: XCTestCase {
    func testStandardRegistryHasEveryAgentID() {
        let reg = RoutingCapabilityRegistry.standard()
        XCTAssertEqual(Set(reg.harnesses), Set(AgentID.allCases.map(\.harnessID)))
        XCTAssertEqual(reg.capabilities(for: "claude")?.accountModel, .login)
        XCTAssertNil(reg.capabilities(for: "nope"))
    }

    func testAFakeHarnessIsRoutableThroughTheRegistry() async {
        let fake = FakeRoutingCapabilities()
        fake.catalog = .supported([ModelEntry(id: "fake-1", displayName: "Fake One", knobs: ["mode"])])
        fake.knobSchema = ["mode": ["fast", "slow"]]
        let reg = RoutingCapabilityRegistry([fake])
        let cats = await reg.catalogs(enabled: ["fake"])
        XCTAssertTrue(cats.contains(ModelRef(harness: "fake", model: "fake-1")))
        XCTAssertTrue(cats.knobsValid(ModelRef(harness: "fake", model: "fake-1", knobs: ["mode": "fast"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(harness: "fake", model: "fake-1")])
    }

    func testUnsupportedCatalogYieldsAnEmptyDisabledCatalog() async {
        let reg = RoutingCapabilityRegistry.standard()
        let cats = await reg.catalogs(enabled: ["claude", "codex"])
        XCTAssertEqual(cats.byHarness["claude"]?.models, [])
        XCTAssertEqual(cats.enabledModels, [], "a stub conformer must never pretend to have models")
    }

    func testStubsSayUnsupportedRatherThanFake() {
        for h in AgentID.allCases.map(\.harnessID) {
            let caps = RoutingCapabilityRegistry.standard().capabilities(for: h)!
            if case .supported = caps.applying(LaunchOverrides(model: "x", knobs: [:]), to: .codex(.init())) {
                XCTFail("\(h) stub claimed launch overrides")
            }
        }
    }

    func testFakeSpawnerRecordsAndReturnsScript() async {
        let spawner = FakeSwarmSpawner()
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        spawner.results = [.success(ref)]
        let block = ExecutionBlock(kind: "tests", harness: "fake", model: "fake-1", pool: "p",
                                   source: AssignmentSource(by: .rule, reason: "r", at: Date()))
        let r = await spawner.spawn(task: TaskRef(id: "t1", project: URL(fileURLWithPath: "/p")), block: block,
                                    lease: nil, firstPrompt: "Your task is t1")
        XCTAssertEqual(r, .success(ref))
        XCTAssertEqual(spawner.calls.map(\.firstPrompt), ["Your task is t1"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingCapabilityRegistryTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RoutingCapabilityRegistry' in scope`.

- [ ] **Step 3: Implement `AgentRoutingCapabilities.swift`**

```swift
import Foundation
import IntakeKit

/// An adapter's answer to one Level 3 question: the value, or an explicit "can't". Never a
/// made-up value — a stub that returned an empty-but-supported answer would let routing think an
/// adapter has no models rather than that nobody asked it yet.
enum RoutingCapability<Value> {
    case supported(Value)
    case unsupported(reason: String)
    var value: Value? { if case .supported(let v) = self { v } else { nil } }
}

/// How an adapter's capacity is owned. `.none` is a local provider: no account, so no rollover —
/// its limit is concurrency (L3-U local pools).
enum AccountModel: String, Sendable { case login, providerKeys, none }

/// The model and knobs a spawn asks for, on top of the agent's preferences.
struct LaunchOverrides: Equatable, Sendable {
    var model: String?
    var knobs: [String: String]
}

/// What routing, rollover and the swarm need from an agent. Separate from `AgentAdapter`
/// because adapters are built per account (`SessionStore.makeClaudeAdapter(account:)`), while
/// these answers are per agent; session-specific calls take the `Session`.
@MainActor
protocol AgentRoutingCapabilities: AnyObject {
    var harness: HarnessID { get }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]>
    var knobSchema: [String: [String]] { get }
    var accountModel: AccountModel { get }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource>
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer>
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void>
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions>
}

extension AgentID {
    var harnessID: HarnessID { HarnessID(rawValue) }
}

@MainActor
final class RoutingCapabilityRegistry {
    private var entries: [HarnessID: any AgentRoutingCapabilities] = [:]
    private(set) var harnesses: [HarnessID] = []

    init(_ list: [any AgentRoutingCapabilities]) {
        for e in list where entries[e.harness] == nil {
            entries[e.harness] = e
            harnesses.append(e.harness)
        }
    }

    func capabilities(for harness: HarnessID) -> (any AgentRoutingCapabilities)? { entries[harness] }

    /// Every registered harness's catalog. A harness outside `enabled`, or one whose catalog is
    /// unsupported, contributes a disabled, empty catalog — present, so validation can say
    /// "codex is disabled" instead of "codex does not exist".
    func catalogs(enabled: Set<HarnessID>) async -> AdapterCatalogs {
        var out: [AdapterCatalog] = []
        for h in harnesses {
            guard let caps = entries[h] else { continue }
            let models = await caps.modelCatalog().value
            out.append(AdapterCatalog(harness: h, models: models ?? [], knobSchema: caps.knobSchema,
                                      defaultModel: models?.first?.id,
                                      enabled: enabled.contains(h) && models != nil))
        }
        return AdapterCatalogs(out)
    }

    /// One conformer per `AgentID`. The `switch` is exhaustive on purpose: a new `AgentID` case
    /// (the OpenCode branch adds `.opencode`) fails to compile here until it states its answers.
    static func standard() -> RoutingCapabilityRegistry {
        RoutingCapabilityRegistry(AgentID.allCases.map { id -> any AgentRoutingCapabilities in
            switch id {
            case .claude: ClaudeRoutingCapabilities()
            case .codex: CodexRoutingCapabilities()
            }
        })
    }
}

/// Stubs until L3-R (catalog, knobs, overrides), L3-U (meter, transcript) and L3-S (reset) fill
/// them in. Each says "unsupported" with the spec that owns it.
@MainActor
final class ClaudeRoutingCapabilities: AgentRoutingCapabilities {
    let harness: HarnessID = AgentID.claude.harnessID
    let accountModel: AccountModel = .login
    var knobSchema: [String: [String]] { [:] }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: "filled in by L3-R") }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { .unsupported(reason: "filled in by L3-U") }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { .unsupported(reason: "filled in by L3-U") }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: "filled in by L3-S") }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: "filled in by L3-S") }
}

@MainActor
final class CodexRoutingCapabilities: AgentRoutingCapabilities {
    let harness: HarnessID = AgentID.codex.harnessID
    let accountModel: AccountModel = .login
    var knobSchema: [String: [String]] { [:] }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: "filled in by L3-R") }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { .unsupported(reason: "filled in by L3-U") }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { .unsupported(reason: "filled in by L3-U") }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: "filled in by L3-S") }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: "filled in by L3-S") }
}

/// Owned by L3-S. Spawns (or the caller reuses) an agent for `task` and submits `firstPrompt`
/// once its composer is ready. L3-U's hand-off calls it with the hand-off prompt.
@MainActor
protocol SwarmSpawner: AnyObject {
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError>
}
```

- [ ] **Step 4: Implement `Tests/FlightDeckTests/FlightControlL3/Fakes/FakeRoutingCapabilities.swift`**

```swift
import Foundation
import IntakeKit
@testable import FlightDeck

/// A third harness, `"fake"`, so "any registered adapter" is exercised from day one without
/// adding an `AgentID` case (which would touch every exhaustive switch in the app).
@MainActor
final class FakeRoutingCapabilities: AgentRoutingCapabilities {
    var harness: HarnessID = "fake"
    var accountModel: AccountModel = .login
    var knobSchema: [String: [String]] = [:]
    var catalog: RoutingCapability<[ModelEntry]> = .supported([])
    var meter: RoutingCapability<any UsageMeterSource> = .unsupported(reason: "fake")
    var pointer: RoutingCapability<TranscriptPointer> = .unsupported(reason: "fake")
    var resetResult: Result<RoutingCapability<Void>, Error> = .success(.supported(()))
    var overridesResult: RoutingCapability<AgentOptions>?
    private(set) var resetCalls: [UUID] = []
    private(set) var overrideCalls: [LaunchOverrides] = []

    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { catalog }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { meter }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { pointer }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        resetCalls.append(session.id); return try resetResult.get()
    }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        overrideCalls.append(overrides); return overridesResult ?? .supported(options)
    }
}

@MainActor
final class FakeSwarmSpawner: SwarmSpawner {
    struct Call: Equatable { let task: TaskRef; let block: ExecutionBlock; let lease: AccountLease?; let firstPrompt: String }
    /// Consumed in order; when empty, spawns fail with `.launchFailed("unscripted")`.
    var results: [Result<SessionRef, SpawnError>] = []
    private(set) var calls: [Call] = []
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        calls.append(Call(task: task, block: block, lease: lease, firstPrompt: firstPrompt))
        return results.isEmpty ? .failure(.launchFailed("unscripted")) : results.removeFirst()
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingCapabilityRegistryTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed N tests, with 0 failures` and no `error:` lines.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift Tests/FlightDeckTests/FlightControlL3/Fakes/FakeRoutingCapabilities.swift Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift
git commit -m "feat: route level 3 work to any registered adapter through a capability registry" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Shared fixtures and the live br round-trip

**Files:**
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/br-list-with-blocks.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/kinds.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/usage-timeline.json`
- Create: `Tests/FlightDeckTests/FlightControlL3/L3Fixtures.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/L3FixtureTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/ExecutionBlockLiveTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `enum L3Fixtures { static func data(_ name: String) throws -> Data; static func brRows() throws -> [[String: Any]]; static func kinds() throws -> KindRegistryFile; static func usageTimeline() throws -> [UsageReading] }`. Fixture ids that later branches assert on: tasks `fx-valid`, `fx-pinned`, `fx-invalid`, `fx-none`, `fx-newer`; kinds `tests`, `snapshot-tests` (planning, active), `golden-tests` (merged:snapshot-tests); usage timeline for account `11111111-1111-1111-1111-111111111111` crossing 0.5 → 0.82 → 0.96 → hard rejection → reset 0.05.

- [ ] **Step 1: Write the fixtures**

`br-list-with-blocks.json` — five rows in `br list --json`'s envelope `{"issues":[…],"total":N}` (probed on br 0.6.0; `br ready --json` and `br show --json` return bare arrays):

```json
{"total":5,"issues":[
 {"id":"fx-valid","title":"Add snapshot tests for the parser","status":"open","priority":1,"issue_type":"task","labels":[],"created_at":"2026-10-04T18:00:00Z","updated_at":"2026-10-04T18:00:00Z",
  "agent_context":"{\"flight_deck\":{\"execution\":{\"harness\":\"codex\",\"host\":null,\"kind\":\"snapshot-tests\",\"knobs\":{\"effort\":\"high\"},\"model\":\"gpt-6-sol\",\"pinned\":false,\"pool\":\"codex-subs\",\"source\":{\"at\":\"2026-10-04T18:00:00Z\",\"by\":\"rule\",\"reason\":\"test-authoring 0.8 → codex\",\"ruleId\":\"r3\"},\"v\":1}},\"instructions\":\"keep\"}"},
 {"id":"fx-pinned","title":"Rewrite the scheduler","status":"open","priority":2,"issue_type":"task","labels":[],"created_at":"2026-10-04T18:00:00Z","updated_at":"2026-10-04T18:00:00Z",
  "agent_context":"{\"flight_deck\":{\"execution\":{\"harness\":\"claude\",\"kind\":\"algorithm\",\"knobs\":{\"effort\":\"high\"},\"model\":\"opus\",\"pinned\":true,\"pool\":\"claude-subs\",\"source\":{\"at\":\"2026-10-04T18:00:00Z\",\"by\":\"manual\",\"reason\":\"pinned by the maintainer\"},\"v\":1}}}"},
 {"id":"fx-invalid","title":"Broken block","status":"open","priority":2,"issue_type":"task","labels":[],"created_at":"2026-10-04T18:00:00Z","updated_at":"2026-10-04T18:00:00Z",
  "agent_context":"{\"flight_deck\":{\"execution\":{\"v\":1,\"kind\":\"tests\",\"harness\":\"codex\",\"pool\":\"codex-subs\",\"source\":{\"by\":\"rule\",\"reason\":\"r\",\"at\":\"2026-10-04T18:00:00Z\"}}}}"},
 {"id":"fx-none","title":"No block yet","status":"open","priority":3,"issue_type":"task","labels":[],"created_at":"2026-10-04T18:00:00Z","updated_at":"2026-10-04T18:00:00Z"},
 {"id":"fx-newer","title":"From the future","status":"open","priority":3,"issue_type":"task","labels":[],"created_at":"2026-10-04T18:00:00Z","updated_at":"2026-10-04T18:00:00Z",
  "agent_context":"{\"flight_deck\":{\"execution\":{\"v\":2}}}"}
]}
```

`kinds.json`:

```json
{"v":1,"kinds":[
 {"id":"tests","name":"Tests","description":"Unit and integration tests","dimensions":{"test-authoring":0.9,"agentic-coding":0.4},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"},
 {"id":"snapshot-tests","name":"Snapshot tests","description":"Write or update snapshot/golden-file tests","dimensions":{"test-authoring":0.8,"agentic-coding":0.3},"origin":"planning","status":"active","createdAt":"2026-10-04T18:00:00Z"},
 {"id":"golden-tests","name":"Golden tests","description":"Duplicate of snapshot tests","dimensions":{"test-authoring":0.8},"origin":"planning","status":"merged:snapshot-tests","createdAt":"2026-10-04T18:00:00Z"},
 {"id":"algorithm","name":"Algorithm","description":"Non-trivial algorithms","dimensions":{"algorithmic-reasoning":0.9,"agentic-coding":0.3},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"}
]}
```

`usage-timeline.json` — an array of `UsageReading` (ISO dates):

```json
[
 {"account":{"harness":"claude","id":"11111111-1111-1111-1111-111111111111","label":"Work"},"windows":[{"name":"five_hour","utilization":0.50,"resetsAt":"2026-10-04T23:00:00Z"},{"name":"seven_day","utilization":0.30,"resetsAt":"2026-10-09T00:00:00Z"}],"readAt":"2026-10-04T18:00:00Z","source":"fixture","hardRejection":false},
 {"account":{"harness":"claude","id":"11111111-1111-1111-1111-111111111111","label":"Work"},"windows":[{"name":"five_hour","utilization":0.82,"resetsAt":"2026-10-04T23:00:00Z"},{"name":"seven_day","utilization":0.31,"resetsAt":"2026-10-09T00:00:00Z"}],"readAt":"2026-10-04T19:00:00Z","source":"fixture","hardRejection":false},
 {"account":{"harness":"claude","id":"11111111-1111-1111-1111-111111111111","label":"Work"},"windows":[{"name":"five_hour","utilization":0.96,"resetsAt":"2026-10-04T23:00:00Z"},{"name":"seven_day","utilization":0.33,"resetsAt":"2026-10-09T00:00:00Z"}],"readAt":"2026-10-04T20:00:00Z","source":"fixture","hardRejection":false},
 {"account":{"harness":"claude","id":"11111111-1111-1111-1111-111111111111","label":"Work"},"windows":[],"readAt":"2026-10-04T20:10:00Z","source":"fixture","hardRejection":true},
 {"account":{"harness":"claude","id":"11111111-1111-1111-1111-111111111111","label":"Work"},"windows":[{"name":"five_hour","utilization":0.05,"resetsAt":"2026-10-05T04:00:00Z"},{"name":"seven_day","utilization":0.34,"resetsAt":"2026-10-09T00:00:00Z"}],"readAt":"2026-10-04T23:05:00Z","source":"fixture","hardRejection":false}
]
```

- [ ] **Step 2: Write the failing fixture tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Four branches assert against these fixtures, so their meaning is pinned once, here.
final class L3FixtureTests: XCTestCase {
    func testBrRowsDecodeAsDocumented() throws {
        let rows = try L3Fixtures.brRows()
        func decode(_ id: String) -> Result<ExecutionBlock?, ExecutionBlockError> {
            ExecutionBlockCodec.decode(agentContext: rows.first { $0["id"] as? String == id }?["agent_context"] as? String)
        }
        XCTAssertEqual(try decode("fx-valid").get()?.kind, "snapshot-tests")
        XCTAssertEqual(try decode("fx-pinned").get()?.pinned, true)
        XCTAssertEqual(decode("fx-invalid"), .failure(.missingField("model")))
        XCTAssertNil(try decode("fx-none").get())
        XCTAssertEqual(decode("fx-newer"), .failure(.unsupportedVersion(2)))
    }

    func testKindsFixtureResolvesMerged() throws {
        let file = try L3Fixtures.kinds()
        XCTAssertEqual(KindResolution.resolve("golden-tests", in: file.kinds)?.id, "snapshot-tests")
        for k in file.kinds { XCTAssertNoThrow(try k.validate()) }
    }

    func testUsageTimelineCrossesSoftThenHard() throws {
        let t = try L3Fixtures.usageTimeline()
        XCTAssertEqual(t.map { $0.worstWindow?.utilization }, [0.50, 0.82, 0.96, nil, 0.34])
        XCTAssertEqual(t.map(\.hardRejection), [false, false, false, true, false])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=L3FixtureTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'L3Fixtures' in scope`.

- [ ] **Step 4: Implement `L3Fixtures.swift`**

```swift
import Foundation
import IntakeKit

/// Loads the shared Level 3 fixtures from the test bundle's `Fixtures/FlightControlL3` folder.
enum L3Fixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3") else {
            throw NSError(domain: "L3Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    /// `br list --json` wraps rows in `{"issues": […]}`; `br ready`/`br show` return bare arrays.
    /// Accept both so a fixture copied from either command loads.
    static func brRows() throws -> [[String: Any]] { try rows(in: data("br-list-with-blocks")) }

    static func rows(in data: Data) throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: data)
        if let env = obj as? [String: Any], let issues = env["issues"] as? [[String: Any]] { return issues }
        return obj as? [[String: Any]] ?? []
    }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    static func kinds() throws -> KindRegistryFile { try decoder.decode(KindRegistryFile.self, from: data("kinds")) }
    static func usageTimeline() throws -> [UsageReading] { try decoder.decode([UsageReading].self, from: data("usage-timeline")) }
}
```

- [ ] **Step 5: Write the live round-trip test (skipped by default)**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The whole contract rests on one probe: br keeps `agent_context` byte-for-byte, and
/// `br list --json` returns it while `br ready --json` does not. Re-probe it against the real
/// binary so a br upgrade that changes either fact fails here, not in a swarm.
/// Skipped unless `TEST_RUNNER_BR_LIVE=1` or `BR_LIVE=1`, and when `br` is missing.
final class ExecutionBlockLiveTests: XCTestCase {
    func testBlockSurvivesBrCreateAndList() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BR_LIVE"] == "1" || env["TEST_RUNNER_BR_LIVE"] == "1" else { throw XCTSkip("set BR_LIVE=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let br = home.appendingPathComponent(".local/bin/br").path
        guard FileManager.default.isExecutableFile(atPath: br) else { throw XCTSkip("br not at ~/.local/bin/br") }
        let dir = home.appendingPathComponent(".fd-l3-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func run(_ args: [String]) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
            p.currentDirectoryURL = dir
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try run(["/usr/bin/git", "init", "-q"])
        _ = try run([br, "init"])
        let block = ExecutionBlock(kind: "tests", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"],
                                   pool: "codex-subs", source: AssignmentSource(by: .rule, ruleId: "r1", reason: "live",
                                   at: Date(timeIntervalSince1970: 1_790_000_000)))
        let ctx = try ExecutionBlockCodec.encode(block, into: #"{"instructions":"keep"}"#)
        _ = try run([br, "create", "live probe", "-t", "task", "--agent-context", ctx, "--silent"])

        let list = try L3Fixtures.rows(in: Data(try run([br, "list", "--json"]).utf8))
        let stored = try XCTUnwrap(list.first?["agent_context"] as? String)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: stored).get(), block)
        XCTAssertTrue(stored.contains("\"instructions\""))

        let ready = try L3Fixtures.rows(in: Data(try run([br, "ready", "--json"]).utf8))
        XCTAssertFalse(ready.isEmpty)
        XCTAssertNil(ready.first?["agent_context"], "br ready started carrying agent_context — readers may simplify")
    }
}
```

- [ ] **Step 6: Run both to verify**

Run: `FD_TEST_FILTER=L3FixtureTests,ExecutionBlockLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`, with `ExecutionBlockLiveTests` skipped.
Run: `BR_LIVE=1 FD_TEST_FILTER=ExecutionBlockLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 1 test, with 0 failures` and no skip. If `test-unit.sh` does not forward `BR_LIVE`, use `TEST_RUNNER_BR_LIVE=1` instead.

- [ ] **Step 7: Commit**

```bash
git add Tests/FlightDeckTests/Fixtures/FlightControlL3 Tests/FlightDeckTests/FlightControlL3/L3Fixtures.swift Tests/FlightDeckTests/FlightControlL3/L3FixtureTests.swift Tests/FlightDeckTests/FlightControlL3/ExecutionBlockLiveTests.swift
git commit -m "test: add shared level 3 fixtures and a live br agent_context probe" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Full suite, spec deviations, merge

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md` (§5, §7)
- Modify: `docs/FOLLOWUPS.md` (the Level 3 entry)

- [ ] **Step 1: Run the whole unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tee /tmp/l3-0-unit.log | tail -5; rg -n "error:" /tmp/l3-0-unit.log | head`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. Any failure in a test this branch did not touch: check it against master before blaming this branch.

- [ ] **Step 2: Record the deviations in the spec**

In §5, replace "Added to `AgentAdapter` as a new protocol, `AgentRoutingCapabilities`. Every adapter conforms." with:

> A separate `@MainActor` protocol, `AgentRoutingCapabilities`, with one conformer per agent, held in `RoutingCapabilityRegistry` (`Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`). Not on `AgentAdapter`: adapters are built per account, these answers are per agent. Session-specific calls take the `Session`. `RoutingCapabilityRegistry.standard()` switches exhaustively over `AgentID`, so a new agent case must state its answers to compile.

In §7, change the `Router` line to include `spill(_:kind:project:exhausted:catalogs:now:)` and `now: Date` on `assign`, and change the `SwarmSpawner` line to `spawn(task:block:lease:firstPrompt:)`. Add under §8: "`FakeAdapter` is `FakeRoutingCapabilities` with harness `"fake"`, not an `AgentAdapter` conformer."

- [ ] **Step 3: Update FOLLOWUPS**

In the "Level 3 'Operate' — DESIGNED" entry, add: "L3-0 contract merged (<sha>); L3-R/I/U/S may start."

- [ ] **Step 4: Commit and merge**

```bash
git add docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md docs/FOLLOWUPS.md
git commit -m "docs: record the level 3 contract as built" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then merge to master per `superpowers:finishing-a-development-branch`. Before merging, run `git diff master...HEAD -- vendor` and confirm it is empty (worktree vendor symlinks must never be committed).
