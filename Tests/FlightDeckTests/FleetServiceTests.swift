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

    /// `WireSearchHits.indexing` must reflect whatever backfill `FleetService.indexingProgress`
    /// currently holds, and must be `nil` the instant nothing is running — reporting `0 of 0`
    /// permanently would put a meaningless footer on the phone. `store.searchIndex` is nil in
    /// this harness, so every reply's `hits` is empty regardless of query; this exercises only
    /// the progress plumbing, not the index itself.
    func testASearchReplyCarriesIndexingProgressWhileABackfillIsInFlightAndNilOtherwise() async throws {
        let (_, key, port) = try await standUp()

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
}
