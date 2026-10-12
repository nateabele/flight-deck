import Foundation
import XCTest
@testable import HostKit

/// Two muxes cross-wired in memory: what one sends, the other receives, in order. `tap` sees
/// every frame first and may swallow it, which is how a test withholds credit or forges a
/// malformed frame without a transport that misbehaves on cue.
private final class MuxPair: @unchecked Sendable {
    private let lock = NSLock()
    private var _controller: ChannelMux!
    private var _host: ChannelMux!
    /// Frames bound for the host, then frames bound for the controller. Return false to drop.
    var toHost: (@Sendable (Data) -> Bool)?
    var toController: (@Sendable (Data) -> Bool)?
    private var dataBytesToHost: [ChannelID: Int] = [:]
    private var _largestPayloadToHost = 0
    private var _framesToController = 0

    var controller: ChannelMux { _controller }
    var host: ChannelMux { _host }

    init() {
        _controller = ChannelMux(role: .controller) { [unowned self] data in self.deliverToHost(data) }
        _host = ChannelMux(role: .host) { [unowned self] data in self.deliverToController(data) }
    }

    func dataBytesSentToHost(on id: ChannelID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return dataBytesToHost[id, default: 0]
    }

    var largestPayloadToHost: Int { lock.lock(); defer { lock.unlock() }; return _largestPayloadToHost }
    var framesToController: Int { lock.lock(); defer { lock.unlock() }; return _framesToController }

    private func deliverToHost(_ data: Data) {
        if let frame = try? ChannelFrame(decoding: data), frame.kind == .data {
            lock.lock()
            dataBytesToHost[frame.channel, default: 0] += frame.payload.count
            _largestPayloadToHost = max(_largestPayloadToHost, frame.payload.count)
            lock.unlock()
        }
        if let toHost, !toHost(data) { return }
        _host.receive(binary: data)
    }

    private func deliverToController(_ data: Data) {
        lock.lock(); _framesToController += 1; lock.unlock()
        if let toController, !toController(data) { return }
        _controller.receive(binary: data)
    }
}

/// A cheap order-sensitive checksum, eight bytes at a time so 64 MiB stays quick in a debug build.
private struct Checksum {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private(set) var count = 0
    private var carry = Data()

    mutating func add(_ data: Data) {
        count += data.count
        carry.append(data)
        let whole = carry.count / 8 * 8
        carry.withUnsafeBytes { raw in
            var i = 0
            while i < whole {
                value = (value ^ raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x100_0000_01b3
                i += 8
            }
        }
        carry = Data(carry.suffix(from: carry.startIndex + whole))
    }

    var final: UInt64 {
        var v = value
        for byte in carry { v = (v ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return v
    }
}

private func readAll(_ channel: any ByteChannel) async throws -> Data {
    var out = Data()
    while let chunk = try await channel.read() { out.append(chunk) }
    return out
}

/// Fulfils when `body` returns, so a test can assert it has *not* yet.
private func finished(_ test: XCTestCase, _ label: String,
                      _ body: @escaping @Sendable () async throws -> Void) -> XCTestExpectation {
    let done = test.expectation(description: label)
    Task { try? await body(); done.fulfill() }
    return done
}

final class ChannelMuxTests: XCTestCase {
    /// 64 MiB through the 256 KiB window: only arrives whole if credit keeps being returned as
    /// the reader consumes, and every byte arrives exactly once and in order.
    func testRoundTripLargeStream() async throws {
        let pair = MuxPair()
        let sent = try await pair.controller.open()
        let received = try await pair.host.accept(sent.id)

        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        }
        var expected = Checksum()
        for n in 0..<64 { var b = block; b[0] = UInt8(n); expected.add(b) }

        let writer = Task {
            for n in 0..<64 { var b = block; b[0] = UInt8(n); try await sent.write(b) }
            await sent.finish()
        }
        var actual = Checksum()
        while let chunk = try await received.read() { actual.add(chunk) }
        try await writer.value

        XCTAssertEqual(actual.count, 64 << 20)
        XCTAssertEqual(actual.final, expected.final)
    }

    /// A reader that never reads must back up its writer at exactly the window, not let the
    /// mux buffer without bound; and reading half the window is what lets the writer move.
    func testWriterSuspendsWithoutCredit() async throws {
        let pair = MuxPair()
        let channel = try await pair.controller.open()
        let reader = try await pair.host.accept(channel.id)
        let window = Int(ChannelFrame.initialCredit)

        let done = finished(self, "write returned") {
            try await channel.write(Data(count: window + 1))
        }
        done.isInverted = true
        await fulfillment(of: [done], timeout: 0.3)
        XCTAssertEqual(pair.dataBytesSentToHost(on: channel.id), window,
                       "the writer sent past its credit")

        // Below half the window, no credit goes back yet.
        var consumed = 0
        while consumed < window / 2 {
            guard let chunk = try await reader.read() else { return XCTFail("early EOF") }
            consumed += chunk.count
        }
        let resumed = expectation(description: "the last byte sent")
        let poll = Task {
            while pair.dataBytesSentToHost(on: channel.id) < window + 1 { try await Task.sleep(nanoseconds: 5_000_000) }
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 5)
        poll.cancel()
    }

    /// `finish` ends one direction only: the peer reads EOF after the bytes, and can still
    /// write back, which a request/response over one channel (a sync bundle, then its verdict)
    /// depends on.
    func testEOFIsHalfClose() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let b = try await pair.host.accept(a.id)

        try await a.write(Data("question".utf8))
        await a.finish()
        let read = try await readAll(b)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "question")
        let afterEOF = try await b.read()
        XCTAssertNil(afterEOF, "EOF is sticky")

        try await b.write(Data("answer".utf8))
        await b.finish()
        let answer = try await readAll(a)
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "answer")

