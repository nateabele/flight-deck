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
final class FleetModel: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting, TranscriptSearching {
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
    /// One token per session that has asked to abort a blocked dialog, minted on first use and
    /// reused after — see `abortBlockedPrompt(session:)`'s own comment for why this is scoped
    /// to the pairing rather than to the blocked episode.
    @ObservationIgnored private var blockedAbortTokens: [UUID: UUID] = [:]
    /// Every `FleetCommand` handed to `sendPrompt`, in order. Exists for tests only:
    /// `FleetModel.fixture()` leaves `connector` nil, so `sendPrompt` completes synchronously
    /// with `.disconnected` and there would otherwise be nothing to assert `abortBlockedPrompt`
    /// against — no protocol stub sits between it and `sendPrompt`, both being methods on this
    /// same type.
    @ObservationIgnored private(set) var sentCommands: [FleetCommand] = []

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
        // Same reasoning as the transcripts above: a closed tab's title is this pairing's
        // content, not fleet-independent fact, and the next Mac's project paths coinciding
        // with this one's would otherwise render titles that Mac never closed.
        recentlyClosed = []
        // The dedup this guards is scoped to a pairing, not to a device: a token minted for
        // this Mac's session id would collapse a genuinely new abort on a *different* Mac that
        // later reuses the same id, which is exactly the reuse `unpair()` already guards against
        // above for `timelineModels`.
        blockedAbortTokens.removeAll()
        state = .idle
        lastLive = nil
        pairingProgress = nil
        pairingFailure = nil
    }

    func markRead(_ id: UUID) { connector?.send(.markRead(id: id)) }

    /// Put the unread mark back on a session the reader wants to return to.
    ///
    /// The counterpart to `markRead`, and it exists because unread is one fleet-wide fact
    /// rather than a per-client one (spec §8): a session the phone opened is read on the Mac
    /// too, so the phone has to be able to undo that or the mark is a one-way door from
    /// whichever screen happened to see it first.
    ///
    /// Fire and forget in both directions, exactly like `markRead`: the command is a no-op
    /// while disconnected, and the row does not change until the Mac echoes an
    /// `unreadChanged` back. Nothing here sets it optimistically — a dot that appears and
    /// then vanishes when the Mac disagrees is worse than one that takes a moment.
    func markUnread(_ id: UUID) { connector?.send(.markUnread(id: id)) }

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

    /// Open a session as a particular row of the project's New Session menu.
    ///
    /// The row is named by its agent and its position among that agent's accounts, never by an
    /// account id — see `WireNewSessionOption`. The Mac re-resolves both and falls back to the
    /// project's default if the agent no longer matches.
    func newSession(inProject id: UUID, agent: String, accountIndex: Int) {
        connector?.send(.newSession(project: id, agent: agent, accountIndex: accountIndex))
    }

    /// What each project's `+` should offer, as last answered.
    ///
    /// **Absent and empty are different states and are held apart.** A project with no entry
    /// has not been answered — the request is in flight, or this Mac predates the feature and
    /// never will — and falls back to the single default row. A project whose entry is an
    /// empty array *was* answered, and the answer was that nothing can be launched: every
    /// agent was omitted for having no live account. That greys the `+` out. Collapsing the
    /// two would offer a row whose only possible outcome is a refusal from the far end.
    private(set) var newSessionOptions: [UUID: [WireNewSessionOption]] = [:]

    /// Ask for every project's rows.
    ///
    /// **One request per project**, mirroring `timeline.page`: the reply path already
    /// correlates by `cid`, and N small independent fetches mean one slow project cannot hold
    /// up the rest of the list.
    ///
    /// Called when the list appears, on reconnect, and on returning to the foreground. The
    /// third is the one that matters: the rows derive from preferences, preferences emit no
    /// fleet events, and there is no hook to push a change from — so the only moment the phone
    /// can learn that an account was signed in on the Mac is the moment someone picks the phone
    /// up and it asks again.
    func refreshNewSessionOptions() {
        guard let connector else { return }
        for project in fleet.projects {
            connector.requestNewSessionOptions(project: project.id) { [weak self] result in
                guard let self, case .success(let answer) = result else { return }
                self.newSessionOptions[answer.project] = answer.options
            }
        }
    }

    /// Every historical conversation the Mac's index knows a name for, plus every live tab's
    /// recency — what `PhoneSearchCandidates.build` turns into the name half of search. `nil`
    /// until the first reply, exactly like `newSessionOptions`'s per-project entries: absent
    /// and empty are different states, and a phone that has not yet asked must not render as
    /// though it asked and found nothing.
    private(set) var conversationCatalogue: WireConversationCatalogue?

    /// Ask for the whole conversation catalogue.
    ///
    /// Called when the fleet list appears, on reconnect, and on returning to the foreground —
    /// see `connect()`'s `onFleet` closure, which is every one of those moments at once. That
    /// single placement is deliberate, the same reasoning `refreshNewSessionOptions` gives:
    /// the catalogue is a request's answer, not fleet state, so nothing pushes it when it goes
    /// stale — the only moment the phone can learn about it is the moment someone looks.
    func refreshConversations() {
        guard let connector else { return }
        connector.requestConversations { [weak self] result in
            guard let self, case .success(let catalogue) = result else { return }
            self.conversationCatalogue = catalogue
        }
    }

    /// Every reopenable tab the Mac is holding, across all projects, most recent first.
    ///
    /// One flat list rather than a per-project dictionary, because the Mac keeps one stack:
    /// `FleetListScreen.closedRows(in:forProjectAt:)` buckets it by `projectPath` at render
    /// time. Empty until the first answer, and `refreshRecentlyClosed` puts it back to empty
    /// on every refusal too — an older Mac, or one downgraded under a live phone, always
    /// leaves this empty — so the section simply never renders there. Absent and empty do not
    /// need holding apart here, unlike `newSessionOptions`: both mean "no rows to show" and
    /// neither changes anything else on the screen.
    private(set) var recentlyClosed: [WireClosedSession] = []

    /// Ask for the whole reopen stack.
    ///
    /// Hung off `connect()`'s `onFleet`, which fires on snapshots **and on every folded
    /// event** — so a close at either end refreshes this without needing a hook of its own.
    /// That matters more here than for `refreshNewSessionOptions`, which shares the hook: a
    /// session the phone itself just closed has to appear in that project's `+` immediately,
    /// not after a background-and-return.
    func refreshRecentlyClosed() {
        guard let connector else { return }
        connector.requestRecentlyClosed { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let closed):
                self.recentlyClosed = closed
            case .failure(.disconnected):
                // Transient: the socket died, not the Mac's opinion of this request. A phone
                // that blanked the section on every dropped Wi-Fi bar would lose it and win
                // it back on a flicker, which is worse than showing a beat-stale list until
                // the next reconnect answers for real.
                break
            case .failure(.server):
                // A refusal from *this* Mac — `unsupported`, from a build too old to decode
                // the request — and that will not change while it stays this build. Clearing
                // here is what keeps `reopenClosed` unreachable per the property `FleetCommand`
                // documents: a Mac downgraded under a live phone must lose the section, not
                // just fail to refresh it, or the last-cached row survives to be tapped
                // against a Mac that cannot decode the command it sends.
                self.recentlyClosed = []
            }
        }
    }

    /// Reopen a closed tab on the Mac. Fire-and-forget, exactly like `newSession`: the tab
    /// arrives as a `sessionAdded` event and the list redraws itself.
    func reopenClosed(_ id: UUID) {
        connector?.send(.reopenClosed(session: id))
    }

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
        sentCommands.append(command)
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.send(command, then: completion)
    }

    /// Escape at a dialog nothing on this build can read — see `FleetCommand.abortPrompt`'s own
    /// comment for why it names a session rather than a call, and `PromptCard.showsBlocked` for
    /// when this is ever offered at all.
    ///
    /// **One token per session, minted once and reused on every later call.** The button gives
    /// no feedback of its own — nothing tears the Blocked card down until the Mac's status
    /// actually moves on — so a second tap is the ordinary response to the first appearing to
    /// do nothing. Sent with the same token, it reaches `SessionStore.answeredPromptTokens` as
    /// a replay and collapses to `.duplicate` there rather than pressing Escape twice.
    ///
    /// **Scoped to the session for the pairing's lifetime, not to the blocked episode.**
    /// Nothing held here distinguishes "the same dialog, tapped again" from "a new dialog on a
    /// session that was blocked before" — both are just this session's id — and the Mac's own
    /// table draws no finer a line either: it clears `id`'s tokens only when that tab closes
    /// (`SessionStore`), not per dialog. A phone-side cache keyed any narrower would claim a
    /// precision neither end of the wire actually has. `unpair()` clears this, alongside
    /// `timelineModels`, for the same reason: a token minted for one Mac's session id must not
    /// dedup an abort meant for a different Mac that later reuses it.
    func abortBlockedPrompt(session id: UUID) async {
        let token = blockedAbortTokens[id] ?? UUID()
        blockedAbortTokens[id] = token
        sendPrompt(.abortPrompt(id: id, token: token)) { _ in }
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

    /// Search transcript content for `query`. Forwarded rather than absorbed, exactly as
    /// `timelinePage` is: the connector answers **exactly once**, including with
    /// `.disconnected` when nothing is connected or the socket dies mid-search, and a layer
    /// here that could swallow that would leave `SessionSearchModel` waiting on a footer that
    /// never arrives.
    ///
    /// `limit` is clamped with `SearchLimits.maxHits` here rather than trusted from the
    /// caller — the same ceiling the Mac itself clamps to (`FleetService`'s `.search` handler),
    /// so a phone-side bug that asked for more could not cost the Mac an unbounded query.
    func searchTranscripts(
        query: String, limit: Int,
        then completion: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.requestSearch(query: query, limit: min(limit, SearchLimits.maxHits), then: completion)
    }

    /// Resume a closed conversation, or select it if it is already open. Forwarded rather
    /// than absorbed, exactly as `searchTranscripts` is: the connector answers **exactly
    /// once**, including with `.disconnected`, and a layer here that could swallow that would
    /// leave a tapped search result spinning forever with nothing pushed.
    func requestOpenConversation(
        conversationID: String, projectPath: String,
        then completion: @escaping (Result<UUID, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.requestOpenConversation(
            conversationID: conversationID, projectPath: projectPath, then: completion
        )
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
            MainActor.assumeIsolated {
                self?.fleet = fleet
                // **Every snapshot, which is every connect** — first dial, reconnect, and the
                // redial on return from the background. That covers all three moments the
                // menu can have gone stale without a single one of them needing its own hook,
                // because preferences emit no fleet events and there is nothing to be told.
                //
                // A project that appears later by event, rather than in a snapshot, has no
                // rows until the next connect and falls back to the default row. That is the
                // supported state, not a gap: it is also what an older Mac produces forever.
                self?.refreshNewSessionOptions()
                // Same reasoning, same placement: the catalogue is a request's answer, not
                // fleet state (see `conversationCatalogue`'s doc comment), so this is the only
                // hook it gets.
                self?.refreshConversations()
                // Same hook, and here the "every folded event" half is the point rather than a
                // side effect — see `refreshRecentlyClosed`.
                self?.refreshRecentlyClosed()
            }
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
                if case .connected = state {
                    self?.lastLive = Date()
                    // Every model is told, not only the one on screen: `timelineModels` is
                    // never evicted, so a reader who has opened ten sessions holds ten of
                    // these, and each decides for itself via `isOnScreen` whether a resumed
                    // link is its business. `.connected` is the right signal to fan out here
                    // because it fires once per successful dial and covers snapshot, replay
                    // and empty-replay alike — unlike the open session's own triggers
                    // (`.task(id:)`, its two `.onChange`s, the busy poll), none of which fire
                    // on a reconnect that changes nothing the screen was already watching.
                    // `FleetConnector.accept()` sets `winner` before reporting `.connected`
                    // (FleetConnector.swift:521,530), so `linkResumed()`'s own calls back out
                    // through `fleet` already ride the new link rather than a dead one.
                    self?.timelineModels.values.forEach { $0.linkResumed() }
                }
                PhoneLog.connection.notice("state \(Self.describe(state), privacy: .public)")
            }
        }
        // The counterpart to the Mac's own `resume lastSeq=… mode=…` line, and the reason
        // `FleetConnector.onSnapshot` exists at all: `onFleet` fires for snapshots and for
        // every folded event alike, so it cannot say which of the two just happened — and
        // "I threw away my history and took a whole new snapshot" is exactly the fact a
        // stale-card report needs from this end.
        connector.onSnapshot = { seq, reason in
            MainActor.assumeIsolated {
                PhoneLog.connection.notice(
                    "snapshot seq=\(seq) reason=\(reason.rawValue, privacy: .public)"
                )
            }
        }
        // The phone's half of the log fetch. Wired here rather than inside `FleetConnector`
        // because reading `OSLogStore` needs `OSLog`, which FleetKit deliberately does not
        // import — see `FleetConnector.onPhoneRequest`.
        connector.onPhoneRequest = { request, reply in
            MainActor.assumeIsolated {
                switch request {
                case .logs(let seconds, let limit):
                    let answer = PhoneLog.entries(seconds: seconds, limit: limit)
                    // Logged before the reply goes out, so the fetch itself appears in the
                    // NEXT fetch — which is how a reader tells "the Mac asked and got nothing"
                    // from "the Mac never asked".
                    switch answer {
                    case .success(let logs):
                        // Composed first, then logged as one interpolation: `OSLogMessage` is
                        // not a `String` and cannot be concatenated.
                        let served = "logs served seconds=\(seconds)"
                            + " entries=\(logs.entries.count) truncated=\(logs.truncated)"
                        PhoneLog.connection.notice("\(served, privacy: .public)")
                    case .failure(let refusal):
                        PhoneLog.connection.error(
                            "logs refused code=\(refusal.code, privacy: .public)"
                        )
                    }
                    reply(answer)
                }
            }
        }
        // Before `start()`, so the line is in the log ahead of whatever the dial produces.
        // `lastSeq` is what this phone is about to ask to resume from — zero on a cold launch
        // by design, see `init`.
        let dialing = "dialing lastSeq=\(mac.lastSeq) endpoints=\(mac.endpoints.count)"
        PhoneLog.connection.notice("\(dialing, privacy: .public)")
        self.connector = connector
        connector.start()
    }

    /// One short, structural word per state — never the Mac's name, which is a user-chosen
    /// string and has no business crossing back over the wire in a diagnostic.
    private static func describe(_ state: FleetConnector.State) -> String {
        switch state {
        case .idle: return "idle"
        case .searching: return "searching"
        case .connected: return "connected"
        case .lost(let retryingIn): return "lost retrying-in=\(Int(retryingIn))s"
        }
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
