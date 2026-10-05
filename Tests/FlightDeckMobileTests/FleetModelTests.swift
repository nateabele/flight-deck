import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A store that refuses every write, standing in for the two keychain failures seen for real:
/// a build with no access group (`errSecMissingEntitlement`, -34018) and a device that has
/// not been unlocked since boot. `InMemoryPairedMacStore` cannot express either — its `save`
/// does not throw at all — which is why the failing half lives here.
private final class RefusingPairedMacStore: PairedMacStoring {
    static let status: OSStatus = -34018
    private(set) var saveAttempts = 0

    func load() -> PairedMac? { nil }

    func save(_ mac: PairedMac) throws {
        saveAttempts += 1
        throw PairedMacStoreError.keychainWriteFailed(status: Self.status)
    }

    func clear() {}
}

@MainActor
final class FleetModelTests: XCTestCase {
    /// The QR path. A pairing that exists only in memory looks exactly like a working one —
    /// the fleet arrives, the list fills in — right up until the next launch, when `load()`
    /// returns nil and the phone is back at the pairing screen with nothing to explain why.
    /// So the save has to come first and its failure has to abort: `mac` staying `nil` is the
    /// assertion that matters, and the thrown status is what the screen puts on the screen.
    func testAdoptingAScannedCodeSurfacesAKeychainFailureInsteadOfPairingAnyway() {
        let store = RefusingPairedMacStore()
        let model = FleetModel(store: store)

        XCTAssertThrowsError(try model.adopt(code: Self.scannableCode())) { error in
            XCTAssertEqual(
                error as? PairedMacStoreError,
                .keychainWriteFailed(status: RefusingPairedMacStore.status)
            )
        }
        XCTAssertEqual(store.saveAttempts, 1)
        XCTAssertNil(model.mac, "a pairing that could not be stored must not look adopted")
    }

    /// The typed path's completion, where the same failure cannot be thrown — the SPAKE2
    /// exchange has already succeeded by the time this runs, on a callback nobody can `try`.
    /// It has to become copy instead, and the status has to survive into it: -34018 is a
    /// developer problem and `errSecInteractionNotAllowed` is not, and the number is the only
    /// thing that tells them apart.
    func testTypedPairingReportsAKeychainFailureInsteadOfLookingPaired() {
        let store = RefusingPairedMacStore()
        let model = FleetModel(store: store)

        model.adopt(key: .mint(), serviceName: "Studio._flightdeck._tcp", macName: "Studio")

        XCTAssertNil(model.mac, "a pairing that could not be stored must not look adopted")
        XCTAssertEqual(
            model.pairingFailure,
            "Couldn't save this pairing to the keychain (error -34018)."
        )
    }

    /// Two failures, opposite instructions. `.wrongCode` sends the user back to the keyboard;
    /// `.attemptsExhausted` says that Mac's window is burned and only a new code will do.
    /// Swapping them spends one of three tries teaching the user nothing — and neither string
    /// is reachable from the Mac's side, so nothing but this notices.
    func testWrongCodeAndExhaustedAttemptsSendTheUserInOppositeDirections() {
        XCTAssertEqual(
            FleetModel.message(for: .wrongCode),
            "No Mac on this network accepted that code. Check it against your Mac's screen."
        )
        XCTAssertEqual(
            FleetModel.message(for: .attemptsExhausted),
            "Too many tries. Show a new code on your Mac and start again."
        )
    }

    /// The other two are distinct for the same reason: one sends the user to the network and
    /// one to the App Store, and a single "pairing failed" for all four would send them
    /// nowhere. Asserted as four distinct strings rather than four literals, so this keeps
    /// working when the copy is reworded and stops working when two branches collapse.
    ///
    /// **Driven off `CaseIterable`, not a hand-written list.** The list version passed for
    /// however long it took someone to add a case and forget this file, which is the only way
    /// this property ever breaks. Enumerating the type means a new failure with no copy of its
    /// own fails here the moment it exists.
    func testEveryPairingFailureGetsItsOwnMessage() {
        let all = PairingInitiator.Failure.allCases
        let messages = all.map(FleetModel.message(for:))

        XCTAssertEqual(
            Set(messages).count, all.count,
            "two failures share one message: \(zip(all, messages).map { "\($0) -> \($1)" })"
        )
        XCTAssertFalse(messages.contains(where: \.isEmpty))
    }

