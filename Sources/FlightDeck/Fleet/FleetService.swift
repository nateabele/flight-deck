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
    /// Which paired slots are currently attached — a remotely-driveable machine that gives
    /// no sign of being attached to is the thing §11 of the spec calls out as not-polish.
    /// `DevicesSettingsTab` reads this directly to badge each device row; a connection whose
    /// PSK identity could not be read back is attached but cannot appear here — see
    /// `FleetAttachment.slot`.
    @Published private(set) var attachedSlots: Set<UUID> = []

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let store: SessionStore
    private let preferences: PreferencesStore
    private let armer: PairingArmer
    private let server: FleetSocketServer
    private let replicator: FleetReplicator
    private(set) var boundPort: NWEndpoint.Port?
    /// The window's own listener, and the port it is on. Both are `nil` whenever no window is
    /// open, which is invariant 2 stated as a field rather than as a comment.
    private let pairing = PairingListener()
    private(set) var pairingPort: NWEndpoint.Port?
    /// Cancelled and replaced by every `scheduleExpiry`, so re-arming or an early cancel
    /// never leaves a stale timer racing the current window.
    private var expiryTask: Task<Void, Never>?
    /// Whether `start()` has already run the launch-time reconciliation below. Guards it to
    /// exactly the first call: every later call is a key rotation from `reloadKeys()`
    /// (arm, expiry, revocation), and one of those — `arm()` itself — persists a fresh
    /// provisional device and then calls `start()` before returning. Reconciling on every
    /// call would revoke the device the user just armed for.
    private var hasReconciledAtLaunch = false

    /// The Bonjour instance name this Mac advertises under, and the name the phone stores so
    /// it can prefer the Mac it paired with.
    ///
    /// Sanitized and suffixed rather than used raw: a Bonjour instance name cannot carry
    /// arbitrary characters (an apostrophe in "Nate's MacBook" is enough), and two Macs whose
    /// owners both left the default name would otherwise advertise identically — a phone
    /// would then race a machine that will refuse its key. The suffix comes from a stable
    /// per-install id so it survives relaunches.
    let serviceName: String

    init(store: SessionStore, preferences: PreferencesStore, armer: PairingArmer) {
        self.store = store
        self.preferences = preferences
        self.armer = armer
        self.server = FleetSocketServer()
        self.replicator = FleetReplicator { [weak store] in
            guard let store else { return .empty }
            return FleetProjection.snapshot(of: store)
        }
        self.serviceName = Self.derivedServiceName(preferences: preferences)
        store.replicator = replicator
        wireHandlers()
    }

    private static func derivedServiceName(preferences: PreferencesStore) -> String {
        let raw = Host.current().localizedName ?? "Mac"
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.prefix(24).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed.isEmpty ? "flightdeck" : trimmed.lowercased())-\(preferences.installSuffix)"
    }

    /// Everything the socket calls back into. One method so the initializer reads as
    /// "own these three things, then connect them", rather than as forty lines of closures.
    private func wireHandlers() {
        replicator.onEvents = { [weak self] batch in
            for entry in batch {
                self?.server.broadcast(.event(seq: entry.seq, entry.event))
            }
        }
        server.onHello = { [weak self] attachment, lastSeq in
            guard let self else { return [] }
            self.noteAttached(attachment)
            return self.frames(resumingFrom: lastSeq)
        }
        server.onCommand = { [weak self] _, cid, command in
            self?.apply(command, cid: cid) ?? .err(cid: cid, code: "stopped")
        }
        server.onAttachedSlotsChanged = { [weak self] slots in
            // Safe only because `FleetSocketServer`'s `queue` defaults to `.main` and nothing
            // here overrides it: `assumeIsolated` traps rather than hopping if the caller
            // turns out not to be on the main actor, and `init(queue:)` does not enforce
            // serial-ness, let alone `.main` specifically — a caller passing a concurrent
            // queue would compile cleanly and turn this into a runtime crash with no
            // compiler signal. `FleetSocketServer` now also asserts this with a
            // `dispatchPrecondition` before invoking any handler, so a violation traps at
            // the source instead of here.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Assigned directly, not merged: `slots` is already the server's full,
                // authoritative attached set at this instant, so keeping our own copy in
                // sync by patching it per-event is exactly the stale-count bug this signal
                // shape replaces.
                self.attachedSlots = slots
            }
        }
    }

    /// A replay when the ring can serve it, a snapshot when it cannot. The explicit
    /// re-snapshot is the point: silently resuming from wherever the server happens to be is
    /// how a phone ends up confidently displaying a fleet that no longer exists.
    private func frames(resumingFrom lastSeq: Int) -> [ServerFrame] {
        switch replicator.resume(from: lastSeq) {
        case .replay(let events):
            return events.map { .event(seq: $0.seq, $0.event) }
        case .resnapshot(let reason):
            let current = replicator.snapshot()
            return [.snapshot(seq: current.seq, fleet: current.fleet, reason: reason)]
        }
    }

    /// `async` because `FleetSocketServer.start` awaits the OS reporting its bound port
    /// rather than polling for it — the polling version blocked its caller for up to five
    /// seconds, and this type is main-actor, so that was a visible stall.
    ///
    /// `deviceKeys(at: armer.currentTime)`, not the default `Date()`: a provisional device's
    /// `armedUntil` is stamped on the armer's own clock, and under a test's injected clock
    /// that is not real wall time. Filtering against real `Date()` there judged a
    /// freshly-armed window already expired — the listener refused the very key it had just
    /// been told to accept, and the client's handshake could never complete.
    ///
    /// Invariant for any future `deviceKeys(` call site: liveness judgements for a
    /// provisional device must use the armer's clock (`armer.currentTime`), never raw
    /// `Date()` — see the paragraph above for the bug that found this the hard way.
    ///
    /// The reconciliation below runs only on this call's first invocation, and only that one
    /// — see `hasReconciledAtLaunch`. A provisional device is a window the user opened and
    /// has not yet walked a phone through; all three layers that enforce its 120-second
    /// timeout (this armer, `expiryTask`, and `deviceKeys(at:)`'s filter) are established by
    /// `arm()` and none of them survive a quit or crash. A provisional row that outlives the
    /// process it was armed in is not a window anyone is still standing in front of, so it is
    /// revoked outright here rather than re-timed — the same ruling `deviceKeys(at:)`'s doc
    /// comment already made for expiry itself: durable behaviour is a property of the data,
    /// not of who remembers to keep a clock running for it.
    @discardableResult
    func start(port: NWEndpoint.Port? = nil) async throws -> NWEndpoint.Port {
        if !hasReconciledAtLaunch {
            hasReconciledAtLaunch = true
            preferences.pairedDevices
                .filter(\.isProvisional)
                .forEach { preferences.revokeDevice(slot: $0.slot) }
        }
        // `boundPort` first, so a `reloadKeys()` mid-run rebinds exactly the port this process
        // is already advertising; the remembered port is only ever consulted by the first bind
        // of a launch, which is the whole point — a phone's `PairedMac.endpoints` are
        // `host:port` strings that die the instant this Mac comes back on a different port.
        let remembered = preferences.fleetPort.flatMap(NWEndpoint.Port.init(rawValue:))
        let requested = port ?? boundPort ?? remembered
        // Nothing holds the remembered port while Flight Deck is not running, so it is a
        // preference and not a claim: if it is taken, the listener still has to come up. A
        // phone that has to rediscover is a nuisance; a Mac with no listener is a dead feature.
        //
        // Deliberately NOT extended to the reload path (`boundPort != nil`) or to an explicit
        // `port:`. Every arm, expiry and revocation calls `start()` to rotate keys, and that
        // rebind of the same port has a documented `EADDRINUSE` race with the listener it just
        // released — see `FleetSocketServer.start`. Falling back there would let a routine key
        // reload quietly move the listener out from under the endpoints in the pairing code
        // `arm()` built moments earlier and under every paired phone at once, which is the very
        // failure this whole change exists to remove. A failed reload throws, exactly as before.
        let mayFallBack = port == nil && boundPort == nil && requested != nil
        let bound: NWEndpoint.Port
        do {
            bound = try await bind(port: requested)
        } catch {
            guard mayFallBack else { throw error }
            Self.logger.error(
                "fleet listener could not rebind remembered port \(requested?.rawValue ?? 0, privacy: .public), asking the OS for another: \(String(describing: error), privacy: .public)"
            )
            bound = try await bind(port: nil)
        }
        boundPort = bound
        // The port the OS chose after a fallback is remembered too, or the next launch keeps
        // asking for one that is never coming back.
        preferences.rememberFleetPort(bound.rawValue)
        Self.logger.info("fleet listener bound to port \(bound.rawValue, privacy: .public)")
        return bound
    }

    /// The keys are read per attempt rather than hoisted, so the fallback bind cannot install a
    /// key set that a window expiring between the two attempts has already invalidated.
    private func bind(port: NWEndpoint.Port?) async throws -> NWEndpoint.Port {
        try await server.start(
            keys: preferences.deviceKeys(at: armer.currentTime),
            port: port,
            serviceName: serviceName
        )
    }

    func stop() {
        closePairingListener()
        // `server.stop()` drops every attachment synchronously through `cancelConnections()`,
        // which fires `onAttachedSlotsChanged` itself — see `wireHandlers()` — so
        // `attachedSlots` is already empty by the time this returns; nothing to clear here.
        server.stop()
    }

    /// Restarts the listener so a changed key set takes effect. Every arm, expiry and
    /// revocation calls this, so it runs far more often than "revocation is rare" suggests —
    /// see the note on `FleetSocketServer.stop()` in Task 4.
    ///
    /// It restarts the fleet listener only — the pairing listener's lifetime is the window's,
    /// not the key set's, and rebinding it here would move a port a phone is mid-exchange on.
    func reloadKeys() async throws { try await start() }

    /// Opens a pairing window: mints the code, publishes the provisional key, and brings up
    /// the pairing listener the phone will type that code at.
    ///
    /// The provisional slot is written to Preferences *before* the listener restarts,
    /// because the phone cannot complete a handshake against a key the listener does not
    /// hold — "armed" and "the key is live" are the same instant by construction.
    func arm() async throws -> ArmedPairing {
        armer.cancel()
        // Before anything else: a second `arm()` must not leave the previous window's listener
        // answering on its old port with its old code.
        closePairingListener()
        preferences.pairedDevices
            .filter(\.isProvisional)
            .forEach { preferences.revokeDevice(slot: $0.slot) }

        // A code built before the listener bound would carry `host:0` endpoints — the phone
        // would race candidates that can never connect, and the failure would look like a
        // network problem rather than a Mac that was not listening yet. Refuse instead.
        guard let boundPort else { throw FleetSocketError.didNotBind }
        let port = boundPort.rawValue
        let macName = Host.current().localizedName ?? "Mac"
        let armed = armer.arm(
            macName: macName,
            serviceName: serviceName,
            endpoints: LocalEndpoints.current(port: port)
        )
        if let pending = armer.pending {
            preferences.upsert(pending)
            if let armedUntil = pending.armedUntil { scheduleExpiry(at: armedUntil) }
        }
        try await reloadKeys()

        pairing.onPaired = { [weak self] in
            // Deferred by one main-actor turn on purpose. `PairingListener` fires this from
            // the sealed frame's own send completion — so the frame is already in the stack
            // and a graceful `cancel()` orders its FIN behind it — but this still runs inside
            // the listener's own connection callback, and `closePairingListener()` cancels
            // the very connection that callback is holding. The hop takes teardown out from
            // under the handler reacting to it. It is not redundant: `cancel()` does NOT
            // flush a send the stack has not yet taken (see `PairingListener.stop()` for the
            // `POSIXErrorCode 89` measurement), so the ordering here is load-bearing, not
            // stylistic.
            Task { @MainActor [weak self] in self?.closePairingListener() }
        }
        pairing.onAttemptsExhausted = { [weak self] in
            // Three failures burn the window (§7): the provisional key is revoked and the
            // user re-arms. `cancelArming` is the same path the Cancel button takes, and the
            // same one-turn hop, for the same reason — this fires from the send completion of
            // the `.attemptsExhausted` reject.
            Task { @MainActor [weak self] in try? await self?.cancelArming() }
        }
        pairingPort = try await pairing.start(
            code: armed.code, key: armed.payload.key, macName: macName,
            serviceName: serviceName, port: nil
        )
        return armed
    }

    /// The one place the pairing listener is torn down, so every route that closes a window
    /// closes it identically (invariant 2). `pairingPort` is cleared with it because the two
    /// are one fact: a port with no listener behind it is exactly the state that made
    /// "is a window open?" answerable two ways.
    private func closePairingListener() {
        pairing.stop()
        pairingPort = nil
    }

    func cancelArming() async throws {
        expiryTask?.cancel()
        closePairingListener()
        if let pending = armer.pending { preferences.revokeDevice(slot: pending.slot) }
        armer.cancel()
        try await reloadKeys()
    }

    /// Schedules the window's own expiry, so a code stops being a key on time whether or not
    /// anything is still on screen.
    ///
    /// The pairing sheet also calls `expireArming()` on a timer, but that timer dies with the
    /// sheet: dismissing it early — ⌘W, clicking away, quitting — used to leave the key live
    /// indefinitely. `deviceKeys(at:)` already refuses an expired key, so this is belt to that
    /// braces: it makes the *listener* drop it promptly rather than at the next reload.
    ///
    /// The delay is measured against `armer.currentTime`, not `Date()`: `deadline` lives in
    /// the armer's clock domain, and under a test's injected clock that is not real wall
    /// time. Subtracting real `Date()` from a deadline computed on a fixed 1970 test clock
    /// produced a negative delay — an immediate, spurious expiry that revoked a device before
    /// its own handshake could complete.
    private func scheduleExpiry(at deadline: Date) {
        expiryTask?.cancel()
        let seconds = deadline.timeIntervalSince(armer.currentTime)
        expiryTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            try? await self?.expireArming()
        }
    }

    /// Drops a window that ran out. Called on a timer by the pairing sheet, and again before
    /// the sheet closes, so an expired code stops being a key rather than merely stopping
    /// being drawn.
    func expireArming() async throws {
        guard let pending = armer.pending else { return }
        armer.expire()
        guard armer.pending == nil else { return }
        closePairingListener()
        preferences.revokeDevice(slot: pending.slot)
        try await reloadKeys()
    }

    /// Convenience for the tests and for nothing else — production dials a discovered or
    /// remembered endpoint, never a hard-coded host.
    func loopbackEndpoint() throws -> NWEndpoint {
        guard let boundPort else { throw FleetSocketError.didNotBind }
        return .hostPort(host: "127.0.0.1", port: boundPort)
    }

    /// A device said hello. If it is the one the user just armed for, this is the instant
    /// pairing completes — there is no separate pairing exchange, because a completed
    /// TLS-PSK handshake already proved everything a pairing exchange would have.
    private func noteAttached(_ attachment: FleetAttachment) {
        guard let slot = attachment.slot else { return }
        // `attachedSlots` is not touched here: `wireHandlers()`'s `onAttachedSlotsChanged`
        // already reflects this attachment by the time `onHello` — and therefore this
        // method — runs; see `FleetSocketServer.accept()`'s ordering.
        let now = Date()
        if armer.claim(slot: slot), var device = preferences.pairedDevices.first(where: { $0.slot == slot }) {
            expiryTask?.cancel()
            device.pairedAt = now
            device.armedUntil = nil
            device.lastSeenAt = now
            preferences.upsert(device)
        } else {
            preferences.noteDeviceSeen(slot: slot, at: now)
        }
        // After the upsert above, not before: on the pairing attach that branch writes the
        // whole provisional device back, which would put the placeholder name straight over
        // an adopted one. Every attach, not just the first — the user may have renamed the
        // phone since — and `adoptClaimedName` is what keeps that from overwriting a name
        // the user chose here instead.
        if let claimed = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claimed.isEmpty {
            preferences.adoptClaimedName(slot: slot, claimed)
        }
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
