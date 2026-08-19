# Fleet Replication Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replicate the live fleet — projects, sessions, status, sub-agent count, unread — out of `SessionStore` to a remote client over one mutually-authenticated WebSocket, with resume, and prove it end-to-end without a phone.

**Architecture:** A new `FleetKit` framework, built for **both** macOS and iOS from one source directory, holds the wire value types, the event fold, snapshot application, the frame codec, the TLS-PSK parameter factory, and both socket halves. It imports `Foundation` and `Network` and nothing else — the iOS slice is what enforces that. `SessionStore` gains one optional sink (`replicator`, injected exactly like `notifier`) that every fleet-state mutation reports to; `FleetReplicator` keeps a mirror snapshot plus a bounded ring, and in DEBUG asserts the mirror still equals a fresh projection of the store after every batch. That assertion is the only thing standing between a new mutation site and a silently stale client.

**Tech Stack:** Swift 6 (FleetKit) / Swift 5 (app) / Network.framework / XCTest / xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` — read §3, §4, §5 and §10 before Task 1. The plan argues from the spec; where this document says "because", the spec says why at length. The deferred refactor this plan's assertion stands in for is `docs/superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md`.

**Scope:** slice 1a's *spine*. No pairing UI, no Bonjour, no iOS app, no timeline — those are `2026-08-19-fleet-pairing-and-ios.md` (pairing + phone) and slice 1b (timeline). This plan ends with a headless test in which a real `FleetClient` completes a TLS-PSK handshake against a real `FleetSocketServer`, receives a snapshot of a live `SessionStore`, follows its mutations, resumes after a drop, and marks a session read.

## Global Constraints

- `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate — vendored Ghostty is not Swift-6 clean. **Never "fix" it.** The new `FleetKit` targets override it to `6.0` in their own `settings.base`; a Swift 6 module imports into a Swift 5 target without complaint.
- Deployment targets: macOS 14.0 (existing), iOS 17.0 (added by Task 1).
- **`FleetKit` may import `Foundation` and `Network` only.** No AppKit, no UIKit, no SwiftUI, and nothing from the `FlightDeck` module. It must not use `Session`, `Repo`, `SessionStatus` or `AgentID` — those carry desktop-only fields (`transcriptDirectory`, `transcriptPath`) and live in a module FleetKit cannot see. Wire types are trimmed structs that duplicate only what a client renders.
- **No iOS Simulator runtime is installed on this machine** (`xcrun simctl list runtimes` is empty) and there is no provisioning profile. The iOS slice is therefore **compile-checked only** (`./scripts/build-ios.sh`), and every behavioural test in this plan runs in the existing macOS headless bundle. Do not add an iOS test target.
- TDD, and **confirm the test fails against the missing/broken code before implementing.** Never weaken an assertion to go green.
- Comments explain *why* and name the failure they prevent. That is the house style; match it.
- Tests are XCTest: `final class XTests: XCTestCase` + `import FleetKit` (plain, not `@testable` — anything a test needs is `public`, which keeps the public API honest) and `@testable import FlightDeck` where a test touches the app.
- Test loop is `./scripts/test-unit.sh` (headless). **Never run `./scripts/smoke.sh`** for this feature — it seizes the foreground for ~70s and captures the user's keystrokes as phantom failures.
- **Never launch a bundle from `DerivedData/`.** Flight Deck has no argv parsing, so even `--help` boots a second full app instance that spawns duplicate `claude --resume` processes. Verification here is "build succeeds + unit tests pass".
- This checkout is **shared by concurrent sessions.** Never `git stash`, `git checkout .`, or revert. Stage only the files you touched, by name.
- Commits: lowercase, behavioral, imperative subject; body covers mechanism, evidence, and rejected alternatives; trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Every `xcodebuild` needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `-derivedDataPath DerivedData` — the scripts handle both. Never `sudo xcode-select`.

---

### Task 1: `FleetKit` — a two-platform module, and the build wiring that proves it

This task delivers no behaviour. It exists because every wiring hazard in the plan lives here, and finding them at Task 11 instead of Task 1 is what makes a plan overrun: a new framework target, its Swift-6 override, embedding into the app, the test bundle's `@rpath` lookup, and an iOS slice compiled from the same sources. One trivial public type is enough to prove all five.

The iOS framework target is not premature. It is the **enforcement mechanism** for the "Foundation and Network only" constraint — a stray `import AppKit` in FleetKit fails `./scripts/build-ios.sh` immediately, where a convention in a doc would be discovered by the phone app weeks later.

**Files:**
- Create: `Sources/FleetKit/FleetKitVersion.swift`
- Create: `scripts/build-ios.sh`
- Modify: `project.yml` (deployment target, two `FleetKit` targets, dependencies)
- Modify: `scripts/test-unit.sh` (framework search path)
- Test: `Tests/FlightDeckTests/FleetKitModuleTests.swift`

**Interfaces:**
- Produces: module `FleetKit`, importable from `FlightDeck` and from `FlightDeckTests`; `public enum FleetKitVersion { public static let wire = 1 }`. Every later task adds to this module.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetKitModuleTests.swift`:

```swift
import XCTest
import FleetKit