    /// **The specific collapse that cost a day, pinned so it cannot come back.**
    ///
    /// `noAnswer` means the connection came UP and the Mac did not reply — so the network is
    /// demonstrably working, and telling the user to check their Wi-Fi points away from the
    /// fault. That is exactly what happened: a listener that accepted the connection and never
    /// answered read as "Couldn't reach that Mac. Check you're both on the same Wi-Fi." on a
    /// phone that could ping the Mac, and the real cause took packet captures to find.
    func testTheNoAnswerCaseDoesNotBlameTheNetwork() {
        let message = FleetModel.message(for: .noAnswer)
        XCTAssertFalse(message.lowercased().contains("wi-fi"),
                       "the connection succeeded; Wi-Fi advice sends the user the wrong way")
        XCTAssertFalse(message.lowercased().contains("couldn't reach"),
                       "it WAS reached — that is what distinguishes this from .unreachable")
        XCTAssertTrue(message.lowercased().contains("blocking")
                        || message.lowercased().contains("busy"),
                      "say what it could actually be")
    }

    /// The history channel's one entry point from the phone, and the only thing it must never
    /// do is nothing. A request has no second channel — a command's effect comes back as a
    /// northbound event, so dropping one is merely ineffective, while dropping a request is a
    /// screen spinning on a page that will never arrive. With no paired Mac there is no
    /// connector to forward to, so the refusal has to be manufactured here, and it has to
    /// arrive **before this call returns**: `SessionTimelineModel` arms its deadline ahead of
    /// the request precisely because this completion can run inside the frame that started it.
    func testAskingForAPageWithNothingConnectedIsRefusedBeforeTheCallReturns() {
        let model = FleetModel(store: RefusingPairedMacStore())
        var answer: Result<TimelinePage, FleetRequestError>?

        model.timelinePage(.timeline(session: UUID(), anchor: .latest, limit: 40)) {
            answer = $0
        }

        guard case .failure(let error)? = answer else {
            return XCTFail("a request with no connector answered \(String(describing: answer))")
        }
        XCTAssertEqual(error, .disconnected)
    }

    /// **The model behind a session screen is made once and kept**, and the reason is not
    /// bandwidth. A `navigationDestination` closure re-runs on any change to what it reads —
    /// a fleet event, a rename, the connection state — so a model constructed inside it would
    /// be a *new* model with an empty feed each time, and the conversation would empty itself
    /// under the reader while a poll or a status change ran in the background.
    func testOpeningASessionTwiceKeepsTheConversationThePhoneAlreadyHolds() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let session = UUID()

