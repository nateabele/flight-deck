import XCTest
@testable import FleetKit

/// The content vocabulary, and the one property of it that is not obvious: an unrecognised
/// `kind` or `status` must DECODE, not throw.
///
/// `FleetSocket.receive` treats a frame it cannot parse as a protocol violation and ends the
/// connection — deliberately, because two sides silently disagreeing about state is the
/// failure the whole resume design exists to prevent. That rule is correct for a malformed
/// frame and catastrophic for a well-formed one carrying a kind this build has not heard of:
/// a Mac shipping a new `TimelineItem.Kind` would disconnect every older phone, permanently,
/// with no diagnostic. Same reasoning as `WireSession.agent` being a `String` rather than an
/// enum — see that property's comment.
final class TimelineVocabularyTests: XCTestCase {
    private func decode(_ json: String) throws -> TimelineItem {
        try JSONDecoder().decode(TimelineItem.self, from: Data(json.utf8))
    }

    func testAnUnknownKindDecodesRatherThanThrowing() throws {
        let item = try decode("""
            {"id":"12#0","kind":"videoClip","status":"complete","body":{"text":"hi"}}
            """)
        XCTAssertEqual(item.kind, .unknown)
        XCTAssertEqual(item.body.text, "hi", "the rest of the item must survive the unknown kind")
    }

    func testAnUnknownStatusDecodesRatherThanThrowing() throws {
        let item = try decode("""
            {"id":"12#0","kind":"assistantText","status":"buffering","body":{"text":"hi"}}
            """)
        XCTAssertEqual(item.status, .unknown)
    }

    func testEveryKnownKindRoundTrips() throws {
        for kind in [TimelineItem.Kind.userTurn, .assistantText, .thinking,
                     .toolCall, .toolResult, .prompt] {
            let item = TimelineItem(
                id: "0#0", kind: kind, status: .complete,
                body: TimelineItem.Body(text: "x")
            )
            let data = try JSONEncoder().encode(item)
            XCTAssertEqual(try JSONDecoder().decode(TimelineItem.self, from: data), item,
                           "\(kind) did not survive a round trip")
        }
    }

    func testAnItemsIdentifierIsItsByteOffsetAndBlockIndex() {
        XCTAssertEqual(TimelineItem.identifier(offset: 4096, index: 2), "4096#2")
    }

    /// The body's optional fields are absent from the wire when they are nil, so a plain
    /// prose item is a small object rather than four explicit nulls. This is checked because
    /// a page carries up to 200 of them.
    func testAProseBodyEncodesWithoutItsToolFields() throws {
        let data = try JSONEncoder().encode(
            TimelineItem(id: "0#0", kind: .assistantText, status: .complete,
                         body: TimelineItem.Body(text: "hello"))
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"tool\""))
        XCTAssertFalse(json.contains("\"callID\""))
        XCTAssertFalse(json.contains("\"summary\""))
    }

    /// Every `Body` field set to a distinct value, round-tripped through the hand-written
    /// codec. Distinct matters: two fields holding equal values would still round-trip
    /// correctly even if `Body.encode`/`Body.init(from:)` swapped their `CodingKey`s, which
    /// would defeat the point of this test. Also covers `Status.streaming`, which nothing
    /// else in this file constructs — it ships in the vocabulary only so a later `Status`
    /// addition is not a protocol break, and that makes it the case most likely to bit-rot
    /// unnoticed if it is never exercised.
    func testABodyWithEveryFieldSetRoundTrips() throws {
        let item = TimelineItem(
            id: "0#0", kind: .toolResult, status: .streaming,
            body: TimelineItem.Body(
                text: "the full text",
                summary: "the summary line",
                tool: "Read",
                callID: "call_123",
                truncatedBytes: 512,
                isError: true
            )
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TimelineItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.status, .streaming)
        XCTAssertEqual(decoded.body.text, "the full text")
        XCTAssertEqual(decoded.body.summary, "the summary line")
        XCTAssertEqual(decoded.body.tool, "Read")
        XCTAssertEqual(decoded.body.callID, "call_123")
        XCTAssertEqual(decoded.body.truncatedBytes, 512)
        XCTAssertEqual(decoded.body.isError, true)
    }
}
