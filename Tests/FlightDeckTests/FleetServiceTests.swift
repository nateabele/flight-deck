import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The seam test: a real client, a real socket, and a real `SessionStore` at the far end.
/// This is the test that says slice 1a's spine works.
@MainActor
final class FleetServiceTests: XCTestCase {
    /// Held for the length of the test, not just for `standUp()`: it owns the preferences
    /// store the service reads its keys back out of, and a harness released here would take
    /// that with it.
    private var harness: FleetTestHarness?
    private var service: FleetService?
    private var client: FleetClient?

    /// Same reason as `DisplayDrawableGuardTests`: `SessionStore.provider` is `weak`, so an
    /// unretained `StubProvider` would deallocate mid-test.
    private var retainedProviders: [StubProvider] = []

    override func tearDown() async throws {
        client?.disconnect()
        service?.stop()
        client = nil
        service = nil
        harness = nil
    }

    /// The stand-up itself lives in `FleetTestHarness` — the timeline's loopback test needs
    /// exactly this fleet, and two ways to stand one up is how the two halves drift. The
    /// tuple stays so none of the tests below change.
    private func standUp() async throws -> (SessionStore, FleetDeviceKey, NWEndpoint.Port) {
        let harness = FleetTestHarness()
        self.harness = harness
        self.service = harness.service
        return (harness.store, harness.key, try await harness.start())
    }

    /// The same, plus the live claude login a New Session menu row needs to resolve against.
    /// Without one `NewSessionOptionsProjection.account` answers nil and the handler falls back
    /// to the project's default — the path that was never broken — so a test that skips this
    /// exercises everything except the line it means to.
    private func standUpWithALogin() async throws
        -> (SessionStore, PreferencesStore, FleetDeviceKey, NWEndpoint.Port) {
        let harness = FleetTestHarness()
        self.harness = harness
        self.service = harness.service
        harness.preferences.preferences.storedAccounts = [
            AgentAccount(agent: .claude, displayName: "Work",
                         home: URL(fileURLWithPath: "/w/home-work"))
        ]
        return (harness.store, harness.preferences, harness.key, try await harness.start())
    }

    func testAConnectingClientIsHandedTheLiveFleet() async throws {
        let (store, key, port) = try await standUp()
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
        // `await fulfillment`, not `wait(for:)`: this method's synchronous prefix runs as a
        // Task job on the MainActor's executor, which is backed by `DispatchQueue.main` — the
        // same queue `FleetSocketServer`/`FleetClient` use to deliver every callback. A
        // `wait(for:)` spin blocks that job in place without suspending it, so the executor
        // never admits the very callbacks the wait is blocking on: the socket frame would
        // never arrive and the expectation would never fulfill. `fulfillment` is a genuine
        // suspension point, so the Task job ends and the queue drains normally.
        await fulfillment(of: [arrived], timeout: 10)

        XCTAssertEqual(snapshot?.projects.first?.name, "alpha")
        XCTAssertEqual(snapshot?.projects.first?.sessions.map(\.id), [session.id])
    }