        XCTAssertTrue(
            model.timelineModel(for: session) === model.timelineModel(for: session),
            "a second visit to the same session must find the pages it already downloaded"
        )
        XCTAssertFalse(
            model.timelineModel(for: session) === model.timelineModel(for: UUID()),
            "and two sessions must not share one feed"
        )
    }

    /// Held conversation content is as much "this pairing" as the fleet snapshot is: a phone
    /// that unpaired and kept a transcript in memory is showing the user something they
    /// believe they revoked. The `phase` is what proves the old model was carrying state — it
    /// only reaches `.failed` because this model asked for a page and was refused.
    func testUnpairingDropsHeldConversationsRatherThanKeepingThemInMemory() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let session = UUID()
        let before = model.timelineModel(for: session)
        before.loadLatest()
        XCTAssertEqual(before.phase, .failed("Not connected to your Mac."),
                       "the premise: this model is holding something")

        model.unpair()

        let after = model.timelineModel(for: session)
        XCTAssertFalse(before === after, "the revoked pairing's transcript is still in memory")
        XCTAssertEqual(after.phase, .idle)
    }

    /// **Privacy, not memory — the disk half of the test above.** A spilled body is transcript
    /// text too, only parked under `Caches` instead of in memory, and `unpair()` must not leave
    /// a plaintext copy of a revoked pairing's conversation sitting there merely because it
    /// happened to be paged out at the moment of unpairing.
    ///
    /// `timelineModel(for:)` builds its `SessionTimelineModel` with no `spillDirectory`
    /// override — the app never passes one, only tests do — so there is no seam here to point
    /// at a temp directory instead. This exercises `TimelineSpillStore.purgeAll()`'s real
    /// default location directly, the same one `unpair()` calls it against, rather than only
    /// asserting the store's own `purgeAll(directory:)` behaves (see `TimelineSpillStoreTests`,
    /// which covers that half in an isolated temp directory).
    func testUnpairingRemovesAnySpilledTranscriptTextFromDisk() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let session = UUID()
        let store = TimelineSpillStore(session: session)
        store.write(["0#0": TimelineItem.Body(text: "leftover transcript")])
        defer { store.purge() }
        XCTAssertFalse(store.read(["0#0"]).isEmpty, "the premise: something is actually on disk")

        model.unpair()

        XCTAssertTrue(TimelineSpillStore(session: session).read(["0#0"]).isEmpty,
                      "unpairing must not leave a revoked pairing's transcript on disk")
    }

    /// **Bounded, for the same reason `timelineModels` itself needs bounding.** A reader who
    /// opens more sessions than the cap must not keep every one of them resident — only the
    /// most-recently-viewed handful survive, and the rest are dropped for `timelineModel(for:)`
    /// to rebuild on reopen.
    func testOpeningManySessionsEvictsAllButTheMostRecentlyViewed() {
        let model = FleetModel(store: RefusingPairedMacStore())
        var ids: [UUID] = []
        for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) {
            let id = UUID(); ids.append(id)
            _ = model.timelineModel(for: id)
        }
        let kept = ids.suffix(FleetModel.maxKeptTimelineModels)
        for id in kept { XCTAssertFalse(model.evictedTimelineModelIDs.contains(id)) }
        for id in ids.prefix(3) { XCTAssertTrue(model.evictedTimelineModelIDs.contains(id)) }
    }

    /// A model is never dropped while it is holding something the reader was told is in
    /// flight — here, an outbox row that never got to retire because there is no connector to
    /// answer it. `fail` (not `dismiss`) is what a synchronous `.disconnected` produces, and it
    /// leaves the row present rather than removing it, so the outbox stays non-empty.
    func testAModelWithAnOutstandingOutboxEntryIsNotEvicted() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let sticky = UUID()
        let stickyModel = model.timelineModel(for: sticky)
        stickyModel.send("a message that will sit unacked with no connector")
        XCTAssertTrue(stickyModel.hasOutstandingWork, "the outbox holds an unretired entry")
        for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) { _ = model.timelineModel(for: UUID()) }
        XCTAssertFalse(model.evictedTimelineModelIDs.contains(sticky),
                       "a model with outstanding work is never evicted")
    }

    /// The other half of eviction: dropping a model must not be permanent. Reopening its id
    /// finds nothing resident, builds a fresh model exactly as a first open would, and clears
    /// the id from the evicted set — the same path `unpair()` leaves every id on before any of
    /// them is ever opened again.
    func testReopeningAnEvictedModelReturnsAFreshOne() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let first = UUID()
        let a = model.timelineModel(for: first)
        for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) { _ = model.timelineModel(for: UUID()) }
        XCTAssertTrue(model.evictedTimelineModelIDs.contains(first))
        let b = model.timelineModel(for: first)
        XCTAssertFalse(a === b, "a reopened evicted session gets a fresh model that re-fetches")
        XCTAssertFalse(model.evictedTimelineModelIDs.contains(first), "reopening un-evicts it")
    }

    /// More aggressive than the LRU cap: under a real memory warning there is no recency
    /// exemption at all, only on-screen and busy survive.
    func testAMemoryWarningEvictsEverythingButTheOnScreenAndBusyModels() {
        let model = FleetModel(store: RefusingPairedMacStore())
        let onScreen = UUID(), idle = UUID(), busy = UUID()
        model.timelineModel(for: onScreen).viewing(true)
        _ = model.timelineModel(for: idle)
        model.timelineModel(for: busy).send("stuck")   // outstanding work, no socket

        model.handleMemoryWarning()

        XCTAssertTrue(model.evictedTimelineModelIDs.contains(idle), "an idle off-screen model goes")
        XCTAssertFalse(model.evictedTimelineModelIDs.contains(onScreen), "the on-screen model stays")
        XCTAssertFalse(model.evictedTimelineModelIDs.contains(busy), "outstanding work stays")
    }

    /// A real `FD2-` code, minted here rather than checked in: `PairingPayload.encoded()` is
    /// the Mac's own encoder, so this exercises the decode `adopt(code:)` actually performs.
    private static func scannableCode() -> String {
        PairingPayload(
            key: .mint(), macName: "Studio",
            serviceName: "Studio._flightdeck._tcp", endpoints: []
        ).encoded()
    }

    // MARK: refresh-on-connect, not on every event

    /// **The wiring these three requests get, driven through a real socket rather than a fake
    /// `FleetConnector`.** `connector` is `private` on `FleetModel` and `FleetConnector` is a
    /// concrete class, so there is no protocol seam to substitute — `FleetListScreenTests`
    /// establishes the pattern this borrows: a real `FleetSocketServer` on loopback, standing
    /// in for the Mac, with the server's own `onRequest` tallying what actually went out.
    private var server: FleetSocketServer!

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    /// Tally of requests the phone actually sent, by kind. A class, not a captured `var`:
    /// `onRequest` runs on the server's own queue, not the test's, so a plain local would be a
    /// data race under Swift 6 — same reasoning as `FleetListScreenTests.Box`.
    private final class RequestTally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ request: FleetRequest) {
            lock.lock(); defer { lock.unlock() }
            counts[key(for: request), default: 0] += 1
        }

        func count(_ kind: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[kind, default: 0]
        }

        /// Every project a `newSessionOptions` request actually named, in the order asked —
        /// finer-grained than `count`, for asserting `.projectAdded` asked for the ONE new
        /// project rather than merely that the aggregate count went up by one.
        private var newSessionOptionsProjectsStorage: [UUID] = []
        func newSessionOptionsProjects() -> [UUID] {
            lock.lock(); defer { lock.unlock() }
            return newSessionOptionsProjectsStorage
        }

        private func key(for request: FleetRequest) -> String {
            switch request {
            case .newSessionOptions(let project):
                newSessionOptionsProjectsStorage.append(project)
                return "newSessionOptions"
            case .conversations: return "conversations"
            case .recentlyClosed: return "recentlyClosed"
            default: return "other"
            }
        }
    }

    /// A `FleetModel` connected to a real, in-process Mac, plus the tally of what it asked for.
    ///
    /// One project, so `newSessionOptions` — one request per project — lands at exactly one
    /// per connect rather than needing a per-project count of its own.
    private func connectedModel(tally: RequestTally) async throws -> FleetModel {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        self.server = server
        server.onHello = { _, _ in [.snapshot(seq: 0, fleet: Self.fleet, reason: .initial)] }
        server.onCommand = { _, cid, _, reply in reply(.ack(cid: cid)) }
        server.onRequest = { _, cid, request, reply in
            tally.record(request)
            switch request {
            case .newSessionOptions(let project):
                reply(.newSessionOptions(cid: cid, WireNewSessionOptions(project: project, options: [])))
            case .conversations:
                reply(.conversations(
                    cid: cid, WireConversationCatalogue(conversations: [], sessionActivity: [:])
                ))
            case .recentlyClosed:
                reply(.recentlyClosed(cid: cid, []))
            default:
                break
            }
        }
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        store.save(PairedMac(
            key: key, macName: "Studio", serviceName: "studio-tests._flightdeck._tcp",
            endpoints: ["127.0.0.1:\(port.rawValue)"]
        ))
        let model = FleetModel(store: store)

        try await waitUntil(timeout: 10) {
            model.fleet.projects.flatMap(\.sessions).count == 2
        }
        XCTAssertEqual(
            model.fleet.projects.flatMap(\.sessions).count, 2, "the fixture fleet never arrived"
        )
        return model
    }

    /// A sleep rather than a run-loop spin: this is an async context, and yielding the main
    /// actor is what lets the connector's own main-queue callbacks land at all — same reason
    /// `FleetListScreenTests`' deadline loops give.
    private func waitUntil(
        timeout: TimeInterval, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// **The bug this file exists to pin.** `activityChanged` and `unreadChanged` fire on every
    /// status tick and every read/unread flip — by far the most common fleet events — and used
    /// to hang off `onFleet`, which fires on every one of them. Each re-asked the Mac for the
    /// New Session menu, the whole conversation catalogue and the whole reopen stack: 50–114 KB
    /// and ~0.16s of phone CPU, measured, for nothing that had changed. Neither event can move
    /// any of the three, so the fix is that they must not ask again at all.
    func testActivityAndUnreadEventsIssueNoCatalogueOptionsOrClosedRequests() async throws {
        let tally = RequestTally()
        let model = try await connectedModel(tally: tally)
        try await waitUntil(timeout: 10) {
            tally.count("newSessionOptions") == 1 && tally.count("conversations") == 1
                && tally.count("recentlyClosed") == 1
        }
        let sessionID = model.fleet.projects.first?.sessions.first?.id ?? UUID()

        server.broadcast(.event(seq: 1, .activityChanged(
            id: sessionID, activity: "busy", waitingFor: nil,
            subagentCount: 0, hasBackgroundWork: false
        )))
        server.broadcast(.event(seq: 2, .unreadChanged(id: sessionID, isUnread: true)))
        // No deadline loop: the assertion is that nothing changes, so the only thing a wait
        // would buy is more time for a wrongly implemented refresh to sneak in before it runs.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(tally.count("newSessionOptions"), 1, "an activity/unread event must not re-ask for the New Session menu")
        XCTAssertEqual(tally.count("conversations"), 1, "an activity/unread event must not re-ask for the conversation catalogue")
        XCTAssertEqual(tally.count("recentlyClosed"), 1, "an activity/unread event must not re-ask for the reopen stack")
    }

    /// The other half: connecting must still ask for all three, exactly once — the fix must
    /// not become "never asks again" merely because the loop moved off `onFleet`.
    func testConnectingIssuesEachOfTheThreeRefreshesExactlyOnce() async throws {
        let tally = RequestTally()
        _ = try await connectedModel(tally: tally)

        try await waitUntil(timeout: 10) {
            tally.count("newSessionOptions") == 1 && tally.count("conversations") == 1
                && tally.count("recentlyClosed") == 1
        }
        XCTAssertEqual(tally.count("newSessionOptions"), 1)
        XCTAssertEqual(tally.count("conversations"), 1)
        XCTAssertEqual(tally.count("recentlyClosed"), 1)
    }

    /// `sessionAdded`/`sessionRemoved` are the only two events that can move the reopen stack,
    /// so they keep their own ask — unlike `activityChanged`/`unreadChanged` above — but must
    /// not drag the other two along with them: a tab closing is not a reason to re-ask for the
    /// New Session menu or the conversation catalogue.
    func testSessionRemovedIssuesOneClosedStackRequestAndNothingElse() async throws {
        let tally = RequestTally()
        let model = try await connectedModel(tally: tally)
        try await waitUntil(timeout: 10) {
            tally.count("newSessionOptions") == 1 && tally.count("conversations") == 1
                && tally.count("recentlyClosed") == 1
        }
        let sessionID = try XCTUnwrap(model.fleet.projects.first?.sessions.first?.id)

        server.broadcast(.event(seq: 1, .sessionRemoved(id: sessionID)))

        try await waitUntil(timeout: 10) { tally.count("recentlyClosed") == 2 }
        XCTAssertEqual(tally.count("recentlyClosed"), 2, "a closed tab must refresh the reopen stack")
        XCTAssertEqual(tally.count("newSessionOptions"), 1, "closing a tab must not re-ask for the New Session menu")
        XCTAssertEqual(tally.count("conversations"), 1, "closing a tab must not re-ask for the conversation catalogue")
    }

    /// **The regression the quiet-event fix introduced.** A project added mid-connection used
    /// to get its New Session menu on the next reconnect only — nothing else asks, since the
    /// rows derive from preferences and preferences emit no other event — so the `+` on a
    /// project that just appeared showed the default row until then. `.projectAdded` must ask
    /// for that ONE project, the same shape `sessionAdded`/`sessionRemoved` already get above,
    /// not drag `refreshConversations`/`refreshRecentlyClosed` along for a project that changed
    /// nothing either of them tracks.
    func testProjectAddedAsksForThatOneProjectsNewSessionOptionsAndNothingElse() async throws {
        let tally = RequestTally()
        let model = try await connectedModel(tally: tally)
        try await waitUntil(timeout: 10) {
            tally.count("newSessionOptions") == 1 && tally.count("conversations") == 1
                && tally.count("recentlyClosed") == 1
        }
        let newProject = WireProject(id: UUID(), name: "new", path: "/Users/me/new")

        server.broadcast(.event(seq: 1, .projectAdded(newProject, at: model.fleet.projects.count)))

        try await waitUntil(timeout: 10) { tally.count("newSessionOptions") == 2 }
        XCTAssertEqual(tally.count("newSessionOptions"), 2, "a new project must ask for its own New Session menu")
        XCTAssertEqual(
            tally.newSessionOptionsProjects().last, newProject.id,
            "the request must name the project that was just added, not re-sweep every project"
        )
        XCTAssertEqual(tally.count("conversations"), 1, "a new project must not re-ask for the conversation catalogue")
        XCTAssertEqual(tally.count("recentlyClosed"), 1, "a new project must not re-ask for the reopen stack")
    }

    /// One project, two sessions — enough for `newSessionOptions`' one-request-per-project
    /// count to be meaningful without needing a per-project tally of its own.
    private static let fleet = FleetSnapshot(projects: [
        WireProject(
            id: UUID(), name: "me", path: "/Users/me",
            sessions: [
                WireSession(id: UUID(), title: "Home", agent: "claude"),
                WireSession(id: UUID(), title: "session 2", agent: "claude"),
            ]
        )
    ])
}

