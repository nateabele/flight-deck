# Delegated Execution (Sub-project C) Implementation Plan — fanned out

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. This plan is built for **parallel tracks**. Task C0 runs alone. Tracks C1–C7 then run **concurrently**, each in its own git worktree with a file set no other track touches. C8 integrates them. Steps use checkbox (`- [ ]`) syntax.

**Goal:** an agent in any Flight Deck session runs `flightdeck run --on mini -- xcodebuild test …`. Its uncommitted working tree is synced to the host, the command runs there, and the agent sees streamed output and the real exit code. Artifacts and changed files come back. Services keep running with ports forwarded to the Mac, and runs that need the screen queue rather than collide.

**Architecture:**
- **Logic lives in HostKit wherever possible** (Foundation-only, `swift test` on macOS and Linux in seconds). This is what makes the tracks parallel and keeps most of them off the overloaded Xcode build.
- **One channel multiplexer** carries every byte stream (exec I/O, bundles, tars, port forwards) beside the JSON control frames on the existing host WebSocket.
- **On the host,** `HostServerCore` gains a request router that dispatches to `Workspace`, `Runner`, `ScreenLease` and `PortCheck`.
- **On the controller,** `DelegationService` (app) drives `SyncEngine`, `PortForwarder` and `HostLink` channels, and the `flightdeck` CLI reaches it over the control socket.

**Tech Stack:**
- Swift 6.3, HostKit SwiftPM (macOS + `swift:6.3-noble`), git ≥ 2.40 CLI on both ends.
- Network.framework (Mac), SwiftNIO (Linux hostd).
- IOKit power assertions and `CGSessionCopyCurrentDictionary` (macOS host).
- The `systemd-inhibit` CLI (Linux host).

**Spec:** `docs/superpowers/specs/2026-10-03-remote-hosts-delegation-design.md`, §4–§9 (sub-project C). Read §4 (sync), §5 (CLI), §6 (execution), §7 (preflight), §8 (config) and §9 (agent integration) before starting any track.

**Base:** branch `host-foundation` (sub-project A, merged or merging to master). Every track branches from the same commit: C0's head.

## Global Constraints

- HostKit stays "Foundation-only, Swift 6, with no Network.framework, Security or CryptoKit" and must pass `./scripts/test-hostkit.sh` on both platforms. Use git through `Process`, never libgit2.
- **Exit codes:**
  - a completed run exits with the remote command's code;
  - a run killed by signal `n` exits `128+n`;
  - a delegation failure exits **125**, with one stderr line starting `flightdeck:` that names the host and the next step;
  - a `wait` timeout exits **124**.
- **Preflight (§7) runs fully before any sync or remote work.** A failure releases everything reserved and changes nothing on either machine.
- **Sync:**
  - The snapshot uses a temporary `GIT_INDEX_FILE` and never touches the user's index, stash, reflog or branches.
  - The tree hash is verified on the host before anything runs.
  - Apply is `checkout --force --detach` + `clean -fd`, **never `-x`**.
  - LFS repos are refused.
  - K=5 snapshots per worktree. Result refs expire after fetch or 24 h. The pool holds 2 slots.
- **Runs:**
  - The command runs as `$SHELL -lc` in the checkout plus the CLI's relative subdirectory.
  - The environment is the host's own plus `--env` and recipe `env`. **The controller's environment is never sent.**
  - Cancel is SIGINT, then SIGTERM after 10 s, then SIGKILL after another 10 s, all to the process group.
  - Output is spooled at 64 MiB per run, dropping the oldest first with a marker line.
  - A run survives the controller disconnecting.
- **Services:**
  - Port notation is `L:R`, `N`, or `auto:R`. A CLI `--port` replaces the recipe entry with the same R.
  - Forwards bind `127.0.0.1` only.
  - Services stop when their tab closes, on `down`, or after `orphan_timeout`, which defaults to 30 min.
