// Tests/FlightDeckTests/OpenConversationTests.swift
import XCTest
@testable import FlightDeck

/// ⌘K's Return key: `SessionStore.openConversation`, the effectful half of
/// `SearchActivation.plan`.
///
/// Mirrors `ReopenClosedSessionTests`' style deliberately — driving the store through its
/// public surface with a `CapturingProvider` that never spawns a real surface, so every branch
/// is testable without an agent process.
@MainActor
final class OpenConversationTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    private final class SpyReporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    private let projectA = URL(fileURLWithPath: "/w/a", isDirectory: true)
    private let projectB = URL(fileURLWithPath: "/w/b", isDirectory: true)

    private func makeStore(preferences: PreferencesStore? = nil) -> SessionStore {
        let store = SessionStore(provider: CapturingProvider(), persistence: nil, preferences: preferences)
        store.titleResolver = { _, _, done in done(nil) }
        store.launchFailureReporter = SpyReporter()
        return store
    }

    /// One real login, homed in a directory that actually exists — `launchAccount`'s home
    /// check is part of what item 5 tests exercise, so a fixture that skipped it would pass
    /// for the wrong reason.
    private func account(_ name: String) -> AgentAccount {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenConversationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return AgentAccount(agent: .claude, displayName: name, home: home)
    }

    /// A fresh scratch directory, torn down after the test — for the two `resolvedTranscriptDirectory`
    /// fixtures below, which write real transcript files rather than merely asserting on paths.
    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenConversationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - Item 5: the in-store already-open guard

    /// The guard `openConversation` keeps for itself, not only the one inside
    /// `SearchActivation.plan`: a caller that fills `plan`'s `openSessions` wrong must not be
    /// trusted blind, or a second `claude --resume` starts on a conversation that already has a
    /// tab — two processes appending one transcript.
    func testOpeningAnAlreadyOpenConversationSelectsItsTabRatherThanResuming() {
        let store = makeStore()
        let session = store.newSession(in: projectA)

        store.openConversation(.resume(
            conversationID: session.pinnedConversationID.uuidString, projectPath: projectA.path,
            title: "ignored", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), [session.id],
                       "no second tab may be filed for a conversation already open")
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    // MARK: - The client-selection rule: the two paths round 1's brief missed

    /// Round 1's brief said `openConversation` had two selection writes; it has four — this
    /// is the already-live recheck above, the same guard `testOpeningAnAlreadyOpenConversationSelectsItsTabRatherThanResuming`
    /// exercises at the default. That test alone is what confirms ⌘K still selects here: it
    /// takes no `selecting:` argument, gets the default `true`, and still passes.
    ///
    /// This test is the client half: `selecting: false` must leave the desk's selection alone,
    /// while still returning the live tab's id — the phone needs that id to navigate its own
    /// side, even though the Mac does not move.
    func testAClientResumeRequestForAnAlreadyOpenConversationLeavesTheDesksSelectionAlone() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        let elsewhere = store.newSession(in: projectA)
        store.selectSession(elsewhere.id)

        let opened = store.openConversation(.resume(
            conversationID: session.pinnedConversationID.uuidString, projectPath: projectA.path,
            title: "ignored", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true }, selecting: false)

        XCTAssertEqual(opened, session.id, "the caller still needs the live tab's id")
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id).sorted(), [session.id, elsewhere.id].sorted(),
                       "no second tab may be filed for a conversation already open")
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client request must not move the desk's selection off elsewhere")
    }

    /// The other missed path: `.select(id)`, reached when a search result already names an
    /// open tab directly (`SearchActivation.plan`'s own `.session` case, or a conversation id
    /// match) rather than resolving through the resume machinery above. Default `selecting:
    /// true` is what ⌘K's Return relies on — pinned here so it cannot regress alongside the
    /// client-selection rule.
    func testSelectingAnAlreadyOpenTabByIDSelectsAtTheDeskDefault() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        let elsewhere = store.newSession(in: projectA)
        store.selectSession(elsewhere.id)

        let opened = store.openConversation(.select(session.id))

        XCTAssertEqual(opened, session.id)
        XCTAssertEqual(store.selectedSessionID, session.id,
                       "⌘K's Return must still land on the tab it selected")
    }

    /// The client half of `.select`: a phone action naming an already-open tab must not move
    /// the desk's selection off whatever is on screen, even though it still reports the tab's
    /// id back to the caller.
    func testSelectingAnAlreadyOpenTabByIDFromAClientLeavesTheDesksSelectionAlone() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        let elsewhere = store.newSession(in: projectA)
        store.selectSession(elsewhere.id)

        let opened = store.openConversation(.select(session.id), selecting: false)

        XCTAssertEqual(opened, session.id, "the caller still needs the tab's id")
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client's .select must not move the desk's selection off elsewhere")
    }

    // MARK: - Un-collapsing the target project

    func testResumingIntoACollapsedProjectUncollapsesIt() {
        let store = makeStore()
        store.newSession(in: projectA)
        store.setCollapsed(true, forProjectAt: store.repos[0].id)
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Resumed", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.isCollapsed, false)
    }

    // MARK: - Re-adding a project that left the sidebar

    func testOpeningAConversationInAProjectThatLeftTheSidebarBringsItBack() {
        let store = makeStore()
        let conversation = UUID()

        store.openConversation(.addProjectThenResume(
            projectPath: projectB.path, conversationID: conversation.uuidString,
            title: "New chat", transcriptDirectory: projectB.path
        ), directoryExists: { _ in true })

        let repo = store.repos.first { $0.url.path == projectB.path }
        XCTAssertNotNil(repo, "the project must come back into the sidebar")
        XCTAssertEqual(repo?.sessions.first?.pinnedConversationID, conversation)
    }

    // MARK: - The "nothing to resume" fallback

    /// The branch the brief's own comment names: a project row, or a result whose conversation
    /// id was never learned, must land on the project rather than fall through into the
    /// `Session(...)` below it and file a tab titled from a raw UUID.
    func testAProjectResultWithNoConversationLandsOnTheProjectRatherThanLaunchingANamelessAgent() {
        let store = makeStore()
        let existing = store.newSession(in: projectA)
        let before = store.repos.flatMap(\.sessions).map(\.id)

        store.openConversation(.addProjectThenResume(
            projectPath: projectA.path, conversationID: "", title: "fd", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), before,
                       "no tab may be filed for an empty conversation id")
        XCTAssertEqual(store.selectedSessionID, existing.id)
    }

    /// The other half of the same branch: a project not yet in the sidebar is added exactly the
    /// way "Add Project" adds it, not with a bare `Session(title: "session")`.
    func testAProjectResultForAProjectNotInTheSidebarAddsItTheNormalWay() {
        let store = makeStore()

        store.openConversation(.addProjectThenResume(
            projectPath: projectB.path, conversationID: "", title: "fd", transcriptDirectory: projectB.path
        ), directoryExists: { _ in true })

        let repo = store.repos.first { $0.url.path == projectB.path }
        XCTAssertEqual(repo?.sessions.count, 1)
        XCTAssertNotEqual(repo?.sessions.first?.title, "session",
                          "a project added this way must not fall through to the nameless-tab title")
    }

    /// **Round 2's finding.** The new-project side above delegates to `addProject(at:)`, which
    /// used to take no `selecting:` of its own and so always selected through `newSession`'s
    /// default — a hole guarded only by `FleetService` pre-validating the UUID before this
    /// branch is ever reachable from a client, not by this method itself. Pins that the hole is
    /// closed: a client landing on a project new to the sidebar must not move the desk's
    /// selection, same as every other path through `openConversation`.
    func testAProjectResultForAProjectNotInTheSidebarFromAClientLeavesTheDesksSelectionAlone() {
        let store = makeStore()
        let elsewhere = store.newSession(in: projectA)

        let opened = store.openConversation(.addProjectThenResume(
            projectPath: projectB.path, conversationID: "", title: "fd", transcriptDirectory: projectB.path
        ), directoryExists: { _ in true }, selecting: false)

        let repo = store.repos.first { $0.url.path == projectB.path }
        XCTAssertEqual(repo?.sessions.count, 1, "the project really was added")
        XCTAssertEqual(opened, repo?.sessions.first?.id, "the caller still needs the new tab's id")
        XCTAssertEqual(store.selectedSessionID, elsewhere.id,
                       "a client's search must not move the desk's selection off elsewhere, even onto a brand new project")
    }

    // MARK: - Item 1: the account stamp

    func testResumingStampsTheProjectsResolvedAccount() {
        let chosen = account("chosen")
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [chosen]
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: chosen.id])
        ]
        let store = makeStore(preferences: preferences)
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(
            store.repos.first?.sessions.first(where: { $0.pinnedConversationID == conversation })?.accountID,
            chosen.id
        )
    }

    /// The refusal `newSession` follows: a project that names a login which no longer resolves
    /// must not launch as the built-in home instead. No tab may be filed either.
    func testAResumeUnderADanglingAccountAssignmentIsRefusedRatherThanSubstituted() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: UUID()])
        ]
        let store = makeStore(preferences: preferences)
        let reporter = SpyReporter()
        store.launchFailureReporter = reporter
        let conversation = UUID()

        let opened = store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab under the wrong login is worse than no tab")
        XCTAssertEqual(reporter.reported, [.accountMissing("Claude")])
        XCTAssertNil(opened, "a refused launch must report that nothing opened, not a tab id")
    }

    /// The bug this return value exists to make unrepresentable: before it returned `UUID?`,
    /// this method's only outward signal of success was `selectedSessionID`, which a refused
    /// launch below leaves untouched — so a caller reading that property afterward, the way
    /// `FleetService` used to, would see whatever tab was already selected and report a
    /// confident success naming an unrelated conversation. Pre-selecting `unrelated` here is
    /// what makes that failure mode visible: this test fails on the old `Void`-returning shape
    /// (nothing to assert `XCTAssertNil` against) and would have falsely passed a version that
    /// read `selectedSessionID` back, since that property still names `unrelated.id` on this path.
    func testARefusedLaunchNeverReportsAPreviouslySelectedTabAsTheResult() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: UUID()])
        ]
        let store = makeStore(preferences: preferences)
        store.launchFailureReporter = SpyReporter()
        let unrelated = store.newSession(in: projectB)
        store.selectSession(unrelated.id)
        let conversation = UUID()

        let opened = store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertNil(opened, "a refused launch must not be reported as the previously-selected tab")
        XCTAssertEqual(store.selectedSessionID, unrelated.id,
                       "selection is untouched by the refusal — exactly why reading it back is unsafe")
    }

    // MARK: - Item 4: the title

    func testResumingUsesTheResultsTitleRatherThanTheRawConversationID() {
        let store = makeStore()
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Fix the flaky test", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.first?.title, "Fix the flaky test")
    }

    /// Falls back to the id only when the title sanitizes to nothing usable, not merely when it
    /// differs from the id — a tab found by name must come back called that name.
    func testATitleThatSanitizesToNothingFallsBackToTheConversationID() {
        let store = makeStore()
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "   ", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.first?.title, conversation.uuidString)
    }

    // MARK: - Item 3: worktree transcript-directory resolution

    /// The wiring, not the algorithm: with fixture paths like `projectA` that exist nowhere on
    /// disk, `resolvedTranscriptDirectory`'s real default always degenerates to its
    /// single-candidate fallback — so a regression that dropped the closure's result on the
    /// floor and hardcoded `transcriptDirectory: projectPath` would pass every other test in
    /// this file. Injecting a sentinel here is what would catch that: it can only appear on the
    /// filed session if `openConversation` actually plumbs the closure's return value through.
    /// Capturing the arguments the closure is called with is what would catch a *different*
    /// regression — the same wiring silently reading `openConversation`'s own `projectPath`
    /// against, say, the tab's `id` instead of `pinned`.
    func testOpeningWiresTheResolvedTranscriptDirectoryThroughToTheSession() {
        let store = makeStore()
        let conversation = UUID()
        let sentinel = "/sentinel/worktree"
        var seenArguments: (projectPath: String, conversationID: UUID)?

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true }, resolveTranscriptDirectory: { projectPath, conversationID in
            seenArguments = (projectPath, conversationID)
            return sentinel
        })

        XCTAssertEqual(store.repos.first?.sessions.first?.transcriptDirectory, sentinel)
        XCTAssertEqual(seenArguments?.projectPath, projectA.path)
        XCTAssertEqual(seenArguments?.conversationID, conversation)
    }

    /// The algorithm itself, against a real `~/.claude/projects`-shaped fixture built through
    /// the same `ClaudeSession` functions production uses — never a hand-written encoded path,
    /// which could drift silently from the encoding this test exists to exercise.
    func testResolvedTranscriptDirectoryFindsTheWorktreeThatOwnsTheConversation() throws {
        let root = try makeTempDir()
        let projectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        let projectPath = root.appendingPathComponent("proj", isDirectory: true).path
        let worktreePath = (projectPath as NSString)
            .appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true
        )
        let conversation = UUID()
        try write(conversation, workingDirectory: worktreePath, under: projectsRoot)

        let resolved = SessionStore.resolvedTranscriptDirectory(
            projectPath: projectPath, conversationID: conversation, projectsRoot: projectsRoot
        )

        XCTAssertEqual(resolved, worktreePath)
    }

    /// The negative case: a conversation that ran in the project itself, not any worktree, must
    /// resolve to the project path even when a worktree directory exists alongside it.
    func testResolvedTranscriptDirectoryPrefersTheProjectWhenThatIsWhereTheConversationRan() throws {
        let root = try makeTempDir()
        let projectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        let projectPath = root.appendingPathComponent("proj", isDirectory: true).path
        let worktreePath = (projectPath as NSString)
            .appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(
            atPath: worktreePath, withIntermediateDirectories: true
        )
        let conversation = UUID()
        try write(conversation, workingDirectory: projectPath, under: projectsRoot)

        let resolved = SessionStore.resolvedTranscriptDirectory(
            projectPath: projectPath, conversationID: conversation, projectsRoot: projectsRoot
        )

        XCTAssertEqual(resolved, projectPath)
    }

    /// Writes an empty transcript at exactly the path `ClaudeSession.transcriptURL` derives for
    /// `workingDirectory` — the same function `resolvedTranscriptDirectory` itself calls — so
    /// the fixture cannot drift from the encoding rule it is meant to exercise.
    private func write(_ conversation: UUID, workingDirectory: String, under projectsRoot: URL) throws {
        let url = ClaudeSession.transcriptURL(
            sessionID: conversation, workingDirectory: workingDirectory, projectsRoot: projectsRoot
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }
}
