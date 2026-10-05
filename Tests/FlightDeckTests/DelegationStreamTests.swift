import XCTest
@testable import FleetKit

/// `FleetSocketServer` lets a delegation stream answer one `cid` with several frames until a
/// terminal one, and still answers every other request exactly once.
@MainActor
final class DelegationStreamTests: XCTestCase {
    /// Sends `first`, then a `recentlyClosed` sentinel on the same connection, and returns every
    /// frame that arrived for `first`'s cid before the sentinel's reply. One connection is
    /// FIFO, so anything the server let through for `first` has arrived by then.
    private func frames(for first: FleetRequest,
                        answer: @escaping (_ cid: Int, _ reply: (ServerFrame) -> Void) -> Void) async throws -> [ServerFrame] {
        let path = "/tmp/fdds-\(UUID().uuidString.prefix(8)).sock"
        let server = FleetSocketServer()
        defer { server.stop() }
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            if case .recentlyClosed = request { return reply(.recentlyClosed(cid: cid, [])) }
            answer(cid, reply)
        }
        try await server.startLocal(path: path)

        let client = FleetClient(localCaller: nil)
        defer { client.disconnect() }
        let done = expectation(description: "sentinel")
        var firstCID = -1
        var sentinel = -1
        var got: [ServerFrame] = []
        client.onFrame = { frame in
            if case .snapshot = frame {
                firstCID = client.send(first)
                sentinel = client.send(FleetRequest.recentlyClosed)
                return
            }
            if frame.correlationID == firstCID { got.append(frame) }
            if frame.correlationID == sentinel { done.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [done], timeout: 10)
        return got
    }

    func testADelegateStreamPassesEveryFrameUntilTheTerminalOne() async throws {
        let got = try await frames(for: .delegate(.ps)) { cid, reply in
            reply(.delegateNotice(cid: cid, message: "one"))
            reply(.delegateNotice(cid: cid, message: "two"))
            reply(.delegateExit(cid: cid, status: 3))
            reply(.ack(cid: cid)) // after the terminal frame: must never arrive
        }
        XCTAssertEqual(got.count, 3, "\(got)")
        XCTAssertEqual(got.last, .delegateExit(cid: got.last?.correlationID ?? -1, status: 3))
    }

    func testAnErrEndsAStream() async throws {
        let got = try await frames(for: .delegate(.ps)) { cid, reply in
            reply(.delegateNotice(cid: cid, message: "one"))
            reply(.err(cid: cid, code: "x"))
            reply(.delegateNotice(cid: cid, message: "late"))
        }
        XCTAssertEqual(got.count, 2, "\(got)")
    }

    /// Every pre-existing request is unchanged: its first reply is its only reply.
    func testAnOrdinaryRequestIsStillAnsweredOnce() async throws {
        let got = try await frames(for: .hostList) { cid, reply in
            reply(.hostList(cid: cid, []))
            reply(.ack(cid: cid))
        }
        XCTAssertEqual(got, [.hostList(cid: got.first?.correlationID ?? -1, [])])
    }
}

/// `ReplyStream`'s rules, without a socket: the answered-once rule, and the output bound.
final class DelegationReplyStreamTests: XCTestCase {
    private let mebibyte = Data(count: 1024 * 1024)

    func testOrdinaryRepliesAreSentInlineOnce() {
        let stream = ReplyStream()
        XCTAssertEqual(stream.admit(.ack(cid: 1)), .send(.ack(cid: 1)))
        XCTAssertEqual(stream.admit(.ack(cid: 1)), .drop)
    }

    /// Past 4 MiB of output the stack has not taken, the stream ends with `slow_reader` — once
    /// — and nothing more goes out; sent bytes free the window again.
    func testOutputPastTheHighWaterMarkEndsTheStream() {
        let stream = ReplyStream()
        for offset in 0..<4 {
            XCTAssertEqual(stream.admit(.delegateOutput(cid: 1, stream: "stdout", offset: Int64(offset) << 20, data: mebibyte)),
                           .stream(.delegateOutput(cid: 1, stream: "stdout", offset: Int64(offset) << 20, data: mebibyte),
                                   bytes: mebibyte.count))
        }
        stream.sent(mebibyte.count)
        guard case .stream(.delegateOutput, _) = stream.admit(.delegateOutput(cid: 1, stream: "stdout", offset: 4 << 20, data: mebibyte))
        else { return XCTFail("a freed window takes more") }
        guard case .stream(.err(1, "slow_reader", _), 0) = stream.admit(.delegateOutput(cid: 1, stream: "stdout", offset: 5 << 20, data: mebibyte))
        else { return XCTFail("past the mark, the stream ends") }
        XCTAssertEqual(stream.admit(.delegateExit(cid: 1, status: 0)), .drop)
    }

    /// One oversized chunk with nothing in flight is still sent: the bound is on a backlog.
    func testOneLargeChunkAloneIsSent() {
        let stream = ReplyStream()
        let big = Data(count: 5 * 1024 * 1024)
        guard case .stream(.delegateOutput, _) = stream.admit(.delegateOutput(cid: 1, stream: "stdout", offset: 0, data: big))
        else { return XCTFail() }
    }
}
