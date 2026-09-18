# Flywheel Run-Integration (Level 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an FD-spawned agent (claude and codex) a first-class participant in a flywheel project's beads + Agent-Mail substrate — identity booted, `AGENT_NAME` injected, reservation guard enforcing — proven by a real-agent smoke test. No swarm/observe UI.

**Architecture:** A new `Sources/FlightDeck/Flywheel/` group of small, pure-ish services (probe, coordinator, setup) plus additive, strictly `flywheelEnabled`-gated hooks into the existing spawn path. Agents talk to the substrate via CLI (AGENTS.md-instructed); FD's job is only to bootstrap identity (`am macros start-session`), inject `AGENT_NAME` into the PTY env, install the guard on opt-in, and keep identity stable across wake. When the flag is off, behavior is byte-for-byte unchanged.

**Tech Stack:** Swift, SwiftUI/AppKit, libghostty surface config, `Process`/`Pipe` for CLI shell-out, XCTest (`scripts/test-unit.sh`).

**Spec:** `docs/superpowers/specs/2026-09-18-flywheel-run-integration-design.md` (read it — this plan argues from it). Background evidence: `docs/FLYWHEEL-SPIKE-FINDINGS.md`.

## Global Constraints

- **Flag off ⇒ zero behavior change.** Every hook is gated on `ProjectSettings.flywheelEnabled == true`; a non-flywheel session's env, spawn path, and persistence stay byte-for-byte as today. This is the single most important invariant; every task's tests assert the negative case.
- **Back-compat persistence idiom:** new persisted fields are **Optional + synthesized `decodeIfPresent`** (never a non-optional new field), matching every field on `SessionSnapshot.Entry`. A non-optional addition throws and wipes state on first launch.
- **Never bypass `am macros start-session`** with raw `am agents register` — the missing `projects/<slug>/project.json` makes the pre-commit guard fail *open* (Spike A).
- **Project key = standardized absolute path**, matching `PreferencesStore.key(_:)` (`URL(fileURLWithPath:isDirectory:true).standardizedFileURL.path`), passed as `am`'s `--project` human_key.
- **No repo mutation without explicit confirmation** (guard/hook install runs only after the opt-in sheet is confirmed).
- **Tests:** `./scripts/test-unit.sh` (macOS, runs the full suite ~8 min; budget for it; it ignores `-only-testing:`). `Sources/FlightDeckMobile` is untouched — `test-ios.sh` not required.

---

## File Structure

- `Sources/FlightDeck/Flywheel/FlywheelIdentity.swift` *(new)* — value type `{ agentName, project }`; the env delta producer.
- `Sources/FlightDeck/Flywheel/FlywheelProcessRunner.swift` *(new)* — a tiny `Process`/`Pipe` shell-out seam (test fake point).
- `Sources/FlightDeck/Flywheel/FlywheelCoordinator.swift` *(new)* — `boot(...)`: builds `am macros start-session` args, runs, parses the agent name.
- `Sources/FlightDeck/Flywheel/FlywheelProjectProbe.swift` *(new)* — marker/status detection over a repo dir.
- `Sources/FlightDeck/Flywheel/FlywheelSetup.swift` *(new)* — one-time `am guard install` + beads-sync hooks.
- `Sources/FlightDeck/Preferences/ProjectSettings.swift` — add `flywheelEnabled`.
- `Sources/FlightDeck/SessionModel.swift` — add `Session.flywheelIdentity`.
- `Sources/FlightDeck/SessionPersistence.swift` — add `Entry.flywheelAgentName`.
- `Sources/FlightDeck/Preferences/PreferencesStore.swift` — thread identity through `sessionEnvironment`.
- `Sources/FlightDeck/SessionStore.swift` — snapshot map; flywheel-gated async claude routing; codex bootstrap; wake re-injection; project-add probe.
- `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` — codex bootstrap in/around `prepare`.
- `Sources/FlightDeck/SessionSidebar.swift` / `ProjectHeaderRow.swift` — opt-in menu action + confirm sheet.
- `scripts/flywheel-smoke.sh` *(new)* + `docs/FLYWHEEL-SMOKE-CHECKLIST.md` *(new)*.
- Tests under `Tests/FlightDeckTests/Flywheel*`.

---

## Task 1: `ProjectSettings.flywheelEnabled` flag

**Files:**
- Modify: `Sources/FlightDeck/Preferences/ProjectSettings.swift`
- Test: `Tests/FlightDeckTests/ProjectSettingsFlywheelTests.swift`