/// Proves the module boundary itself, which is the thing most likely to be broken by a
/// build-file edit rather than by code: FleetKit is a real framework, it is embedded in the
/// app, and the headless test bundle can resolve it at load time. A plain `import` — not
/// `@testable` — because everything the phone needs is `public`, and a test that reached in
/// through `@testable` would stop noticing when something was accidentally left internal.
final class FleetKitModuleTests: XCTestCase {
    func testTheModuleIsLinkedAndItsPublicSurfaceIsReachable() {
        XCTAssertEqual(FleetKitVersion.wire, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — compilation error, `no such module 'FleetKit'`.

- [ ] **Step 3: Create the module's one source file**

Create `Sources/FleetKit/FleetKitVersion.swift`:

```swift
import Foundation

/// The wire contract's version, sent in no frame yet and bumped by nothing yet — it exists
/// so that when the phone and the Mac disagree there is somewhere to say so, rather than a
/// version field being retrofitted into a protocol that already has clients.
public enum FleetKitVersion {
    public static let wire = 1
}
```

- [ ] **Step 4: Add both platform targets to `project.yml`**

In `options.deploymentTarget`, add the iOS floor:

```yaml
options:
  bundleIdPrefix: dev.flightdeck
  deploymentTarget:
    macOS: "14.0"
    iOS: "17.0"
```

Add two targets. They share one source directory deliberately — `PRODUCT_MODULE_NAME` is pinned to `FleetKit` on both so `import FleetKit` compiles unchanged on either platform:

```yaml
  FleetKit:
    type: framework
    platform: macOS
    sources: [Sources/FleetKit]
    settings:
      base:
        # Swift 6 here, Swift 5 project-wide. The project-wide floor exists for vendored
        # Ghostty (not Swift-6 clean); FleetKit vendors nothing and carries the wire types
        # that cross a thread boundary on every frame, which is exactly the code that wants
        # `Sendable` checked rather than assumed. A Swift 6 module imports cleanly into a
        # Swift 5 target, so nothing else has to move.
        SWIFT_VERSION: "6.0"
        PRODUCT_MODULE_NAME: FleetKit
        GENERATE_INFOPLIST_FILE: "YES"

  # Same sources, iOS slice. This target ships nothing on its own — it is the enforcement
  # mechanism for "FleetKit imports Foundation and Network only". An `import AppKit` that
  # slipped into the shared sources compiles fine for macOS and fails here, which is the
  # only cheap way to catch it before the phone app exists. See scripts/build-ios.sh.
  FleetKitiOS:
    type: framework
    platform: iOS
    sources: [Sources/FleetKit]
    settings:
      base:
        SWIFT_VERSION: "6.0"
        PRODUCT_MODULE_NAME: FleetKit
        GENERATE_INFOPLIST_FILE: "YES"
        CODE_SIGNING_ALLOWED: "NO"
```

Add the dependency to the app target (inside the existing `FlightDeck.dependencies` list, alongside the GhosttyKit framework entry):

```yaml
      - target: FleetKit
        embed: true
```

And to the test bundle (inside `FlightDeckTests.dependencies`, alongside `- target: FlightDeck`):

```yaml
      # Linked, not embedded: the copy inside "Flight Deck.app/Contents/Frameworks" is the
      # one that loads at runtime. See the DYLD_FRAMEWORK_PATH note in scripts/test-unit.sh.
      - target: FleetKit
        embed: false
```

- [ ] **Step 5: Teach the headless runner where the framework lives**

`scripts/test-unit.sh` runs the `.xctest` bundle outside its host app, so the bundle's
`@rpath/FleetKit.framework/...` lookup has nothing to resolve against. Add the app's
`Frameworks` directory to the search path. Replace the final two lines of the script:

```bash
APPFRAMEWORKS="$PWD/${PRODUCTS}/Flight Deck.app/Contents/Frameworks"

# Contents/Frameworks joins the search path for FleetKit.framework, which the test bundle
# links but does not embed. Without it `xctest` aborts at load with an @rpath failure that
# reads like a missing symbol rather than a missing directory.
DYLD_LIBRARY_PATH="$APPMACOS" DYLD_FRAMEWORK_PATH="$APPMACOS:$APPFRAMEWORKS" \
  xcrun xctest "$BUNDLE"
```

- [ ] **Step 6: Add the iOS compile check**

Create `scripts/build-ios.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

# Compile-only check of the iOS slice of FleetKit.
#
# There is no iOS Simulator runtime installed on this machine and no provisioning profile,
# so nothing here can be RUN — but it can be built, and building is the whole point: this
# is what fails when FleetKit's shared sources acquire a macOS-only import. `-target`
# rather than `-scheme` deliberately, so this does not depend on Xcode having autocreated
# a scheme for a target that is never run.
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -target FleetKitiOS \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath DerivedData build
```

Then: `chmod +x scripts/build-ios.sh`

- [ ] **Step 7: Run both checks to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, including `FleetKitModuleTests`.

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/FleetKitVersion.swift scripts/build-ios.sh scripts/test-unit.sh \
        project.yml Tests/FlightDeckTests/FleetKitModuleTests.swift
git commit -m "build: add FleetKit, a wire module compiled for macOS and iOS alike"
```

---

### Task 2: The wire value types

What a client renders, and nothing more. These are **not** `Session`/`Repo`/`SessionStatus`: those carry `transcriptDirectory`, `transcriptPath` and `pinnedConversationID`, which are desktop path-derivation details that no client should ever see, and they live in a module FleetKit cannot import. Duplicating five fields is the cost of that boundary and it is the right price.

`agent` is a `String`, not `AgentID`, for the same reason — and the round-trip test pins that an unknown agent decodes rather than throwing, because a Mac running a newer Flight Deck than the phone is the ordinary case, not the exotic one.

**Files:**
- Create: `Sources/FleetKit/Wire.swift`
- Test: `Tests/FlightDeckTests/FleetWireTests.swift`

**Interfaces:**
- Produces: `public struct FleetSnapshot`, `public struct WireProject`, `public struct WireSession`. Consumed by every later task.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetWireTests.swift`:

```swift
import XCTest
import FleetKit

final class FleetWireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testASnapshotSurvivesAnEncodeDecodeRoundTrip() throws {
        let snapshot = FleetSnapshot(projects: [
            WireProject(
                id: UUID(), name: "flight-deck", path: "/w/flight-deck", isCollapsed: false,
                sessions: [
                    WireSession(
                        id: UUID(), title: "mobile", agent: "claude",
                        activity: "busy", waitingFor: nil, subagentCount: 2, isUnread: false
                    )
                ]
            )
        ])
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    /// A session with no agent process is NOT idle — it is statusless, and the two render
    /// differently (nothing versus a dot). `nil` has to survive the wire or every dead tab
    /// on the phone looks alive.
    func testAStatuslessSessionStaysStatuslessAcrossTheWire() throws {
        let session = WireSession(
            id: UUID(), title: "dormant", agent: "codex",
            activity: nil, waitingFor: nil, subagentCount: 0, isUnread: true
        )
        XCTAssertNil(try roundTrip(session).activity)
    }

    /// The Mac may be running a newer Flight Deck than the phone. An agent the client has
    /// never heard of must arrive as an unrenderable-but-present string rather than
    /// throwing and taking the whole snapshot down with it — which is what a client-side
    /// `AgentID` enum would have done.
    func testAnUnknownAgentDecodesRatherThanThrowing() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"t","agent":"gemini",
         "subagentCount":0,"isUnread":false}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WireSession.self, from: json).agent, "gemini")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetSnapshot' in scope`.

- [ ] **Step 3: Write the wire types**

Create `Sources/FleetKit/Wire.swift`:

```swift
import Foundation

/// The whole fleet as a client sees it: the sidebar, flattened to values.
///
/// Deliberately not `[Repo]`. `Repo` and `Session` live in the app module and carry fields
/// that exist only to derive paths on the Mac — `transcriptDirectory`, `transcriptPath`,
/// `pinnedConversationID`. Shipping them would put the Mac's filesystem layout on a phone's
/// disk for no rendering benefit, and would drag the app module across a boundary FleetKit
/// exists to hold.
public struct FleetSnapshot: Codable, Equatable, Sendable {
    public var projects: [WireProject]

    public init(projects: [WireProject] = []) {
        self.projects = projects
    }

    public static let empty = FleetSnapshot()
}

public struct WireProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// The project root, shown as a subtitle and used for nothing else. A client never
    /// opens it — it has no filesystem in common with the Mac.
    public var path: String
    public var isCollapsed: Bool
    public var sessions: [WireSession]

    public init(
        id: UUID, name: String, path: String, isCollapsed: Bool = false,
        sessions: [WireSession] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isCollapsed = isCollapsed
        self.sessions = sessions
    }
}

public struct WireSession: Codable, Equatable, Sendable, Identifiable {
    /// The tab's id, which is the only stable key a client may hold. Never the conversation
    /// id: that is not stable across a re-pin and, for codex, differs from the tab id from
    /// birth.
    public let id: UUID
    public var title: String
    /// `AgentID.rawValue`, carried as a plain `String` on purpose. A client-side enum would
    /// throw on an agent added after the client shipped, taking the entire snapshot down
    /// with it; an unrecognised string just renders without a glyph.
    public var agent: String
    /// `SessionActivity.rawValue`, or `nil` for "no agent process registered".
    /// `nil` is NOT `"idle"` — a statusless tab renders nothing where an idle one renders a
    /// dot, and collapsing the two makes every dead tab look alive.
    public var activity: String?
    /// Why the session is blocked, verbatim from the agent, when `activity == "waiting"`.
    public var waitingFor: String?
    public var subagentCount: Int
    public var isUnread: Bool

    public init(
        id: UUID, title: String, agent: String,
        activity: String? = nil, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
        self.isUnread = isUnread
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/Wire.swift Tests/FlightDeckTests/FleetWireTests.swift
git commit -m "feat: describe the fleet on the wire without the Mac's path details"
```

---

### Task 3: `FleetEvent` and snapshot application

The delta vocabulary, and the function that folds a delta into a snapshot. Both live in FleetKit rather than in the app, and that placement is the point of §10 in the spec: the client applies deltas using **the same code** that produced them, so an application bug cannot be a disagreement between two implementations.

The non-obvious requirement is that **an event naming something the snapshot does not contain must be a no-op, never a trap.** A client that resumed across a gap, or that raced a re-snapshot, will see them; crashing on the phone because the Mac closed a project is not a trade anyone would make.

**Files:**
- Create: `Sources/FleetKit/FleetEvent.swift`
- Create: `Sources/FleetKit/SnapshotApplication.swift`
- Test: `Tests/FlightDeckTests/FleetEventApplicationTests.swift`

**Interfaces:**
- Consumes: `FleetSnapshot`, `WireProject`, `WireSession` (Task 2).
- Produces: `public enum FleetEvent` with the eleven cases listed below; `public enum RenameOrigin: String { case user, agent }`; `FleetSnapshot.apply(_:)` (mutating) and `FleetSnapshot.applying(_:)` (`[FleetEvent] -> FleetSnapshot`). Tasks 4, 8, 9, 10 and 11 all depend on these exact case labels.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetEventApplicationTests.swift`:

```swift
import XCTest
import FleetKit

final class FleetEventApplicationTests: XCTestCase {
    private let projectID = UUID()
    private let sessionID = UUID()

    private func session(_ id: UUID, _ title: String) -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func base() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "flight-deck", path: "/w/fd",
                        sessions: [session(sessionID, "one")])
        ])
    }

    // MARK: Sessions

    func testASessionIsAddedIntoItsProjectAtTheGivenIndex() {
        let newID = UUID()
        let after = base().applying([
            .sessionAdded(session(newID, "zero"), project: projectID, at: 0)
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [newID, sessionID])
    }

    /// An out-of-range index appends rather than trapping. The index came off a wire from a
    /// machine whose fleet has moved on since; a client must never crash on one.
    func testAnOutOfRangeInsertionAppends() {
        let newID = UUID()
        let after = base().applying([
            .sessionAdded(session(newID, "last"), project: projectID, at: 99)
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [sessionID, newID])
    }

    func testASessionIsRemoved() {
        XCTAssertTrue(base().applying([.sessionRemoved(id: sessionID)]).projects[0].sessions.isEmpty)
    }

    func testRenamingChangesTheTitle() {
        let after = base().applying([.renamed(id: sessionID, title: "two", origin: .user)])
        XCTAssertEqual(after.projects[0].sessions[0].title, "two")
    }

    func testActivityCarriesItsWholeTripleTogether() {
        let after = base().applying([
            .activityChanged(id: sessionID, activity: "waiting",
                             waitingFor: "permission prompt", subagentCount: 0)
        ])
        XCTAssertEqual(after.projects[0].sessions[0].activity, "waiting")
        XCTAssertEqual(after.projects[0].sessions[0].waitingFor, "permission prompt")
    }

    /// Statuslessness is a real state and has to be reachable by an event, or a tab whose
    /// agent exited would keep rendering the status it had when it died.
    func testActivityCanReturnToNil() {
        var snapshot = base().applying([
            .activityChanged(id: sessionID, activity: "busy", waitingFor: nil, subagentCount: 3)
        ])
        snapshot = snapshot.applying([
            .activityChanged(id: sessionID, activity: nil, waitingFor: nil, subagentCount: 0)
        ])
        XCTAssertNil(snapshot.projects[0].sessions[0].activity)
        XCTAssertEqual(snapshot.projects[0].sessions[0].subagentCount, 0)
    }

    func testUnreadFlips() {
        let after = base().applying([.unreadChanged(id: sessionID, isUnread: true)])
        XCTAssertTrue(after.projects[0].sessions[0].isUnread)
    }

    func testAMoveTakesTheSessionOutOfItsOldProject() {
        let other = UUID()
        var snapshot = base()
        snapshot.projects.append(WireProject(id: other, name: "b", path: "/w/b"))
        let after = snapshot.applying([.sessionMoved(id: sessionID, project: other, at: 0)])
        XCTAssertTrue(after.projects[0].sessions.isEmpty)
        XCTAssertEqual(after.projects[1].sessions.map(\.id), [sessionID])
    }

    // MARK: Projects

    func testAProjectIsAddedAndRemoved() {
        let newID = UUID()
        var snapshot = base().applying([
            .projectAdded(WireProject(id: newID, name: "b", path: "/w/b"), at: 0)
        ])
        XCTAssertEqual(snapshot.projects.map(\.id), [newID, projectID])
        snapshot = snapshot.applying([.projectRemoved(id: newID)])
        XCTAssertEqual(snapshot.projects.map(\.id), [projectID])
    }

    func testCollapseIsCarried() {
        XCTAssertTrue(
            base().applying([.projectCollapsed(id: projectID, isCollapsed: true)])
                .projects[0].isCollapsed
        )
    }

    func testProjectsAreReorderedByTheGivenOrder() {
        let other = UUID()
        var snapshot = base()
        snapshot.projects.append(WireProject(id: other, name: "b", path: "/w/b"))
        let after = snapshot.applying([.projectsReordered(order: [other, projectID])])
        XCTAssertEqual(after.projects.map(\.id), [other, projectID])
    }

    /// An order naming ids the client does not have — because a project was closed in the
    /// gap — must reorder what it can and keep the rest, not drop rows it was never told
    /// to remove.
    func testAReorderNamingUnknownIDsKeepsEveryProjectItDidNotMention() {
        let ghost = UUID()
        let after = base().applying([.projectsReordered(order: [ghost, projectID])])
        XCTAssertEqual(after.projects.map(\.id), [projectID])
    }

    func testSessionsAreReorderedWithinTheirProject() {
        let second = UUID()
        var snapshot = base()
        snapshot.projects[0].sessions.append(session(second, "two"))
        let after = snapshot.applying([
            .sessionsReordered(project: projectID, order: [second, sessionID])
        ])
        XCTAssertEqual(after.projects[0].sessions.map(\.id), [second, sessionID])
    }

    // MARK: Events about things we do not have

    /// The resume path guarantees this happens: a client that missed a removal, or that
    /// re-snapshotted mid-replay, sees events for ids it has never held. Every one must be
    /// inert.
    func testEveryEventAboutAnUnknownIDIsANoOp() {
        let ghost = UUID()
        let snapshot = base()
        let inert: [FleetEvent] = [
            .sessionRemoved(id: ghost),
            .renamed(id: ghost, title: "x", origin: .agent),
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0),
            .unreadChanged(id: ghost, isUnread: true),
            .sessionMoved(id: ghost, project: projectID, at: 0),
            .sessionAdded(session(UUID(), "x"), project: ghost, at: 0),
            .sessionsReordered(project: ghost, order: []),
            .projectRemoved(id: ghost),
            .projectCollapsed(id: ghost, isCollapsed: true)
        ]
        for event in inert {
            XCTAssertEqual(snapshot.applying([event]), snapshot, "\(event) was not inert")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetEvent' in scope`.

- [ ] **Step 3: Write the event vocabulary**

Create `Sources/FleetKit/FleetEvent.swift`:

```swift
import Foundation

/// Who changed a title. Carried because the desktop and the client want it for different
/// reasons and a diff cannot supply it: a user rename and an agent's self-rename produce
/// an identical `title` field and are different facts. Slice 3 decides notification
/// eligibility from this; the timeline will show it.
public enum RenameOrigin: String, Equatable, Sendable {
    /// The user typed it, on either machine.
    case user
    /// The agent renamed its own conversation and the sidebar followed.
    case agent
}

/// One change to the fleet, as it goes on the wire.
///
/// An enum of intents rather than a diff, for the reason the spec gives in §5: a diff
/// carries the outcome and loses why it happened, and `renamed(origin:)` is the case that
/// makes that concrete. The replay ring simply *is* this log.
public enum FleetEvent: Equatable, Sendable {
    case projectAdded(WireProject, at: Int)
    case projectRemoved(id: UUID)
    case projectCollapsed(id: UUID, isCollapsed: Bool)
    case projectsReordered(order: [UUID])

    case sessionAdded(WireSession, project: UUID, at: Int)
    case sessionRemoved(id: UUID)
    case sessionMoved(id: UUID, project: UUID, at: Int)
    case sessionsReordered(project: UUID, order: [UUID])

    case renamed(id: UUID, title: String, origin: RenameOrigin)
    /// The whole status triple at once, never one field of it. `SessionStatus` is committed
    /// as a unit by `commitStatuses`, and splitting it here would let a client render a
    /// `waitingFor` string against an activity that had already moved on.
    case activityChanged(id: UUID, activity: String?, waitingFor: String?, subagentCount: Int)
    case unreadChanged(id: UUID, isUnread: Bool)
}

extension FleetEvent {
    /// The session this event is about, if any. Used by the replay fold (Task 4) to decide
    /// what a removal makes redundant.
    var sessionID: UUID? {
        switch self {
        case .sessionAdded(let s, _, _): return s.id
        case .sessionRemoved(let id), .sessionMoved(let id, _, _),
             .renamed(let id, _, _), .activityChanged(let id, _, _, _),
             .unreadChanged(let id, _):
            return id
        case .projectAdded, .projectRemoved, .projectCollapsed,
             .projectsReordered, .sessionsReordered:
            return nil
        }
    }

    /// The project this event is about, if any.
    var projectID: UUID? {
        switch self {
        case .projectAdded(let p, _): return p.id
        case .projectRemoved(let id), .projectCollapsed(let id, _),
             .sessionsReordered(let id, _):
            return id
        case .sessionAdded, .sessionRemoved, .sessionMoved, .projectsReordered,
             .renamed, .activityChanged, .unreadChanged:
            return nil
        }
    }
}
```

- [ ] **Step 4: Write snapshot application**

Create `Sources/FleetKit/SnapshotApplication.swift`:

```swift
import Foundation

extension FleetSnapshot {
    /// Fold one event in.
    ///
    /// Every lookup failure is a silent no-op, and that is a contract rather than laziness:
    /// the resume path (§4) hands a client events about ids it may never have held — a
    /// session added and closed inside a gap, or a project the client dropped on a
    /// re-snapshot. Trapping on those would turn an ordinary reconnect into a crash on the
    /// device furthest from a debugger.
    public mutating func apply(_ event: FleetEvent) {
        switch event {
        case .projectAdded(let project, let at):
            guard !projects.contains(where: { $0.id == project.id }) else { return }
            projects.insert(project, at: min(max(at, 0), projects.count))

        case .projectRemoved(let id):
            projects.removeAll { $0.id == id }

        case .projectCollapsed(let id, let isCollapsed):
            guard let p = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[p].isCollapsed = isCollapsed

        case .projectsReordered(let order):
            projects = Self.reorder(projects, by: order)

        case .sessionAdded(let session, let project, let at):
            guard let p = projects.firstIndex(where: { $0.id == project }) else { return }
            guard !projects[p].sessions.contains(where: { $0.id == session.id }) else { return }
            projects[p].sessions.insert(session, at: min(max(at, 0), projects[p].sessions.count))

        case .sessionRemoved(let id):
            for p in projects.indices { projects[p].sessions.removeAll { $0.id == id } }

        case .sessionMoved(let id, let project, let at):
            guard
                let destination = projects.firstIndex(where: { $0.id == project }),
                let found = locate(id)
            else { return }
            let session = projects[found.project].sessions.remove(at: found.session)
            let clamped = min(max(at, 0), projects[destination].sessions.count)
            projects[destination].sessions.insert(session, at: clamped)

        case .sessionsReordered(let project, let order):
            guard let p = projects.firstIndex(where: { $0.id == project }) else { return }
            projects[p].sessions = Self.reorder(projects[p].sessions, by: order)

        case .renamed(let id, let title, _):
            mutate(id) { $0.title = title }

        case .activityChanged(let id, let activity, let waitingFor, let subagentCount):
            mutate(id) {
                $0.activity = activity
                $0.waitingFor = waitingFor
                $0.subagentCount = subagentCount
            }

        case .unreadChanged(let id, let isUnread):
            mutate(id) { $0.isUnread = isUnread }
        }
    }

    public func applying(_ events: [FleetEvent]) -> FleetSnapshot {
        var copy = self
        for event in events { copy.apply(event) }
        return copy
    }

    private func locate(_ id: UUID) -> (project: Int, session: Int)? {
        for p in projects.indices {
            if let s = projects[p].sessions.firstIndex(where: { $0.id == id }) {
                return (p, s)
            }
        }
        return nil
    }

    private mutating func mutate(_ id: UUID, _ body: (inout WireSession) -> Void) {
        guard let at = locate(id) else { return }
        body(&projects[at.project].sessions[at.session])
    }

    /// Reorder by the given ids, keeping anything the order does not mention **in place at
    /// the end**. An order naming rows the client never received is the normal case across a
    /// resume gap; dropping the unmentioned rows would delete sessions nobody asked to close.
    private static func reorder<T: Identifiable>(_ items: [T], by order: [T.ID]) -> [T] {
        var remaining = items
        var result: [T] = []
        for id in order {
            guard let at = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: at))
        }
        return result + remaining
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/FleetEvent.swift Sources/FleetKit/SnapshotApplication.swift \
        Tests/FlightDeckTests/FleetEventApplicationTests.swift
git commit -m "feat: describe fleet changes as intents a client can fold into a snapshot"
```

---

### Task 4: The replay fold

A phone off the network for an hour must not be handed four thousand status flaps when it comes back. Folding is what makes a long gap **resumable at all** rather than forcing a re-snapshot, which is why it belongs on the resume path and not in a later optimisation pass.

The fold's contract is exactly one property, and the tests are written to state it: **for any event sequence, applying the fold produces the same snapshot as applying the raw sequence.** Everything else is a means to that end.

**Files:**
- Create: `Sources/FleetKit/FleetReplay.swift`
- Test: `Tests/FlightDeckTests/FleetReplayFoldTests.swift`

**Interfaces:**
- Consumes: `FleetEvent`, `FleetSnapshot.applying(_:)` (Task 3).
- Produces: `public enum FleetReplay { public static func fold(_ events: [FleetEvent]) -> [FleetEvent] }`. Task 10 calls it on the resume path.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetReplayFoldTests.swift`:

```swift
import XCTest
import FleetKit

final class FleetReplayFoldTests: XCTestCase {
    private let projectID = UUID()
    private let a = UUID()
    private let b = UUID()

    private func session(_ id: UUID, _ title: String) -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func base() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd",
                        sessions: [session(a, "a"), session(b, "b")])
        ])
    }

    /// The whole contract. Every other test in this file explains *how* the fold gets here;
    /// this one is what it is for.
    private func assertFoldPreservesOutcome(
        _ events: [FleetEvent], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            base().applying(FleetReplay.fold(events)),
            base().applying(events),
            "the fold changed the resulting fleet",
            file: file, line: line
        )
    }

    func testRepeatedActivityCollapsesToTheLast() {
        let flaps: [FleetEvent] = (0..<50).map { i in
            .activityChanged(id: a, activity: i.isMultiple(of: 2) ? "busy" : "idle",
                             waitingFor: nil, subagentCount: 0)
        }
        XCTAssertEqual(FleetReplay.fold(flaps).count, 1)
        assertFoldPreservesOutcome(flaps)
    }

    func testRepeatedRenamesCollapseToTheLast() {
        let renames: [FleetEvent] = ["x", "y", "z"].map {
            .renamed(id: a, title: $0, origin: .agent)
        }
        XCTAssertEqual(FleetReplay.fold(renames), [.renamed(id: a, title: "z", origin: .agent)])
    }

    /// Per-session, not global: two sessions flapping must both survive, or the fold
    /// silently loses one of them.
    func testCollapsingIsPerSession() {
        let events: [FleetEvent] = [
            .activityChanged(id: a, activity: "busy", waitingFor: nil, subagentCount: 0),
            .activityChanged(id: b, activity: "busy", waitingFor: nil, subagentCount: 0),
            .activityChanged(id: a, activity: "idle", waitingFor: nil, subagentCount: 0)
        ]
        XCTAssertEqual(FleetReplay.fold(events).count, 2)
        assertFoldPreservesOutcome(events)
    }

    func testASessionRemovedInTheGapKeepsOnlyItsRemoval() {
        let events: [FleetEvent] = [
            .renamed(id: a, title: "x", origin: .user),
            .activityChanged(id: a, activity: "busy", waitingFor: nil, subagentCount: 4),
            .unreadChanged(id: a, isUnread: true),
            .sessionRemoved(id: a)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.sessionRemoved(id: a)])
        assertFoldPreservesOutcome(events)
    }

    /// A session that appeared and vanished inside the gap collapses to its removal alone.
    /// The removal survives rather than the pair vanishing: the fold cannot know whether the
    /// client already held this id, and a removal it did not need is inert, while a removal
    /// it did need and never got is a phantom session.
    func testASessionAddedAndRemovedInTheGapCollapsesToItsRemoval() {
        let ghost = UUID()
        let events: [FleetEvent] = [
            .sessionAdded(session(ghost, "ghost"), project: projectID, at: 0),
            .activityChanged(id: ghost, activity: "busy", waitingFor: nil, subagentCount: 0),
            .sessionRemoved(id: ghost)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.sessionRemoved(id: ghost)])
        assertFoldPreservesOutcome(events)
    }

    func testAProjectRemovedInTheGapTakesItsOwnEventsWithIt() {
        let events: [FleetEvent] = [
            .projectCollapsed(id: projectID, isCollapsed: true),
            .sessionsReordered(project: projectID, order: [b, a]),
            .projectRemoved(id: projectID)
        ]
        XCTAssertEqual(FleetReplay.fold(events), [.projectRemoved(id: projectID)])
        assertFoldPreservesOutcome(events)
    }

    /// Order between *different* subjects is load-bearing: a session added to a project must
    /// not be folded ahead of the project's own arrival.
    func testRelativeOrderOfSurvivingEventsIsPreserved() {
        let newProject = UUID()
        let newSession = UUID()
        let events: [FleetEvent] = [
            .projectAdded(WireProject(id: newProject, name: "n", path: "/w/n"), at: 1),
            .sessionAdded(session(newSession, "n1"), project: newProject, at: 0),
            .renamed(id: newSession, title: "n2", origin: .user)
        ]
        XCTAssertEqual(FleetReplay.fold(events), events)
        assertFoldPreservesOutcome(events)
    }

    func testAnEmptyGapFoldsToNothing() {
        XCTAssertTrue(FleetReplay.fold([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetReplay' in scope`.

- [ ] **Step 3: Implement the fold**

Create `Sources/FleetKit/FleetReplay.swift`:

```swift
import Foundation

/// Collapses a replay window to the shortest sequence with the same outcome.
///
/// Why this is on the resume path rather than an optimisation: without it, a phone that was
/// away for an hour is handed every status flap the fleet produced, which is thousands of
/// frames for a fleet that is doing its job. That is not slow-but-correct — it is the
/// difference between a gap being resumable and the server having to force a re-snapshot,
/// which is the expensive path this exists to avoid.
public enum FleetReplay {
    public static func fold(_ events: [FleetEvent]) -> [FleetEvent] {
        keptIndices(events).map { events[$0] }
    }

    /// The indices `fold` keeps, in order.
    ///
    /// Exposed as the primitive because the resume path folds events that carry sequence
    /// numbers and must not lose them (`FleetReplicator.resume(from:)`). Returning positions
    /// rather than values is what lets that caller reuse this policy instead of
    /// reimplementing it against a second type — and two copies of a fold that must agree
    /// exactly is the bug this avoids.
    public static func keptIndices(_ events: [FleetEvent]) -> [Int] {
        let doomed = subjectsRemovedInWindow(events)
        let survivors = events.indices.filter { survives(events[$0], doomed) }
        return collapseLastWriteWins(survivors, in: events)
    }

    /// A removal is the only event about a doomed subject that still matters. Everything
    /// earlier is superseded by it, and everything later cannot exist.
    ///
    /// The removal is kept unconditionally, even when this window also contains the subject's
    /// creation. An earlier draft dropped it in that case, reasoning that a client which never
    /// saw the subject need not hear it left — but the fold sees only events, never the
    /// snapshot, so it cannot distinguish a genesis add from a redundant add on something the
    /// client already holds, and guessing wrong left the client holding a deleted session.
    /// Applying a removal for an unknown id is a silent no-op by contract, so keeping it costs
    /// one inert frame and makes the property hold unconditionally.
    private static func survives(_ event: FleetEvent, _ doomed: Doomed) -> Bool {
        if let id = event.sessionID, doomed.sessions.contains(id) {
            guard case .sessionRemoved = event else { return false }
            return true
        }
        if let id = event.projectID, doomed.projects.contains(id) {
            guard case .projectRemoved = event else { return false }
            return true
        }
        return true
    }

    // MARK: Removals

    /// Subjects that are gone by the end of the window. There is deliberately no
    /// "born in this window" companion — see `survives(_:_:)`.
    private struct Doomed {
        var sessions: Set<UUID> = []
        var projects: Set<UUID> = []
    }

    /// One forward pass recording, per subject, where it was last added and last removed.
    ///
    /// A subject is doomed only when its last removal comes *after* its last addition. That
    /// ordering test is what lets a remove-then-re-add under the same id survive intact:
    /// dropping both events would leave the client holding the subject's pre-window contents,
    /// which is stale data rather than a missing frame — the worse of the two failures.
    ///
    /// The symmetry between sessions and projects is load-bearing. An earlier draft of this
    /// plan defended sessions only, and a project removed and re-added inside one window
    /// resurrected every session it used to hold.
    private static func subjectsRemovedInWindow(_ events: [FleetEvent]) -> Doomed {
        var lastSessionAdd: [UUID: Int] = [:], lastSessionRemove: [UUID: Int] = [:]
        var lastProjectAdd: [UUID: Int] = [:], lastProjectRemove: [UUID: Int] = [:]
        for (index, event) in events.enumerated() {
            switch event {
            case .sessionAdded(let session, _, _): lastSessionAdd[session.id] = index
            case .sessionRemoved(let id): lastSessionRemove[id] = index
            case .projectAdded(let project, _): lastProjectAdd[project.id] = index
            case .projectRemoved(let id): lastProjectRemove[id] = index
            default: continue
            }
        }

        var doomed = Doomed()
        for (id, removedAt) in lastSessionRemove where (lastSessionAdd[id] ?? -1) < removedAt {
            doomed.sessions.insert(id)
        }
        for (id, removedAt) in lastProjectRemove where (lastProjectAdd[id] ?? -1) < removedAt {
            doomed.projects.insert(id)
        }
        return doomed
    }

    // MARK: Last-write-wins collapsing

    /// The kinds where only the final value can matter, keyed by what they are final *for*.
    /// Anything not listed here is positional and is left exactly where it is.
    ///
    /// Reorders and moves are deliberately absent, and that is a correctness requirement
    /// rather than caution. `reorder` leaves any id its order does not mention "in place", so
    /// a reorder's result depends on the list it runs against — it is a state-dependent
    /// transform, not a field. Collapsing two reorders that straddle an insertion silently
    /// changes the surviving order: with [A,B], `reorder→[B,A]`, `add C at 1`, `reorder
    /// pinning only A` yields [A,B,C] raw and [A,C,B] folded. There is nothing to gain by
    /// collapsing them either — reorders are human drag gestures, while the volume this fold
    /// exists to absorb is machine-generated status flaps.
    private enum FoldKey: Hashable {
        case activity(UUID), rename(UUID), unread(UUID), collapsed(UUID)
    }

    private static func key(_ event: FleetEvent) -> FoldKey? {
        switch event {
        case .activityChanged(let id, _, _, _): return .activity(id)
        case .renamed(let id, _, _): return .rename(id)
        case .unreadChanged(let id, _): return .unread(id)
        case .projectCollapsed(let id, _): return .collapsed(id)
        default: return nil
        }
    }

    /// Walks backwards keeping the first sighting of each key — i.e. the *last* occurrence
    /// in the original order — then restores the order. Keeping the last rather than
    /// rewriting the first in place is what preserves ordering against neighbouring events:
    /// a rename that happened after a move must still be applied after it.
    private static func collapseLastWriteWins(_ indices: [Int], in events: [FleetEvent]) -> [Int] {
        var seen: Set<FoldKey> = []
        var reversed: [Int] = []
        for i in indices.reversed() {
            if let key = key(events[i]) {
                guard seen.insert(key).inserted else { continue }
            }
            reversed.append(i)
        }
        return reversed.reversed()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/FleetReplay.swift Tests/FlightDeckTests/FleetReplayFoldTests.swift
git commit -m "feat: fold a replay window so an hour offline is resumable"
```

---

### Task 5: The frame codec

The spec documents a wire shape with a `"t"` discriminator and flat fields (§4). Swift's synthesized `Codable` for an enum with associated values produces `{"sessionRemoved":{"id":"…"}}` instead — so accepting the synthesis would make the spec a lie about the bytes on the wire. This task writes the codec by hand so the documented shape *is* the shipped shape, and pins it with tests that assert the literal keys.

That is not ceremony. `CodexSchemaConformanceTests` exists in this repo for the same reason: a wire format nobody can read from a packet dump is a wire format nobody can debug.

**Files:**
- Create: `Sources/FleetKit/WireCoding.swift`
- Create: `Sources/FleetKit/Frames.swift`
- Test: `Tests/FlightDeckTests/FleetFrameCodingTests.swift`

**Interfaces:**
- Consumes: `FleetEvent`, `FleetSnapshot` (Tasks 2–3).
- Produces: `FleetEvent: Codable`; `public enum FleetCommand: Codable, Equatable, Sendable { case markRead(id: UUID), markUnread(id: UUID) }`; `public enum SnapshotReason: String, Codable, Sendable { case initial, seqTooOld }`; `public enum ClientFrame: Codable, Equatable, Sendable { case hello(lastSeq: Int), cmd(cid: Int, FleetCommand) }`; `public enum ServerFrame: Codable, Equatable, Sendable { case snapshot(seq: Int, fleet: FleetSnapshot, reason: SnapshotReason), case event(seq: Int, FleetEvent), case ack(cid: Int), case err(cid: Int, code: String) }`. Tasks 11 and 12 send and receive exactly these.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetFrameCodingTests.swift`:

```swift
import XCTest
import FleetKit

/// These tests assert the *bytes*, not just round-tripping. Round-tripping alone would pass
/// happily against Swift's synthesized nesting, which is exactly the shape the spec does not
/// describe — and the first time anyone reads a packet dump is the first time they would
/// find out.
final class FleetFrameCodingTests: XCTestCase {
    private func fields<T: Encodable>(of value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Events carry a flat discriminator

    func testARenameEncodesFlatWithItsTypeTag() throws {
        let id = UUID()
        let encoded = try fields(of: FleetEvent.renamed(id: id, title: "two", origin: .agent))
        XCTAssertEqual(encoded["t"] as? String, "session.renamed")
        XCTAssertEqual(encoded["id"] as? String, id.uuidString)
        XCTAssertEqual(encoded["title"] as? String, "two")
        XCTAssertEqual(encoded["origin"] as? String, "agent")
    }

    func testAnActivityChangeEncodesItsWholeTriple() throws {
        let encoded = try fields(of: FleetEvent.activityChanged(
            id: UUID(), activity: "waiting", waitingFor: "permission prompt", subagentCount: 3
        ))
        XCTAssertEqual(encoded["t"] as? String, "session.activity")
        XCTAssertEqual(encoded["activity"] as? String, "waiting")
        XCTAssertEqual(encoded["waitingFor"] as? String, "permission prompt")
        XCTAssertEqual(encoded["subagentCount"] as? Int, 3)
    }

    func testEveryEventCaseRoundTrips() throws {
        let project = WireProject(id: UUID(), name: "n", path: "/w/n")
        let session = WireSession(id: UUID(), title: "s", agent: "codex")
        let cases: [FleetEvent] = [
            .projectAdded(project, at: 1),
            .projectRemoved(id: UUID()),
            .projectCollapsed(id: UUID(), isCollapsed: true),
            .projectsReordered(order: [UUID(), UUID()]),
            .sessionAdded(session, project: project.id, at: 0),
            .sessionRemoved(id: UUID()),
            .sessionMoved(id: UUID(), project: project.id, at: 2),
            .sessionsReordered(project: project.id, order: [UUID()]),
            .renamed(id: UUID(), title: "t", origin: .user),
            .activityChanged(id: UUID(), activity: nil, waitingFor: nil, subagentCount: 0),
            .unreadChanged(id: UUID(), isUnread: true)
        ]
        for event in cases {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event,
                           "\(event) did not survive a round trip")
        }
    }

    /// An unrecognised `t` must throw rather than decode to some default. A frame the client
    /// silently misreads is worse than one it refuses: the first leaves a wrong fleet on
    /// screen, the second is a log line.
    func testAnUnknownEventTypeThrows() {
        let json = Data(#"{"t":"session.teleported","id":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FleetEvent.self, from: json))
    }

    // MARK: Frames

    func testAnEventFrameCarriesItsSequenceBesideTheEventsOwnFields() throws {
        let id = UUID()
        let encoded = try fields(of: ServerFrame.event(
            seq: 813, .renamed(id: id, title: "x", origin: .user)
        ))
        XCTAssertEqual(encoded["seq"] as? Int, 813)
        XCTAssertEqual(encoded["t"] as? String, "session.renamed")
        XCTAssertEqual(encoded["title"] as? String, "x")
        XCTAssertNil(encoded["event"], "the event must be flat in the frame, not nested")
    }

    func testASnapshotFrameNamesWhyItWasSent() throws {
        let encoded = try fields(of: ServerFrame.snapshot(
            seq: 9, fleet: .empty, reason: .seqTooOld
        ))
        XCTAssertEqual(encoded["t"] as? String, "snapshot")
        XCTAssertEqual(encoded["reason"] as? String, "seqTooOld")
        XCTAssertNotNil(encoded["fleet"])
    }

    func testCommandFramesCarryTheirCorrelationIDAndOperation() throws {
        let id = UUID()
        let encoded = try fields(of: ClientFrame.cmd(cid: 41, .markRead(id: id)))
        XCTAssertEqual(encoded["t"] as? String, "cmd")
        XCTAssertEqual(encoded["cid"] as? Int, 41)
        XCTAssertEqual(encoded["op"] as? String, "session.markRead")
        XCTAssertEqual(encoded["id"] as? String, id.uuidString)
    }

    func testEveryFrameRoundTrips() throws {
        let server: [ServerFrame] = [
            .snapshot(seq: 1, fleet: .empty, reason: .initial),
            .event(seq: 2, .sessionRemoved(id: UUID())),
            .ack(cid: 7),
            .err(cid: 8, code: "unknown_session")
        ]
        for frame in server {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
        }
        let client: [ClientFrame] = [
            .hello(lastSeq: 0), .hello(lastSeq: 812),
            .cmd(cid: 1, .markRead(id: UUID())), .cmd(cid: 2, .markUnread(id: UUID()))
        ]
        for frame in client {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: data), frame)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'ServerFrame' in scope`, and `FleetEvent` does not conform to `Encodable`.

- [ ] **Step 3: Hand-write `FleetEvent`'s coding**

Create `Sources/FleetKit/WireCoding.swift`:

```swift
import Foundation

/// The type tags that appear as `"t"` on the wire. Spelled out as a table rather than
/// derived from the case names, because a case rename must not silently become a protocol
/// break — changing a wire tag has to be a deliberate edit to this file.
enum FleetEventTag: String, Codable {
    case projectAdded = "project.added"
    case projectRemoved = "project.removed"
    case projectCollapsed = "project.collapsed"
    case projectsReordered = "projects.reordered"
    case sessionAdded = "session.added"
    case sessionRemoved = "session.removed"
    case sessionMoved = "session.moved"
    case sessionsReordered = "sessions.reordered"
    case renamed = "session.renamed"
    case activityChanged = "session.activity"
    case unreadChanged = "session.unread"
}

extension FleetEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case t, id, at, order, title, origin
        case project, session, projectId
        case activity, waitingFor, subagentCount, isUnread, isCollapsed
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectAdded(let project, let at):
            try c.encode(FleetEventTag.projectAdded, forKey: .t)
            try c.encode(project, forKey: .project)
            try c.encode(at, forKey: .at)
        case .projectRemoved(let id):
            try c.encode(FleetEventTag.projectRemoved, forKey: .t)
            try c.encode(id, forKey: .id)
        case .projectCollapsed(let id, let isCollapsed):
            try c.encode(FleetEventTag.projectCollapsed, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(isCollapsed, forKey: .isCollapsed)
        case .projectsReordered(let order):
            try c.encode(FleetEventTag.projectsReordered, forKey: .t)
            try c.encode(order, forKey: .order)
        case .sessionAdded(let session, let project, let at):
            try c.encode(FleetEventTag.sessionAdded, forKey: .t)
            try c.encode(session, forKey: .session)
            try c.encode(project, forKey: .projectId)
            try c.encode(at, forKey: .at)
        case .sessionRemoved(let id):
            try c.encode(FleetEventTag.sessionRemoved, forKey: .t)
            try c.encode(id, forKey: .id)
        case .sessionMoved(let id, let project, let at):
            try c.encode(FleetEventTag.sessionMoved, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(project, forKey: .projectId)
            try c.encode(at, forKey: .at)
        case .sessionsReordered(let project, let order):
            try c.encode(FleetEventTag.sessionsReordered, forKey: .t)
            try c.encode(project, forKey: .projectId)
            try c.encode(order, forKey: .order)
        case .renamed(let id, let title, let origin):
            try c.encode(FleetEventTag.renamed, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(origin, forKey: .origin)
        case .activityChanged(let id, let activity, let waitingFor, let subagentCount):
            try c.encode(FleetEventTag.activityChanged, forKey: .t)
            try c.encode(id, forKey: .id)
            // `encode` not `encodeIfPresent`: an absent key and an explicit null are the
            // same to a decoder here, but a packet dump that shows `"activity": null` says
            // "no agent process" out loud, and this is the field most likely to be
            // misread as "idle".
            try c.encode(activity, forKey: .activity)
            try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
            try c.encode(subagentCount, forKey: .subagentCount)
        case .unreadChanged(let id, let isUnread):
            try c.encode(FleetEventTag.unreadChanged, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(isUnread, forKey: .isUnread)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(FleetEventTag.self, forKey: .t) {
        case .projectAdded:
            self = .projectAdded(try c.decode(WireProject.self, forKey: .project),
                                 at: try c.decode(Int.self, forKey: .at))
        case .projectRemoved:
            self = .projectRemoved(id: try c.decode(UUID.self, forKey: .id))
        case .projectCollapsed:
            self = .projectCollapsed(id: try c.decode(UUID.self, forKey: .id),
                                     isCollapsed: try c.decode(Bool.self, forKey: .isCollapsed))
        case .projectsReordered:
            self = .projectsReordered(order: try c.decode([UUID].self, forKey: .order))
        case .sessionAdded:
            self = .sessionAdded(try c.decode(WireSession.self, forKey: .session),
                                 project: try c.decode(UUID.self, forKey: .projectId),
                                 at: try c.decode(Int.self, forKey: .at))
        case .sessionRemoved:
            self = .sessionRemoved(id: try c.decode(UUID.self, forKey: .id))
        case .sessionMoved:
            self = .sessionMoved(id: try c.decode(UUID.self, forKey: .id),
                                 project: try c.decode(UUID.self, forKey: .projectId),
                                 at: try c.decode(Int.self, forKey: .at))
        case .sessionsReordered:
            self = .sessionsReordered(project: try c.decode(UUID.self, forKey: .projectId),
                                      order: try c.decode([UUID].self, forKey: .order))
        case .renamed:
            self = .renamed(id: try c.decode(UUID.self, forKey: .id),
                            title: try c.decode(String.self, forKey: .title),
                            origin: try c.decode(RenameOrigin.self, forKey: .origin))
        case .activityChanged:
            self = .activityChanged(
                id: try c.decode(UUID.self, forKey: .id),
                activity: try c.decodeIfPresent(String.self, forKey: .activity),
                waitingFor: try c.decodeIfPresent(String.self, forKey: .waitingFor),
                subagentCount: try c.decode(Int.self, forKey: .subagentCount)
            )
        case .unreadChanged:
            self = .unreadChanged(id: try c.decode(UUID.self, forKey: .id),
                                  isUnread: try c.decode(Bool.self, forKey: .isUnread))
        }
    }
}

extension RenameOrigin: Codable {}
```

- [ ] **Step 4: Write the frames**

Create `Sources/FleetKit/Frames.swift`:

```swift
import Foundation

/// Why a snapshot arrived. A client that asked to resume and got a snapshot instead needs
/// to know it lost history, because that is the moment any local "since you were away"
/// affordance becomes a lie.
public enum SnapshotReason: String, Codable, Equatable, Sendable {
    /// The client asked for everything (`lastSeq == 0`).
    case initial
    /// The client asked to resume from before the ring's floor.
    case seqTooOld
}

/// Something the client asks the Mac to do.
///
/// `ack` means *dispatched*, not done — see §4. Typing into a pty has no delivery
/// confirmation, so the observable effect always arrives separately as a northbound event.
/// One rule for both agents beats commands whose meaning depends on which agent is behind
/// them.
public enum FleetCommand: Codable, Equatable, Sendable {
    case markRead(id: UUID)
    case markUnread(id: UUID)

    enum CodingKeys: String, CodingKey { case op, id }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
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
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        switch try c.decode(Op.self, forKey: .op) {
        case .markRead: self = .markRead(id: id)
        case .markUnread: self = .markUnread(id: id)
        }
    }
}

/// Client → Mac.
public enum ClientFrame: Codable, Equatable, Sendable {
    /// The first frame on every socket. TLS-PSK has already established *who* this is, so
    /// this is a resume point rather than a credential. `0` means "I have nothing".
    case hello(lastSeq: Int)
    case cmd(cid: Int, FleetCommand)

    enum CodingKeys: String, CodingKey { case t, lastSeq, cid }

    private enum Tag: String, Codable { case hello, cmd }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let lastSeq):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(lastSeq, forKey: .lastSeq)
        case .cmd(let cid, let command):
            try c.encode(Tag.cmd, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object rather than nested under an "op" key, so a
            // command reads as one line in a dump. Two keyed containers over one encoder
            // merge into a single JSON object.
            try command.encode(to: encoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            self = .hello(lastSeq: try c.decode(Int.self, forKey: .lastSeq))
        case .cmd:
            self = .cmd(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetCommand(from: decoder))
        }
    }
}

/// Mac → client. Northbound frames are sequenced; replies to commands are correlated.
public enum ServerFrame: Codable, Equatable, Sendable {
    case snapshot(seq: Int, fleet: FleetSnapshot, reason: SnapshotReason)
    case event(seq: Int, FleetEvent)
    case ack(cid: Int)
    case err(cid: Int, code: String)

    enum CodingKeys: String, CodingKey { case t, seq, fleet, reason, cid, code }

    private enum Tag: String, Codable { case snapshot, ack, err }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let seq, let fleet, let reason):
            try c.encode(Tag.snapshot, forKey: .t)
            try c.encode(seq, forKey: .seq)
            try c.encode(fleet, forKey: .fleet)
            try c.encode(reason, forKey: .reason)
        case .event(let seq, let event):
            try c.encode(seq, forKey: .seq)
            // The event supplies its own `t`; the frame adds only the sequence. One flat
            // object per change is what makes a dump readable.
            try event.encode(to: encoder)
        case .ack(let cid):
            try c.encode(Tag.ack, forKey: .t)
            try c.encode(cid, forKey: .cid)
        case .err(let cid, let code):
            try c.encode(Tag.err, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(code, forKey: .code)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try the frame's own tags first; anything else is an event's tag, which is why
        // the two namespaces must never collide. `FleetEventTag`'s values are all dotted
        // and these three are not, which keeps that a property rather than a promise.
        if let tag = try? c.decode(Tag.self, forKey: .t) {
            switch tag {
            case .snapshot:
                self = .snapshot(seq: try c.decode(Int.self, forKey: .seq),
                                 fleet: try c.decode(FleetSnapshot.self, forKey: .fleet),
                                 reason: try c.decode(SnapshotReason.self, forKey: .reason))
            case .ack:
                self = .ack(cid: try c.decode(Int.self, forKey: .cid))
            case .err:
                self = .err(cid: try c.decode(Int.self, forKey: .cid),
                            code: try c.decode(String.self, forKey: .code))
            }
            return
        }
        self = .event(seq: try c.decode(Int.self, forKey: .seq),
                      try FleetEvent(from: decoder))
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Verify the iOS slice still compiles**

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/WireCoding.swift Sources/FleetKit/Frames.swift \
        Tests/FlightDeckTests/FleetFrameCodingTests.swift
git commit -m "feat: put the documented frame shape on the wire, not Swift's synthesized nesting"
```

---

### Task 6: TLS pre-shared keys, proven by loopback before anything is built on them

This is the plan's one genuinely uncertain API, and it is deliberately Task 6 rather than Task 12: the whole trust boundary (§3) rests on "a device slot the Mac has no secret for cannot complete a handshake, so an unpaired peer never reaches application code". If that is not true as written, the design changes, and it must change now rather than after a listener, a replicator and a phone have been built on it.

Three things are **verified** from the macOS 26.5 SDK headers and are not in question:

- `sec_protocol_options_add_pre_shared_key(options, psk, psk_identity)` — `Security/SecProtocolOptions.h:373`, macOS 10.14+.
- `sec_protocol_options_append_tls_ciphersuite(options, ciphersuite)` — same header, line 118.
- `TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8` — `Security/CipherSuite.h:197`.

The **unverified** part, which the test in this task exists to settle, is whether a listener that registers *several* PSKs selects the right one for whichever identity a client offers. Nothing in the headers says it does not; nothing says it does.

> **If multi-key selection does not work**, do not improvise. Stop, and take the documented fallback: register one fleet-wide PSK at the TLS layer and move per-device identity into the `hello` frame as an HMAC challenge over a server-supplied nonce. That is weaker — an unpaired peer reaches application code before being rejected — so it must be recorded in `docs/FOLLOWUPS.md` and in the spec's §11 rather than absorbed silently.

**Files:**
- Create: `Sources/FleetKit/FleetTLS.swift`
- Test: `Tests/FlightDeckTests/FleetTLSHandshakeTests.swift`

**Interfaces:**
- Produces: `public struct FleetDeviceKey: Equatable, Sendable { public let slot: UUID; public let secret: Data; public init(slot:secret:); public static func mint() -> FleetDeviceKey }` and `public enum FleetTLS { public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters; public static func clientParameters(key: FleetDeviceKey) -> NWParameters }`. Task 11 builds its listener and connection from exactly these.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetTLSHandshakeTests.swift`:

```swift
import Network
import XCTest
import FleetKit

/// The trust boundary, tested as a boundary. Everything else in this feature assumes an
/// unpaired peer cannot reach application code; these four tests are the only evidence for
/// that claim, so they exercise a real listener and a real connection over loopback rather
/// than asserting anything about the parameter objects.
final class FleetTLSHandshakeTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    /// Starts a listener that accepts any of `keys` and echoes the first message it receives.
    private func startEchoListener(keys: [FleetDeviceKey]) throws -> NWEndpoint.Port {
        let listener = try NWListener(using: FleetTLS.listenerParameters(keys: keys))
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, _ in
                guard let data else { return }
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    /// Returns the connection's terminal state: `.ready` on a successful handshake, or
    /// `.failed`/`.cancelled` when the peer refused us.
    private func attempt(
        key: FleetDeviceKey, port: NWEndpoint.Port, timeout: TimeInterval = 8
    ) -> NWConnection.State {
        let connection = NWConnection(
            host: "127.0.0.1", port: port, using: FleetTLS.clientParameters(key: key)
        )
        let settled = expectation(description: "connection settled")
        var terminal: NWConnection.State = .setup
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                terminal = state
                settled.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .main)
        let outcome = XCTWaiter().wait(for: [settled], timeout: timeout)
        connection.cancel()
        // A handshake the peer refuses can also manifest as silence rather than a failure
        // state, so a timeout counts as "did not connect" — never as a pass.
        return outcome == .completed ? terminal : .cancelled
    }

    private func isReady(_ state: NWConnection.State) -> Bool {
        if case .ready = state { return true }
        return false
    }

    func testAPairedKeyCompletesTheHandshake() throws {
        let key = FleetDeviceKey.mint()
        let port = try startEchoListener(keys: [key])
        XCTAssertTrue(isReady(attempt(key: key, port: port)))
    }

    /// The real question this task exists to answer: can one listener hold several paired
    /// devices' keys at once? Everything about revocation-per-slot depends on it.
    func testEveryRegisteredSlotCanConnectToOneListener() throws {
        let first = FleetDeviceKey.mint()
        let second = FleetDeviceKey.mint()
        let port = try startEchoListener(keys: [first, second])
        XCTAssertTrue(isReady(attempt(key: first, port: port)), "first slot was refused")
        XCTAssertTrue(isReady(attempt(key: second, port: port)), "second slot was refused")
    }

    /// Revocation is deleting a slot's secret, so this is the test that says revocation
    /// works: the same slot id with a different secret must not get in.
    func testTheRightSlotWithTheWrongSecretIsRefused() throws {
        let paired = FleetDeviceKey.mint()
        let impostor = FleetDeviceKey(slot: paired.slot, secret: FleetDeviceKey.mint().secret)
        let port = try startEchoListener(keys: [paired])
        XCTAssertFalse(isReady(attempt(key: impostor, port: port)))
    }

    func testASlotTheMacHasNeverSeenIsRefused() throws {
        let port = try startEchoListener(keys: [.mint()])
        XCTAssertFalse(isReady(attempt(key: .mint(), port: port)))
    }

    func testAMintedKeyIsThirtyTwoBytesAndNotReused() {
        let a = FleetDeviceKey.mint()
        let b = FleetDeviceKey.mint()
        XCTAssertEqual(a.secret.count, 32)
        XCTAssertNotEqual(a.secret, b.secret)
        XCTAssertNotEqual(a.slot, b.slot)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetTLS' in scope`.

- [ ] **Step 3: Implement the parameter factory**

Create `Sources/FleetKit/FleetTLS.swift`:

```swift
import Foundation
import Network
import Security

/// One paired device: the slot the Mac filed it under, and the secret they share.
///
/// The slot id doubles as the TLS PSK *identity*, which is what lets one listener hold
/// several devices' keys and still know which one connected — and what makes revoking a
/// device exactly "delete this slot's secret" with no other bookkeeping.
public struct FleetDeviceKey: Equatable, Sendable {
    public let slot: UUID
    /// 32 bytes from the system CSPRNG. Never derived from anything the user types: this is
    /// displayed once, in a QR, on a screen the user is looking at (§3), so there is no
    /// password to stretch and nothing to be memorable.
    public let secret: Data

    public init(slot: UUID, secret: Data) {
        self.slot = slot
        self.secret = secret
    }

    public static func mint() -> FleetDeviceKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here means the system CSPRNG is unavailable, which is not a condition
        // to paper over with a weaker key — there is no safe fallback, so trap.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return FleetDeviceKey(slot: UUID(), secret: Data(bytes))
    }

    /// The PSK identity blob. The slot's UUID string rather than its raw bytes, so a packet
    /// capture and the paired-devices list in Preferences name the same thing.
    var identity: Data { Data(slot.uuidString.utf8) }
}

/// Builds the `NWParameters` both halves of the fleet socket use.
public enum FleetTLS {
    /// Server side: every currently-paired slot, registered up front.
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        parameters(keys: keys)
    }

    /// Client side: this device's one key.
    public static func clientParameters(key: FleetDeviceKey) -> NWParameters {
        parameters(keys: [key])
    }

    private static func parameters(keys: [FleetDeviceKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        for key in keys {
            sec_protocol_options_add_pre_shared_key(
                sec, key.secret.dispatch, key.identity.dispatch
            )
        }

        // Required, and the reason is a trap worth naming: Network.framework's PSK support
        // is the **TLS 1.2** PSK ciphersuite family (`TLS_PSK_WITH_AES_128_GCM_SHA256`,
        // 0x00A8 — Security/CipherSuite.h:197), not TLS 1.3 external PSK. Without this
        // append the handshake offers no suite the peer can agree to and simply hangs; and
        // pinning `sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)` — which
        // looks like obvious hardening — breaks it for the same reason. Do not add that pin.
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: numericCast(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let parameters = NWParameters(tls: tls)
        // The phone roams between networks and the Mac's address changes under it; letting
        // an established connection survive a path change is most of what makes roaming
        // (§3) feel like nothing happened.
        parameters.multipathServiceType = .handover
        return parameters
    }
}

extension Data {
    /// Bridge to the `dispatch_data_t` the `sec_protocol_*` C API takes. `__DispatchData` is
    /// the imported C type; `DispatchData` is Swift's overlay value type, and the cast
    /// between them is the documented way across.
    var dispatch: __DispatchData {
        withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, all five cases.

**If `testEveryRegisteredSlotCanConnectToOneListener` is the only failure**, multi-key selection is not supported. Stop and take the fallback documented at the top of this task; do not weaken the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/FleetTLS.swift Tests/FlightDeckTests/FleetTLSHandshakeTests.swift
git commit -m "feat: authenticate a paired device with a TLS pre-shared key, per slot"
```

---

### Task 7: Projecting a live `SessionStore` into a snapshot

The connect-time snapshot, and — more importantly — the **oracle** the drift assertion of Task 8 compares against. It is a pure read: no mutation, no side effect, no `@Published` write, so it can be called as often as an assertion wants.

This is the first file in the *app* module rather than in FleetKit, because it is the only place that may know both `Repo`/`Session`/`SessionStatus` and the wire types.

**Files:**
- Create: `Sources/FlightDeck/Fleet/FleetProjection.swift`
- Test: `Tests/FlightDeckTests/FleetProjectionTests.swift`

**Interfaces:**
- Consumes: `SessionStore.repos`, `.statuses`, `.unreadIdle`; `FleetSnapshot`, `WireProject`, `WireSession` (Task 2).
- Produces: `enum FleetProjection { @MainActor static func snapshot(of store: SessionStore) -> FleetSnapshot }`, plus `@MainActor static func project(_ repo: Repo, statuses:unread:) -> WireProject` for the emission sites in Tasks 9–10 to reuse.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetProjectionTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetProjectionTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(provider: nil, persistence: nil)
    }

    func testTheProjectionCarriesEveryProjectAndSessionInOrder() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let snapshot = FleetProjection.snapshot(of: store)
        XCTAssertEqual(snapshot.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snapshot.projects[0].sessions.map(\.id), [a.id])
        XCTAssertEqual(snapshot.projects[1].sessions.map(\.id), [b.id])
    }

    /// A tab with no registered agent process is statusless, and that has to reach the wire
    /// as `nil` rather than as `"idle"` — see `WireSession.activity`.
    func testASessionWithNoRegisteredProcessProjectsANilActivity() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertNil(FleetProjection.snapshot(of: store).projects[0].sessions[0].activity)
    }

    func testStatusAndUnreadAreCarriedOntoTheSession() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([
            session.id: SessionStatus(
                activity: .waiting, waitingFor: "permission prompt", subagentCount: 2
            )
        ])
        store.markUnreadForTesting([session.id])
        let projected = FleetProjection.snapshot(of: store).projects[0].sessions[0]
        XCTAssertEqual(projected.activity, "waiting")
        XCTAssertEqual(projected.waitingFor, "permission prompt")
        XCTAssertEqual(projected.subagentCount, 2)
        XCTAssertTrue(projected.isUnread)
    }

    func testCollapseStateIsCarried() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = try! XCTUnwrap(store.repos.first)
        store.setCollapsed(true, forProjectAt: project.id)
        XCTAssertTrue(FleetProjection.snapshot(of: store).projects[0].isCollapsed)
    }

    func testTheAgentIsCarriedAsItsRawValue() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertEqual(
            FleetProjection.snapshot(of: store).projects[0].sessions[0].agent,
            AgentID.claude.rawValue
        )
    }

    func testProjectingAnEmptyStoreIsAnEmptySnapshotNotACrash() {
        XCTAssertEqual(FleetProjection.snapshot(of: store()), .empty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetProjection' in scope`.

- [ ] **Step 3: Write the projection**

Create `Sources/FlightDeck/Fleet/FleetProjection.swift`:

```swift
import FleetKit
import Foundation

/// Reads the store into the wire's shape.
///
/// Two jobs, and the second is the one that pays for the first being pure: it builds the
/// snapshot a client gets at connect time, and it is the **oracle** `FleetReplicator`
/// compares its event-fold mirror against on every batch (see that type, and
/// specs/2026-08-18-fleet-state-encapsulation-design.md §4). Nothing here may mutate,
/// publish, or memoize — an assertion that changed the thing it was asserting about would be
/// worse than no assertion.
enum FleetProjection {
    @MainActor
    static func snapshot(of store: SessionStore) -> FleetSnapshot {
        FleetSnapshot(projects: store.repos.map {
            project($0, statuses: store.statuses, unread: store.unreadIdle)
        })
    }

    @MainActor
    static func project(
        _ repo: Repo, statuses: [UUID: SessionStatus], unread: Set<UUID>
    ) -> WireProject {
        WireProject(
            id: repo.id,
            name: repo.displayName,
            path: repo.url.path,
            isCollapsed: repo.isCollapsed,
            sessions: repo.sessions.map { project($0, status: statuses[$0.id], unread: unread) }
        )
    }

    @MainActor
    static func project(
        _ session: Session, status: SessionStatus?, unread: Set<UUID>
    ) -> WireSession {
        WireSession(
            id: session.id,
            title: session.title,
            agent: session.agent.rawValue,
            // `nil` deliberately, not `"idle"`: absence of a status means no agent process
            // is registered for this tab, which renders as nothing rather than as a dot.
            activity: status?.activity.rawValue,
            waitingFor: status?.waitingFor,
            subagentCount: status?.subagentCount ?? 0,
            isUnread: unread.contains(session.id)
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

If `applyRegistryForTesting` or `markUnreadForTesting` do not exist with those signatures, read `SessionStore.swift` around the `// MARK:` for test hooks and use whatever is there — do **not** add a new hook, and do not make `statuses` or `unreadIdle` settable from outside.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetProjection.swift \
        Tests/FlightDeckTests/FleetProjectionTests.swift
git commit -m "feat: read the live fleet into the shape a client renders"
```

---

### Task 8: `FleetReplicator` — the mirror, the ring, and the drift assertion

Three jobs in one type because they are one mechanism: it folds every recorded batch into a **mirror** snapshot (which is what a connecting client is handed, so the snapshot costs nothing to produce), keeps the recent past in a bounded **ring** (which is what a resuming client replays), and — in DEBUG — checks the mirror against a fresh projection after every batch.

That third job is the whole reason this plan can proceed before `SessionStore`'s fleet state is encapsulated. Read `specs/2026-08-18-fleet-state-encapsulation-design.md` §1 and §4 before touching this file: **a mutation site that changes state without recording its event leaves every connected client silently and permanently wrong**, nothing crashes, no existing test fails, and the symptom on the phone reads as a network bug. This assertion is the only thing standing between that and a stale client, and it must not be removed before the encapsulation replaces it.

`onDrift` exists so the assertion is *testable*: a bare `assertionFailure` would take the test runner down with it, and a safety net nobody can prove fires is not a safety net.

**Files:**
- Create: `Sources/FleetKit/SequencedEvent.swift`
- Create: `Sources/FlightDeck/Fleet/FleetReplicator.swift`
- Test: `Tests/FlightDeckTests/FleetReplicatorTests.swift`

**Interfaces:**
- Consumes: `FleetSnapshot`, `FleetEvent`, `FleetReplay.keptIndices` (Tasks 2–4), `SnapshotReason` (Task 5).
- Produces:
  - `public struct SequencedEvent: Codable, Equatable, Sendable { public let seq: Int; public let event: FleetEvent }` and `FleetReplay.fold(_: [SequencedEvent]) -> [SequencedEvent]`.
  - `@MainActor protocol FleetRecording: AnyObject { func record(_ events: [FleetEvent]); func reset() }` — Task 9 injects this into `SessionStore`.
  - `@MainActor final class FleetReplicator: FleetRecording` with `init(capacity:project:)`, `seq`, `snapshot() -> (seq: Int, fleet: FleetSnapshot)`, `resume(from:) -> Resume`, `reset()`, `var onEvents: (([SequencedEvent]) -> Void)?`, `var onDrift: ((FleetSnapshot, FleetSnapshot) -> Void)?`, and `enum Resume: Equatable { case replay([SequencedEvent]); case resnapshot(SnapshotReason) }`. Tasks 11 and 12 drive exactly these.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetReplicatorTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetReplicatorTests: XCTestCase {
    private let projectID = UUID()
    private let sessionID = UUID()

    /// The replicator is driven against a closure, not a store, so these tests describe the
    /// ring and the mirror without standing up surfaces or processes. The store-level
    /// coupling is Tasks 9 and 10's subject.
    private func makeReplicator(
        capacity: Int = 4096, truth: @escaping @MainActor () -> FleetSnapshot
    ) -> FleetReplicator {
        FleetReplicator(capacity: capacity, project: truth)
    }

    private func session(_ id: UUID, _ title: String = "s") -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func fleet(titled title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd",
                        sessions: [session(sessionID, title)])
        ])
    }

    // MARK: Sequencing and the mirror

    func testSequenceNumbersAdvanceOncePerEventNotOncePerBatch() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "c")
        replicator.record([
            .renamed(id: sessionID, title: "b", origin: .user),
            .renamed(id: sessionID, title: "c", origin: .user)
        ])
        XCTAssertEqual(replicator.seq, 2)
    }

    func testTheSnapshotIsTheFoldedMirrorNotAReprojection() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(replicator.snapshot().fleet, fleet(titled: "b"))
        XCTAssertEqual(replicator.snapshot().seq, 1)
    }

    func testRecordingNothingChangesNothing() {
        let replicator = makeReplicator { .empty }
        replicator.record([])
        XCTAssertEqual(replicator.seq, 0)
    }

    func testSubscribersSeeEachBatchWithItsSequenceNumbers() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var delivered: [SequencedEvent] = []
        replicator.onEvents = { delivered.append(contentsOf: $0) }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(delivered.map(\.seq), [1])
    }

    // MARK: Resume

    func testAClientAlreadyCurrentGetsAnEmptyReplay() {
        let replicator = makeReplicator { .empty }
        XCTAssertEqual(replicator.resume(from: 0), .resnapshot(.initial))
        var truth = fleet(titled: "a")
        let live = makeReplicator { truth }
        truth = fleet(titled: "b")
        live.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(live.resume(from: 1), .replay([]))
    }

    /// `lastSeq == 0` is "I have nothing", which is a snapshot rather than a replay of the
    /// whole ring — the ring is bounded and would silently under-deliver.
    func testAClientWithNothingIsSnapshotted() {
        XCTAssertEqual(makeReplicator { .empty }.resume(from: 0), .resnapshot(.initial))
    }

    func testAGapInsideTheRingIsReplayedWithItsOriginalSequenceNumbers() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        truth = FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd", sessions: [])
        ])
        replicator.record([.sessionRemoved(id: sessionID)])
        guard case .replay(let events) = replicator.resume(from: 1) else {
            return XCTFail("a gap inside the ring must replay")
        }
        XCTAssertEqual(events, [SequencedEvent(seq: 2, event: .sessionRemoved(id: sessionID))])
    }

    /// The replay is folded, which is what makes an hour offline resumable at all. Fifty
    /// flaps must arrive as one frame, still carrying a real sequence number.
    func testAReplayIsFoldedAndKeepsTheSurvivingEventsSequence() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        for i in 0..<50 {
            replicator.record([.activityChanged(
                id: sessionID, activity: i.isMultiple(of: 2) ? "busy" : "idle",
                waitingFor: nil, subagentCount: 0
            )])
        }
        guard case .replay(let events) = replicator.resume(from: 0 + 1) else {
            return XCTFail("expected a replay")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.seq, 50)
    }

    /// A client asking from before the ring's floor cannot be served, and must be told so
    /// rather than quietly resumed from wherever the ring happens to start — that is how a
    /// phone ends up confidently displaying a fleet that no longer exists.
    func testAGapOlderThanTheRingForcesAReSnapshot() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator(capacity: 4) { truth }
        for i in 0..<10 {
            replicator.record([.renamed(id: sessionID, title: "t\(i)", origin: .user)])
        }
        XCTAssertEqual(replicator.resume(from: 1), .resnapshot(.seqTooOld))
    }

    /// A client that claims a sequence the Mac has never issued has been talking to a
    /// different Flight Deck — a relaunch, or a restored backup. Snapshot it.
    func testAClientFromTheFutureIsSnapshotted() {
        XCTAssertEqual(makeReplicator { .empty }.resume(from: 99), .resnapshot(.seqTooOld))
    }

    func testTheRingIsBounded() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator(capacity: 4) { truth }
        for i in 0..<100 {
            replicator.record([.renamed(id: sessionID, title: "t\(i)", origin: .user)])
        }
        guard case .replay(let events) = replicator.resume(from: 99) else {
            return XCTFail("the newest events must still be replayable")
        }
        XCTAssertEqual(events.map(\.seq), [100])
    }

    /// After a wholesale restore there is no event sequence that describes what happened,
    /// so a client on the old sequence must be sent back for a snapshot rather than told it
    /// is current.
    func testAResetSendsEveryTrailingClientBackForASnapshot() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        truth = FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "restored", path: "/w/restored")
        ])
        replicator.reset()
        XCTAssertEqual(replicator.snapshot().fleet, truth)
        XCTAssertEqual(replicator.resume(from: 1), .resnapshot(.seqTooOld))
    }

    // MARK: Drift — the safety net itself

    /// The failure this whole mechanism exists to catch: a mutation happened, and whoever
    /// wrote it forgot to record its event. The mirror and the store disagree, and every
    /// connected client is now permanently wrong.
    func testAMutationWithNoEventIsReportedAsDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var drifts: [(FleetSnapshot, FleetSnapshot)] = []
        replicator.onDrift = { drifts.append(($0, $1)) }

        // The store moved on — a rename happened — but the event recorded alongside it was
        // about something else entirely.
        truth = fleet(titled: "renamed-but-unreported")
        replicator.record([.unreadChanged(id: sessionID, isUnread: true)])

        XCTAssertEqual(drifts.count, 1)
        XCTAssertEqual(drifts.first?.1, truth, "drift must report the store's actual state")
    }

    func testAFaithfulRecordingReportsNoDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var drifted = false
        replicator.onDrift = { _, _ in drifted = true }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertFalse(drifted)
    }

    /// After reporting, the mirror resynchronises. A replicator that kept serving a mirror
    /// it already knows is wrong would turn one missing line into every subsequent snapshot
    /// being wrong too.
    func testTheMirrorResynchronisesAfterDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        replicator.onDrift = { _, _ in }
        truth = fleet(titled: "actual")
        replicator.record([.unreadChanged(id: sessionID, isUnread: true)])
        XCTAssertEqual(replicator.snapshot().fleet, truth)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetReplicator' in scope`.

- [ ] **Step 3: Add the sequenced event and its fold to FleetKit**

Create `Sources/FleetKit/SequencedEvent.swift`:

```swift
import Foundation

/// An event with the position it holds in the northbound stream. The sequence is what a
/// client sends back as `hello(lastSeq:)` to resume.
public struct SequencedEvent: Codable, Equatable, Sendable {
    public let seq: Int
    public let event: FleetEvent

    public init(seq: Int, event: FleetEvent) {
        self.seq = seq
        self.event = event
    }
}

extension FleetReplay {
    /// The fold, keeping each surviving event's sequence number.
    ///
    /// Folding drops events, so the last survivor's sequence can be lower than the newest
    /// one issued. That is deliberate and harmless: a client's `lastSeq` is simply the
    /// highest it has seen, so a fold that discards the tail only makes its *next* resume
    /// window slightly wider. Inventing a synthetic sequence for a folded frame would be
    /// the alternative, and it would let a client claim to have applied an event it never
    /// received.
    public static func fold(_ events: [SequencedEvent]) -> [SequencedEvent] {
        keptIndices(events.map(\.event)).map { events[$0] }
    }
}
```

- [ ] **Step 4: Write the replicator**

Create `Sources/FlightDeck/Fleet/FleetReplicator.swift`:

```swift
import FleetKit
import Foundation
import OSLog

/// The sink `SessionStore` reports every fleet-state change to.
///
/// A protocol, and optional on the store, for the same reason `Notifying` is: the overwhelming
/// majority of tests construct a store that has no client attached and must not be made to
/// care.
@MainActor
protocol FleetRecording: AnyObject {
    func record(_ events: [FleetEvent])
    /// The fleet was replaced wholesale rather than changed — `SessionStore.restore` is the
    /// only caller. There is no sensible event sequence for "everything is different now",
    /// so this discards the replay history and forces every client behind the current
    /// sequence to re-snapshot.
    func reset()
}

/// Turns the store's change log into something a client can follow: a mirror to hand out at
/// connect time, and a bounded ring to replay across a gap.
///
/// **The drift check is load-bearing, not diagnostics.** Until `SessionStore`'s fleet state
/// is encapsulated (specs/2026-08-18-fleet-state-encapsulation-design.md), nothing stops a
/// new mutation site from changing `repos`, `statuses` or `unreadIdle` without recording its
/// event — and the consequence is not a crash but a client that is silently and permanently
/// wrong until it reconnects. Comparing the folded mirror against a fresh projection after
/// every batch is what turns that into a test failure at the moment the mutation is written.
/// Do not remove it before the encapsulation replaces it.
@MainActor
final class FleetReplicator: FleetRecording {
    enum Resume: Equatable {
        case replay([SequencedEvent])
        case resnapshot(SnapshotReason)
    }

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let capacity: Int
    private let project: @MainActor () -> FleetSnapshot
    private var ring: [SequencedEvent] = []
    private var mirror: FleetSnapshot

    private(set) var seq = 0

    /// Delivered to every attached client. Set by `FleetService` (Task 12).
    var onEvents: (([SequencedEvent]) -> Void)?

    /// Called when the mirror and a fresh projection disagree — i.e. a mutation happened
    /// without its event. `nil` means "trap", which is what a DEBUG build wants; the tests
    /// that prove this net actually fires install a spy instead, because an
    /// `assertionFailure` would take the runner down with it.
    var onDrift: ((_ mirrored: FleetSnapshot, _ actual: FleetSnapshot) -> Void)?

    init(capacity: Int = 4096, project: @escaping @MainActor () -> FleetSnapshot) {
        self.capacity = capacity
        self.project = project
        self.mirror = project()
    }

    func record(_ events: [FleetEvent]) {
        guard !events.isEmpty else { return }
        var batch: [SequencedEvent] = []
        batch.reserveCapacity(events.count)
        for event in events {
            seq += 1
            mirror.apply(event)
            batch.append(SequencedEvent(seq: seq, event: event))
        }
        ring.append(contentsOf: batch)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        checkForDrift()
        onEvents?(batch)
    }

    func snapshot() -> (seq: Int, fleet: FleetSnapshot) { (seq, mirror) }

    /// Re-read the store and throw the replay history away.
    ///
    /// The sequence still advances, and that is the load-bearing part: a client sitting on
    /// the old sequence must not be told "you are current" when the entire fleet was just
    /// replaced underneath it. Bumping past it, with an empty ring, is what routes that
    /// client to `.resnapshot` instead.
    func reset() {
        mirror = project()
        ring.removeAll()
        seq += 1
    }

    func resume(from lastSeq: Int) -> Resume {
        // "I have nothing" is a snapshot, not a replay of the whole ring: the ring is
        // bounded, so replaying it would silently deliver a partial fleet that looks whole.
        guard lastSeq > 0 else { return .resnapshot(.initial) }
        // A client claiming a sequence we have never issued has been talking to a different
        // Flight Deck — a relaunch, or a restored backup.
        guard lastSeq <= seq else { return .resnapshot(.seqTooOld) }
        guard lastSeq < seq else { return .replay([]) }
        // `floor - 1` is the newest sequence a client could have applied and still be
        // servable: the ring's first entry is the next one it needs.
        let floor = ring.first?.seq ?? (seq + 1)
        guard lastSeq >= floor - 1 else { return .resnapshot(.seqTooOld) }
        return .replay(FleetReplay.fold(ring.filter { $0.seq > lastSeq }))
    }

    private func checkForDrift() {
        #if DEBUG
        let actual = project()
        guard actual != mirror else { return }
        Self.logger.error(
            "fleet event log drifted from the store — a mutation recorded no event"
        )
        if let onDrift {
            onDrift(mirror, actual)
        } else {
            assertionFailure("""
                Fleet event log drifted from SessionStore.

                Some mutation changed repos/statuses/unreadIdle without recording its \
                FleetEvent. Every attached client is now wrong until it reconnects. Find the \
                write that has no `emit(...)` beside it — see \
                docs/superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md.
                """)
        }
        // Resynchronise so one missing line does not make every later snapshot wrong too.
        mirror = actual
        #endif
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/SequencedEvent.swift Sources/FlightDeck/Fleet/FleetReplicator.swift \
        Tests/FlightDeckTests/FleetReplicatorTests.swift
git commit -m "feat: mirror the fleet from its own event log, and assert the two agree"
```

---

### Task 9: Recording the fleet's shape — sessions and projects

The seam into `SessionStore`, plus every event about a session or project **existing**. Renames, status and unread are Task 10; splitting them is not arbitrary — this task's events change the snapshot's *structure* and Task 10's change fields inside it, so a reviewer can reject one and keep the other.

Two structural moves make this small rather than sprawling, and both are the local version of what `FleetState` will do properly later:

- **`emit` is one private method**, so a mutation site adds one line, not five.
- **`unreadIdle` gets a single private writer** in Task 10 for the same reason `commitStatuses` is the single writer of `statuses`: seven scattered `insert`/`remove` calls cannot each be trusted to remember an event.

The drift assertion from Task 8 is what proves each site landed. It is installed by a test helper here and used by every subsequent store test.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — add `replicator`/`emit`, then emit at `insertSession`, `addSession`, `closeSession`, `closeProject`, `setCollapsed`, `moveSidebarRows`, `moveSession`, `restore`
- Create: `Tests/FlightDeckTests/FleetEmissionHarness.swift`
- Test: `Tests/FlightDeckTests/FleetStructureEmissionTests.swift`

**Interfaces:**
- Consumes: `FleetRecording`, `FleetReplicator` (Task 8), `FleetProjection` (Task 7).
- Produces: `SessionStore.replicator: (any FleetRecording)?`; `SessionStore.emit(_:)` (private); test helper `func attachedReplicator(to: SessionStore) -> FleetReplicator` which installs a replicator whose `project` closure re-reads the store and whose `onDrift` fails the test.

- [ ] **Step 1: Write the test harness and the failing test**

Create `Tests/FlightDeckTests/FleetEmissionHarness.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

/// Installs a replicator on a store and turns any drift into a test failure with the two
/// snapshots printed side by side.
///
/// Every store test in this feature goes through here rather than constructing a replicator
/// inline, because the assertion is only worth anything if it is on by default: a test that
/// forgot to install it would pass over exactly the missing-emission bug the assertion
/// exists to catch.
@MainActor
func attachedReplicator(
    to store: SessionStore, file: StaticString = #filePath, line: UInt = #line
) -> FleetReplicator {
    let replicator = FleetReplicator { [weak store] in
        guard let store else { return .empty }
        return FleetProjection.snapshot(of: store)
    }
    replicator.onDrift = { mirrored, actual in
        XCTFail("""
            a mutation changed the fleet without recording its event.
            mirrored: \(mirrored)
            actual:   \(actual)
            """, file: file, line: line)
    }
    store.replicator = replicator
    return replicator
}
```

Create `Tests/FlightDeckTests/FleetStructureEmissionTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

/// These tests assert the *events*, and the harness's drift check independently asserts that
/// the events add up to the store. Both matter: the events are the contract a client sees,
/// and the drift check is what notices a site nobody thought to test.
@MainActor
final class FleetStructureEmissionTests: XCTestCase {
    private func store() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    private func recorded(_ replicator: FleetReplicator) -> [FleetEvent] { replicator.recorded }

    func testCreatingTheFirstSessionAnnouncesItsProjectThenItself() {
        let store = store()
        let replicator = attachedReplicator(to: store)
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        guard case .projectAdded(let project, let at) = recorded(replicator).first else {
            return XCTFail("a new project must be announced before the session inside it")
        }
        XCTAssertEqual(at, 0)
        XCTAssertEqual(project.name, "alpha")
        XCTAssertTrue(project.sessions.isEmpty,
                      "the project arrives empty; its session is a separate event")
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionAdded(let s, project.id, _) = $0 { return s.id == session.id }
            return false
        }))
    }

    func testASecondSessionInTheSameProjectAnnouncesNoSecondProject() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertFalse(recorded(replicator).contains { if case .projectAdded = $0 { return true }; return false })
    }

    /// A session landing in a collapsed project springs it open, and a client that missed
    /// that would render the new session inside a project that still looks closed.
    func testASessionLandingInACollapsedProjectAnnouncesTheExpansion() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        store.setCollapsed(true, forProjectAt: project)
        let replicator = attachedReplicator(to: store)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        XCTAssertTrue(recorded(replicator).contains(.projectCollapsed(id: project, isCollapsed: false)))
    }

    func testClosingASessionAnnouncesItsRemoval() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.closeSession(session.id)
        XCTAssertTrue(recorded(replicator).contains(.sessionRemoved(id: session.id)))
    }

    /// Closing a project closes its sessions first, so a client sees each leave before the
    /// project does. Order matters here: a `projectRemoved` alone would be enough for the
    /// snapshot, but the timeline and notifications read individual removals.
    func testClosingAProjectAnnouncesItsSessionsThenItself() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        let replicator = attachedReplicator(to: store)
        store.closeProject(project)
        let events = recorded(replicator)
        let sessionAt = events.firstIndex(of: .sessionRemoved(id: session.id))
        let projectAt = events.firstIndex(of: .projectRemoved(id: project))
        XCTAssertNotNil(sessionAt)
        XCTAssertNotNil(projectAt)
        XCTAssertLessThan(try XCTUnwrap(sessionAt), try XCTUnwrap(projectAt))
    }

    func testCollapsingAProjectIsAnnouncedOnceAndOnlyOnAChange() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let project = store.repos[0].id
        let replicator = attachedReplicator(to: store)
        store.setCollapsed(true, forProjectAt: project)
        store.setCollapsed(true, forProjectAt: project)
        XCTAssertEqual(
            recorded(replicator).filter { if case .projectCollapsed = $0 { return true }; return false }.count,
            1
        )
    }

    func testMovingASessionToAnotherProjectAnnouncesTheMoveNotAnAddAndRemove() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let beta = store.repos[1].id
        let replicator = attachedReplicator(to: store)
        store.moveSession(session.id, toProjectAt: URL(fileURLWithPath: "/w/beta"))
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionMoved(session.id, beta, _) = $0 { return true }
            return false
        }))
        XCTAssertFalse(recorded(replicator).contains(.sessionRemoved(id: session.id)),
                       "a move must not read as a close on the client")
    }

    func testMovingASessionIntoAProjectThatDoesNotExistYetAnnouncesItFirst() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.moveSession(session.id, toProjectAt: URL(fileURLWithPath: "/w/gamma"))
        guard let firstProject = recorded(replicator).first(where: {
            if case .projectAdded = $0 { return true }; return false
        }), case .projectAdded(let project, _) = firstProject else {
            return XCTFail("the destination project must be announced before the move")
        }
        XCTAssertEqual(project.name, "gamma")
        XCTAssertTrue(recorded(replicator).contains(where: {
            if case .sessionMoved(session.id, project.id, _) = $0 { return true }
            return false
        }))
    }

    func testReorderingTheSidebarAnnouncesTheNewOrder() {
        let store = store()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = store.newSession(in: URL(fileURLWithPath: "/w/beta"))
        let order = store.repos.map(\.id)
        let replicator = attachedReplicator(to: store)
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertTrue(recorded(replicator).contains(.projectsReordered(order: [order[1], order[0]])))
    }
}
```

Add the recording spy the tests read. Inside `FleetReplicator`, beside `ring`:

```swift
    #if DEBUG
    /// Every event recorded so far, for tests that assert the emission itself rather than
    /// its effect. Unbounded, unlike `ring` — a test wants the whole history of the mutation
    /// it just performed, and a test's fleet does not run for hours. DEBUG-only: nothing in
    /// the app has any business reading the log back.
    private(set) var recorded: [FleetEvent] = []
    #endif
```

appended to in `record`, right after `mirror.apply(event)`:

```swift
            #if DEBUG
            recorded.append(event)
            #endif
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `value of type 'SessionStore' has no member 'replicator'`.

- [ ] **Step 3: Add the seam to `SessionStore`**

Beside `var notifier: Notifying?` (around line 458):

```swift
    /// Where fleet changes are reported for replication to paired devices. Optional and nil
    /// by default, exactly like `notifier`: nearly every test builds a store with no client
    /// attached and must not be made to care.
    ///
    /// **If you add a mutation to `repos`, `statuses` or `unreadIdle`, it must `emit` its
    /// event.** Forgetting leaves every connected phone silently wrong until it reconnects —
    /// nothing crashes and no existing test fails. `FleetReplicator`'s DEBUG drift check is
    /// what turns that omission into a failure; see
    /// docs/superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md for the
    /// structural fix that will eventually make it unwriteable.
    var replicator: (any FleetRecording)?

    private func emit(_ events: FleetEvent...) {
        guard let replicator, !events.isEmpty else { return }
        replicator.record(events)
    }

    /// The wire form of a session as it stands right now.
    private func wire(_ session: Session) -> WireSession {
        FleetProjection.project(session, status: statuses[session.id], unread: unreadIdle)
    }
```

Add `import FleetKit` at the top of `SessionStore.swift`.

- [ ] **Step 4: Emit at each structural site**

`insertSession` — announce a project the moment it is created, empty, then the session:

```swift
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
            // Emitted here, before the session goes in, so a client never receives a
            // `sessionAdded` naming a project it has not been told about.
            emit(.projectAdded(
                FleetProjection.project(repos[repoIndex], statuses: statuses, unread: unreadIdle),
                at: repoIndex
            ))
        }
        let insertedAt: Int
        if let index, index >= 0, index <= repos[repoIndex].sessions.count {
            repos[repoIndex].sessions.insert(session, at: index)
            insertedAt = index
        } else {
            repos[repoIndex].sessions.append(session)
            insertedAt = repos[repoIndex].sessions.count - 1
        }
        emit(.sessionAdded(wire(session), project: repos[repoIndex].id, at: insertedAt))
```

`addSession` — the expansion is a real change a client must see:

```swift
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
```

`closeSession` — immediately after `repos[repoIndex].sessions.remove(at: sessionIndex)`:

```swift
        emit(.sessionRemoved(id: id))
```

The `unreadIdle.remove(id)` further down in the same method needs **no** event: the session is already gone from the client's snapshot, so its unread bit went with it.

`closeProject` — after `repos.removeAll { $0.id == id }`:

```swift
        emit(.projectRemoved(id: id))
```

`setCollapsed` — after `repos[index].isCollapsed = isCollapsed`:

```swift
        emit(.projectCollapsed(id: id, isCollapsed: isCollapsed))
```

`moveSidebarRows` — the one place a diff is the honest description, because `SidebarReorder.apply` returns a whole rearranged array and there is no smaller intent to report:

```swift
    func moveSidebarRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let updated = SidebarReorder.apply(
            to: repos, rows: sidebarRows, from: source, to: destination
        ) else { return }
        let before = repos
        repos = updated
        emitReorder(from: before, to: updated)
        persist()
    }

    /// A reorder is the one mutation whose input is already a whole rebuilt array — the
    /// policy lives in `SidebarReorder` and hands back `[Repo]`, not a move. Comparing the
    /// two is therefore describing what the caller did, not the store-wide diffing the
    /// design rejected: the comparison is bounded by one gesture.
    private func emitReorder(from before: [Repo], to after: [Repo]) {
        if before.map(\.id) != after.map(\.id) {
            emit(.projectsReordered(order: after.map(\.id)))
        }
        for repo in after {
            guard
                let old = before.first(where: { $0.id == repo.id }),
                old.sessions.map(\.id) != repo.sessions.map(\.id)
            else { continue }
            emit(.sessionsReordered(project: repo.id, order: repo.sessions.map(\.id)))
        }
    }
