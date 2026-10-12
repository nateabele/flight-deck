import XCTest
@testable import FleetKit

/// What crosses the wire for a dialog the Mac read off its screen (`ScreenPromptID`,
/// `OpenPrompt.signIn`), and what an older or newer peer does with it.
///
/// **The skew rules, stated once.** The wire version is not bumped for this, so both directions
/// have to degrade rather than fail:
///
/// - an older Mac never sends `url`, `"signin"` or a `screen:` id — a newer phone sees the
///   absence it has always seen;
/// - an older phone, given the newer Mac's bytes, must decode the session around them and draw
///   **no card** for a kind it does not know — `LegacyWireOpenPrompt` below is a frozen copy of
///   the shape and the `prompt` rule it had before this field, which is the only honest way to
///   assert that without a second build.
final class ScreenPromptWireTests: XCTestCase {
    private let url = "https://claude.com/cai/oauth/authorize?code=true&client_id=c"
        + "&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
        + "&code_challenge=x&code_challenge_method=S256&state=s"

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    /// `WireOpenPrompt` as it was before `url` and `"signin"` — frozen. If this and the real type
    /// ever need to differ for a reason other than a new kind, a test here should say why.
    private struct LegacyWireOpenPrompt: Decodable {
        var callID: String
        var kind: String
        var tool: String?
        var summary: String?
        var questions: [PromptQuestion]?

        var prompt: OpenPrompt? {
            switch kind {
            case "permission": return .permission(callID: callID, tool: tool, summary: summary)
            case "question":
                guard let questions, !questions.isEmpty else { return nil }
                return .question(callID: callID, questions)
            default: return nil
            }
        }
    }

    // MARK: - Round trips

    func testASignInRoundTripsToTheSameDialog() throws {
        let open = OpenPrompt.signIn(callID: ScreenPromptID.signIn(state: "s"), url: url)
        let wire = WireOpenPrompt(open)
        XCTAssertEqual(wire.kind, "signin")
        XCTAssertEqual(try roundTrip(wire).prompt, open)
    }

    func testAScreenMenuRoundTripsAsAnOrdinaryQuestion() throws {
        let call = ScreenPromptID.menu(prompt: "Select login method:", labels: ["A", "B"])
        let open = OpenPrompt.question(callID: call, [
            PromptQuestion(question: "Select login method:", options: [.init(label: "A"), .init(label: "B")]),
        ])
        XCTAssertEqual(try roundTrip(WireOpenPrompt(open)).prompt, open)
        XCTAssertEqual(WireOpenPrompt(open).kind, "question", "no new kind: an older phone already draws this")
    }

    func testASessionBlockedOnAScreenDialogCarriesItInTheSnapshotAndTheEvent() throws {
        let open = OpenPrompt.signIn(callID: ScreenPromptID.signIn(state: "s"), url: url)
        let offer = WireOpenPrompt(open)
        let session = WireSession(id: UUID(), title: "t", agent: "claude", activity: "waiting",
                                  openPromptCall: .call(open.callID), openPrompt: offer)
        XCTAssertEqual(try roundTrip(session).openPrompt?.prompt, open)
        XCTAssertEqual(try roundTrip(session).openPromptCall, .call(open.callID))
        let event = FleetEvent.activityChanged(
            id: session.id, activity: "waiting", waitingFor: nil, subagentCount: 0,
            hasBackgroundWork: false, openPromptCall: .call(open.callID), openPrompt: offer
        )
        XCTAssertEqual(try roundTrip(event), event)
    }

    // MARK: - The bytes an older phone has always seen

