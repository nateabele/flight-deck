import XCTest
@testable import FlightDeck

/// Building the name-match list from the deck and the index.
///
/// Three sources with three different recency answers, which is why this is a tested unit
/// rather than a closure inside `AppDelegate`.
final class SearchCandidatesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func repo(_ path: String, sessions: [Session] = []) -> Repo {
        var repo = Repo(url: URL(fileURLWithPath: path, isDirectory: true))
        repo.sessions = sessions
        return repo
    }

    func testEveryOpenSessionBecomesACandidate() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [
                Session(title: "rename-break", workingDirectory: "/w/fd"),
                Session(title: "wifi", workingDirectory: "/w/fd"),
            ])],
            conversations: [:],
            modified: { _ in self.now }
        )

        let sessions = candidates.filter {
            if case .session = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(sessions.map(\.name), ["rename-break", "wifi"])
    }

    func testEachProjectBecomesACandidateNamedByItsFolder() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd")], conversations: [:], modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.filter { $0.kind == .project }.map(\.name), ["fd"])
    }

    /// A past conversation with no open tab is still matchable by name — that is most of
    /// what makes ⌘K useful for history rather than only for the live deck.
    func testIndexedConversationsWithNoTabBecomeCandidates() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd")],
            conversations: ["c1": IndexedConversation(name: "mobile-ui", projectPath: "/w/fd")],
            modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.filter { $0.kind == .conversation("c1") }.map(\.name), ["mobile-ui"])
        XCTAssertEqual(candidates.first { $0.kind == .conversation("c1") }?.projectPath, "/w/fd")
    }

    /// A conversation that already has a tab must appear once, as the session — not twice,
    /// once as a tab and once as history, with two different meanings for Return.
    func testAConversationWithAnOpenTabIsNotAlsoListedAsHistory() {
        let id = UUID()
        let session = Session(id: id, title: "rename-break", workingDirectory: "/w/fd")

        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [session])],
            conversations: [
                id.uuidString.lowercased():
                    IndexedConversation(name: "rename-break", projectPath: "/w/fd"),
            ],
            modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.filter { $0.name == "rename-break" }.count, 1)
    }

    /// `SQLiteSearchIndex.prune` drops a project's message and source rows once it leaves the
    /// sidebar, but never its `conversation` rows — so `conversationNames()` keeps answering
    /// for a project that is no longer open. Left unfiltered, ⌘K would offer a name match the
    /// user cannot actually resume: `SearchActivation.plan` only resumes into a project
    /// already in `projects`, and everything else routes through `addProjectThenResume`,
    /// silently re-adding a project the user removed on purpose.
    func testConversationsFromAProjectNoLongerInTheSidebarAreNotCandidates() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd")],
            conversations: ["c1": IndexedConversation(name: "mobile-ui", projectPath: "/w/other")],
            modified: { _ in self.now }
        )

        XCTAssertTrue(candidates.filter { $0.kind == .conversation("c1") }.isEmpty)
    }

    /// Recency comes from the transcript's mtime. There is no per-session activity stamp
    /// anywhere in the model, and the file already records exactly this — a live session
    /// appends to it constantly — so adding one would duplicate a fact that could then
    /// disagree with itself.
    func testRecencyComesFromTheTranscriptModificationDate() {
        let stamp = now.addingTimeInterval(-500)
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [
                Session(title: "rename-break", workingDirectory: "/w/fd"),
            ])],
            conversations: [:],
            modified: { _ in stamp }
        )

        XCTAssertEqual(candidates.first?.lastActivity, stamp)
    }

    /// A project is as recent as its liveliest session, so an active project outranks a
    /// dormant one at equal match quality.
    func testAProjectIsAsRecentAsItsNewestSession() {
        let old = Session(title: "old", workingDirectory: "/w/fd")
        let new = Session(title: "new", workingDirectory: "/w/fd")
        let stamps = [
            ClaudeSession.transcriptURL(
                sessionID: old.pinnedConversationID, workingDirectory: "/w/fd"
            ): now.addingTimeInterval(-1000),
            ClaudeSession.transcriptURL(
                sessionID: new.pinnedConversationID, workingDirectory: "/w/fd"
            ): now,
        ]

        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [old, new])],
            conversations: [:],
            modified: { stamps[$0] ?? .distantPast }
        )

        XCTAssertEqual(candidates.first { $0.kind == .project }?.lastActivity, now)
    }
}
