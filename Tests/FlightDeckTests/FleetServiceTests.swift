import Combine
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

    /// A waker that fails the test the moment it is asked to do anything, for a test whose
    /// entire point is that it must never be reached.
    private final class MustNotBeCalledWaker: DisplayWaking, @unchecked Sendable {
        func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
            XCTFail("an unknown project must be refused before any wake is attempted")
            return false
        }
        func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool {
            XCTFail("an unknown project must be refused before any wake is attempted")
            return false
        }
    }

    /// **The ordering `apply`'s own `.newSession` arm documents — "after the project lookup,
    /// so an unknown project still says so rather than being masked by this" — must survive
    /// `onCommand`'s deferral too.** Without the project gated alongside `canCreateTerminal`
    /// in `FleetService.onCommand`, a stale phone snapshot naming a project the Mac has since
    /// closed would, on a sleeping display, physically wake the screen for a command that was
    /// always going to be refused, and would answer `terminal_unavailable` instead of
    /// `unknown_project` if the wake happened to fail — exactly the masking that comment
    /// forbids. A provider is required, same reason as the test above: with none,
    /// `canCreateTerminal` is unconditionally true and this display state would never gate
    /// anything.
    func testANewSessionForAnUnknownProjectWithTheDisplayAsleepAnswersUnknownProjectNotTerminalUnavailable() async throws {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.display = Display(isDrawable: false)
        store.displayWaker = MustNotBeCalledWaker()

        let harness = FleetTestHarness(store: store)
        self.harness = harness
        self.service = harness.service
        let (_, key, port) = (harness.store, harness.key, try await harness.start())

        let refused = expectation(description: "unknown_project")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                // No project in this store has this id — `store.repos` was never seeded.
                _ = client.send(.newSession(project: UUID(), agent: nil, accountIndex: nil))
            }
            if case .err(_, let code) = frame {
                XCTAssertEqual(code, "unknown_project")
                refused.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
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
        // The phone's `.newSession` reaches `awaitTerminalCreatable`, which calls this
        // overload, not the sync one above — so this is the one the test below actually
        // exercises. Both are kept in sync (pun unavoidable) since `DisplayWaking` requires
        // both and nothing here needs them to differ.
        func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool {
            lock.lock(); _calls += 1; lock.unlock()
            onWake()
            return true
        }
    }

    /// The companion to the refusal above: a phone `+` reaching an asleep display must
    /// attempt a wake, not refuse outright — this is `Finding 1`'s regression test.
    /// `onCommand`'s gate reads `canCreateTerminal` only to decide whether a wake is worth
    /// attempting; it is `awaitTerminalCreatable` that must actually be called, and a `Waker`
    /// that always succeeds is what tells the two apart: a handler that stopped there,
    /// content with the plain read, would never make this display drawable and the phone
    /// would still be refused.
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

    /// A waker whose async twin genuinely awaits before flipping the display, rather than
    /// resolving on the calling turn the way `Waker` above does. This is the case
    /// `onCommand`'s reply-callback shape exists for: the sync twin is never called here, so a
    /// test that passed only because `await` happened to resolve immediately would not tell
    /// the two apart.
    private final class SlowWaker: DisplayWaking, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private let onWake: @Sendable () -> Void
        init(onWake: @escaping @Sendable () -> Void) { self.onWake = onWake }
        func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
            XCTFail("the phone's creation path must use the async twin, never the blocking one")
            return false
        }
        func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool {
            lock.lock(); _calls += 1; lock.unlock()
            try? await Task.sleep(nanoseconds: 20_000_000)
            onWake()
            return true
        }
    }

    /// The point of Task 1: a slow wake must not block anything, and the phone still gets
    /// answered once it completes. `SlowWaker` genuinely suspends inside its async twin, so
    /// this fails against an `onCommand` shape that cannot answer after an `await` — the
    /// return-value shape that preceded the reply-callback one — the same way it would fail
    /// if the handler still called the synchronous `wakeAndWaitForDrawable`.
    func testANewSessionFromThePhoneAwaitsASlowWakeAndStillSucceeds() async throws {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.display = Display(isDrawable: true)
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let project = try XCTUnwrap(store.repos.first?.id)
        // Flipped only after the project exists, same as the tests above.
        let display = MutableDisplay(false)
        store.display = display
        let waker = SlowWaker(onWake: { display.set(true) })
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

    /// **The wire half of the same bug `OpenConversationTests` pins at the store level.** With
    /// the Mac already sitting on an unrelated tab, `search.open` for a conversation whose
    /// account assignment is dangling must come back `err(launch_failed)` — never
    /// `session(cid:, id)` naming the tab that merely happened to be selected beforehand. The
    /// earlier shape here read `store.selectedSessionID` after the call and would have replied
    /// with `elsewhere`'s id on exactly this path; this test fails against that shape and
    /// passes against `FleetService.openConversation`'s `Result`-based one.
    ///
    /// Built by hand rather than through `FleetTestHarness`/`standUp()`: those wire the
    /// `PreferencesStore` only to `FleetService`, not to the `SessionStore` underneath it
    /// (`SessionStore(provider:persistence:)` leaves `preferences` at its default `nil`), so
    /// `launchAccount` takes its `guard let preferences else { return .success(nil) }` escape
    /// and a dangling assignment can never be reached at all. This fixture wires the same
    /// `PreferencesStore` into both, the way the real app does.
    func testAnOpenConversationRequestWhoseLaunchFailsIsRefusedNotConfusedWithAPreviouslySelectedTab() async throws {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedProjectSettings = [
            "/w/alpha": ProjectSettings(accounts: [.claude: UUID()])
        ]
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        let key = FleetDeviceKey.mint()
        preferences.upsert(
            PairedDevice(slot: key.slot, name: "test device", secret: key.secret,
                        pairedAt: Date(), lastSeenAt: nil, armedUntil: nil)
        )
        let service = FleetService(store: store, preferences: preferences, armer: PairingArmer())
        self.service = service
        let port = try await service.start(port: nil)

        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        store.selectSession(elsewhere.id)

        let conversation = UUID()
        let refused = expectation(description: "err")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.openConversation(
                    conversationID: conversation.uuidString, projectPath: "/w/alpha"
                ))
            }
            if case .session = frame {
                XCTFail("a refused launch must never be reported as a session")
            }
            if case .err(_, "launch_failed") = frame { refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)

        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "selection is untouched by the refusal — the previously-selected tab a stale read would have named")
    }

    // MARK: - The client-selection rule: a command from a client never moves the desk's tab

    /// **The reported bug, at the wire.** With the Mac sitting on an unrelated tab, a phone `+`
    /// tap must file its tab without also reactivating it on the desktop — that yanks the desk's
    /// focus off whatever is on screen for a change nobody at the desk asked for. Asserting the
    /// tab really was created is what keeps this from passing on a silently swallowed command.
    func testANewSessionFromThePhoneLeavesTheDesksSelectionAlone() async throws {
        let (store, key, port) = try await standUp()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        store.selectSession(elsewhere.id)
        let project = try XCTUnwrap(store.repos.first { $0.url.path == "/w/target" }?.id)

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.newSession(project: project, agent: nil, accountIndex: nil))
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        XCTAssertEqual(
            store.repos.first { $0.url.path == "/w/target" }?.sessions.count, 2,
            "the phone's + really created a tab"
        )
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client's + must not move the desk's selection off elsewhere")
    }

    /// The same rule for the reported path itself: a phone reopening a tab must not reactivate
    /// it on the desktop. `store.repos` is checked to confirm the reopen actually happened —
    /// the failure mode this exists to catch is a selection assertion that would pass just as
    /// happily against a command that silently did nothing.
    func testAReopenFromThePhoneLeavesTheDesksSelectionAlone() async throws {
        let (store, key, port) = try await standUp()
        let closed = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        store.closeSession(closed.id)
        store.selectSession(elsewhere.id)

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.reopenClosed(session: closed.id))
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        XCTAssertTrue(store.repos.flatMap(\.sessions).contains { $0.id == closed.id },
                     "the phone's reopen really brought the tab back")
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client's reopen must not move the desk's selection off elsewhere")
    }

    /// **Where the bug actually lived.** `:448` above pins the refused half of `search.open`;
    /// this pins the successful half — a conversation resumed fresh, not merely selected among
    /// already-open tabs, which is the branch `SessionStore.openConversation` reaches for most
    /// phone searches.
    func testASuccessfulSearchOpenFromThePhoneLeavesTheDesksSelectionAlone() async throws {
        let (store, key, port) = try await standUp()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        store.selectSession(elsewhere.id)
        let conversation = UUID()

        let opened = expectation(description: "session")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.openConversation(
                    conversationID: conversation.uuidString, projectPath: "/w/alpha"
                ))
            }
            if case .err = frame { XCTFail("this launch must succeed") }
            if case .session = frame { opened.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [opened], timeout: 10)

        XCTAssertEqual(
            store.repos.first { $0.url.path == "/w/alpha" }?.sessions.count, 2,
            "the phone's search.open really resumed a tab"
        )
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client's search.open must not move the desk's selection off elsewhere")
    }

    /// **The judgement call, pinned so it cannot be simplified away.** With nothing selected on
    /// the Mac, there is no focus for a client action to steal, and the alternative is a sidebar
    /// showing tabs over an empty pane — so a client action selects anyway, exactly as a desk
    /// action would.
    func testANewSessionFromThePhoneSelectsWhenTheDeskHasNoSelection() async throws {
        let (store, key, port) = try await standUp()
        _ = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        store.selectedSessionID = nil
        let project = try XCTUnwrap(store.repos.first?.id)

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.newSession(project: project, agent: nil, accountIndex: nil))
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        let created = try XCTUnwrap(store.repos.first?.sessions.last, "the phone's + really created a tab")
        XCTAssertEqual(store.selectedSessionID, created.id,
                       "a client action selects when nothing else has focus to steal")
    }

    /// **The second, riding-along behaviour change.** Not selecting also means not marking
    /// read — `selectedSessionID`'s `didSet` is what clears `unreadIdle`, so a reopen that
    /// leaves the desk's selection alone must also leave the reopened tab's unread mark alone.
    /// `markUnread` seeds the mark directly (it does not require the session to be currently
    /// live), which is what lets this test isolate the read-state consequence from the reopen
    /// itself.
    func testAReopenFromThePhoneLeavesTheReopenedTabUnread() async throws {
        let (store, key, port) = try await standUp()
        let closed = store.newSession(in: URL(fileURLWithPath: "/w/target"))
        let elsewhere = store.newSession(in: URL(fileURLWithPath: "/w/elsewhere"))
        store.closeSession(closed.id)
        store.selectSession(elsewhere.id)
        store.markUnread(closed.id)
        XCTAssertTrue(store.unreadIdle.contains(closed.id), "fixture assumption")

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame {
                _ = client.send(.reopenClosed(session: closed.id))
            }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        XCTAssertTrue(store.repos.flatMap(\.sessions).contains { $0.id == closed.id },
                     "the phone's reopen really brought the tab back")
        XCTAssertTrue(store.unreadIdle.contains(closed.id),
                     "a phone reopen must not silently mark the tab read on the Mac")
    }

    /// `WireSearchHits.indexing` must reflect whatever backfill `FleetService.indexingProgress`
    /// currently holds, and must be `nil` the instant nothing is running — reporting `0 of 0`
    /// permanently would put a meaningless footer on the phone. A working `StubSearchIndex` is
    /// installed so the reply travels the `.searchHits` path at all — see
    /// `testASearchRequestWithNoIndexIsRefusedRatherThanAnsweredEmpty` below for the nil case,
    /// which this test used to (wrongly) share a harness with; this one exercises only the
    /// progress plumbing, not the index itself.
    func testASearchReplyCarriesIndexingProgressWhileABackfillIsInFlightAndNilOtherwise() async throws {
        let (store, key, port) = try await standUp()
        store.searchIndex = StubSearchIndex()

        let inFlight = expectation(description: "in flight")
        var duringBackfill: WireIndexingProgress?
        service?.indexingProgress = SearchIndexBuilder.Progress(indexed: 312, total: 484)
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.search(query: "hello", limit: 10)) }
            if case .searchHits(_, let hits) = frame {
                duringBackfill = hits.indexing
                inFlight.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [inFlight], timeout: 10)
        XCTAssertEqual(duringBackfill, WireIndexingProgress(done: 312, total: 484))

        // The backfill finishes: `AppDelegate` clears the progress the same way it does at
        // the end of `SearchIndexBuilder.build`.
        service?.indexingProgress = nil
        let afterwards = expectation(description: "afterwards")
        var afterBackfill: WireIndexingProgress? = WireIndexingProgress(done: 1, total: 1)
        client.onFrame = { frame in
            if case .searchHits(_, let hits) = frame {
                afterBackfill = hits.indexing
                afterwards.fulfill()
            }
        }
        _ = client.send(.search(query: "hello", limit: 10))
        await fulfillment(of: [afterwards], timeout: 10)
        XCTAssertNil(afterBackfill, "an absent backfill must not leave a stale footer on screen")
    }

    // MARK: An unavailable index must be refused, never answered as empty

    /// **The regression this exists for.** `try? store.searchIndex?.search(...) ?? []`
    /// collapsed "no index open" into an empty hit list, which `SessionSearchModel.apply`
    /// reads as `.empty` and renders as "No Results" — a claim about the corpus the Mac is in
    /// no position to make (spec §9), reachable for the life of the process whenever
    /// `AppDelegate`'s `try? SQLiteSearchIndex(at:)` fails. `store.searchIndex` is nil by
    /// default in this harness — nothing needs to be configured to reach it. This test would
    /// fail against the old `try?`-collapsing line, which answered `.searchHits(hits: [])`
    /// here instead of refusing.
    func testASearchRequestWithNoIndexIsRefusedRatherThanAnsweredEmpty() async throws {
        let (_, key, port) = try await standUp()

        let arrived = expectation(description: "reply")
        var reply: ServerFrame?
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.search(query: "hello", limit: 10)) }
            if case .searchHits = frame { reply = frame; arrived.fulfill() }
            if case .err = frame { reply = frame; arrived.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [arrived], timeout: 10)

        guard case .err(_, let code) = reply else {
            return XCTFail("a search with no index must be refused, not answered: \(String(describing: reply))")
        }
        XCTAssertEqual(code, "index_unavailable")
    }

    /// The other half of the same collapse: an index that is open but whose read itself
    /// throws — a locked or corrupt file — must be refused the same way as no index at all,
    /// not answered with whatever `try?` happened to swallow into `[]`.
    func testASearchRequestWhenTheIndexThrowsIsRefusedRatherThanAnsweredEmpty() async throws {
        let (store, key, port) = try await standUp()
        let index = StubSearchIndex()
        index.shouldThrow = true
        store.searchIndex = index

        let arrived = expectation(description: "reply")
        var reply: ServerFrame?
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.search(query: "hello", limit: 10)) }
            if case .searchHits = frame { reply = frame; arrived.fulfill() }
            if case .err = frame { reply = frame; arrived.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [arrived], timeout: 10)

        guard case .err(_, let code) = reply else {
            return XCTFail("a throwing index must be refused, not answered: \(String(describing: reply))")
        }
        XCTAssertEqual(code, "index_unavailable")
    }

    /// The same collapse existed in `conversationCatalogue()`, with the milder consequence the
    /// finding names — the name half of search silently loses all history — but it is the
    /// identical lie: an empty catalogue reads as "the Mac has no history for you at all"
    /// rather than "the Mac could not read its index right now".
    func testAConversationsRequestWithNoIndexIsRefusedRatherThanAnsweredEmpty() async throws {
        let (_, key, port) = try await standUp()

        let arrived = expectation(description: "reply")
        var reply: ServerFrame?
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.conversations) }
            if case .conversations = frame { reply = frame; arrived.fulfill() }
            if case .err = frame { reply = frame; arrived.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [arrived], timeout: 10)

        guard case .err(_, let code) = reply else {
            return XCTFail("a conversations request with no index must be refused, not answered: \(String(describing: reply))")
        }
        XCTAssertEqual(code, "index_unavailable")
    }

    // MARK: Phone presence

    /// **A viewer must lose its badge when ITS connection goes, not only when the last phone
    /// on the Mac disconnects.**
    ///
    /// `viewingByClient` is keyed by connection id, and the `.viewing` handler says why in as
    /// many words: "one phone reconnecting is two connections". The prune did not agree — it
    /// was `if slots.isEmpty { removeAll() }`, which fires only when the very last attachment
    /// goes, so any client that left while another stayed attached kept its entry forever.
    ///
    /// That is not a corner case; it is every wake of every phone. The handset rebuilds its
    /// connector on returning from the background (`RedialOnReturn` on the iOS side), so the
    /// old connection dies and a new one arrives with a new id — and with a second phone
    /// attached, or simply with the new connection landing before the old one is reaped,
    /// `slots` never passes through empty. The Mac went on drawing "a phone is viewing this
    /// session" for a connection that no longer existed.
    ///
    /// **Two distinct paired devices, and the SECOND one is the one dropped.** Two same-slot
    /// connections viewing different sessions would still discriminate a per-client prune from
    /// a per-slot one — per-client drops only the dead connection's session; a slot with
    /// another connection still attached would look untouched to a per-slot prune, and the
    /// dead one's session would stay. The two strategies collapse into each other only when
    /// both connections on the same slot are viewing the same session, which is not the case
    /// worth isolating here. Two distinct devices sidesteps the slot question entirely, and
    /// dropping the second rather than the first is the same care
    /// `FleetSlotAttributionTests.testDroppingOneDeviceLeavesTheOtherOnItsOwnSlot` takes, for
    /// the same reason — a wrong implementation that recomputes from the last-registered
    /// client happens to look right when you drop the first.
    ///
    /// No sessions are created in the store: the `.viewing` handler deliberately has no
    /// `sessionExists` guard, so two bare UUIDs are the honest fixture.
    func testPresenceDropsWithItsOwnClientAndLeavesTheOtherViewerAlone() async throws {
        let preferences = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        let staying = FleetDeviceKey.mint()
        let leaving = FleetDeviceKey.mint()
        for key in [staying, leaving] {
            preferences.upsert(PairedDevice(
                slot: key.slot, name: "phone", secret: key.secret,
                pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
            ))
        }
        let service = FleetService(store: store, preferences: preferences, armer: PairingArmer())
        self.service = service
        let port = try await service.start(port: nil)

        let watched = UUID()
        let abandoned = UUID()

        // Sequenced rather than raced, so "the second device" is unambiguous.
        let stayingClient = viewer(staying, viewing: watched, port: port)
        self.client = stayingClient
        await presence(on: service, reaches: "the first viewer") { $0.contains(watched) }

        let leavingClient = viewer(leaving, viewing: abandoned, port: port)
        await presence(on: service, reaches: "the second viewer") { $0.contains(abandoned) }

        XCTAssertEqual(service.phoneActiveSessions, [watched, abandoned],
                       "the premise: two phones, each on its own session")

        leavingClient.disconnect()
        await presence(on: service, reaches: "the departed viewer pruned") { !$0.contains(abandoned) }

        XCTAssertEqual(
            service.phoneActiveSessions, [watched],
            "only the client that left loses its badge — the phone still attached is still watching"
        )
    }

    /// A client that reports itself viewing `session` the moment it is attached.
    private func viewer(
        _ key: FleetDeviceKey, viewing session: UUID, port: NWEndpoint.Port
    ) -> FleetClient {
        let client = FleetClient(key: key)
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.viewing(session: session)) }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        return client
    }

    /// Waits for `phoneActiveSessions` to satisfy `predicate`.
    ///
    /// Checked once up front as well as subscribed, because `@Published` emits on `willSet`:
    /// a state already reached before the sink is installed produces no further element, and
    /// waiting for one that will never come is a ten-second timeout rather than a pass.
    private func presence(
        on service: FleetService, reaches description: String,
        _ predicate: @escaping @Sendable (Set<UUID>) -> Bool
    ) async {
        if predicate(service.phoneActiveSessions) { return }
        let met = expectation(description: description)
        // The predicate can be satisfied by more than one publish — a second phone attaching
        // after the first already matched — and an over-fulfilled expectation is a failure.
        met.assertForOverFulfill = false
        let token = service.$phoneActiveSessions.sink { if predicate($0) { met.fulfill() } }
        await fulfillment(of: [met], timeout: 10)
        token.cancel()
    }
}

/// A minimal `SearchIndex` for exercising `FleetService`'s wiring without a real SQLite file.
/// `shouldThrow` flips `search`/`conversationNames` into throwing, the shape a corrupt or
/// mid-migration index takes — the state `FleetService`'s `try? index.search(...)` must turn
/// into `index_unavailable` rather than an empty answer.
private final class StubSearchIndex: SearchIndex {
    var hits: [TranscriptHit] = []
    var conversations: [String: IndexedConversation] = [:]
    var shouldThrow = false

    func ingest(_: [IndexedMessage], from: URL, projectPath: String, offset: UInt64?) throws {}
    func readOffset(for: URL) -> UInt64 { 0 }
    func setConversationName(_: String, projectPath: String, for: String) throws {}
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws {}
    func messageCount(forConversation: String) throws -> Int { 0 }

    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
        if shouldThrow { throw StubSearchIndexError.boom }
        return hits
    }

    func conversationNames() throws -> [String: IndexedConversation] {
        if shouldThrow { throw StubSearchIndexError.boom }
        return conversations
    }
}

private enum StubSearchIndexError: Error { case boom }