```

`moveSession` — the destination may not exist yet, and it is un-collapsed on arrival:

```swift
        let destination: Int
        if let existing = indexOfRepo(for: target) {
            destination = existing
        } else {
            repos.append(Repo(url: target))
            destination = repos.count - 1
            emit(.projectAdded(
                FleetProjection.project(repos[destination], statuses: statuses, unread: unreadIdle),
                at: destination
            ))
        }
        repos[destination].sessions.append(session)
        emit(.sessionMoved(
            id: id, project: repos[destination].id,
            at: repos[destination].sessions.count - 1
        ))
        if repos[destination].isCollapsed {
            repos[destination].isCollapsed = false
            emit(.projectCollapsed(id: repos[destination].id, isCollapsed: false))
        }
```

`restore` — at the very end of the method, after the whole fleet has been rebuilt:

```swift
        // The fleet was replaced, not changed. There is no event sequence that describes
        // that, and emitting one per restored row would be a lie about what happened — so
        // the replicator re-reads and anyone behind is sent back for a snapshot.
        replicator?.reset()
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS. A `FleetEmissionHarness` drift failure names the site you missed — read the two snapshots it prints.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/Fleet/FleetReplicator.swift \
        Tests/FlightDeckTests/FleetEmissionHarness.swift \
        Tests/FlightDeckTests/FleetStructureEmissionTests.swift