        // Writing after our own finish is a caller bug, refused rather than sent.
        do { try await a.write(Data("late".utf8)); XCTFail("wrote after finish") } catch {}
    }

    /// One side's cancel fails what both sides have pending: a reader parked on either end
    /// must not wait forever for bytes that will never come.
    func testCancelClosesBothWays() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let b = try await pair.host.accept(a.id)

        let localRead = expectation(description: "local read failed")
        let remoteRead = expectation(description: "remote read failed")
        Task { do { _ = try await a.read() } catch { localRead.fulfill() } }
        Task { do { _ = try await b.read() } catch { remoteRead.fulfill() } }
        try await Task.sleep(nanoseconds: 50_000_000)  // both parked
        a.cancel()
        await fulfillment(of: [localRead, remoteRead], timeout: 2)

        do { try await b.write(Data("x".utf8)); XCTFail("peer wrote into a closed channel") } catch {}
        do { try await a.write(Data("x".utf8)); XCTFail("wrote into a cancelled channel") } catch {}
        // A cancelled id is dead for good: the host cannot claim it again.
        do { _ = try await pair.host.accept(a.id); XCTFail("re-claimed a closed channel") } catch {}
    }

    /// Credit is per channel: one stalled stream (its reader gone quiet, its writer parked)
    /// must not hold up another channel on the same connection.
    func testInterleavedChannelsDoNotBlockEachOther() async throws {
        let pair = MuxPair()
        let stalled = try await pair.controller.open()
        _ = try await pair.host.accept(stalled.id)
        let parked = finished(self, "stalled write returned") {
            try await stalled.write(Data(count: Int(ChannelFrame.initialCredit) * 2))
        }
        parked.isInverted = true

        let live = try await pair.controller.open()
        let liveHost = try await pair.host.accept(live.id)
        // Read concurrently: 800 KB is past the window, so this channel needs its own credit
        // returned while the stalled one gets none.
        let reader = Task { try await readAll(liveHost) }
        for n in 0..<8 {
            try await live.write(Data(repeating: UInt8(n), count: 100_000))
        }
        await live.finish()
        let got = try await reader.value
        XCTAssertEqual(got.count, 800_000)
        XCTAssertEqual(got.last, 7)
        await fulfillment(of: [parked], timeout: 0.1)
        stalled.cancel()
    }

    /// A frame the codec rejects still names its channel in the first four bytes; that
    /// channel closes, both ends, and its neighbour is untouched. A frame too short to name a
    /// channel is dropped, and closes nothing.
    func testMalformedFrameClosesOnlyThatChannel() async throws {
        let pair = MuxPair()
        let bad = try await pair.controller.open()
        let badHost = try await pair.host.accept(bad.id)
        let good = try await pair.controller.open()
        let goodHost = try await pair.host.accept(good.id)

        pair.host.receive(binary: Data([0, 0]))  // truncated, unattributable
        var forged = ChannelFrame(channel: bad.id, kind: .data).encoded()
        forged[4] = 9  // no such kind
        pair.host.receive(binary: forged)

        do { _ = try await badHost.read(); XCTFail("the malformed channel stayed open") } catch {}
        // The controller hears about it too: its next read fails rather than waits.
        do { _ = try await bad.read(); XCTFail("the peer never closed the controller's end") } catch {}

        try await good.write(Data("fine".utf8))
        await good.finish()
        let got = try await readAll(goodHost)
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "fine")
    }

    /// A peer that sends more than it was granted is broken or hostile; buffering the excess
    /// would make the window meaningless, so that channel closes.
    func testOverrunningCreditClosesThatChannel() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let b = try await pair.host.accept(a.id)
        let over = Data(count: Int(ChannelFrame.initialCredit) + 1)
        pair.host.receive(binary: ChannelFrame(channel: a.id, kind: .data, payload: over).encoded())
        do {
            while try await b.read() != nil {}
            XCTFail("an overrun channel read to a clean EOF")
        } catch {}
    }

    /// Both ends allocate without asking each other, so the id spaces must be disjoint: the
    /// controller odd, the host even. Each side's peer-opened channels arrive on `accept()`.
    func testOddEvenIDsNeverCollide() async throws {
        let pair = MuxPair()
        var controllerIDs: [ChannelID] = [], hostIDs: [ChannelID] = []
        for _ in 0..<3 {
            controllerIDs.append(try await pair.controller.open().id)
            hostIDs.append(try await pair.host.open().id)
        }
        XCTAssertEqual(controllerIDs, [1, 3, 5])
        XCTAssertEqual(hostIDs, [2, 4, 6])

        // The host opens one and speaks first; the controller is handed it on `accept()`.
        var incoming = pair.controller.accept().makeAsyncIterator()
        let fromHost = try await pair.host.open()
        try await fromHost.write(Data("hi".utf8))
        await fromHost.finish()
        guard let accepted = await incoming.next() else { return XCTFail("no peer channel") }
        XCTAssertEqual(accepted.id, fromHost.id)
        let got = try await readAll(accepted)
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "hi")

        // Claiming an id of one's own parity is a mistake, not a peer channel.
        do { _ = try await pair.host.accept(2); XCTFail("host claimed its own id") } catch {}
    }

    // MARK: Contract A6, rule by rule

    /// Credit frames add to what is left, rather than setting it: two grants of one byte each
    /// let exactly two more bytes through.
    func testCreditFramesAreAdditive() async throws {
        let pair = MuxPair()
        // The host never sees the data (it is counted, then swallowed), so the only credit
        // the controller gets is what this test forges; a host that saw the overrun would
        // close the channel, and a write that throws would read as one that went out.
        pair.toHost = { data in (try? ChannelFrame(decoding: data))?.kind != .data }
        let a = try await pair.controller.open()
        let window = Int(ChannelFrame.initialCredit)
        try await a.write(Data(count: window))
        XCTAssertEqual(pair.dataBytesSentToHost(on: a.id), window)

        pair.controller.receive(binary: ChannelFrame.credit(channel: a.id, bytes: 1).encoded())
        pair.controller.receive(binary: ChannelFrame.credit(channel: a.id, bytes: 1).encoded())
        try await a.write(Data(count: 2))  // returns only if both grants counted
        XCTAssertEqual(pair.dataBytesSentToHost(on: a.id), window + 2)

        let third = finished(self, "a third byte went out") { try await a.write(Data(count: 1)) }
        third.isInverted = true
        await fulfillment(of: [third], timeout: 0.3)
        a.cancel()
    }

    /// Frames naming an id that is ours but never opened, or a closed one, are dropped: no
    /// channel appears, nothing is answered, and the real channels are untouched.
    func testFramesForUnknownOrClosedIDsAreDropped() async throws {
        let pair = MuxPair()
        let closed = try await pair.controller.open()
        _ = try await pair.host.accept(closed.id)
        closed.cancel()
        let before = pair.framesToController

        // 2 is the host's own parity and it never opened it; 1 is closed.
        pair.host.receive(binary: ChannelFrame(channel: 2, kind: .data, payload: Data("x".utf8)).encoded())
        var forged = ChannelFrame(channel: 2, kind: .data).encoded()
        forged[4] = 9
        pair.host.receive(binary: forged)
        pair.host.receive(binary: ChannelFrame(channel: closed.id, kind: .data, payload: Data("x".utf8)).encoded())
        XCTAssertEqual(pair.framesToController, before, "answered a frame it should have dropped")

        // The host can still open its own 2, untainted by the stray frame.
        let mine = try await pair.host.open()
        XCTAssertEqual(mine.id, 2)
        let peer = try await pair.controller.accept(mine.id)
        try await mine.write(Data("clean".utf8))
        await mine.finish()
        let got = try await readAll(peer)
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "clean")
    }

    /// Bytes that beat the request naming their channel wait for `accept`, up to the initial
    /// credit and no further: one byte past it closes the channel instead of buffering.
    func testPreAcceptBufferIsBoundedByInitialCredit() async throws {
        let pair = MuxPair()
        let window = Int(ChannelFrame.initialCredit)

        let early = try await pair.controller.open()
        try await early.write(Data(repeating: 7, count: window))  // fits: no credit needed
        let claimed = try await pair.host.accept(early.id)
        await early.finish()
        let got = try await readAll(claimed)
        XCTAssertEqual(got.count, window)

        // A peer ignoring its credit: one frame past the bound, nobody has accepted yet.
        let flood = try await pair.controller.open()
        for _ in 0..<(window / ChannelFrame.maxPayload) {
            pair.host.receive(binary: ChannelFrame(channel: flood.id, kind: .data,
                                                   payload: Data(count: ChannelFrame.maxPayload)).encoded())
        }
        pair.host.receive(binary: ChannelFrame(channel: flood.id, kind: .data, payload: Data([1])).encoded())
        do { _ = try await pair.host.accept(flood.id); XCTFail("accepted an overflowed channel") } catch {}
        do { _ = try await flood.read(); XCTFail("the controller's end stayed open") } catch {}
    }

    /// A request naming a channel failed, so the controller cancels a channel the host never
    /// saw a byte of. The host must not later hand that id to anyone: the close is remembered
    /// even for an id it had never met.
    func testCancelBeforeAnyBytesStillClosesTheHostsClaim() async throws {
        let pair = MuxPair()
        let named = try await pair.controller.open()
        named.cancel()
        do { _ = try await pair.host.accept(named.id); XCTFail("claimed a channel its request failed") } catch {}
        // And the host side of the same rule: a claimed channel cancelled there fails the
        // controller's parked read.
        let other = try await pair.controller.open()
        let claimed = try await pair.host.accept(other.id)
        let failed = expectation(description: "controller read failed")
        Task { do { _ = try await other.read() } catch { failed.fulfill() } }
        claimed.cancel()
        await fulfillment(of: [failed], timeout: 2)
    }

    /// No data frame carries more than 64 KiB, whatever the write size; one that does is
    /// refused and closes its channel.
    func testDataPayloadsAreAtMost64KiB() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let b = try await pair.host.accept(a.id)
        let reader = Task { try await readAll(b) }
        try await a.write(Data(count: 1 << 20))
        await a.finish()
        let got = try await reader.value
        XCTAssertEqual(got.count, 1 << 20)
        XCTAssertEqual(pair.largestPayloadToHost, 64 * 1024)

        let big = try await pair.controller.open()
        let bigHost = try await pair.host.accept(big.id)
        pair.host.receive(binary: ChannelFrame(channel: big.id, kind: .data,
                                               payload: Data(count: 64 * 1024 + 1)).encoded())
        do { _ = try await bigHost.read(); XCTFail("an oversized frame was accepted") } catch {}
    }

    /// The transport went away: every channel fails at once, with no frames to a peer that is
    /// no longer there, and nothing new opens.
    func testShutdownFailsEveryChannel() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let failed = expectation(description: "read failed")
        Task { do { _ = try await a.read() } catch { failed.fulfill() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        pair.controller.shutdown()
        await fulfillment(of: [failed], timeout: 2)
        do { _ = try await pair.controller.open(); XCTFail("opened after shutdown") } catch {}
    }

    // MARK: Fix round 1

    /// Both directions at full speed at once, through the synchronous pair: each side's
    /// writer delivers straight into the other's mux, which answers with credit straight
    /// back. A lock held across `send`, or credit returned for arrival instead of
    /// consumption, deadlocks or corrupts here. One channel carrying both ways, then two.
    func testSimultaneousBidirectionalLargeStreams() async throws {
        let size = 16 << 20
        func pattern(_ seed: UInt8) -> Data {
            var block = Data(count: 1 << 20)
            block.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 7 &+ Int(seed)) }
            }
            return block
        }
        func expected(_ seed: UInt8) -> UInt64 {
            var c = Checksum(); let b = pattern(seed)
            for _ in 0..<(size >> 20) { c.add(b) }
            return c.final
        }
        func pump(_ out: any ByteChannel, _ into: any ByteChannel, seed: UInt8) async throws -> (Int, UInt64) {
            let block = pattern(seed)
            let writer = Task {
                for _ in 0..<(size >> 20) { try await out.write(block) }
                await out.finish()
            }
            let reader = Task { () throws -> (Int, UInt64) in
                var c = Checksum()
                while let chunk = try await into.read() { c.add(chunk) }
                return (c.count, c.final)
            }
            try await writer.value
            return try await reader.value
        }

        for channels in [1, 2] {
            let pair = MuxPair()
            let up = try await pair.controller.open()
            let upHost = try await pair.host.accept(up.id)
            let (downHost, down): (any ByteChannel, any ByteChannel)
            if channels == 1 {
                (downHost, down) = (upHost, up)
            } else {
                let opened = try await pair.host.open()
                downHost = opened
                down = try await pair.controller.accept(opened.id)
            }
            async let a = pump(up, upHost, seed: 1)
            async let b = pump(downHost, down, seed: 2)
            let (ra, rb) = try await (a, b)
            XCTAssertEqual(ra.0, size, "\(channels) channel(s): upstream count")
            XCTAssertEqual(ra.1, expected(1), "\(channels) channel(s): upstream bytes")
            XCTAssertEqual(rb.0, size, "\(channels) channel(s): downstream count")
            XCTAssertEqual(rb.1, expected(2), "\(channels) channel(s): downstream bytes")
        }
    }

    /// A writer parked for credit on a channel its own side then finishes must fail, not sit
    /// parked for credit that a finished channel will never use.
    func testFinishWakesAParkedWriter() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        _ = try await pair.host.accept(a.id)
        let failed = expectation(description: "parked write failed")
        Task {
            do { try await a.write(Data(count: Int(ChannelFrame.initialCredit) + 1)) } catch { failed.fulfill() }
        }
        try await Task.sleep(nanoseconds: 100_000_000)  // parked at zero credit
        await a.finish()
        await fulfillment(of: [failed], timeout: 2)
    }

    func testShutdownFailsAParkedWriter() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let failed = expectation(description: "parked write failed")
        Task {
            do { try await a.write(Data(count: Int(ChannelFrame.initialCredit) + 1)) } catch {
                XCTAssertEqual(error as? ChannelMuxError, .shutdown)
                failed.fulfill()
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        pair.controller.shutdown()
        await fulfillment(of: [failed], timeout: 2)
    }

    /// A loop over `accept()` must end when the connection does, not wait forever.
    func testAcceptStreamFinishesOnShutdown() async throws {
        let pair = MuxPair()
        let stream = pair.controller.accept()
        let ended = expectation(description: "stream ended")
        Task { for await _ in stream {}; ended.fulfill() }
        pair.controller.shutdown()
        await fulfillment(of: [ended], timeout: 2)
    }

    /// A cancelled task's read or write must return rather than stay parked; cancelling it
    /// cancels the channel, both ends, since the stream is now torn.
    func testTaskCancellationEndsParkedReadAndWrite() async throws {
        let pair = MuxPair()
        let a = try await pair.controller.open()
        let b = try await pair.host.accept(a.id)
        let reader = Task { _ = try await a.read() }
        try await Task.sleep(nanoseconds: 50_000_000)
        reader.cancel()
        do { try await reader.value; XCTFail("cancelled read returned normally") } catch {}
        do { _ = try await b.read(); XCTFail("the peer never heard of the cancel") } catch {}

        let c = try await pair.controller.open()
        _ = try await pair.host.accept(c.id)
        let writer = Task { try await c.write(Data(count: Int(ChannelFrame.initialCredit) + 1)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        writer.cancel()
        do { try await writer.value; XCTFail("cancelled write returned normally") } catch {}
    }

    /// Unclaimed peer channels are capped: each is bounded by the window, but an
    /// authenticated peer could otherwise open ids without end and make the host hold
    /// 256 KiB for each. Past the cap a new id is closed; claimed ones do not count.
    func testUnclaimedPeerChannelsAreCapped() async throws {
        let pair = MuxPair()
        var ids: [ChannelID] = []
        for _ in 0..<ChannelMux.maxUnclaimed {
            let c = try await pair.controller.open()
            try await c.write(Data([1]))
            ids.append(c.id)
        }
        let over = try await pair.controller.open()
        try await over.write(Data([1]))
        do { _ = try await pair.host.accept(over.id); XCTFail("past the cap still opened") } catch {}
        do { _ = try await over.read(); XCTFail("the controller's end stayed open") } catch {}

        // Claiming one frees a place.
        _ = try await pair.host.accept(ids[0])
        let next = try await pair.controller.open()
        try await next.write(Data([1]))
        _ = try await pair.host.accept(next.id)
    }

    /// A credit frame for a channel never seen is noise, not an open: it must not create a
    /// channel, which would count against the unclaimed cap and surface on `accept()` with
    /// nothing behind it.
    func testCreditForAnUnknownChannelIsDropped() async throws {
        let pair = MuxPair()
        let stream = pair.host.accept()
        let surfaced = expectation(description: "a channel surfaced")
        surfaced.isInverted = true
        surfaced.assertForOverFulfill = false
        let watcher = Task { for await _ in stream { surfaced.fulfill() } }
        for id in stride(from: ChannelID(1), through: 9, by: 2) {
            pair.host.receive(binary: ChannelFrame.credit(channel: id, bytes: 10).encoded())
        }
        await fulfillment(of: [surfaced], timeout: 0.3)
        XCTAssertEqual(pair.framesToController, 0, "answered a stray credit")
        watcher.cancel()
    }

    /// Every closed id is remembered so a late frame for it is dropped, but a forwarded port
    /// opens one channel per connection: a set of every id ever closed grew without bound for
    /// the link's life. A contiguous run of closed ids collapses into a watermark, so the
    /// memory is the ids closed *above* the oldest one still open, and the drop rule is the same.
    func testClosedIDTombstonesStayBounded() async throws {
        let pair = MuxPair()
        let longLived = try await pair.controller.open()
        _ = try await pair.host.accept(longLived.id)
        var closed: [ChannelID] = []
        for _ in 0..<200 {
            let c = try await pair.controller.open()
            _ = try await pair.host.accept(c.id)
            c.cancel()
            closed.append(c.id)
        }
        // Held above the one still open: those ids really are remembered one by one.
        XCTAssertEqual(pair.controller.tombstoneCount, 200)
        XCTAssertEqual(pair.host.tombstoneCount, 200)

        longLived.cancel()
        XCTAssertEqual(pair.controller.tombstoneCount, 0, "the run below nextID collapses once nothing in it is open")
        XCTAssertEqual(pair.host.tombstoneCount, 0)

        // The drop rule survives the collapse: a late frame for an old id is still dropped,
        // and the id still cannot be claimed again.
        let before = pair.framesToController
        for id in [longLived.id, closed[0], closed[199]] {
            pair.host.receive(binary: ChannelFrame(channel: id, kind: .data, payload: Data("x".utf8)).encoded())
            do { _ = try await pair.host.accept(id); XCTFail("re-claimed closed \(id)") } catch {
                XCTAssertEqual(error as? ChannelMuxError, .closed)
            }
        }
        XCTAssertEqual(pair.framesToController, before, "answered a frame for a closed id")

        // And the next id is untouched by the watermark.
        let next = try await pair.controller.open()
        let peer = try await pair.host.accept(next.id)
        try await next.write(Data("ok".utf8))
        await next.finish()
        let got = try await readAll(peer)
        XCTAssertEqual(got, Data("ok".utf8))
    }

    /// The host side sees ids out of order (a later channel's bytes can beat an earlier one's
    /// request), so its watermark may only pass ids that really closed.
    func testWatermarkWaitsForAGapInPeerIDs() async throws {
        let pair = MuxPair()
        let first = try await pair.controller.open()     // never reaches the host
        let second = try await pair.controller.open()
        _ = try await pair.host.accept(second.id)
        second.cancel()
        XCTAssertEqual(pair.host.tombstoneCount, 1, "id \(first.id) is not closed, so \(second.id) cannot collapse")
        let late = try await pair.host.accept(first.id)
        try await first.write(Data("late".utf8))
        await first.finish()
        let got = try await readAll(late)
        XCTAssertEqual(got, Data("late".utf8))
    }

    /// The collapse at the edges: 0 is no side's id and never closed, and the last id of each
    /// parity cannot be passed by the floor, so it must stay remembered rather than vanish.
    func testClosedIDsEdges() {
        var ids = ChannelMux.ClosedIDs()
        XCTAssertFalse(ids.contains(0))
        ids.insert(1); ids.insert(2)
        XCTAssertTrue(ids.contains(1) && ids.contains(2))
        XCTAssertEqual(ids.heldIndividually, 0)
        XCTAssertFalse(ids.contains(0) || ids.contains(3) || ids.contains(4))

        // Every id below the top few already closed, as if the link had lived that long.
        var top = ChannelMux.ClosedIDs(evenFloor: ChannelID.max - 3, oddFloor: ChannelID.max - 4)
        for id in [ChannelID.max, ChannelID.max - 2, ChannelID.max - 4, ChannelID.max - 1, ChannelID.max - 3] {
            top.insert(id)
        }
        for id in (ChannelID.max - 6)...ChannelID.max {
            XCTAssertTrue(top.contains(id), "\(id) closed")
        }
        XCTAssertEqual(top.heldIndividually, 2, "only the last id of each parity is held one by one")
    }

    /// The unclaimed cap used to stop applying once anyone called `accept()`: each new peer
    /// channel was yielded into the stream, whose buffer had no bound, so a consumer that
    /// stopped draining let a peer queue channels (each with a window of bytes) without end.
    /// The stream now holds at most `maxUnclaimed`; one past that is closed like any other
    /// channel past the cap.
    func testAcceptStreamIsCappedLikeUnclaimedChannels() async throws {
        let pair = MuxPair()
        let stream = pair.controller.accept()     // nobody drains it yet
        var opened: [any ByteChannel] = []
        for _ in 0..<ChannelMux.maxUnclaimed {
            let c = try await pair.host.open()
            try await c.write(Data([1]))
            opened.append(c)
        }
        let over = try await pair.host.open()
        try await over.write(Data([1]))
        // A read, not a check of state: if the channel stayed open it parks, and the timeout
        // reports that instead of hanging the suite.
        let closed = expectation(description: "past the cap is closed")
        let reader = Task {
            do { _ = try await over.read() } catch {
                XCTAssertEqual(error as? ChannelMuxError, .closed)
                closed.fulfill()
            }
        }
        await fulfillment(of: [closed], timeout: 2)
        reader.cancel()

        // Every channel within the cap is still delivered, in order, and readable.
        var got: [ChannelID] = []
        for await channel in stream {
            let first = try await channel.read()
            XCTAssertEqual(first, Data([1]))
            got.append(channel.id)
            if got.count == opened.count { break }
        }
        XCTAssertEqual(got, opened.map(\.id))
    }
}
