import FleetKit
import Foundation

/// A conversation with every shape the screen has to survive, at the sizes they really arrive
/// at. **Not three short rows** — that is precisely the fixture that made the first version of
/// this screen look finished, and it was rejected the moment a real session was opened on it.
///
/// Shared by the render harness and by the row/entry tests, so what is asserted and what is
/// looked at are the same conversation.
enum TimelineFixtures {

    /// Ten records: a long prompt, a long answer, a thinking block, a `Bash` call paired with
    /// multi-line output, a `Read` whose 64 KB result was cut, a failing call, a `.prompt`, and
    /// a kind this build has never heard of. The two tool calls are **interleaved** — b2's
    /// result lands before a1's — so anything that pairs by position gets both wrong.
    static var conversation: [TimelineItem] { [
        userTurn, assistantAnswer, thinking,
        bashCall, readCall, bashResult, readResult,
        failingCall, failingResult,
        prompt, unknown,
    ] }

    static let userTurn = TimelineItem(
        id: "10240#0", kind: .userTurn, status: .complete,
        body: .init(text: """
            The timeline screen needs to keep an open session current — right now it shows \
            whatever it fetched when you opened it and never follows along. Check whether \
            there's a hasNewer on the wire before you add a poll.
            """),
        at: "2026-08-23T09:14:02.117Z"
    )

    static let assistantAnswer = TimelineItem(
        id: "10930#0", kind: .assistantText, status: .complete,
        body: .init(text: """
            There is no `hasNewer`, and there shouldn't be. Forwards, `hasMore` is a fact \
            about the instant the file was read, so a screen that stopped polling on it would \
            stop following a live agent the moment the reader caught up.

            So the screen needs two triggers, not one: the fleet event for this session \
            (which catches busy → idle, when a turn's last records land) and a timer while \
            the session is busy (which covers the four minutes in the middle, where \
            emitActivity emits nothing at all).
            """),
        at: "2026-08-23T09:14:19.882Z"
    )

    static let thinking = TimelineItem(
        id: "11884#0", kind: .thinking, status: .complete,
        body: .init(text: """
            The poll interval matters less than the cancellation. If .task doesn't cancel on \
            disappear, every session the user has ever opened keeps polling for the life of \
            the process.
            """),
        at: "2026-08-23T09:14:20.004Z"
    )

