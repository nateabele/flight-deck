# API-Error Auto-Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a turn dies on a transient API error, Flight Deck waits on a backoff ladder and re-nudges the agent until it recovers — for every agent, behind one preference, off by default.

**Architecture:** Retry state rides *inside* the existing `SessionAPIError`, so `setAPIError` stays the single writer and no new `FleetEvent` case is needed. A new `AgentTurnRecovery` adapter capability decides (fail-closed) whether a failure is retryable and what text revives it. A `maintenanceTick()` — driven by the shared `WatchClock`, not the claude-only registry scan — drops a `DeferredPrompt` into the queue that already knows how to type into a composer.

**Tech Stack:** Swift 5 (`SWIFT_VERSION: "5.0"` is deliberate), SwiftUI/AppKit, XCTest. FleetKit is `Foundation`/`Network`/`Security` only — it compiles for iOS.

**Spec:** `docs/superpowers/specs/2026-09-21-api-error-auto-retry-design.md` (commits `7eae006`, `86d59dc`)

## Global Constraints

- **Two test targets.** `./scripts/test-unit.sh` (macOS) does **not** cover `Sources/FlightDeckMobile`. Touching the phone requires `./scripts/test-ios.sh`. Both must pass before the final commit.
- **`test-unit.sh` ignores `-only-testing:`** — it silently runs the whole suite every time. Budget ~8 min per run; do not investigate this.
- **Never loop `./scripts/smoke.sh`.** Not needed by this plan at all.
- **Run tests in the foreground.** A backgrounded run dies with the subagent's turn.
- **`build-boringssl.sh` must have run** before any build, or every target fails on a missing `BoringSSL.xcframework`.
- **Shared checkout.** Other sessions are editing this tree. Never `git stash`, `git checkout .`, or revert. Stage only the files you changed, by path.
- **Comments explain *why* and name the failure they prevent.** This is the house style; match the density of the surrounding file.
- **Commits:** lowercase imperative subject (`fix: …`, `feat: …`, `test: …`), body covering mechanism/evidence/rejected alternatives, trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **TDD:** confirm every test fails against the unmodified code before implementing. Never weaken an assertion to go green.
- **`SessionAPIError.kind` is read verbatim and never matched against an enum for *display*.** The allowlist in Task 2 matches it for *policy* only; the display rule is unchanged.

---

### Task 1: `SessionAPIError` carries retry state

The foundation — every later task reads these fields. Putting them on the existing struct is what avoids a new `FleetEventTag`, which would throw in an older phone's decoder and tear the socket down.

**Files:**
- Modify: `Sources/FleetKit/SessionAPIError.swift`
- Test: `Tests/FlightDeckTests/SessionAPIErrorTests.swift` (create if absent; otherwise extend)

**Interfaces:**
- Produces: `SessionAPIError.retryAttempt: Int?`, `SessionAPIError.nextRetryAt: Date?`, and an extended `label`. Both new fields default to `nil` in the memberwise `init`, so no existing construction site changes.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FleetKit

final class SessionAPIErrorRetryTests: XCTestCase {
    func testLabelIsUnchangedWhenNoRetryIsArmed() {
        let e = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
        XCTAssertEqual(e.label, "Stopped — API error 529 (overloaded)")
    }

