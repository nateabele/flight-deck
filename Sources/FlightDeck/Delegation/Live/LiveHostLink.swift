import Foundation
import HostKit
import OSLog

/// What `LiveHostLink` needs of one host's connection. `HostLink` is the real one
/// (HostLink+Delegation.swift); the tests drive a scripted fake, so the event fan-out below is
/// exercised without a socket.
@MainActor
protocol DelegationTransport: AnyObject {
    var isOnline: Bool { get }
    /// What the host advertised in its helloAck; nil while no connection is live.
    var capabilities: Set<HostCapability>? { get }
    /// One request. A host `err` throws `HostLinkError.remote`; a drop, `.offline`. With
    /// `progress`, `timeout` is an idle timeout from the last activity it reports.
    func send(_ request: DelegationRequest, timeout: TimeInterval,
              progress: (@MainActor () -> Date)?) async throws -> DelegationReply
    func openChannel() async throws -> any ByteChannel
}

/// `HostLinking` over one host's connection: requests, channels, and run events fanned out to
/// any number of local subscribers (the contract on `HostLinking.events`: Ruling 18, one host
/// attach per run fanned out to every local subscriber, and Ruling 21, a disk copy that
/// replays first).
///
/// **One host attach per run, and a copy on disk.** The host streams a run's events to the
/// connection that started it, or that last sent `run.attach` for it, from wherever that
/// attach began. Everything that arrives is written to the run's `RunMirror`, and every
/// subscriber — the monitor, an attached `run`, a `wait {from}`, a `logs`, before or after the
/// run ended, before or after a relaunch — is served from that copy, then live. The host is
/// asked again (`run.attach` from the earliest missing byte) only when the copy lacks what a
/// subscriber wants: a run this install never saw from the start, or a pruned copy.
///
/// **Offsets are the only truth.** Each subscriber has its own `next` byte; a chunk is cut to
/// start there and one wholly before it is skipped, so what a replay or a reconnect re-sends
/// never reaches a subscriber twice.
@MainActor
final class LiveHostLink: HostLinking {
    let name: String
    private let transport: any DelegationTransport
    private let mirrors: URL
    private let mirrorPrefix: String
    private var feeds: [String: RunFeed] = [:]
    /// Runs whose feed ended and was let go. A replay already in flight can still deliver its
    /// tail afterwards; without this, that tail would look like a new run starting.
    private var retired: Set<String> = []
    /// Channels this link opened, by id, so a request naming one can time out on the
    /// transfer going quiet rather than on a fixed bound. Weak: a forward's channels are never
    /// named by such a request and must not be kept alive here.
    private var transfers: [ChannelID: WeakTransfer] = [:]
    /// The §5 line for this host while it is not connected ("mini is offline (last seen 4m
    /// ago)"), from the directory. A link is handed out offline so `logs` on a finished run
    /// can still answer from its copy on disk; everything that needs the host refuses with this.
    var unavailable: (() -> DelegationError)?