    func testAMutationAfterAttachingReachesTheClient() async throws {
        let (store, key, port) = try await standUp()
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
        // Poll rather than sleep: `attachedSlots` is the service's own published fact.
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.service?.attachedSlots.count == 1 { attached.fulfill() }
            }
        }
        // See the comment on the first test: `await fulfillment`, not `wait(for:)`, so the
        // MainActor's DispatchQueue.main-backed executor actually drains while we wait.
        await fulfillment(of: [attached], timeout: 10)
        observer.invalidate()

        store.rename(session.id, to: "elsewhere")
        await fulfillment(of: [renamed], timeout: 10)
    }

    func testMarkingReadFromAClientClearsTheMarkOnTheMac() async throws {
        let (store, key, port) = try await standUp()
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
        await fulfillment(of: [acked], timeout: 10)

        // Unread is one fleet-wide fact, not a per-device one (§8): reading on the phone
        // clears the dot on the Mac, which is what the mark means.
        XCTAssertFalse(store.unreadIdle.contains(a.id))
    }

    /// **A new session lands in the project the phone tapped, not the one the Mac has
    /// selected.** The regression this pins shipped and was reported from a phone within the
    /// hour: the handler routed through `SessionStore.createFromMenu`, which is the menu bar's
    /// entry point and chooses a directory itself — the active tab's, else the last active
    /// project — because a menu click carries no project with it. A tap on the phone does
    /// carry one, and it was being thrown away.
    ///
    /// Asserted through the socket rather than against the store directly, because the
    /// discarded argument was in the wire handler and a store-level test could not have seen
    /// it: `createFromMenu` did exactly what it says on its own tin.
    func testANewSessionFromThePhoneLandsInTheProjectItNamed() async throws {
        let (store, _, key, port) = try await standUpWithALogin()
        // Two projects, and the Mac's selection deliberately parked in the WRONG one — which
        // is the state that made the bug visible and the state a phone is normally used in.
        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        store.selectSession(elsewhere.id)

        let target = try XCTUnwrap(
            store.repos.first { $0.url.path == "/w/target" },
            "the project the phone will name"
        )
        let before = target.sessions.count

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            // **Agent and account index, not a bare project.** Both nil takes the default
            // path, which was never broken — the discarded project was on the menu-row path,
            // so a test that sends nothing here passes without touching the fix.
            if case .snapshot = frame {
                _ = client.send(.newSession(project: target.id, agent: "claude", accountIndex: 0))
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        let after = try XCTUnwrap(store.repos.first { $0.url.path == "/w/target" })
        XCTAssertEqual(after.sessions.count, before + 1, "the tab belongs to the project tapped")
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/w/elsewhere" }?.sessions.count, 1,
            "and not to whichever project the Mac happened to have selected"
        )
    }

    func testACommandNamingASessionThatIsGoneIsRefusedNotIgnored() async throws {
        let (_, key, port) = try await standUp()
        let refused = expectation(description: "err")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.markRead(id: UUID())) }
            if case .err(_, "unknown_session") = frame { refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
    }

    /// A stub the display guard treats as asleep — same shape as `DisplayDrawableGuardTests`'s
    /// own `Display`, redeclared here rather than shared because both files already keep their
    /// own private test doubles.
    private struct Display: DisplayInspecting { var isDrawable: Bool }

    /// `.newSession` was answered from `SessionStore.canCreateTerminal` at the wire handler
    /// (`FleetService.swift`'s `"terminal_unavailable"` code) with no test ever having sent the
    /// command that reaches it — `DisplayDrawableGuardTests` covers the store-level guard, but
    /// nothing covered the phone actually being told about a refusal. A provider is required:
    /// with none, `canCreateTerminal` is unconditionally true and this command would succeed.
    func testANewSessionFromThePhoneIsRefusedWhenTheDisplayCannotBeDrawnTo() async throws {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.display = Display(isDrawable: true)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let project = try XCTUnwrap(store.repos.first?.id)
        // Flipped only after the project exists: the guard under test is `canCreateTerminal`,
        // not the project lookup that runs ahead of it in the handler.
        store.display = Display(isDrawable: false)

        let harness = FleetTestHarness(store: store)
        self.harness = harness
        self.service = harness.service
        let (_, key, port) = (harness.store, harness.key, try await harness.start())

        let refused = expectation(description: "err")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.newSession(project: project, agent: nil, accountIndex: nil))
            }
            if case .err(_, "terminal_unavailable") = frame { refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(store.repos.first?.sessions.count, 1, "no second tab was created")
    }

    /// A stub the display guard can flip mid-test — `Display` above is a `let`-only struct,
    /// which cannot express "becomes drawable once woken" from inside a `DisplayWaking`.
    private final class MutableDisplay: DisplayInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _drawable: Bool
        init(_ drawable: Bool) { _drawable = drawable }
        var isDrawable: Bool { lock.lock(); defer { lock.unlock() }; return _drawable }
        func set(_ v: Bool) { lock.lock(); _drawable = v; lock.unlock() }
    }

    /// A waker that succeeds and, like the real one, leaves the display actually drawable —
    /// same shape as `DisplayWakeTests`'s own `Waker`, redeclared here rather than shared for
    /// the same reason `Display` above is. Flipping `display` on success matters here and not
    /// just in `DisplayWakeTests`: `store.newSession(inProject:)` calls `ensureTerminalCreatable`
    /// again internally, and a waker that returned `true` without making `isDrawable` true
    /// would be woken twice for one tap.
    private final class Waker: DisplayWaking, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private let onWake: @Sendable () -> Void
        init(onWake: @escaping @Sendable () -> Void) { self.onWake = onWake }
        func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
            lock.lock(); _calls += 1; lock.unlock()
            onWake()
            return true
        }
    }

    /// The companion to the refusal above: a phone `+` reaching an asleep display must
    /// attempt a wake, not refuse outright — this is `Finding 1`'s regression test.
    /// `ensureTerminalCreatable`, not `canCreateTerminal`, is what the handler must call, and
    /// a `Waker` that always succeeds is what tells the two apart: with `canCreateTerminal`
    /// still read directly, this display never becomes drawable and the phone gets refused.
    func testANewSessionFromThePhoneWakesTheDisplayAndSucceeds() async throws {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.display = Display(isDrawable: true)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let project = try XCTUnwrap(store.repos.first?.id)
        // Flipped only after the project exists, same as the refusal test above.
        let display = MutableDisplay(false)
        store.display = display
        let waker = Waker(onWake: { display.set(true) })
        store.displayWaker = waker

        let harness = FleetTestHarness(store: store)
        self.harness = harness
        self.service = harness.service
        let (_, key, port) = (harness.store, harness.key, try await harness.start())

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.newSession(project: project, agent: nil, accountIndex: nil))
            }
            if case .err(_, "terminal_unavailable") = frame {
                XCTFail("a display that can be woken must not be refused")
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)
        XCTAssertEqual(waker.calls, 1)
        XCTAssertEqual(store.repos.first?.sessions.count, 2, "the woken display got its tab")
    }
}