    func testLabelNamesTheAttemptWhenArmed() {
        let e = SessionAPIError(
            status: 529, kind: "overloaded", isTransient: true,
            retryAttempt: 2, nextRetryAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(e.label, "Stopped — API error 529 (overloaded) · retrying, attempt 2")
    }

    func testRetryFieldsRoundTrip() throws {
        let e = SessionAPIError(
            status: 429, kind: "rate_limit", isTransient: true,
            retryAttempt: 3, nextRetryAt: Date(timeIntervalSince1970: 1_700_000_000))
        let back = try JSONDecoder().decode(
            SessionAPIError.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }

    /// The old-client guarantee: a payload written before these fields existed must decode,
    /// not throw. A throw here propagates out of `WireSession.init(from:)` and kills the socket.
    func testAPayloadWithoutRetryFieldsDecodes() throws {
        let legacy = Data(#"{"status":529,"kind":"overloaded","isTransient":true}"#.utf8)
        let back = try JSONDecoder().decode(SessionAPIError.self, from: legacy)
        XCTAssertNil(back.retryAttempt)
        XCTAssertNil(back.nextRetryAt)
        XCTAssertEqual(back.status, 529)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `extra argument 'retryAttempt' in call` (compile error). A compile failure **is** the red state here; do not skip ahead.

- [ ] **Step 3: Implement**

In `Sources/FleetKit/SessionAPIError.swift`, add the two properties after `isTransient`:

```swift
    /// Which auto-retry attempt is pending, 1-based, or `nil` when no retry is armed.
    ///
    /// Retry state lives inside this struct rather than in a `FleetEvent` case of its own,
    /// and that is a compatibility decision, not a tidiness one: a new `FleetEventTag` raw
    /// value throws in an older phone's decoder and tears down the socket, while an unknown
    /// *field* is simply skipped by the `decodeIfPresent` below. It also keeps
    /// `SessionStore.setAPIError` the single writer, which is what the replicator's drift
    /// assertion depends on.
    public var retryAttempt: Int?
    /// When the next attempt is due — absolute, never a remaining duration. A countdown
    /// value would change every second and emit an event per tick; a timestamp changes once
    /// per attempt and the client does the arithmetic, as `WirePlanGate.startedAt` does.
    public var nextRetryAt: Date?
```

Extend the memberwise `init` with `retryAttempt: Int? = nil, nextRetryAt: Date? = nil` and assign both. Add both to `CodingKeys`. Add to the hand-written `init(from:)`:

```swift
        retryAttempt = try c.decodeIfPresent(Int.self, forKey: .retryAttempt)
        nextRetryAt = try c.decodeIfPresent(Date.self, forKey: .nextRetryAt)
```

Extend `label` — this one function is the Mac tooltip, the Mac accessibility label, and the phone's VoiceOver string, which is why the retry clause goes here and not in three views:

```swift
        if let retryAttempt { out += " · retrying, attempt \(retryAttempt)" }
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, and no other test regresses (the encoder is `encodeIfPresent`, so absent fields stay absent on the wire).

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/SessionAPIError.swift Tests/FlightDeckTests/SessionAPIErrorTests.swift
git commit   # subject: "feat: carry auto-retry state on SessionAPIError"
```

---

### Task 2: The `AgentTurnRecovery` capability

Who decides a failure is worth retrying, per agent, failing closed.

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift` (protocol requirement + `AgentID` dispatch)
- Create: `Sources/FlightDeck/Agents/ClaudeTurnRecovery.swift`
- Create: `Sources/FlightDeck/Agents/Codex/CodexTurnRecovery.swift`
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift`, `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift`
- Test: `Tests/FlightDeckTests/AgentTurnRecoveryTests.swift`

**Interfaces:**
- Consumes: `SessionAPIError.isTransient`, `.kind` (Task 1's struct, unchanged fields).
- Produces: `protocol AgentTurnRecovery { func retries(_ error: SessionAPIError) -> Bool; var resumeText: String { get } }`; `AgentAdapter.turnRecovery: AgentTurnRecovery?`; `AgentID.turnRecovery`; `CodexTurnRecovery.isTransientKind(_ kind: String?) -> Bool` (static — Task 3 calls it).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck
@testable import FleetKit

final class AgentTurnRecoveryTests: XCTestCase {
    func testClaudeDefersToTheCLIsOwnPredicate() {
        let r = ClaudeTurnRecovery()
        XCTAssertTrue(r.retries(SessionAPIError(kind: "overloaded", isTransient: true)))
        XCTAssertFalse(r.retries(SessionAPIError(kind: "invalid_request", isTransient: false)))
    }

    func testCodexRetriesEveryAllowlistedKind() {
        let r = CodexTurnRecovery()
        for kind in ["rate_limit_exceeded", "server_overloaded", "internal_server_error",
                     "response_too_many_failed_attempts", "response_stream_connection_failed",
                     "response_stream_disconnected", "http_connection_failed"] {
            XCTAssertTrue(r.retries(SessionAPIError(kind: kind)), "\(kind) should retry")
        }
    }

    func testCodexRefusesPermanentKinds() {
        let r = CodexTurnRecovery()
        for kind in ["unauthorized", "bad_request", "context_window_exceeded",
                     "usage_limit_exceeded", "cyber_policy",
                     "misalignment_policy_violation", "sandbox_error", "other"] {
            XCTAssertFalse(r.retries(SessionAPIError(kind: kind)), "\(kind) must not retry")
        }
    }

    /// The fail-closed assertion, and the reason the allowlist exists. Codex's error
    /// vocabulary is not ours and it will grow; a kind we have never seen must never be
    /// able to cause unattended typing into a terminal.
    func testCodexRefusesAnUnknownKindAndANilKind() {
        let r = CodexTurnRecovery()
        XCTAssertFalse(r.retries(SessionAPIError(kind: "quantum_flux_exceeded")))
        XCTAssertFalse(r.retries(SessionAPIError(kind: nil)))
        // isTransient must NOT be a backdoor around the allowlist for codex.
        XCTAssertFalse(r.retries(SessionAPIError(kind: "quantum_flux", isTransient: true)))
    }

    func testBothAgentsExposeRecoveryThroughTheAgentIDSwitch() {
        XCTAssertNotNil(AgentID.claude.turnRecovery)
        XCTAssertNotNil(AgentID.codex.turnRecovery)
        XCTAssertEqual(AgentID.claude.turnRecovery?.resumeText, SessionStore.resumePrompt)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'ClaudeTurnRecovery' in scope`.

- [ ] **Step 3: Implement**

In `AgentAdapter.swift`, beside the other capability declarations (after `dialogDriver`, ~line 114):

```swift
    /// **How a turn this agent lost to an API failure is revived — or `nil`, the refusal.**
    ///
    /// A capability rather than a flag on the error, because the vocabulary is each agent's
    /// own: claude ships a transience predicate in its transcript record, codex ships a
    /// `codex_error_info` variant name and nothing else. Both answers are allowlists here —
    /// an unrecognised kind never retries — so an agent growing a new error kind cannot
    /// start typing into a terminal unattended. A `nil` is the refusal, exactly as it is for
    /// `textChannel`: an agent added later retries nothing until someone builds and tests
    /// its classifier against captured records.
    ///
    /// Read through `AgentID.turnRecovery` below.
    static var turnRecovery: AgentTurnRecovery? { get }
```

Add the protocol in the same file, beside `AgentTextChannel`:

```swift
/// Whether a failed turn is worth retrying, and what revives it. See
/// `AgentAdapter.turnRecovery`.
@MainActor
protocol AgentTurnRecovery {
    func retries(_ error: SessionAPIError) -> Bool
    var resumeText: String { get }
}
```

Add the `AgentID` arm beside the others (~line 450):

```swift
    /// See `AgentAdapter.turnRecovery`. Consulted by `SessionStore`'s arming gate alone, so
    /// the retry loop never learns an agent's name.
    var turnRecovery: AgentTurnRecovery? {
        switch self {
        case .claude: ClaudeAdapter.turnRecovery
        case .codex: CodexAdapter.turnRecovery
        }
    }
```

`ClaudeTurnRecovery.swift`:

```swift
import FleetKit

/// Claude states transience itself, in the transcript record, and `ClaudeSession` already
/// parses it — so this defers rather than re-deriving a rule the CLI owns.
@MainActor
struct ClaudeTurnRecovery: AgentTurnRecovery {
    func retries(_ error: SessionAPIError) -> Bool { error.isTransient }
    var resumeText: String { SessionStore.resumePrompt }
}
```

`CodexTurnRecovery.swift`:

```swift
import FleetKit

/// Codex ships no transience flag — only a `codex_error_info` variant name — so the rule
/// lives here, as an allowlist.
///
/// Spellings are the ROLLOUT's (snake_case), not the app-server schema's (camelCase). The
/// two disagree for the same data; probed 2026-09-21 against codex-cli 0.155.1, where a
/// 429 wrote `response_too_many_failed_attempts` into the rollout's `task_complete` record.
@MainActor
struct CodexTurnRecovery: AgentTurnRecovery {
    /// The single source of truth for codex transience. `CodexEventMapper` calls this to
    /// populate `isTransient` at parse time, so the persisted flag and the retry decision
    /// cannot disagree.
    nonisolated static let transientKinds: Set<String> = [
        "rate_limit_exceeded",
        "server_overloaded",
        "internal_server_error",
        "response_too_many_failed_attempts",
        "response_stream_connection_failed",
        "response_stream_disconnected",
        "http_connection_failed",
    ]

    nonisolated static func isTransientKind(_ kind: String?) -> Bool {
        guard let kind else { return false }
        return transientKinds.contains(kind)
    }

    func retries(_ error: SessionAPIError) -> Bool {
        Self.isTransientKind(error.kind)
    }

    var resumeText: String { SessionStore.resumePrompt }
}
```

Then `static let turnRecovery: AgentTurnRecovery? = ClaudeTurnRecovery()` in `ClaudeAdapter`, and `= CodexTurnRecovery()` in `CodexAdapter`, each with a one-line comment in the style of the neighbours.

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentAdapter.swift \
        Sources/FlightDeck/Agents/ClaudeTurnRecovery.swift \
        Sources/FlightDeck/Agents/Codex/CodexTurnRecovery.swift \
        Sources/FlightDeck/Agents/ClaudeAdapter.swift \
        Sources/FlightDeck/Agents/Codex/CodexAdapter.swift \
        Tests/FlightDeckTests/AgentTurnRecoveryTests.swift
git commit   # subject: "feat: add the AgentTurnRecovery capability, failing closed"
```

---

### Task 3: Codex produces `SessionAPIError` from its rollout

The missing producer. Without this the feature is claude-only.

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift` (the `task_complete` arm, ~line 45)
- Test: `Tests/FlightDeckTests/CodexEventMapperTests.swift` (extend)

**Interfaces:**
- Consumes: `CodexTurnRecovery.isTransientKind(_:)` from Task 2; `AgentEvent.apiError(SessionAPIError?)`, which already exists at `AgentKind.swift:58`.
- Produces: no new symbols — `events(inRolloutLine:)` gains `.apiError` emissions.

- [ ] **Step 1: Write the failing tests**

The fixture is a real record captured from codex-cli 0.155.1 driven against an upstream returning 429.

```swift
func testTaskCompleteWithAnErrorEmitsAnAPIError() {
    let line = #"""
    {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"exceeded retry limit, last status: 429 Too Many Requests","codex_error_info":{"response_too_many_failed_attempts":{"http_status_code":429}}}}}
    """#
    let events = CodexEventMapper.events(inRolloutLine: line)
    guard case .apiError(let error)? = events.first(where: {
        if case .apiError = $0 { return true } else { return false }
    }) else { return XCTFail("no apiError emitted: \(events)") }
    XCTAssertEqual(error?.status, 429)
    XCTAssertEqual(error?.kind, "response_too_many_failed_attempts")
    XCTAssertTrue(error?.isTransient == true)
    // The turn still ended; the existing contract must not regress.
    XCTAssertTrue(events.contains(.turnEnded))
    XCTAssertTrue(events.contains(.activity(.idle)))
}

func testACleanTaskCompleteClearsAnyStandingError() {
    let line = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"done"}}"#
    XCTAssertTrue(CodexEventMapper.events(inRolloutLine: line).contains(.apiError(nil)))
}

/// A user interrupt is not an API failure, and must not clear or set one.
func testTurnAbortedTouchesTheErrorNotAtAll() {
    let line = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    let events = CodexEventMapper.events(inRolloutLine: line)
    XCTAssertFalse(events.contains { if case .apiError = $0 { return true } else { return false } })
    XCTAssertTrue(events.contains(.turnEnded))
}

/// A permanent failure is still reported — the badge is right — it simply will not retry.
func testAPermanentErrorIsReportedAsNonTransient() {
    let line = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"nope","codex_error_info":{"unauthorized":{}}}}}"#
    guard case .apiError(let error)? = CodexEventMapper.events(inRolloutLine: line).first(where: {
        if case .apiError = $0 { return true } else { return false }
    }) else { return XCTFail("no apiError emitted") }
    XCTAssertEqual(error?.kind, "unauthorized")
    XCTAssertFalse(error?.isTransient == true)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — "no apiError emitted".

- [ ] **Step 3: Implement**

Replace the `task_complete` arm. Note `codex_error_info` is **either** a bare string (the unit-only variants) **or** a single-key object whose value may carry `http_status_code` — both shapes appear in the schema, so both must parse:

```swift
        case "task_complete":
            // The error rides as a FIELD on this record rather than as a record type of its
            // own, which is why a survey of rollout `type` values finds nothing error-shaped.
            // Probed 2026-09-21 against codex-cli 0.155.1 by driving a real TUI at an
            // upstream returning 429. The app-server spells the same payload in camelCase;
            // the file spells it snake_case, and the file is what this parser reads.
            guard let error = payload["error"] as? [String: Any] else {
                return [.activity(.idle), .turnEnded, .apiError(nil)]
            }
            return [.activity(.idle), .turnEnded, .apiError(apiError(fromTurnError: error))]

        // An aborted turn is a user interrupt, not an API failure: it must neither raise an
        // error nor clear one that is standing.
        case "turn_aborted":
            return [.activity(.idle), .turnEnded]
```

And a private helper in the same type:

```swift
    /// `codex_error_info` is a union: a bare string for the unit variants
    /// (`"unauthorized"`), or a one-key object for the ones carrying a status
    /// (`{"response_too_many_failed_attempts":{"http_status_code":429}}`). Both shapes are
    /// in the published schema, so reading only one would drop half the vocabulary.
    private static func apiError(fromTurnError error: [String: Any]) -> SessionAPIError {
        let info = error["codex_error_info"]
        var kind: String?
        var status: Int?
        if let name = info as? String {
            kind = name
        } else if let object = info as? [String: Any], let name = object.keys.first {
            kind = name
            status = (object[name] as? [String: Any])?["http_status_code"] as? Int
        }
        return SessionAPIError(
            status: status,
            kind: kind,
            // One source of truth: the adapter's allowlist, so the persisted flag and the
            // retry decision cannot disagree.
            isTransient: CodexTurnRecovery.isTransientKind(kind))
    }
```

Update the type's header comment: its "two things this can never emit" list is unchanged, but the `task_complete`/`turn_aborted` shared arm is now split — say why.

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift \
        Tests/FlightDeckTests/CodexEventMapperTests.swift
git commit   # subject: "feat: report codex API failures from the rollout's task_complete"
```

---

### Task 4: The preference

**Files:**
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (`ShellPreferences`)
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (accessor, after `sleepIdleThresholdSeconds`)
- Modify: `Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift` (new `Recovery` section after `Sleep`)
- Test: `Tests/FlightDeckTests/PreferencesStoreTests.swift` (extend)

**Interfaces:**
- Produces: `PreferencesStore.autoRetriesAPIErrors: Bool` (default **false**). Task 6 reads it.

- [ ] **Step 1: Write the failing tests**

Mirror the existing trio for `idleSleepEnabled` — default-when-nil, round-trip, and the load-bearing legacy decode:

```swift
func testAutoRetryDefaultsOff() {
    XCTAssertFalse(makeStore().autoRetriesAPIErrors)
}

func testAutoRetryRoundTripsThroughPersistence() {
    let p = InMemoryPreferencesPersistence()
    let store = PreferencesStore(persistence: p)
    store.autoRetriesAPIErrors = true
    XCTAssertTrue(PreferencesStore(persistence: p).autoRetriesAPIErrors)
}

/// A `"shell": {...}` blob written before this field existed must still decode. Without the
/// optional, `load()`'s `try?` returns nil and every preference the user has is silently reset.
func testAShellBlobPredatingTheFieldStillDecodes() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Preferences())) as? [String: Any])
    var shell = try XCTUnwrap(object["shell"] as? [String: Any])
    shell.removeValue(forKey: "autoRetryAPIErrors")
    object["shell"] = shell
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(Preferences.self, from: data)
    XCTAssertNil(decoded.shell.autoRetryAPIErrors)
}
```

Match the existing file's helper names (`makeStore()` / the persistence double it already uses) rather than introducing new ones.

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh` → FAIL (compile: no member `autoRetriesAPIErrors`).

- [ ] **Step 3: Implement**

`ShellPreferences` gains, with the optionality comment the neighbouring fields all carry:

```swift
    /// Whether a session whose turn died on a transient API error is automatically nudged
    /// back to life on a backoff ladder. Applies to every agent that declares an
    /// `AgentTurnRecovery`, which is why it lives here rather than under `claude`. Optional
    /// for the same reason `idleSleepEnabled` is — a `"shell": {...}` blob already on disk
    /// predates this field. `nil` reads as OFF: this feature types into a terminal, so it is
    /// opt-in.
    var autoRetryAPIErrors: Bool?
```

Add to the `init` (`autoRetryAPIErrors: Bool? = nil`) and assign. Store accessor:

```swift
    /// Whether transient API failures are retried automatically. Defaults OFF — unlike the
    /// other shell toggles, this one acts on the user's behalf by typing.
    var autoRetriesAPIErrors: Bool {
        get { preferences.shell.autoRetryAPIErrors ?? false }
        set {
            var shell = preferences.shell
            shell.autoRetryAPIErrors = newValue
            preferences.shell = shell
        }
    }
```

UI — a new `Section("Recovery")` immediately after the `Sleep` section in `ShellSettingsTab.swift`, matching that section's shape exactly (explicit `Binding(get:set:)`, kebab-case identifier, caption below):

```swift
            Section("Recovery") {
                Toggle(
                    "Retry after API errors",
                    isOn: Binding(
                        get: { preferences.autoRetriesAPIErrors },
                        set: { preferences.autoRetriesAPIErrors = $0 }
                    )
                )
                .accessibilityIdentifier("prefs-auto-retry-api-errors")
                Text("When a turn stops because the API was overloaded or rate-limited, Flight Deck waits and then types “\(SessionStore.resumePrompt)” into the session, backing off up to 15 minutes between tries until it succeeds. Only failures the agent reports as temporary are retried, and anything you type cancels it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Run to verify they pass** — `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift \
        Tests/FlightDeckTests/PreferencesStoreTests.swift
git commit   # subject: "feat: add the auto-retry preference, off by default"
```

---

### Task 5: An agent-independent maintenance tick

**Read spec §4.4's amendment before starting.** This task exists because `applyRegistry` — where `flushPendingPrompts` lives today — runs only when a claude tab exists. Building the retry on it would make an all-agents feature claude-only.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry` ~5789-5807; the production init ~1658)
- Test: `Tests/FlightDeckTests/SessionStoreMaintenanceTickTests.swift`

**Interfaces:**
- Produces: `SessionStore.maintenanceTick()` (private) and `maintenanceTickForTesting()` (internal seam, in the style of `flushPromptQueueForTesting`). Task 6 adds `flushRetryBackoff()` to the tick's body.

- [ ] **Step 1: Write the failing test**

```swift
/// A codex-only fleet gets no `applyRegistry` tick — `startStatusWatching` and
/// `startWatching(tabID:)` both gate on `hasStatusRegistry`, which codex answers false. So
/// everything that used to live only in that defer starved. This is the regression guard.
@MainActor
func testACodexOnlyFleetStillTypesAQueuedPrompt() async {
    let store = makeStoreWithASingleCodexTab()   // no claude tab anywhere
    let injector = FakeInjector(viewport: codexComposerViewport)
    store.overrideInjector(injector, for: tabID)

    store.submitPrompt("hello", token: UUID(), to: tabID)
    XCTAssertTrue(injector.typed.isEmpty, "nothing should be typed before a tick")

    store.maintenanceTickForTesting()

    XCTAssertEqual(injector.typed, ["hello"])
}
```

Build it from the existing codex-tab and injector doubles in `Tests/FlightDeckTests/` (`CodexStatusRoutingTests.swift` and the prompt-queue tests already construct both) — do not invent new fakes.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `maintenanceTickForTesting` undefined; and once defined but not wired, the prompt is never typed.

- [ ] **Step 3: Implement**

Extract `applyRegistry`'s `defer` body, preserving its comments:

```swift
    /// Everything that must run on a timer regardless of which agents are open.
    ///
    /// **Called from two places on purpose.** `applyRegistry`'s `defer` keeps claude's
    /// cadence exactly as it was; the `WatchClock` registration in `init` is what covers a
    /// fleet with no claude tab in it. Registry scans exist only for agents that declare
    /// `hasStatusRegistry` — codex does not — so before this split a codex-only fleet never
    /// flushed a deferred rename, a phone prompt, or anything else parked here.
    ///
    /// Safe to run twice in one instant: every flush below is idempotent and
    /// deadline-guarded, and `inject` refuses re-entry for a tab already mid-settle.
    private func maintenanceTick() {
        flushPendingRenames()
        flushPendingPrompts()
        flushPromptQueue()
    }
```

`applyRegistry`'s `defer` becomes `defer { maintenanceTick() }`, keeping the explanatory comments by moving them onto `maintenanceTick`'s body. In the production init, beside the sleep-controller registration at ~1658:

```swift
        // The agent-independent half of the tick. `sleepController` registers the same way
        // one line up; see `maintenanceTick` for why the registry scan cannot be the only
        // driver.
        clock.add(self) { [weak self] in self?.maintenanceTick() }
```

Add the test seam beside the existing ones (~4168):

```swift
    func maintenanceTickForTesting() { maintenanceTick() }
```

- [ ] **Step 4: Run to verify it passes** — `./scripts/test-unit.sh` → PASS, with no regression in the existing prompt-queue and rename tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/SessionStoreMaintenanceTickTests.swift
git commit   # subject: "fix: tick deferred work on a clock, not the claude-only registry scan"
```

---

### Task 6: The retry scheduler

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (constants near `resumePrompt` ~3470; `apply(_:to:)` ~6888; `maintenanceTick`)
- Test: `Tests/FlightDeckTests/SessionStoreAPIRetryTests.swift`

**Interfaces:**
- Consumes: `AgentID.turnRecovery` (Task 2), `PreferencesStore.autoRetriesAPIErrors` (Task 4), `maintenanceTick()` (Task 5), `SessionAPIError.retryAttempt`/`.nextRetryAt` (Task 1).
- Produces: `SessionStore.retryBackoff: [TimeInterval]`, `.retryBackoffFloor: TimeInterval`, `static func retryDelay(forAttempt:jitter:) -> TimeInterval`, and `flushRetryBackoff()` inside `maintenanceTick`.

- [ ] **Step 1: Write the failing tests**

```swift
func testTheLadderRampsThenSaturatesAtTheFloor() {
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: 0), 30)
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 5, jitter: 0), 480)
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 6, jitter: 0), 900)
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 99, jitter: 0), 900)
}

func testJitterStaysWithinTenPercent() {
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: 0.1), 33, accuracy: 0.001)
    XCTAssertEqual(SessionStore.retryDelay(forAttempt: 1, jitter: -0.1), 27, accuracy: 0.001)
}

@MainActor func testATransientErrorArmsTheFirstAttempt() { /* pref on → retryAttempt == 1, nextRetryAt ≈ now+30 */ }
@MainActor func testAPermanentErrorDoesNotArm() { /* isTransient false → both fields nil */ }
@MainActor func testNothingArmsWhenThePreferenceIsOff() { }
@MainActor func testNothingArmsForAnAgentWithNoTurnRecovery() { /* override adapter with turnRecovery nil */ }
@MainActor func testTheDueAttemptQueuesTheNudgeAndAdvancesTheRung() {
    // after maintenanceTickForTesting() at nextRetryAt: pendingPrompts[tab]?.text == "Keep going",
    // retryAttempt == 2, nextRetryAt advanced by ~60.
}
@MainActor func testAnAttemptIsNotQueuedBeforeItIsDue() { }
@MainActor func testProgressClearsTheErrorAndDisarms() { /* .apiError(nil) → no retry state */ }
@MainActor func testGoingBusyCancelsTheQueuedNudge() { /* existing cancelSupersededPrompts */ }
@MainActor func testTurningThePreferenceOffMidBackoffStopsIt() { }
@MainActor func testClosingTheTabClearsRetryState() { }
@MainActor func testOneTickInsideASettleWindowTypesOnce() { }
```

Fill every body — no placeholders in the delivered plan's tests. Drive time with the store's existing `now()` seam (declared ~1404) and injection with the existing fake injector; assert on `store.apiErrors[tab]` and `store.pendingPrompts[tab]`.

- [ ] **Step 2: Run to verify they fail** — `./scripts/test-unit.sh` → FAIL.

- [ ] **Step 3: Implement**

Constants beside `resumePrompt`:

```swift
    /// Waits between auto-retries, in seconds, then `retryBackoffFloor` forever.
    ///
    /// A literal ladder rather than a computed curve, matching `stuckPromptReportLadder`.
    /// It starts at 30s rather than immediately because this is a SECOND-order retry: both
    /// shipped agents run their own retry loop and have already exhausted it by the time a
    /// failure reaches us — claude's record means "the retry loop gave up", and codex's
    /// `response_too_many_failed_attempts` says so in the name.
    static let retryBackoff: [TimeInterval] = [30, 60, 120, 300, 480]
    /// The cadence a long outage is ridden at once the ladder is spent. There is no attempt
    /// cap: the stops that make that safe are the allowlist, the composer gate, and every
    /// path that clears the error. See the design doc §4.3.
    static let retryBackoffFloor: TimeInterval = 900

    /// `jitter` is a fraction in -0.1...0.1, injected rather than drawn here so the ladder is
    /// testable. Jitter at all so a fleet of tabs that all died on the same 529 does not
    /// re-nudge in lockstep and re-create the thundering herd that caused it.
    static func retryDelay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let base = attempt <= retryBackoff.count
            ? retryBackoff[attempt - 1]
            : retryBackoffFloor
        return base * (1 + jitter)
    }
```

A pure arming helper, plus the two call sites:

```swift
    /// Returns `error` with retry state attached, or unchanged when this failure must not be
    /// retried. Pure and applied BEFORE `setAPIError`, so arming costs no second event and
    /// `setAPIError` stays the only writer the drift assertion knows about.
    private func armed(_ error: SessionAPIError?, for id: UUID, attempt: Int = 1) -> SessionAPIError? {
        guard var error,
              preferences?.autoRetriesAPIErrors == true,
              let session = session(for: id),
              session.agent.textChannel != nil,
              let recovery = session.agent.turnRecovery,
              recovery.retries(error)
        else { return error }
        error.retryAttempt = attempt
        error.nextRetryAt = now().addingTimeInterval(
            Self.retryDelay(forAttempt: attempt, jitter: Double.random(in: -0.1...0.1)))
        return error
    }
```

In `apply(_:to:)`, `case .apiError(let error):` becomes `if setAPIError(tabID, armed(error, for: tabID)) { persist() }`.

`flushRetryBackoff()`, added to `maintenanceTick()`'s body:

```swift
    /// Queues the nudge for every tab whose next attempt has come due.
    ///
    /// Feeds `pendingPrompts` rather than calling `inject` directly, which is the whole
    /// reason this is small: that queue already waits for a composer, defers behind a
    /// rename, and is cancelled by `cancelSupersededPrompts` the moment the session starts
    /// working on its own. Its 120s deadline dropping an unsent nudge is harmless here —
    /// unlike a restore's one-shot prompt, the next rung tries again.
    private func flushRetryBackoff() {
        guard preferences?.autoRetriesAPIErrors == true else { return disarmAllRetries() }
        let currentTime = now()
        for (id, error) in apiErrors {
            guard let attempt = error.retryAttempt, let due = error.nextRetryAt,
                  currentTime >= due, pendingPrompts[id] == nil,
                  let recovery = session(for: id)?.agent.turnRecovery
            else { continue }
            pendingPrompts[id] = DeferredPrompt(
                text: recovery.resumeText,
                deadline: currentTime.addingTimeInterval(Self.resumePromptWindow))
            setAPIError(id, armed(error, for: id, attempt: attempt + 1))
        }
    }

    /// Strips retry state from every tab, without disturbing the errors themselves — the
    /// badge is still true, only the loop stops. Reached when the preference goes off
    /// mid-backoff, which is the one stop a user expects to be instant.
    private func disarmAllRetries() {
        for (id, error) in apiErrors where error.retryAttempt != nil {
            var cleared = error
            cleared.retryAttempt = nil
            cleared.nextRetryAt = nil
            setAPIError(id, cleared)
        }
    }
```

Confirm `closeSession` already drops the tab's `apiErrors` entry; if it does not, clear it there alongside `acceptedPromptTokens` and say so in a comment.

- [ ] **Step 4: Run to verify they pass** — `./scripts/test-unit.sh` → PASS, including the existing `FleetReplicator` drift assertion (DEBUG), which is the real proof `setAPIError` stayed the single writer.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreAPIRetryTests.swift
git commit   # subject: "feat: retry a transient API failure on a backing-off ladder"
```

---

### Task 7: Restart behaviour

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`restore()`, the `apiErrors` seed at ~2525)
- Test: `Tests/FlightDeckTests/SessionStoreAPIRetryTests.swift` (extend)

**Interfaces:** consumes Task 6's `armed(_:for:attempt:)`. Produces no new symbols.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor func testARestoredErrorDoesNotInheritItsOldSchedule() {
    // persisted apiError with retryAttempt 4 / nextRetryAt in the past
    // → after restore, nextRetryAt is ~now+900, never the stale timestamp
}
@MainActor func testARestoredTransientErrorReArmsAtTheFloor() {
    // pref on → retryAttempt == 1, nextRetryAt ≈ now + retryBackoffFloor (not 30)
}
@MainActor func testARestoredPermanentErrorDoesNotArm() { }
@MainActor func testNoReArmWhenThePreferenceIsOff() { }
```

- [ ] **Step 2: Run to verify they fail** — FAIL: the persisted schedule survives and fires immediately.

- [ ] **Step 3: Implement**

At the restore seed, replacing `if let error = entry.apiError { apiErrors[entry.id] = error }`:

```swift
            if var error = entry.apiError {
                // The persisted schedule is stale by definition — its `nextRetryAt` is a
                // timestamp from the previous run and is almost always already past, so
                // carrying it over would fire every restored tab's nudge on the first tick.
                error.retryAttempt = nil
                error.nextRetryAt = nil
                // Re-armed at the FLOOR, not rung 0: a relaunch is not evidence the API
                // recovered, and arming a restored fleet at 30s is exactly the launch-time
                // burst of typing `cancelSupersededPrompts`' boot-flicker note warns about.
                // Assigned directly rather than through `setAPIError`: restore runs before
                // the replicator is attached, which is why the existing seed bypasses it too.
                apiErrors[entry.id] = armed(
                    error, for: entry.id, attempt: Self.retryBackoff.count + 1)
            }
```

`attempt: retryBackoff.count + 1` is what makes `retryDelay` return the floor; reference that relationship in the comment so the two cannot drift.

- [ ] **Step 4: Run to verify they pass** — `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreAPIRetryTests.swift
git commit   # subject: "feat: re-arm a restored retry at the floor, never on a stale schedule"
```

---

### Task 8: The phone's in-session banner

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (the top `safeAreaInset` ~350; a new `retryBanner(_:)` beside `planGateBanner` ~968)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineScreenTests.swift`

**Interfaces:** consumes `WireSession.apiError.retryAttempt`/`.nextRetryAt` (Task 1, already on the wire via the untouched `apiErrorChanged` event). Produces `static func retryBannerText(for:at:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Test the pure text function, not the layout — SwiftUI layout is not reachable from this suite (see `docs/MOBILE.md`):

```swift
func testRetryBannerNamesTheAttemptAndTheCountdown() {
    let at = Date(timeIntervalSince1970: 1_000)
    let session = wireSession(apiError: SessionAPIError(
        status: 529, kind: "overloaded", isTransient: true,
        retryAttempt: 2, nextRetryAt: at.addingTimeInterval(90)))
    XCTAssertEqual(
        SessionTimelineScreen.retryBannerText(for: session, at: at),
        "Retrying — attempt 2, next in 1m 30s")
}

func testNoBannerWithoutRetryState() {
    let session = wireSession(apiError: SessionAPIError(status: 529, kind: "overloaded"))
    XCTAssertNil(SessionTimelineScreen.retryBannerText(for: session, at: Date()))
}

/// The tick can land after the due time; "next in -3s" must never be rendered.
func testAnOverdueAttemptReadsAsImminent() {
    let at = Date(timeIntervalSince1970: 1_000)
    let session = wireSession(apiError: SessionAPIError(
        retryAttempt: 3, nextRetryAt: at.addingTimeInterval(-5)))
    XCTAssertEqual(
        SessionTimelineScreen.retryBannerText(for: session, at: at),
        "Retrying — attempt 3, any moment now")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-ios.sh`
Expected: FAIL — `retryBannerText` undefined. (This script builds and boots its own throwaway simulator; it will overwrite an app on a device destination, so do not repoint it.)

- [ ] **Step 3: Implement**

The text function, then the banner, then the inset. Wrap only the banner in the ticker:

```swift
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let gate = session?.planGate { planGateBanner(gate) }
                // Scoped to the banner, and only while one is armed: a `TimelineView` over
                // anything larger would re-render the timeline once a second for a strip
                // that is absent almost always. Same argument `SessionSidebar` makes for
                // refusing one over its rows.
                if session?.apiError?.nextRetryAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let text = Self.retryBannerText(for: session, at: context.date) {
                            retryBanner(text)
                        }
                    }
                }
            }
        }
```

`retryBanner(_:)` clones `planGateBanner`'s padding, `frame`, and `Color(.secondarySystemBackground)` so the two strips align, but is **not** a `Button` and carries no chevron — a retry is not something the reader answers. Use `arrow.clockwise` (unused in this file) tinted `.orange`.

- [ ] **Step 4: Run to verify they pass** — `./scripts/test-ios.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/SessionTimelineScreen.swift \
        Tests/FlightDeckMobileTests/SessionTimelineScreenTests.swift
git commit   # subject: "feat: show a retry countdown banner on the session screen"
```

---

### Task 9: Docs, and the full two-suite run

**Files:**
- Modify: `docs/FOLLOWUPS.md`, `docs/HANDOFF.md`, `docs/ARCHITECTURE.md` (the adapter-capability list)

- [ ] **Step 1: Run both suites, in the foreground**

```bash
./scripts/test-unit.sh && ./scripts/test-ios.sh
```

Both must pass. Paste the real tail of each into the commit body — do not assert success without it.

- [ ] **Step 2: Write the docs**

- `ARCHITECTURE.md`: add `turnRecovery` to the adapter-capability list beside `textChannel`/`dialogDriver`.
- `HANDOFF.md`: one line under current state — the feature, its preference, and that it is off by default.
- `FOLLOWUPS.md`: a dated section recording, honestly, (a) that the Mac shows the attempt number but no live countdown, and why; (b) that `SessionAPIError.kind` is now matched against an allowlist for policy while still rendered verbatim, so a codex vocabulary change needs the allowlist re-probed — cross-reference the probe recipe; (c) that Task 5 fixed pre-existing prompt/rename starvation on codex-only fleets, which was never filed as a bug.

- [ ] **Step 3: Commit**

```bash
git add docs/FOLLOWUPS.md docs/HANDOFF.md docs/ARCHITECTURE.md
git commit   # subject: "docs: record the auto-retry loop and its known edges"
```

---

## Self-review

- **Spec coverage.** §4.1 → Task 3. §4.2 → Task 2. §4.3 → Task 6. §4.4 (incl. the amendment) → Tasks 5 and 6. §4.5 wire/Mac → Task 1 (the `label` change *is* the Mac surface; no `SessionStatusIcon` edit is needed, which is the point of that function). §4.5 phone → Task 8. §4.6 → Task 7. §4.7 → Task 4. §5 → tests throughout, plus Task 9's two-suite gate. No gaps.
- **Type consistency.** `turnRecovery` / `AgentTurnRecovery` / `retries(_:)` / `resumeText` / `isTransientKind(_:)` / `retryDelay(forAttempt:jitter:)` / `armed(_:for:attempt:)` / `flushRetryBackoff()` / `maintenanceTick()` / `retryBannerText(for:at:)` are spelled identically everywhere they appear.
- **Known thin spots, called out rather than hidden.** Task 6's and Task 7's test bodies are named and specified but not written out in full — the implementer must write them, using the `now()` seam and the existing injector doubles. Task 5's test depends on fixture helpers whose exact names must be read from the existing codex tests rather than assumed.
