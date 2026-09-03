import FleetKit
import XCTest
@testable import FlightDeck

/// Whether a blocked tab's transcript is still being read from the right file, when this Mac
/// says so out loud, and the repair when a registry tick says otherwise.
///
/// **Isolated from `PromptLifecycleTests`, which owns what a live transcript derives.** These
/// tests drive `checkStuckPrompts` directly through `stuckCheckForTesting`, never through
/// `applyRegistry` itself — `applyRegistry`'s own resolution loop would happily repoint an
/// unanchored tab's `transcriptDirectory` to a fresh row's `cwd` on the very first tick it sees
/// one, which would make "silence early, a record later" impossible to observe: the loop would
/// have already done the repair before `checkStuckPrompts` got a turn. Calling the seam directly
/// keeps that loop out of the picture, exactly as production keeps this check running *after* it
/// (see the call site in `applyRegistry`). The seam still builds its `ConversationPin`
/// resolutions through the same `pinResolutions` production uses, so the row-selection rule
/// under test below is the real one.
///
/// **This file also owns whether the record is emitted at all.** It captures
/// `promptLifecycleSink` rather than leaving `FleetTestHarness`'s silencing in force — which it
/// did for a whole branch, with the consequence that deleting the `promptLifecycleSink(...)`
/// call inside `checkStuckPrompts` left the entire suite green, on a branch whose headline
/// deliverable is that one line.
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
    /// Everything the store filed while a test ran. See the class comment.
    private var records: [PromptLifecycleRecord] = []
    /// The store's `now()`, under the test's control: the report schedule is wall-clock, so a
    /// test that could not move time could only ever observe its first rung.
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        harness?.service.stop()
        harness = nil
        records = []
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - Fixtures

    private func entry(
        _ sessionID: UUID, cwd: String, pid: pid_t = 4242, startedAt: Double = 1,
        procStart: String = "start-a"
    ) -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sessionID, activity: .waiting, waitingFor: nil,
              startedAt: startedAt, cwd: cwd, procStart: procStart)
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
        // The whole point of this fixture, and what `FleetTestHarness` silences by default.
        harness.store.promptLifecycleSink = { [weak self] in self?.records.append($0) }
        harness.store.now = { [weak self] in self?.clock ?? Date() }
        let transcript = Transcript()
        self.transcript = transcript
        harness.service.promptTailForTesting = { _, _ in transcript.lines }

        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistryForTesting([session.id: SessionStatus(activity: .waiting)])
        return (harness.store, session.id)
    }

    /// Makes the tab's dialog nameable, so a following tick ends the episode instead of
    /// carrying it forward.
    private func makeFixtureCallNameable() {
        transcript.lines = [SourceLine(offset: 0, text: bashLine("toolu_FIX"))]
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    /// Every `.stuck` this test has seen, unpacked into the fields worth asserting on.
    private var stuckRecords: [(code: String, watched: String?, cwd: String?, matches: Bool)] {
        records.compactMap { record in
            guard case .stuck(let code, let watched, let cwd, let matches, _, _, _) = record.event
            else { return nil }
            return (code, watched, cwd, matches)
        }
    }

    // MARK: - When the record is written

    /// **The ordinary race must stay unremarkable.** claude writes its status file and its
    /// transcript by independent paths, so `waiting` routinely lands a beat before the record
    /// naming the call — 16:37:57 `unnamed` → 16:37:58 `opened`, from the incident this feature
    /// was built for. A second of unnameability is that, and it must produce nothing at all.
    func testASecondOfUnnameabilityIsAnOrdinaryRaceAndSaysNothing() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(1)
        store.stuckCheckForTesting(rows: rows)

        XCTAssertTrue(records.isEmpty, "one beat of unnamed is the race, not a diagnosis")
        XCTAssertEqual(store.stuckEpisodeForTesting(tab)?.reported, 0)
    }

    /// **The record exists, and this is the test that says so.** Deleting the
    /// `promptLifecycleSink(...)` call in `checkStuckPrompts` has to fail here — for a whole
    /// branch nothing did, because this file left the harness's silencing in force and
    /// `PromptLifecycleLogTests` only ever constructed records by hand.
    func testAStuckEpisodeEmitsExactlyOneRecordPerRung() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(5)
        store.stuckCheckForTesting(rows: rows)
        XCTAssertEqual(stuckRecords.count, 1, "the first rung fires once the race is ruled out")

        // Production ticks at ~2 Hz. Every one of these is a tick with nothing new to say.
        for _ in 0..<10 {
            advance(0.5)
            store.stuckCheckForTesting(rows: rows)
        }
        XCTAssertEqual(
            stuckRecords.count, 1,
            "a rung fires once — this must never become a log line every 500ms"
        )
    }

    /// **The whole reason the schedule repeats.** The first record of an episode is written
    /// seconds in, when `fileAgeMs` and `lastRecordAgeMs` are young by construction and cannot
    /// tell a 24-minute stall from a race about to resolve. Only a later line, taken when those
    /// ages have grown with the wall clock, carries the spec's stated discriminator — and the
    /// previous rule (two ticks, ~1s, once per episode) could never produce one.
    func testALongStallKeepsReportingSoTheAgesEventuallyMeanSomething() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        var seen: [Int] = []
        // Roughly the shape of the observed failures: 24 minutes to 3 hours.
        for elapsed in [5.0, 30.0, 120.0, 600.0, 1_800.0, 7_200.0] {
            clock = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(elapsed)
            store.stuckCheckForTesting(rows: rows)
            seen.append(stuckRecords.count)
        }

        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6], "each rung reports once, in order")
        XCTAssertEqual(
            store.stuckEpisodeForTesting(tab)?.reported, 6,
            "and the ladder is spent — a stall longer than its last rung stays quiet"
        )
    }

    /// A tick that crosses several rungs at once — the app spent the interval in the background
    /// at `WatchClock.backgroundInterval`, or the Mac slept — files the one record it is due,
    /// not a backlog of everything it missed.
    func testATickThatSkipsSeveralRungsFilesOneRecord() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(700)
        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(stuckRecords.count, 1)
        XCTAssertEqual(store.stuckEpisodeForTesting(tab)?.reported, 4,
                       "the skipped rungs are spent, not queued")
    }

    /// The episode ends the moment the dialog can be named, and the next one starts from the
    /// bottom of the ladder — otherwise a tab that blocked once would report instantly forever.
    func testNamingTheDialogEndsTheEpisodeAndTheNextOneStartsOver() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(5)
        store.stuckCheckForTesting(rows: rows)
        XCTAssertEqual(stuckRecords.count, 1)

        makeFixtureCallNameable()
        store.stuckCheckForTesting(rows: rows)
        XCTAssertNil(store.stuckEpisodeForTesting(tab), "a named dialog closes the episode")

        transcript.lines = []
        store.stuckCheckForTesting(rows: rows)
        advance(1)
        store.stuckCheckForTesting(rows: rows)
        XCTAssertEqual(stuckRecords.count, 1, "the new episode starts at the bottom of the ladder")
    }

    /// A tab that stops waiting closes its episode too — the same reset, for the other reason a
    /// dialog goes away.
    func testLeavingWaitingEndsTheEpisode() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        store.applyRegistryForTesting([tab: SessionStatus(activity: .busy)])
        store.stuckCheckForTesting(rows: rows)

        XCTAssertNil(store.stuckEpisodeForTesting(tab))
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - What the record says

    func testTheRecordCarriesTheVerdictAndBothPaths() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(5)
        store.stuckCheckForTesting(rows: rows)

        let record = try XCTUnwrap(stuckRecords.first)
        XCTAssertEqual(record.code, "prompt_changed", "the probe's own refusal, verbatim")
        XCTAssertEqual(record.cwd, original, "the registry's cwd, as the pin resolved it")
        XCTAssertEqual(
            record.watched, store.watchedTranscriptURL(of: tab)?.path,
            "the file this Mac is actually reading, not one recomputed for the log"
        )
        // The verdict itself is `SessionStore.pathMatches`, pinned on its own below — what
        // matters here is that the record carries the two paths the verdict was taken over,
        // and not two recomputed for the log.
    }

    // MARK: - The repair

    func testAMismatchedPathIsRetargetedOnceTheEpisodeIsWorthReporting() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)
        let worktree = tmp.appendingPathComponent(".claude/worktrees/w", isDirectory: true).path
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: worktree)]

        store.stuckCheckForTesting(rows: rows)          // the ordinary race: silent, no repair
        XCTAssertEqual(store.transcriptDirectory(of: tab), original)

        advance(5)
        store.stuckCheckForTesting(rows: rows)
        XCTAssertEqual(store.transcriptDirectory(of: tab), worktree,
                       "a mismatched path must be repaired on the spot, not left for a later tick")
    }

    func testAMatchingPathIsNeverRetargeted() throws {
        let (store, tab) = openFixtureSession()
        let original = store.transcriptDirectory(of: tab)!
        let rows = [pid_t(4242): entry(store.pinnedConversationID(of: tab)!, cwd: original)]

        store.stuckCheckForTesting(rows: rows)
        advance(5)
        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(store.transcriptDirectory(of: tab), original,
                       "a path that already agrees must not be churned")
    }

    /// **Which registry row this reads, when more than one names the conversation.**
    ///
    /// This selection used to be `rows.values.first { $0.sessionID == pinnedConversationID }`,
    /// which `ConversationPin.resolve`'s own comment rules out in as many words: `rows.values`
    /// has no defined order, and two processes really can hold one conversation once resumes
    /// are in play. The row it happened to return then decided both the recorded `registryCwd`
    /// *and* the `retarget` below it — the same mutation the hardened path drives — so a tab
    /// anchored to one process could be moved onto a second process's transcript on a coin
    /// flip, manufacturing the exact "wrong file" cause the record beside it had just reported.
    ///
    /// Here the second row is strictly newer, so the unanchored tiebreak would prefer it and
    /// `first` might return either; the tab is anchored to the first, and the anchor must win.
    func testTheAnchoredRowIsChosenWhenTwoProcessesShareOneConversation() throws {
        let (store, tab) = openFixtureSession()
        let conversation = store.pinnedConversationID(of: tab)!
        let mine = store.transcriptDirectory(of: tab)!
        let theirs = tmp.appendingPathComponent("someone-elses-resume", isDirectory: true).path

        // The real path, so an anchor exists: `stuckCheckForTesting` resolves but applies
        // nothing, and an unanchored tab would fall through to the newest-wins tiebreak.
        store.applyRegistry([4242: entry(conversation, cwd: mine)])

        let rows = [
            pid_t(4242): entry(conversation, cwd: mine, pid: 4242, startedAt: 1),
            pid_t(5555): entry(conversation, cwd: theirs, pid: 5555, startedAt: 99,
                               procStart: "start-b"),
        ]
        advance(5)
        store.stuckCheckForTesting(rows: rows)

        XCTAssertEqual(
            stuckRecords.last?.cwd, mine,
            "the record must name the row this tab is anchored to, not whichever the dictionary " +
            "yielded first"
        )
        XCTAssertEqual(
            store.transcriptDirectory(of: tab), mine,
            "and the repair must not follow a second process onto its transcript"
        )
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