    /// For a request whose reply waits on bulk work on the host — a whole bundle received and
    /// unpacked, a result streamed, a `downCommand` run, checkouts measured or deleted — or on
    /// a replay sent ahead of it. `HostLink.requestTimeout` (10 s) would fail those mid-transfer
    /// while the host is still working; a link that really died fails them `.offline` anyway.
    static let bulkReplyTimeout: TimeInterval = 3600
    /// How long a channel transfer (`sync.push`, `run.result`, `run.artifacts`) may move no
    /// bytes before its request fails. No bound on the whole: a big first sync over a slow
    /// link legitimately takes as long as it takes.
    static let transferIdleTimeout: TimeInterval = 60

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "delegation")

    /// `mirrors` is `Application Support/Flight Deck/delegation/`. `mirrorPrefix` (the host's
    /// slot) keeps one host's provisional copy names apart from another's.
    init(name: String, transport: any DelegationTransport, mirrors: URL, mirrorPrefix: String) {
        self.name = name
        self.transport = transport
        self.mirrors = mirrors
        self.mirrorPrefix = mirrorPrefix
    }

    var capabilities: Set<HostCapability>? { transport.capabilities }

    /// Up now, and not closed for good. `DelegationService` asks the directory again for a
    /// link that is not, which hands back this same object while the host stays paired, so
    /// its feeds and their copies carry over the reconnect.
    var isConnected: Bool { !closed && transport.isOnline }
    private var closed = false

    // MARK: Requests

    func request(_ request: DelegationRequest) async throws -> DelegationReply {
        try requireOnline()
        let reply: DelegationReply
        do {
            if let channel = Self.transferChannel(of: request), let transfer = transfers[channel]?.channel {
                reply = try await transport.send(request, timeout: Self.transferIdleTimeout) { transfer.lastActivity }
            } else {
                reply = try await transport.send(request, timeout: Self.timeout(for: request), progress: nil)
            }
        } catch HostLinkError.offline {
            // One code for "the host is not there" however it was found out, so
            // the CLI's retry list keys on `host_offline` alone.
            throw unavailable?() ?? DelegationError(code: "host_offline",
                                                    message: "\(name) went offline before answering \(Self.op(request)) — rerun once flightdeck host ls shows it online")
        } catch HostLinkError.timedOut {
            throw DelegationError(code: "host_timeout",
                                  message: "\(name) did not answer \(Self.op(request)) in time — check that hostd is running on \(name), then rerun")
        }
        if case .runStart(let runID) = reply { started(runID) }
        return reply
    }

    func openChannel() async throws -> any ByteChannel {
        try requireOnline()
        let channel = TransferChannel(try await transport.openChannel())
        transfers = transfers.filter { $0.value.channel != nil }
        transfers[channel.id] = WeakTransfer(channel: channel)
        return channel
    }

    func requireOnline() throws {
        guard transport.isOnline else {
            throw unavailable?() ?? DelegationError(code: "host_offline",
                                                    message: "\(name) is offline — check flightdeck host ls, then rerun")
        }
    }

    /// The channel a request moves its payload over, when its reply waits on that transfer.
    static func transferChannel(of request: DelegationRequest) -> ChannelID? {
        switch request {
        case .syncPush(_, let channel), .runResult(_, let channel), .runArtifacts(_, _, let channel): return channel
        default: return nil
        }
    }

    /// The wire op (`sync.push`), for a failure line; only ever built on an error path.
    static func op(_ request: DelegationRequest) -> String {
        guard let data = try? JSONEncoder().encode(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else { return "the request" }
        return op
    }

    static func timeout(for request: DelegationRequest) -> TimeInterval {
        switch request {
        case .syncPush, .runResult, .runArtifacts, .runAttach, .serviceDown, .serviceSync,
             .workspaceUsage, .workspacePrune:
            return bulkReplyTimeout
        case .syncTips, .runStart, .runSignal, .runCancel, .runAck, .portCheck, .portOpen, .screenStatus:
            return HostLink.requestTimeout
        }
    }

    // MARK: Events

    func events(runID: String, localID: String, from offset: Int64) -> AsyncThrowingStream<RunEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<RunEvent, Error>.makeStream()
        let feed: RunFeed
        if let existing = feeds[runID], existing.localID == nil || existing.localID == localID {
            // `run.start`'s feed, named now that the service has given the run its id.
            if existing.localID == nil { existing.bind(localID, to: mirrorURL(localID)) }
            feed = existing
        } else if let bound = feeds[runID]?.localID, let asked = Int(localID.dropFirst()),
                  let other = Int(bound.dropFirst()) {
            // Bound to another run under the same host id: a host from before unique run ids
            // (Ruling 27: `<boot epoch>-r<n>`) restarted and reused the id. Only the newer of
            // the two (local ids only grow) can still be on the host; the older is gone from it.
            guard asked > other else {
                continuation.finish(throwing: gone)
                return stream
            }
            feeds[runID]?.fail(gone)
            feed = openFeed(runID, localID: localID)
        } else {
            feed = openFeed(runID, localID: localID)
        }
        let token = feed.subscribe(from: max(0, offset), continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.unsubscribe(runID, token) }
        }
        settle(runID)
        return stream
    }

    /// An `event` frame from the host. One for a run with no feed is `run.start`'s first
    /// output beating its reply (the only attach this link did not ask for), held for the
    /// subscriber that reply leads to.
    func received(runID: String, _ event: RunEvent) {
        if feeds[runID] == nil {
            guard !retired.contains(runID) else { return }
            startFeed(runID)
        }
        feeds[runID]?.receive(event)
        settle(runID)
    }

    /// The connection came up, or went down. A drop ends the host's subscriptions with it, so
    /// every feed still owed output re-attaches from the last byte it holds once the link is
    /// back — nothing lost, and nothing a subscriber already has is passed on again.
    func connectionChanged(online: Bool) {
        for (runID, feed) in feeds {
            if online { settle(runID) } else { feed.disconnected() }
        }
    }

    /// The host is gone for good (forgotten, or refusing us): every open stream fails rather
    /// than waiting on a reconnect that will never come. The copies on disk stay.
    func close(_ error: Error) {
        closed = true
        let all = feeds
        feeds = [:]
        for (runID, feed) in all {
            retired.insert(runID)
            feed.fail(error)
        }
    }

    /// Deletes these runs' copies, for retention when the registry forgets them. A subscriber
    /// still reading one is ended.
    func prune(_ runs: [(hostRunID: String, localID: String)]) {
        for run in runs {
            if let feed = feeds[run.hostRunID], feed.localID == run.localID {
                feeds[run.hostRunID] = nil
                feed.fail(CancellationError())
                retired.insert(run.hostRunID)
            }
            RunMirror(url: mirrorURL(run.localID)).delete()
        }
    }

    func mirrorURL(_ localID: String) -> URL {
        Self.mirrorURL(in: mirrors, localID: localID)
    }

    /// `<local run id>.out`. The local id, not the host's: this Mac never reuses one, while a
    /// host's ids were unique only per hostd lifetime before Ruling 27, and a reused one used
    /// to start the old run's copy over with the new run's output.
    nonisolated static func mirrorURL(in directory: URL, localID: String) -> URL {
        directory.appendingPathComponent("\(localID).out")
    }

    /// Where a run's copy lives until the service names it: its first output can beat the
    /// `run.start` reply that tells anyone its local id.
    /// What a run's readers are ended with when the host can no longer have it.
    private var gone: DelegationError {
        DelegationError(code: "unknown_run", message: DelegationService.hostLine(code: "unknown_run", message: "", host: name))
    }

    private func provisionalURL(_ runID: String) -> URL {
        mirrors.appendingPathComponent("pending-\(mirrorPrefix)-\(runID).out")
    }

    // MARK: Feeds

    /// `run.start` answered. It attaches this connection from byte 0 (A2), so the run's feed
    /// exists from here and the monitor that subscribes next sends no second attach.
    ///
    /// The id leaves `retired` first, whatever else happens: a feed let go under this id (an
    /// earlier run, on a host that reused it) must not swallow this run's events. If it was
    /// there, the events that beat this reply were dropped as that old run's tail, so the host
    /// is asked to replay the run from its start.
    private func started(_ runID: String) {
        let dropped = retired.remove(runID) != nil
        if let existing = feeds[runID], existing.localID != nil {
            // Bound to an older run under the same host id: that run is gone from the host.
            existing.fail(gone)
            feeds[runID] = nil
        }
        if feeds[runID] == nil { startFeed(runID) }
        if dropped {
            feeds[runID]?.replayFromStart()
            settle(runID)
        }
    }

    /// A feed for a run whose output is arriving before anyone has asked for it: its copy
    /// starts at byte 0, under a provisional name.
    private func startFeed(_ runID: String) {
        let mirror = RunMirror(url: provisionalURL(runID))
        mirror.reset(origin: 0)
        let feed = RunFeed(mirror: mirror, localID: nil)
        feed.attachedFromStart()
        retired.remove(runID)
        install(feed, runID)
    }

    /// A feed for a run asked about: whatever copy is on disk, from an earlier launch or an
    /// earlier subscriber.
    private func openFeed(_ runID: String, localID: String) -> RunFeed {
        let feed = RunFeed(mirror: RunMirror(url: mirrorURL(localID)), localID: localID)
        retired.remove(runID)
        install(feed, runID)
        return feed
    }

    private func install(_ feed: RunFeed, _ runID: String) {
        feed.changed = { [weak self, weak feed] in
            guard let self, let feed, self.feeds[runID] === feed else { return }
            self.settle(runID)
        }
        feeds[runID] = feed
    }

    private func unsubscribe(_ runID: String, _ token: UUID) {
        guard let feed = feeds[runID] else { return }
        feed.unsubscribe(token)
        settle(runID)
    }

    /// After anything that changes a feed: drop it from memory once it has ended and nobody
    /// is reading, or send the `run.attach` it now needs.
    private func settle(_ runID: String) {
        guard let feed = feeds[runID] else { return }
        if feed.isDone {
            feeds[runID] = nil
            retired.insert(runID)
            return
        }
        guard transport.isOnline, let offset = feed.attachNeeded() else { return }
        Task { @MainActor in
            do {
                _ = try await self.transport.send(.runAttach(runID: runID, offset: offset), timeout: Self.bulkReplyTimeout,
                                                  progress: nil)
            } catch HostLinkError.remote(let code, let message) {
                // `unknown_run`: the host no longer has it (pruned, or its state was reset).
                guard self.feeds[runID] === feed else { return }
                self.feeds[runID] = nil
                self.retired.insert(runID)
                feed.fail(DelegationError(code: code,
                                          message: DelegationService.hostLine(code: code, message: message, host: self.name)))
            } catch {
                // Offline: `connectionChanged` re-attaches when the link is back.
                Self.logger.info("\(self.name, privacy: .public): run.attach \(runID, privacy: .public) from \(offset): \(String(describing: error), privacy: .public)")
                feed.disconnected()
            }
        }
    }
}