**Interfaces:**
- Produces: `ProjectSettings.flywheelEnabled: Bool?` (nil ⇒ false); read as `settings.flywheelEnabled == true`.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import FlightDeck

final class ProjectSettingsFlywheelTests: XCTestCase {
    func testDefaultsToNilAndReadsAsDisabled() {
        XCTAssertNil(ProjectSettings().flywheelEnabled)
        XCTAssertFalse(ProjectSettings().flywheelEnabled == true)
    }

    func testEmptyIgnoresFlywheelFalseButNotTrue() {
        XCTAssertTrue(ProjectSettings(flywheelEnabled: nil).isEmpty)
        XCTAssertTrue(ProjectSettings(flywheelEnabled: false).isEmpty)
        XCTAssertFalse(ProjectSettings(flywheelEnabled: true).isEmpty)
    }

    func testDecodesLegacyJSONWithoutTheField() throws {
        let legacy = Data(#"{"accounts":{},"options":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: legacy)
        XCTAssertNil(decoded.flywheelEnabled)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testRoundTripsTrue() throws {
        let data = try JSONEncoder().encode(ProjectSettings(flywheelEnabled: true))
        XCTAssertEqual(try JSONDecoder().decode(ProjectSettings.self, from: data).flywheelEnabled, true)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail** — Run `./scripts/test-unit.sh`. Expected: FAIL (`flywheelEnabled` not a member).

- [ ] **Step 3: Implement.** Add the stored property (Optional for `decodeIfPresent` back-compat), the init param, and extend `isEmpty`:

```swift
    var options: [AgentID: AgentOptions]
    /// nil ⇒ not a flywheel project (the default). Optional so an existing settings record
    /// written before this field still decodes — synthesized `Codable` uses `decodeIfPresent`
    /// for optionals. Read as `flywheelEnabled == true`.
    var flywheelEnabled: Bool?

    init(
        defaultAgent: AgentID? = nil,
        accounts: [AgentID: UUID] = [:],
        options: [AgentID: AgentOptions] = [:],
        flywheelEnabled: Bool? = nil
    ) {
        self.defaultAgent = defaultAgent
        self.accounts = accounts
        self.options = options
        self.flywheelEnabled = flywheelEnabled
    }
```
And:
```swift
    var isEmpty: Bool {
        defaultAgent == nil && accounts.isEmpty && options.values.allSatisfy(\.isEmpty)
            && flywheelEnabled != true
    }
```

- [ ] **Step 4: Run tests, verify pass** — `./scripts/test-unit.sh`. Expected: PASS; suite green.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(flywheel): per-project flywheelEnabled flag"`

---

## Task 2: `FlywheelIdentity` + `FlywheelProcessRunner` + `FlywheelCoordinator`

**Files:**
- Create: `Sources/FlightDeck/Flywheel/FlywheelIdentity.swift`, `FlywheelProcessRunner.swift`, `FlywheelCoordinator.swift`
- Test: `Tests/FlightDeckTests/Flywheel/FlywheelCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `struct FlywheelIdentity: Equatable, Sendable { let agentName: String; let project: String; var environment: [String: String] }` where `environment == ["AGENT_NAME": agentName, "AGENT_MAIL_AGENT": agentName, "AGENT_MAIL_PROJECT": project]`.
  - `protocol FlywheelProcessRunner: Sendable { func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) }` with default `SystemFlywheelProcessRunner` (model on the `Process()`+`Pipe()` read-before-`waitUntilExit` pattern in `Sources/FlightDeck/Agents/LoginShellPath.swift:59-79`).
  - `struct FlywheelCoordinator { let runner: FlywheelProcessRunner; let amPath: String; func boot(project: String, program: String, model: String, name: String?) async throws -> FlywheelIdentity }`
  - `enum FlywheelProgram { static func rawValue(for agent: AgentID) -> String }` → `.claude` ⇒ `"claude-code"`, `.codex` ⇒ `"codex-cli"`.
- Consumes: `AgentID` (Task uses it only via `FlywheelProgram`).

- [ ] **Step 1: Write failing tests** (fake runner; assert argv, name parse, env delta):

```swift
import XCTest
@testable import FlightDeck

private struct FakeRunner: FlywheelProcessRunner {
    var stdout: String; var exitCode: Int32 = 0
    private(set) final class Calls { var argv: [[String]] = [] }
    let calls = Calls()
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        calls.argv.append([exe] + args); return (stdout, exitCode)
    }
}

final class FlywheelCoordinatorTests: XCTestCase {
    private let json = #"{"agent":{"name":"BlueFalcon"},"inbox":[]}"#

    func testBootBuildsStartSessionArgvAndParsesName() async throws {
        let fake = FakeRunner(stdout: json)
        let c = FlywheelCoordinator(runner: fake, amPath: "/usr/local/bin/am")
        let id = try await c.boot(project: "/tmp/p", program: "claude-code", model: "opus-4.8", name: nil)
        XCTAssertEqual(id.agentName, "BlueFalcon")
        XCTAssertEqual(id.project, "/tmp/p")
        XCTAssertEqual(fake.calls.argv.first, [
            "/usr/local/bin/am", "macros", "start-session",
            "--project", "/tmp/p", "--program", "claude-code", "--model", "opus-4.8", "--json",
        ])
    }

    func testBootPassesNameWhenGiven() async throws {
        let fake = FakeRunner(stdout: json)
        _ = try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "codex-cli", model: "gpt-5", name: "BlueFalcon")
        XCTAssertEqual(fake.calls.argv.first?.suffix(2).first, "-n")
        XCTAssertEqual(fake.calls.argv.first?.last, "BlueFalcon")   // -n BlueFalcon before --json? see impl note
    }

    func testEnvironmentDelta() {
        let env = FlywheelIdentity(agentName: "RedOtter", project: "/tmp/p").environment
        XCTAssertEqual(env["AGENT_NAME"], "RedOtter")
        XCTAssertEqual(env["AGENT_MAIL_AGENT"], "RedOtter")
        XCTAssertEqual(env["AGENT_MAIL_PROJECT"], "/tmp/p")
    }

    func testNonZeroExitThrows() async {
        let fake = FakeRunner(stdout: "", exitCode: 1)
        do { _ = try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "claude-code", model: "m", name: nil)
            XCTFail("expected throw")
        } catch {}
    }

