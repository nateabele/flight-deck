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

    /// Held while a pairing exists and the fleet is listening; see `refreshSleepAssertion`.
    private var sleepAssertion: (any NSObjectProtocol)?

    /// Which session each live connection is looking at.
    private var viewingByClient: [UUID: UUID] = [:]

    /// Sessions some phone currently has open. Drives the sidebar's presence badge.
    @Published private(set) var phoneActiveSessions: Set<UUID> = []

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let store: SessionStore
    private let preferences: PreferencesStore
    private let armer: PairingArmer
    private let server: FleetSocketServer
    private let replicator: FleetReplicator
    /// Answers history requests. Held here rather than built per request because it holds the
    /// store, and because there is exactly one of it — a request carries its own session id,
    /// so nothing about it is per-connection.
    private let timeline: TimelineService
    /// Carries out a phone's answer to a blocked dialog. Held here rather than built per
    /// command for the reason `timeline` is: it holds the store, and there is exactly one of
    /// it — a command carries its own session id, so nothing about it is per-connection.
    private let prompts: PromptService
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
        self.timeline = TimelineService(store: store)
        self.prompts = PromptService(store: store)
        self.serviceName = Self.derivedServiceName(preferences: preferences)
        store.replicator = replicator
        wireHandlers()
    }

    /// The rows of one project's New Session menu, or nil when there is no such project.
    ///
    /// Built from `NewSessionAffordance.menu(agents:preferences:resolved:)` — the same call the
    /// sidebar makes, with the same arguments — so the two menus cannot disagree.
    private func newSessionOptions(for project: UUID) -> WireNewSessionOptions? {
        guard let path = store.projectPath(project) else { return nil }
        let rows = NewSessionOptionsProjection.rows(for: menuEntries(forProjectAt: path)) {
            preferences.account(id: $0)?.displayName
        }
        // An empty answer is a real answer: every agent was omitted for having no live
        // account. The phone greys its `+` out rather than offering a row that cannot launch.
        return WireNewSessionOptions(project: project, options: rows)
    }

    private func menuEntries(forProjectAt path: String) -> [NewSessionAffordance.MenuEntry] {
        let agents = preferences.agentOrder(forProject: path)
        return NewSessionAffordance.menu(
            agents: agents, preferences: preferences.preferences,
            resolved: preferences.resolvedAccounts(for: agents, project: path)
        )
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
        // The rule on `closePairingListener()`, wired: the armer fires this from the one place
        // it clears `pending`, so cancel, expiry and a claimed slot all close the listener
        // without any of them naming it. This is the only thing that closes the window on the
        // QR path — a phone that scanned the code never touches the pairing listener, so
        // `armer.claim` is the sole witness that pairing finished.
        armer.onWindowClosed = { [weak self] in self?.closePairingListener() }
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
        server.onCommand = { [weak self] client, cid, command in
            self?.apply(command, from: client, cid: cid) ?? .err(cid: cid, code: "stopped")
        }
        server.onRequest = { [weak self] _, cid, request, reply in
            guard let self else { return reply(.err(cid: cid, code: "stopped")) }
            switch request {
            case .timeline(let session, let anchor, let limit):
                // A `Task` rather than a synchronous answer, because reading a page is file
                // I/O: `TimelineService` hands the parse to a detached task and resumes here
                // on the main actor, which is `queue`. `reply` is therefore called on
                // `queue`, as `onRequest` requires — and after an await, which is exactly the
                // case `FleetSocketServer`'s deferred-send guard is written for.
                //
                // Nothing here writes: the answer is composed from the transcript on disk and
                // the store is only ever asked to resolve the tab. That is what keeps the
                // history channel out of the fleet event log entirely — no `FleetEvent`, no
                // broadcast, and nothing new for `FleetReplicator`'s drift check to guard.
                Task { @MainActor in
                    switch await self.timeline.page(
                        session: session, anchor: anchor, limit: limit
                    ) {
                    case .success(let page): reply(.page(cid: cid, page))
                    // `.code` is the wire spelling, verbatim — see `TimelineErrorCode`.
                    case .failure(let code): reply(.err(cid: cid, code: code.code))
                    }
                }
            case .newSessionOptions(let project):
                // Answered synchronously: this reads preferences and the project list, both of
                // which are already on this actor. No file I/O, so nothing to hop for.
                //
                // Nothing here writes and nothing enters `FleetSnapshot` — which is the whole
                // design. Menu rows come from preferences, preferences emit no fleet events,
                // and a snapshot that changed without one is what `FleetReplicator`'s drift
                // assertion catches. It caught it once already; see the spec.
                guard let options = self.newSessionOptions(for: project) else {
                    return reply(.err(cid: cid, code: "unknown_project"))
                }
                reply(.newSessionOptions(cid: cid, options))
            case .macEndpoints:
                // Answered synchronously: enumerating interfaces is a syscall, not file I/O,
                // so there is nothing to hop a `Task` for and `reply` lands on `queue` as
                // `onRequest` requires.
                //
                // Nothing here writes and nothing enters `FleetSnapshot` — addresses change
                // with no event recorded, which is exactly the shape `FleetReplicator`'s
                // drift assertion catches.
                guard let boundPort = self.boundPort else {
                    return reply(.err(cid: cid, code: "not_listening"))
                }
                reply(.macEndpoints(
                    cid: cid,
                    LocalEndpoints.routable(port: boundPort.rawValue, limit: 4)
                ))
            }
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
                self.refreshSleepAssertion()
                // A phone that vanished mid-session never sends `viewing(nil)`, so presence is
                // pruned from the authoritative attached set rather than trusted to clean up
                // after itself — otherwise a badge glows for a phone that is gone.
                if slots.isEmpty, !self.viewingByClient.isEmpty {
                    self.viewingByClient.removeAll()
                    self.publishPhonePresence()
                }
            }
        }
    }

    private func publishPhonePresence() {
        phoneActiveSessions = Set(viewingByClient.values)
    }

    /// Keeps the Mac awake for exactly as long as a phone is attached, and no longer.
    ///
    /// A sleeping Mac does not keep its fleet sockets: TCP does not survive system sleep and
    /// nothing here changes that. The alternative — Wake on Demand, where a Bonjour sleep
    /// proxy answers for the sleeping Mac — needs a proxy on the network and `womp` on the
    /// current power source, and on a laptop's battery profile neither is typically true.
    ///
    /// Scoped to a live phone rather than taken for the app's lifetime: an assertion held
    /// whenever Flight Deck runs would flatten a laptop overnight for a phone nobody is using.
    ///
    /// **Prevents IDLE sleep only.** Closing the lid still sleeps and no assertion overrides
    /// that — it is a hardware path, not a policy one.
    /// Held whenever this Mac is REACHABLE by a paired phone — not merely while one is
    /// attached.
    ///
    /// Scoping it to an attached phone was the first version and it could not work, because
    /// the failure it was meant to prevent runs in the opposite order: the phone is put down,
    /// its app is backgrounded, the connection drops, this assertion is released, the Mac
    /// idle-sleeps, and now nothing can wake it to accept the reconnect. The assertion has to
    /// outlive the connection or it only ever protects a session already in progress.
    ///
    /// Gated on there being a pairing at all, so a Mac nobody has paired with sleeps normally.
    /// The cost is real and deliberate: a paired laptop will not idle-sleep while Flight Deck
    /// runs. That IS the feature — "keep it reachable" and "let it sleep" cannot both hold.
    private func refreshSleepAssertion() {
        holdSleepAwake(!preferences.pairedDevices.isEmpty)
    }

    private func holdSleepAwake(_ shouldHold: Bool) {
        if shouldHold, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "A paired phone can reach this Mac"
            )
        } else if !shouldHold, let held = sleepAssertion {
            ProcessInfo.processInfo.endActivity(held)
            sleepAssertion = nil
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
        // Taken here rather than on first attach: a phone can only reconnect to a Mac that is
        // awake, so the assertion has to be up before anyone dials in.
        refreshSleepAssertion()
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
        // Directly, because this is not a `pending` clear: the process is going away and the
        // window's key goes with it. See `closePairingListener()` for the rule that makes
        // these two the only direct calls left.
        closePairingListener()
        // Released here and not left to the attachment signal: `server.stop()` empties the
        // attached set, and an assertion keyed on that would survive a stop that unpaired
        // everything.
        holdSleepAwake(false)
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
        // Before anything else: a second `arm()` must not leave the previous window's listener
        // answering on its old port with its old code. `cancel()` is what closes it — it
        // clears `pending` unconditionally, and the listener follows `pending`.
        armer.cancel()
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
            // `routable`, not `current`: loopback is enumerated and ranked last, but `current`
            // still returns it, and `127.0.0.1:<port>` packs into the QR as happily as any
            // other IPv4:port. On a Wi-Fi-only Mac — no VPN, no VMs, no Internet Sharing, so
            // just `lo0` and `en0` — that spends the code's second slot on a dial the phone
            // makes to itself. The limit is the payload's own cap, so the filtering happens
            // BEFORE the slots are allocated rather than after.
            endpoints: LocalEndpoints.routable(
                port: port, limit: PairingPayload.maxEndpoints
            )
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
    ///
    /// **The rule, which is what to check at a call site — not a list of routes:
    /// the pairing listener's lifetime is `armer.pending`'s lifetime.** Every route that
    /// clears `pending` closes the listener, and it is `PairingArmer.onWindowClosed` that
    /// makes that true rather than any enumeration here: the armer clears `pending` in exactly
    /// one place and fires from it, so cancel, expiry, a claimed slot and anything added later
    /// are all covered without naming them.
    ///
    /// The two direct calls that remain are the two that are *not* a `pending` clear, and each
    /// closes the listener strictly inside `pending`'s life, which the rule permits:
    /// `stop()`, where the process is going away and the window's key dies with it; and the
    /// success path's `onPaired`, which closes the moment the sealed key is out — a turn
    /// before the phone attaches and `claim` clears `pending`.
    ///
    /// The enumerated version of this shipped first and was wrong. It read "success" as
    /// `PairingListener.onPaired` and missed the QR, which is the other success and touches
    /// this socket not at all; the window stayed open, and its code stayed a live key, for as
    /// long as the app ran.
    private func closePairingListener() {
        pairing.stop()
        pairingPort = nil
    }

    func cancelArming() async throws {
        expiryTask?.cancel()
        if let pending = armer.pending { preferences.revokeDevice(slot: pending.slot) }
        // Closes the pairing listener too — see `closePairingListener()` for why that is the
        // armer's job and not a line here.
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
        // Closes the pairing listener when — and only when — it actually clears the window;
        // `expire()` declines at the instant the window ends, and the guard below is that.
        armer.expire()
        guard armer.pending == nil else { return }
        preferences.revokeDevice(slot: pending.slot)
        try await reloadKeys()
    }

    /// Test seam, forwarding to `PromptService.tail` — the same seam `PromptServiceTests`
    /// substitutes, reached through here because `prompts` is private and a loopback test has
    /// no other way to put a transcript in front of it. No production caller.
    var promptTailForTesting: @Sendable (URL, Int) -> [SourceLine] {
        get { prompts.tail }
        set { prompts.tail = newValue }
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
        // `claim` closing the pairing window closes the pairing listener with it, through
        // `PairingArmer.onWindowClosed`. Deliberately not a `closePairingListener()` in the
        // branch body: `claim` clears `pending` from inside the *first* condition of this
        // `if`, and the second one can fail on its own, so a line in here would be a route
        // that closes the window and leaves the listener up.
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

    private func apply(
        _ command: FleetCommand, from client: FleetAttachment, cid: Int
    ) -> ServerFrame {
        switch command {
        case .viewing(let session):
            // Keyed on the CONNECTION id, not the pairing slot: one phone reconnecting is two
            // connections, and keying on the slot would let a dead connection's presence
            // outlive it until the new one happened to report something.
            //
            // No `sessionExists` guard. Presence is cosmetic, and a phone that opened a tab
            // the Mac closed a moment ago should get silence rather than an error it cannot
            // act on — the badge simply has nothing to attach to.
            if let session { viewingByClient[client.id] = session }
            else { viewingByClient.removeValue(forKey: client.id) }
            publishPhonePresence()
        case .markRead(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markRead(id)
        case .markUnread(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markUnread(id)
        case .renameSession(let id, let title):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            // The store refuses a title its agent cannot use — empty after sanitising, or all
            // metacharacters for an agent renamed down a pty. Answered rather than swallowed,
            // so the phone can say why instead of showing a name that never took.
            guard store.rename(id, to: title) else {
                return .err(cid: cid, code: "rejected_title")
            }
        case .closeSession(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            // `recordingHistory` left at its default, so a tab closed from the phone can be
            // reopened by the same undo a tab closed on the Mac can. A phone-specific close
            // that skipped history would be the one destructive action with no way back.
            store.closeSession(id)
        case .setProjectCollapsed(let id, let isCollapsed):
            guard store.projectExists(id) else { return .err(cid: cid, code: "unknown_project") }
            store.setCollapsed(isCollapsed, forProjectAt: id)
        case .newSession(let project, let agent, let accountIndex):
            guard let path = store.projectPath(project) else {
                return .err(cid: cid, code: "unknown_project")
            }
            // After the project lookup, so an unknown project still says so rather than being
            // masked by this. Checked once, ahead of both branches below (the plain `+` tap and
            // the agent/account variant): `store.newSession`/`createSession` would otherwise
            // refuse silently — `newSession(inProject:)` still returns a non-nil `Session`, an
            // un-inserted one, so the phone would see an ordinary ack for a tab that was never
            // created. `ensureTerminalCreatable`, not `canCreateTerminal`: this is the phone's
            // only creation command, so this is the one call that must attempt a wake first
            // rather than just reading whether the display already happens to be drawable.
            guard store.ensureTerminalCreatable() else {
                return .err(cid: cid, code: "terminal_unavailable")
            }
            // Both nil is a plain `+` tap: the project's defaults, exactly as before this
            // feature existed and exactly what an older phone sends.
            guard let agent, let accountIndex, let picked = AgentID(rawValue: agent) else {
                guard store.newSession(inProject: project) != nil else {
                    return .err(cid: cid, code: "unknown_project")
                }
                break
            }
            // Re-resolved now, not read from anything the phone sent: the row it tapped was
            // described from a menu that may since have changed shape. A row whose agent no
            // longer matches falls back to the project's default rather than opening as an
            // account nobody chose — `NewSessionOptionsProjection.account` is where that
            // judgement lives and why.
            let account = NewSessionOptionsProjection.account(
                forAgent: agent, index: accountIndex, in: menuEntries(forProjectAt: path)
            )
            guard account != nil else {
                guard store.newSession(inProject: project) != nil else {
                    return .err(cid: cid, code: "unknown_project")
                }
                break
            }
            // **`createSession(agent:in:…)`, not `createFromMenu`.** The latter is the *menu
            // bar's* entry point and it chooses the directory itself — the active tab's, else
            // the last active project, else the first repo — because a menu click carries no
            // project with it. A tap on the phone does: it names the project it was made on,
            // and routing it through the menu's chooser created the tab in whichever project
            // happened to be selected on the Mac instead. It also swallowed the launch result,
            // so a login that could not start still produced a tab — one with no agent behind
            // it, which the phone correctly draws with no composer at all ("There's no agent
            // running in this tab right now") and which is indistinguishable from a bug in the
            // composer. That is the report this comment exists for.
            Task { @MainActor in
                let created = await self.store.createSession(
                    agent: picked, in: path, account: account
                )
                if case .failure(let error) = created {
                    // The `ack` for this command has already gone — a create is dispatched,
                    // like every other command (§4). Logged rather than dropped so a login
                    // that cannot launch leaves a trace on the Mac rather than only a silent
                    // tab on the phone.
                    Self.logger.error(
                        "new session from phone failed to launch: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        case .prompt(let id, let token, let text):
            // Every refusal, "no such tab" included, is the store's to make: it is the only
            // thing that knows the tab's agent, its status and whether it has a surface, and
            // splitting the checks across two files is how they drift. `sessionExists` above
            // stays where it is for the two commands that have nothing else to check.
            //
            // No validation is repeated here and none should be added. §5's rule is that a
            // command with no existing store method gets one added to the store rather than a
            // special case in the replicator; this is that method.
            if let code = store.submitPrompt(text, token: token, to: id).errorCode {
                return .err(cid: cid, code: code)
            }
        case .answerPrompt(let id, let token, let call, let answer):
            // Every refusal is the service's and the store's to make, for the reason `.prompt`
            // states: they are the only things that know the tab's agent, its status, its
            // transcript and its screen, and splitting the checks across two files is how they
            // drift. No validation is repeated here and none should be added — not even the
            // `sessionExists` the two read marks do, which `PromptService` answers as
            // `unknown_session` from the source it has to resolve anyway.
            //
            // Synchronous, and it must stay synchronous: `onCommand` answers inline, and
            // `PromptService.answer`'s read is a tail sized for exactly that.
            if case .failure(let code) = prompts.answer(
                session: id, call: call, answer: answer, token: token
            ) {
                return .err(cid: cid, code: code.code)
            }
        }
        // `ack` means dispatched, not done. For the two read marks the observable effect is
        // the northbound `session.unread` event the store call just recorded; for a prompt it
        // is the `.userTurn` the agent writes into its own transcript, and for an answer the
        // `tool_result` closing the call — both read back over the history channel. One rule
        // for all four, which is why they share a frame. An answer is dispatched at the
        // keystroke: `SessionStore.drive` re-reads the screen after the repaint and declines
        // to press Return on a row that no longer says what was asked for, and that refusal
        // arrives too late to be a reply. It is recoverable by the person at the keyboard;
        // a wrong Return would not have been.
        return .ack(cid: cid)
    }
}