private struct WeakTransfer {
    weak var channel: TransferChannel?
}

/// A channel that remembers when bytes last moved through it, for its request's idle timeout.
final class TransferChannel: ByteChannel, @unchecked Sendable {
    private let base: any ByteChannel
    private let lock = NSLock()
    private var last = Date()

    init(_ base: any ByteChannel) { self.base = base }

    var id: ChannelID { base.id }
    var lastActivity: Date { lock.withLock { last } }

    func write(_ data: Data) async throws {
        try await base.write(data)
        touch()
    }

    func read() async throws -> Data? {
        let data = try await base.read()
        touch()
        return data
    }

    func finish() async { await base.finish() }
    func cancel() { base.cancel() }

    private func touch() { lock.withLock { last = Date() } }
}

/// One run's events on one link, fanned out by offset from its `RunMirror`.
@MainActor
final class RunFeed {
    private final class Subscriber {
        let continuation: AsyncThrowingStream<RunEvent, Error>.Continuation
        /// The next output byte this subscriber is owed.
        var next: Int64
        /// The last `queued`/`started` it was given: a replay re-sends the state first, and
        /// the same state twice is noise.
        var state: RunEvent?
        /// Still being served from the copy on disk. Live output is not handed to it until it
        /// has caught up: the replay reads that output back from the copy, in order.
        var replay: Task<Void, Never>?

