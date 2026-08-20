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
    private let browse: Bool
    private let queue: DispatchQueue

    private var racers: [String: FleetClient] = [:]
    private var winner: FleetClient?
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
        mac: PairedMac, store: any PairedMacStoring,
        browse: Bool = true, queue: DispatchQueue = .main
    ) {
        self.mac = mac
        self.store = store
        self.browse = browse
        self.queue = queue
    }

    public func start() {
        running = true
        attempt = 0
        race()
    }

    public func stop() {
        running = false
        invalidateDeferredWork()
        teardown()
        report(.idle)
    }

    /// `ack` means dispatched, not done — the effect arrives as a northbound event.
    public func send(_ command: FleetCommand) {
        _ = winner?.send(command)
    }

    // MARK: The race

    /// Parallel, not sequential. The key identifies the Mac, so the first candidate to
    /// complete a handshake is by definition the right one and there is nothing to rank
    /// beforehand — while trying them in order means a phone that has changed networks waits
    /// out a TCP timeout per stale address before reaching the one that works.
    private func race() {
        guard running else { return }
        teardown()
        report(.searching)
        let generation = invalidateDeferredWork()
        for candidate in remembered() { dial(candidate) }
        if browse { startBrowsing() }
        // Without the generation guard: a race whose candidates all fail in 100ms retries at
        // ~1s, and THIS race's 8s timer later fires anyway, sees no winner, and schedules a
        // second retry on top of the pending one. Two races then run against each other, the
        // later one tearing down whatever the earlier one connected, and `attempt` advances
        // twice as fast as `retryDelays` says. The symptom is a phone that gets harder to
        // connect the longer it tries, which reads as a flaky network rather than a bug.
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
        let client = FleetClient(key: mac.key, queue: queue)
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

    private func apply(_ frame: ServerFrame) {
        switch frame {
        case .snapshot(let seq, let snapshot, _):
            fleet = snapshot
            advance(to: seq)
        case .event(let seq, let event):
            fleet.apply(event)
            advance(to: seq)
        case .ack, .err:
            // Command replies change no fleet state; the effect arrives as its own event.
            return
        }
        onFleet?(fleet)
    }

    /// `lastSeq` advances only on frames actually applied, and is persisted immediately.
    /// Advancing it optimistically would let a phone claim to have applied an event it
    /// dropped, and the resume path would then never send it again — a fleet permanently
    /// missing one change, with nothing to indicate it.
    ///
    /// Note a gap the spine's review left here deliberately: when a resuming client is already
    /// current, the server answers `.replay([])` and therefore sends *nothing*. The connector
    /// cannot distinguish "you are up to date" from "your hello was ignored", so it must treat
    /// reaching `.ready` and sending `hello` as the success signal — not the arrival of a
    /// frame. Do not add a receive-timeout that assumes a frame always follows `hello`.
    ///
    /// A `store.save` on every applied frame is eager rather than throttled, and that is a
    /// decision, not an oversight: `KeychainPairedMacStore.save` updates in place, so there is
    /// no delete-then-add window to make routine, only a `SecItemUpdate` per event. Throttling
    /// would need its own durability path for a normal disconnect (persisting on
    /// `noteDisconnect`, since a coalesced write could otherwise lag behind what the Mac has
    /// already sent) for a value whose loss costs nothing worse than one extra snapshot
    /// download on the next launch. That trade is not worth the extra state here.
    private func advance(to seq: Int) {
        guard seq > mac.lastSeq else { return }
        mac.lastSeq = seq
        store.save(mac)
    }

    /// The address that worked goes to the front, so the next launch connects on its first
    /// attempt instead of racing the same dead candidates again.
    private func promote(_ description: String) {
        var endpoints = mac.endpoints.filter { $0 != description }
        endpoints.insert(description, at: 0)
        mac.endpoints = endpoints
        store.save(mac)
    }

    private func noteDisconnect(_ candidate: Candidate, client: FleetClient) {
        racers.removeValue(forKey: candidate.description)
        guard client === winner else {
            // A losing racer failing is expected and uninteresting — unless every candidate
            // has now failed with nothing left to discover, which is "cannot find the Mac".
            if winner == nil, racers.isEmpty, browser == nil { scheduleRetry() }
            return
        }
        winner = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running else { return }
        teardown()
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
        for client in racers.values { client.disconnect() }
        racers.removeAll()
        winner?.disconnect()
        winner = nil
        browser?.cancel()
        browser = nil
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
