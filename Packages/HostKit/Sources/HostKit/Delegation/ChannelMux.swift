import Foundation

/// Why a channel operation failed.
public enum ChannelMuxError: Error, Equatable {
    /// The channel was cancelled by either end, or closed for a protocol violation.
    case closed
    /// The transport under the mux went away (`shutdown`).
    case shutdown
    /// `write` after this end's own `finish`.
    case finished
    /// `accept(_:)` named an id of this side's own parity, which only `open` hands out.
    case notPeerChannel(ChannelID)
    /// `accept(_:)` named a channel something already claimed; two owners would race its reads.
    case alreadyClaimed(ChannelID)
    /// A second `read` while one is parked. A channel has one reader.
    case concurrentRead
    /// Every id of this side's parity has been handed out.
    case idsExhausted
}

/// Every byte stream of delegated execution, multiplexed onto one connection's binary
/// messages beside its JSON control frames (layout and credit rules: `ChannelProtocols.swift`).
///
/// **Ids:** the controller allocates odd ids and the host even ones, so both ends can open
/// without a round trip and never pick the same number. Ids are never reused within a
/// connection; a closed id is remembered so a frame still in flight for it (a credit, the
/// tail of a stream the peer had not yet seen closed) is dropped rather than resurrecting a
/// phantom channel that would buffer bytes nobody will read.
///
/// **Opening is implicit.** No frame announces a channel: a peer channel exists from its first
/// frame or from `accept(_:)`, whichever comes first. That is what lets the host claim channel
/// 7 from a `run.result` request before a single byte has crossed it, and lets bytes that beat
/// the request wait, within the window, for their owner.
///
/// **Flow control:** each direction starts with `ChannelFrame.initialCredit`. A writer
/// suspends at zero credit. The reader returns credit for what its *consumer* has read — not
/// what has merely arrived — once half the window has been consumed, so a slow consumer backs
/// up its own writer and nothing else. A peer that sends past its credit, or data after its
/// EOF, has broken the protocol; that channel closes, and only that one.
///
/// **Threading:** `receive(binary:)` may be called from any thread, but in transport order, and
/// `send` is never called with the lock held — a transport may deliver synchronously into the
/// other end, which may answer straight back. One writer and one reader per channel at a time.
public final class ChannelMux: ChannelOpening, ChannelAccepting, @unchecked Sendable {
    public enum Role: Sendable {
        /// Opens odd ids.
        case controller
        /// Opens even ids.
        case host
    }

    /// Peer channels the host holds before anyone claims them. Each is bounded by the
    /// window, so this bounds the pre-accept bytes too (32 x 256 KiB = 8 MiB): without it an
    /// authenticated but broken peer could open ids without end and make us hold a window
    /// for each.
    public static let maxUnclaimed = 32

    private let role: Role
    private let send: @Sendable (Data) -> Void
    private let lock = NSLock()
    // Guarded by `lock`, as is every `Channel`'s mutable state.
    private var nextID: ChannelID
    private var channels: [ChannelID: Channel] = [:]
    private var closedIDs = ClosedIDs()
    private var isShutdown = false
    private var incoming: AsyncStream<any ByteChannel>?
    private var incomingContinuation: AsyncStream<any ByteChannel>.Continuation?

    /// `send` writes one binary message to the peer, in call order.
    public init(role: Role, send: @escaping @Sendable (Data) -> Void) {
        self.role = role
        self.send = send
        nextID = role == .controller ? 1 : 2
    }

    // MARK: Public surface

    public func open() async throws -> any ByteChannel {
        try lock.withLock {
            if isShutdown { throw ChannelMuxError.shutdown }
            // `nextID` would wrap past UInt32.max into the peer's parity.
            guard nextID <= ChannelID.max - 2 else { throw ChannelMuxError.idsExhausted }
            let channel = Channel(id: nextID, mux: self)
            channel.claimed = true
            channels[nextID] = channel
            nextID += 2
            return channel
        }
    }

    /// Claims a channel the peer opened and named in a request, whether or not its first
    /// bytes have arrived yet.
    public func accept(_ id: ChannelID) async throws -> any ByteChannel {
        try lock.withLock {
            guard isPeerID(id) else { throw ChannelMuxError.notPeerChannel(id) }
            if isShutdown { throw ChannelMuxError.shutdown }
            if closedIDs.contains(id) { throw ChannelMuxError.closed }
            if let channel = channels[id] {
                guard !channel.claimed else { throw ChannelMuxError.alreadyClaimed(id) }
                channel.claimed = true
                return channel
            }
            let channel = Channel(id: id, mux: self)
            channel.claimed = true
            channels[id] = channel
            return channel
        }
    }

