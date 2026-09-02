import Foundation
import Network

/// Finds the paired Mac and keeps a fleet in sync with it.
///
/// `@unchecked Sendable` for the same reason `FleetClient` is, and it is not optional here:
/// FleetKit builds in Swift 6 language mode, and this class hands `[weak self]` closures to
/// `DispatchQueue.asyncAfter` and `NWBrowser.browseResultsChangedHandler`, both of which are
/// typed `@Sendable`. Without the conformance those captures are a compile error. Every
/// mutation below happens on `queue` — the dials, the callbacks, the timers, the teardown —
/// so the state is confined to one queue rather than protected by locks, which is the same
/// idiom the rest of this module uses. Do not "fix" a concurrency diagnostic here by
/// sprinkling `nonisolated(unsafe)`; if something needs to touch this off `queue`, that is a
/// design change, not an annotation.
///
/// That confinement is a coincidence of `queue`'s default (`.main`, called from a
/// `@MainActor` consumer) unless it is actually enforced: `init` accepts any `DispatchQueue`,
/// and a caller that supplies a custom one while still calling `start()`/`stop()`/`send()`
/// from `@MainActor` would get real data races on `running`, `attempt`, `generation` and
/// `racers` — with zero compiler signal, since `@unchecked Sendable` is a promise, not a
/// check. `start()`, `stop()` and `send()` each assert
/// `dispatchPrecondition(condition: .onQueue(queue))` as their first line. `FleetSocketServer`
/// asserts the same condition but the other direction — at the sites where it invokes a
/// caller-supplied closure, to guarantee that closure lands on `queue` — because callers reach
/// it through `async` entry points instead of a queue-confined API; this class's public
/// methods are the queue-confined API, so the assertion belongs at their entry instead. (Any
/// test driving this class from `@MainActor` satisfies the default `.main` queue the same way
/// production's SwiftUI call sites do — `@MainActor`'s executor is the main dispatch queue.)
public final class FleetConnector: @unchecked Sendable {
    public enum State: Equatable {
        case idle
        case searching
        case connected(macName: String)
        case lost(retryingIn: TimeInterval)
    }

    public var onState: ((State) -> Void)?
    public var onFleet: ((FleetSnapshot) -> Void)?
    /// Each event as it lands, in addition to the folded snapshot `onFleet` publishes.
    ///
    /// Most events describe the fleet and are fully expressed by the snapshot, which is why
    /// this did not exist. `promptExpired` is the first that does not: it is addressed to one
    /// screen's outbox, which is not snapshot state, so folding it changes nothing and a
    /// client watching only `onFleet` would never learn its message was dropped.
    public var onEvent: ((FleetEvent) -> Void)?
    /// Fires once per applied snapshot, with the sequence it lands on and why it arrived.
    ///
    /// Separate from `onFleet`, which fires on snapshots *and* on every folded event, so it
    /// cannot tell a consumer which of the two it just saw. That distinction is the whole
    /// reason this exists: the phone's diagnostic log needs the counterpart to the Mac's own
    /// `resume lastSeq=… mode=…` line, and "I got a whole snapshot at seq N because my resume
    /// point was too old" is a different fact from "I applied one more event".
    ///
    /// Nothing branches on it. A consumer that made a decision here would be deciding on a
    /// signal `onFleet` already covers, one frame later.
    public var onSnapshot: ((_ seq: Int, _ reason: SnapshotReason) -> Void)?
    /// Answers a `PhoneRequest` the Mac asked of this phone, or `nil` when nothing is wired.
    ///
    /// **A closure the app supplies rather than something this class does**, because reading
    /// the phone's own log needs `OSLogStore` — and FleetKit imports Foundation, Network,
    /// Security and CryptoKit and nothing else, which is what the `FleetKitiOS` target exists
    /// to enforce. So the frame handling lives here and the reading lives in
    /// `FlightDeckMobile.PhoneLog`.
    ///
    /// `then` may be called on any queue and at any time; whatever it is handed is delivered
    /// on `queue`. Unwired, the Mac is answered `unhandled` — a refusal it can print, rather
    /// than a request that never comes back.
    public var onPhoneRequest: (
        (_ request: PhoneRequest,
         _ then: @escaping (Result<WirePhoneLogs, PhoneRequestRefusal>) -> Void) -> Void
    )?
    /// Backoff between races; the last value repeats. Settable so tests do not wait it out.
    public var retryDelays: [TimeInterval] = [1, 2, 5, 15, 30]
    /// How long a race may run before it is abandoned and retried. Well short of a TCP
    /// connect timeout on purpose — a stale candidate must not hold the whole race open for
    /// a minute when a live one might appear on the next attempt.
    public var raceTimeout: TimeInterval = 8

    private struct Candidate {
        let description: String
        let endpoint: NWEndpoint
        /// Whether this candidate belongs in the remembered list. A Bonjour result does not:
        /// it is rediscovered every time and has no stable text form worth storing.
        let isRemembered: Bool
    }