- **Screen:** one lease per host. macOS checks for a console user and an unlocked screen. Linux refuses `screen`.
- **Agent skill:** it is static. It never lists hosts or recipes; it tells the agent to run `flightdeck host ls` and `flightdeck recipe ls`. It must ship for **both** Claude and Codex.
- **Wire:** every new frame gets hand-rolled `t`-tag Codable plus pinned literal tests (HostWire style). New capabilities are `run`, `sync`, `service` and `screen`. Bump `ProtocolVersion` to **1.1**.
- **Commits:** lowercase, behavioral, imperative, with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Use TDD (RED shown first). Never weaken an assertion.
- **Hazards (AGENTS.md):**
  - Never launch app bundles or touch `/Applications`. Never `git stash`.
  - `./scripts/test-unit.sh` exits 0 even when tests fail, so always `rg -n "error:|failed \("`.
  - The machine runs at load average 200–400. **Tracks C1–C5 and C7 must not run `test-unit.sh`.** Only C6 and C8 build the app.
- **Parallel-track rule:** a track edits only the files its section lists. If it needs to change a C0 contract file, it stops and reports `NEEDS_CONTEXT` with the proposed change. The controller rules and broadcasts the change, and the track never edits the file itself.

## Review Focus

1. **The user keeps editing while a run is in flight.** The result patch three-way merges against the *current* tree, with conflict markers and no overwrite. (C2 test `testApplyAfterLocalEditsConflictsNotOverwrites`.)
2. **The laptop sleeps mid-run.** The run continues, and `logs`/`wait` resume from their offset with nothing lost or duplicated. (C3 `testReattachResumesFromOffset`; C8 e2e `testRunSurvivesControllerDrop`.)
3. **A requested local port is already taken.** Delegation fails before any sync, names the holder, suggests a free port, and holds nothing afterwards. (C5 `testHeldPortFailsBeforeSyncAndReleasesAll`.)
4. **Two agents both want the mini's screen.** The second queues with the holder named, and runs when the first ends, including when the first is cancelled. (C3 `testSecondScreenRunQueuesThenRunsAfterCancel`.)
5. **An ignored file the command needs wasn't sent.** The run fails with the `--include` hint, and only when the output names a path that exists locally and is ignored. (C6 `testMissingIgnoredFileHint`.)

---

## Dependency graph

```
C0 contract ──┬─ C1 mux ───────────┐
              ├─ C2 sync ──────────┤
              ├─ C3 runner/lease ──┤
              ├─ C4 config/shims ──┼─ C8 integration ─ final review
              ├─ C5 preflight/ports┤
              ├─ C6 CLI+service ───┤
              └─ C7 agent skill ───┘
```

The C1–C7 file sets are disjoint. Each track tests against C0's protocols with in-package fakes. Only C8 wires the real implementations together.

---

### Task C0: Freeze the contract (runs alone, ~45 min)

**Owns:**
- Create in `Packages/HostKit/Sources/HostKit/Delegation/`: `DelegationWire.swift`, `ChannelProtocols.swift`, `SyncTypes.swift`, `RunTypes.swift`, `ServiceTypes.swift`, `DelegateConfigTypes.swift`.
- Modify `HostWire.swift`, but only to add cases that forward to `DelegationWire`, plus the 1.1 bump and the new capabilities.
- Create `Sources/FleetKit/DelegationControlWire.swift`, for the CLI ↔ app control-socket requests.
- Create `Packages/HostKit/Tests/HostKitTests/DelegationWireTests.swift`.

**Produces (every later track consumes these; signatures are binding once C0 merges):**

