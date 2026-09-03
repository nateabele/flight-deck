import FleetKit
import XCTest
@testable import FlightDeck

/// Whether a blocked tab's transcript is still being read from the right file, and the repair
/// when a registry tick says otherwise.
///
/// **Isolated from `PromptLifecycleTests`, which owns what gets logged.** These tests drive
/// `checkStuckPrompts` directly through `stuckCheckForTesting`, never through `applyRegistry`
/// itself — `applyRegistry`'s own resolution loop (`ConversationPin.resolve`) would happily
/// repoint an unanchored tab's `transcriptDirectory` to a fresh row's `cwd` on the very first
/// tick it sees one, which would make "one silent tick, then a repair on the second" impossible
/// to observe: the loop would have already done the repair before `checkStuckPrompts` got a
/// turn. Calling the seam directly keeps that loop out of the picture, exactly as production
/// keeps this check running *after* it (see the call site in `applyRegistry`).
@MainActor
final class SessionStoreStuckPromptTests: XCTestCase {
    /// The transcript `openPromptProbe` reads through the harness's real `PromptService`.
    /// `@unchecked Sendable` for the reason `PromptLifecycleTests.Transcript` is: `tail` is
    /// `@Sendable`, and every call here arrives inline, on the main actor, from
    /// `checkStuckPrompts` itself.
    private final class Transcript: @unchecked Sendable {
        var lines: [SourceLine] = []
    }

    private var harness: FleetTestHarness?
    private var projectsRoot: URL!
    private var transcript: Transcript!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        harness?.service.stop()
        harness = nil
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - Fixtures