    private var mac: PairedMac
    private let store: any PairedMacStoring
    /// Handed to every client this connector dials, so whichever candidate wins the race
    /// tells the Mac what this device calls itself. Injected for the reason `FleetClient`'s
    /// own property documents: `UIDevice` is not reachable from FleetKit.
    private let deviceName: String?
    private let browse: Bool
    private let queue: DispatchQueue

    private var racers: [String: FleetClient] = [:]
    private var winner: FleetClient?
    /// Outstanding requests, by correlation id.
    ///
    /// Every entry MUST be resolved exactly once — with a page, with an error, or with
    /// `.disconnected` when the socket goes away. A callback that never fires leaves the
    /// screen that made the request showing a spinner forever, with nothing on screen to say
    /// why. That is the same failure the stale-fleet banner exists to prevent, one layer
    /// down, and it is why `teardown()` drains this table rather than clearing it.
    ///
    /// The `cid` space is a `FleetClient`'s. `nextCID` is never reset — `connect()` does not
    /// touch it — so the restart at 1 on every new connection is THIS class's doing: `dial()`
    /// constructs a fresh client per candidate. The invariant therefore belongs here, not to
    /// `FleetClient`, and `testACidReusedByTheNextConnectionAnswersTheNewRequestOnly` asserts
    /// `cids == [1, 1]` so it cannot quietly stop being true.
    ///
    /// What keeps a reused number unambiguous is that no entry from an earlier connection is
    /// ever still here to be matched. `winner` is dropped in exactly two places, and both
    /// empty this table before anything can be filed against the next connection:
    /// `teardown()` drains it in the same breath, and `noteDisconnect()` reaches `teardown()`
    /// through `scheduleRetry()` — see the comment there for why that path is reachable
    /// whenever this one is. A frame from an earlier connection cannot arrive to be matched
    /// either: `FleetClient` gates `onFrame` on `hasEnded`, and `accept()` refuses a client
    /// that is neither a live racer nor the current winner.
    private var pending: [Int: (Result<TimelinePage, FleetRequestError>) -> Void] = [:]
    /// Outstanding **commands**, by correlation id, for callers that need to know the Mac
    /// heard them.
    ///
    /// A second table beside `pending` rather than a generic one, and it is safe because the
    /// two share a single `cid` space: `FleetClient.send` mints both verbs from one `nextCID`,
    /// deliberately (see its comment), so a number is filed in at most one of these and
    /// `apply` can try each in turn. A generic reply type would have meant retyping `pending`,
    /// widening `ServerFrame`, and touching every call site of a channel already shipped.
    ///
    /// Same exactly-once rule as `pending`, for a stronger reason: `send(_:)` without a
    /// completion drops silently when nothing is connected, which is harmless for `markRead`
    /// and is not harmless for a prompt. `drainPending()` empties this table too.
    private var pendingAcks: [Int: (Result<Void, FleetRequestError>) -> Void] = [:]

    /// The third table `apply(_:)`'s `.err` arm was written in anticipation of.
    ///
    /// A second answer type rather than a widened `pending`, on the same reasoning `pendingAcks`
    /// records: making the reply generic would mean retyping `pending`, widening every caller of
    /// a channel already shipped, and re-testing a history path this feature does not touch.
    /// One `cid` space still, so a number is filed in at most one of the three and `apply` can
    /// try each in turn. Drained with the others.
    private var pendingOptions: [Int: (Result<WireNewSessionOptions, FleetRequestError>) -> Void] = [:]
    /// A fourth answer type, on the same reasoning `pendingAcks` and `pendingOptions` give:
    /// one table per answer shape, all four sharing the single `cid` space `FleetClient.send`
    /// mints from, so a number is filed in at most one and `apply` tries each in turn.
    private var pendingEndpoints: [Int: (Result<[String], FleetRequestError>) -> Void] = [:]
    /// A fifth answer type, same reasoning as the four above: one table per shape, sharing
    /// the single `cid` space, so `apply` tries each in turn.
    private var pendingConversations: [Int: (Result<WireConversationCatalogue, FleetRequestError>) -> Void] = [:]
    /// A sixth answer type, same reasoning.
    private var pendingSearch: [Int: (Result<WireSearchHits, FleetRequestError>) -> Void] = [:]
    /// A seventh answer type, same reasoning.
    private var pendingSession: [Int: (Result<UUID, FleetRequestError>) -> Void] = [:]
    /// An eighth answer type, same reasoning as the seven above: one table per answer shape,
    /// all sharing the single `cid` space `FleetClient.send` mints from, so a number is filed
    /// in at most one and `apply` tries each in turn.
    private var pendingClosed: [Int: (Result<[WireClosedSession], FleetRequestError>) -> Void] = [:]
    private var browser: NWBrowser?
    private var fleet = FleetSnapshot.empty
    private var attempt = 0
    private var running = false
    /// Invalidates outstanding deferred work. `DispatchQueue.asyncAfter` cannot be
    /// cancelled, so every timer here has to recognise that it is stale rather than be
    /// stopped — it captures the generation current when it was scheduled and does nothing
    /// if the connector has moved on since. Bumped by EVERY transition, not just `race()`:
    /// a race timeout that fires during a backoff window would otherwise see an unchanged
    /// generation and retry on top of the retry already pending.
    private var generation = 0

