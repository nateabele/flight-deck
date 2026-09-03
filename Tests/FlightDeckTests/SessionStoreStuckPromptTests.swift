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
}