```swift
// Channels (C1 implements; everyone else consumes)
public typealias ChannelID = UInt32
public protocol ByteChannel: AnyObject, Sendable {
    var id: ChannelID { get }
    func write(_ data: Data) async throws          // suspends on missing credit
    func read() async throws -> Data?              // nil = EOF
    func finish() async                            // half-close (EOF)
    func cancel()                                  // abrupt close, both ways
}
public protocol ChannelOpening: Sendable { func open() async throws -> any ByteChannel }
// Binary WebSocket frame layout: [u32 BE channel][u8 kind][payload]; kind 0 data, 1 credit(u32 BE bytes), 2 eof, 3 close.
// Initial credit 256 KiB per channel per direction.

// Sync (C2)
public struct SnapshotRef: Codable, Sendable, Equatable { public let repoRoot: String; public let wtKey: String
    public let worktreeName: String; public let commit: String; public let tree: String }
public protocol SnapshotMaking: Sendable { func snapshot(worktree: URL, include: [String]) throws -> SnapshotRef }
public protocol BundleMaking: Sendable { func bundle(worktree: URL, snapshot: SnapshotRef, haves: [String]) throws -> URL }
public protocol WorkspaceStore: Sendable {
    func tips(controller: UUID, repoRoot: String, wtKey: String) throws -> [String]
    func receive(controller: UUID, bundle: URL, ref: SnapshotRef) throws
    func checkout(controller: UUID, ref: SnapshotRef, pin: Bool) throws -> CheckoutLease   // verifies tree
    func resultCommit(lease: CheckoutLease, runID: String) throws -> String?               // nil = nothing changed
    func resultBundle(controller: UUID, repoRoot: String, runID: String) throws -> URL?
    func artifacts(lease: CheckoutLease, globs: [String]) throws -> URL?                   // tar
}
public struct CheckoutLease: Sendable, Equatable { public let path: URL; public let slot: Int; public let ref: SnapshotRef }

// Runs (C3)
public struct RunSpec: Codable, Sendable, Equatable { public var command: String; public var subdir: String
    public var env: [String: String]; public var pty: Bool; public var screen: Bool; public var service: Bool
    public var downCommand: String?; public var ports: [PortMapping] }
public enum RunEvent: Codable, Sendable, Equatable { case queued(position: Int, holder: String?)
    case started(runID: String); case output(stream: OutputStream, offset: Int64, data: Data)
    case exited(RunExit); case serviceDied(RunExit) }
public enum OutputStream: String, Codable, Sendable { case stdout, stderr, pty }
public enum RunExit: Codable, Sendable, Equatable { case code(Int32); case signal(Int32)
    public var cliStatus: Int32 { get } }     // code → code, signal n → 128+n
public protocol RunControlling: Sendable {
    func start(_ spec: RunSpec, in lease: CheckoutLease, owner: String) async throws -> String   // runID
    func events(runID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error>
    func signal(runID: String, _ sig: Int32) throws
    func cancel(runID: String)              // INT → 10s TERM → 10s KILL
}

// Services / ports (C5)
public struct PortMapping: Codable, Sendable, Equatable { public enum Local: Codable, Sendable, Equatable { case fixed(UInt16), auto }
    public let local: Local; public let remote: UInt16
    public static func parse(_ s: String) throws -> PortMapping }      // "5432", "15432:5432", "auto:5432"
public enum PortHolder: Codable, Sendable, Equatable { case free; case process(name: String, pid: Int32)
    case container(name: String); case flightDeck(session: String); case unknown }

// Config (C4)
public struct DelegateConfig: Sendable, Equatable { public var defaultHost: String?; public var include: [String]
    public var recipes: [String: Recipe]; public var routes: [Route] }
public struct Recipe: Codable, Sendable, Equatable { public var host: String?; public var run: String; public var down: String?
    public var screen = false; public var long = false; public var service = false; public var restartOnSync = false
    public var fetch: [String] = []; public var ports: [String] = []; public var env: [String: String] = [:]
    public var apply: ApplyMode = .review; public var pool: Int? }
public enum ApplyMode: String, Codable, Sendable { case review, auto }
public struct Route: Sendable, Equatable { public let match: String; public let recipe: String }

// New HostRequest cases (wire, in DelegationWire): sync.tips, sync.push(channel), run.start, run.attach(offset),
// run.signal, run.cancel, run.result(channel), run.artifacts(globs, channel), port.check, port.open(service, remote, channel),
// service.down, screen.status. New HostServerFrame: event(runID, RunEvent).
```

The control-socket wire lives in FleetKit (`DelegationControlWire.swift`). It has `FleetRequest` cases `delegate.run`, `delegate.exec`, `delegate.up/down/restart/sync`, `delegate.ps`, `delegate.wait/logs/stop`, `delegate.diff/apply`, `recipe.ls/add/check` and `host.info` (which already exists). Streamed output reaches the CLI as `ServerFrame.delegateOutput(cid, stream, data)` and `.delegateExit(cid, status)`. **All `FleetRequest` and `ServerFrame` switch arms land in C0, with handlers stubbed to `err(code:"not_implemented")`.** That keeps C6 and C8 from fighting over exhaustive switches. Run `build-ios.sh` and `test-ios.sh` at the end of C0.