    func testUnparseableStdoutThrows() async {
        let fake = FakeRunner(stdout: "not json")
        do { _ = try await FlywheelCoordinator(runner: fake, amPath: "am")
            .boot(project: "/tmp/p", program: "claude-code", model: "m", name: nil)
            XCTFail("expected throw")
        } catch {}
    }
}
```

- [ ] **Step 2: Run tests, verify fail** — `./scripts/test-unit.sh`. Expected: FAIL (types undefined).

- [ ] **Step 3: Implement.** `FlywheelIdentity` with the computed `environment`. `FlywheelProcessRunner` protocol + `SystemFlywheelProcessRunner` using `Process`/`Pipe` (stdout pipe drained before `waitUntilExit`, per `LoginShellPath.defaultRun`; run off the main actor). `FlywheelCoordinator.boot`: build args `["macros","start-session","--project",project,"--program",program,"--model",model] + (name.map { ["-n", $0] } ?? []) + ["--json"]`; call runner; on non-zero exit throw `FlywheelError.startSession(exitCode:stderrOrStdout:)`; decode `{ "agent": { "name": String } }` (a minimal `Decodable`) or throw `FlywheelError.unparseable`. `amPath` resolved once via a login-shell `command -v am` lookup (reuse `LoginShellPath`), defaulting to `"am"`. *(Adjust the `-n`/`--json` ordering assertion in Step 1 to match the arg order you implement.)*

- [ ] **Step 4: Run tests, verify pass.** — `./scripts/test-unit.sh`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): identity + am start-session coordinator"`

---

## Task 3: `FlywheelProjectProbe` (marker detection)

**Files:**
- Create: `Sources/FlightDeck/Flywheel/FlywheelProjectProbe.swift`
- Test: `Tests/FlightDeckTests/Flywheel/FlywheelProjectProbeTests.swift`

**Interfaces:**
- Produces: `struct FlywheelStatus: Equatable { var hasBeads: Bool; var hasAgentMailMarker: Bool; var guardInstalled: Bool; var beadsSyncHooksInstalled: Bool; var isFlywheelProject: Bool { hasBeads || hasAgentMailMarker }; var needsSetup: Bool { isFlywheelProject && !(guardInstalled && beadsSyncHooksInstalled) } }` and `enum FlywheelProjectProbe { static func status(of repo: URL, fileManager: FileManager = .default) -> FlywheelStatus }`.

