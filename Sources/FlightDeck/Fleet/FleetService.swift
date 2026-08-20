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
    /// How many phones are watching right now. Published because the Mac shows it — a
    /// remotely-driveable machine that gives no sign of being attached to is the thing §11
    /// of the spec calls out as not-polish.
    @Published private(set) var attachedDeviceCount = 0
    /// Which paired slots are currently attached, distinct from `attachedDeviceCount`
    /// because a connection whose PSK identity could not be read back still counts toward
    /// the count but cannot appear here — see `FleetAttachment.slot`.
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
    /// Cancelled and replaced by every `scheduleExpiry`, so re-arming or an early cancel
    /// never leaves a stale timer racing the current window.
    private var expiryTask: Task<Void, Never>?

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
        server.onAttachedCountChanged = { [weak self] count in
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
                self.attachedDeviceCount = count
                if count == 0 { self.attachedSlots.removeAll() }
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
    @discardableResult
    func start(port: NWEndpoint.Port? = nil) async throws -> NWEndpoint.Port {
        let bound = try await server.start(
            keys: preferences.deviceKeys(at: armer.currentTime), port: port ?? boundPort
        )
        boundPort = bound
        Self.logger.info("fleet listener bound to port \(bound.rawValue, privacy: .public)")
        return bound
    }

    func stop() {
        server.stop()
        attachedDeviceCount = 0
        attachedSlots.removeAll()
    }

    /// Restarts the listener so a changed key set takes effect. Every arm, expiry and
    /// revocation calls this, so it runs far more often than "revocation is rare" suggests —
    /// see the note on `FleetSocketServer.stop()` in Task 4.
    func reloadKeys() async throws { try await start() }

    /// Opens a pairing window and returns the code to display.
    ///
    /// The provisional slot is written to Preferences *before* the listener restarts,
    /// because the phone cannot complete a handshake against a key the listener does not
    /// hold — "armed" and "the key is live" are the same instant by construction.
    func arm() async throws -> PairingPayload {
        armer.cancel()
        preferences.pairedDevices
            .filter(\.isProvisional)
            .forEach { preferences.revokeDevice(slot: $0.slot) }

        // A code built before the listener bound would carry `host:0` endpoints — the phone
        // would race candidates that can never connect, and the failure would look like a
        // network problem rather than a Mac that was not listening yet. Refuse instead.
        guard let boundPort else { throw FleetSocketError.didNotBind }
        let port = boundPort.rawValue
        let payload = armer.arm(
            macName: Host.current().localizedName ?? "Mac",
            serviceName: serviceName,
            endpoints: LocalEndpoints.current(port: port)
        )
        if let pending = armer.pending {
            preferences.upsert(pending)
            if let armedUntil = pending.armedUntil { scheduleExpiry(at: armedUntil) }
        }
        try await reloadKeys()
        return payload
    }

    func cancelArming() async throws {
        expiryTask?.cancel()
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
        attachedSlots.insert(slot)
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
