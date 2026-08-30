import XCTest
@testable import FlightDeck

/// The Plannotator HTTP contract, against a recorded transport.
///
/// A double rather than a live gate: a test that needs a four-day hook running is a test that
/// does not run. The shapes encoded here were read off the `plannotator` binary and confirmed
/// against a live server on 2026-08-29.
final class PlanGateClientTests: XCTestCase {

    private actor Recorder {
        var requests: [URLRequest] = []
        var responses: [(Data, Int)] = []
        func push(_ response: (Data, Int)) { responses.append(response) }
        func record(_ request: URLRequest) -> (Data, Int)? {
            requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        func all() -> [URLRequest] { requests }
    }

    private func client(_ recorder: Recorder) -> PlanGateClient {
        PlanGateClient(port: 54232, transport: { request in await recorder.record(request) })
    }

    func testPlanReadsTheBodyField() async throws {
        let recorder = Recorder()
        await recorder.push((Data(##"{"plan":"# Title\n\nBody."}"##.utf8), 200))
        let plan = await client(recorder).plan()
        XCTAssertEqual(plan, "# Title\n\nBody.")
        let requests = await recorder.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/plan")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "127.0.0.1")
    }

    /// Loopback, always. The API is unauthenticated; a hostname that could resolve off-machine
    /// would be a way to reach someone else's gate.
    func testEveryRequestGoesToLoopback() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        await recorder.push((Data("{}".utf8), 200))
        _ = await client(recorder).annotate(text: "n", originalText: "phrase")
        _ = await client(recorder).resolve(approved: true, feedback: nil)
        for request in await recorder.all() {
            XCTAssertEqual(request.url?.host, "127.0.0.1")
        }
    }

    func testAnnotatePostsAnInlineComment() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        let ok = await client(recorder).annotate(text: "needs a rollback",
                                                 originalText: "open the file")
        XCTAssertTrue(ok)
        let requests = await recorder.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/external-annotations")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "COMMENT")
        XCTAssertEqual(json["source"] as? String, "flight-deck")
        XCTAssertEqual(json["text"] as? String, "needs a rollback")
        XCTAssertEqual(json["originalText"] as? String, "open the file")
    }

    /// A comment with no anchor is a `GLOBAL_COMMENT` and must carry no `originalText` —
    /// an empty string would be matched as a substring and pin to the first character.
    func testAnnotateWithoutAnAnchorIsGlobal() async throws {
        let recorder = Recorder()
        await recorder.push((Data("{}".utf8), 200))
        _ = await client(recorder).annotate(text: "missing a rollback section",
                                            originalText: nil)
        let requests = await recorder.all()
        let request = try XCTUnwrap(requests.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "GLOBAL_COMMENT")
        XCTAssertNil(json["originalText"])
    }

    func testResolveApproveHitsApproveWithFeedback() async throws {
        let recorder = Recorder()
        await recorder.push((Data(#"{"ok":true}"#.utf8), 200))
        let ok = await client(recorder).resolve(approved: true, feedback: "ship it, but rename X")
        XCTAssertTrue(ok)
        let requests = await recorder.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/approve")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["feedback"] as? String, "ship it, but rename X")
    }

    func testResolveDenyHitsDeny() async throws {
        let recorder = Recorder()
        await recorder.push((Data(#"{"ok":true}"#.utf8), 200))
        _ = await client(recorder).resolve(approved: false, feedback: "step 3 is wrong")
        let requests = await recorder.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/deny")
    }

    /// A gate that closed between the tap and the request. The transport returns nothing;
    /// the caller must learn that, not read `false` as "the server said no".
    func testATransportFailureIsNotSuccess() async {
        let recorder = Recorder()   // no queued response
        let ok = await client(recorder).resolve(approved: true, feedback: nil)
        XCTAssertFalse(ok)
    }

    func testANon2xxIsNotSuccess() async {
        let recorder = Recorder()
        await recorder.push((Data("gone".utf8), 404))
        let ok = await client(recorder).resolve(approved: true, feedback: nil)
        XCTAssertFalse(ok)
    }
}