        init(_ continuation: AsyncThrowingStream<RunEvent, Error>.Continuation, next: Int64) {
            self.continuation = continuation
            self.next = next
        }
    }

    private let mirror: RunMirror
    /// The local run id the copy is named for; nil for a run whose `run.start` reply (and so
    /// its local id) is still on its way, whose copy has a provisional name until then.
    private(set) var localID: String?
    private var subscribers: [UUID: Subscriber] = [:]
    private var everSubscribed = false
    /// True while the host has a subscription for this run on the live connection.
    private var attached = false
    /// One past the last byte the host's stream delivered: where its next chunk should begin.
    private var hostAt: Int64?
    /// A `run.attach` sent while the stream was already flowing, to replay from here. Until
    /// the replay begins, what still arrives is the old stream, which the replay repeats.
    private var replay: Int64?
    /// A replay owed but not yet asked for (`replayFromStart`).
    private var owedReplay: Int64?
    /// Called when something changed that the link must act on: a replay from the copy
    /// finished, so the feed may be done, or may need the host for what the copy lacked.
    var changed: (() -> Void)?

    init(mirror: RunMirror, localID: String?) {
        self.mirror = mirror
        self.localID = localID
    }

    /// Nothing more to deliver, and nobody to deliver it to.
    var isDone: Bool { mirror.exit != nil && subscribers.isEmpty && everSubscribed }

