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

    // MARK: - Codex

    private func mappedCodex(_ lines: [String]) -> [TimelineItem] {
        var offset = 0
        var items: [TimelineItem] = []
        for line in lines {
            items += CodexTimelineMapper.items(inRolloutLine: line, at: offset)
            offset += line.utf8.count + 1
        }
        return items
    }

    private func codexRollout() throws -> [String] {
        try Self.lines("rollout-content.captured", in: "Codex")
    }

    func testTheCapturedRolloutExercisesEveryKindThisMapperEmits() throws {
        let kinds = Set(mappedCodex(try codexRollout()).map(\.kind))
        XCTAssertEqual(kinds, [.userTurn, .assistantText, .thinking, .toolCall, .toolResult],
                       "the capture must contain a prompt, a reply, a thought, a tool call "
                       + "and its result; recapture per the plan's Task 4 Step 1. "
                       + "Got \(kinds)")
    }

    /// The whole mapping, in order, over bytes codex actually wrote — the check the
    /// hand-written unit tests structurally cannot make, since they assert against lines
    /// written by the same person who wrote the mapper.
    func testTheCapturedRolloutMapsToTheConversationThatWasHeld() throws {
        let items = mappedCodex(try codexRollout())
        XCTAssertEqual(items.map(\.kind), [
            .userTurn, .assistantText, .toolCall, .toolResult, .assistantText,
            .userTurn, .thinking, .assistantText, .toolCall, .toolResult, .assistantText,
            .userTurn, .assistantText, .toolCall, .toolResult, .toolCall, .toolResult,
            .assistantText,
        ], "three prompts, each of which ran a tool; the third needed two calls to reach an "
        + "MCP tool it was then refused")
        XCTAssertEqual(items.filter { $0.kind != .toolCall && $0.kind != .toolResult }
            .map(\.body.text), [
                "Run the shell command: echo hi. Then reply with exactly the word: done",
                "I\u{2019}ll run the command now.",
                "done",
                "Use the update_plan tool to record a two-step plan for tidying a directory, "
                    + "then reply with exactly the word: planned",
                "**Planning commentary integration**",
                "I\u{2019}ll record the two-step plan.",
                "planned",
                "Call the echo_upper tool with the text \"hello timeline\", then reply with "
                    + "exactly the word: echoed",
                "I\u{2019}ll call the requested tool.",
                "echoed",
            ])
        XCTAssertEqual(items[2].body.tool, "exec")
        XCTAssertEqual(items[2].body.callID, "call_x14xQdGXch1AgsA0dDpLoWWq")
        XCTAssertTrue(items[2].body.text.hasPrefix("const r = await tools.exec_command("),
                      "a custom_tool_call's input is a program, carried verbatim")
        XCTAssertEqual(items[3].body.callID, items[2].body.callID,
                       "the result must name the call it answers, which is what pairs them "
                       + "on screen")
        XCTAssertNil(items[3].body.tool, "no output record names its tool")
        // The `output` of a 0.148.0 tool result is a block ARRAY, and this is the assertion
        // that would have caught the mapper reading it as a String: it renders as "" and the
        // whole tool half of the timeline goes silently blank.
        XCTAssertEqual(items[3].body.text, "Script completed\nWall time 0.1 seconds\nOutput:\nhi\n")
        XCTAssertTrue(items.allSatisfy { $0.status == .complete })
        XCTAssertTrue(items.allSatisfy { $0.at?.hasPrefix("2026-08-23T02:2") == true },
                      "every item is dated from its own record, verbatim")
    }

    /// The two rules whose violation is silent rather than noisy, checked against the real
    /// records that carry them: `response_item`/`reasoning`'s ciphertext must never reach a
    /// phone, and `response_item`/`message` is the assembled prompt — the skills and plugin
    /// catalogues — not anything a user said.
    func testTheCapturedRolloutsCiphertextAndPromptAssemblyAreNeverCarried() throws {
        let lines = try codexRollout()
        XCTAssertEqual(lines.filter { $0.contains("\"encrypted_content\"") }.count, 3,
                       "the capture must still contain the encrypted reasoning records; "
                       + "recapture per the plan's Task 4 Step 1 if it does not")
        XCTAssertEqual(lines.filter { $0.contains("<recommended_plugins>") }.count, 1,
                       "the capture must still contain the prompt-assembly message")
        let items = mappedCodex(lines)
        XCTAssertTrue(items.allSatisfy { !$0.body.text.contains("gAAAAA") },
                      "encrypted_content is not thinking and never goes on the wire")
        XCTAssertTrue(items.allSatisfy { !$0.body.text.contains("<recommended_plugins>") },
                      "the assembled prompt is not a user turn")
    }

    /// The existing capture is filtered to `event_msg`, which is why a second one was needed:
    /// it cannot exercise the tool half of the table at all. Asserted so nobody "consolidates"
    /// the two fixtures and quietly loses that coverage.
    func testTheOlderRolloutCaptureHasNoToolRecordsAndThatIsWhyThereAreTwo() throws {
        let kinds = Set(mappedCodex(try Self.lines("rollout.captured", in: "Codex")).map(\.kind))
        XCTAssertFalse(kinds.contains(.toolCall))
        XCTAssertTrue(kinds.contains(.userTurn), "it is still a conversation, just a prose one")
    }

    func testEveryItemFromTheCapturedRolloutHasAUniqueId() throws {
        let ids = mappedCodex(try codexRollout()).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "ids are offset#index; a collision means the offset arithmetic is wrong "
                       + "and a client would drop rows as duplicates")
    }

    /// The whole point of the fixtures being captured rather than authored.
    ///
    /// Against each file's checksum, not against its parseability: every semantic edit worth
    /// worrying about — a softened prompt, a changed `cwd`, a swapped `call_id` — leaves valid
    /// JSON behind, so the parse test below catches only bytes appended past the end.
    ///
    /// Driven off the provenance's own `files` list rather than off one hard-coded name, so a
    /// fifth capture added to this directory without a digest fails here instead of joining it
    /// unguarded.
    func testEveryCapturedRolloutMatchesItsRecordedChecksum() throws {
        let provenance = try Self.provenance("rollout.captured", in: "Codex")
        let files = try XCTUnwrap(provenance["files"] as? [String])
        let recorded = try XCTUnwrap(provenance["sha256"] as? [String: String])
        XCTAssertEqual(Set(recorded.keys), Set(files),
                       "the provenance must record a sha256 for every file it lists, and list "
                       + "every file it records one for")
        for file in files {
            let url = try XCTUnwrap(Bundle(for: TimelineFixtureTests.self).url(
                forResource: (file as NSString).deletingPathExtension,
                withExtension: "jsonl", subdirectory: "Fixtures/Codex"
            ), "Fixtures/Codex/\(file) not found in the test bundle")
            let digest = SHA256.hash(data: try Data(contentsOf: url))
            XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), recorded[file],
                           "\(file) no longer matches the digest in its provenance file — it "
                           + "was edited, or it was recaptured without updating the provenance")
        }
    }

    /// The cheap half of the same guard, kept because it names the failure differently: a
    /// truncated append leaves a line that does not parse at all.
    func testEveryCapturedRolloutLineIsStillOneJSONRecord() throws {
        for line in try codexRollout() {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "a line that no longer parses was edited: \(line.prefix(60))"
            )
        }
    }

    /// The leak this capture shipped with, pinned so it cannot come back. Two of its records
    /// carried this machine's home directory and an inventory of the operator's private
    /// `~/.agents/skills`, and were dropped; codex reads that directory regardless of
    /// `CODEX_HOME`, so the throwaway home the capture ran under did not isolate it.
    func testNoCapturedRolloutNamesAHomeDirectoryOrAPrivateSkill() throws {
        for file in ["rollout-content.captured", "rollout.captured", "turn-aborted.captured",
                     "session-index.captured"] {
            for line in try Self.lines(file, in: "Codex") {
                XCTAssertFalse(line.contains("/Users/"),
                               "\(file) names a home directory: \(line.prefix(60))")
                XCTAssertFalse(line.contains(".agents/skills"),
                               "\(file) lists the operator's skills: \(line.prefix(60))")
            }
        }
    }
}
