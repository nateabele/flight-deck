import FleetKit
import XCTest
@testable import FlightDeck

/// Guards the timeline fixtures themselves, and what they must contain.
///
/// Two jobs. `Fixtures/` is a folder reference copied as resources, so a file that fails to
/// land in the bundle otherwise produces a confusing nil at its first use site rather than an
/// error here — the same reason `CodexRolloutFixtureTests` exists. And a capture that came
/// out missing a record shape would silently under-cover the mapper, so the composition is
/// asserted rather than assumed.
final class TimelineFixtureTests: XCTestCase {
    static func lines(_ name: String, in directory: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle(for: TimelineFixtureTests.self).url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/\(directory)"
            ),
            "Fixtures/\(directory)/\(name).jsonl not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func mapped(_ lines: [String]) -> [TimelineItem] {
        var offset = 0
        var items: [TimelineItem] = []
        for line in lines {
            items += ClaudeTimelineMapper.items(inLine: line, at: offset)
            offset += line.utf8.count + 1
        }
        return items
    }

    private func claudeTranscript() throws -> [String] {
        try Self.lines("transcript.captured", in: "Claude")
    }

    func testTheCapturedClaudeTranscriptExercisesEveryKindThisMapperEmits() throws {
        let kinds = Set(mapped(try claudeTranscript()).map(\.kind))
        XCTAssertEqual(kinds, [.userTurn, .assistantText, .toolCall, .toolResult],
                       "the capture must contain a prompt, a reply, a tool call and its "
                       + "result; recapture per the plan's Task 3 Step 1 if it does not. "
                       + "(.thinking is absent on purpose — the only thinking block the "
                       + "capture contains is a REDACTED one, which is dropped; the unit "
                       + "tests cover an unredacted one.)")
    }

    /// The whole mapping, in order, over bytes claude actually wrote — the check the
    /// hand-written unit tests structurally cannot make, since they assert against lines
    /// written by the same person who wrote the mapper.
    func testTheCapturedTranscriptMapsToTheConversationThatWasHeld() throws {
        let items = mapped(try claudeTranscript())
        XCTAssertEqual(items.map(\.kind), [
            .userTurn, .assistantText,
            .userTurn, .toolCall, .toolResult, .assistantText,
            .userTurn, .assistantText,
        ], "three prompts, one of which ran a tool; the redacted thinking record emits nothing")
        XCTAssertEqual(items.map(\.body.text), [
            "Reply with exactly the word: ok",
            "ok",
            "Run this exact shell command with the Bash tool and then say done: echo hi",
            """
            {
              "command" : "echo hi",
              "description" : "Echo hi"
            }
            """,
            "hi",
            "done",
            "Think about this step by step before answering, then reply with just the "
                + "number: what is 17 times 3?",
            "51",
        ])
        XCTAssertEqual(items[3].body.tool, "Bash")
        XCTAssertEqual(items[3].body.summary, "echo hi")
        XCTAssertEqual(items[3].body.callID, "toolu_0145fQBTj1mVv9oTVVfhbUqh")
        XCTAssertEqual(items[4].body.callID, items[3].body.callID,
                       "the result must name the call it answers, which is what pairs them "
                       + "on screen")
        XCTAssertNil(items[4].body.tool, "no tool_result record names its tool")
        XCTAssertTrue(items.allSatisfy { $0.status == .complete })
        XCTAssertTrue(items.allSatisfy { $0.at?.hasPrefix("2026-08-23T01:5") == true },
                      "every item is dated from its own record, verbatim")
    }

    /// Ground truth for the rule with the most expensive silent failure. This block is real:
    /// `claude-opus-5` answered a step-by-step prompt with `{"type":"thinking","thinking":"",
    /// "signature":"CAIS…"}` and nothing else. Redaction is not a rare edge — it is what a
    /// whole class of thinking blocks looks like on the wire, and emitting them is a blank row
    /// each, with a few hundred opaque bytes attached.
    func testTheCapturedTranscriptsRedactedThinkingBlockEmitsNothing() throws {
        let lines = try claudeTranscript()
        let redacted = lines.filter { $0.contains(#""type":"thinking","thinking":"""#) }
        XCTAssertEqual(redacted.count, 1,
                       "the capture must still contain the redacted thinking record; "
                       + "recapture per the plan's Task 3 Step 1 if it does not")
        XCTAssertTrue(ClaudeTimelineMapper.items(inLine: try XCTUnwrap(redacted.first), at: 0)
            .isEmpty)
        XCTAssertTrue(mapped(lines).allSatisfy { !$0.body.text.contains("CAIS") },
                      "a signature is not thinking and never goes on the wire")
    }

    func testEveryItemFromTheCapturedTranscriptHasAUniqueId() throws {
        let ids = mapped(try claudeTranscript()).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "ids are offset#index; a collision means the offset arithmetic is wrong "
                       + "and a client would drop rows as duplicates")
    }

    /// The whole point of the fixture being captured rather than authored.
    func testNoCapturedLineWasEdited() throws {
        for line in try claudeTranscript() {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "a line that no longer parses was edited: \(line.prefix(60))"
            )
        }
    }
}