    @discardableResult
    private func invalidateDeferredWork() -> Int {
        generation += 1
        return generation
    }

    public init(
        mac: PairedMac, store: any PairedMacStoring, deviceName: String? = nil,
        browse: Bool = true, queue: DispatchQueue = .main
    ) {
        self.mac = mac
        self.store = store
        self.deviceName = deviceName
        self.browse = browse
        self.queue = queue
    }

    /// Idempotent, defensively rather than because anything currently calls it twice.
    ///
    /// Without the guard, `start()` on a running connector re-enters `race()`, whose
    /// `teardown()` cancels every live racer just to redial the same candidates — and a frame
    /// already hopped onto `queue` from one of those cancelled clients can then land in
    /// `accept()` and be installed as `winner`, wedging the connector on a dead socket. That
    /// wedge is closed at three levels (here, in `accept()`'s liveness guard, and by
    /// `FleetClient` gating `onFrame` on `hasEnded`); this is the cheapest of the three and
    /// the one that stops the sequence starting.
    ///
    /// The phone reconnects by discarding the connector and building a new one rather than by
    /// re-calling `start()`, so today this guard never fires. It is here for the caller that
    /// does not know that yet.
    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !running else { return }
        running = true
        attempt = 0
        race()
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        running = false
        invalidateDeferredWork()
        teardown()
        report(.idle)
    }

    /// `ack` means dispatched, not done — the effect arrives as a northbound event.
    public func send(_ command: FleetCommand) {
        dispatchPrecondition(condition: .onQueue(queue))
        _ = winner?.send(command)
    }

    /// Ask the Mac to do something and hear that it heard.
    ///
    /// `ack` still means dispatched, not done — the observable effect arrives separately, as
    /// a northbound event or (for a prompt) in the agent's own transcript. What this adds
    /// over `send(_:)` is the *hearing*: `.success` on `ack`, `.failure(.server(code:))` on
    /// `err`, and `.failure(.disconnected)` — **synchronously** — when there is no socket.
    ///
    /// Same asymmetry and same reason as `request(_:then:)`: a dropped command with no caller
    /// waiting is merely ineffective, while a dropped answer to a caller that IS waiting is a
    /// person who believes they told an agent something.
    public func send(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(command)
        // `0` is `FleetClient`'s "there is no connection to write to" — a seatbelt rather
        // than a live case, kept for the reason `request(_:then:)`'s own guard is kept: the
        // alternative to a redundant check is a completion that is silently never filed.
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingAcks[cid] = completion
    }

    /// Ask the Mac for something and get exactly one answer.
    ///
    /// Answers **synchronously with `.disconnected`** when nothing is connected, rather than
    /// dropping the request the way `send(_ command:)` does. That asymmetry is deliberate:
    /// a command's effect arrives separately as a northbound event, so a dropped one is
    /// merely ineffective, while a dropped request is a caller waiting forever.
    public func request(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(request)
        // `0` is `FleetClient`'s "there is no connection to write to", and it is a seatbelt
        // rather than a live case: `connection` is nilled only by `disconnect()`, and the one
        // caller that disconnects the winner nils `winner` on the very next statement of the
        // same serial queue, so no request can observe the gap. A socket that has merely
        // FAILED does not produce it either — `connection` is still non-nil, `send` returns a
        // real cid, and that request is resolved by the drain. Kept because the alternative
        // to a redundant `guard` here is a completion that is silently never filed.
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pending[cid] = completion
    }

    /// Ask for a project's New Session rows. Same contract as `request(_:then:)` — exactly one
    /// answer, `.disconnected` synchronously when there is nothing to ask.
    public func requestNewSessionOptions(
        project: UUID,
        then completion: @escaping (Result<WireNewSessionOptions, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.newSessionOptions(project: project))
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingOptions[cid] = completion
    }

    /// Ask the Mac which addresses it can currently be reached on. Same contract as
    /// `request(_:then:)` — exactly one answer, `.disconnected` synchronously when there is
    /// nothing to ask.
    ///
    /// The answer is adopted by `adoptEndpoints` before the completion runs, so a caller that
    /// only wants the refresh can pass an empty closure and ignore the value.
    public func requestMacEndpoints(
        then completion: @escaping (Result<[String], FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.macEndpoints)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingEndpoints[cid] = completion
    }

    private func resolveEndpoints(
        _ cid: Int, with result: Result<[String], FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingEndpoints.removeValue(forKey: cid) else { return }
        completion(result)
    }

    /// Ask for the whole conversation catalogue plus every live tab's recency. Same contract
    /// as `request(_:then:)` — exactly one answer, `.disconnected` synchronously when there
    /// is nothing to ask.
    public func requestConversations(
        then completion: @escaping (Result<WireConversationCatalogue, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.conversations)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingConversations[cid] = completion
    }

    /// Search transcript content for `query`. Same contract as `request(_:then:)` — exactly
    /// one answer, `.disconnected` synchronously when there is nothing to ask.
    public func requestSearch(
        query: String, limit: Int,
        then completion: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.search(query: query, limit: limit))
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingSearch[cid] = completion
    }

    /// Ask the Mac to resume `conversationID` — from `projectPath` — into a new tab. Same
    /// contract as `request(_:then:)` — exactly one answer, `.disconnected` synchronously
    /// when there is nothing to ask.
    public func requestOpenConversation(
        conversationID: String, projectPath: String,
        then completion: @escaping (Result<UUID, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(
            FleetRequest.openConversation(conversationID: conversationID, projectPath: projectPath)
        )
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingSession[cid] = completion
    }

    /// Ask for every reopenable tab the Mac is holding. Same contract as `request(_:then:)` —
    /// exactly one answer, `.disconnected` synchronously when there is nothing to ask.
    public func requestRecentlyClosed(
        then completion: @escaping (Result<[WireClosedSession], FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.recentlyClosed)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingClosed[cid] = completion
    }

    /// Takes the Mac's list as authoritative for membership, keeping the promoted address in
    /// front when the Mac still claims it.
    private func adoptEndpoints(_ list: [String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Empty means "this Mac could not enumerate", never "this Mac has no addresses" — we
        // are reading the frame over one of them. Erasing a working candidate on the strength
        // of an empty answer is the one outcome worse than a stale list.
        guard !list.isEmpty else { return }
        var next = list
        // `promote()` puts whichever address last won a race at the front. Preserve that
        // across a refresh; drop it when the Mac no longer claims it, which is precisely the
        // stale candidate this request exists to remove.
        if let promoted = mac.endpoints.first, let index = next.firstIndex(of: promoted) {
            next.remove(at: index)
            next.insert(promoted, at: 0)
        }
        guard next != mac.endpoints else { return }
        mac.endpoints = next
        try? store.save(mac)
    }

    /// Resolves one outstanding request, or does nothing if nothing is waiting on that `cid`.
    ///
    /// Removed before it is invoked, which is what makes it exactly once: a completion is
    /// free to re-enter — `stop()` from inside one is the ordinary case — and whatever it
    /// does next finds nothing left filed under this number.
    private func resolve(_ cid: Int, with result: Result<TimelinePage, FleetRequestError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pending.removeValue(forKey: cid) else { return }
        completion(result)
    }

    private func resolveOptions(
        _ cid: Int, with result: Result<WireNewSessionOptions, FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingOptions.removeValue(forKey: cid) else { return }
        completion(result)
    }

    private func resolveConversations(
        _ cid: Int, with result: Result<WireConversationCatalogue, FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingConversations.removeValue(forKey: cid) else { return }
        completion(result)
    }

    private func resolveSearch(
        _ cid: Int, with result: Result<WireSearchHits, FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingSearch.removeValue(forKey: cid) else { return }
        completion(result)
    }

    private func resolveSession(
        _ cid: Int, with result: Result<UUID, FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingSession.removeValue(forKey: cid) else { return }
        completion(result)
    }

    private func resolveClosed(
        _ cid: Int, with result: Result<[WireClosedSession], FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingClosed.removeValue(forKey: cid) else { return }
        completion(result)
    }

    /// Resolves one outstanding command, reporting whether there was one.
    ///
    /// Removed before it is invoked, exactly as `resolve` does and for the same reason: a
    /// completion is free to re-enter — `stop()` from inside one is ordinary — and whatever
    /// it does next must find nothing left filed under this number.
    ///
    /// The `Bool` is what lets `apply` try this table first and fall through to `pending`
    /// without either arm having to know which verb a `cid` belonged to.
    @discardableResult
    private func resolveAck(_ cid: Int, with result: Result<Void, FleetRequestError>) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingAcks.removeValue(forKey: cid) else { return false }
        completion(result)
        return true
    }

    // MARK: The race

    /// Parallel, not sequential. The key identifies the Mac, so the first candidate to
    /// complete a handshake is by definition the right one and there is nothing to rank
    /// beforehand — while trying them in order means a phone that has changed networks waits
    /// out a TCP timeout per stale address before reaching the one that works.
    private func race() {
        guard running else { return }
        teardown()
        // `teardown()` drains `pending`, and a completion is free to call `stop()` from
        // inside that drain — see `scheduleRetry()`, where the same re-entry is reachable
        // today. Kept in step here so the two post-`teardown()` sites cannot drift into
        // disagreeing about whether the connector is still running; `startBrowsing()` guards
        // the same hazard, for the same reason, a few lines down.
        guard running else { return }
        report(.searching)
        let generation = invalidateDeferredWork()
        for candidate in remembered() { dial(candidate) }
        if browse { startBrowsing() }
        // Without the generation guard: a race whose candidates all fail in 100ms retries at
        // ~1s, and THIS race's 8s timer later fires anyway, sees no winner, and schedules a
        // second retry on top of the pending one. That is backoff acceleration and a spurious
        // extra `.lost`, not two races actually running concurrently — the moment either
        // deferred callback calls `race()`, its own generation bump invalidates whatever the
        // other one still has pending. A live connection is never what gets torn down by
        // this; see `testAStaleRaceTimeoutDuringBackoffDoesNotDoubleTheRetry` for the trace.
        queue.asyncAfter(deadline: .now() + raceTimeout) { [weak self] in
            guard let self, self.running, self.winner == nil,
                  generation == self.generation
            else { return }
            self.scheduleRetry()
        }
    }

    private func remembered() -> [Candidate] {
        mac.endpoints.compactMap { text in
            Self.endpoint(from: text).map {
                Candidate(description: text, endpoint: $0, isRemembered: true)
            }
        }
    }

    private func dial(_ candidate: Candidate) {
        guard running, winner == nil, racers[candidate.description] == nil else { return }
        let client = FleetClient(key: mac.key, deviceName: deviceName, queue: queue)
        racers[candidate.description] = client
        client.onFrame = { [weak self] frame in
            self?.accept(frame, from: candidate, client: client)
        }
        client.onDisconnect = { [weak self] _ in
            self?.noteDisconnect(candidate, client: client)
        }
        client.connect(to: candidate.endpoint, lastSeq: mac.lastSeq)
    }

    private func startBrowsing() {
        // `race()` reports `.searching` before this is called, and an `onState` handler is
        // free to call `stop()` re-entrantly from inside that callback. `dial()` already
        // guards against running that way; without the same guard here, a browser started
        // after `running` went false would never be cancelled — `stop()` already ran its
        // `teardown()` and won't run it again.
        guard running else { return }
        let browser = NWBrowser(
            for: .bonjour(type: FleetSocketServer.bonjourType, domain: nil), using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      // Only the Mac we paired with. Another Flight Deck on the same LAN
                      // would refuse our key anyway, but dialling it is noise in the race.
                      name == self.mac.serviceName
                else { continue }
                self.dial(Candidate(
                    description: "bonjour:\(name)", endpoint: result.endpoint,
                    isRemembered: false
                ))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func accept(_ frame: ServerFrame, from candidate: Candidate, client: FleetClient) {
        // A frame can still arrive from a client `teardown()` already disconnected:
        // Network.framework hops the receive completion onto `queue` before `cancel()` runs,
        // and cancellation cannot recall an in-flight block. `FleetClient.onFrame` is now
        // gated on `!hasEnded` at the source (see `FleetClient.swift`), but this is a second,
        // independent line of defense — refusing a client that is neither a live racer nor
        // the current winner means a frame from a torn-down race can never be installed as
        // `winner`, which would otherwise silently disconnect every racer a NEW race had just
        // dialled.
        guard running, racers[candidate.description] === client || client === winner else {
            return
        }
        if winner == nil {
            winner = client
            for (description, other) in racers where other !== client {
                other.disconnect()
                racers.removeValue(forKey: description)
            }
            browser?.cancel()
            browser = nil
            attempt = 0
            if candidate.isRemembered { promote(candidate.description) }
            report(.connected(macName: mac.macName))
            // Addresses have no push path — the network emits no fleet events — so a connect
            // is the only moment they can be refreshed. Hung off `.connected` rather than off
            // `apply`'s `.snapshot` arm, where it used to live under the claim that "every
            // snapshot is every connect": that is false, and false in the case the feature
            // exists for. `FleetReplicator.resume(from:)` resnapshots only on a first
            // connection, after the Mac's `seq` went backwards, or when the client fell off
            // the 4096-entry ring; every other reconnect is answered with a replay — events,
            // or nothing at all. A phone that drops Wi-Fi and rejoins, or is backgrounded and
            // foregrounded against a Mac that has been up a while, takes that path every
            // time, and never refreshed. Here it covers snapshot and replay alike, once per
            // connection, because this block only runs when `winner` is installed.
            //
            // (Nor is this "the same hook the New Session menu hangs off", as the comment in
            // the `.snapshot` arm also claimed. That menu hangs off `onFleet`, which fires on
            // snapshots *and* on every event.)
            //
            // Two orderings inside this block are load-bearing. After `winner = client`, or
            // `requestMacEndpoints` no-ops on its own `guard let winner`. After `promote()`,
            // because `adoptEndpoints` reads `mac.endpoints.first` to decide which address
            // keeps the front position promotion just gave it. It is on `queue` because
            // `accept()` is, so the precondition `requestMacEndpoints` asserts holds without
            // weakening. The answer is adopted in `apply`'s `.macEndpoints` arm; nothing
            // here needs the value, and a `.disconnected` from a consumer that tore down
            // inside `report` above is a no-op into the empty closure.
            requestMacEndpoints { _ in }
        }
        guard client === winner else { return }
        apply(frame)
    }

    /// Note a gap the spine's review left here deliberately: when a resuming client is already
    /// current, the server answers `.replay([])` and therefore sends *nothing*. The connector
    /// cannot distinguish "you are up to date" from "your hello was ignored", so it must treat
    /// reaching `.ready` and sending `hello` as the success signal — not the arrival of a
    /// frame. Do not add a receive-timeout that assumes a frame always follows `hello`.
    private func apply(_ frame: ServerFrame) {
        switch frame {
        case .snapshot(let seq, let snapshot, let reason):
            fleet = snapshot
            adopt(seq)
            // After `adopt`, so a handler that reads the connector's own resume point sees the
            // one this snapshot just established rather than the one it replaced.
            onSnapshot?(seq, reason)
            // No endpoint refresh here. It is fired from `accept()` the moment `.connected`
            // is reported, which covers a replayed resume as well as a snapshot — see the
            // comment there for why a snapshot is not every connect.
        case .event(let seq, let event):
            fleet.apply(event)
            advance(to: seq)
            // After the fold and after the seq advances: a handler that acts on this must not
            // see a connector describing an older fleet than the event it is being handed.
            onEvent?(event)
        case .page(let cid, let page):
            // Resolved and returned WITHOUT touching `lastSeq`. A page carries no sequence
            // (see `ServerFrame.page`), and reaching `advance(to:)` from here would let a
            // phone paging back through an hour of transcript rewrite how much fleet history
            // it believes it has applied — and resume from the wrong place on its next
            // launch.
            resolve(cid, with: .success(page))
            return
        case .newSessionOptions(let cid, let options):
            // Unsequenced, exactly like `page` and for the same reason — a menu is not fleet
            // state and must not move the resume point.
            resolveOptions(cid, with: .success(options))
            return
        case .macEndpoints(let cid, let list):
            // Unsequenced, exactly like `page` and `newSessionOptions` and for the same
            // reason — addresses are not fleet state and must not move the resume point.
            adoptEndpoints(list)
            resolveEndpoints(cid, with: .success(list))
            return
        case .recentlyClosed(let cid, let closed):
            // Unsequenced, exactly like `page` and `newSessionOptions` and for the same
            // reason — a reopen list is not fleet state and must not move the resume point.
            resolveClosed(cid, with: .success(closed))
            return
        case .err(let cid, let code):
            // Commands first, then requests. The tables share one `cid` space
            // (`FleetClient.nextCID` mints for all of them), so a number is in at most one of
            // them and the order cannot cross an answer — it is stated so a future table is
            // added deliberately rather than by accident.
            //
            // `code` is carried through verbatim rather than interpreted: `unhandled` (no
            // handler wired) and `unsupported` (a request this Mac cannot parse) are both on
            // this wire today, and a newer Mac may invent more.
            if resolveAck(cid, with: .failure(.server(code: code))) { return }
            if pendingOptions[cid] != nil {
                resolveOptions(cid, with: .failure(.server(code: code)))
                return
            }
            if pendingEndpoints[cid] != nil {
                resolveEndpoints(cid, with: .failure(.server(code: code)))
                return
            }
            if pendingConversations[cid] != nil {
                resolveConversations(cid, with: .failure(.server(code: code)))
                return
            }
            if pendingSearch[cid] != nil {
                resolveSearch(cid, with: .failure(.server(code: code)))
                return
            }
            if pendingSession[cid] != nil {
                resolveSession(cid, with: .failure(.server(code: code)))
                return
            }
            if pendingClosed[cid] != nil {
                resolveClosed(cid, with: .failure(.server(code: code)))
                return
            }
            resolve(cid, with: .failure(.server(code: code)))
            return
        case .ack(let cid):
            // An `ack` for a command with a completion filed is that completion's answer.
            if resolveAck(cid, with: .success(())) { return }
            // An `ack` correlated to a REQUEST is a server that answered the wrong verb —
            // "dispatched, not done" is no answer to a question whose point is the data it
            // carries back. Released as a server error rather than dropped, so the caller is
            // freed either way. An `ack` matching neither table is a `send(_:)` with no
            // completion, and is the no-op it has always been.
            resolve(cid, with: .failure(.server(code: "unexpected_ack")))
            return
        case .conversations(let cid, let catalogue):
            // Unsequenced, exactly like `page` and `newSessionOptions` and for the same
            // reason — the catalogue is not fleet state and must not move the resume point.
            resolveConversations(cid, with: .success(catalogue))
            return
        case .searchHits(let cid, let hits):
            // Unsequenced, same reason.
            resolveSearch(cid, with: .success(hits))
            return
        case .session(let cid, let sessionID):
            // Unsequenced, same reason.
            resolveSession(cid, with: .success(sessionID))
            return
        case .phoneRequest(let cid, let request):
            // The one frame on this socket the phone answers rather than applies. Unsequenced
            // for the reason every reply above is: a diagnostic fetch is not fleet state, and
            // reaching `advance(to:)` from here would let the Mac's own correlation id move
            // this phone's resume point.
            serve(request, cid: cid)
            return
        }
        onFleet?(fleet)
    }

    /// Answers one `PhoneRequest`, on the connection it arrived on.
    ///
    /// The reply is hopped back onto `queue` and re-checked against `winner`, because
    /// `onPhoneRequest` is free to answer from wherever it read: a phone that lost Wi-Fi mid
    /// read would otherwise write a reply into a client this connector has already torn down,
    /// or — worse — into whichever client happens to be the winner by then, on a `cid` from a
    /// connection that no longer exists. The Mac's own `askDeadline` releases the caller in
    /// that case; a misdirected reply would have it answering the wrong question instead.
    private func serve(_ request: PhoneRequest, cid: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let onPhoneRequest else {
            // Answered rather than ignored, and with the same code an unwired `onRequest` on
            // the Mac produces: a caller whose fetch is dropped in silence waits out a
            // deadline for a reply that was never coming.
            winner?.answer(.refused(cid: cid, code: "unhandled"))
            return
        }
        let client = winner
        onPhoneRequest(request) { [weak self, weak client] result in
            guard let self else { return }
            self.queue.async {
                guard let client, client === self.winner else { return }
                switch result {
                case .success(let logs): client.answer(.logs(cid: cid, logs))
                case .failure(let refusal):
                    client.answer(.refused(cid: cid, code: refusal.code))
                }
            }
        }
    }

    /// A `.snapshot` sets `lastSeq` ABSOLUTELY, not just when it is higher.
    /// `FleetReplicator.seq` restarts at 0 on every Mac process launch, and the case where
    /// that surfaces here is `.seqTooOld`: the server answering "you asked to resume from
    /// before what I can offer", which after a restart means offering a `seq` LOWER than
    /// what this phone already has stored. Frames on one connection are ordered, so whatever
    /// seq the snapshot being applied right now carries IS the truth for this connection —
    /// higher or lower than the old value, regardless of which `SnapshotReason` produced it.
    /// Guarding this with the same `>` rule `.event` uses (the rule this used to share) would
    /// pin `lastSeq` at the pre-restart value forever: the *display* stays correct
    /// regardless, because `fleet.apply` runs unconditionally and events are idempotent, but
    /// every future reconnect would then re-download the whole snapshot instead of resuming
    /// — a permanent, invisible degradation with nothing on screen to explain it.
    /// `try?`, and this is the one place in the codebase where discarding a `save` failure is
    /// the right answer rather than the bug that made `save` throw in the first place. By the
    /// time any of these three run there is already a `PairedMac` in the keychain — this is
    /// bookkeeping on top of it (how far the phone has replayed, which address answered), not
    /// the pairing itself. A write that fails here costs one full snapshot instead of a resume
    /// on the next launch, which is invisible and self-correcting. A write that fails in
    /// `FleetModel.adopt` costs the pairing, which is why that one is reported to the user.
    ///
    /// There is also nowhere for an error to go from here: these run inside frame application
    /// on `queue`, per applied frame, with no user watching and no channel to reach one.
    private func adopt(_ seq: Int) {
        mac.lastSeq = seq
        try? store.save(mac)
    }

    /// An `.event`'s seq, unlike a snapshot's, only ever advances `lastSeq` when it is a real
    /// advance: applying one twice must not un-advance a `lastSeq` that has already moved
    /// past it.
    ///
    /// `store.save` runs on every applied frame, unthrottled, and that stays a decision, not
    /// an oversight — though on a different basis than the one first written here. It is NOT
    /// bounded by the Mac-side replay fold, which runs only on the reconnect path; the live
    /// path broadcasts one frame per event. What actually bounds it: `emitActivity` on the
    /// Mac filters to genuine state transitions, and `WatchClock` polls at 500ms/2s, so status
    /// events land at roughly 2/s per session, not per tick of activity. The real cost worth
    /// naming is that `store.save` is a synchronous `securityd` XPC round trip made on
    /// `queue`, which defaults to `.main` — the thread rendering the fleet list. If that ever
    /// needs revisiting, the fix is moving the write off the main queue, not throttling how
    /// often `lastSeq` changes.
    private func advance(to seq: Int) {
        guard seq > mac.lastSeq else { return }
        mac.lastSeq = seq
        try? store.save(mac)
    }

    /// The address that worked goes to the front, so the next launch connects on its first
    /// attempt instead of racing the same dead candidates again.
    private func promote(_ description: String) {
        var endpoints = mac.endpoints.filter { $0 != description }
        endpoints.insert(description, at: 0)
        mac.endpoints = endpoints
        try? store.save(mac)
    }

    private func noteDisconnect(_ candidate: Candidate, client: FleetClient) {
        // Same staleness hazard as `accept()`, and the same fix: a disconnect callback for a
        // client that is no longer registered under its own description (and isn't the
        // winner) belongs to a race `teardown()` already moved past. Acting on it here would
        // let an "all candidates failed" verdict fire for a generation that already retried,
        // double-advancing the backoff — only reachable with Bonjour off (`browse: false`,
        // as the tests run), since a live browser keeps `noteDisconnect`'s all-failed branch
        // from ever being the sole trigger, but the guard costs nothing either way.
        guard racers[candidate.description] === client || client === winner else { return }
        racers.removeValue(forKey: candidate.description)
        guard client === winner else {
            // A losing racer failing is expected and uninteresting — unless every candidate
            // has now failed with nothing left to discover, which is "cannot find the Mac".
            if winner == nil, racers.isEmpty, browser == nil { scheduleRetry() }
            return
        }
        winner = nil
        // The pending table is drained by `scheduleRetry()`'s `teardown()`, not here, and
        // that path is reachable whenever this branch is. `scheduleRetry()` does nothing once
        // `running` is false — but `running` is false only after `stop()`, whose `teardown()`
        // has already cleared `racers` and nilled `winner`, so this method's entry guard
        // fails and this branch is not merely un-drained, it is unreachable. (`stop()`'s
        // `disconnect()` also sets `FleetClient.hasEnded` before cancelling, so it cannot
        // produce the callback that gets here at all.) That is why no path can leave
        // `pending` non-empty with `winner` nil.
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running else { return }
        teardown()
        // Re-checked AFTER `teardown()`, because `teardown()` now drains `pending` and a
        // completion hearing `.disconnected` is free to call `stop()` — which
        // `resolve(_:with:)` calls the ordinary case. Without this, control unwinds back
        // into a method that goes on to report `.lost(retryingIn:)` on a connector that
        // just went `.idle` and will never race again (`race()` guards on `running`). The
        // consumer's last word would be "reconnecting in one second" with nothing
        // reconnecting and nothing on screen to explain it — the same shape as the flap
        // this channel already fixed once.
        guard running else { return }
        // Bumping here is what makes a timeout that fires DURING the backoff window
        // harmless — at that moment no new race has started, so a generation bumped only by
        // `race()` would still match and the retry would double.
        let generation = invalidateDeferredWork()
        let delay = retryDelays[min(attempt, retryDelays.count - 1)]
        attempt += 1
        report(.lost(retryingIn: delay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.race()
        }
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(queue))
        for client in racers.values { client.disconnect() }
        racers.removeAll()
        winner?.disconnect()
        winner = nil
        browser?.cancel()
        browser = nil
        drainPending()
    }

    /// Answers every outstanding request and command. Drained, not cleared — see `pending`.
    ///
    /// Called only once `winner` is already nil, and that ordering is load-bearing rather
    /// than tidiness. A completion hearing `.disconnected` is exactly the caller most likely
    /// to ask again, and it does so re-entrantly, from inside this loop. With `winner` still
    /// installed the retry would be filed into a table this drain has already emptied — and
    /// nothing would ever resolve it, since there is no connection left to lose and no reply
    /// that can arrive. With `winner` nil it takes `request()`'s synchronous `.disconnected`
    /// path instead.
    ///
    /// `removeAll()` before the loop, not after, for the mirror-image reason: a completion
    /// that re-enters through `stop()` runs this whole drain again and must find nothing left
    /// to answer a second time.
    private func drainPending() {
        dispatchPrecondition(condition: .onQueue(queue))
        let outstanding = pending
        pending.removeAll()
        for completion in outstanding.values { completion(.failure(.disconnected)) }
        // Commands too, and the same `removeAll`-before-the-loop discipline: a completion
        // that re-enters through `stop()` runs this whole drain again and must find nothing
        // left to answer a second time.
        let outstandingAcks = pendingAcks
        pendingAcks.removeAll()
        for completion in outstandingAcks.values { completion(.failure(.disconnected)) }
        // And the menu rows. A phone whose fetch dies with the socket must be told, or its
        // `+` sits on a fallback row forever with nothing on the way.
        let outstandingOptions = pendingOptions
        pendingOptions.removeAll()
        for completion in outstandingOptions.values { completion(.failure(.disconnected)) }
        // And the endpoint refresh. Added the moment the table was, per the rule in
        // docs/NETWORKING.md: a client whose socket dies with a request outstanding waits
        // forever otherwise.
        let outstandingEndpoints = pendingEndpoints
        pendingEndpoints.removeAll()
        for completion in outstandingEndpoints.values { completion(.failure(.disconnected)) }
        // And the three search tables, for the same reason: a phone whose socket dies with
        // a catalogue fetch, a search, or an open-conversation request outstanding must be
        // told rather than left spinning.
        let outstandingConversations = pendingConversations
        pendingConversations.removeAll()
        for completion in outstandingConversations.values { completion(.failure(.disconnected)) }
        let outstandingSearch = pendingSearch
        pendingSearch.removeAll()
        for completion in outstandingSearch.values { completion(.failure(.disconnected)) }
        let outstandingSession = pendingSession
        pendingSession.removeAll()
        for completion in outstandingSession.values { completion(.failure(.disconnected)) }
        // And the reopen list, for the same reason: a phone whose socket dies with that fetch
        // outstanding must be told, or its `+` menu waits on a section that never arrives.
        let outstandingClosed = pendingClosed
        pendingClosed.removeAll()
        for completion in outstandingClosed.values { completion(.failure(.disconnected)) }
    }

    private func report(_ state: State) { onState?(state) }

    private static func endpoint(from text: String) -> NWEndpoint? {
        guard
            let colon = text.lastIndex(of: ":"),
            let port = NWEndpoint.Port(String(text[text.index(after: colon)...])),
            !text[..<colon].isEmpty
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(text[..<colon])), port: port)
    }
}