- [ ] **Step 1:** write `DelegationWireTests` first. Cover the pinned literal shapes for every new request, reply and event, plus `RunExit.cliStatus` (`code(3)`→3, `signal(9)`→137) and `PortMapping.parse` (valid inputs, and rejecting `0`, `70000`, `a:b` and `auto:auto`). RED.
- [ ] **Step 2:** implement the types and codecs. Bump to 1.1 and update every pinned hello literal. `./scripts/test-hostkit.sh` goes GREEN.
- [ ] **Step 3:** add the FleetKit control wire and the stubbed handler arms in `FleetService`, `CLIRunner`, `ControlScope` (delegate requests write state: allowed for `.session` callers and humans) and `FleetConnector`. Run `build-ios.sh`, `test-ios.sh` and one `test-unit.sh`.
- [ ] **Step 4:** commit — `feat: freeze the delegated-execution contract`.

---

### Track C1: Channel multiplexer

**Owns:**
- `Packages/HostKit/Sources/HostKit/Delegation/ChannelMux.swift`
- `Tests/HostKitTests/ChannelMuxTests.swift`
- `Packages/HostDaemonLinux/Sources/HostDaemonLinux/BinaryFrames.swift`
- `Sources/HostDaemon/DarwinBinaryFrames.swift`
- `Sources/FlightDeck/Hosts/HostLinkChannels.swift`

**Builds:** `ChannelMux(send: @Sendable (Data) -> Void)`, which:
- implements `ChannelOpening`;
- has `receive(binary:)` and `accept() -> AsyncStream<ByteChannel>` for peer-opened channels;
- uses odd ids for the controller and even ids for the host, so the two sides never collide;
- does credit-based flow control, sending a credit frame once half the window has been consumed.

The Linux and Darwin transports forward binary WebSocket frames to the mux, and `HostLink` exposes `openChannel()`. **HostServerCore and HostLink request routing are out of scope** (C8 does that).

**Tests (HostKit, two muxes cross-wired in memory):**
- `testRoundTripLargeStream` (64 MiB, checksum)
- `testWriterSuspendsWithoutCredit`
- `testEOFIsHalfClose`
- `testCancelClosesBothWays`
- `testInterleavedChannelsDoNotBlockEachOther`
- `testMalformedFrameClosesOnlyThatChannel`
- `testOddEvenIDsNeverCollide`

Transport glue: a Linux unit test frames bytes through NIO `EmbeddedChannel`; a Darwin test does a loopback round trip over `DarwinHostServer` and a raw `NWConnection` binary message. That is one focused `FD_TEST_FILTER` run, the only app build in C1.

---

### Track C2: Sync engine

**Owns:**
- `Packages/HostKit/Sources/HostKit/Delegation/{GitRunner,Snapshotter,BundleMaker,Workspace,ResultApplier}.swift`
- `Tests/HostKitTests/{Snapshotter,Workspace,ResultApplier}Tests.swift`

**Builds:**
- `GitRunner`: runs `git` with an explicit env, a timeout and captured stderr.
- `Snapshotter` (§4.2):
  - temp index seeded from `HEAD`, then `add -A`, then `add -f` for the includes;
  - `write-tree`, then `commit-tree -p HEAD`;
  - `refs/flightdeck/snapshots/<host>/<n>`, trimmed to K;
  - recursive submodules;
  - LFS detection that throws `.lfsUnsupported`.
- `BundleMaker` (§4.3).
- `Workspace: WorkspaceStore` (§4.1, §4.4–4.7):
  - store path keyed by controller slot and oldest root commit;
  - `git worktree` pool slots with locks and a 2-slot cap;
  - same-snapshot sharing and pinning;
  - apply and tree verification;
  - result commit in a temp index; artifacts tar with a tracked-path refusal;
  - gc and expiry.
- `ResultApplier` (controller side): fetches the result bundle and three-way merges into the current worktree with the snapshot as the base, so the user's concurrent edits produce conflict markers. It returns `.clean`, `.conflicts([path])` or `.nothing`.