- [ ] **Step 1: Write failing tests** using temp fixture dirs:

```swift
import XCTest
@testable import FlightDeck

final class FlywheelProjectProbeTests: XCTestCase {
    private func tempRepo(_ build: (URL) throws -> Void) rethrows -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fw-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try build(dir); return dir
    }

    func testNoMarkers() {
        let s = FlywheelProjectProbe.status(of: tempRepo { _ in })
        XCTAssertFalse(s.isFlywheelProject); XCTAssertFalse(s.needsSetup)
    }

    func testBeadsAndAgentMailDetected() throws {
        let repo = try tempRepo { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".beads"), withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(".agent-mail.yaml"))
        }
        let s = FlywheelProjectProbe.status(of: repo)
        XCTAssertTrue(s.hasBeads); XCTAssertTrue(s.hasAgentMailMarker)
        XCTAssertTrue(s.isFlywheelProject); XCTAssertTrue(s.needsSetup) // guard/hooks absent
    }

    func testGuardDetectedViaHookMarker() throws {
        let repo = try tempRepo { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".beads"), withIntermediateDirectories: true)
            let hooks = dir.appendingPathComponent(".git/hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try "50-agent-mail.py".write(to: hooks.appendingPathComponent("pre-commit"),
                                         atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(FlywheelProjectProbe.status(of: repo).guardInstalled)
    }
}
```

- [ ] **Step 2: Run, verify fail** — `./scripts/test-unit.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** with `FileManager` checks: `hasBeads` = `.beads/` is a directory; `hasAgentMailMarker` = `.agent-mail.yaml` exists; `guardInstalled` = `.git/hooks/pre-commit` exists and its contents mention the Agent-Mail chain-runner (`agent-mail` / `50-agent-mail`); `beadsSyncHooksInstalled` = `.git/hooks/pre-commit`/`post-checkout` exist and mention `br sync`. Pure, no mutation, no shell-out.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): project marker probe"`

---

## Task 4: `FlywheelSetup.enable` (guard + beads-sync hooks)

**Files:**
- Create: `Sources/FlightDeck/Flywheel/FlywheelSetup.swift`
- Test: `Tests/FlightDeckTests/Flywheel/FlywheelSetupTests.swift`

**Interfaces:**
- Consumes: `FlywheelProcessRunner`, `FlywheelProjectProbe`.
- Produces: `struct FlywheelSetup { let runner: FlywheelProcessRunner; let amPath: String; func enable(repo: URL) async throws -> [String] }` returning the list of setup steps actually run (so the UI can report). Idempotent: skips steps the probe reports already present.

- [ ] **Step 1: Write failing tests** (fake runner asserts `am guard install <abs> <abs>` is issued when guard absent, skipped when present; beads-sync hook file is written when absent):

```swift
func testInstallsGuardWhenAbsent() async throws {
    let repo = /* temp repo with .beads, no guard hook */
    let fake = FakeRunner(stdout: "")
    let ran = try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: repo)
    XCTAssertTrue(fake.calls.argv.contains { $0 == ["am","guard","install", repo.path, repo.path] })
    XCTAssertTrue(ran.contains("am guard install"))
}

func testSkipsGuardWhenPresent() async throws {
    let repo = /* temp repo whose pre-commit already mentions 50-agent-mail */
    let fake = FakeRunner(stdout: "")
    _ = try await FlywheelSetup(runner: fake, amPath: "am").enable(repo: repo)
    XCTAssertFalse(fake.calls.argv.contains { $0.contains("guard") })
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement:** probe first; if `!guardInstalled` run `am guard install <abs> <abs>` (throw on non-zero); if `!beadsSyncHooksInstalled` write a minimal `pre-commit`/`post-checkout` that runs `br sync --flush-only` and `git add .beads` (chain to any existing hook the same way `am guard` does — move existing to `.orig` and chain; if `am guard` already installed the chain-runner, append the `br sync` step instead of clobbering). Return the human-readable step list. Do **not** set `flywheelEnabled` here — that is the store's job on success (Task 8).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): one-time repo setup (guard + beads sync)"`

---

## Task 5: `FlywheelIdentity` persistence (Session + snapshot)

**Files:**
- Modify: `Sources/FlightDeck/SessionModel.swift` (add `Session.flywheelIdentity`), `Sources/FlightDeck/SessionPersistence.swift` (add `Entry.flywheelAgentName`), `Sources/FlightDeck/SessionStore.swift` (snapshot map both directions)
- Test: `Tests/FlightDeckTests/FlywheelIdentityPersistenceTests.swift`

