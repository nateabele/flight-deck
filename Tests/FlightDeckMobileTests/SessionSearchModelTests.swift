import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class SessionSearchModelTests: XCTestCase {
    /// Hands back what the test says, when the test says — so the two clocks can be driven
    /// apart deliberately instead of raced.
    final class Transport: TranscriptSearching {
        var requests: [String] = []
        var pending: [(Result<WireSearchHits, FleetRequestError>) -> Void] = []

        func searchTranscripts(
            query: String, limit: Int,
            then completion: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void
        ) {
            requests.append(query)
            pending.append(completion)
        }

        func answer(_ hits: [TranscriptHit], at index: Int = 0) {
            pending[index](.success(WireSearchHits(hits: hits, indexing: nil)))
        }
    }

    /// Comfortably past the 90 ms debounce, so the request has certainly been issued.
    private func letTheDebounceFire() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private func candidate(_ name: String) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/proj", projectName: "proj",
            lastActivity: Date(timeIntervalSince1970: 1), conversationID: nil
        )
    }

    private func hit(_ conversation: String) -> TranscriptHit {
        TranscriptHit(
            rowID: 1, conversationID: conversation, projectPath: "/proj",
            conversationName: conversation, snippet: "the rename path",
            timestamp: Date(timeIntervalSince1970: 1), offset: 4096
        )
    }

    /// Names rank on the keystroke with nothing in flight — the whole point of matching
    /// them locally, and what makes the field work with the Mac asleep.
    func testNamesRankWithoutAskingTheMac() {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")
        model.candidatesChanged([candidate("rename fix"), candidate("unrelated")])

        model.query = "rename"

        XCTAssertEqual(model.results.map(\.title), ["rename fix"])
        XCTAssertTrue(transport.requests.isEmpty, "names must not wait on a round trip")
    }

    /// A reply for a superseded query is discarded, so a previous query's evidence can
    /// never survive under a new one.
    func testAStaleReplyIsDropped() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")

        model.query = "rena"
        try await letTheDebounceFire()
        XCTAssertEqual(transport.requests, ["rena"])

        model.query = "rename"
        transport.answer([hit("stale")], at: 0)

        XCTAssertFalse(model.results.contains { $0.conversationID == "stale" })
    }

    /// Hits land BELOW names however they arrive — the property that stops a row moving
    /// under a finger already descending on it.
    func testHitsAlwaysAppendBelowNames() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")
        model.candidatesChanged([candidate("rename fix")])

        model.query = "rename"
        try await letTheDebounceFire()
        transport.answer([hit("conv")])

        XCTAssertEqual(model.results.first?.title, "rename fix")
        XCTAssertEqual(model.results.last?.conversationID, "conv")
    }

    /// Disconnected says so and never claims "no results" — that is a claim about the
    /// corpus a disconnected phone is in no position to make.
    func testDisconnectedSetsTheOfflineFooterRatherThanEmpty() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Nate's Mac")

        model.query = "rename"
        try await letTheDebounceFire()
        transport.pending[0](.failure(.disconnected))

        XCTAssertEqual(model.footer, .offline("Nate's Mac"))
    }

    /// The "hits append below names" property is not an accident of one arrival order — it
    /// holds regardless, because `SearchRanker` puts transcript hits in the last tier
    /// unconditionally. Reversing the arrival order the previous test used should not change
    /// the outcome.
    func testHitsAppendBelowNamesEvenWhenTheReplyArrivesBeforeTheQueryIsChecked() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")
        model.candidatesChanged([candidate("rename fix"), candidate("rename again")])

        model.query = "rename"
        try await letTheDebounceFire()
        // Two conversations, so the merged list has more than one row per half — a stronger
        // check than one name and one hit, which could pass by coincidence of list length.
        transport.answer([hit("conv-a"), hit("conv-b")])

        let names = model.results.prefix(2)
        let transcriptRows = model.results.suffix(2)
        XCTAssertEqual(Set(names.map(\.title)), ["rename fix", "rename again"])
        XCTAssertEqual(Set(transcriptRows.map(\.conversationID)), ["conv-a", "conv-b"])
    }

    /// Hits merged in first still land below a name that only becomes a match *after* the
    /// reply arrives — the candidate list changing later must not let the standing
    /// transcript tier climb above it. This is the arrival order the given tests don't
    /// cover: name candidates arriving AFTER the transcript reply, rather than before it.
    func testHitsStayBelowANameCandidateAddedAfterTheReplyArrives() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")

        model.query = "rename"
        try await letTheDebounceFire()
        transport.answer([hit("conv")])
        XCTAssertEqual(model.results.map(\.title), ["conv"], "only the hit exists yet")

        // A name candidate arrives after the hit is already merged in.
        model.candidatesChanged([candidate("rename fix")])

        XCTAssertEqual(model.results.map(\.title), ["rename fix", "conv"])
        XCTAssertEqual(model.results.last?.conversationID, "conv")
    }
}