**Tests (real temp repos, macOS + Linux):**
- `testSnapshotLeavesIndexStashReflogUntouched`
- `testIncludeForceAddsIgnored`
- `testUntrackedIncludedIgnoredExcluded`
- `testBundleIsDeltaOnSharedBase`
- `testBundleAfterRebase`
- `testTreeMismatchRejects`
- `testIgnoredBuildOutputSurvivesApply`
- `testDeletedFileRemovedOnApply`
- `testMtimesOfUnchangedFilesPreserved`
- `testSubmoduleRoundTrip`
- `testLFSRefused`
- `testPoolLocksAndQueues`
- `testSameSnapshotSharesSlot`
- `testResultCommitNothingChanged`
- `testApplyCleanPatch`
- `testApplyAfterLocalEditsConflictsNotOverwrites` (Review Focus 1)
- `testArtifactGlobOnTrackedPathRefused`
- `testExpiryAndGC`

---

### Track C3: Runner, spool, screen lease, power

**Owns:**
- `Packages/HostKit/Sources/HostKit/Delegation/{Runner,OutputSpool,ScreenLease,PowerAssertion,ConsoleSession}.swift`
- the matching tests
- (`ScreenLease.swift` here replaces nothing; the A-plan name was reserved and never built)

**Builds:**
- `Runner: RunControlling`:
  - `posix_spawn` in a new process group running `$SHELL -lc`;
  - pipes, or a pty (`openpty`) when `pty`;
  - env = host env + spec env;
  - cwd = lease path + subdir, refusing `..` escapes;
  - signal escalation via an injectable clock;
  - exit mapping.
- `OutputSpool`:
  - one file per stream under `runs/<id>/`, with offsets;
  - a 64 MiB cap that drops the oldest output and writes a marker;
  - replay from an offset.
- `ScreenLease`: a FIFO with holder labels; a cancelled holder releases.
- `PowerAssertion`: macOS uses `IOPMAssertionCreateWithName` (idle-sleep for every run, display for screen runs) behind `#if os(macOS)`; Linux uses a `systemd-inhibit --what=sleep` child when present.
- `ConsoleSession` (macOS): console user and lock state from `CGSessionCopyCurrentDictionary` (`CGSSessionScreenIsLocked`); Linux returns `.unsupported`. HostKit must stay Foundation-only, so put the CoreGraphics/IOKit pieces in a separate `HostKitDarwin` target in the same package and inject them into Runner.

**Tests:**
- `testExitCodeAndSignalMapping`
- `testCancelEscalatesIntToTermToKill` (a child that traps INT and TERM)
- `testProcessGroupKilledIncludingGrandchildren`
- `testEnvIsHostPlusSpecOnly`
- `testSubdirEscapeRefused`
- `testPtyGetsTTY`
- `testSpoolCapDropsOldestWithMarker`
- `testReattachResumesFromOffset` (Review Focus 2)
- `testRunSurvivesNoSubscribers`
- `testSecondScreenRunQueuesThenRunsAfterCancel` (Review Focus 4)
- `testLinuxRefusesScreen`

---

### Track C4: Config, recipes, routing shims

**Owns:**
- `Packages/HostKit/Sources/HostKit/Delegation/{DelegateConfigParser,RecipeWriter,RouteMatcher}.swift`
- `Sources/FlightDeck/Delegation/RouteShims.swift`
- `Resources/RouteShim/flightdeck-route-shim.sh`
- the matching tests

