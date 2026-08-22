import FleetKit
import Foundation
import Observation
import UIKit

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
    /// Where a typed pairing has got to, or `nil` when none is running. Drives the pairing
    /// screen's progress line; `nil` again the moment it ends, either way.
    private(set) var pairingProgress: PairingRunner.Progress?
    /// Copy for a pairing that ended badly. Separate from `pairingProgress` because the screen
    /// keeps showing this after the run is over, and a progress value that lingered would
    /// leave a spinner beside an error.
    private(set) var pairingFailure: String?

    @ObservationIgnored private let store: any PairedMacStoring
    @ObservationIgnored private var connector: FleetConnector?
    @ObservationIgnored private var runner: PairingRunner?

    init(store: any PairedMacStoring = KeychainPairedMacStore()) {
        self.store = store
        self.mac = store.load()
        if mac != nil { connect() }
    }

    /// Throws `PairingPayloadError` or `PairedMacStoreError`, both of which the pairing
    /// screen turns into copy.
    ///
    /// The save comes FIRST and its failure aborts the adoption, which is the whole point of
    /// it throwing. A pairing that only exists in memory looks exactly like a working one —
    /// the fleet arrives, the list fills in — right up until the next launch, when `load()`
    /// returns nil and the phone is back at the QR screen with nothing to explain why. Better
    /// to refuse the pairing now and say so than to hand the user a session that is already
    /// over.
    func adopt(code: String) throws {
        let payload = try PairingPayload(decoding: code)
        let mac = PairedMac(adopting: payload)
        try store.save(mac)
        self.mac = mac
        connect()
    }

    /// Pair by typed code: browse for armed Macs, try each in turn, store whichever accepts.
    ///
    /// Takes a `PairingCode`, never a `String` — the checksum is checked in `PairingScreen`
    /// before this is reached, and the type is what makes "a failed checksum never becomes an
    /// attempt" (spec §7) structural rather than a rule.
    func pair(code: PairingCode) {
        // Replaces any run already in flight. Without this a second tap orphans the first
        // runner, which keeps browsing and can complete a pairing the user has moved on from.
        runner?.cancel()
        pairingFailure = nil
        pairingProgress = .searching

        let runner = PairingRunner()
        runner.onProgress = { [weak self] progress in
            // `MainActor.assumeIsolated`, not a `Task` hop, for the reason `connect()`'s own
            // comment gives: `PairingRunner`'s queue defaults to `.main`, so this genuinely IS
            // the main queue, and a hop would let two progress updates land out of order.
            MainActor.assumeIsolated {
                guard let self else { return }
                switch progress {
                case .searching, .trying:
                    self.pairingProgress = progress
                case .paired:
                    self.pairingProgress = nil
                case .noMacsFound:
                    self.pairingProgress = nil
                    // Not a verdict on the code: the typed path is LAN-only by design
                    // (spec §11), and the QR carries endpoints that work off it.
                    self.pairingFailure =
                        "Can't find that Mac on this network. Scan the QR code instead."
                case .failed(let failure):
                    self.pairingProgress = nil
                    self.pairingFailure = Self.message(for: failure)
                }
            }
        }
        runner.onPaired = { [weak self] key, serviceName, macName in
            MainActor.assumeIsolated {
                self?.adopt(key: key, serviceName: serviceName, macName: macName)
            }
        }
        self.runner = runner
        runner.start(code: code)
    }

    /// Stores what the exchange delivered and connects.
    ///
    /// **No endpoints, deliberately.** Typed pairing is LAN-only by design (spec §11), and
    /// `FleetConnector` reaches a Mac with an empty remembered list purely by browsing
    /// `_flightdeck._tcp` for `serviceName` — which is why `serviceName` here is the Bonjour
    /// instance name the runner actually dialled, not anything derived. `macName` comes out of
    /// the seal, so it is authenticated; the browse result's display name was not.
    private func adopt(key: FleetDeviceKey, serviceName: String, macName: String) {
        let mac = PairedMac(key: key, macName: macName, serviceName: serviceName, endpoints: [])
        // Saved BEFORE it is adopted, and a failure aborts — the same order and the same
        // reason as `adopt(code:)` above: a pairing that only exists in memory looks like a
        // working one until the next launch.
        do {
            try store.save(mac)
        } catch let error as PairedMacStoreError {
            // The exchange succeeded and the phone cannot keep the result. Saying "try again"
            // would be a lie — the retry runs the identical keychain write.
            pairingFailure = PairingScreen.message(for: error)
            return
        } catch {
            pairingFailure = "Couldn't save this pairing to the keychain."
            return
        }
        self.mac = mac
        runner = nil
        connect()
    }

    /// Each failure says what to do next. One message for all of them would leave a user
    /// retyping a code whose window is already burned.
    private static func message(for failure: PairingInitiator.Failure) -> String {
        switch failure {
        case .wrongCode:
            return "No Mac on this network accepted that code. Check it against your Mac's screen."
        case .attemptsExhausted:
            return "Too many tries. Show a new code on your Mac and start again."
        case .connectionFailed:
            return "Couldn't reach that Mac. Check you're both on the same Wi-Fi."
        case .malformedResponse:
            return "That Mac answered with something Flight Deck didn't understand. Update both apps."
        }
    }

    func unpair() {
        // A run in flight outlives the pairing it was started from unless it is stopped here:
        // it would keep browsing and could adopt a Mac onto a model the user just cleared.
        runner?.cancel()
        runner = nil
        connector?.stop()
        connector = nil
        // Destroying the secret, not just hiding the fleet: a phone that "unpaired" while
        // keeping a working key is a device the user believes is revoked and is not.
        store.clear()
        mac = nil
        fleet = .empty
        state = .idle
        lastLive = nil
        pairingProgress = nil
        pairingFailure = nil
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
        let connector = FleetConnector(mac: mac, store: store, deviceName: Self.deviceName)
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

    var macName: String { mac?.macName ?? "your Mac" }

    /// What this phone tells the Mac to call it, sent in `hello`.
    ///
    /// Read here rather than in FleetKit because FleetKit cannot import UIKit — see
    /// `FleetConnector.deviceName`. And know what this actually returns before trusting it:
    /// since iOS 16 `UIDevice.current.name` yields the *model* name ("iPhone", "iPad") for
    /// any app without the user-assigned-device-name entitlement, which this app does not
    /// have. Only on the simulator does it give the device's own name. So expect every
    /// paired handset to arrive claiming "iPhone" — better than a placeholder, and precisely
    /// why the Mac lets the user rename a device in Settings > Devices.
    private static var deviceName: String { UIDevice.current.name }
}
