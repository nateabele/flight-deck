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