**Interfaces:**
- Produces: `Session.flywheelIdentity: FlywheelIdentity?`; `SessionSnapshot.Entry.flywheelAgentName: String?`.
- Consumes: `FlywheelIdentity` (Task 2). Note only the **name** is persisted; `project` is re-derived from the session's `workingDirectory` on restore.

- [ ] **Step 1: Write failing tests** — snapshot Entry round-trips `flywheelAgentName`; legacy JSON without it decodes to nil; the store's snapshot→session and session→snapshot maps carry the name (reconstruct `FlywheelIdentity(agentName:project:)` from `flywheelAgentName` + `workingDirectory`). Include a legacy-decode test mirroring `ProjectSettings` Task 1.

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.**
  - `Session`: add `var flywheelIdentity: FlywheelIdentity?` (non-persisted-shape in-memory field) + init param defaulting nil (keep the 140 `newSession` callers compiling — default arg).
  - `Entry`: add `var flywheelAgentName: String?` (Optional, `decodeIfPresent` — copy the doc-comment idiom from the neighbouring optional fields) + init param.
  - `SessionStore` snapshot write: set `flywheelAgentName: session.flywheelIdentity?.agentName`. Snapshot read/restore: `flywheelIdentity = entry.flywheelAgentName.map { FlywheelIdentity(agentName: $0, project: <restored workingDirectory standardized>) }`. Find the two map sites by searching `SessionStore.swift` for where `Entry(` is constructed (save) and where a restored `Session(` is built from an `Entry` (load).
- [ ] **Step 4: Run, verify pass** (+ existing persistence tests stay green — the back-compat assertion).
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): persist agent identity across relaunch"`

---

## Task 6: Inject `AGENT_NAME` into the PTY env

**Files:**
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (`sessionEnvironment`), `Sources/FlightDeck/SessionStore.swift` (the two surface-config assignment sites)
- Test: `Tests/FlightDeckTests/SessionEnvironmentFlywheelTests.swift`

**Interfaces:**
- Consumes: `FlywheelIdentity`, `Session.flywheelIdentity`.
- Produces: `sessionEnvironment(for:flywheel:inherited:)` — a new optional `flywheel: FlywheelIdentity? = nil` param whose `environment` delta is merged last.

- [ ] **Step 1: Write failing tests:**

```swift
func testIdentityAddsAgentNameVars() {
    let store = /* PreferencesStore over a temp defaults */
    let env = store.sessionEnvironment(
        for: nil, flywheel: FlywheelIdentity(agentName: "BlueFalcon", project: "/tmp/p"))
    XCTAssertEqual(env["AGENT_NAME"], "BlueFalcon")
    XCTAssertEqual(env["AGENT_MAIL_PROJECT"], "/tmp/p")
}

func testNoIdentityLeavesEnvUnchanged() {
    let store = /* … */
    XCTAssertEqual(store.sessionEnvironment(for: nil), store.sessionEnvironment(for: nil, flywheel: nil))
    XCTAssertNil(store.sessionEnvironment(for: nil, flywheel: nil)["AGENT_NAME"])
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** Add the param to `sessionEnvironment`; after the existing `FD_OUTLOG_BUDGET` line, `if let flywheel { environment.merge(flywheel.environment) { _, new in new } }`. At the two surface sites (`SessionStore.insertSession` ~:2237 and `makeAttachSurface` ~:1206), pass `flywheel: session.flywheelIdentity` in the `sessionEnvironment(...)` call. (Both sites have `session` in scope.)
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): inject AGENT_NAME into session env"`

---