    /// Names the copy for `localID` once the service knows it.
    func bind(_ localID: String, to url: URL) {
        self.localID = localID
        mirror.move(to: url)
    }

    // MARK: Subscribers

    func subscribe(from offset: Int64, _ continuation: AsyncThrowingStream<RunEvent, Error>.Continuation) -> UUID {
        let token = UUID()
        let subscriber = Subscriber(continuation, next: offset)
        subscribers[token] = subscriber
        everSubscribed = true
        // A2's replay order: the state, then output from the offset, then the end.
        if let state = mirror.state { give(state, to: subscriber) }
        if mirror.covers(offset), offset < mirror.end {
            subscriber.replay = Task { @MainActor [weak self] in await self?.replay(token) }
        } else {
            finishIfOwed(token)
        }
        return token
    }

    /// Serves `token` from the copy, one chunk per disk read, until it has caught up with
    /// everything held; it then takes live output like any other subscriber. A chunk at a time
    /// keeps a large replay from landing on the control socket as one burst: the socket ends a
    /// stream with `slow_reader` past 4 MiB in flight, and a copy holds up to 64 MiB.
    private func replay(_ token: UUID) async {
        while let subscriber = subscribers[token], !Task.isCancelled {
            // A host replay reset the copy under it: the live path (and an attach) takes over.
            guard mirror.covers(subscriber.next), subscriber.next < mirror.end,
                  let chunk = await mirror.chunk(from: subscriber.next)
            else { break }
            guard subscribers[token] === subscriber, !Task.isCancelled else { return }
            give(chunk, to: subscriber)
        }
        guard let subscriber = subscribers[token] else { return }
        subscriber.replay = nil
        finishIfOwed(token)
        changed?()
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.replay?.cancel()
    }

    // MARK: The host's stream

    /// `run.start`'s reply: the connection is attached from byte 0.
    func attachedFromStart() {
        attached = true
        hostAt = 0
    }

    /// The run's first events may have been dropped before its `run.start` reply arrived (see
    /// `LiveHostLink.request`), so the host is asked to send it all again.
    func replayFromStart() {
        owedReplay = 0
    }

    func receive(_ event: RunEvent) {
        switch event {
        case .queued, .started:
            // A replay always opens with the run's state (A2), so this is where it begins.
            if let from = replay { beginReplay(from) }
            mirror.record(event)
            for subscriber in subscribers.values { give(event, to: subscriber) }
        case .output(let stream, let offset, let data):
            receive(RunMirror.Chunk(stream: stream, offset: offset, data: data))
        case .exited, .serviceDied:
            // The old stream's end: the replay asked for repeats it after the output.
            guard replay == nil else { return }
            mirror.record(event)
            for token in Array(subscribers.keys) { finishIfOwed(token) }
        }
    }

