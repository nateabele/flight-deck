import CryptoKit
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

    /// The provenance file beside a capture, which is where its checksum lives.
    static func provenance(_ name: String, in directory: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle(for: TimelineFixtureTests.self).url(
                forResource: "\(name).provenance", withExtension: "json",
                subdirectory: "Fixtures/\(directory)"
            ),
            "Fixtures/\(directory)/\(name).provenance.json not found in the test bundle"
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
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
            .userTurn, .toolCall, .toolResult, .assistantText,
            .userTurn, .toolCall, .toolResult, .assistantText,
        ], "five prompts, three of which ran a tool; the redacted thinking record and the "
            + "document record both emit nothing")
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
            "Read the file /tmp/t3-tiny.png with the Read tool, then say: seen",
            """
            {
              "file_path" : "\\/tmp\\/t3-tiny.png"
            }
            """,
            // The image-only result. Empty is deliberate — see `resultText`; the payload is
            // what must not travel, and there is no text element to show instead.
            "",
            "seen",
            "Read the file /tmp/t3-tiny.pdf with the Read tool, then say: read",
            """
            {
              "file_path" : "\\/tmp\\/t3-tiny.pdf"
            }
            """,
            "PDF file read: /tmp/t3-tiny.pdf (605 bytes)",
            "read",
        ])
        XCTAssertEqual(items[3].body.tool, "Bash")
        XCTAssertEqual(items[3].body.summary, "echo hi")
        XCTAssertEqual(items[3].body.callID, "toolu_0145fQBTj1mVv9oTVVfhbUqh")
        XCTAssertEqual(items[4].body.callID, items[3].body.callID,
                       "the result must name the call it answers, which is what pairs them "
                       + "on screen")
        XCTAssertNil(items[4].body.tool, "no tool_result record names its tool")
        XCTAssertEqual(items[9].body.tool, "Read")
        XCTAssertEqual(items[9].body.summary, "/tmp/t3-tiny.png")
        XCTAssertEqual(items[10].body.callID, items[9].body.callID)
        XCTAssertTrue(items.allSatisfy { $0.status == .complete })
        XCTAssertTrue(items.allSatisfy { $0.at?.hasPrefix("2026-08-23T0") == true },
                      "every item is dated from its own record, verbatim")
    }

    /// **The two base64 payloads in this capture, from the two directions the mapper meets
    /// them, neither of which the mapping table names.** A `Read` of a `.png` answers with a
    /// `tool_result` whose content is a block array holding an `image`; a `Read` of a `.pdf`
    /// additionally attaches the whole file as a `document` block in a `user` record. Both are
    /// real records here, and neither payload may appear in any item.
    func testNoCapturedPayloadReachesAnItem() throws {
        let lines = try claudeTranscript()
        XCTAssertEqual(lines.filter { $0.contains("iVBORw0KGgo") }.count, 1,
                       "the capture must still hold the image tool_result")
        XCTAssertEqual(lines.filter { $0.contains("JVBERi0xLjQ") }.count, 2,
                       "the capture must still hold the PDF's tool_result and document record")
        let bodies = mapped(lines).flatMap { [$0.body.text, $0.body.summary ?? ""] }
        XCTAssertFalse(bodies.contains { $0.contains("iVBORw0KGgo") || $0.contains("JVBERi0xLjQ") })
    }

    /// **The `isMeta` rule, proven on a real record that carries a megabyte-class payload.**
    ///
    /// Reading a PDF makes claude write a second `user` record holding the whole file as a
    /// `document` block — and mark it `isMeta: true`, alongside `turnCompanion: true`. That is
    /// the same family as the image-geometry note the mapping table names, and it is what
    /// stops this record here. The `document` block itself never reaches `userItem`, so its
    /// arm stays uncovered by the capture (the provenance says so); that is a second line of
    /// defence, not the one doing the work.
    func testTheCapturedDocumentAttachmentIsMetaAndEmitsNothing() throws {
        let document = try claudeTranscript().filter { $0.contains(#""type":"document""#) }
        XCTAssertEqual(document.count, 1)
        let line = try XCTUnwrap(document.first)
        XCTAssertTrue(line.contains(#""isMeta":true"#),
                      "if claude stops marking these meta, the guard below stops applying and "
                      + "the second line of defence — no row for a `document` block — is all "
                      + "that is left")
        XCTAssertTrue(ClaudeTimelineMapper.items(inLine: line, at: 0).isEmpty)
    }

    /// Ground truth for the rule with the most expensive silent failure. This block is real:
    /// `claude-opus-5` answered a step-by-step prompt with `{"type":"thinking","thinking":"",
    /// "signature":"CAIS…"}` and nothing else. Redaction is not a rare edge — it is what a
    /// whole class of thinking blocks looks like on the wire, and emitting them is a blank row
    /// each, with a few hundred opaque bytes attached.
    func testTheCapturedTranscriptsRedactedThinkingBlockEmitsNothing() throws {
        let lines = try claudeTranscript()
        let redacted = lines.filter { $0.contains(#""thinking":"","signature":"#) }
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
    ///
    /// Against the file's checksum, not against its parseability: every semantic edit worth
    /// worrying about — a softened prompt, a changed `cwd`, a swapped `tool_use_id` — leaves
    /// valid JSON behind, so a parse check catches only bytes appended past the end. The
    /// provenance records the digest of the file as captured; this is what makes that record
    /// enforceable.
    func testTheCapturedTranscriptMatchesItsRecordedChecksum() throws {
        let recorded = try XCTUnwrap(
            (try Self.provenance("transcript.captured", in: "Claude")["sha256"]
                as? [String: Any])?["transcript.captured.jsonl"] as? String,
            "the provenance must record a sha256 for every file it lists"
        )
        let url = try XCTUnwrap(Bundle(for: TimelineFixtureTests.self).url(
            forResource: "transcript.captured", withExtension: "jsonl",
            subdirectory: "Fixtures/Claude"
        ))
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), recorded,
                       "the capture no longer matches the digest in its provenance file — it "
                       + "was edited, or it was recaptured without updating the provenance")
    }

    func testEveryCapturedLineIsStillOneJSONRecord() throws {
        for line in try claudeTranscript() {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "a line that no longer parses was edited: \(line.prefix(60))"
            )
        }
    }
}