## Task 7: Spawn bootstrap wiring (claude async route + codex) — the crux

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`, `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift`
- Test: `Tests/FlightDeckTests/Flywheel/FlywheelSpawnTests.swift` (with a fake `FlywheelProcessRunner` injected into the store)

**Interfaces:**
- Consumes: `FlywheelCoordinator`, `Session.flywheelIdentity`, `ProjectSettings.flywheelEnabled`.
- Produces: an internal `SessionStore.bootFlywheelIdentityIfNeeded(agent:project:name:) async -> FlywheelIdentity?` (nil when the project is not flywheel-enabled) and a `newSession(..., flywheelIdentity: FlywheelIdentity?)` internal overload that stamps `session.flywheelIdentity` before `addSession`.

Read the region `SessionStore.swift:1611-1810` (the create cluster, already summarized in the spec) before editing.

- [ ] **Step 1: Write failing tests** — with the store's coordinator faked to return `BlueFalcon`:
  - Creating a **claude** session in a flywheel-enabled project yields a session whose `flywheelIdentity?.agentName == "BlueFalcon"` and whose surface env (via `sessionEnvironment(for:flywheel:)`) contains `AGENT_NAME`.
  - Creating a claude session in a **non-flywheel** project yields `flywheelIdentity == nil` and runs **no** coordinator call (fake asserts zero argv).
  - A codex session in a flywheel project likewise gets the identity.
  - `boot` failure surfaces through `launchFailureReporter` and returns `.failure` (no half-built tab).

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.**
  - Inject a `FlywheelCoordinator` into `SessionStore` (constructor default = system runner; tests pass a fake).
  - `bootFlywheelIdentityIfNeeded`: if `preferences.projectSettings(project).flywheelEnabled == true`, call `coordinator.boot(project: key(project), program: FlywheelProgram.rawValue(for: agent), model: <derive from options(for:project:)>, name: existingName)`; else return nil. Throwing surfaces as an `AgentLaunchError` via `launchFailureReporter` (mirror the neighbouring `launchAccount` failure branch).
  - **Claude routing:** the async `createSession` already delegates claude to `newSession` (sync). Change that branch so that, when flywheel-enabled, it first `await bootFlywheelIdentityIfNeeded(...)`, then calls the new `newSession(..., flywheelIdentity:)` overload that stamps the identity onto the `Session` before `addSession`. Then **route the flywheel-relevant claude-creation entry points through `createSession`**: enumerate the direct `newSession(in:)` callers that create user-facing claude tabs (⌘N / New Tab / New-session-in-project / the New Session dropdown / drop-to-add) — search `SessionStore.swift` and the command/menu layer for `newSession(in:` — and, when the target project is flywheel-enabled, dispatch through `Task { await createSession(agent: .claude, in: …) }` instead. Leave `seedInitialSession` (home dir, never flywheel) and all non-flywheel spawns on the untouched sync path.
  - **Codex:** in `createSession`'s codex branch, after the account resolves, `await bootFlywheelIdentityIfNeeded(agent: .codex, …)` and stamp the identity on the rebuilt `session` (the `Session(id: draft.id, …)` at ~:1797). (Codex already runs on the async path, so no re-routing.)
  - **Wake re-injection:** in `makeAttachSurface`, if `session.flywheelIdentity != nil`, fire a detached `Task` to `coordinator.boot(name: storedName)` to refresh the lease/inbox idempotently — but the env re-injection itself already happens synchronously via Task 6 (the identity is on the persisted session). The refresh is best-effort; a failure logs, does not block the surface.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): bootstrap agent identity on spawn (claude+codex)"`

---

## Task 8: Opt-in affordance + one-time setup

**Files:**
- Modify: `Sources/FlightDeck/SessionSidebar.swift` / `Sources/FlightDeck/ProjectHeaderRow.swift`, `Sources/FlightDeck/SessionStore.swift` (project-add probe + `enableFlywheel(for:)`)
- Test: `Tests/FlightDeckTests/Flywheel/FlywheelEnableFlowTests.swift`

**Interfaces:**
- Produces: `SessionStore.enableFlywheel(for repo: URL) async` — runs `FlywheelSetup.enable`, and on success `setProjectSettings` with `flywheelEnabled = true`; on failure reports via `launchFailureReporter` and leaves the flag false.
- Produces: `SessionStore.flywheelSuggestion(for repo: URL) -> FlywheelStatus?` cached from the project-add probe.

- [ ] **Step 1: Write failing tests** — `enableFlywheel` with a fake setup: success sets `projectSettings(path).flywheelEnabled == true`; setup-throw leaves it nil and reports a failure. Probe-on-add sets a suggestion for a marker-bearing fixture repo and nil otherwise.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.**
  - Probe at the project-add choke point: in `SessionStore.insertSession`'s new-repo branch (~:2179-2192, where `repos.append(Repo(url:))` + `.projectAdded`), compute `FlywheelProjectProbe.status(of: url)` and stash it (a `[String: FlywheelStatus]` keyed by `key(path)`) if `isFlywheelProject`. Do not probe on the spawn hot path.
  - `enableFlywheel(for:)` as above.
  - UI: a project context-menu item "Enable Flywheel coordination…" on `ProjectHeaderRow` (shown when a suggestion exists or always, disabled/checked when already enabled), opening a confirmation sheet that lists the exact steps `FlywheelSetup` will run (from a dry `FlywheelProjectProbe` diff), with Cancel / Enable. Enable calls `enableFlywheel`. Keep the UI minimal — no other surfaces.
- [ ] **Step 4: Run, verify pass** (logic tests; the sheet itself is exercised by the smoke test).
- [ ] **Step 5: Commit** — `git commit -am "feat(flywheel): opt-in menu + confirmed one-time setup"`

---

## Task 9: Real-agent smoke test

**Files:**
- Create: `scripts/flywheel-smoke.sh`, `docs/FLYWHEEL-SMOKE-CHECKLIST.md`

**Interfaces:** none (operational).

- [ ] **Step 1: Write `scripts/flywheel-smoke.sh`** — a guarded, on-demand harness (not wired into CI). It must: refuse to run unless `FLYWHEEL_SMOKE=1` is set (so it never runs unattended, per the project's focus-stealing-smoke-test norm); create an **isolated** scratch repo via `flywheel-new` under a temp dir; print the manual FD steps (enable flywheel in FD for the scratch repo; spawn two agents; give each a one-line non-interactive task: claim a specific bead, reserve a file, attempt a commit); then run a **verifier** that reads the substrate and asserts, printing PASS/FAIL per check:
  1. two distinct `AGENT_NAME`s registered (`am agents --project <repo> --json`);
  2. a conflicting commit was blocked — grep the captured commit output for `mcp-agent-mail: file reservation conflict detected!`;
  3. both bead claims visible (`br list --json` shows two `in_progress` beads with distinct assignees).
- [ ] **Step 2: Write `docs/FLYWHEEL-SMOKE-CHECKLIST.md`** — the human runbook: prerequisites, the exact FD clicks, expected observations, teardown (`am`/scratch cleanup), and a note that it consumes tokens and steals focus (alert before running).
- [ ] **Step 3: Shellcheck / dry-run** the script's non-agent paths (fixture verifier against a hand-seeded scratch repo) — `bash -n scripts/flywheel-smoke.sh` and run the verifier against a mocked `.beads`/`am` state to confirm the assertions parse.
- [ ] **Step 4: Commit** — `git commit -am "test(flywheel): on-demand real-agent smoke harness + checklist"`

---

## Self-Review

**Spec coverage:** flag (T1); coordinator/start-session + env delta (T2); probe (T3); guard/sync setup (T4); identity persistence (T5); AGENT_NAME injection (T6); claude async route + codex bootstrap + wake (T7); opt-in + confirmed setup (T8); real-agent smoke test (T9). Non-goals (no observe UI, no convergence/encode, no worktree mode) are respected. ✅

**Placeholder scan:** test bodies that reference "/* … */" fixtures (T4/T6/T8) are helper-construction stubs, not logic placeholders — each names exactly what the fixture must contain; the implementer builds the trivial temp-dir/defaults helper. No "TBD/add error handling" anywhere. ✅

**Type consistency:** `FlywheelIdentity{agentName,project,environment}`, `FlywheelProcessRunner.run`, `FlywheelCoordinator.boot`, `FlywheelProgram.rawValue(for:)`, `FlywheelStatus`, `Session.flywheelIdentity`, `Entry.flywheelAgentName`, `sessionEnvironment(for:flywheel:inherited:)` used consistently T1→T9. ✅

## Verification

- **Unit:** `./scripts/test-unit.sh` — all new tests pass; full suite stays green; back-compat decode tests (T1, T5) prove existing state survives.
- **Non-regression:** a non-flywheel project: coordinator never invoked (T7 asserts zero argv), env byte-for-byte unchanged (T6), claude stays on the synchronous path.
- **Real-agent E2E:** `FLYWHEEL_SMOKE=1 ./scripts/flywheel-smoke.sh`, run deliberately (focus-aware), asserts distinct AGENT_NAMEs, a blocked conflicting commit with the exact guard message, and both bead claims visible — closing Spike A's simulated-vs-real gap.

*Executed in a git worktree (per project worktree norms — symlink `vendor/*-artifacts` so it builds; use built-in `Edit`, not quillmap mutators, in the worktree); the spec + this plan commit on that branch, never shared `master`.*
