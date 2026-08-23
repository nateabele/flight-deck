import FleetKit
import XCTest
@testable import FlightDeck

/// Codex's half of the one vocabulary (spec §6), mapped from the ROLLOUT rather than from
/// `item/started` / `item/completed`.
///
/// Spec §6 names the app-server notifications; that path was deleted in b76a07b because its
/// notifications only reach the connection that made the change, and Flight Deck's turns run
/// in a separate `codex resume` process. The rollout is written by whoever drives the turn.
/// See the plan's findings §1.
///
/// The subtle rule here is which record FAMILY each row comes from. Prose comes from
/// `event_msg` and tool calls from `response_item`, and taking both families for either would
/// double every reply or paste the assembled prompt in as a user turn. Four tests below guard
/// exactly that, with named mutations in the task report.
///
/// The other standing rule, shared with `ClaudeTimelineMapperTests`: **the unit under test is
/// every field of every item emitted**, not the function. A test that checks `kind` and `text`
/// passes with `tool` and `callID` crossed, so each record shape has one test that pins the
/// fields it MUST populate and the fields it must leave alone, at values no two of which are
/// interchangeable.
final class CodexTimelineMapperTests: XCTestCase {
    private func items(_ line: String, at offset: Int = 200) -> [TimelineItem] {
        CodexTimelineMapper.items(inRolloutLine: line, at: offset)
    }