    /// Peer-opened channels nobody has claimed by id, each yielded once, at its first frame.
    /// Created on first call, so a side that only ever claims by id (the host's router) never
    /// accumulates channels in a stream nobody drains. The same stream on every call.
    public func accept() -> AsyncStream<any ByteChannel> {
        lock.lock(); defer { lock.unlock() }
        if let incoming { return incoming }
        let (stream, continuation) = AsyncStream<any ByteChannel>.makeStream()
        if isShutdown { continuation.finish() }
        incoming = stream
        incomingContinuation = continuation
        return stream
    }

    /// One binary message from the transport.
    public func receive(binary data: Data) {
        // Shorter than a channel id: there is no channel to blame, so nothing closes.
        guard data.count >= 4 else { return }
        let id = data.prefix(4).reduce(0) { $0 << 8 | ChannelID($1) }
        var effects = Effects()
        lock.lock()
        if !isShutdown {
            do {
                handle(try ChannelFrame(decoding: data), &effects)
            } catch {
                violation(id, &effects)
            }
        }
        lock.unlock()
        effects.run(send)
    }

    /// The connection is gone. Every channel fails with `.shutdown`, and no frame is sent:
    /// there is no peer to send it to, and its own mux is being torn down the same way.
    public func shutdown() {
        var effects = Effects()
        lock.lock()
        isShutdown = true
        for channel in channels.values { channel.fail(.shutdown, &effects) }
        channels = [:]
        incomingContinuation?.finish()
        lock.unlock()
        effects.run(send)
    }

    // MARK: Frames in (all under `lock`)

    private func handle(_ frame: ChannelFrame, _ effects: inout Effects) {
        let id = frame.channel
        if closedIDs.contains(id) { return }
        let channel: Channel
        if let known = channels[id] {
            channel = known
        } else if isPeerID(id) {
            // A close for a channel we never saw needs no answer; just never let it open.
            if frame.kind == .close { closedIDs.insert(id); return }
            // Nor does a credit: the peer cannot have consumed bytes we never sent, and a
            // channel created by one would sit against the cap with nothing behind it.
            if frame.kind == .credit { return }
            if incomingContinuation == nil,
               channels.values.lazy.filter({ !$0.claimed }).count >= Self.maxUnclaimed {
                return violation(id, &effects)
            }
            channel = Channel(id: id, mux: self)
            channels[id] = channel
            if let incomingContinuation {
                channel.claimed = true
                effects.yields.append { incomingContinuation.yield(channel) }
            }
        } else {
            // Our parity, but never opened: dropped (contract A6). Answering with a close
            // would let a confused peer make us emit a frame per frame it sends.
            return
        }

        switch frame.kind {
        case .data:
            // Past the allowance is past the window, which for a channel nobody has claimed
            // yet is the pre-accept buffer's bound; past `ChannelFrame.maxPayload` is a frame no conforming
            // writer sends (A6). Either closes the channel rather than buffering the excess.
            guard !channel.receivedEOF, frame.payload.count <= ChannelFrame.maxPayload,
                  frame.payload.count <= channel.receiveAllowance else {
                return violation(id, &effects)
            }
            channel.receiveAllowance -= frame.payload.count
            if frame.payload.isEmpty { return }
            if let reader = channel.reader {
                channel.reader = nil
                channel.consumed(frame.payload.count, &effects)
                let payload = frame.payload
                effects.resumes.append { reader.resume(returning: payload) }
            } else {
                channel.inbox.append(frame.payload)
            }
        case .credit:
            channel.sendCredit += Int(frame.creditBytes ?? 0)
            channel.wakeWriters(&effects)
        case .eof:
            channel.receivedEOF = true
            if channel.inbox.isEmpty, let reader = channel.reader {
                channel.reader = nil
                effects.resumes.append { reader.resume(returning: nil) }
            }
            retireIfDone(channel)
        case .close:
            channel.fail(.closed, &effects)
            retire(id)
        }
    }

    /// A frame for `id` broke the protocol: close that channel at both ends.
    private func violation(_ id: ChannelID, _ effects: inout Effects) {
        // Closed, or of our own parity and never opened: dropped, like any frame for an
        // unknown or closed id (A6). Not tombstoned either, since we may yet open that id.
        if closedIDs.contains(id) || (channels[id] == nil && !isPeerID(id)) { return }
        channels[id]?.fail(.closed, &effects)
        retire(id)
        effects.frames.append(ChannelFrame(channel: id, kind: .close).encoded())
    }

    // MARK: Channel lifecycle (under `lock`)