/// Pause/Resume from the swarm card: the in-flight mark must always clear, and a failure must say so.
@MainActor
final class FleetModelSwarmCommandTests: XCTestCase {
    private var sent: [FleetCommand] = []
    private var pending: [(Result<Void, FleetRequestError>) -> Void] = []

    private func model(timeout: Duration = .seconds(60)) -> FleetModel {
        let m = FleetModel(store: RefusingPairedMacStore())
        m.swarmTimeout = timeout
        m.swarmSender = { [unowned self] command, done in sent.append(command); pending.append(done) }
        return m
    }

    func testPauseAndResumeSendTheirCommandsAndAckClears() {
        let m = model(); let project = UUID()
        m.setSwarmPaused(true, project: project)
        XCTAssertEqual(sent, [.swarmPause(project: project)])
        XCTAssertTrue(m.swarmInFlight.contains(project))
        m.setSwarmPaused(true, project: project)
        XCTAssertEqual(sent.count, 1, "a second tap before the ack is ignored")
        pending.removeFirst()(.success(()))
        XCTAssertTrue(m.swarmInFlight.isEmpty)
        XCTAssertNil(m.swarmMessages[project])
        m.setSwarmPaused(false, project: project)
        XCTAssertEqual(sent.last, .swarmResume(project: project))
    }