git commit -m "feat: report every session and project the fleet gains, loses or moves"
```

---

### Task 10: Recording titles, status and unread

The fields inside a row. Three subjects, three shapes of problem:

- **Titles** have two sites and they carry different intent — `rename` is the user, `applyExternalTitle` is the agent renaming its own conversation. That distinction cannot be recovered from a diff, which is the concrete reason §5 chose an event log.
- **Status** has a documented single writer (`commitStatuses`) that already computes `[StatusTransition]` per tick — the replicator becomes its fourth consumer alongside `applyReadState`, `deliverNotifications` and `cancelSupersededPrompts`. But there is a **second, undocumented writer**: `applySubagentCount` writes `statuses[id] = status` directly. It must emit too, and it is exactly the kind of site the drift assertion exists to catch.
- **Unread** has seven scattered writers. Routing them through one private mutator is the only way this stays correct, and it is the local version of what `FleetState` will enforce properly.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/FleetFieldEmissionTests.swift`

**Interfaces:**
- Consumes: everything from Task 9.
- Produces: `SessionStore.setUnread(_:_:)` (private, the single writer of `unreadIdle`).

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetFieldEmissionTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetFieldEmissionTests: XCTestCase {
    private func store() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    /// The distinction a diff cannot carry, and the reason this is an event log: both
    /// produce an identical `title` field and they are different facts.
    func testAUserRenameAndAnAgentRenameAreDistinguishable() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)

        store.rename(session.id, to: "typed")
        XCTAssertTrue(replicator.recorded.contains(
            .renamed(id: session.id, title: "typed", origin: .user)
        ))

        store.applyExternalTitle(session.id, "self-named")
        XCTAssertTrue(replicator.recorded.contains(
            .renamed(id: session.id, title: "self-named", origin: .agent)
        ))
    }

    /// `applyExternalTitle`'s equality check is the loop guard against our own rename echoing
    /// back. An event emitted before that guard would put the echo on the wire.
    func testAnEchoedExternalTitleEmitsNothing() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.rename(session.id, to: "settled")
        let replicator = attachedReplicator(to: store)
        store.applyExternalTitle(session.id, "settled")
        XCTAssertTrue(replicator.recorded.isEmpty)
    }

    func testAStatusTickEmitsOneActivityEventPerChangedSession() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([
            a.id: SessionStatus(activity: .busy, subagentCount: 3),
            b.id: SessionStatus(activity: .waiting, waitingFor: "input needed")
        ])
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: a.id, activity: "busy", waitingFor: nil, subagentCount: 3
        )))
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: b.id, activity: "waiting", waitingFor: "input needed", subagentCount: 0
        )))
    }

    /// A tab whose agent exits goes statusless, which is not the same as idle. Emitting
    /// nothing here would leave the phone showing whatever it was doing when it died.
    func testASessionLosingItsProcessEmitsANilActivity() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([:])
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: session.id, activity: nil, waitingFor: nil, subagentCount: 0
        )))
    }

    /// The second, easily-missed writer of `statuses`. This is the site the drift assertion
    /// was built to catch, so it gets a test of its own.
    func testASubagentCountArrivingOnItsOwnIsAnnounced() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applySubagentCount(session.id, 4)
        XCTAssertTrue(replicator.recorded.contains(.activityChanged(
            id: session.id, activity: "busy", waitingFor: nil, subagentCount: 4
        )))
    }

    func testMarkingUnreadAndReadingItAgainAreBothAnnounced() {
        let store = store()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(b.id)
        let replicator = attachedReplicator(to: store)

        store.markUnread(a.id)
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: a.id, isUnread: true)))

        // Selecting a tab is what marks it read — the one unread write that happens in a
        // `didSet` rather than in a named method.
        store.selectSession(a.id)
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: a.id, isUnread: false)))
    }

    func testMarkingAnAlreadyUnreadSessionEmitsNothingNew() {
        let store = store()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(session.id)
        store.markUnread(session.id)
        let replicator = attachedReplicator(to: store)
        store.markUnread(session.id)
        XCTAssertTrue(replicator.recorded.isEmpty, "an unchanged flag is not an event")
    }

    /// A session finishing while the user is looking elsewhere is the whole point of the
    /// unread mark, and it is set from `applyReadState` rather than from any named method.
    func testFinishingUnwatchedIsAnnouncedAsUnread() {
        let store = store()
        let watched = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let other = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(other.id)
        store.applyRegistryForTesting([watched.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)
        store.applyRegistryForTesting([watched.id: SessionStatus(activity: .idle)])
        XCTAssertTrue(replicator.recorded.contains(.unreadChanged(id: watched.id, isUnread: true)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — the emission assertions fail, and the harness reports drift on top.

- [ ] **Step 3: Emit on the two rename paths**

`rename(_:to:)` — after `repos[at.repo].sessions[at.session].title = name`:

```swift
        emit(.renamed(id: id, title: name, origin: .user))
```

`applyExternalTitle(_:_:)` — after the same assignment. It sits **below** the guard whose equality check is the loop breaker, so our own rename echoing back through the transcript emits nothing:

```swift
        emit(.renamed(id: id, title: name, origin: .agent))
```

- [ ] **Step 4: Emit on both status writers**

In `commitStatuses`, alongside the three existing consumers of the same transition list — it becomes the fourth, which is the pattern §5 of the spec points at:

```swift
        applyReadState(transitions)
        deliverNotifications(transitions)
        cancelSupersededPrompts(transitions)
        emitActivity(transitions)
```

and:

```swift
    /// The fourth consumer of a tick's transitions. Reads off the same diff the other three
    /// do, so a status a client sees is by construction the status that drove the sidebar,
    /// the notification and the prompt cancellation.
    private func emitActivity(_ transitions: [StatusTransition]) {
        let changed = transitions.filter { $0.old != $0.new }
        guard !changed.isEmpty else { return }
        replicator?.record(changed.map { transition in
            .activityChanged(
                id: transition.id,
                // nil rather than "idle": no status means no agent process, and the two
                // render differently.
                activity: transition.new?.activity.rawValue,
                waitingFor: transition.new?.waitingFor,
                subagentCount: transition.new?.subagentCount ?? 0
            )
        })
    }
```

In `applySubagentCount`, after `statuses[id] = status` — the writer that does **not** go through `commitStatuses`:

```swift
        emit(.activityChanged(
            id: id, activity: status.activity.rawValue,
            waitingFor: status.waitingFor, subagentCount: status.subagentCount
        ))
```

- [ ] **Step 5: Give `unreadIdle` a single writer**

Add:

```swift
    /// The only writer of `unreadIdle`.
    ///
    /// Not style. There were seven `insert`/`remove` sites — a selection `didSet`, restore,
    /// `markUnread`, `closeSession`, `applyReadState`, app activation, and a test seam — and
    /// each one having to remember an event is the omission this whole mechanism is trying
    /// to make impossible. Returning early on an unchanged flag also keeps a client from
    /// receiving an event per poll for a session that has been unread for an hour.
    @discardableResult
    private func setUnread(_ id: UUID, _ isUnread: Bool) -> Bool {
        let changed = isUnread
            ? unreadIdle.insert(id).inserted
            : unreadIdle.remove(id) != nil
        guard changed else { return false }
        emit(.unreadChanged(id: id, isUnread: isUnread))
        return true
    }
```

Then route every existing site through it:

| Site | Was | Becomes |
|---|---|---|
| `selectedSessionID.didSet` | `unreadIdle.remove(id)` | `setUnread(id, false)` |
| `restore`, per entry | `unreadIdle.insert(entry.id)` | `setUnread(entry.id, true)` |
| `markUnread(_:)` | `unreadIdle.insert(id)` | `setUnread(id, true)` |
| `closeSession(_:)` | `unreadIdle.remove(id)` | `setUnread(id, false)` |
| `applyReadState`, `.mark` | `unreadIdle.insert(...)` | `setUnread(transition.id, true)` |
| `applyReadState`, `.clear` | `unreadIdle.remove(...)` | `setUnread(transition.id, false)` |
| `observeAppActivation` | `self.unreadIdle.remove(id)` | `self.setUnread(id, false)` |
| `markUnreadForTesting(_:)` | `unreadIdle.formUnion(ids)` | `for id in ids { setUnread(id, true) }` |

`closeSession`'s call now runs **after** its `emit(.sessionRemoved(id:))`, so it emits nothing — the id is no longer in the mirror. That is correct and needs no special case.

After this, `rg -n 'unreadIdle\.(insert|remove|formUnion)' Sources/FlightDeck/SessionStore.swift` must match only the two lines inside `setUnread`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS — the whole suite, not just the new file. The pre-existing unread and status tests are the regression net for the rerouting.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FleetFieldEmissionTests.swift
git commit -m "feat: report title, status and unread changes with the intent behind them"
```

---

### Task 11: The socket, both halves, proven over loopback

One WebSocket carries everything (§4). Both halves live in FleetKit — the server half knows nothing about `SessionStore`, it just calls closures — which is what lets this task's test drive a *real* client against a *real* server inside the macOS test bundle, with no phone, no simulator and no store.

That is the point of the split. The alternative, a server that reaches into the store directly, would have made the only possible end-to-end test a manual one on a device.

**Files:**
- Create: `Sources/FleetKit/FleetSocket.swift` (shared frame send/receive over an `NWConnection`)
- Create: `Sources/FleetKit/FleetSocketServer.swift`
- Create: `Sources/FleetKit/FleetClient.swift`
- Test: `Tests/FlightDeckTests/FleetSocketLoopbackTests.swift`

**Interfaces:**
- Consumes: `FleetTLS` (Task 6), `ClientFrame`/`ServerFrame` (Task 5).
- Produces:
  - `public final class FleetSocketServer` — `init(queue:)`, `start(keys:port:) throws -> NWEndpoint.Port`, `stop()`, `broadcast(_: ServerFrame)`, `var onHello: ((UUID, Int) -> [ServerFrame])?`, `var onCommand: ((UUID, Int, FleetCommand) -> ServerFrame)?`, `var onAttachedCountChanged: ((Int) -> Void)?`, `var authDeadline: TimeInterval`.
  - `public final class FleetClient` — `init(key:queue:)`, `connect(to: NWEndpoint, lastSeq: Int)`, `disconnect()`, `send(_: FleetCommand) -> Int`, `var onFrame: ((ServerFrame) -> Void)?`, `var onReady: (() -> Void)?`, `var onDisconnect: ((Error?) -> Void)?`.
- Task 12 wires the server's closures to the store.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetSocketLoopbackTests.swift`:

```swift
import Network
import XCTest
import FleetKit

/// The whole spine, end to end, in one process: a real TLS-PSK handshake, a real WebSocket,
/// real frames. The server half is driven by closures rather than by a `SessionStore`, which
/// is exactly what makes this testable at all — see Task 11's note.
final class FleetSocketLoopbackTests: XCTestCase {
    private var server: FleetSocketServer?
    private var client: FleetClient?

    override func tearDown() {
        client?.disconnect()
        server?.stop()
        client = nil
        server = nil
        super.tearDown()
    }

    private let sessionID = UUID()

    private func fleet(_ title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [
                WireSession(id: sessionID, title: title, agent: "claude")
            ])
        ])
    }

    /// Starts a server whose `hello` always answers with one snapshot at seq 7.
    @discardableResult
    private func startServer(
        key: FleetDeviceKey,
        hello: @escaping (UUID, Int) -> [ServerFrame],
        command: @escaping (UUID, Int, FleetCommand) -> ServerFrame = { _, cid, _ in .ack(cid: cid) }
    ) throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        server.onHello = hello
        server.onCommand = command
        self.server = server
        return try server.start(keys: [key], port: nil)
    }

    private func connect(key: FleetDeviceKey, port: NWEndpoint.Port, lastSeq: Int = 0) -> FleetClient {
        let client = FleetClient(key: key)
        self.client = client
        client.connect(
            to: .hostPort(host: "127.0.0.1", port: port), lastSeq: lastSeq
        )
        return client
    }

    func testAPairedClientReceivesTheSnapshotItAskedFor() throws {
        let key = FleetDeviceKey.mint()
        let expected = fleet("one")
        let port = try startServer(key: key, hello: { _, lastSeq in
            XCTAssertEqual(lastSeq, 0)
            return [.snapshot(seq: 7, fleet: expected, reason: .initial)]
        })

        let received = expectation(description: "snapshot")
        var frames: [ServerFrame] = []
        let client = connect(key: key, port: port)
        client.onFrame = { frames.append($0); received.fulfill() }
        wait(for: [received], timeout: 10)

        XCTAssertEqual(frames, [.snapshot(seq: 7, fleet: expected, reason: .initial)])
    }

    func testLiveEventsReachAnAttachedClient() throws {
        let key = FleetDeviceKey.mint()
        let port = try startServer(key: key, hello: { _, _ in
            [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)]
        })

        let sawEvent = expectation(description: "event")
        let client = connect(key: key, port: port)
        client.onFrame = { frame in
            if case .event(2, .renamed(_, "two", .user)) = frame { sawEvent.fulfill() }
        }
        // Broadcast only after the client is attached, or the frame has nowhere to go —
        // the server holds no queue for a client that has not connected yet.
        let attached = expectation(description: "attached")
        server?.onAttachedCountChanged = { if $0 == 1 { attached.fulfill() } }
        wait(for: [attached], timeout: 10)
        server?.broadcast(.event(seq: 2, .renamed(id: sessionID, title: "two", origin: .user)))
        wait(for: [sawEvent], timeout: 10)
    }

    func testResumingSendsTheSequenceTheClientAlreadyHas() throws {
        let key = FleetDeviceKey.mint()
        let asked = expectation(description: "hello with lastSeq")
        let port = try startServer(key: key, hello: { _, lastSeq in
            if lastSeq == 812 { asked.fulfill() }
            return [.snapshot(seq: 900, fleet: self.fleet("one"), reason: .seqTooOld)]
        })
        _ = connect(key: key, port: port, lastSeq: 812)
        wait(for: [asked], timeout: 10)
    }

    func testACommandIsAcknowledgedAgainstItsOwnCorrelationID() throws {
        let key = FleetDeviceKey.mint()
        let delivered = expectation(description: "command reached the server")
        let port = try startServer(
            key: key,
            hello: { _, _ in [.snapshot(seq: 1, fleet: self.fleet("one"), reason: .initial)] },
            command: { _, cid, command in
                XCTAssertEqual(command, .markRead(id: self.sessionID))
                delivered.fulfill()
                return .ack(cid: cid)
            }
        )

        let acked = expectation(description: "ack")
        let client = connect(key: key, port: port)
        var cid = 0
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(.markRead(id: self.sessionID)) }
            if case .ack(cid) = frame, cid != 0 { acked.fulfill() }
        }
        wait(for: [delivered, acked], timeout: 10)
    }

    /// The trust boundary again, this time through the whole stack rather than at the TLS
    /// layer alone: an unpaired device must never reach `onHello`.
    func testAnUnpairedClientNeverReachesApplicationCode() throws {
        let port = try startServer(key: .mint(), hello: { _, _ in
            XCTFail("an unpaired device reached the application layer")
            return []
        })
        let client = FleetClient(key: .mint())
        self.client = client
        let refused = expectation(description: "refused")
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        // A refusal can also present as silence; either way `onHello` must not have run,
        // which is what the XCTFail above asserts.
        _ = XCTWaiter().wait(for: [refused], timeout: 8)
    }

    /// A peer that completes a handshake and then says nothing must not hold a slot open
    /// forever — that is a resource leak reachable by anyone holding a revoked-but-not-yet-
    /// deleted key.
    func testASilentClientIsDroppedAfterTheAuthDeadline() throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.authDeadline = 0.5
        server.onHello = { _, _ in [] }
        self.server = server
        let port = try server.start(keys: [key], port: nil)

        var counts: [Int] = []
        let dropped = expectation(description: "dropped")
        server.onAttachedCountChanged = { count in
            counts.append(count)
            if counts.contains(1) && count == 0 { dropped.fulfill() }
        }
        // A raw TLS connection that never speaks WebSocket-frames-with-a-hello.
        let silent = NWConnection(
            host: "127.0.0.1", port: port, using: FleetTLS.clientParameters(key: key)
        )
        silent.start(queue: .main)
        wait(for: [dropped], timeout: 10)
        silent.cancel()
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetSocketServer' in scope`.

- [ ] **Step 3: Write the shared frame plumbing**

Create `Sources/FleetKit/FleetSocket.swift`:

```swift
import Foundation
import Network

/// Frame send/receive over one `NWConnection`, shared by both halves.
///
/// WebSocket rather than a bare length prefix over TLS, for two reasons that both bite
/// later: ping/pong keepalive is what keeps a phone's connection alive through a carrier's
/// idle timeout, and a relay (§3, out of scope but designed for) speaks WebSocket
/// everywhere and a bespoke framing nowhere.
enum FleetSocket {
    static func webSocketParameters(_ base: NWParameters) -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        // Answer the peer's pings in the stack rather than in application code: a keepalive
        // that depends on the app being responsive is not a keepalive.
        options.autoReplyPing = true
        base.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return base
    }

    static func send<Frame: Encodable>(
        _ frame: Frame, over connection: NWConnection, onError: ((Error) -> Void)? = nil
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(frame)
        } catch {
            onError?(error)
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { error in if let error { onError?(error) } }
        )
    }

    /// Delivers whole messages, repeatedly, until the connection ends. `receiveMessage`
    /// rather than `receive(minimumIncompleteLength:)` because the WebSocket protocol has
    /// already done the framing — reassembling it by hand would be reimplementing it.
    static func receive<Frame: Decodable>(
        _ type: Frame.Type, from connection: NWConnection,
        onFrame: @escaping (Frame) -> Void, onEnd: @escaping (Error?) -> Void
    ) {
        connection.receiveMessage { data, context, _, error in
            if let error {
                onEnd(error)
                return
            }
            if let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                onEnd(nil)
                return
            }
            if let data, !data.isEmpty {
                do {
                    onFrame(try JSONDecoder().decode(Frame.self, from: data))
                } catch {
                    // A frame we cannot parse is a protocol violation, not a transient
                    // hiccup: continuing would leave the two sides silently disagreeing
                    // about state, which is the failure mode the whole resume design
                    // exists to make impossible.
                    onEnd(error)
                    return
                }
            }
            receive(type, from: connection, onFrame: onFrame, onEnd: onEnd)
        }
    }
}
```

- [ ] **Step 4: Write the server half**

Create `Sources/FleetKit/FleetSocketServer.swift`:

```swift
import Foundation
import Network

/// The listener, and one attached-client registry. Knows nothing about what a fleet is —
/// every decision is a closure the app supplies, which is what lets the whole protocol be
/// tested in one process without a store.
public final class FleetSocketServer {
    /// How long a peer may hold a completed handshake without sending `hello` before it is
    /// dropped. Settable so the test does not have to wait the production value.
    public var authDeadline: TimeInterval = 5

    /// Answers a client's first frame. Returns the frames to send back — a snapshot, or a
    /// folded replay.
    public var onHello: ((_ client: UUID, _ lastSeq: Int) -> [ServerFrame])?
    /// Answers a command. Returns the single frame to reply with (`ack` or `err`).
    public var onCommand: ((_ client: UUID, _ cid: Int, _ command: FleetCommand) -> ServerFrame)?
    public var onAttachedCountChanged: ((Int) -> Void)?

    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Only clients that have said `hello`. A handshake alone does not make an attachment,
    /// which is what keeps `onAttachedCountChanged` meaningful as "phones watching".
    private var attached: [UUID: NWConnection] = [:]

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// `port: nil` asks the OS for one, which is what the tests use. Returns the port
    /// actually bound, for advertising.
    @discardableResult
    public func start(keys: [FleetDeviceKey], port: NWEndpoint.Port?) throws -> NWEndpoint.Port {
        stop()
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys)
        )
        let listener = try port.map { try NWListener(using: parameters, on: $0) }
            ?? NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener

        // `listener.port` is nil until the listener is ready, and a caller that has to
        // advertise the port cannot proceed without it.
        let deadline = Date().addingTimeInterval(5)
        while listener.port == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let bound = listener.port else { throw FleetSocketError.didNotBind }
        return bound
    }

    public func stop() {
        for connection in attached.values { connection.cancel() }
        attached.removeAll()
        listener?.cancel()
        listener = nil
    }

    public func broadcast(_ frame: ServerFrame) {
        for connection in attached.values {
            FleetSocket.send(frame, over: connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.start(queue: queue)

        // Drop a peer that completed a handshake and then said nothing. Without this a
        // silent connection holds a slot for as long as the app runs.
        queue.asyncAfter(deadline: .now() + authDeadline) { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.attached[id] == nil else { return }
            connection.cancel()
        }

        FleetSocket.receive(ClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .hello(let lastSeq):
                if self.attached[id] == nil {
                    self.attached[id] = connection
                    self.onAttachedCountChanged?(self.attached.count)
                }
                for reply in self.onHello?(id, lastSeq) ?? [] {
                    FleetSocket.send(reply, over: connection)
                }
            case .cmd(let cid, let command):
                // A command before `hello` is a client that skipped the handshake step;
                // answering it would let an unattached peer drive the Mac.
                guard self.attached[id] != nil else { return connection.cancel() }
                let reply = self.onCommand?(id, cid, command) ?? .err(cid: cid, code: "unhandled")
                FleetSocket.send(reply, over: connection)
            }
        } onEnd: { [weak self] _ in
            guard let self else { return }
            connection.cancel()
            guard self.attached.removeValue(forKey: id) != nil else { return }
            self.onAttachedCountChanged?(self.attached.count)
        }
    }
}

public enum FleetSocketError: Error {
    case didNotBind
}
```

- [ ] **Step 5: Write the client half**

Create `Sources/FleetKit/FleetClient.swift`:

```swift
import Foundation
import Network

/// The client end. Ships in FleetKit rather than in the phone app so the loopback test can
/// drive the real thing — a second, test-only client implementation would prove nothing
/// about the one that ships.
public final class FleetClient {
    public var onFrame: ((ServerFrame) -> Void)?
    public var onReady: (() -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let key: FleetDeviceKey
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var nextCID = 1

    public init(key: FleetDeviceKey, queue: DispatchQueue = .main) {
        self.key = key
        self.queue = queue
    }

    public func connect(to endpoint: NWEndpoint, lastSeq: Int) {
        disconnect()
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.clientParameters(key: key)
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // `hello` goes out the instant the socket is usable. TLS-PSK has already
                // established who we are, so this is a resume point, not a credential.
                FleetSocket.send(ClientFrame.hello(lastSeq: lastSeq), over: connection)
                self.onReady?()
            case .failed(let error):
                self.onDisconnect?(error)
            case .cancelled:
                self.onDisconnect?(nil)
            default:
                break
            }
        }
        FleetSocket.receive(ServerFrame.self, from: connection) { [weak self] frame in
            self?.onFrame?(frame)
        } onEnd: { [weak self] error in
            self?.onDisconnect?(error)
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    /// Returns the correlation id the reply will carry. `ack` means dispatched, not done —
    /// the observable effect arrives separately as a northbound event (§4).
    @discardableResult
    public func send(_ command: FleetCommand) -> Int {
        guard let connection else { return 0 }
        let cid = nextCID
        nextCID += 1
        FleetSocket.send(ClientFrame.cmd(cid: cid, command), over: connection)
        return cid
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

If `testAnUnpairedClientNeverReachesApplicationCode` hangs rather than failing fast, that is the handshake being refused by silence — the `XCTWaiter` there tolerates it deliberately, and the real assertion is the `XCTFail` inside `onHello`.

- [ ] **Step 7: Verify the iOS slice still compiles**

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. This is the check that catches a macOS-only API slipping into the socket code.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/FleetSocket.swift Sources/FleetKit/FleetSocketServer.swift \
        Sources/FleetKit/FleetClient.swift Tests/FlightDeckTests/FleetSocketLoopbackTests.swift
git commit -m "feat: carry the fleet over one authenticated websocket, both ends"
```

---

### Task 12: `FleetService` — the store on one end, the socket on the other

The only type that knows both. It owns the replicator, installs it on the store, broadcasts each recorded batch, answers `hello` from the ring, and turns a command into a store method call.

The spec's rule about commands is followed literally here: *where a command has no existing store method, add one to the store rather than special-casing it in the replicator* — because anything the phone can do, the Mac's own UI should be able to do. `markRead` is that case.

**Files:**
- Create: `Sources/FlightDeck/Fleet/FleetService.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add `markRead(_:)`)
- Test: `Tests/FlightDeckTests/FleetServiceTests.swift`

**Interfaces:**
- Consumes: `FleetSocketServer` (Task 11), `FleetReplicator` (Task 8), `FleetProjection` (Task 7), `SessionStore`.
- Produces: `@MainActor final class FleetService: ObservableObject` — `init(store:keys:)`, `start(port:) throws -> NWEndpoint.Port`, `stop()`, `@Published private(set) var attachedDeviceCount: Int`; and `SessionStore.markRead(_ id: UUID)`. Plan 2's pairing UI reads `attachedDeviceCount` and supplies `keys`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetServiceTests.swift`:

```swift
import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The seam test: a real client, a real socket, and a real `SessionStore` at the far end.
/// This is the test that says slice 1a's spine works.
@MainActor
final class FleetServiceTests: XCTestCase {
    private var service: FleetService?
    private var client: FleetClient?

    override func tearDown() async throws {
        client?.disconnect()
        service?.stop()
        client = nil
        service = nil
    }

    private func standUp() throws -> (SessionStore, FleetDeviceKey, NWEndpoint.Port) {
        let store = SessionStore(provider: nil, persistence: nil)
        let key = FleetDeviceKey.mint()
        let service = FleetService(store: store, keys: { [key] })
        self.service = service
        return (store, key, try service.start(port: nil))
    }

    func testAConnectingClientIsHandedTheLiveFleet() throws {
        let (store, key, port) = try standUp()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        let arrived = expectation(description: "snapshot")
        var snapshot: FleetSnapshot?
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot(_, let fleet, .initial) = frame {
                snapshot = fleet
                arrived.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        wait(for: [arrived], timeout: 10)

        XCTAssertEqual(snapshot?.projects.first?.name, "alpha")
        XCTAssertEqual(snapshot?.projects.first?.sessions.map(\.id), [session.id])
    }

    func testAMutationAfterAttachingReachesTheClient() throws {
        let (store, key, port) = try standUp()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        let renamed = expectation(description: "rename reached the client")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .event(_, .renamed(session.id, "elsewhere", .user)) = frame {
                renamed.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)

        let attached = expectation(description: "attached")
        // Poll rather than sleep: `attachedDeviceCount` is the service's own published fact.
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.service?.attachedDeviceCount == 1 { attached.fulfill() }
            }
        }
        wait(for: [attached], timeout: 10)
        observer.invalidate()

        store.rename(session.id, to: "elsewhere")
        wait(for: [renamed], timeout: 10)
    }

    func testMarkingReadFromAClientClearsTheMarkOnTheMac() throws {
        let (store, key, port) = try standUp()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(b.id)
        store.markUnread(a.id)
        XCTAssertTrue(store.unreadIdle.contains(a.id))

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.markRead(id: a.id)) }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        wait(for: [acked], timeout: 10)

        // Unread is one fleet-wide fact, not a per-device one (§8): reading on the phone
        // clears the dot on the Mac, which is what the mark means.
        XCTAssertFalse(store.unreadIdle.contains(a.id))
    }

    func testACommandNamingASessionThatIsGoneIsRefusedNotIgnored() throws {
        let (_, key, port) = try standUp()
        let refused = expectation(description: "err")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.markRead(id: UUID())) }
            if case .err(_, "unknown_session") = frame { refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        wait(for: [refused], timeout: 10)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetService' in scope`.

- [ ] **Step 3: Add `markRead` to the store**

Beside `markUnread(_:)`:

```swift
    /// The counterpart to `markUnread`, and the store method the phone's `markRead` command
    /// lands on.
    ///
    /// Added here rather than special-cased in the replicator on purpose: anything the phone
    /// can do, the Mac's own UI should be able to do, and a command with no store method
    /// behind it is a feature that exists on one device only. Writes through `setUnread`, so
    /// `unreadIdle` keeps its single writer.
    func markRead(_ id: UUID) {
        setUnread(id, false)
        persist()
    }
```

- [ ] **Step 4: Write the service**

Create `Sources/FlightDeck/Fleet/FleetService.swift`:

```swift
import Combine
import FleetKit
import Foundation
import Network
import OSLog

/// Binds the fleet to the socket.
///
/// The only type that knows both a `SessionStore` and an `NWListener`, which is deliberate:
/// `FleetSocketServer` stays testable without a store, `SessionStore` stays testable without
/// a network, and everything that needs both is here where it can be read at once.
@MainActor
final class FleetService: ObservableObject {
    /// How many phones are watching right now. Published because the Mac shows it — a
    /// remotely-driveable machine that gives no sign of being attached to is the thing §11
    /// of the spec calls out as not-polish.
    @Published private(set) var attachedDeviceCount = 0

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let store: SessionStore
    private let keys: @MainActor () -> [FleetDeviceKey]
    private let server: FleetSocketServer
    private let replicator: FleetReplicator

    init(store: SessionStore, keys: @escaping @MainActor () -> [FleetDeviceKey]) {
        self.store = store
        self.keys = keys
        self.server = FleetSocketServer()
        self.replicator = FleetReplicator { [weak store] in
            guard let store else { return .empty }
            return FleetProjection.snapshot(of: store)
        }

        store.replicator = replicator
        replicator.onEvents = { [weak self] batch in
            for entry in batch {
                self?.server.broadcast(.event(seq: entry.seq, entry.event))
            }
        }
        server.onHello = { [weak self] _, lastSeq in
            guard let self else { return [] }
            switch self.replicator.resume(from: lastSeq) {
            case .replay(let events):
                return events.map { .event(seq: $0.seq, $0.event) }
            case .resnapshot(let reason):
                let current = self.replicator.snapshot()
                return [.snapshot(seq: current.seq, fleet: current.fleet, reason: reason)]
            }
        }
        server.onCommand = { [weak self] _, cid, command in
            self?.apply(command, cid: cid) ?? .err(cid: cid, code: "stopped")
        }
        server.onAttachedCountChanged = { [weak self] count in
            MainActor.assumeIsolated { self?.attachedDeviceCount = count }
        }
    }

    /// `port: nil` asks the OS for one. Plan 2's Bonjour advertisement publishes whatever
    /// comes back — no port is hard-coded anywhere, because a fixed port is a collision
    /// waiting for a second Mac app.
    @discardableResult
    func start(port: NWEndpoint.Port? = nil) throws -> NWEndpoint.Port {
        let bound = try server.start(keys: keys(), port: port)
        Self.logger.info("fleet listener bound to port \(bound.rawValue, privacy: .public)")
        return bound
    }

    func stop() {
        server.stop()
        attachedDeviceCount = 0
    }

    /// Restart the listener so a change to the paired-device list takes effect. Revoking a
    /// device is deleting its key, and a listener started with the old set would keep
    /// honouring it until the app quit.
    func reloadKeys(port: NWEndpoint.Port? = nil) throws {
        try start(port: port)
    }

    private func apply(_ command: FleetCommand, cid: Int) -> ServerFrame {
        switch command {
        case .markRead(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markRead(id)
        case .markUnread(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markUnread(id)
        }
        // `ack` means dispatched, not done. The observable effect arrives separately as the
        // northbound `session.unread` event this command's store call just recorded.
        return .ack(cid: cid)
    }
}
```

`sessionExists(_:)` is a one-line addition to `SessionStore` beside `status(for:)`:

```swift
    func sessionExists(_ id: UUID) -> Bool { locate(id) != nil }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS — the whole suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/FleetServiceTests.swift
git commit -m "feat: serve the live fleet to an attached client, and take its commands"
```

---

### Task 13: Documentation

The spine is invisible from the UI and will stay that way until Plan 2, so the only way the next person finds it is if it is written down. Three places, each with a different reader.

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `AGENTS.md` (layout table)
- Modify: `docs/FOLLOWUPS.md`

- [ ] **Step 1: Describe the subsystem in `docs/ARCHITECTURE.md`**

Add a section in the house voice covering: the two modules and why `FleetKit` is compiled for iOS (boundary enforcement); the event log and the drift assertion, with a pointer to the encapsulation spec; the single socket and why there is no HTTP tier; and TLS-PSK as the whole authorization story. Keep it to the shape of the neighbouring sections — mechanism and the failure each choice prevents, not an API listing.

- [ ] **Step 2: Add the new paths to `AGENTS.md`**

In the Layout table:

```markdown
| `Sources/FleetKit/` | Wire types, event fold and both socket halves. Swift 6, `Foundation`+`Network` only — compiled for iOS too, which is what enforces that. |
| `Sources/FlightDeck/Fleet/` | The desktop side: projection, replicator, and the service that binds the store to the socket. |
```

And under Commands:

```bash
./scripts/build-ios.sh          # compile-check FleetKit's iOS slice — run after touching Sources/FleetKit
```

- [ ] **Step 3: Record the follow-ups in `docs/FOLLOWUPS.md`**

Add a dated section, in the existing style, covering exactly three things:

1. **The drift assertion is temporary and must not be removed** until the `FleetState` encapsulation lands. Cross-reference the section already added on 2026-08-18 rather than repeating it.
2. **"Mark as Read" exists as a store method and a phone command, but has no Mac menu item.** The spec's rule is that anything the phone can do the Mac should too; `SessionCommands`' context menu offers only "Mark as Unread". Small, and deliberately not in this plan's scope.
3. **The listener restarts to pick up a key change** (`FleetService.reloadKeys`), which drops attached clients for the length of a reconnect. Acceptable because revocation is rare and a client reconnects on its own, but worth knowing before someone calls it on a timer.

- [ ] **Step 4: Verify nothing regressed and commit**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

```bash
git add docs/ARCHITECTURE.md AGENTS.md docs/FOLLOWUPS.md
git commit -m "docs: describe the fleet replication spine and what it defers"
```

---

## Done when

- `./scripts/test-unit.sh` passes, including `FleetServiceTests` — a real client over a real TLS-PSK WebSocket receives a snapshot of a live `SessionStore`, follows its mutations, and marks a session read.
- `./scripts/build-ios.sh` succeeds, proving `FleetKit` carries no macOS-only dependency.
- `rg -n 'unreadIdle\.(insert|remove|formUnion)' Sources/FlightDeck/SessionStore.swift` matches only the two lines inside `setUnread`.
- Nothing user-visible has changed. There is no pairing UI, no Bonjour, and no phone — that is Plan 2, `docs/superpowers/plans/2026-08-19-fleet-pairing-and-ios.md`.

## Not in this plan

- **Pairing, Bonjour and the phone** — `docs/superpowers/plans/2026-08-19-fleet-pairing-and-ios.md`.
  `FleetService` is built here and started by nothing; that plan is what gives it keys and a UI.
- **The `prompt.opened` / `prompt.closed` frames** the spec's §4 documents. They are in the
  protocol's design so the shape did not have to be invented twice (§9), and nothing in slice 1
  builds them — a client that never sees one is correct, not incomplete.
- **Timeline pagination.** Same reason: designed in §6, built in slice 1b.