    fileprivate func cancel(_ channel: Channel) {
        var effects = Effects()
        lock.lock()
        if channel.failure == nil {
            channel.fail(.closed, &effects)
            if !isShutdown {
                effects.frames.append(ChannelFrame(channel: channel.id, kind: .close).encoded())
            }
            retire(channel.id)
        }
        lock.unlock()
        effects.run(send)
    }

    fileprivate func finish(_ channel: Channel) {
        var effects = Effects()
        lock.lock()
        if channel.failure == nil, !channel.sentEOF {
            channel.sentEOF = true
            effects.frames.append(ChannelFrame(channel: channel.id, kind: .eof).encoded())
            // A writer parked for credit on a channel its own side just finished is a misuse;
            // fail it rather than leave it parked forever.
            channel.wakeWriters(&effects)
            retireIfDone(channel)
        }
        lock.unlock()
        effects.run(send)
    }

    /// Up to `limit` bytes of send credit, reserved; 0 means "parked and woken, ask again".
    fileprivate func reserve(_ channel: Channel, upTo limit: Int) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            lock.lock()
            if let failure = channel.failure {
                lock.unlock()
                return continuation.resume(throwing: failure)
            }
            if channel.sentEOF {
                lock.unlock()
                return continuation.resume(throwing: ChannelMuxError.finished)
            }
            if channel.sendCredit > 0 {
                let n = min(limit, channel.sendCredit)
                channel.sendCredit -= n
                lock.unlock()
                return continuation.resume(returning: n)
            }
            channel.writers.append(continuation)
            lock.unlock()
        }
    }

    fileprivate func sendData(_ channel: Channel, _ chunk: Data) {
        send(ChannelFrame(channel: channel.id, kind: .data, payload: chunk).encoded())
    }

    fileprivate func read(_ channel: Channel) async throws -> Data? {
        var effects = Effects()
        let result: Result<Data?, Error>? = lock.withLock {
            if let failure = channel.failure { return .failure(failure) }
            if !channel.inbox.isEmpty {
                let chunk = channel.inbox.removeFirst()
                channel.consumed(chunk.count, &effects)
                return .success(chunk)
            }
            if channel.receivedEOF { return .success(nil) }
            if channel.reader != nil { return .failure(ChannelMuxError.concurrentRead) }
            return nil
        }
        effects.run(send)
        if let result { return try result.get() }
        // Nothing buffered: park. Re-checked under the lock, since a frame may have landed
        // between the two critical sections.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            var effects = Effects()
            lock.lock()
            if let failure = channel.failure {
                lock.unlock()
                return continuation.resume(throwing: failure)
            }
            if !channel.inbox.isEmpty {
                let chunk = channel.inbox.removeFirst()
                channel.consumed(chunk.count, &effects)
                lock.unlock()
                effects.run(send)
                return continuation.resume(returning: chunk)
            }
            if channel.receivedEOF {
                lock.unlock()
                return continuation.resume(returning: nil)
            }
            if channel.reader != nil {
                lock.unlock()
                return continuation.resume(throwing: ChannelMuxError.concurrentRead)
            }
            channel.reader = continuation
            lock.unlock()
        }
    }

    /// Both directions ended cleanly: stop routing frames to it. The object lives on with
    /// its holder, so bytes already buffered can still be read.
    private func retireIfDone(_ channel: Channel) {
        if channel.sentEOF, channel.receivedEOF { retire(channel.id) }
    }

    private func retire(_ id: ChannelID) {
        channels[id] = nil
        closedIDs.insert(id)
    }

    /// Ids remembered one by one, for tests that pin the bound.
    var tombstoneCount: Int { lock.withLock { closedIDs.heldIndividually } }

    private func isPeerID(_ id: ChannelID) -> Bool {
        // 0 is neither side's: the controller starts at 1, the host at 2.
        id != 0 && (id % 2 == 1) == (role == .host)
    }

    // MARK: -

    /// The ids of one connection that have closed, so a frame still in flight for one is dropped.
///
/// A plain set grew by one id per channel ever closed, and a busy forwarded port opens a
/// channel per connection, so it grew for the whole life of the link. Each side hands out its
/// ids in order (odd from 1, even from 2), so per parity the ids that have all closed form a
/// prefix: those collapse into a watermark, and only ids closed above the oldest one still
/// open (or never seen) are held one by one. Exact, not approximate: an id joins the watermark
/// only once it is itself closed, which matters on the receiving side, where a later channel's
/// first frame can arrive before an earlier one's.
struct ClosedIDs {
    /// Per parity (index `id % 2`), the lowest id not yet known closed in the prefix.
    private var floor: [ChannelID]
    private var above: Set<ChannelID> = []

    /// Floors other than the first ids exist for tests of the top of the id space, which
    /// would otherwise take two billion inserts to reach.
    init(evenFloor: ChannelID = 2, oddFloor: ChannelID = 1) {
        floor = [evenFloor, oddFloor]
    }

