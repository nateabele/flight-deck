import FleetKit
import Foundation
import Observation
import UIKit

/// Everything both screens talk to, and nothing more.
///
/// Deliberately thin: it owns a store and a connector, both of which are already tested in
/// `FleetKit` against real sockets on macOS, so anything here that would be worth testing on
/// its own belongs in `FleetKit` instead — keeping this file glue is what keeps that true.
///
/// What does NOT belong in `FleetKit` is the ordering this file imposes on the store: a save
/// that fails must abort the adoption rather than leave a pairing that exists only in memory.
/// That is asserted by `FleetModelTests` in `FlightDeckMobileTests`, which runs on the
/// simulator — see `scripts/test-ios.sh`.
@MainActor
@Observable
final class FleetModel: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
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
    /// One open session's model per tab id, kept so that going back to the list and forward
    /// again shows the conversation the phone already holds instead of re-downloading it.
    ///
    /// **`@ObservationIgnored` is load-bearing, not tidiness.** `timelineModel(for:)` inserts
    /// into this from inside a `navigationDestination` closure — that is, during a view
    /// update — and an observed mutation there would invalidate the very view that is being
    /// built. Nothing renders this dictionary; the screens observe the models in it.
    @ObservationIgnored private var timelineModels: [UUID: SessionTimelineModel] = [:]

    init(store: any PairedMacStoring = KeychainPairedMacStore()) {
        self.store = store
        self.mac = store.load()
        // A cold launch asks for EVERYTHING, whatever cursor the pairing was saved with.
        //
        // `lastSeq` is a resume cursor: `hello(lastSeq:)` with a non-zero value means "send
        // only what changed after that", and only zero means "send the whole snapshot"
        // (Frames.swift). It is persisted with the pairing, but `fleet` is NOT — it starts at
        // `.empty` every launch and nothing restores it. So a relaunch used to say "I am at
        // seq N" while holding no snapshot at all, get a handful of deltas back, apply them to
        // nothing, and sit there fully connected and completely empty — which the list then
        // reported, correctly and uselessly, as "No sessions yet".
        //
        // It never recovered on its own, either: the cursor was already current, so the Mac
        // had nothing further to send and no reason to resend what it had.
        //
        // The invariant this restores is that a resume cursor and the snapshot it resumes onto
        // must persist together or not at all. Here that is "not at all" — one extra full
        // snapshot per launch, which is what this protocol does for a first-time pairing
        // anyway. Reconnects DURING a run still resume, because `mac.lastSeq` advances
        // normally from here; only the value inherited from disk is discarded.
        //
        // Persisting the snapshot instead would also close this, and would additionally make
        // the list appear instantly. It is the better end state and is deliberately not done
        // here: a restored snapshot must also restore `lastLive`, or the list renders stale
        // data with no way to tell it from live — the exact failure `FleetListScreen`'s stale
        // banner exists to prevent.
        mac?.lastSeq = 0
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
    ///
    /// Internal rather than private, for the same reason `KeychainPairedMacStore.attributes`
    /// is: this is the only entry to the typed path's keychain write, and `pair(code:)`
    /// cannot reach it from a test without a real Bonjour browse and a real armed Mac. See
    /// `FleetModelTests.testTypedPairingReportsAKeychainFailureInsteadOfLookingPaired`.
    func adopt(key: FleetDeviceKey, serviceName: String, macName: String) {
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
    ///
    /// Internal rather than private so the four mappings can be asserted directly — reaching
    /// them through `pair(code:)` needs a Mac that refuses a code, which no unit test has.
    /// `.wrongCode` and `.attemptsExhausted` in particular send the user in opposite
    /// directions, and swapping them spends one of three tries teaching them nothing.
    static func message(for failure: PairingInitiator.Failure) -> String {
        switch failure {
        case .wrongCode:
            return "No Mac on this network accepted that code. Check it against your Mac's screen."
        case .attemptsExhausted:
            return "Too many tries. Show a new code on your Mac and start again."
        case .unreachable:
            return "Couldn't reach that Mac. Check you're both on the same Wi-Fi."
        case .droppedByMac:
            return "That Mac closed the connection before finishing. Try the code again."
        case .noAnswer:
            // Deliberately does NOT say "check your Wi-Fi": reaching this case means the
            // connection came UP, so the network is demonstrably working and that advice
            // points away from the fault. Naming the firewall is the useful half — the one
            // real instance of this was a listener that accepted the connection and never
            // replied.
            return "That Mac answered the connection but not the pairing. "
                + "It may be busy, or something on it is blocking Flight Deck."
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
        // Held conversation content is as much "this pairing" as the snapshot is. A phone
        // that unpaired and kept a session's transcript in memory is showing the user
        // something they believe they revoked — and it is what the next pairing, to a
        // different Mac, would open a session onto if a tab id ever collided.
        timelineModels.removeAll()
        state = .idle
        lastLive = nil
        pairingProgress = nil
        pairingFailure = nil
    }

    func markRead(_ id: UUID) { connector?.send(.markRead(id: id)) }

    /// Which session this phone is looking at, or nil on leaving. Fire-and-forget: presence
    /// is cosmetic, and a dropped report costs a badge rather than correctness — the Mac
    /// prunes on disconnect regardless.
    func viewing(_ session: UUID?) { connector?.send(.viewing(session: session)) }

    /// Rename a tab. The title is sanitised on the Mac, per agent — see the command.
    func renameSession(_ id: UUID, to title: String) {
        connector?.send(.renameSession(id: id, title: title))
    }

    /// Close a tab on the Mac. Destructive, and gated behind a confirming gesture on screen.
    func closeSession(_ id: UUID) { connector?.send(.closeSession(id: id)) }

    /// Collapse or expand a project. Sends the TARGET state, never a toggle, so two clients
    /// that disagree about what is currently collapsed converge instead of ping-ponging.
    func setCollapsed(_ isCollapsed: Bool, project id: UUID) {
        connector?.send(.setProjectCollapsed(id: id, isCollapsed: isCollapsed))
    }

    /// Open a new session in a project, with that project's own defaults.
    ///
    /// Nothing is sent but the project: agent, account and working directory are resolved on
    /// the Mac, which is the only place they are configured.
    func newSession(inProject id: UUID) { connector?.send(.newSession(project: id)) }

    /// The model behind one session screen, made once and kept.
    ///
    /// **Cached because the alternative is a screen that empties itself.** A
    /// `navigationDestination` closure runs again on any change to what it reads — a fleet
    /// event, a title, the connection state — and a model built inside it would be a *new*
    /// model each time, with an empty feed and a `.latest` fetch to fill it. Held here, the
    /// screen keeps its conversation, its scroll position and its cursors across every
    /// re-evaluation, and `SessionTimelineModel.loadLatest` asks for what is new rather than
    /// for the end of the file again.
    ///
    /// Keyed on the **tab id**, never the conversation id: the latter is not stable across a
    /// re-pin and, for codex, differs from the tab id from birth — the same rule the fleet
    /// list's `ForEach` states.
    ///
    /// The models hold this object back (`SessionTimelineModel` keeps its pager strongly),
    /// which is a cycle broken in `unpair()` and bounded by the app's own lifetime otherwise:
    /// there is exactly one `FleetModel` and it outlives every screen.
    func timelineModel(for id: UUID) -> SessionTimelineModel {
        if let existing = timelineModels[id] { return existing }
        let model = SessionTimelineModel(sessionID: id, fleet: self)
        timelineModels[id] = model
        return model
    }

    /// Ask the Mac for a page of a session's conversation.
    ///
    /// Forwarded rather than absorbed: the connector answers **exactly once**, including with
    /// `.disconnected` when nothing is connected or the socket dies mid-fetch, and adding a
    /// layer that could swallow that would put a spinner on screen forever with nothing to
    /// explain it. This model's job is to hand the callback through unchanged.
    ///
    /// The `guard` completes **synchronously**, which is the same asymmetry
    /// `FleetConnector.request(_:then:)` documents and for the same reason: a command's effect
    /// comes back as a northbound event, so dropping one is merely ineffective, while dropping
    /// a request is a caller waiting forever. A caller must therefore expect its completion to
    /// run before this call returns — `SessionTimelineModel.fetch` arms its deadline first for
    /// exactly that reason.
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.request(request, then: completion)
    }

    /// Ask the Mac to type something into a session's agent.
    ///
    /// Forwarded rather than absorbed, exactly as `timelinePage` is: the connector answers
    /// **exactly once**, including with `.disconnected` when nothing is connected or the
    /// socket dies mid-send, and a layer here that could swallow that would leave a person
    /// believing they told an agent something.
    ///
    /// The `guard` completes **synchronously**, the same asymmetry
    /// `FleetConnector.send(_:then:)` documents — a caller must expect its completion to run
    /// before this call returns, which is why `SessionTimelineModel.send` arms its deadline
    /// first.
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }

    /// Answer a blocked dialog. Forwarded rather than absorbed, exactly as `sendPrompt` is:
    /// the connector answers **exactly once**, including with `.disconnected`, and a layer here
    /// that could swallow that would leave a person believing they told an agent to proceed.
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }

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
        // Routed to the tab's own model rather than held here: the outbox belongs to the
        // screen that sent the prompt, and `timelineModels` is already the map from a session
        // to it. A tab with no live model dropped the event on purpose — there is no outbox
        // row to fail, because the row only exists while that screen's model does.
        connector.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                guard case .promptExpired(let id, let token) = event else { return }
                self?.timelineModels[id]?.promptExpired(token)
            }
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