    func testAUserMessageEventIsAUserTurnAndNothingMore() {
        let items = items("""
            {"timestamp":"2026-08-19T16:47:57.520Z","type":"event_msg","payload":\
            {"type":"user_message","message":"Reply with exactly the word: ok",\
            "images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.userTurn])
        XCTAssertEqual(items[0].id, "200#0")
        XCTAssertEqual(items[0].at, "2026-08-19T16:47:57.520Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.text, "Reply with exactly the word: ok")
        // A typed prompt is prose: a `summary` would claim its text is unfit for a row, and a
        // `tool`/`callID` would claim it is part of a tool exchange. Both are lies about it.
        XCTAssertNil(items[0].body.summary)
        XCTAssertNil(items[0].body.tool)
        XCTAssertNil(items[0].body.callID)
        XCTAssertFalse(items[0].body.isError)
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// Distinct from the user turn above only by `kind`, which is exactly why both pin every
    /// field: one `case` arm returning the other's kind relabels the user's words as the
    /// agent's, and a test that only checked `text` would pass through it.
    func testAnAgentMessageEventIsAssistantTextAndNothingMore() {
        let items = items("""
            {"timestamp":"2026-08-19T16:47:59.159Z","type":"event_msg","payload":\
            {"type":"agent_message","message":"ok","phase":"final_answer","memory_citation":null}}
            """, at: 4242)
        XCTAssertEqual(items.map(\.kind), [.assistantText])
        XCTAssertEqual(items[0].id, "4242#0")
        XCTAssertEqual(items[0].at, "2026-08-19T16:47:59.159Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.text, "ok")
        XCTAssertNil(items[0].body.summary)
        XCTAssertNil(items[0].body.tool)
        XCTAssertNil(items[0].body.callID)
        XCTAssertFalse(items[0].body.isError)
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// **The prose family is `event_msg`, and only `event_msg`.** Codex writes the same reply
    /// twice — once as an event and once as a `response_item` — so mapping both puts every
    /// assistant message on screen twice.
    func testAResponseItemMessageIsNotMappedAsProse() {
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:06.003Z","type":"response_item","payload":\
            {"type":"message","role":"assistant","content":[{"type":"output_text",\
            "text":"I'll look for the project's tooling first."}],"phase":"commentary"}}
            """).isEmpty, "agent_message already carried this; mapping both duplicates it")
    }

    /// A `response_item` / `message` with `role:"user"` is codex's *prompt assembly* — the
    /// skills catalogue, the plugin catalogue, the environment context — tens of kilobytes of
    /// it, on every single turn. It is not something the user said. The `role:"developer"`
    /// half of the same blob is no different.
    func testTheInstructionBlobIsNotAUserTurn() {
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:00.429Z","type":"response_item","payload":\
            {"type":"message","role":"user","content":[{"type":"input_text",\
            "text":"<recommended_plugins>\\nHere is a list of plugins…"}]}}
            """).isEmpty)
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:00.430Z","type":"response_item","payload":\
            {"type":"message","role":"developer","content":[{"type":"input_text",\
            "text":"<skills_instructions>\\n## Skills\\nA skill is a set of instructions…"}]}}
            """).isEmpty)
    }

    func testAgentReasoningIsThinkingAndNothingMore() {
        let items = items("""
            {"timestamp":"2025-10-14T16:38:51.503Z","type":"event_msg","payload":\
            {"type":"agent_reasoning","text":"**Verifying command execution permissions**"}}
            """, at: 909)
        XCTAssertEqual(items.map(\.kind), [.thinking])
        XCTAssertEqual(items[0].id, "909#0")
        XCTAssertEqual(items[0].at, "2025-10-14T16:38:51.503Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.text, "**Verifying command execution permissions**")
        XCTAssertNil(items[0].body.summary)
        XCTAssertNil(items[0].body.tool)
        XCTAssertNil(items[0].body.callID)
        XCTAssertFalse(items[0].body.isError)
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// **`response_item` / `reasoning` is `agent_reasoning` again, with ciphertext attached.**
    /// Its `summary` repeats the event's text word for word — 1268 `agent_reasoning` records
    /// and 1268 non-empty `reasoning` summaries in a survey of 494 rollouts on the build
    /// machine — and it carries one to two kilobytes of `encrypted_content` per record.
    /// Mapping it would double every thought and put the blob on the wire.
    ///
    /// Written with a NON-empty summary on purpose: 1268 of the 1339 in the survey have one,
    /// so "there is nothing renderable in it" is not why this is skipped, and a mapper that
    /// only skipped the empty ones would pass a test written the other way.
    func testEncryptedReasoningIsNeverCarriedEvenWhenItHasASummary() {
        XCTAssertTrue(items("""
            {"timestamp":"2025-10-12T19:43:28.455Z","type":"response_item","payload":\
            {"type":"reasoning","summary":[{"type":"summary_text",\
            "text":"**Verifying command execution permissions**"}],"content":null,\
            "encrypted_content":"gAAAAABo7ATgVjzkQgWQexM3GBGil"}}
            """).isEmpty, "agent_reasoning already carried this text, without the ciphertext")
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:05.224Z","type":"response_item","payload":\
            {"type":"reasoning","summary":[],"encrypted_content":"gAAAAABqKCelFjUA_JsDN0w0"}}
            """).isEmpty)
    }

    /// `arguments` is a JSON **string**, not an object — the one shape difference from
    /// claude's `input` that a shared mapper has to know about.
    func testAFunctionCallParsesItsArgumentsString() {
        let items = items("""
            {"timestamp":"2026-06-09T14:48:08.898Z","type":"response_item","payload":\
            {"type":"function_call","name":"qartez_grep","namespace":"mcp__qartez",\
            "arguments":"{\\"query\\":\\"conversation index\\",\\"limit\\":50,\
            \\"format\\":\\"detailed\\"}","call_id":"call_AejD3fggPArahE3Bb78ykVbb"}}
            """, at: 512)
        XCTAssertEqual(items.map(\.kind), [.toolCall])
        XCTAssertEqual(items[0].id, "512#0")
        XCTAssertEqual(items[0].at, "2026-06-09T14:48:08.898Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.tool, "qartez_grep")
        XCTAssertEqual(items[0].body.callID, "call_AejD3fggPArahE3Bb78ykVbb")
        XCTAssertEqual(items[0].body.text, """
            {
              "format" : "detailed",
              "limit" : 50,
              "query" : "conversation index"
            }
            """, "the arguments string is parsed and pretty-printed, not passed through as "
            + "one escaped line")
        XCTAssertEqual(items[0].body.summary, "conversation index",
                       "the preview comes from the shared key table, same as claude's")
        XCTAssertFalse(items[0].body.isError, "a call has not failed; only a result can")
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// The `shell` call is what 957 of the corpus's `function_call` records are, and its
    /// `command` is an array — so the preview key table finds no String under `command` and
    /// falls through to the next key it does find. Pinned because "the preview is nil" is a
    /// legitimate answer here rather than a failure: the row still renders from `tool`.
    func testAShellFunctionCallPrettyPrintsAnArrayCommandAndHasNoPreview() {
        let items = items("""
            {"timestamp":"2025-10-12T21:05:02.157Z","type":"response_item","payload":\
            {"type":"function_call","name":"shell",\
            "arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"cat docs/SPEC.md\\"],\
            \\"timeout_ms\\":120000}","call_id":"call_MHUAYO4a9X2n6BkHU3qo6Zlz"}}
            """)
        XCTAssertEqual(items[0].body.tool, "shell")
        XCTAssertNil(items[0].body.summary, "command is an array here, not a String")
        XCTAssertTrue(items[0].body.text.contains("\"cat docs\\/SPEC.md\""),
                      "the detail screen still gets the whole input")
    }

    /// Not every `arguments` is JSON. One that is not must render as itself rather than as an
    /// empty body.
    func testAFunctionCallWithNonJSONArgumentsKeepsThemVerbatim() {
        let items = items("""
            {"type":"response_item","payload":{"type":"function_call","name":"shell",\
            "arguments":"echo hi","call_id":"call_1"}}
            """)
        XCTAssertEqual(items[0].body.text, "echo hi")
        XCTAssertEqual(items[0].body.summary, "echo hi")
        XCTAssertEqual(items[0].body.tool, "shell")
        XCTAssertEqual(items[0].body.callID, "call_1")
    }

    func testAFunctionCallOutputIsAToolResultThatNamesItsCallButNotItsTool() {
        let items = items("""
            {"timestamp":"2026-06-09T14:48:09.100Z","type":"response_item","payload":\
            {"type":"function_call_output","call_id":"call_AejD3fggPArahE3Bb78ykVbb",\
            "output":"Wall time: 0.02s\\nOutput:\\nhi"}}
            """, at: 1024)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].id, "1024#0")
        XCTAssertEqual(items[0].at, "2026-06-09T14:48:09.100Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.text, "Wall time: 0.02s\nOutput:\nhi")
        XCTAssertEqual(items[0].body.callID, "call_AejD3fggPArahE3Bb78ykVbb")
        // Nothing in an output record names the tool it answers, so `tool` must stay nil
        // rather than be guessed at; `summary` stays nil because a result is prose and its
        // first line is the right row preview.
        XCTAssertNil(items[0].body.tool)
        XCTAssertNil(items[0].body.summary)
        XCTAssertFalse(items[0].body.isError,
                       "no record in this family says a result failed; see the task report")
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// `apply_patch` arrives as a `custom_tool_call` whose `input` is a patch, and codex-cli
    /// 0.148.0's unified `exec` tool puts a JavaScript program in the same field. Neither is
    /// JSON. A mapper that assumed JSON here would render every edit as an empty row.
    func testACustomToolCallCarriesItsInputVerbatim() {
        let items = items("""
            {"timestamp":"2026-06-09T15:46:39.125Z","type":"response_item","payload":\
            {"type":"custom_tool_call","status":"completed","call_id":"call_EDyk",\
            "name":"apply_patch",\
            "input":"*** Begin Patch\\n*** Add File: docs/x.md\\n+hello\\n"}}
            """, at: 2048)
        XCTAssertEqual(items.map(\.kind), [.toolCall])
        XCTAssertEqual(items[0].id, "2048#0")
        XCTAssertEqual(items[0].at, "2026-06-09T15:46:39.125Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.tool, "apply_patch")
        XCTAssertEqual(items[0].body.callID, "call_EDyk")
        XCTAssertEqual(items[0].body.text, "*** Begin Patch\n*** Add File: docs/x.md\n+hello\n")
        XCTAssertEqual(items[0].body.summary, "*** Begin Patch",
                       "the first line is the preview when the input is not JSON")
        XCTAssertFalse(items[0].body.isError)
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    func testACustomToolCallOutputIsAToolResult() {
        let items = items("""
            {"timestamp":"2026-06-09T15:46:40.001Z","type":"response_item","payload":\
            {"type":"custom_tool_call_output","call_id":"call_EDyk",\
            "output":"Exit code: 0\\nSuccess."}}
            """, at: 4096)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].id, "4096#0")
        XCTAssertEqual(items[0].at, "2026-06-09T15:46:40.001Z")
        XCTAssertEqual(items[0].status, .complete)
        XCTAssertEqual(items[0].body.text, "Exit code: 0\nSuccess.")
        XCTAssertEqual(items[0].body.callID, "call_EDyk")
        XCTAssertNil(items[0].body.tool)
        XCTAssertNil(items[0].body.summary)
        XCTAssertFalse(items[0].body.isError)
        XCTAssertEqual(items[0].body.truncatedBytes, 0)
    }

    /// **`output` is a String on codex-cli 0.46.0 and a block array on 0.148.0**, and both are
    /// in the fixtures. This is the shape the mapping table did not have, found by capturing
    /// rather than by assuming: reading only the String renders every tool result in a current
    /// rollout as an empty row — the whole tool half of the timeline, silently blank.
    ///
    /// The blocks are fragments of one output stream, not discrete blocks like claude's, so
    /// they are joined with nothing. A `"\n"` separator — the right answer in
    /// `ClaudeTimelineMapper` — would insert a blank line the terminal never showed, because
    /// the header fragment already ends with its own newline.
    func testAToolResultWithBlockOutputIsJoinedWithoutASeparator() {
        let items = items("""
            {"timestamp":"2026-08-23T02:24:49.900Z","type":"response_item","payload":\
            {"type":"custom_tool_call_output","id":"ctco_01a02c6f","call_id":"call_x14x",\
            "output":[{"type":"input_text",\
            "text":"Script completed\\nWall time 0.1 seconds\\nOutput:\\n"},\
            {"type":"input_text","text":"hi\\n"}]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].body.text, "Script completed\nWall time 0.1 seconds\nOutput:\nhi\n")
        XCTAssertEqual(items[0].body.callID, "call_x14x")
    }

    func testAnOutputThatIsNeitherAStringNorBlocksIsEmptyRatherThanACrash() {
        XCTAssertEqual(items("""
            {"type":"response_item","payload":{"type":"function_call_output",\
            "call_id":"call_2","output":{"exit_code":0}}}
            """)[0].body.text, "")
        XCTAssertEqual(items("""
            {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c"}}
            """)[0].body.text, "")
    }

    /// Bookkeeping, duplicates, and records with no row. `mcp_tool_call_end` in particular
    /// carries a full tool result and is skipped anyway: the matching `*_output` record
    /// already carried it, and mapping both would double every MCP call's output.
    func testBookkeepingAndDuplicateRecordsEmitNothing() {
        for line in [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"ok"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied"}}"#,
            #"{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"c","result":{"Ok":{}}}}"#,
            #"{"type":"event_msg","payload":{"type":"patch_apply_end","call_id":"c","success":true}}"#,
            #"{"type":"event_msg","payload":{"type":"web_search_end","call_id":"c","query":"x"}}"#,
            #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed"}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_call","call_id":"c"}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_output","call_id":"c"}}"#,
            #"{"type":"session_meta","payload":{"id":"x"}}"#,
            #"{"type":"turn_context","payload":{}}"#,
            #"{"type":"world_state","payload":{"full":true}}"#,
            #"{"type":"compacted","payload":{"message":"x"}}"#,
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(40)) should map to nothing")
        }
    }

    /// A malformed line maps to nothing rather than crashing — the same defensive posture
    /// `CodexEventMapper.events(inRolloutLine:)` takes over this same file, and for the same
    /// reason: this parses bytes another process is appending to as we read.
    func testAMalformedLineEmitsNothingRatherThanACrash() {
        for line in [
            "not json at all",
            "",
            #"["not","an","object"]"#,
            #"{"type":"event_msg"}"#,
            #"{"type":"event_msg","payload":"not an object"}"#,
            #"{"type":"event_msg","payload":{"message":"no payload type"}}"#,
            #"{"payload":{"type":"user_message","message":"no record type"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":""}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":[]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_reasoning"}}"#,
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(40)) should map to nothing")
        }
    }

    /// `at` is the record's own timestamp verbatim and nothing else. A record without one is
    /// undated rather than dated now — this mapper never calls `Date()`, so a re-fetch of the
    /// same page cannot come back with a different time on the same row.
    func testARecordWithNoTimestampIsUndated() {
        XCTAssertNil(items("""
            {"type":"event_msg","payload":{"type":"agent_message","message":"undated"}}
            """)[0].at)
    }

    /// The plan's findings §2: a survey of 494 rollouts on the build machine found zero
    /// `*delta*` records. Codex does not stream through this path, so nothing here is ever
    /// `.streaming`. `.streaming` exists in the vocabulary for a future route; if something
    /// starts emitting it, this fails and the UI has to be built for it.
    func testEveryMappedItemIsComplete() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"go"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"ok"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"**Weighing**"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}","call_id":"c"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"hi"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"p","call_id":"d"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"d","output":"ok"}}"#,
        ]
        let mapped = lines.flatMap { items($0) }
        XCTAssertEqual(mapped.count, lines.count, "every shape above emits exactly one row")
        XCTAssertEqual(mapped.map(\.status), Array(repeating: .complete, count: lines.count))
    }
}
