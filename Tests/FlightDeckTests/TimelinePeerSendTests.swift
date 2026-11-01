import XCTest
@testable import FleetKit

/// This session's half of a conversation with another one. Before `TimelinePeerSend`, the phone
/// drew the other side's messages as prose and this side's as a `SendMessage` JSON tree or a
/// clipped `flightdeck peer send` command line.
final class TimelinePeerSendTests: XCTestCase {
    private func call(_ tool: String, _ input: [String: Any], id: String = "40#1",
                      truncated: Int = 0) -> TimelineItem {
        let data = try! JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted])
        return TimelineItem(
            id: id, kind: .toolCall, status: .complete,
            body: .init(text: String(decoding: data, as: UTF8.self), summary: "s", tool: tool,
                        callID: "toolu_1", truncatedBytes: truncated),
            at: "2026-10-31T15:00:00Z"
        )
    }

    private func result(_ text: String, isError: Bool = false) -> TimelineItem {
        TimelineItem(id: "41#0", kind: .toolResult, status: .complete,
                     body: .init(text: text, callID: "toolu_1", isError: isError))
    }

    private func rewritten(_ item: TimelineItem, _ result: TimelineItem? = nil) -> TimelineEntry {
        TimelinePeerSend.rewritten(TimelineEntry(item: item, result: result))
    }

    /// Input keys as claude writes them on 2026-10-31.
    func testASendMessageIsTheMessageHeadedByItsRecipient() {
        let entry = rewritten(
            call("SendMessage", ["to": "Publish", "recipient": "Publish", "recipient_kind": "name",
                                 "summary": "Ask Publish", "type": "message", "content": "",
                                 "message": "Please publish **hostd-v0.1.0**.\n\n- 4 files"]),
            result(#"{"success":true,"message":"“Ask Publish” → Publish (another Claude session)"}"#)
        )
        XCTAssertNil(entry.result, "the delivery receipt is not something to read")
        XCTAssertEqual(entry.item.id, "40#1", "same id, so expansion and scroll targets hold")
        XCTAssertEqual(entry.item.kind, .systemNotice)
        XCTAssertEqual(entry.item.at, "2026-10-31T15:00:00Z")
        XCTAssertEqual(entry.item.body.tool, TimelinePeerSend.tool)
        XCTAssertEqual(entry.item.body.sender, "Publish")
        XCTAssertEqual(entry.item.body.text, "Please publish **hostd-v0.1.0**.\n\n- 4 files")
        XCTAssertFalse(entry.item.body.isError)
    }

    /// `SendMessage` reports an unknown recipient as `success: false` in an ordinary result.
    func testAFailedSendIsMarkedAnError() {
        let entry = rewritten(
            call("SendMessage", ["to": "session 532", "message": "hi"]),
            result(#"{"success":false,"message":"No agent named 'session 532' is reachable."}"#)
        )
        XCTAssertTrue(entry.item.body.isError)
    }

    private func received(from name: String, at address: String, id: String) -> TimelineEntry {
        TimelineEntry(item: TimelineItem(
            id: id, kind: .systemNotice, status: .complete,
            body: .init(text: "hello", tool: TimelinePeerSend.receivedTool, sender: name,
                        senderAddress: address)
        ), result: nil)
    }

    /// A reply goes to the socket the message came from. 40 of the 120 `SendMessage` calls in
    /// this project's transcripts on 2026-10-31 did, and each was headed "To another session".
    func testAReplyToASocketIsNamedByTheMessageThatCameFromIt() {
        let socket = "uds:/tmp/cc-socks/37633.sock"
        let entries = TimelinePeerSend.rewritten([
            received(from: "CPU", at: socket, id: "1#0"),
            received(from: "Phone Context", at: socket, id: "2#0"),
            TimelineEntry(item: call("SendMessage", ["to": socket, "message": "On it."]), result: nil),
            TimelineEntry(item: call("SendMessage", ["to": "uds:/tmp/cc-socks/1.sock", "message": "?"],
                                     id: "41#1"), result: nil),
        ])
        XCTAssertEqual(entries[2].item.body.sender, "Phone Context", "the tab's name now")
        XCTAssertEqual(entries[2].item.body.senderAddress, socket)
        XCTAssertEqual(entries[3].item.body.sender, "another session",
                       "a socket nothing in the feed names")
    }

    /// No envelope carries a tab id, so the fleet's list names one.
    func testASendToATabIdIsNamedByTheFleet() {
        let tab = UUID(uuidString: "3F5E8C01-96C1-4B3C-888F-6C389F99E006")!
        let entries = TimelinePeerSend.rewritten(
            [TimelineEntry(item: call("Bash", ["command": "flightdeck peer send \(tab.uuidString.lowercased()) 'Ready.'"]),
                           result: nil)],
            tabTitle: { $0 == tab ? "Design" : nil }
        )
        XCTAssertEqual(entries[0].item.body.sender, "Design")
    }

    func testAnUnreadableAddressIsNamedInWords() {
        XCTAssertEqual(TimelinePeerSend.recipientName("uds:/tmp/cc-socks/37633.sock"), "another session")
        XCTAssertEqual(TimelinePeerSend.recipientName("0d861624-4e02-4f06-b36d-ca6c8558eaa6"),
                       "another session")
        XCTAssertEqual(TimelinePeerSend.recipientName("af92c7283199fbc10"), "agent f92c728")
        XCTAssertEqual(TimelinePeerSend.recipientName("The Plan [4551a9]"), "The Plan [4551a9]")
    }

    /// The shapes this project's sessions actually typed.
    func testAShellPeerSendIsReadAsTwoLiteralWords() {
        let sent = TimelinePeerSend.peerSend(in: """
            cd /Users/me/Projects/flight-deck; flightdeck peer send "Flight Control Planning v2" 'Visual Companion 2 here.

            (c) It'\\''s yes.' 2>&1 | tail -1
            """)
        XCTAssertEqual(sent, .init(recipient: "Flight Control Planning v2",
                                   text: "Visual Companion 2 here.\n\n(c) It's yes."))
        XCTAssertEqual(
            TimelinePeerSend.peerSend(in: #"flightdeck peer send --notify-when-idle Design "say \"hi\"""#),
            .init(recipient: "Design", text: #"say "hi""#)
        )
        XCTAssertEqual(
            TimelinePeerSend.peerSend(
                in: "flightdeck peer send --from 46A43AEA-3E33-412D-8A90-359D594623D9 \"The Plan\" 'Live.'"),
            .init(recipient: "The Plan", text: "Live."),
            "--from names this tab, not the recipient"
        )
        XCTAssertEqual(
            TimelinePeerSend.peerSend(in: "cd /tmp && flightdeck peer send Execute done"),
            .init(recipient: "Execute", text: "done")
        )
    }

    /// Each of these is a command that is more than a send, or a message this cannot know.
    func testACommandThatIsNotJustALiteralSendStaysACommand() {
        for command in [
            #"flightdeck peer send Design "$(cat notes.md)""#,
            "flightdeck peer send Design \"$M\"",
            "M='x'; flightdeck peer send Design \"$M\"",
            "git commit -q && flightdeck peer send Design 'done'",
            "echo flightdeck peer send Design 'done'",
            "flightdeck peer send Design",
            "flightdeck peer send Design 'unterminated",
            "flightdeck peer send A 'one'; flightdeck peer send B 'two'",
        ] {
            XCTAssertNil(TimelinePeerSend.peerSend(in: command), command)
        }
    }

    func testABashSendBecomesAMessageAndOtherBashStaysAToolCall() {
        let send = rewritten(call("Bash", ["command": "flightdeck peer send 'The Plan' 'Ready.'"]),
                             result("sent"))
        XCTAssertEqual(send.item.kind, .systemNotice)
        XCTAssertEqual(send.item.body.sender, "The Plan")
        XCTAssertEqual(send.item.body.text, "Ready.")

        let other = rewritten(call("Bash", ["command": "ls"]), result("a\nb"))
        XCTAssertEqual(other.item.kind, .toolCall)
        XCTAssertEqual(other.result?.id, "41#0")
    }

    /// A body cut at the byte cap is not the whole message; the card says so, a prose row would not.
    func testATruncatedSendStaysAToolCard() {
        let entry = rewritten(call("SendMessage", ["to": "Publish", "message": "hi"], truncated: 9))
        XCTAssertEqual(entry.item.kind, .toolCall)
    }
}
