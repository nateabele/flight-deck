import XCTest
import FleetKit

final class FleetWireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testASnapshotSurvivesAnEncodeDecodeRoundTrip() throws {
        let snapshot = FleetSnapshot(projects: [
            WireProject(
                id: UUID(), name: "flight-deck", path: "/w/flight-deck", isCollapsed: false,
                sessions: [
                    WireSession(
                        id: UUID(), title: "mobile", agent: "claude",
                        activity: "busy", waitingFor: nil, subagentCount: 2, isUnread: false
                    )
                ]
            )
        ])
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    /// A session with no agent process is NOT idle — it is statusless, and the two render
    /// differently (nothing versus a dot). `nil` has to survive the wire or every dead tab
    /// on the phone looks alive.
    func testAStatuslessSessionStaysStatuslessAcrossTheWire() throws {
        let session = WireSession(
            id: UUID(), title: "dormant", agent: "codex",
            activity: nil, waitingFor: nil, subagentCount: 0, isUnread: true
        )
        XCTAssertNil(try roundTrip(session).activity)
    }

    /// The Mac may be running a newer Flight Deck than the phone. An agent the client has
    /// never heard of must arrive as an unrenderable-but-present string rather than
    /// throwing and taking the whole snapshot down with it — which is what a client-side
    /// `AgentID` enum would have done.
    func testAnUnknownAgentDecodesRatherThanThrowing() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"t","agent":"gemini",
         "subagentCount":0,"isUnread":false}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WireSession.self, from: json).agent, "gemini")
    }

    /// An older Mac sends no such key. The phone must decode that as `false`, not throw — a
    /// throw here takes the entire snapshot down, not one field.
    func testWireSessionDecodesWithoutBackgroundWorkKey() throws {
        let json = """
        {"id":"A4C9067B-9CAF-43CB-8B75-88A145249058","title":"frontend-state",
         "agent":"claude","activity":"idle","subagentCount":0,"isUnread":false}
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(WireSession.self, from: json)
        XCTAssertFalse(session.hasBackgroundWork)
    }

    /// The wire version was deliberately not bumped for the `hasBackgroundWork` split, so an
    /// older Mac can still send the pre-decomposition `"shell"` string as `activity`. That
    /// must decode as exactly what a newer Mac would have sent for the same fact —
    /// `activity: "idle"` plus the flag — rather than reaching `SessionStatusGlyph`'s
    /// "Unrecognized status" fallback.
    func testWireSessionDecodesLegacyShellAsIdlePlusBackgroundWork() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","agent":"claude","activity":"shell",
         "subagentCount":0,"isUnread":false}
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(WireSession.self, from: json)
        XCTAssertEqual(session.activity, "idle")
        XCTAssertTrue(session.hasBackgroundWork)
    }

    /// An older Mac's snapshot has no such key, because the preference it names did not
    /// exist yet. The field is additive; its absence must mean off, never a decode failure —
    /// off is the safe direction for a control that drives a terminal blind.
    func testWireSessionDecodesWithoutTheAllowsBlockedAbortKeyAsOff() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-0000000000AA","title":"t","agent":"claude",
         "subagentCount":0,"isUnread":false,"hasBackgroundWork":false}
        """#
        let session = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
        XCTAssertFalse(session.allowsBlockedAbort,
                       "the field is additive; its absence must mean off, never a decode failure")
    }

    func testActivityChangedRoundTripsBackgroundWork() throws {
        let event = FleetEvent.activityChanged(
            id: UUID(), activity: "idle", waitingFor: nil,
            subagentCount: 0, hasBackgroundWork: true
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(FleetEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    /// The other half of the compatibility contract: an older Mac's *incremental* frame, not
    /// just its snapshot. `testWireSessionDecodesWithoutBackgroundWorkKey` above proves
    /// `WireSession` tolerates the missing key; this proves the `activityChanged` decode arm
    /// in `WireCoding.swift` does too — it has its own `decodeIfPresent(...) ?? false`, wired
    /// up separately, and nothing exercised it.
    /// **The three states of `openPromptCall`, over the wire, in one test.** The distinction is
    /// carried by the *presence* of the key, so a decoder reaching for `decodeIfPresent` would
    /// fold the first two together — and a phone would then stop drawing cards against a Mac
    /// that has no opinion about dialogs at all.
    func testOpenPromptIdentityKeepsAnAbsentKeyAndAnExplicitNullApart() throws {
        let id = UUID().uuidString
        let tail = #""agent":"claude","activity":"waiting","subagentCount":0,"isUnread":false"#
        let cases: [(String, OpenPromptIdentity)] = [
            ("", .unreported),
            (#","openPromptCall":null"#, .noPrompt),
            (#","openPromptCall":"toolu_A""#, .call("toolu_A")),
        ]
        for (fragment, expected) in cases {
            let json = Data(#"{"id":"\#(id)","title":"t",\#(tail)\#(fragment)}"#.utf8)
            XCTAssertEqual(
                try JSONDecoder().decode(WireSession.self, from: json).openPromptCall,
                expected, "decoding \(fragment.isEmpty ? "an absent key" : fragment)"
            )
        }
    }

    /// Each of the three round-trips as itself, in the snapshot and in the incremental frame
    /// alike. That is what makes `.unreported` safe to hold on a client rather than something
    /// that has to be normalized away the moment it arrives.
    func testOpenPromptIdentityRoundTripsInEveryState() throws {
        for identity in [OpenPromptIdentity.unreported, .noPrompt, .call("toolu_B")] {
            let session = WireSession(id: UUID(), title: "t", agent: "claude",
                                      activity: "waiting", openPromptCall: identity)
            XCTAssertEqual(try roundTrip(session).openPromptCall, identity)
            let event = FleetEvent.activityChanged(
                id: session.id, activity: "waiting", waitingFor: nil, subagentCount: 0,
                hasBackgroundWork: false, openPromptCall: identity
            )
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        }
    }

    /// The incremental frame's own decode arm, wired up separately from `WireSession`'s and so
    /// able to rot on its own — the gap `testActivityChangedDecodesWithoutBackgroundWorkKey`
    /// below was written to close for the flag beside it.
    func testActivityChangedDecodesWithoutTheOpenPromptKeyAsUnreported() throws {
        let id = UUID().uuidString
        let json = Data(#"""
        {"t":"session.activity","id":"\#(id)","activity":"waiting","subagentCount":0}
        """#.utf8)
        guard case .activityChanged(_, _, _, _, _, let call) =
            try JSONDecoder().decode(FleetEvent.self, from: json)
        else { return XCTFail("expected .activityChanged") }
        XCTAssertEqual(call, .unreported)
    }

    func testActivityChangedDecodesWithoutBackgroundWorkKey() throws {
        let id = UUID()
        let json = Data("""
        {"t":"session.activity","id":"\(id.uuidString)","activity":"idle","subagentCount":0}
        """.utf8)
        let event = try JSONDecoder().decode(FleetEvent.self, from: json)
        guard case .activityChanged(_, _, _, _, let hasBackgroundWork, _) = event else {
            return XCTFail("expected .activityChanged, got \(event)")
        }
        XCTAssertFalse(hasBackgroundWork)
    }

    // MARK: Search's wire types

    func testWireConversationSurvivesARoundTrip() throws {
        let conversation = WireConversation(id: "abc", name: "n", projectPath: "/proj")
        XCTAssertEqual(try roundTrip(conversation), conversation)
    }

    /// `sessionActivity` is keyed by `uuidString`, not `UUID`, specifically so it encodes as
    /// a JSON object rather than `Codable`'s synthesized flat array for a non-`String`-keyed
    /// dictionary — see `WireConversationCatalogue`'s doc comment. Asserted on the bytes,
    /// since a round trip alone cannot see which shape shipped.
    func testWireConversationCatalogueEncodesSessionActivityAsAnObjectKeyedByUUIDString() throws {
        let id = UUID()
        let catalogue = WireConversationCatalogue(
            conversations: [WireConversation(id: "abc", name: "n", projectPath: "/proj")],
            sessionActivity: [id.uuidString: Date(timeIntervalSince1970: 1_000)]
        )
        XCTAssertEqual(try roundTrip(catalogue), catalogue)

        let data = try JSONEncoder().encode(catalogue)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let activity = try XCTUnwrap(json["sessionActivity"] as? [String: Any])
        XCTAssertNotNil(activity[id.uuidString], "keyed by uuidString, not nested as an array")
    }

    func testWireSearchHitsSurvivesARoundTripWithAndWithoutIndexingProgress() throws {
        let hit = TranscriptHit(
            rowID: 7, conversationID: "abc", projectPath: "/proj", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 1), offset: 4_096
        )
        let withoutProgress = WireSearchHits(hits: [hit], indexing: nil)
        XCTAssertEqual(try roundTrip(withoutProgress), withoutProgress)

        let withProgress = WireSearchHits(
            hits: [hit], indexing: WireIndexingProgress(done: 3, total: 10)
        )
        XCTAssertEqual(try roundTrip(withProgress), withProgress)
    }

    func testTranscriptHitSurvivesARoundTrip() throws {
        let hit = TranscriptHit(
            rowID: 42, conversationID: "abc", projectPath: "/proj", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 5), offset: 8_192
        )
        XCTAssertEqual(try roundTrip(hit), hit)
    }
}
