# `flightdeck` CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `flightdeck`, a CLI that reads and drives the running Flight Deck in real time,
using the phone's exact wire protocol over a local unix socket.

**Architecture:** FleetKit gains a newline-delimited-JSON transport (`FleetLineFramer`) and a
*local mode* for `FleetSocketServer` / `FleetClient`. `FleetService` runs a second
`FleetSocketServer` instance in local mode, wired to the same `onHello`/`onCommand`/`onRequest`
closures as the phone's, with a `ControlScope` check in front. Tabs get
`FLIGHT_DECK_SESSION_ID` / `FLIGHT_DECK_CONTROL_SOCKET` / `FLIGHT_DECK_CALLER`. The CLI is a
thin `main.swift` over a testable core (`Sources/FlightDeckCLI`) that is compiled into both the
tool and the unit-test bundle.

**Tech Stack:** Swift (FleetKit Swift 6, app and CLI Swift 5), Network.framework
(`NWListener`/`NWConnection` over `.unix(path:)`, `NWProtocolFramer`), CryptoKit (HMAC),
XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-24-flightdeck-cli-design.md`. Read it first: it holds
the reasons, and this plan holds the steps.

## Global Constraints

- Work in a git worktree (`superpowers:using-git-worktrees`). Symlink `vendor/*-artifacts` into
  it before building (memory: "Worktree setup and merging"). Do **not** commit those symlinks,
  and check `git diff master -- vendor` before merging.
- Use built-in `Edit`/`Write` inside the worktree. **Never qartez mutators**: in a worktree they
  write to the main checkout.
- FleetKit is `SWIFT_VERSION 6.0` and imports only Foundation, Network, Security and CryptoKit.
  It is also compiled for iOS. **Every task that touches `Sources/FleetKit` ends with
  `./scripts/build-ios.sh`.**
- Leave the app's `SWIFT_VERSION: "5.0"` alone.
- Test loop: `./scripts/test-unit.sh`. It **always runs the full suite (~8 min)** and ignores
  `-only-testing:`. Run it in the **foreground**; a backgrounded run dies with the agent's turn.
  Never run `./scripts/smoke.sh`.
- **Never launch any `.app` from `DerivedData/`** (AGENTS.md rule 2). Running the `flightdeck`
  binary directly is fine; it is not the app.
- TDD: confirm each new test **fails against the unfixed code** before you implement. Never
  weaken an assertion.
- House style: comments explain *why* and name the failure they prevent.
- Commits: lowercase, behavioral, imperative (`feat: …`, `fix: …`, `test: …`, `docs: …`). End
  each with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
  Stage explicit paths only. The checkout is shared, so no `git add -A` and no `git stash`.
- Wire names: the socket is `<state dir>/control.sock` (`control-debug.sock` in DEBUG). The
  environment variables are `FLIGHT_DECK_SESSION_ID`, `FLIGHT_DECK_CONTROL_SOCKET` and
  `FLIGHT_DECK_CALLER`. The defaults keys are `FlightDeckControlSocket` (Bool, default true),
  `FlightDeckAgentControlScope` (`full`|`ownSession`|`readOnly`, default `full`) and
  `FlightDeckControlSecret` (Data).
- CLI exit codes: `0` ok · `1` refused by the app / timed out · `2` usage or resolution error ·
  `69` cannot connect.

## Review Focus

1. **`tail` across an app restart or release swap.** The socket file vanishes and then
   reappears. `tail` must reconnect and resume from its last printed seq, not exit or
   duplicate events. Test: Task 9, `testTailReconnectsAndResumesFromLastSeq`.
2. **Debug and Release running at once, or two instances on one state dir.** A second bind must
   never unlink a live socket. Tests: Task 3, `testStartLocalRefusesALiveSocket`; Task 5, the
   per-build filename.
3. **Detached tabs surviving an app relaunch still carry their old `FLIGHT_DECK_CALLER`.**
   Scoping must still work, and a forged or garbled token must fail closed. Test: Task 5,
   `testTokenIsStableAcrossSecretReloadAndRejectsTampering`, and Task 6's fail-closed cases.
4. **Session resolution with duplicate titles, `self` outside Flight Deck, and short prefixes.**
   Test: Task 8, the resolver cases.
5. **`flightdeck new` must print the new tab's id**, and a concurrent `sessionAdded` in a
   different project must not be misattributed. Test: Task 9, `testNewPrintsTheSessionAddedInItsProject`.

---

### Task 1: FleetKit line transport

**Files:**
- Create: `Sources/FleetKit/FleetLineFramer.swift`
- Modify: `Sources/FleetKit/FleetSocket.swift` (add `lineParameters`)
- Test: `Tests/FlightDeckTests/FleetLineFramerTests.swift`

**Interfaces:**
- Produces: `FleetLineFramer` (internal; `static let definition`, `static let maximumLineLength`)
  and `FleetSocket.lineParameters(maximumMessageSize: Int = TimelineLimits.maximumMessageSize) -> NWParameters`
  (internal static). `FleetSocket.send`/`receive` are unchanged. A probe on 2026-09-24 confirmed
  that the WebSocket metadata `send` attaches is ignored by a framer stack, and that
  `receiveMessage` delivers one whole line per call.

- [ ] **Step 1: Write the failing test**

```swift
import Network
import XCTest
@testable import FleetKit

/// The local transport's framing, over a real unix socket. A fake would prove nothing about
/// the one thing that matters here: that Network.framework hands `receiveMessage` whole lines.
final class FleetLineFramerTests: XCTestCase {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var path = ""

    override func setUp() {
        super.setUp()
        // Short on purpose: sockaddr_un holds 103 bytes and NSTemporaryDirectory is long.
        path = "/tmp/fdlf-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        connections.forEach { $0.cancel() }
        listener?.cancel()
        unlink(path)
        super.tearDown()
    }

    /// Stands up a listener; `onMessage` sees each server-side message, `onEnd` each end.
    private func serve(maximum: Int = TimelineLimits.maximumMessageSize,
                       onMessage: @escaping (String) -> Void,
                       onEnd: @escaping (Error?) -> Void = { _ in }) throws -> NWConnection {
        let parameters = FleetSocket.lineParameters(maximumMessageSize: maximum)
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.connections.append(connection)
            connection.start(queue: .main)
            func loop() {
                connection.receiveMessage { data, _, _, error in
                    if let error { return onEnd(error) }
                    if let data { onMessage(String(decoding: data, as: UTF8.self)) }
                    loop()
                }
            }
            loop()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        let client = NWConnection(to: .unix(path: path),
                                  using: FleetSocket.lineParameters(maximumMessageSize: maximum))
        connections.append(client)
        client.start(queue: .main)
        return client
    }

    private func send(_ text: String, _ connection: NWConnection) {
        connection.send(content: Data(text.utf8), isComplete: true, completion: .idempotent)
    }

    func testBackToBackSendsArriveAsSeparateMessages() throws {
        var got: [String] = []
        let three = expectation(description: "three")
        let client = try serve { got.append($0); if got.count == 3 { three.fulfill() } }
        send("one", client); send("two", client); send("three", client)
        wait(for: [three], timeout: 5)
        XCTAssertEqual(got, ["one", "two", "three"])
    }

    func testAFrameWhoseJSONCarriesAnEscapedNewlineSurvivesWhole() throws {
        // JSONEncoder escapes a newline inside a string as `\n` (two bytes), which is what
        // makes newline-delimited framing safe for these frames at all.
        let encoded = String(decoding: try JSONEncoder().encode(["text": "a\nb"]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\n"))
        let one = expectation(description: "one")
        var got: String?
        let client = try serve { got = $0; one.fulfill() }
        send(encoded, client)
        wait(for: [one], timeout: 5)
        XCTAssertEqual(got, encoded)
    }

    func testALineLongerThanTheCapFailsTheConnection() throws {
        // Without the cap, a peer that never sends a newline makes the reader buffer forever.
        let ended = expectation(description: "ended")
        let client = try serve(maximum: 64, onMessage: { _ in }, onEnd: { _ in ended.fulfill() })
        send(String(repeating: "z", count: 200), client)
        wait(for: [ended], timeout: 5)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Run `./scripts/test-unit.sh`. Expected: a build
  failure, because `lineParameters` is not defined.

- [ ] **Step 3: Implement `FleetLineFramer.swift`**

```swift
import Foundation
import Network

/// Newline-delimited framing for the local control socket.
///
/// **Not WebSocket, because WebSocket cannot run here.** `NWProtocolWebSocket` over a
/// `.unix(path:)` endpoint aborts the client with `ECONNABORTED` before `.ready` (probed
/// 2026-09-24; see the spec). The frames themselves are the same `ClientFrame`/`ServerFrame`
/// JSON the phone speaks. Only the framing differs, and `JSONEncoder` never emits a raw
/// newline (it escapes the ones inside strings), so a newline is an unambiguous terminator.
///
/// A framer rather than hand-reassembly so `FleetSocket.receive` keeps using `receiveMessage`
/// and delivering whole frames. Both transports share one send/receive path.
final class FleetLineFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: FleetLineFramer.self)
    static var label: String { "FleetLines" }

    /// Set once, before any listener or connection is built. `NWProtocolFramer` instantiates
    /// this type itself, so a per-instance value has nowhere to come from. The cap is the same
    /// one the WebSocket side uses (`TimelineLimits.maximumMessageSize`). Tests lower it to
    /// prove it fails closed.
    nonisolated(unsafe) static var maximumLineLength = TimelineLimits.maximumMessageSize

    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        let cap = Self.maximumLineLength
        while true {
            var lineLength: Int?
            var overflow = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: cap + 1) { buffer, _ in
                guard let buffer else { return 0 }
                if let newline = buffer.firstIndex(of: 0x0A) { lineLength = newline }
                else if buffer.count > cap { overflow = true }
                return 0
            }
            // Failing the connection is the whole defence: a peer that never sends a newline
            // would otherwise have the stack buffer its bytes without limit.
            if overflow { framer.markFailed(error: .posix(.EMSGSIZE)); return 0 }
            guard parsed, let length = lineLength else { return 0 }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            _ = framer.deliverInputNoCopy(length: length, message: message, isComplete: true)
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { _, _ in 1 }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
        framer.writeOutput(data: Data([0x0A]))
    }
}
```

Add this to `FleetSocket` (beside `webSocketParameters`):

```swift
    /// The local control socket's parameters: a plain stream plus `FleetLineFramer`. See that
    /// type for why this is not `webSocketParameters`. The caller sets `requiredLocalEndpoint`
    /// (listener) or dials `.unix(path:)` (client).
    static func lineParameters(
        maximumMessageSize: Int = TimelineLimits.maximumMessageSize
    ) -> NWParameters {
        FleetLineFramer.maximumLineLength = maximumMessageSize
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: FleetLineFramer.definition), at: 0
        )
        return parameters
    }
```

In the test's `tearDown`, reset `FleetLineFramer.maximumLineLength = TimelineLimits.maximumMessageSize`
so the 64-byte cap cannot leak into later tests.

- [ ] **Step 4: Run to verify it passes.** Run `./scripts/test-unit.sh`, then
  `./scripts/build-ios.sh`. Expected: all three new tests pass and the iOS build is clean.

- [ ] **Step 5: Commit** `Sources/FleetKit/FleetLineFramer.swift`, `Sources/FleetKit/FleetSocket.swift`
  and `Tests/FlightDeckTests/FleetLineFramerTests.swift`, with the message
  `feat: add a newline-delimited transport for the local fleet socket`.

---

### Task 2: FleetKit wire additions

**Files:**
- Modify: `Sources/FleetKit/Frames.swift` (`ClientFrame.hello`, plus a new `ServerFrame.correlationID`)
- Modify: `Sources/FleetKit/FleetSocketServer.swift` (`FleetAttachment`, and the two `.hello` patterns at ~689/700)
- Test: `Tests/FlightDeckTests/FleetFrameCodingTests.swift` (add cases)

**Interfaces:**
- Produces:
  - `ClientFrame.hello(lastSeq: Int, device: String?, caps: [String] = [], caller: String? = nil)`,
    with JSON key `caller`, omitted when nil.
  - `FleetAttachment.isLocal: Bool` and `FleetAttachment.caller: String?`. The init gains
    `isLocal: Bool = false, caller: String? = nil`.
  - `public extension ServerFrame { var correlationID: Int? }`: the `cid` for every
    `cid`-bearing case, nil for `.snapshot` and `.event`.

- [ ] **Step 1: Write the failing tests** (append to `FleetFrameCodingTests`, and reuse its existing `fields(of:)` helper):

```swift
    func testHelloCarriesCallerOnlyWhenPresent() throws {
        let with = try fields(of: ClientFrame.hello(lastSeq: 3, device: nil, caps: [], caller: "abc.def"))
        XCTAssertEqual(with["caller"] as? String, "abc.def")
        let without = try fields(of: ClientFrame.hello(lastSeq: 3, device: nil))
        XCTAssertNil(without["caller"], "a phone must keep putting the bytes it always did on the wire")
    }

    func testHelloWithoutCallerStillDecodes() throws {
        let frame = try JSONDecoder().decode(ClientFrame.self, from: Data(#"{"t":"hello","lastSeq":9}"#.utf8))
        XCTAssertEqual(frame, .hello(lastSeq: 9, device: nil, caps: [], caller: nil))
    }

    func testHelloCallerRoundTrips() throws {
        let frame = ClientFrame.hello(lastSeq: 1, device: "x", caps: ["logs"], caller: "tok")
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: JSONEncoder().encode(frame)), frame)
    }

    func testCorrelationIDIsTheCidForRepliesAndNilForState() {
        XCTAssertEqual(ServerFrame.ack(cid: 4).correlationID, 4)
        XCTAssertEqual(ServerFrame.err(cid: 5, code: "x").correlationID, 5)
        XCTAssertEqual(ServerFrame.session(cid: 6, UUID()).correlationID, 6)
        XCTAssertNil(ServerFrame.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial).correlationID)
        XCTAssertNil(ServerFrame.event(seq: 1, .projectRemoved(id: UUID())).correlationID)
    }
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure (extra argument `caller`, no member `correlationID`).

- [ ] **Step 3: Implement.** In `ClientFrame`:
  - Change the case to `case hello(lastSeq: Int, device: String?, caps: [String] = [], caller: String? = nil)`.
  - Add `caller` to `CodingKeys`.
  - Encode it with `try c.encodeIfPresent(caller, forKey: .caller)` and decode it with
    `try c.decodeIfPresent(String.self, forKey: .caller)`.
  - Add a comment in the house style: it is optional and omitted for the same reason `device`
    is, and it is only honoured by a local-mode server (Task 3).

  Add to `Frames.swift`:

```swift
public extension ServerFrame {
    /// The `cid` a reply answers, or nil for the two sequenced state frames. What `flightdeck raw`
    /// correlates on. A switch rather than a decode of `FleetSocket.CorrelatedFrame` so that a new
    /// reply case cannot compile until someone decides whether it is correlated.
    var correlationID: Int? {
        switch self {
        case .snapshot, .event: return nil
        case .ack(let cid), .err(let cid, _), .page(let cid, _), .newSessionOptions(let cid, _),
             .macEndpoints(let cid, _), .recentlyClosed(let cid, _), .conversations(let cid, _),
             .searchHits(let cid, _), .session(let cid, _), .phoneRequest(let cid, _):
            return cid
        }
    }
}
```

  (If the compiler reports another `ServerFrame` case, add it to the correct arm. The switch
  deliberately has no `default`.)

  In `FleetAttachment`, add `public let isLocal: Bool` and `public let caller: String?`. Extend
  the `init` with `isLocal: Bool = false, caller: String? = nil`, and give both fields doc
  comments. `caller` is *claimed*, like `name`, and is verified by the app, never trusted. In
  `FleetSocketServer.accept`, update the patterns to `case .hello(_, let device, let caps, _)`
  and `case .hello(let lastSeq, _, _, _)`.

- [ ] **Step 4: Run `./scripts/test-unit.sh` and then `./scripts/build-ios.sh`.** Expected: PASS and a clean build.

- [ ] **Step 5: Commit** these files with the message
  `feat: let a hello name its caller, and expose a reply's correlation id`.

---

### Task 3: `FleetSocketServer` local mode

**Files:**
- Modify: `Sources/FleetKit/FleetSocketServer.swift`
- Test: `Tests/FlightDeckTests/FleetLocalSocketTests.swift`

**Interfaces:**
- Consumes: `FleetSocket.lineParameters()` (Task 1) and `FleetAttachment.isLocal`/`caller` (Task 2).
- Produces:
  - `public func startLocal(path: String) async throws`.
  - `FleetSocketError` gains `case pathTooLong(Int)` and `case inUse`.
  - An instance started this way is in local mode: its attachments have `isLocal == true` and
    carry `caller`, `slot` is always nil, the socket file is `0600`, and `stop()` unlinks it.
    `start(keys:…)` and `startLocal` must not both be called on one instance; assert that
    with `precondition`.

- [ ] **Step 1: Write the failing tests**

```swift
import Network
import XCTest
@testable import FleetKit

@MainActor
final class FleetLocalSocketTests: XCTestCase {
    private var server: FleetSocketServer!
    private var path = ""

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
        path = "/tmp/fdls-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        unlink(path)
        super.tearDown()
    }

    /// A bare line-framed client: sends raw JSON lines, collects decoded server frames.
    private func dial(onFrame: @escaping (ServerFrame) -> Void) -> NWConnection {
        let connection = NWConnection(to: .unix(path: path), using: FleetSocket.lineParameters())
        FleetSocket.receive(ServerFrame.self, from: connection, onFrame: onFrame, onEnd: { _ in })
        connection.start(queue: .main)
        return connection
    }

    func testHelloIsAnsweredAndTheAttachmentIsLocalWithItsCaller() async throws {
        var seen: FleetAttachment?
        server.onHello = { attachment, _ in
            seen = attachment
            return [.snapshot(seq: 7, fleet: FleetSnapshot(), reason: .initial)]
        }
        try await server.startLocal(path: path)
        let arrived = expectation(description: "snapshot")
        let connection = dial { if case .snapshot(7, _, _) = $0 { arrived.fulfill() } }
        FleetSocket.send(ClientFrame.hello(lastSeq: 0, device: nil, caps: [], caller: "tok"), over: connection)
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(seen?.isLocal, true)
        XCTAssertEqual(seen?.caller, "tok")
        XCTAssertNil(seen?.slot)
        connection.cancel()
    }

    func testCommandsReachOnCommandAndAreAnsweredOnTheirCid() async throws {
        server.onHello = { _, _ in [] }
        server.onCommand = { _, cid, _, reply in reply(.ack(cid: cid)) }
        try await server.startLocal(path: path)
        let acked = expectation(description: "ack")
        let connection = dial { if case .ack(42) = $0 { acked.fulfill() } }
        FleetSocket.send(ClientFrame.hello(lastSeq: 0, device: nil), over: connection)
        FleetSocket.send(ClientFrame.cmd(cid: 42, .markRead(id: UUID())), over: connection)
        await fulfillment(of: [acked], timeout: 5)
        connection.cancel()
    }

    func testTheSocketFileIsOwnerOnly() async throws {
        try await server.startLocal(path: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testStopUnlinksTheSocket() async throws {
        try await server.startLocal(path: path)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testADeadSocketFileIsReplaced() async throws {
        // What a crash leaves behind: the file, with nothing listening on it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&address.sun_path.0, $0, 103) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try await server.startLocal(path: path)
    }

    func testStartLocalRefusesALiveSocket() async throws {
        // Debug and Release, or two instances on one state dir: the second must never take
        // over the first one's socket.
        try await server.startLocal(path: path)
        let second = FleetSocketServer()
        do {
            try await second.startLocal(path: path)
            XCTFail("bound over a live socket")
        } catch FleetSocketError.inUse {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the live socket must survive")
    }

    func testAPathTooLongForSockaddrIsRefusedByName() async {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        do {
            try await server.startLocal(path: long)
            XCTFail("bound a path sockaddr_un cannot hold")
        } catch FleetSocketError.pathTooLong(let length) {
            XCTAssertEqual(length, long.utf8.count)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure (`startLocal` is undefined).

- [ ] **Step 3: Implement.** Add to `FleetSocketServer`:
  - `private var localPath: String?`, and `private var isLocal: Bool { localPath != nil }`.
  - `private var callers: [UUID: String] = [:]`. Clear it wherever `names` is cleared: in
    `drop(_:)`, and in `cancelConnections()`.
  - `startLocal(path:)`, using the same `withCheckedThrowingContinuation` + `queue.async` shape
    that `start` uses (read `start`'s doc comment for why):

```swift
    /// Local mode: the control socket `flightdeck` talks to. The frames and every handler are
    /// the phone's, over `FleetSocket.lineParameters()` instead of TLS-PSK and WebSocket.
    ///
    /// **A separate instance from the phone's, never a second listener on it.** `stop()`, which
    /// every arm, expiry and revocation reaches through `FleetService.reloadKeys`, cancels every
    /// connection the instance holds. Sharing one would drop every `flightdeck tail` whenever a
    /// phone paired.
    ///
    /// Authorization is the file: `0600`, inside the user's `~/Library`. `NWConnection` exposes
    /// no socket descriptor to read `getpeereid` from, which is the argument
    /// `AnswerTriggerSocket` already makes.
    public func startLocal(path: String) async throws {
        // `sockaddr_un.sun_path` is 104 bytes including the NUL, and `bind` fails rather than
        // truncating. Refused here by name rather than surfacing as EINVAL.
        guard path.utf8.count <= 103 else { throw FleetSocketError.pathTooLong(path.utf8.count) }
        // Probe before unlinking. A crash leaves a dead file that must be cleared, but a live one
        // belongs to another instance on the same state directory, and unlinking it would
        // silently orphan every client that instance has.
        if FileManager.default.fileExists(atPath: path) {
            guard !Self.socketIsLive(path) else { throw FleetSocketError.inUse }
            unlink(path)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // Inside `queue`: `listener` and `localPath` are confined to it.
                precondition(listener == nil && localPath == nil, "one mode per FleetSocketServer")
                let parameters = FleetSocket.lineParameters()
                parameters.requiredLocalEndpoint = .unix(path: path)
                let listener: NWListener
                do { listener = try NWListener(using: parameters) }
                catch { return continuation.resume(throwing: error) }
                localPath = path
                self.listener = listener
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        chmod(path, 0o600)
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }
    }

    /// Whether something answers on `path`. A blocking `connect(2)` on a unix socket succeeds
    /// or fails immediately, with no network round trip to wait on.
    static func socketIsLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&address.sun_path.0, $0, 103) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
```

  - `stop()`: after `listener = nil`, add `if let localPath { unlink(localPath); self.localPath = nil }`.
  - `accept`: in the `hello` recording block, add `if self.isLocal { self.callers[id] = caller }`
    (bind `caller` from the new fourth pattern slot). Build the attachment with
    `slot: self.isLocal ? nil : self.slot(of: connection, id: id)`,
    `isLocal: self.isLocal` and `caller: self.isLocal ? self.callers[id] : nil`. A phone that
    sends `caller` gets it ignored. Update `attachments` the same way.
  - Add `case pathTooLong(Int)` and `case inUse` to `FleetSocketError`, each with a one-line
    comment giving its reason.

- [ ] **Step 4: Run `./scripts/test-unit.sh` and `./scripts/build-ios.sh`.** Expected: PASS
  (every existing Fleet socket test is unchanged).

- [ ] **Step 5: Commit** with the message `feat: run the fleet socket server over a local unix socket`.

---

### Task 4: `FleetClient` local transport

**Files:**
- Modify: `Sources/FleetKit/FleetClient.swift`
- Test: `Tests/FlightDeckTests/FleetLocalClientTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `public init(localCaller caller: String?, queue: DispatchQueue = .main)`.
  - `public func connect(toLocal path: String, lastSeq: Int)`.
  - A local client sends `hello(lastSeq:, device: nil, caps: [], caller:)` and uses line
    parameters. A paired client is unchanged. Everything else on `FleetClient`
    (`onFrame`, `onReady`, `onDisconnect`, `send(_:)`, `answer(_:)`, `disconnect()`) is shared.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FleetKit

@MainActor
final class FleetLocalClientTests: XCTestCase {
    func testALocalClientAttachesWithItsCallerAndGetsAnswers() async throws {
        let path = "/tmp/fdlc-\(UUID().uuidString.prefix(8)).sock"
        let server = FleetSocketServer()
        defer { server.stop() }
        var caller: String?
        server.onHello = { attachment, _ in
            caller = attachment.caller
            return [.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial)]
        }
        server.onRequest = { _, cid, _, reply in reply(.recentlyClosed(cid: cid, [])) }
        try await server.startLocal(path: path)

        let client = FleetClient(localCaller: "tok")
        defer { client.disconnect() }
        let answered = expectation(description: "reply")
        var cid = 0
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(FleetRequest.recentlyClosed) }
            if case .recentlyClosed(let got, _) = frame, got == cid { answered.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertEqual(caller, "tok")
    }

    func testConnectingToNothingDisconnectsRatherThanHanging() async {
        // What `flightdeck` turns into exit 69: the app is not running.
        let client = FleetClient(localCaller: nil)
        let ended = expectation(description: "disconnect")
        client.onDisconnect = { _ in ended.fulfill() }
        client.connect(toLocal: "/tmp/fd-nothing-\(UUID().uuidString.prefix(8)).sock", lastSeq: 0)
        await fulfillment(of: [ended], timeout: 5)
    }
}
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure.

- [ ] **Step 3: Implement.** Replace `private let key: FleetDeviceKey` with a private
  `enum Transport { case paired(FleetDeviceKey), local(caller: String?) }` and store
  `private let transport: Transport`. The existing `init(key:deviceName:caps:queue:)` sets
  `.paired(key)`, and the new init sets `.local(caller:)`, `deviceName = nil` and `caps = []`.
  Split `connect`'s first lines by transport, keeping everything from `self.connection = connection`
  onward shared:

```swift
    public func connect(to endpoint: NWEndpoint, lastSeq: Int) {
        guard case .paired(let key) = transport else {
            preconditionFailure("a local FleetClient dials connect(toLocal:)")
        }
        open(NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint),
            using: FleetSocket.webSocketParameters(FleetTLS.clientParameters(key: key))
        ), lastSeq: lastSeq)
    }

    /// The local control socket. Same frames, same callbacks; line framing instead of TLS-PSK
    /// and WebSocket (see `FleetLineFramer`), and a `caller` in the hello for the app's scope
    /// check.
    public func connect(toLocal path: String, lastSeq: Int) {
        guard case .local = transport else {
            preconditionFailure("a paired FleetClient dials connect(to:)")
        }
        open(NWConnection(to: .unix(path: path), using: FleetSocket.lineParameters()),
             lastSeq: lastSeq)
    }
```

  Move the rest of the old `connect` body into `private func open(_ connection: NWConnection, lastSeq: Int)`,
  starting at `disconnect()`. Build the hello as
  `.hello(lastSeq: lastSeq, device: deviceName, caps: caps, caller: callerForHello)`, where
  `callerForHello` is the `.local` caller and nil for `.paired`.

  **Check the no-listener case.** A unix connect to a missing path should reach `.failed` or
  `.waiting`. If the test shows `.waiting` (Network.framework waits for a path to become
  viable), then in the state handler treat `.waiting(let error)` as `end(error)` for local
  transport only. A missing socket file never becomes viable. Leave paired behaviour unchanged,
  because a phone *should* wait.

- [ ] **Step 4: Run `./scripts/test-unit.sh` and `./scripts/build-ios.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat: let FleetClient dial the local control socket`.

---

### Task 5: `ControlEnvironment` (socket location, caller tokens, tab variables)

**Files:**
- Create: `Sources/FlightDeck/Fleet/ControlEnvironment.swift`
- Test: `Tests/FlightDeckTests/ControlEnvironmentTests.swift`

**Interfaces:**
- Produces:

```swift
enum ControlEnvironment {
    static let enabledKey = "FlightDeckControlSocket"
    static let secretKey = "FlightDeckControlSecret"
    static let sessionVariable = "FLIGHT_DECK_SESSION_ID"
    static let socketVariable = "FLIGHT_DECK_CONTROL_SOCKET"
    static let callerVariable = "FLIGHT_DECK_CALLER"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool
    static func socketURL(stateDirectory: URL, debug: Bool) -> URL
    static func socketURL() -> URL          // the running build's
    static func secret(_ defaults: UserDefaults = .standard) -> Data
    static func token(for session: UUID, secret: Data) -> String
    static func session(forToken token: String, secret: Data) -> UUID?
    static func variables(for session: UUID, socket: URL, secret: Data) -> [String: String]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

final class ControlEnvironmentTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ControlEnvironmentTests.\(UUID())"

    override func setUp() { super.setUp(); defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    func testEnabledByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(ControlEnvironment.isEnabled(defaults))
        defaults.set(false, forKey: ControlEnvironment.enabledKey)
        XCTAssertFalse(ControlEnvironment.isEnabled(defaults))
    }

    func testDebugAndReleaseNeverShareASocketPath() {
        let dir = URL(fileURLWithPath: "/s")
        XCTAssertEqual(ControlEnvironment.socketURL(stateDirectory: dir, debug: false).path, "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.socketURL(stateDirectory: dir, debug: true).path, "/s/control-debug.sock")
    }

    func testTokenIsStableAcrossSecretReloadAndRejectsTampering() {
        let first = ControlEnvironment.secret(defaults)
        XCTAssertEqual(first.count, 32)
        // A relaunch reads the same secret back, which is what keeps a detached tab's token valid.
        XCTAssertEqual(ControlEnvironment.secret(defaults), first)
        let session = UUID()
        let token = ControlEnvironment.token(for: session, secret: first)
        XCTAssertEqual(ControlEnvironment.session(forToken: token, secret: first), session)
        // Another session's id with this session's MAC: the forgery the HMAC exists to stop.
        let mac = token.split(separator: ".").last!
        XCTAssertNil(ControlEnvironment.session(forToken: "\(UUID().uuidString).\(mac)", secret: first))
        XCTAssertNil(ControlEnvironment.session(forToken: "garbage", secret: first))
        XCTAssertNil(ControlEnvironment.session(forToken: token, secret: Data(repeating: 1, count: 32)))
    }

    func testVariablesNameTheSessionTheSocketAndTheCaller() {
        let session = UUID()
        let secret = ControlEnvironment.secret(defaults)
        let vars = ControlEnvironment.variables(
            for: session, socket: URL(fileURLWithPath: "/s/control.sock"), secret: secret)
        XCTAssertEqual(vars["FLIGHT_DECK_SESSION_ID"], session.uuidString)
        XCTAssertEqual(vars["FLIGHT_DECK_CONTROL_SOCKET"], "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.session(forToken: vars["FLIGHT_DECK_CALLER"]!, secret: secret), session)
    }
}
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure.

- [ ] **Step 3: Implement** `ControlEnvironment.swift` with `import CryptoKit`:
  - `isEnabled`: `defaults.object(forKey: enabledKey) as? Bool ?? true`.
  - `socketURL(stateDirectory:debug:)`: append `debug ? "control-debug.sock" : "control.sock"`.
  - `socketURL()`: `socketURL(stateDirectory: FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory(), debug: isDebugBuild)`,
    where `isDebugBuild` is `#if DEBUG true #else false #endif`. Reuse the directory expression
    `AppDelegate.answerTriggerURL()` uses.
  - `secret`: read `defaults.data(forKey: secretKey)`. If it is absent or not 32 bytes, generate
    one with `SecRandomCopyBytes`, `set` it and return it.
  - `token`: `"\(session.uuidString).\(hex(HMAC<SHA256>.authenticationCode(for: Data(session.uuidString.utf8), using: SymmetricKey(data: secret))))"`.
  - `session(forToken:)`: split on `.` into exactly 2 parts, then `UUID(uuidString:)`, then
    compare with `token(for:secret:)` in constant time (`HMAC.isValidAuthenticationCode` on the
    decoded bytes, or compare the full recomputed token string; either is fine at this trust
    level).
  - `variables`: the three keys.
  - Doc comments: why the token is derived and not regenerated (fd-abduco sessions outlive a
    relaunch), and that this is a guardrail, not a secret boundary (any same-user process can
    read another's environment).

- [ ] **Step 4: Run `./scripts/test-unit.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat: derive per-tab control identity and the control socket path`.

---

### Task 6: `ControlScope` policy

**Files:**
- Create: `Sources/FlightDeck/Fleet/ControlScope.swift`
- Test: `Tests/FlightDeckTests/ControlScopeTests.swift`

**Interfaces:**
- Produces:

```swift
enum ControlScopeLevel: String, CaseIterable, Identifiable { case full, ownSession, readOnly; var id: String { rawValue } }
enum ControlCaller: Equatable { case human, session(UUID), invalid }
enum ControlScope {
    static let defaultsKey = "FlightDeckAgentControlScope"
    static func level(_ defaults: UserDefaults = .standard) -> ControlScopeLevel   // default .full
    static func caller(token: String?, secret: Data) -> ControlCaller
    static func permits(_ command: FleetCommand, level: ControlScopeLevel, caller: ControlCaller) -> Bool
    static func permits(_ request: FleetRequest, level: ControlScopeLevel, caller: ControlCaller) -> Bool
}
```

- [ ] **Step 1: Write the failing tests** (the full matrix, table-driven):

```swift
import FleetKit
import XCTest
@testable import FlightDeck

final class ControlScopeTests: XCTestCase {
    private let me = UUID()
    private let other = UUID()
    private let project = UUID()

    private func commands(targeting id: UUID) -> [FleetCommand] {
        [.markRead(id: id), .markUnread(id: id), .closeSession(id: id),
         .renameSession(id: id, title: "t"), .prompt(id: id, token: UUID(), text: "x"),
         .answerPrompt(id: id, token: UUID(), call: "c", answer: .allow),
         .annotatePlan(id: id, token: UUID(), call: "c", text: "x", block: nil),
         .resolvePlan(id: id, token: UUID(), call: "c", approve: true, feedback: nil),
         .abortPrompt(id: id, token: UUID())]
    }
    private var fleetWide: [FleetCommand] {
        [.newSession(project: project), .reopenClosed(session: other),
         .setProjectCollapsed(id: project, isCollapsed: true)]
    }
    private let reads: [FleetRequest] = [.timeline(session: UUID(), anchor: .latest, limit: 5),
        .newSessionOptions(project: UUID()), .recentlyClosed, .macEndpoints, .conversations,
        .search(query: "q", limit: 5)]
    private let open = FleetRequest.openConversation(conversationID: "c", projectPath: "/p")

    func testFullPermitsEverythingFromAnyCaller() {
        for caller in [ControlCaller.human, .session(me), .invalid] {
            for c in commands(targeting: other) + fleetWide {
                XCTAssertTrue(ControlScope.permits(c, level: .full, caller: caller), "\(c)")
            }
            XCTAssertTrue(ControlScope.permits(open, level: .full, caller: caller))
        }
    }

    func testAHumanShellIsNeverScoped() {
        for level in ControlScopeLevel.allCases {
            for c in commands(targeting: other) + fleetWide {
                XCTAssertTrue(ControlScope.permits(c, level: level, caller: .human), "\(level) \(c)")
            }
        }
    }

    func testOwnSessionReachesOnlyItself() {
        for c in commands(targeting: me) {
            XCTAssertTrue(ControlScope.permits(c, level: .ownSession, caller: .session(me)), "\(c)")
        }
        for c in commands(targeting: other) + fleetWide {
            XCTAssertFalse(ControlScope.permits(c, level: .ownSession, caller: .session(me)), "\(c)")
        }
        for r in reads { XCTAssertTrue(ControlScope.permits(r, level: .ownSession, caller: .session(me))) }
        XCTAssertFalse(ControlScope.permits(open, level: .ownSession, caller: .session(me)),
                       "openConversation opens a tab, which is a write")
    }

    func testReadOnlyRefusesEveryWriteButStillReads() {
        for c in commands(targeting: me) + fleetWide {
            XCTAssertFalse(ControlScope.permits(c, level: .readOnly, caller: .session(me)), "\(c)")
        }
        for r in reads { XCTAssertTrue(ControlScope.permits(r, level: .readOnly, caller: .session(me))) }
        XCTAssertFalse(ControlScope.permits(open, level: .readOnly, caller: .session(me)))
    }

    func testViewingIsAlwaysPermitted() {
        for level in ControlScopeLevel.allCases {
            for caller in [ControlCaller.human, .session(me), .invalid] {
                XCTAssertTrue(ControlScope.permits(.viewing(session: other), level: level, caller: caller))
            }
        }
    }

    func testAnInvalidTokenFailsClosedWhenScoped() {
        for level in [ControlScopeLevel.ownSession, .readOnly] {
            for c in commands(targeting: me) + fleetWide {
                XCTAssertFalse(ControlScope.permits(c, level: level, caller: .invalid), "\(level) \(c)")
            }
        }
    }

    func testCallerResolution() {
        let secret = Data(repeating: 7, count: 32)
        XCTAssertEqual(ControlScope.caller(token: nil, secret: secret), .human)
        XCTAssertEqual(ControlScope.caller(token: "nope", secret: secret), .invalid)
        XCTAssertEqual(ControlScope.caller(token: ControlEnvironment.token(for: me, secret: secret),
                                           secret: secret), .session(me))
    }

    func testLevelDefaultsToFullAndReadsItsKey() {
        let suite = "ControlScopeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ControlScope.level(defaults), .full)
        defaults.set("readOnly", forKey: ControlScope.defaultsKey)
        XCTAssertEqual(ControlScope.level(defaults), .readOnly)
        defaults.set("bogus", forKey: ControlScope.defaultsKey)
        XCTAssertEqual(ControlScope.level(defaults), .full)
    }
}
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure.

- [ ] **Step 3: Implement.** `permits(command)`:
  - Return true when `level == .full`, when `caller == .human`, or for `.viewing`.
  - Otherwise, `.readOnly` and `.invalid` return false.
  - For `.ownSession` with `.session(me)`, `switch` **exhaustively, with no `default`**, so a
    new `FleetCommand` cannot compile until someone decides whether it is a write. Every
    id-bearing case returns `id == me`. `.newSession`, `.reopenClosed` and
    `.setProjectCollapsed` return false.

  `permits(request)`: `.openConversation` follows the same rule as a fleet-wide command
  (allowed only for `.full` or `.human`). Every other request returns true; switch
  exhaustively here too. `caller(token:)`: nil gives `.human`,
  `ControlEnvironment.session(forToken:)` gives `.session(id)`, and anything else gives
  `.invalid`. Add doc comments: that this is a guardrail and not a sandbox, and why a human
  shell is unscoped.

- [ ] **Step 4: Run `./scripts/test-unit.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat: add an optional scope for agent-driven fleet control`.

---

### Task 7: App wiring — tab environment, local server, scope enforcement

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`launchEnvironment(for:adapter:orphaned:)`, currently ~line 1376; make it `internal` for testing)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (`makeFleetService`)
- Test: `Tests/FlightDeckTests/FleetLocalControlTests.swift`, `Tests/FlightDeckTests/ControlLaunchEnvironmentTests.swift`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces:
  - `FleetService.startLocal(at url: URL) async throws`, which is also used by tests.
  - `FleetService.controlSecret: Data` (injected in the init as
    `controlSecret: Data = ControlEnvironment.secret()`, so tests can pass a fixed one).
  - `FleetService.scopeLevel: () -> ControlScopeLevel`, a seam defaulting to `{ ControlScope.level() }`.
  - `SessionStore.controlSocket: URL?` and `SessionStore.controlSecret: Data?`. When both are
    set, `launchEnvironment` merges `ControlEnvironment.variables(...)` last.

- [ ] **Step 1: Write the failing tests**

`ControlLaunchEnvironmentTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ControlLaunchEnvironmentTests: XCTestCase {
    func testALaunchedTabCarriesItsControlIdentityAndTheShellPaneCannotOverrideIt() {
        let store = SessionStore(provider: nil, persistence: nil)
        let secret = Data(repeating: 3, count: 32)
        store.controlSocket = URL(fileURLWithPath: "/s/control.sock")
        store.controlSecret = secret
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        // A hand-typed value in the Shell pane must not repoint a tab at another app instance.
        store.preferences?.preferences.shell.environment["FLIGHT_DECK_CONTROL_SOCKET"] = "/elsewhere"
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertEqual(env["FLIGHT_DECK_SESSION_ID"], session.id.uuidString)
        XCTAssertEqual(env["FLIGHT_DECK_CONTROL_SOCKET"], "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.session(forToken: env["FLIGHT_DECK_CALLER"] ?? "", secret: secret),
                       session.id)
    }

    func testNoControlVariablesWhenTheSocketIsOff() {
        let store = SessionStore(provider: nil, persistence: nil)
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertNil(env["FLIGHT_DECK_CONTROL_SOCKET"])
    }
}
```

(If `store.preferences` is not settable this way in a bare store, build the store with a
`PreferencesStore` the same way `FleetTestHarness` does, then set
`preferences.preferences.shell.environment`. The assertion must stay the same.)

`FleetLocalControlTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

@MainActor
final class FleetLocalControlTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient?
    private var path = ""

    override func setUp() async throws {
        harness = FleetTestHarness()
        path = "/tmp/fdfs-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness.service.stop()
        harness = nil
    }

    /// Connects locally and returns once the initial snapshot arrives.
    private func attach(caller: String? = nil, onFrame: @escaping (ServerFrame) -> Void = { _ in })
        async -> FleetClient {
        let client = FleetClient(localCaller: caller)
        self.client = client
        let ready = expectation(description: "snapshot")
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            onFrame(frame)
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        return client
    }

    func testALocalClientSeesTheFleetAndItsChanges() async throws {
        let store = harness.store
        let renamed = expectation(description: "renamed event")
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = await attach { frame in
            if case .event(_, .renamed(let id, "Renamed", _)) = frame, id == session.id { renamed.fulfill() }
        }
        XCTAssertTrue(store.rename(session.id, to: "Renamed"))
        await fulfillment(of: [renamed], timeout: 5)
    }

    func testAScopedAgentIsRefusedAnotherTabButMayMarkItsOwn() async throws {
        let store = harness.store
        let mine = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let theirs = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.markUnread(mine.id); store.markUnread(theirs.id)
        harness.service.scopeLevel = { .ownSession }
        let token = ControlEnvironment.token(for: mine.id, secret: harness.service.controlSecret)
        var replies: [Int: ServerFrame] = [:]
        let two = expectation(description: "two replies"); two.expectedFulfillmentCount = 2
        let client = await attach(caller: token) { frame in
            if let cid = frame.correlationID { replies[cid] = frame; two.fulfill() }
        }
        let refused = client.send(FleetCommand.markRead(id: theirs.id))
        let allowed = client.send(FleetCommand.markRead(id: mine.id))
        await fulfillment(of: [two], timeout: 5)
        XCTAssertEqual(replies[refused], .err(cid: refused, code: "out_of_scope"))
        XCTAssertEqual(replies[allowed], .ack(cid: allowed))
    }

    func testAScopedAgentCannotOpenAConversation() async throws {
        harness.service.scopeLevel = { .readOnly }
        let token = ControlEnvironment.token(for: UUID(), secret: harness.service.controlSecret)
        let refused = expectation(description: "refused")
        var cid = 0
        let client = await attach(caller: token) { frame in
            if case .err(let got, "out_of_scope") = frame, got == cid { refused.fulfill() }
        }
        cid = client.send(FleetRequest.openConversation(conversationID: UUID().uuidString, projectPath: "/w"))
        await fulfillment(of: [refused], timeout: 5)
    }

    func testALocalViewingDoesNotLightThePhoneBadge() async throws {
        let session = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let acked = expectation(description: "ack")
        var cid = 0
        let client = await attach { if case .ack(let got) = $0, got == cid { acked.fulfill() } }
        cid = client.send(FleetCommand.viewing(session: session.id))
        await fulfillment(of: [acked], timeout: 5)
        XCTAssertTrue(harness.service.phoneActiveSessions.isEmpty)
    }

    func testAPhoneKeyReloadDoesNotDropALocalClient() async throws {
        _ = try await harness.start()           // the phone listener
        var disconnected = false
        let client = await attach()
        client.onDisconnect = { _ in disconnected = true }
        _ = try await harness.service.start()   // what every arm/expiry/revoke does
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(disconnected)
    }
}
```

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure (no `startLocal(at:)` or `controlSocket`).

- [ ] **Step 3: Implement.**
  - **`SessionStore`**: add `var controlSocket: URL?` and `var controlSecret: Data?`, with doc
    comments saying `FlightDeckApp` sets them when the control socket is enabled. In
    `launchEnvironment`, after the adapter loop, add:
    ```swift
    // Last, like the adapter's half and for the same reason: a variable typed into the Shell
    // pane must not repoint a tab at another app instance's socket or claim another tab.
    if let controlSocket, let controlSecret {
        for (key, value) in ControlEnvironment.variables(
            for: session.id, socket: controlSocket, secret: controlSecret) { environment[key] = value }
    }
    ```
    Change `private func launchEnvironment` to `func launchEnvironment` and add a comment that
    it is internal for `ControlLaunchEnvironmentTests`.
  - **`FleetService`**:
    - Add `private let localServer = FleetSocketServer()` and
      `let controlSecret: Data`, set from a new defaulted init parameter
      `controlSecret: Data = ControlEnvironment.secret()`.
    - Add `var scopeLevel: () -> ControlScopeLevel = { ControlScope.level() }`.
    - Extract the handler bodies from `wireHandlers()` into methods so both servers share them:
      ```swift
      private func handleHello(_ attachment: FleetAttachment, _ lastSeq: Int) -> [ServerFrame]
      private func handleCommand(_ client: FleetAttachment, _ cid: Int, _ command: FleetCommand, _ reply: @escaping (ServerFrame) -> Void)
      private func handleRequest(_ client: FleetAttachment, _ cid: Int, _ request: FleetRequest, _ reply: @escaping (ServerFrame) -> Void)
      ```
      Moving code verbatim is fine. Assign them to both `server.on…` and `localServer.on…`.
      **Do not** wire `localServer.onAttachedSlotsChanged`: attached slots and presence pruning
      are phone-only by construction.
    - `handleHello`: for `attachment.isLocal`, skip `noteAttached` and return
      `framesForLocal(resumingFrom:)`. That is the same replicator logic as `frames(resumingFrom:)`
      **without** the `promptLifecycle.observeResume` call, because a CLI is not a phone that
      was away. Factor the shared replicator part into `private func resumeFrames(from:) -> [ServerFrame]`,
      and have `frames(resumingFrom:)` call it and then observe.
    - `handleCommand`: first,
      ```swift
      if client.isLocal {
          let caller = ControlScope.caller(token: client.caller, secret: controlSecret)
          guard ControlScope.permits(command, level: scopeLevel(), caller: caller) else {
              return reply(.err(cid: cid, code: "out_of_scope"))
          }
          // Presence is a phone's, and a CLI tailing a tab is not a phone looking at it.
          if case .viewing = command { return reply(.ack(cid: cid)) }
      }
      ```
      After that, run the existing body.
    - `handleRequest`: the same scope guard with `permits(request, …)`.
    - `replicator.onEvents`: also `localServer.broadcast(.event(seq: entry.seq, entry.event))`.
      Leave `promptLifecycle.observe(batch, clients: self.server.attachedCount)` as is (phone
      count only).
    - Add:
      ```swift
      /// The local control socket (`flightdeck`). Independent of pairing: a Mac nobody has paired
      /// with still has a CLI. See `FleetSocketServer.startLocal` for why it is its own instance.
      func startLocal(at url: URL) async throws { try await localServer.startLocal(path: url.path) }
      ```
    - In `stop()`, add `localServer.stop()`.
  - **`FlightDeckApp.makeFleetService`**: after the existing guarded `Task`, add a second,
    independent start. The two must not share a do/catch, because a failed phone bind must not
    stop the CLI and the reverse:
    ```swift
    if ControlEnvironment.isEnabled() {
        let url = ControlEnvironment.socketURL()
        store.controlSocket = url
        store.controlSecret = service.controlSecret
        Task {
            do { try await service.startLocal(at: url) }
            catch { logger.error("control socket failed to bind: \(String(describing: error), privacy: .public)") }
        }
    }
    ```
    This sits after the `isResettingState` guard, so UITests stay hermetic. Put it inside the
    same function and let it inherit that guard, and do not set `store.controlSocket` when
    resetting.

- [ ] **Step 4: Run `./scripts/test-unit.sh`.** Expected: PASS, with the existing
  `FleetServiceTests` unchanged. **Mutation check:** comment out the scope guard and confirm
  `testAScopedAgentIsRefusedAnotherTabButMayMarkItsOwn` fails. Remove the `viewing` early
  return and confirm the badge test fails. Then restore both.
- [ ] **Step 5: Commit** with the message
  `feat: serve the fleet protocol on a local control socket, scoped per tab`.

---

### Task 8: CLI core — arguments and session resolution

**Files:**
- Create: `Sources/FlightDeckCLI/CLIArguments.swift`, `Sources/FlightDeckCLI/CLISessionResolver.swift`
- Modify: `project.yml`. Add `- path: Sources/FlightDeckCLI` to `FlightDeckTests.sources`, so
  the core is compiled into the test bundle. All type names are `CLI`-prefixed so they cannot
  clash with `@testable import FlightDeck`.
- Test: `Tests/FlightDeckTests/CLIArgumentsTests.swift`, `Tests/FlightDeckTests/CLISessionResolverTests.swift`

**Interfaces:**
- Produces:

```swift
struct CLIUsageError: Error, Equatable { let message: String }
enum CLIAnswerChoice: Equatable { case selections([[Int]]), allow, deny }
enum CLICommand: Equatable {
    case help
    case ls(project: String?)
    case tail(session: String?, since: Int?, noSnapshot: Bool)
    case wait(session: String, condition: String, timeout: TimeInterval?)
    case send(session: String, text: String)
    case new(project: String, agent: String?, account: Int?)
    case close(String), reopen(UUID), rename(String, title: String), read(String), unread(String)
    case collapse(project: String, collapsed: Bool)
    case prompt(session: String)
    case answer(session: String, choice: CLIAnswerChoice, call: String?)
    case abort(session: String)
    case planResolve(session: String, approve: Bool, feedback: String?)
    case planAnnotate(session: String, text: String, block: Int?)
    case timeline(session: String, anchor: TimelineAnchor, limit: Int)
    case search(query: String, limit: Int)
    case open(conversation: String, projectPath: String)
    case closed
    case options(project: String)
    case raw(String)
}
struct CLIInvocation: Equatable { var command: CLICommand; var json: Bool; var socket: String? }
enum CLIArguments { static func parse(_ args: [String]) throws -> CLIInvocation }   // args exclude argv[0]

enum CLIResolveError: Error, Equatable { case noSelf, notFound(String), ambiguous(String, [UUID]) }
enum CLISessionResolver {
    static func session(_ token: String, in fleet: FleetSnapshot, selfID: UUID?) -> Result<UUID, CLIResolveError>
    static func project(_ token: String, in fleet: FleetSnapshot, cwd: String) -> Result<UUID, CLIResolveError>
}
```

Parsing rules:
- The global flags `--json` and `--socket PATH` may appear anywhere.
- No arguments, `help`, `-h` or `--help` gives `.help`.
- Defaults: `timeline --limit` is 40; `--before`, `--after` and `--around` map to
  `TimelineAnchor.before/.after/.around`, otherwise `.latest`. `search --limit` is 20. `wait`
  requires `--for` and takes `--timeout` in seconds.
- `answer S allow|deny|'[[0,1],[2]]'` with optional `--call C`. `reopen` requires a full UUID.
- `plan approve|reject S [--feedback F]` and `plan annotate S TEXT [--block N]`.
- `collapse P [--off]`.
- Unknown verbs, missing operands, unknown flags and malformed numbers throw a
  `CLIUsageError`, and its message names the problem.

Resolution rules:
- Session: `self` → `selfID`, or `.noSelf` if it is nil. Otherwise, in order:
  1. An exact UUID match.
  2. A case-insensitive UUID prefix of at least 4 characters matching exactly one session.
  3. An exact title matching exactly one session.
  Several prefix or title matches give `.ambiguous(token, ids)`. No match gives `.notFound`.
- Project: `.` or `here` → the project whose `path` equals `cwd` or is the longest ancestor of
  it. Otherwise an exact `path`, then an exact `name`, then a UUID prefix of at least 4
  characters. The same ambiguity rules apply.

- [ ] **Step 1: Write the failing tests.** `CLIArgumentsTests`:

```swift
import FleetKit
import XCTest

final class CLIArgumentsTests: XCTestCase {
    private func parse(_ s: String...) throws -> CLIInvocation { try CLIArguments.parse(s) }

    func testGlobalsAnywhere() throws {
        XCTAssertEqual(try parse("ls", "--json"), CLIInvocation(command: .ls(project: nil), json: true, socket: nil))
        XCTAssertEqual(try parse("--socket", "/s", "ls").socket, "/s")
    }
    func testNoArgumentsIsHelp() throws { XCTAssertEqual(try CLIArguments.parse([]).command, .help) }
    func testTail() throws {
        XCTAssertEqual(try parse("tail", "--session", "self", "--since", "12", "--no-snapshot").command,
                       .tail(session: "self", since: 12, noSnapshot: true))
    }
    func testWaitNeedsFor() {
        XCTAssertThrowsError(try parse("wait", "abcd"))
        XCTAssertEqual(try? parse("wait", "abcd", "--for", "idle", "--timeout", "30").command,
                       .wait(session: "abcd", condition: "idle", timeout: 30))
    }
    func testSendJoinsNothingAndTakesOneText() throws {
        XCTAssertEqual(try parse("send", "self", "hello there").command, .send(session: "self", text: "hello there"))
        XCTAssertThrowsError(try parse("send", "self"))
    }
    func testAnswerForms() throws {
        XCTAssertEqual(try parse("answer", "s", "allow").command, .answer(session: "s", choice: .allow, call: nil))
        XCTAssertEqual(try parse("answer", "s", "[[0,1],[2]]", "--call", "c").command,
                       .answer(session: "s", choice: .selections([[0, 1], [2]]), call: "c"))
        XCTAssertThrowsError(try parse("answer", "s", "[[x]]"))
    }
    func testPlan() throws {
        XCTAssertEqual(try parse("plan", "reject", "s", "--feedback", "no").command,
                       .planResolve(session: "s", approve: false, feedback: "no"))
        XCTAssertEqual(try parse("plan", "annotate", "s", "note", "--block", "3").command,
                       .planAnnotate(session: "s", text: "note", block: 3))
    }
    func testTimelineAnchors() throws {
        XCTAssertEqual(try parse("timeline", "s").command, .timeline(session: "s", anchor: .latest, limit: 40))
        XCTAssertEqual(try parse("timeline", "s", "--before", "900", "--limit", "5").command,
                       .timeline(session: "s", anchor: .before(900), limit: 5))
    }
    func testReopenNeedsAFullUUID() { XCTAssertThrowsError(try parse("reopen", "abcd")) }
    func testUnknownVerbIsAUsageError() {
        XCTAssertThrowsError(try parse("frobnicate")) { XCTAssertTrue(($0 as? CLIUsageError)?.message.contains("frobnicate") == true) }
    }
}
```

`CLISessionResolverTests` builds a `FleetSnapshot` with two projects and three sessions. Two of
the sessions share the title "dup", and the projects are at `/w/a` and `/w/a/nested`. Cover:
- `self` with and without `selfID`.
- A full UUID, a unique 4-character prefix, and a 3-character prefix, which is refused as
  `notFound`.
- A shared prefix (`ambiguous`), a unique title, and the duplicate title (`ambiguous` listing
  both ids).
- A project by `.` from `cwd` `/w/a/nested/src`, which must pick `/w/a/nested` (longest
  ancestor, not `/w/a`).
- A project by name, and a project not found.

Build `WireSession` and `WireProject` values with their public inits; read `Wire.swift:29` and
`:181` for the parameters.

- [ ] **Step 2: Run `./scripts/test-unit.sh`** (run `xcodegen generate` first, which `build.sh`
  does). Expected: a build failure.
- [ ] **Step 3: Implement both files.** Hand-roll the parser: add no package dependency. Keep
  it one `switch verb` over a small cursor type with `next()`, `flag(_:)` and `int(_:)`
  helpers. Decode `[[Int]]` with `JSONDecoder`.
- [ ] **Step 4: Run `./scripts/test-unit.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `project.yml`, the two sources and the two tests, with the message
  `feat: parse flightdeck commands and resolve sessions by id, prefix or title`.

---

### Task 9: CLI core — the runner

**Files:**
- Create: `Sources/FlightDeckCLI/CLITransport.swift`, `Sources/FlightDeckCLI/CLIRunner.swift`, `Sources/FlightDeckCLI/CLIOutput.swift`
- Test: `Tests/FlightDeckTests/CLIRunnerTests.swift`

**Interfaces:**
- Consumes: Task 8, and FleetKit's `FleetSnapshot.applying(_:)`, `OpenPrompt.find(in:agent:activity:)`,
  `ServerFrame.correlationID` and `PromptAnswer`/`AnswerSelection`.
- Produces:

```swift
protocol CLITransport: AnyObject {
    var onFrame: ((ServerFrame) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func connect(lastSeq: Int)
    @discardableResult func send(_ command: FleetCommand) -> Int
    @discardableResult func send(_ request: FleetRequest) -> Int
    func send(raw frame: ClientFrame)
    func disconnect()
}
struct CLIContext { var selfID: UUID?; var cwd: String; var json: Bool; var isTTY: Bool }
final class CLIRunner {
    init(invocation: CLIInvocation, transport: CLITransport, context: CLIContext,
         out: @escaping (String) -> Void, err: @escaping (String) -> Void,
         finish: @escaping (Int32) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void)
    func run()
}
enum CLIOutput {
    static func line(_ frame: ServerFrame) -> String         // compact JSON, sorted keys
    static func json<T: Encodable>(_ value: T) -> String
    static func table(_ fleet: FleetSnapshot) -> String      // PROJECT  ID(8)  TITLE  AGENT  ACTIVITY  WAITING
    static func eventSession(_ event: FleetEvent) -> UUID?   // for tail --session
}
```

Runner behaviour. Every command connects first. `tail --since N` connects with `lastSeq: N`;
every other command uses `lastSeq: 0`. Every command waits for the first `.snapshot`, keeps
`fleet` up to date with `applying` on each `.event`, and then:

| Command | Behaviour |
|---|---|
| `ls` | Print `table` (TTY, not `--json`) or `json(fleet)` filtered by project if given, then finish 0 |
| `tail` | Print `line(snapshot)` unless `noSnapshot`. Print `line(event)` for each event (filtered by `eventSession == target` when `--session`). Track `lastSeq`. On disconnect, `schedule(1)` reconnect with `lastSeq: lastSeq` and never finish on its own. A re-snapshot after reconnect prints as a line (consumers see the reset) |
| `wait` | Evaluate after the snapshot and every event: `gone` means the session is absent, otherwise `session.activity == condition`. On a match print `json(session)` or `{}` for gone and finish 0. `--timeout` means `schedule(t)` then `err("timed_out")` and finish 1 |
| `send`/`close`/`read`/`unread`/`rename`/`collapse`/`abort`/`reopen` | Resolve, send the `FleetCommand` (fresh `UUID()` token where needed), then on `.ack(cid)` finish 0, on `.err(cid, code)` print `code` to err and finish 1 |
| `new` | Resolve the project, send `.newSession`, and on ack wait for the first `.sessionAdded(s, project: P, _)` **whose project is P**. Print `s.id` (or `json(s)`) and finish 0. After a 30s `schedule` timeout, print `launch_unconfirmed` to err and finish 1 |
| `prompt` | Resolve, send `.timeline(session:, anchor: .latest, limit: 200)`, and on `.page` run `OpenPrompt.find(in: page.items, agent: s.agent, activity: s.activity)`. Print it (questions with numbered options, or JSON) and finish 0. Nil means `no_prompt` and finish 1 |
| `answer` | Derive the prompt as `prompt` does. `.allow`/`.deny` require `.permission`. `.selections` require `.question`, and each index must be in range: otherwise print a usage error and finish 2. Build `.answers(selections.enumerated().map { q, picks in picks.map { AnswerSelection(index: $0, label: questions[q].options[$0].label) } })`. `call` is `--call` or the derived `callID`. Then ack/err as above |
| `plan …` | Take `call` from `session.planGate?.callID`. If nil, `no_plan_gate` and finish 1. Send `.resolvePlan` or `.annotatePlan` |
| `timeline`/`search`/`closed`/`options`/`open` | Send the `FleetRequest` and print the reply payload as JSON. `open` prints the `.session` id. `.err` finishes 1 |
| `raw` | Decode the argument as `ClientFrame` (usage error 2 on failure) and `send(raw:)` it. If it has a cid, print every frame whose `correlationID` matches and finish 0 on the first one (1 if it is `.err`). A `hello` prints the next snapshot |

Resolution failures print a message naming the candidates and finish 2. A disconnect before the
first snapshot finishes 69 with `flightdeck: cannot reach Flight Deck at <path>`; the main
program supplies the path in its err message.

- [ ] **Step 1: Write the failing tests** with a fake transport:

```swift
import FleetKit
import XCTest

final class FakeTransport: CLITransport {
    var onFrame: ((ServerFrame) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var connects: [Int] = []
    var sent: [ClientFrame] = []
    private var cid = 0
    func connect(lastSeq: Int) { connects.append(lastSeq) }
    func send(_ command: FleetCommand) -> Int { cid += 1; sent.append(.cmd(cid: cid, command)); return cid }
    func send(_ request: FleetRequest) -> Int { cid += 1; sent.append(.req(cid: cid, request)); return cid }
    func send(raw frame: ClientFrame) { sent.append(frame) }
    func disconnect() {}
    func push(_ frame: ServerFrame) { onFrame?(frame) }
}

final class CLIRunnerTests: XCTestCase {
    private let project = UUID()
    private let other = UUID()
    private let a = UUID()
    private var out: [String] = []
    private var err: [String] = []
    private var code: Int32?
    private var scheduled: [(TimeInterval, () -> Void)] = []

    private func fleet(activity: String? = "busy", extra: [WireSession] = []) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: project, name: "a", path: "/w/a",
                        sessions: [WireSession(id: a, title: "alpha", agent: "claude", activity: activity)] + extra),
            WireProject(id: other, name: "b", path: "/w/b"),
        ])
    }

    private func runner(_ args: String..., transport: FakeTransport, selfID: UUID? = nil) -> CLIRunner {
        let r = CLIRunner(invocation: try! CLIArguments.parse(args), transport: transport,
                          context: CLIContext(selfID: selfID, cwd: "/w/a", json: true, isTTY: false),
                          out: { self.out.append($0) }, err: { self.err.append($0) },
                          finish: { self.code = $0 }, schedule: { self.scheduled.append(($0, $1)) })
        r.run()
        return r
    }

    func testSendResolvesSelfAndFinishesOnAck() {
        let t = FakeTransport()
        _ = runner("send", "self", "hi", transport: t, selfID: a)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, .prompt(a, _, "hi")) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertNil(code)
        t.push(.ack(cid: cid))
        XCTAssertEqual(code, 0)
    }

    func testARefusalIsExitOneWithTheWireCode() {
        let t = FakeTransport()
        _ = runner("close", "alpha", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.err(cid: cid, code: "out_of_scope"))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("out_of_scope"))
    }

    func testUnreachableBeforeSnapshotIsSixtyNine() {
        let t = FakeTransport()
        _ = runner("ls", transport: t)
        t.onDisconnect?(nil)
        XCTAssertEqual(code, 69)
    }

    func testTailReconnectsAndResumesFromLastSeq() {
        let t = FakeTransport()
        _ = runner("tail", transport: t)
        t.push(.snapshot(seq: 5, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 6, .unreadChanged(id: a, isUnread: true)))
        t.onDisconnect?(nil)
        XCTAssertNil(code, "tail outlives an app restart")
        XCTAssertEqual(scheduled.count, 1)
        scheduled[0].1()
        XCTAssertEqual(t.connects, [0, 6])
        XCTAssertEqual(out.count, 2)
    }

    func testTailSessionFilter() {
        let t = FakeTransport()
        _ = runner("tail", "--session", "alpha", "--no-snapshot", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 2, .unreadChanged(id: UUID(), isUnread: true)))
        t.push(.event(seq: 3, .unreadChanged(id: a, isUnread: true)))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].contains(a.uuidString))
    }

    func testWaitFinishesWhenActivityMatches() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "idle", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "busy"), reason: .initial))
        XCTAssertNil(code)
        t.push(.event(seq: 2, .activityChanged(id: a, activity: "idle", waitingFor: nil,
                                               subagentCount: 0, hasBackgroundWork: false)))
        XCTAssertEqual(code, 0)
    }

    func testWaitGone() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "gone", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 2, .sessionRemoved(id: a)))
        XCTAssertEqual(code, 0)
    }

    func testNewPrintsTheSessionAddedInItsProject() {
        let t = FakeTransport()
        _ = runner("new", "/w/a", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, .newSession(project, nil, nil)) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.ack(cid: cid))
        let elsewhere = WireSession(id: UUID(), title: "x", agent: "claude")
        t.push(.event(seq: 2, .sessionAdded(elsewhere, project: other, at: 0)))
        XCTAssertNil(code, "a tab created in another project is not ours")
        let ours = WireSession(id: UUID(), title: "new", agent: "claude")
        t.push(.event(seq: 3, .sessionAdded(ours, project: project, at: 1)))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.joined().contains(ours.id.uuidString))
    }

    func testAmbiguousTitleIsExitTwo() {
        let t = FakeTransport()
        let d1 = WireSession(id: UUID(), title: "dup", agent: "claude")
        let d2 = WireSession(id: UUID(), title: "dup", agent: "claude")
        _ = runner("close", "dup", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(extra: [d1, d2]), reason: .initial))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(t.sent.isEmpty, "nothing is closed on a guess")
        XCTAssertTrue(err.joined().contains(d1.id.uuidString))
        XCTAssertTrue(err.joined().contains(d2.id.uuidString))
    }

    /// A hand-built question, not a capture: this tests the runner's index-to-label mapping,
    /// and `OpenPromptTests` already pins the parse against real captures.
    private func questionPage() -> TimelinePage {
        let input = #"{"questions":[{"question":"Pick","header":"H","multiSelect":false,"options":[{"label":"Red","description":"r"},{"label":"Blue","description":"b"}]}]}"#
        let item = TimelineItem(
            id: TimelineItem.identifier(offset: 0, index: 0), kind: .toolCall, status: .complete,
            body: .init(text: input, tool: "AskUserQuestion", callID: "toolu_q"))
        return TimelinePage(session: a, items: [item], start: 0, end: 100, hasMore: false, reset: false)
    }

    func testAnswerBuildsLabelledSelectionsFromTheDerivedPrompt() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "[[1]]", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, .timeline(a, .latest, 200)) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.page(cid: cid, questionPage()))
        guard case .cmd(_, .answerPrompt(a, _, "toolu_q", let answer)) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertEqual(answer, .answers([[AnswerSelection(index: 1, label: "Blue")]]))
    }

    func testAnswerOutOfRangeIsExitTwoAndSendsNothing() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "[[5]]", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.page(cid: cid, questionPage()))
        XCTAssertEqual(code, 2)
        XCTAssertEqual(t.sent.count, 1, "only the timeline request went out")
    }

    func testRawCorrelatesItsReply() {
        let t = FakeTransport()
        _ = runner("raw", #"{"t":"req","cid":99,"op":"session.recentlyClosed"}"#, transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        XCTAssertEqual(t.sent.last, .req(cid: 99, .recentlyClosed))
        t.push(.ack(cid: 1))                      // someone else's
        XCTAssertNil(code)
        t.push(.recentlyClosed(cid: 99, []))
        XCTAssertEqual(code, 0)
    }
}
```

  If `OpenPrompt.find` returns nil for `questionPage()`, check the item `kind` and `tool` spelling
  against `OpenPromptTests.call(_:tool:…)` (`Tests/FlightDeckTests/OpenPromptTests.swift`), and
  fix the fixture, not the runner.

- [ ] **Step 2: Run `./scripts/test-unit.sh`.** Expected: a build failure.
- [ ] **Step 3: Implement** `CLITransport.swift` (protocol only), `CLIOutput.swift` and
  `CLIRunner.swift`, in the order the table gives. Write `CLIOutput.eventSession` as an
  explicit `switch` over `FleetEvent`:
  - Return `id` for `sessionRemoved`, `sessionMoved`, `renamed`, `activityChanged`,
    `unreadChanged`, `apiErrorChanged`, `planGateChanged`, `promptExpired` and `promptTyped`.
  - Return the session's id for `sessionAdded`.
  - Return nil for the project-level cases.
  - Use **no `default`**, so a new event case must be classified before it compiles.
- [ ] **Step 4: Run `./scripts/test-unit.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** with the message `feat: drive the fleet protocol from flightdeck commands`.

---

### Task 10: The `flightdeck` binary and bundling

**Files:**
- Create: `Sources/flightdeck/main.swift`, `Sources/flightdeck/LocalFleetTransport.swift`
- Modify: `project.yml` (the new `flightdeck` target, plus the embed from the `FlightDeck` target)

**Interfaces:**
- Consumes: Task 4's `FleetClient(localCaller:)`/`connect(toLocal:lastSeq:)`, Task 9's `CLIRunner`/`CLITransport`.

- [ ] **Step 1: Add the target** to `project.yml`, with a comment in the house style explaining
  why it lives in `Contents/MacOS` (already on every tab's `PATH` via `GHOSTTY_BIN_DIR`) and why
  the name never collides with `Flight Deck` (AGENTS.md rule 2):

```yaml
  flightdeck:
    type: tool
    platform: macOS
    sources:
      - Sources/flightdeck
      - Sources/FlightDeckCLI
    dependencies:
      - target: FleetKit
        embed: false
    settings:
      base:
        PRODUCT_NAME: flightdeck
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
        HEADER_SEARCH_PATHS: $(SRCROOT)/vendor/boringssl-artifacts/include
        DEVELOPMENT_TEAM: 2T9E3N27J8
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: Apple Development
```

  In `FlightDeck.dependencies` add:

```yaml
      - target: flightdeck
        embed: true
        codeSign: true
        copy:
          destination: executables
```

- [ ] **Step 2: Write `LocalFleetTransport.swift`**, an adapter from `FleetClient` to `CLITransport`:

```swift
import FleetKit
import Foundation

/// `CLITransport` over the real local socket. The runner is transport-agnostic so its tests can
/// drive it frame by frame. This is the only file that touches a socket.
final class LocalFleetTransport: CLITransport {
    var onFrame: ((ServerFrame) -> Void)? { didSet { client.onFrame = onFrame } }
    var onDisconnect: ((Error?) -> Void)? { didSet { client.onDisconnect = onDisconnect } }
    private let client: FleetClient
    private let path: String
    init(path: String, caller: String?) {
        self.path = path
        client = FleetClient(localCaller: caller)
    }
    func connect(lastSeq: Int) { client.connect(toLocal: path, lastSeq: lastSeq) }
    func send(_ command: FleetCommand) -> Int { client.send(command) }
    func send(_ request: FleetRequest) -> Int { client.send(request) }
    func send(raw frame: ClientFrame) { client.answer(frame) }
    func disconnect() { client.disconnect() }
}
```

- [ ] **Step 3: Write `main.swift`**:
  - Parse `Array(CommandLine.arguments.dropFirst())`. On `CLIUsageError`, print it and the usage
    text to stderr and `exit(2)`. On `.help`, print the usage text (every verb from the spec's
    table, one line each) and `exit(0)`.
  - Resolve the socket in this order: `--socket` → `$FLIGHT_DECK_CONTROL_SOCKET` →
    `$FLIGHT_DECK_STATE_DIR/control.sock` → `~/Library/Application Support/Flight Deck/control.sock`.
  - Build `CLIContext` with `selfID: UUID(uuidString: env["FLIGHT_DECK_SESSION_ID"] ?? "")`,
    `cwd: FileManager.default.currentDirectoryPath`, `json` and `isTTY: isatty(1) == 1`.
  - Create `CLIRunner` with `out` (print, then `fflush(stdout)`) and `err` (write to stderr). In
    `finish`, write a 69-specific message naming the socket path, then `exit(code)`. Pass
    `schedule` as `DispatchQueue.main.asyncAfter`.
  - `runner.run()`, then `dispatchMain()`.
  - Ignore `SIGPIPE` (`signal(SIGPIPE, SIG_IGN)`), so `flightdeck tail | head` ends quietly.

- [ ] **Step 4: Build and verify the bundle.** Do not launch the app.

```bash
./scripts/build.sh
APP="DerivedData/Build/Products/Debug/Flight Deck.app"
test -x "$APP/Contents/MacOS/flightdeck" && echo EMBEDDED
otool -L "$APP/Contents/MacOS/flightdeck" | rg FleetKit        # expect @rpath/FleetKit.framework
codesign --verify --deep --strict "$APP" && echo SIGNED
"$APP/Contents/MacOS/flightdeck" --help | head -3               # the CLI, not the app: safe
"$APP/Contents/MacOS/flightdeck" --socket /tmp/fd-none.sock ls; echo "exit=$?"   # expect exit=69
"$APP/Contents/MacOS/flightdeck" frobnicate; echo "exit=$?"     # expect exit=2
```

  Expected: `EMBEDDED`, a FleetKit rpath line, `SIGNED`, the usage text, `exit=69` and `exit=2`.
  Also run `./scripts/test-unit.sh` (it must stay green) and `./scripts/build-ios.sh`.

- [ ] **Step 5: Commit** `project.yml`, `Sources/flightdeck/*`, with the message
  `feat: ship the flightdeck CLI inside the app bundle`.

---

### Task 11: Preferences surface and docs

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` (a new `Section("Command Line")`)
- Modify: `docs/ARCHITECTURE.md`, `docs/HANDOFF.md`, `AGENTS.md` (the Commands block), `docs/superpowers/specs/2026-09-24-flightdeck-cli-design.md` (Status → implemented)

- [ ] **Step 1: Add the section.** Use `@AppStorage` so it needs no store plumbing:

```swift
            Section("Command Line") {
                // Read at launch, like `FlightDeckAnswerTrigger`: a socket that appeared and
                // vanished under a running app would be a second lifetime to reason about.
                Toggle("Enable the flightdeck control socket (takes effect at relaunch)",
                       isOn: $controlSocketEnabled)
                Picker("Agents in tabs may control", selection: $scopeRaw) {
                    Text("Any tab").tag(ControlScopeLevel.full.rawValue)
                    Text("Only their own tab").tag(ControlScopeLevel.ownSession.rawValue)
                    Text("Nothing (read only)").tag(ControlScopeLevel.readOnly.rawValue)
                }
                Text("A guardrail, not a sandbox: it stops a well-behaved agent reaching past its own tab by mistake. Any program running as you can bypass it. Your own shell is never restricted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

  With these properties: `@AppStorage(ControlEnvironment.enabledKey) private var controlSocketEnabled = true`
  and `@AppStorage(ControlScope.defaultsKey) private var scopeRaw = ControlScopeLevel.full.rawValue`.
  The scope is read per command (`scopeLevel()` calls `ControlScope.level()` each time), so the
  picker takes effect immediately. Only the toggle needs a relaunch.

- [ ] **Step 2: Update the docs.**
  - `ARCHITECTURE.md`: a short "Local control socket" subsection under the fleet section. Cover
    the second `FleetSocketServer` instance, line framing and why it is not WebSocket,
    `ControlScope`, and the three tab variables.
  - `HANDOFF.md`: a quickstart (`flightdeck ls`, `flightdeck tail --session self`,
    `flightdeck send <tab> "…"`, `flightdeck wait <tab> --for idle`) and the fact that it
    ships in `Contents/MacOS`.
  - `AGENTS.md`'s Commands block: add a `flightdeck` line pointing at HANDOFF.
  - The spec: `Status: implemented`.

- [ ] **Step 3: Verify.** Run `./scripts/build.sh` and `./scripts/test-unit.sh`, and expect
  both green.
- [ ] **Step 4: Commit** with the message `docs: document the flightdeck CLI and its scope setting`.

---

## After the last task

- Run a whole-branch review (subagent-driven-development's final reviewer).
- **End-to-end on the real app is Nate's to run.** Agents cannot run the GUI here. A Release
  build must be installed with `scripts/swap-release.sh`, run detached. Then, from a Flight
  Deck tab, check:
  - `flightdeck ls`
  - `flightdeck tail --session self` while typing in another tab
  - `flightdeck new . && flightdeck wait <id> --for idle`
  - the scope picker at "Only their own tab", then `flightdeck close <another tab>` must fail
    with `out_of_scope`
  - `flightdeck tail` survives a swap and resumes.

  Record the results in the spec's status line.
