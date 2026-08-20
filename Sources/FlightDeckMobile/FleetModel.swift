import FleetKit
import Foundation
import Observation

/// Everything both screens talk to, and nothing more.
///
/// Deliberately thin: it owns a store and a connector, both of which are already tested in
/// `FleetKit` against real sockets on macOS. The iOS target has no test host on this
/// machine, so anything here that would be worth testing belongs in `FleetKit` instead —
/// keeping this file glue is what keeps that true.
@MainActor
@Observable
final class FleetModel {
    private(set) var mac: PairedMac?
    private(set) var fleet = FleetSnapshot.empty
    private(set) var state = FleetConnector.State.idle
    /// When `state` last became `.connected`. `nil` until the very first connection succeeds
    /// — a fleet that has never been live must not claim it "last said" anything, which is
    /// why the stale banner branches on this being `nil` rather than assuming a value.
    private(set) var lastLive: Date?

    @ObservationIgnored private let store: any PairedMacStoring
    @ObservationIgnored private var connector: FleetConnector?

    init(store: any PairedMacStoring = KeychainPairedMacStore()) {
        self.store = store
        self.mac = store.load()
        if mac != nil { connect() }
    }

    /// Throws `PairingPayloadError`, which the pairing screen turns into copy.
    func adopt(code: String) throws {
        let payload = try PairingPayload(decoding: code)
        let mac = PairedMac(adopting: payload)
        store.save(mac)
        self.mac = mac
        connect()
    }

    func unpair() {
        connector?.stop()
        connector = nil
        // Destroying the secret, not just hiding the fleet: a phone that "unpaired" while
        // keeping a working key is a device the user believes is revoked and is not.
        store.clear()
        mac = nil
        fleet = .empty
        state = .idle
        lastLive = nil
    }

    func markRead(_ id: UUID) { connector?.send(.markRead(id: id)) }

    func reconnect() {
        connect()
    }

    private func connect() {
        guard let mac else { return }
        // `connect()` replaces `self.connector` unconditionally below. Without this stop, a
        // second call while one is already running (e.g. `adopt(code:)` firing again because
        // the QR scanner is still live and hands another frame to `onCode`, see C1 in the
        // Task 10 review) orphans the previous connector rather than tearing it down — and
        // the orphan keeps running against its own, now-stale `mac`, calling `store.save(mac)`
        // on every event and silently overwriting the pairing this call just wrote.
        connector?.stop()
        let connector = FleetConnector(mac: mac, store: store)
        // `MainActor.assumeIsolated`, not `Task { @MainActor in }`. FlightDeckMobile builds in
        // Swift 6, and these callbacks are plain non-isolated closures, so assigning
        // main-actor state from one is an error the compiler cannot see past on its own. But
        // `FleetConnector`'s queue defaults to `.main`, so the closure genuinely IS on the
        // main queue — `assumeIsolated` states a fact rather than hiding a hazard. A `Task`
        // hop would instead add a real frame of latency to every fleet update and let two
        // updates land out of order, which is a live bug in exchange for a tidier diagnostic.
        //
        // This is only true while the connector runs on `.main`. If it is ever given its own
        // queue, these must become hops and this comment must go.
        connector.onFleet = { [weak self] fleet in
            MainActor.assumeIsolated { self?.fleet = fleet }
        }
        connector.onState = { [weak self] state in
            MainActor.assumeIsolated {
                self?.state = state
                if case .connected = state { self?.lastLive = Date() }
            }
        }
        self.connector = connector
        connector.start()
    }

    var isLive: Bool {
        if case .connected = state { return true }
        return false
    }

    var macName: String { mac?.macName ?? "your Mac" }
}