    private func entry(_ sessionID: UUID, cwd: String) -> ClaudeStatusFile.Entry {
        .init(pid: 4242, sessionID: sessionID, activity: .waiting, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    /// A `waiting` tab whose dialog nothing can name — the harness's `tail` seam starts empty,
    /// which trips `PromptService.openPrompt`'s `prompt_changed` guard the same way a real
    /// upstream record that was never written would. `store.openPromptProbe` needs no manual
    /// wiring here: `FleetService.init` already installs it against this harness's own
    /// `PromptService`, the same as production.
    private func openFixtureSession() -> (SessionStore, UUID) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        harness.service.promptLifecycleForTesting = { _ in }
        let transcript = Transcript()
        self.transcript = transcript
        harness.service.promptTailForTesting = { _, _ in transcript.lines }

        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        return (harness.store, session.id)
    }

    /// Makes the tab's dialog nameable, so a following tick resets the counter instead of
    /// firing.
    private func makeFixtureCallNameable() {
        transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_FIX"))]
    }

    // MARK: - Tests

    func testSecondConsecutiveUnnameableTickRetargetsAMismatchedPath() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)
        let worktree = tmp.appendingPathComponent(".claude/worktrees/w", isDirectory: true).path
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: worktree)]

        store.stuckCheckForTesting(rows: rows)          // tick 1: ordinary race, silent
        XCTAssertEqual(store.transcriptDirectory(of: tab), original)

        store.stuckCheckForTesting(rows: rows)          // tick 2: stuck, and mismatched
        XCTAssertEqual(store.transcriptDirectory(of: tab), worktree,
                       "a mismatched path must be repaired on the spot, not left for a later tick")
    }

    func testOneTickOfUnnameableEmitsNothingAndChangesNothing() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(store.transcriptDirectory(of: tab), original)
        XCTAssertEqual(store.stuckTicksForTesting(tab), 1)
    }

    func testAMatchingPathIsNeverRetargeted() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(store.transcriptDirectory(of: tab), original,
                       "a path that already agrees must not be churned")
    }

    func testTheCounterResetsOnceTheDialogIsNameable() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        makeFixtureCallNameable()
        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(store.stuckTicksForTesting(tab), 0)
    }

    /// Pins the exact string `openPromptProbe` hands `checkStuckPrompts` for its `.stuck`
    /// record's `code` field. `TimelineErrorCode` has no `CustomStringConvertible`, so a
    /// `String(describing:)` regression here would silently swap this test's expected
    /// `"prompt_changed"` for the struct dump `"TimelineErrorCode(code: \"prompt_changed\")"` —
    /// exactly the bug this test exists to catch before it reaches the log a person actually
    /// reads.
    func testTheProbeReturnsTheRawWireCodeNotAStructDump() throws {
        let (store, tab) = openFixtureSession()

        XCTAssertEqual(store.openPromptProbe?(tab), "prompt_changed")
    }

    // MARK: - pathMatches and expectedTranscriptURL
    //
    // `checkStuckPrompts` gates every retarget in the tests above on `!matches`, but every one
    // of them also flips `cwd != session.transcriptDirectory` at the same time, so `matches`
    // itself is never the deciding factor there. These tests call `SessionStore.pathMatches`
    // and `SessionStore.expectedTranscriptURL(for:cwd:)` directly so the raw-equality rule and
    // the `projectsRoot` threading it depends on are each pinned on their own — and so a future
    // edit that "tidies" the comparison to `comparablePath`, or drops the `projectsRoot:`
    // argument inside `expectedTranscriptURL`, fails a test instead of silently changing what a
    // person reading the log believes about a wrong-file failure.

    func testPathMatchesTrueForIdenticalTranscriptURLs() {
        let url = ClaudeSession.transcriptURL(
            sessionID: UUID(), workingDirectory: "/tmp/project", projectsRoot: projectsRoot)

        XCTAssertTrue(SessionStore.pathMatches(watched: url, expected: url))
    }

    func testPathMatchesFalseWhenEitherSideIsNil() {
        let url = ClaudeSession.transcriptURL(
            sessionID: UUID(), workingDirectory: "/tmp/project", projectsRoot: projectsRoot)

        XCTAssertFalse(SessionStore.pathMatches(watched: nil, expected: url))
        XCTAssertFalse(SessionStore.pathMatches(watched: url, expected: nil))
        XCTAssertFalse(SessionStore.pathMatches(watched: nil, expected: nil))
    }

    /// The case the doc comment on `pathMatches` names: a symlink and the real directory it
    /// points at. `encodedProjectDirName` encodes the *string* claude was given, so these are
    /// two different, unrelated project directories on disk — raw equality must call them a
    /// mismatch. `comparablePath`'s `resolvingSymlinksInPath()` would instead collapse the
    /// symlink component down to its target and call them the same file, which is exactly the
    /// silent inversion a "tidying" edit here would produce.
    func testPathMatchesDoesNotResolveSymlinksTheWayComparablePathWould() throws {
        let sessionID = UUID()
        let realDir = projectsRoot.appendingPathComponent(
            ClaudeSession.encodedProjectDirName(for: "/tmp/real-project"), isDirectory: true)
        let linkDir = projectsRoot.appendingPathComponent(
            ClaudeSession.encodedProjectDirName(for: "/tmp/real-project-symlink"), isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let watched = realDir.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        let expected = linkDir.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")

        XCTAssertFalse(
            SessionStore.pathMatches(watched: watched, expected: expected),
            "a symlink alias of the watched directory must read as a mismatch, not get " +
            "normalized away")
    }

    /// The other case the review named: `expectedTranscriptURL` is the one place that threads
    /// `transcriptsRoot(forAccount:)` instead of leaving `ClaudeSession.transcriptURL` at its
    /// default. Calling `pathMatches` with two independently pre-built URLs (the prior version
    /// of this test) only proves two literal strings differ — true of any implementation,
    /// correct or broken — and never touches this method at all. Calling the method itself,
    /// against a session whose store carries a fixture root override, is what a dropped
    /// `projectsRoot:` argument inside it would actually break.
    func testExpectedTranscriptURLUsesThisSessionsAccountRootNotTheDefault() throws {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        let session = harness.store.newSession(in: tmp)
        let cwd = "/tmp/some-project"

        let expected = harness.store.expectedTranscriptURL(for: session, cwd: cwd)
        let defaulted = ClaudeSession.transcriptURL(
            sessionID: session.pinnedConversationID, workingDirectory: cwd)

        XCTAssertTrue(
            expected.path.hasPrefix(projectsRoot.path),
            "expectedTranscriptURL must resolve under this session's fixture-rooted account, " +
            "not wherever the default root happens to be")
        XCTAssertNotEqual(
            expected, defaulted,
            "dropping the projectsRoot: argument inside expectedTranscriptURL must change the " +
            "verdict, not silently agree with the defaulted-root computation")
    }
}