    var heldIndividually: Int { above.count }

    func contains(_ id: ChannelID) -> Bool {
        let start: ChannelID = id % 2 == 0 ? 2 : 1
        return (id >= start && id < floor[Int(id % 2)]) || above.contains(id)
    }

    mutating func insert(_ id: ChannelID) {
        let p = Int(id % 2)
        guard id >= floor[p] else { return }
        above.insert(id)
        // `ChannelID.max - 1` and `.max` are the last of their parity: the floor cannot pass
        // them (`+ 2` would trap), so they stay held one by one.
        while above.contains(floor[p]), floor[p] <= ChannelID.max - 2 {
            above.remove(floor[p])
            floor[p] += 2
        }
    }
}

/// Work gathered under the lock and done after it is released: frames to the transport,
    /// and continuations to resume. Sending under the lock would deadlock a transport that
    /// delivers synchronously into a peer that answers straight back.
    fileprivate struct Effects {
        var frames: [Data] = []
        var resumes: [() -> Void] = []
        var yields: [() -> Void] = []

        func run(_ send: (Data) -> Void) {
            for frame in frames { send(frame) }
            for resume in resumes { resume() }
            for yield in yields { yield() }
        }
    }

    fileprivate final class Channel: ByteChannel, @unchecked Sendable {
        let id: ChannelID
        // Strong: a holder may outlive the mux's owner, and must then get `.shutdown`, not a crash.
        // The cycle through `channels` breaks at retire or shutdown.
        private let mux: ChannelMux

        // Guarded by `mux.lock`.
        var claimed = false
        var sendCredit = Int(ChannelFrame.initialCredit)
        var writers: [CheckedContinuation<Int, Error>] = []
        var sentEOF = false
        /// Bytes the peer may still send before it must wait for our credit.
        var receiveAllowance = Int(ChannelFrame.initialCredit)
        /// Read by the consumer but not yet granted back.
        var ungranted = 0
        var inbox: [Data] = []
        var receivedEOF = false
        var reader: CheckedContinuation<Data?, Error>?
        var failure: ChannelMuxError?

        init(id: ChannelID, mux: ChannelMux) {
            self.id = id
            self.mux = mux
        }

        /// Cancelling the writing task cancels the channel, as for `read`: a write cut short
        /// has already sent part of `data`, so the stream is torn either way.
        func write(_ data: Data) async throws {
            try await withTaskCancellationHandler {
                try await writeAll(data)
            } onCancel: {
                cancel()
            }
        }

        private func writeAll(_ data: Data) async throws {
            var offset = data.startIndex
            while offset < data.endIndex {
                // Writes are cut at `maxPayload` so channels sharing the connection interleave
                // finely: one 16 MiB write cannot hold the socket for its whole length.
                let n = try await mux.reserve(self, upTo: min(data.endIndex - offset, ChannelFrame.maxPayload))
                guard n > 0 else { continue }
                mux.sendData(self, data.subdata(in: offset..<offset + n))
                offset += n
            }
        }

        /// Task cancellation cancels the channel, both ends: a read abandoned mid-stream
        /// leaves a stream nobody can resume, and without this a cancelled task would stay
        /// parked until the peer happened to write or close.
        func read() async throws -> Data? {
            try await withTaskCancellationHandler {
                try await mux.read(self)
            } onCancel: {
                cancel()
            }
        }
        func finish() async { mux.finish(self) }
        func cancel() { mux.cancel(self) }

        /// The consumer took `count` bytes. Credit goes back in half-window steps: per chunk
        /// would double the frame count, and waiting for the whole window would stall the
        /// writer for a full round trip every window.
        func consumed(_ count: Int, _ effects: inout Effects) {
            ungranted += count
            // A peer that has sent EOF will never write again; credit would be noise.
            guard !receivedEOF, ungranted >= Int(ChannelFrame.initialCredit) / 2 else { return }
            effects.frames.append(ChannelFrame.credit(channel: id, bytes: UInt32(ungranted)).encoded())
            receiveAllowance += ungranted
            ungranted = 0
        }

        /// Writers re-check their state on waking, so this serves credit, finish and failure alike.
        func wakeWriters(_ effects: inout Effects) {
            let woken = writers
            writers = []
            for writer in woken { effects.resumes.append { writer.resume(returning: 0) } }
        }

        func fail(_ error: ChannelMuxError, _ effects: inout Effects) {
            guard failure == nil else { return }
            failure = error
            inbox = []
            wakeWriters(&effects)
            if let reader {
                self.reader = nil
                effects.resumes.append { reader.resume(throwing: error) }
            }
        }
    }
}