    static let bashCall = TimelineItem(
        id: "12401#0", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "command": "rg -n 'hasNewer|hasMore' Sources/FleetKit Sources/FlightDeckMobile",
                  "description": "Look for a forwards-more flag on the wire"
                }
                """,
            summary: "rg -n 'hasNewer|hasMore' Sources/FleetKit Sources/FlightDeckMobile",
            tool: "Bash", callID: "toolu_01BashRipgrep"
        ),
        at: "2026-08-23T09:14:21.500Z"
    )

    static let readCall = TimelineItem(
        id: "12980#0", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "file_path": "/Users/nate/Projects/flight-deck/Sources/FleetKit/TranscriptPager.swift"
                }
                """,
            summary: "Sources/FleetKit/TranscriptPager.swift",
            tool: "Read", callID: "toolu_02ReadPager"
        ),
        at: "2026-08-23T09:14:21.640Z"
    )

    /// Lands AFTER the second call was issued — two tools in flight, answered out of order.
    static let bashResult = TimelineItem(
        id: "13655#0", kind: .toolResult, status: .complete,
        body: .init(
            text: """
                Sources/FleetKit/TimelinePage.swift:37:    public var hasMore: Bool
                Sources/FleetKit/TranscriptPager.swift:112:        hasMore: end < size,
                Sources/FleetKit/TranscriptPager.swift:148:        hasMore: start > 0,
                Sources/FlightDeckMobile/SessionTimelineModel.swift:104:    /// There is no `hasNewer` to gate this on and there must not be: forwards, `hasMore` is a
                Sources/FlightDeckMobile/SessionTimelineModel.swift:201:        guard case .after(let cursor) = anchor, page.hasMore, page.end > cursor else { return }
                """,
            tool: "Bash", callID: "toolu_01BashRipgrep"
        ),
        at: "2026-08-23T09:14:22.310Z"
    )

    /// A whole 64 KB item, cut. `truncatedBytes` is what the Mac dropped at the per-item cap.
    static let readResult = TimelineItem(
        id: "14002#0", kind: .toolResult, status: .complete,
        body: .init(
            text: """
                     1  import Foundation
                     2
                     3  /// Hands out one page of a transcript at a time, forwards or backwards, and never
                     4  /// splits a record across a page boundary.
                     5  ///
                     6  /// The cursor is a byte offset into the file, which is what makes a page stable
                     7  /// across a re-read: an append-only file gives every line exactly one offset for
                     8  /// its whole life. A transcript REPLACED rather than appended to is the one case
                     9  /// that breaks it, and `reset` is how a client is told that happened.
                    10  struct TranscriptPager {
                    11      let url: URL
                    12      let limits: TimelineLimits
                    """,
            tool: "Read", callID: "toolu_02ReadPager", truncatedBytes: 68_412
        ),
        at: "2026-08-23T09:14:22.980Z"
    )

    static let failingCall = TimelineItem(
        id: "14780#0", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "command": "./scripts/test-ios.sh"
                }
                """,
            summary: "./scripts/test-ios.sh", tool: "Bash", callID: "toolu_03BashTests"
        ),
        at: "2026-08-23T09:15:44.120Z"
    )

    static let failingResult = TimelineItem(
        id: "15220#0", kind: .toolResult, status: .complete,
        body: .init(
            text: """
                error: no iPhone simulator device type found. Install an iOS platform:
                       xcodebuild -downloadPlatform iOS
                ** TEST FAILED **
                """,
            tool: "Bash", callID: "toolu_03BashTests", isError: true
        ),
        at: "2026-08-23T09:16:02.470Z"
    )

    static let prompt = TimelineItem(
        id: "15990#0", kind: .prompt, status: .complete,
        body: .init(text: "Allow Bash to run `git push origin screen-s5`?"),
        at: "2026-08-23T09:16:10.000Z"
    )

    /// A kind this build has never heard of, from a newer Mac. It must render as *something*.
    static let unknown = TimelineItem(
        id: "16410#0", kind: .unknown, status: .unknown,
        body: .init(text: "{\"type\":\"checkpoint\",\"label\":\"pre-merge\",\"files\":41}"),
        at: "2026-08-23T09:16:31.900Z"
    )

    /// A call whose result has not arrived — the tool is still running, or its output fell the
    /// other side of a page boundary.
    static let unansweredCall = TimelineItem(
        id: "16880#0", kind: .toolCall, status: .complete,
        body: .init(
            text: "{\n  \"command\": \"./scripts/build.sh\"\n}",
            summary: "./scripts/build.sh", tool: "Bash", callID: "toolu_04BashBuild"
        ),
        at: "2026-08-23T09:16:40.000Z"
    )

    /// A tool call the Mac sent no summary for, whose pretty-printed body opens on a bare `{`.
    static let callWithoutSummary = TimelineItem(
        id: "17220#0", kind: .toolCall, status: .complete,
        body: .init(
            text: "{\n  \"pattern\": \"TimelineFeed\",\n  \"path\": \"Sources\"\n}",
            tool: "Grep", callID: "toolu_05Grep"
        ),
        at: "2026-08-23T09:16:50.000Z"
    )

    // MARK: JSON bodies — real records, for the tree

    /// A real `AskUserQuestion` input, pretty-printed the way `ClaudeTimelineMapper.pretty`
    /// sends it (`.sortedKeys`). Taken from
    /// `~/.claude/projects/-Users-nate/8261151b-…jsonl`.
    ///
    /// **`summary` is nil, and that is not laziness in the fixture.** `ToolInputSummary`'s
    /// preview table looks for `command`, `file_path`, `path`, `pattern`, `query`, `url`,
    /// `prompt` or `description` at the TOP level, and this input has one key: `questions`. So
    /// the Mac sends no preview, `TimelineStyle.commandLine` falls through to the first line of
    /// the body that is not a bare delimiter — `"questions": [` — and the row reads as JSON
    /// punctuation. This is the item that prompted the tree.
    static let askUserQuestionCall = TimelineItem(
        id: "31402#1", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "questions": [
                    {
                      "header": "Lifecycle",
                      "multiSelect": false,
                      "options": [
                        {
                          "description": "TranscriptReady fires → assemble context → run workflows → produce drafts/reminders/notes. Single trigger, single code path. Everything you described explicitly, nothing more. Fastest to something you actually use daily.",
                          "label": "Post-meeting only (Recommended)"
                        },
                        {
                          "description": "Adds a scheduler that watches the calendar and produces a pre-meeting brief (who they are, recent mail/Slack, last meeting's open action items) ahead of each meeting. Doubles the trigger surface — needs a scheduler, not just an event listener — but pre-brief is where Contio claims the real value is.",
                          "label": "Pre + post lifecycle"
                        },
                        {
                          "description": "Post-meeting workflows plus non-meeting triggers — inbound email, Slack mention, a reminder coming due. Makes it a general personal automation engine that happens to be meeting-aware, rather than a meeting system.",
                          "label": "Post-meeting + ambient"
                        }
                      ],
                      "question": "Which part of the meeting lifecycle should this cover?"
                    }
                  ]
                }
                """,
            tool: "AskUserQuestion", callID: "toolu_01AskLifecycle"
        ),
        at: "2026-08-22T11:04:18.220Z"
    )

    /// The same input as it arrives when the Mac cut it: mid-`description`, mid-string,
    /// mid-word. **This is the case the fallback exists for** — it is not parseable JSON and
    /// never will be, so the block must show the text and say what was dropped.
    static let askUserQuestionTruncated = TimelineItem(
        id: "31402#2", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "questions": [
                    {
                      "header": "Lifecycle",
                      "multiSelect": false,
                      "options": [
                        {
                          "description": "TranscriptReady fires → assemble context → run workflows → produce drafts/reminders/notes. Single trigger, single code path. Everything you described explicitly, nothing more. Fastest to something you actually use daily.",
                          "label": "Post-meeting only (Recommended)"
                        },
                        {
                          "description": "Adds a scheduler that watches the calendar and produces a pre-meeting brief (who they are, recent mail/Slack, last meeting's open action items) ahead of each meeting. Doubles the trigger sur
                """,
            tool: "AskUserQuestion", callID: "toolu_02AskCut", truncatedBytes: 573
        ),
        at: "2026-08-22T11:06:02.910Z"
    )

    /// An array of objects, nested five deep, with real integers and an array of numbers in
    /// it. A real `mcp__claude-in-chrome__browser_batch` call — an MCP tool, so its name
    /// arrives namespaced and its input looks nothing like a `Bash` command line.
    static let browserBatchCall = TimelineItem(
        id: "33110#0", kind: .toolCall, status: .complete,
        body: .init(
            text: """
                {
                  "actions": [
                    {
                      "input": {
                        "action": "left_click",
                        "coordinate": [
                          600,
                          114
                        ],
                        "tabId": 576557143
                      },
                      "name": "computer"
                    },
                    {
                      "input": {
                        "action": "type",
                        "tabId": 576557143,
                        "text": "agreement"
                      },
                      "name": "computer"
                    },
                    {
                      "input": {
                        "action": "wait",
                        "duration": 6,
                        "tabId": 576557143
                      },
                      "name": "computer"
                    },
                    {
                      "input": {
                        "action": "screenshot",
                        "tabId": 576557143
                      },
                      "name": "computer"
                    }
                  ]
                }
                """,
            tool: "mcp__claude-in-chrome__browser_batch",
            callID: "toolu_01F4eQkYZ79S4T6TRHuejgo5"
        ),
        at: "2026-08-22T11:07:41.030Z"
    )

    /// A tool RESULT that is JSON — the shape an async `Agent` dispatch answers with. Results
    /// are usually `ls` output or a stack trace; this is the minority that is a document, and
    /// it is the reason the tree is offered on the output panel too and not only on the input.
    static let agentLaunchResult = TimelineItem(
        id: "33940#0", kind: .toolResult, status: .complete,
        body: .init(
            text: """
                {
                  "agentId": "aacde7ffb946715f8",
                  "canReadOutputFile": true,
                  "description": "Contio.ai public web presence",
                  "isAsync": true,
                  "outputFile": "/private/tmp/claude-501/-Users-nate/8261151b-4ced-40a8-9082-5dc558ee55e2/tasks/aacde7ffb946715f8.output",
                  "resolvedModel": "claude-opus-5[1m]",
                  "status": "async_launched"
                }
                """,
            tool: "Agent", callID: "toolu_014eALeS8w1k7jd7atJQnHJB"
        ),
        at: "2026-08-22T11:07:41.660Z"
    )

    static func session(
        title: String = "screen-s5 — session timeline", agent: String = "claude",
        activity: String? = "busy", waitingFor: String? = nil, subagentCount: Int = 2
    ) -> WireSession {
        WireSession(
            id: UUID(), title: title, agent: agent,
            activity: activity, waitingFor: waitingFor, subagentCount: subagentCount
        )
    }
}