**Builds:**
- **TOML parsing.** Foundation has no TOML, so write a minimal parser for the subset §8 uses: top-level keys, `[recipe.<name>]` tables, `[[route]]` arrays of tables, strings, bools, ints, and arrays of strings/ints. Unknown keys produce a warning, not an error.
- `DelegateConfig.validate()`: an unknown host is a warning; a service without ports is OK; `ports` must parse; a `screen` recipe whose host is Linux is an error at preflight, not at parse time.
- `RecipeWriter.add(...)` edits the file in place and keeps existing content and comments (append a table, or replace its own table only).
- `RouteMatcher`: glob over the joined argv.
- `RouteShims` (app): builds a per-session shim directory at the front of `PATH`, one symlink per routed command name pointing at the bundled shim script. The script runs `flightdeck route-exec <argv0> -- "$@"`; the CLI matches, then either delegates or execs the real binary found on `PATH` without the shim directory. `FLIGHTDECK_NO_ROUTE=1` bypasses it. The directory is rebuilt when `delegate.toml` changes (an FSEvents watcher on the project's `.flightdeck/`).

**Tests:** a parser fixture for the full §8 example, one per error case, comment preservation, route globbing, and a shim script test run with bash in a temp directory (bypass, fall-through, match). Only the RouteShims tests need the app build, so batch them into one `FD_TEST_FILTER` run.

---

### Track C5: Preflight and port forwarding

**Owns:**
- `Packages/HostKit/Sources/HostKit/Delegation/{PortCheck,Preflight}.swift`
- `Sources/FlightDeck/Delegation/{PortForwarder,LocalPortHolder}.swift`
- the matching tests

**Builds:**
- `PortCheck` (host): bind-probe the remote port; name the holder via `lsof -nP -iTCP:<p> -sTCP:LISTEN` (macOS) or `/proc/net/tcp` + `/proc/*/fd` (Linux); Docker via `docker ps --format` port mapping.
- `Preflight`: a pure ordered pipeline over injected checkers, exactly in §7's order, that returns `Reservation` or throws `DelegationError` with the 125 message. The reservation's `release()` is idempotent.
- `PortForwarder` (app):
  - **binds and holds** `127.0.0.1:L` listeners at preflight;
  - `auto` picks a free port;
  - each accepted connection is handed to an injected `ChannelOpening`;
  - stops on release.
- `LocalPortHolder`: holder names from Flight Deck's own forwards first, then `lsof`, plus a suggested free port.

**Tests:**
- `testPreflightOrderIsExact` (recording fakes)
- `testHeldPortFailsBeforeSyncAndReleasesAll` (Review Focus 3)
- `testAutoPicksFreePort`
- `testCLIPortOverridesRecipeSameRemote`
- `testRemotePortHeldByContainerNamed` (fake `docker` on `PATH`)
- `testForwarderPipesBytesBothWays` (an in-memory `ChannelOpening`)
- `testReleaseIsIdempotent`

---

### Track C6: CLI and DelegationService (app)

**Owns:**
- `Sources/FlightDeck/Delegation/{DelegationService,RunRegistry,MissingFileHint}.swift`
- `Sources/FlightDeckCLI/Delegate*.swift`
- `Sources/FlightDeckTool/main.swift` (usage lines only)
- `Tests/FlightDeckTests/Delegation*Tests.swift`

**Builds:**
- `DelegationService` (`@MainActor`). It owns, per session, its runs and services, and `RunRegistry` persists to `delegation.json` so services survive an app relaunch. It implements every C0 control-socket handler:
  - **run:** preflight → sync → start → stream → result and artifacts;
  - **exec:** no sync;
  - **up / down / restart / sync, ps, wait (with timeout → 124), logs, stop, diff, apply, recipe ls / add / check.**
- It talks to hosts **only through protocols**: `HostLinking` with `request`, `openChannel` and `events`, plus `SnapshotMaking`, `BundleMaking`, `Preflighting` and `ResultApplying`. In C6 these are in-memory fakes; C8 swaps in the real ones.
- Session close calls `down` on the session's services.
- `MissingFileHint`: scans a failed run's stderr tail for paths that exist locally, are ignored and weren't sent, and then emits the `--include` hint.
- CLI parsing and printing for every §5 row. `run` streams stdout and stderr straight to its own fds and exits with `RunExit.cliStatus`. A `long` recipe or `--detach` prints the run id plus `flightdeck wait <id>` and exits 0.

**Tests:**
- `CLIArgumentsTests` additions, one per verb and flag.
- `DelegationServiceTests` against fakes:
  - `testRunStreamsAndExitsWithRemoteCode`
  - `testSignalExitIs128PlusN`
  - `testDelegationFailureIs125WithOneLine`
  - `testLongRecipeDetaches`
  - `testWaitTimeoutIs124RunContinues`
  - `testTabCloseDownsServices`
  - `testMissingIgnoredFileHint` (Review Focus 5)
  - `testAutoApplyFallsBackToReviewOnConflict`
  - `testOnlyOwningSessionSeesItsRuns` (`FLIGHT_DECK_CALLER` scoping)

Run the full `test-unit.sh` once at the end.

---

### Track C7: Agent skill and live probes

**Owns:**
- `Resources/ClaudePlugin/skills/delegate/SKILL.md`
- the Codex delivery path chosen by probe P2 (the bundled skills directory, or `developer_instructions` in `CodexAdapter`'s launch config; files under `Sources/FlightDeck/Agents/Codex/` limited to that one setting)
- `Sources/FlightDeck/Agents/PluginReload.swift` (only if P1 says a reload is needed)
- `docs/DELEGATION-PROBES.md`

**Builds:**
- **The skill text (§9).** It is static and short: when to delegate; `flightdeck host ls`, `host info` and `recipe ls`; `run` and its flags; `exec` for inspecting; how to read 125 hints; `wait` for long runs; `diff` and `apply`; `up`/`down` with ports; and `recipe add`.
- **P1:** does a skill added under `--plugin-dir` hot-reload in Claude Code (current installed version)? Probe it with a throwaway `claude -p` session per the `probe-claude-clear-child-session` memory: clear `CLAUDE_CODE_CHILD_SESSION`. If it doesn't hot-reload, `PluginReload` injects `/reload-plugins` through the existing gated `inject` path when the composer is idle after an app update.
- **P2:** does current codex-cli load SKILL.md skills, and from where? Probe both installs (memory: two codex installs). Wire whichever channel works.
- Record P1, P2, the versions and the exact commands in `docs/DELEGATION-PROBES.md`.
- **P3 and P4** (XCTest from a login item; the lock state) need a second Mac. Write the procedure into that doc for the maintainer.

---

### Task C8: Integration (after C1–C7 merge)

**Owns:** the wiring files only.
- **Host side:** a `HostServerCore` request router plus `DelegationHost`, composing `Workspace`, `Runner`, `ScreenLease`, `PortCheck` and the mux in both hostds.
- **Controller side:** the real `HostLinking` adapter over `HostLink` and `ChannelMux`.
- `DelegationService`'s real dependencies, and `FlightDeckApp` construction.
- The `RouteShims` PATH injection in `SessionStore.launchEnvironment`.

**Tests (real processes, no GUI):**
- **Loopback** (`DelegationLoopbackTests`): an in-process `DarwinHostServer` plus a real `DelegationService` over a real TLS link and temp repos, with stub `xcodebuild`/`docker` scripts on `PATH`:
  - `testRunEndToEnd` (sync, run, output, exit code)
  - `testResultPatchComesBack`
  - `testArtifactsComeBack`
  - `testServiceForwardsPort` (a stub TCP echo service)
  - `testRunSurvivesControllerDrop` (Review Focus 2)
  - `testScreenQueueAcrossTwoSessions`
  - `testPreflightFailureTouchesNothingRemote`
- **Linux interop:** `scripts/test-hostd-linux-interop.sh run`, a new mode that runs a delegated `echo` and a `git status` in a synced checkout on the container hostd.
- **Docs:** ARCHITECTURE "Delegated execution", BUILD (new scripts and modes), FOLLOWUPS (P3/P4 manual, anything parked), HANDOFF.

---

## Execution protocol for the controller

1. Run C0 alone on branch `delegation` from master. Review, merge into `delegation`.
2. Create 7 worktrees from `delegation`'s head (`git worktree add .claude/worktrees/c<N> -b delegation-c<N>`), each with the vendor-artifact symlinks. Dispatch C1–C7 **in one message**, each with `isolation` handled by its own worktree path.
3. Review each track as it lands. Merge it into `delegation` **as soon as it is clean** (`git merge --no-ff`). The file sets are disjoint, so conflicts mean a track broke the rule: reject it.
4. Once all 7 are merged, dispatch C8 on `delegation`. Then the final review, one fix wave, and the merge to master.
5. **Load management:** C1–C5 and C7 use `swift test` only (plus one focused app build for C1/C4 glue). C6 is the only full-suite track until C8. If the load average exceeds 500, hold C6's full-suite run until another track finishes.