    func testFailureClearsInFlightAndSetsAnError() {
        let m = model(); let project = UUID()
        m.setSwarmPaused(true, project: project)
        pending.removeFirst()(.failure(.server(code: "not_allowed")))
        XCTAssertTrue(m.swarmInFlight.isEmpty)
        XCTAssertEqual(m.swarmMessages[project], CommandCopy.message(for: .server(code: "not_allowed")))
        m.setSwarmPaused(true, project: project)
        XCTAssertNil(m.swarmMessages[project], "the next try clears the old message")
    }

    func testNoAnswerClearsAtTheDeadline() async {
        let m = model(timeout: .milliseconds(50)); let project = UUID()
        m.setSwarmPaused(true, project: project)
        for _ in 0..<100 where m.swarmInFlight.contains(project) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(m.swarmInFlight.isEmpty)
        XCTAssertEqual(m.swarmMessages[project], CommandCopy.message(for: nil))
    }

    /// A's late answer must not touch B: it arrives after A timed out and the user tapped again.
    func testALateAnswerToATimedOutSendDoesNotTouchTheNextSend() async {
        let m = model(timeout: .milliseconds(50)); let project = UUID()
        m.setSwarmPaused(true, project: project)
        for _ in 0..<100 where m.swarmInFlight.contains(project) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(m.swarmInFlight.isEmpty)

        m.swarmTimeout = .milliseconds(400)
        m.setSwarmPaused(false, project: project)
        XCTAssertNil(m.swarmMessages[project])
        pending.removeFirst()(.failure(.server(code: "not_allowed")))   // A, late
        XCTAssertTrue(m.swarmInFlight.contains(project), "A's answer must not clear B")
        XCTAssertNil(m.swarmMessages[project], "A's answer must not write B's message")

        for _ in 0..<100 where m.swarmInFlight.contains(project) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(m.swarmInFlight.isEmpty, "B's own deadline must still fire")
        XCTAssertEqual(m.swarmMessages[project], CommandCopy.message(for: nil))
    }

    func testTheCurrentSendsAnswerStillClears() async {
        let m = model(timeout: .milliseconds(50)); let project = UUID()
        m.setSwarmPaused(true, project: project)
        for _ in 0..<100 where m.swarmInFlight.contains(project) { try? await Task.sleep(for: .milliseconds(20)) }
        m.swarmTimeout = .seconds(60)
        m.setSwarmPaused(false, project: project)
        pending.removeFirst()(.success(()))   // A, late: ignored
        XCTAssertTrue(m.swarmInFlight.contains(project))
        pending.removeFirst()(.success(()))   // B
        XCTAssertTrue(m.swarmInFlight.isEmpty)
        XCTAssertNil(m.swarmMessages[project])
    }
}
