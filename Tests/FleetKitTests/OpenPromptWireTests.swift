import XCTest
import FleetKit

/// `WireOpenPrompt` — the dialog's words, sent by the Mac for an agent whose transcript cannot
/// carry them (gemini). What the wire must keep true: a claude tab's bytes do not change, an
/// older peer's frames still decode, a newer peer's dialog cannot take a snapshot down, and the
/// fold overwrites the words exactly as it overwrites the call id beside them.
final class OpenPromptWireTests: XCTestCase {
    private let permission = OpenPrompt.permission(
        callID: "call_9", tool: "write_to_file", summary: "Create a.txt"
    )
    private let question = OpenPrompt.question(callID: "q_1", [
        PromptQuestion(header: "Pick", question: "Which?",
                       options: [.init(label: "Rust", detail: "Fast."), .init(label: "Go")],
                       multiSelect: true)
    ])

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testBothKindsRoundTripToTheSameDialog() throws {
        for open in [permission, question] {
            XCTAssertEqual(try roundTrip(WireOpenPrompt(open)).prompt, open)
        }
    }

    func testASessionCarriesItsOfferedDialogInTheSnapshotAndTheEvent() throws {
        let offer = WireOpenPrompt(permission)
        let session = WireSession(id: UUID(), title: "t", agent: "gemini", activity: "waiting",
                                  openPromptCall: .call("call_9"), openPrompt: offer)
        XCTAssertEqual(try roundTrip(session).openPrompt, offer)
        let event = FleetEvent.activityChanged(
            id: session.id, activity: "waiting", waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .call("call_9"), openPrompt: offer
        )
        XCTAssertEqual(try roundTrip(event), event)
    }

    /// **A claude tab's bytes are the ones an older phone has always received.** The field is
    /// absent — not null — whenever nothing is offered, which is every tab of every agent the
    /// phone can derive a card for.
    func testNothingOfferedWritesNoKey() throws {
        let session = WireSession(id: UUID(), title: "t", agent: "claude", activity: "waiting",
                                  openPromptCall: .call("toolu_A"))
        let event = FleetEvent.activityChanged(
            id: session.id, activity: "waiting", waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .call("toolu_A")
        )
        for data in [try JSONEncoder().encode(session), try JSONEncoder().encode(event)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["openPrompt"], "an absent key, not a null one")
        }
    }

    /// An older Mac never sends the key; a newer phone reads that as nothing offered and keeps
    /// deriving cards itself.
    func testAnOlderPeersFramesDecodeWithNothingOffered() throws {
        let id = UUID().uuidString
        let session = Data(#"""
        {"id":"\#(id)","title":"t","agent":"claude","activity":"waiting","subagentCount":0,"isUnread":false}
        """#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WireSession.self, from: session).openPrompt)
        let event = Data(#"{"t":"session.activity","id":"\#(id)","activity":"waiting","subagentCount":0}"#.utf8)
        guard case .activityChanged(_, _, _, _, _, _, _, _, _, let offer) =
            try JSONDecoder().decode(FleetEvent.self, from: event)
        else { return XCTFail("expected .activityChanged") }
        XCTAssertNil(offer)
    }

    /// **A dialog this build cannot read costs one card, never the snapshot.** A shape a newer
    /// Mac grows — or a kind it adds — must decode the session around it.
    func testAnUnreadableOfferDropsOnlyTheCard() throws {
        let id = UUID().uuidString
        let head = #"{"id":"\#(id)","title":"t","agent":"gemini","activity":"waiting","subagentCount":0,"isUnread":false,"openPromptCall":"call_9","#
        let malformed = Data((head + #""openPrompt":{"kind":42}}"#).utf8)
        let decoded = try JSONDecoder().decode(WireSession.self, from: malformed)
        XCTAssertEqual(decoded.openPromptCall, .call("call_9"), "the rest of the session survives")
        XCTAssertNil(decoded.openPrompt)

        let newer = Data((head + #""openPrompt":{"callID":"call_9","kind":"survey","extra":1}}"#).utf8)
        let offer = try XCTUnwrap(try JSONDecoder().decode(WireSession.self, from: newer).openPrompt)
        XCTAssertNil(offer.prompt, "a kind this build cannot draw is no card")

        let event = Data(#"{"t":"session.activity","id":"\#(id)","activity":"waiting","subagentCount":0,"openPromptCall":"call_9","openPrompt":[]}"#.utf8)
        guard case .activityChanged(_, _, _, _, _, let call, _, _, _, let dropped) =
            try JSONDecoder().decode(FleetEvent.self, from: event)
        else { return XCTFail("the event must still decode") }
        XCTAssertEqual(call, .call("call_9"))
        XCTAssertNil(dropped)
    }

    func testAnEmptyQuestionIsNoCard() {
        XCTAssertNil(WireOpenPrompt(callID: "q", kind: "question", questions: []).prompt)
        XCTAssertNil(WireOpenPrompt(callID: "q", kind: "question").prompt)
    }

    /// **The fold overwrites the words, exactly as it overwrites the id.** A supersede replaces
    /// them; a closed dialog clears them. A fold that kept the last words when an event stopped
    /// carrying them would leave a dead card drawable.
    func testTheFoldReplacesAndClearsTheOfferedDialog() {
        let id = UUID()
        let project = UUID()
        var snapshot = FleetSnapshot(projects: [WireProject(
            id: project, name: "p", path: "/p", isCollapsed: false,
            sessions: [WireSession(id: id, title: "t", agent: "gemini")]
        )])
        let next = OpenPrompt.permission(callID: "call_10", tool: "run_command", summary: "ls")
        for (call, open) in [("call_9", permission), ("call_10", next)] {
            snapshot = snapshot.applying([.activityChanged(
                id: id, activity: "waiting", waitingFor: nil, subagentCount: 0,
                hasBackgroundWork: false, openPromptCall: .call(call), openPrompt: WireOpenPrompt(open)
            )])
            XCTAssertEqual(snapshot.projects[0].sessions[0].openPrompt?.prompt, open)
        }
        snapshot = snapshot.applying([.activityChanged(
            id: id, activity: "busy", waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .noPrompt
        )])
        XCTAssertNil(snapshot.projects[0].sessions[0].openPrompt)
    }
}