    /// **Every other kind writes no `url` key.** The synthesized encoder's `encodeIfPresent`
    /// is what holds that, and a field that silently started writing `"url":null` would change
    /// the bytes of every gemini permission and question offer.
    func testNoUrlKeyUnlessThereIsAUrl() throws {
        let others: [OpenPrompt] = [
            .permission(callID: "c", tool: "t", summary: "s"),
            .question(callID: "q", [PromptQuestion(question: "?", options: [.init(label: "A")])]),
        ]
        for open in others {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(WireOpenPrompt(open))) as? [String: Any])
            XCTAssertNil(object["url"], "\(open)")
        }
        let signIn = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WireOpenPrompt(.signIn(callID: "signin:1", url: url)))) as? [String: Any])
        XCTAssertEqual(signIn["url"] as? String, url)
    }

    // MARK: - Skew: an older phone, a newer Mac

    /// The newer Mac's bytes for a sign-in, through the older phone's decoder: the session
    /// survives, the unknown kind is no card, and the id it carries is just a string.
    func testAnOlderPhoneDecodesASignInAsNoCard() throws {
        let sign = WireOpenPrompt(.signIn(callID: "signin:1", url: url))
        let decoded = try JSONDecoder().decode(
            LegacyWireOpenPrompt.self, from: JSONEncoder().encode(sign))
        XCTAssertEqual(decoded.callID, "signin:1")
        XCTAssertNil(decoded.prompt, "an unknown kind must draw nothing rather than fail")
    }

    /// A screen menu is the case that needs no new phone at all: the older phone's own rule —
    /// derive from the transcript, else the Mac's offer, vetoed by the Mac's id — draws it.
    func testAnOlderPhoneDrawsAScreenMenuThroughItsExistingOfferRule() throws {
        let call = ScreenPromptID.menu(prompt: "Pick:", labels: ["A", "B"])
        let open = OpenPrompt.question(callID: call, [
            PromptQuestion(question: "Pick:", options: [.init(label: "A"), .init(label: "B")]),
        ])
        let decoded = try JSONDecoder().decode(
            LegacyWireOpenPrompt.self, from: JSONEncoder().encode(WireOpenPrompt(open)))
        XCTAssertEqual(decoded.prompt, open)
    }

    // MARK: - Skew: a newer phone, an older Mac

    func testAnOlderMacsSessionHasNoScreenDialogAndNoUrl() throws {
        let id = UUID().uuidString
        let bytes = Data(#"""
        {"id":"\#(id)","title":"t","agent":"claude","activity":"waiting","subagentCount":0,"isUnread":false}
        """#.utf8)
        let session = try JSONDecoder().decode(WireSession.self, from: bytes)
        XCTAssertNil(session.openPrompt)
        XCTAssertEqual(session.openPromptCall, .unreported, "the phone derives for itself, as always")
    }

    /// A `"signin"` whose URL this build will not trust is no card — the second end of the rule
    /// `ClaudeSignInURL` is shared for. Nothing else in the session is lost.
    func testASignInOfferWithAnUntrustedUrlIsNoCard() throws {
        for bad in ["http://claude.com/oauth/authorize?state=s&redirect_uri=https%3A%2F%2Fa.b%2Fc",
                    "https://evil.example/oauth/authorize?state=s&redirect_uri=https%3A%2F%2Fa.b%2Fc",
                    "https://claude.com/oauth/authorize?state=s&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback",
                    "https://claude.com/oauth/authorize?redirect_uri=https%3A%2F%2Fa.b%2Fc",
                    "javascript:alert(1)", ""] {
            XCTAssertNil(WireOpenPrompt(callID: "signin:1", kind: "signin", url: bad).prompt, bad)
        }
        XCTAssertNil(WireOpenPrompt(callID: "signin:1", kind: "signin").prompt, "no url at all")
        XCTAssertNotNil(WireOpenPrompt(callID: "signin:1", kind: "signin", url: url).prompt)
    }

    func testAnOfferWithAnUnknownKindStillDropsOnlyTheCard() throws {
        let id = UUID().uuidString
        let bytes = Data(#"""
        {"id":"\#(id)","title":"t","agent":"claude","activity":"waiting","subagentCount":0,"isUnread":false,"openPromptCall":"signin:9","openPrompt":{"callID":"signin:9","kind":"mfa","url":"https://x.example"}}
        """#.utf8)
        let session = try JSONDecoder().decode(WireSession.self, from: bytes)
        XCTAssertEqual(session.openPromptCall, .call("signin:9"))
        XCTAssertNil(session.openPrompt?.prompt)
    }

    // MARK: - ClaudeSignInURL

    func testTheUsableUrlIsParsedAndItsStateExposed() throws {
        let parsed = try XCTUnwrap(ClaudeSignInURL.parse(url))
        XCTAssertEqual(parsed.state, "s")
        XCTAssertEqual(parsed.url.absoluteString, url, "re-serialised unchanged: `+` and %-escapes intact")
    }

    func testLoopbackRedirectsAreAllRefused() {
        for host in ["localhost", "127.0.0.1", "0.0.0.0", "LOCALHOST", "app.localhost"] {
            let redirect = "https%3A%2F%2F\(host)%2Fcallback"
            XCTAssertNil(ClaudeSignInURL.parse(
                "https://claude.com/oauth/authorize?state=s&redirect_uri=\(redirect)"), host)
        }
        XCTAssertNil(ClaudeSignInURL.parse(
            "https://claude.com/oauth/authorize?state=s&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback"))
    }

    func testAnUnparseableRedirectIsRefusedNotTrusted() {
        XCTAssertNil(ClaudeSignInURL.parse("https://claude.com/oauth/authorize?state=s&redirect_uri=not%20a%20url"))
        XCTAssertNil(ClaudeSignInURL.parse("https://claude.com/oauth/authorize?state=s&redirect_uri="))
    }
}