    private func receive(_ chunk: RunMirror.Chunk) {
        guard !chunk.data.isEmpty else { return }
        if let from = replay {
            // The old stream until the stream goes back; the replay re-sends all of it.
            guard let at = hostAt, chunk.offset < at else { return }
            beginReplay(from)
        }
        // Bytes between where the host was and where this chunk starts are gone from its
        // spool (a replay of dropped output starts with a marker ending at the first byte it
        // kept), so a subscriber waiting in that gap moves on with this chunk.
        let from = hostAt ?? chunk.offset
        for subscriber in subscribers.values
        where subscriber.replay == nil && subscriber.next >= from && subscriber.next < chunk.end {
            give(chunk, to: subscriber)
        }
        mirror.append(chunk)
        hostAt = chunk.end
    }

    /// The copy starts over at the replay's offset: the replay re-sends everything from there.
    private func beginReplay(_ from: Int64) {
        mirror.reset(origin: from)
        hostAt = from
        replay = nil
    }

    /// The offset to send `run.attach` from, when the feed needs one now: a subscriber the copy
    /// cannot serve, or a run still going with no subscription on this connection (a fresh
    /// feed, a reconnect). One at a time — a second sent before the first replay began would
    /// make its start impossible to tell apart.
    func attachNeeded() -> Int64? {
        let missing = subscribers.values.filter { $0.replay == nil }.map(\.next).filter { !mirror.covers($0) }
        if !attached {
            owedReplay = nil
            if let from = missing.min() {
                mirror.reset(origin: from)
                return attach(from)
            }
            // Nothing more is coming for a finished run the copy fully holds.
            guard mirror.exit == nil, mirror.covers(mirror.end) else { return nil }
            return attach(mirror.end)
        }
        guard replay == nil, let from = [owedReplay, missing.min()].compactMap({ $0 }).min() else { return nil }
        owedReplay = nil
        replay = from
        return from
    }

    private func attach(_ from: Int64) -> Int64 {
        attached = true
        hostAt = from
        replay = nil
        return from
    }

    /// The connection dropped: the host's subscription went with it.
    func disconnected() {
        attached = false
        hostAt = nil
        replay = nil
    }

    func fail(_ error: Error) {
        for subscriber in subscribers.values {
            subscriber.replay?.cancel()
            subscriber.continuation.finish(throwing: error)
        }
        subscribers = [:]
    }

    // MARK: Delivery

    private func give(_ state: RunEvent, to subscriber: Subscriber) {
        guard subscriber.state != state else { return }
        subscriber.state = state
        subscriber.continuation.yield(state)
    }

    /// The part of `chunk` at or after the subscriber's `next`; the start moves up to the
    /// chunk's when the bytes before it are gone.
    private func give(_ chunk: RunMirror.Chunk, to subscriber: Subscriber) {
        let start = max(subscriber.next, chunk.offset)
        guard start < chunk.end else { return }
        let data = chunk.data.dropFirst(Int(start - chunk.offset))
        subscriber.continuation.yield(.output(stream: chunk.stream, offset: start, data: Data(data)))
        subscriber.next = chunk.end
    }

    /// Ends a subscriber that has every byte up to the run's end. One still replaying ends
    /// when its replay does.
    private func finishIfOwed(_ token: UUID) {
        guard let exit = mirror.exit, let subscriber = subscribers[token], subscriber.replay == nil,
              mirror.covers(subscriber.next), subscriber.next >= mirror.end
        else { return }
        subscriber.continuation.yield(exit)
        subscriber.continuation.finish()
        subscribers[token] = nil
    }
}
