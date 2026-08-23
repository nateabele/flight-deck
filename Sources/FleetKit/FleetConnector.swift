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
        case .snapshot(let seq, let snapshot, _):
            fleet = snapshot
            adopt(seq)
        case .event(let seq, let event):
            fleet.apply(event)
            advance(to: seq)
        case .page(let cid, let page):
            // Resolved and returned WITHOUT touching `lastSeq`. A page carries no sequence
            // (see `ServerFrame.page`), and reaching `advance(to:)` from here would let a
            // phone paging back through an hour of transcript rewrite how much fleet history
            // it believes it has applied — and resume from the wrong place on its next
            // launch.
            resolve(cid, with: .success(page))
            return
        case .err(let cid, let code):
            // A command's `err` changes no fleet state and is dropped here; a request's is
            // the only answer that request will ever get. `code` is carried through
            // verbatim rather than interpreted: `unhandled` (no reader wired) and
            // `unsupported` (a request this Mac cannot parse) are both on this wire today,
            // and a newer Mac may invent more.
            resolve(cid, with: .failure(.server(code: code)))
            return
        case .ack(let cid):
            // An `ack` correlated to a request is a server that answered the wrong verb —
            // "dispatched, not done" is no answer to a question whose point is the data it
            // carries back. Released as a server error rather than dropped, so the caller is
            // freed either way. An `ack` for a command matches nothing here and is a no-op,
            // which is what it has always been.
            resolve(cid, with: .failure(.server(code: "unexpected_ack")))
            return
        }
        onFleet?(fleet)
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

    /// Answers every outstanding request `.disconnected`. Drained, not cleared — see
    /// `pending`.
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
