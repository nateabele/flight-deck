// Tests/FlightDeckTests/OpenConversationTests.swift
import XCTest
import IntakeKit
import FleetKit
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
        var defaultFontSize: Float { 12 }
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
            title: "ignored", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
            title: "ignored", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
            title: "Resumed", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.isCollapsed, false)
    }

    /// ⌘K on a tab that is already open: selecting a row the collapsed project hides would
    /// land the desk on a tab with no visible sidebar row, so the project springs open.
    func testSelectingAnAlreadyOpenTabInACollapsedProjectUncollapsesIt() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        let elsewhere = store.newSession(in: projectB)
        store.setCollapsed(true, forProjectAt: store.repos[0].id)
        store.selectSession(elsewhere.id)

        store.openConversation(.select(session.id))

        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.repos.first { $0.url == projectA }?.isCollapsed, false)
    }

    /// The same, through the in-store already-live guard rather than `plan`'s `.select`.
    func testResumingAnAlreadyOpenConversationInACollapsedProjectUncollapsesIt() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.newSession(in: projectB)
        store.setCollapsed(true, forProjectAt: store.repos[0].id)

        store.openConversation(.resume(
            conversationID: session.pinnedConversationID.uuidString, projectPath: projectA.path,
            title: "Again", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.repos.first { $0.url == projectA }?.isCollapsed, false)
    }

    /// A client's `.select` moves nothing on the desk, so it has no hidden row to reveal —
    /// springing the project open would change the sidebar for a jump that never happened there.
    func testAClientSelectLeavesACollapsedProjectCollapsed() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.setCollapsed(true, forProjectAt: store.repos[0].id)

        store.openConversation(.select(session.id), selecting: false)

        XCTAssertEqual(store.repos.first?.isCollapsed, true)
    }

    // MARK: - Re-adding a project that left the sidebar

    func testOpeningAConversationInAProjectThatLeftTheSidebarBringsItBack() {
        let store = makeStore()
        let conversation = UUID()

        store.openConversation(.addProjectThenResume(
            projectPath: projectB.path, conversationID: conversation.uuidString,
            title: "New chat", agent: .claude, workingDirectory: projectB.path, transcriptPath: ""
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
            projectPath: projectA.path, conversationID: "", title: "fd", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
            projectPath: projectB.path, conversationID: "", title: "fd", agent: .claude, workingDirectory: projectB.path, transcriptPath: ""
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
            projectPath: projectB.path, conversationID: "", title: "fd", agent: .claude, workingDirectory: projectB.path, transcriptPath: ""
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
        preferences.preferences.accounts = [chosen]
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: .account(chosen.id)])
        ]
        let store = makeStore(preferences: preferences)
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
        preferences.preferences.accounts = []
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: .account(UUID())])
        ]
        let store = makeStore(preferences: preferences)
        let reporter = SpyReporter()
        store.launchFailureReporter = reporter
        let conversation = UUID()

        let opened = store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
        preferences.preferences.accounts = []
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.claude: .account(UUID())])
        ]
        let store = makeStore(preferences: preferences)
        store.launchFailureReporter = SpyReporter()
        let unrelated = store.newSession(in: projectB)
        store.selectSession(unrelated.id)
        let conversation = UUID()

        let opened = store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
            title: "Fix the flaky test", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
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
            title: "   ", agent: .claude, workingDirectory: projectA.path, transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.first?.title, conversation.uuidString)
    }

    // MARK: - The result's own working directory and transcript path

    /// The corpus walk records the literal directory a conversation ran in on the
    /// `TranscriptHit` itself now, rather than `openConversation` re-deriving it from the
    /// project alone — so a resume must land the *result's* directory on the tab, not
    /// silently collapse a worktree conversation back onto its project root.
    func testResumeCarriesTheStoredWorkingDirectoryNotTheProjectRoot() {
        let store = makeStore()
        let conversation = UUID()
        let worktree = (projectA.path as NSString).appendingPathComponent(".claude/worktrees/feature")

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .claude, workingDirectory: worktree, transcriptPath: ""
        ), directoryExists: { _ in true })

        let session = store.repos.first?.sessions.first
        XCTAssertEqual(session?.transcriptDirectory, worktree)
        XCTAssertEqual(session?.workingDirectory, projectA.path,
                       "the sidebar project stays the project root even when the agent works in a worktree")
    }

    /// The other half: a plan whose working directory is genuinely unknown — the index has no
    /// row for that conversation at all, on either the desk's or the phone's path to this
    /// method — falls back to the project root rather than filing a tab with an empty
    /// `transcriptDirectory`, which `resumeExisting`'s `directoryExists` guard would otherwise
    /// have to fail on before recovering. This is a last resort, not the normal outcome for a
    /// name match: `AppDelegate.enrichedForActivation` and `FleetService.openConversation` each
    /// look the conversation up in the index and fill its real working directory and transcript
    /// path into the plan before this method ever sees it, whenever the index can locate it.
    func testResumeFallsBackToTheProjectRootWhenTheResultsWorkingDirectoryIsUnknown() {
        let store = makeStore()
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .claude, workingDirectory: "", transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.first?.transcriptDirectory, projectA.path)
    }

    // MARK: - Codex results resolve as codex, not claude

    /// Codex's shape with the transport removed, so a resume through this method never spawns
    /// or hangs waiting on a real app-server. Mirrors `CodexStatusRoutingTests`' stub —
    /// duplicated rather than shared, the same way `CapturingProvider` is duplicated across
    /// every store test file here, so no test file depends on another's fixtures.
    private struct StubCodexAdapter: AgentAdapter {
        static let id: AgentID = .codex
        nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: .codex) }
        static let textChannel: AgentTextChannel? = nil
        static let renameTyping: AgentRenameTyping? = nil
        static let dialogDriver: AgentDialogDriver? = nil
        static let negotiatesIdentity = true
        static let needsRuntimeStart = true
        static let hasStatusRegistry = false
        nonisolated static func sanitizedTitle(_ raw: String) -> String? {
            CodexAdapter.sanitizedTitle(raw)
        }
        nonisolated static func title(fromTranscriptAt url: URL) -> String? {
            CodexAdapter.title(fromTranscriptAt: url)
        }
        nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
            CodexAdapter.timelineItems(inLine: line, at: offset)
        }
        nonisolated static let homeMarkerFile = CodexAdapter.homeMarkerFile
        nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
            CodexAdapter.identity(fromHomeData: data)
        }
        static let openPromptReader: AgentOpenPromptReader? = CodexAdapter.openPromptReader
        static let searchCorpus: AgentSearchCorpus? = CodexAdapter.searchCorpus
        static let turnRecovery: AgentTurnRecovery? = CodexAdapter.turnRecovery
        let thread: UUID

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            AgentBinding(conversationID: thread, transcriptURL: nil)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }
        func launchCommand(_ b: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_ b: AgentBinding, _ s: Session, _ o: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation {
            LoginInvocation(command: "", inject: nil)
        }
    }

    /// A live codex tab, built the same way `CodexStatusRoutingTests.makeCodexTab` does: through
    /// the real `createSession` negotiation, against a stubbed adapter and runtime rather than a
    /// hand-assembled `Session` — so its `pinnedConversationID` is genuinely the thread the
    /// stub's `prepare` names, the same value the already-open guard below has to match.
    private func makeCodexTab(in store: SessionStore, thread: UUID) async throws -> UUID {
        store.overrideAdapter(StubCodexAdapter(thread: thread), for: .codex, account: nil)
        store.overrideRuntime(FakeAgentRuntime(), for: .codex, account: nil)
        let result = await store.createSession(agent: .codex, in: projectA.path)
        guard case .success(let id) = result else {
            throw XCTSkip("createSession failed: \(result)")
        }
        return id
    }

    /// The already-open guard `openConversation` keeps for itself must catch a codex tab too,
    /// not only claude's — codex refuses a second writer on one thread outright rather than
    /// merely tolerating it badly, so filing a second tab here is not just wasteful, it is a
    /// resume that never lands.
    func testALiveCodexTabIsSelectedRatherThanResumedTwice() async throws {
        let store = makeStore()
        let thread = UUID()
        let tab = try await makeCodexTab(in: store, thread: thread)

        store.openConversation(.resume(
            conversationID: thread.uuidString, projectPath: projectA.path,
            title: "ignored", agent: .codex, workingDirectory: projectA.path, transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), [tab],
                       "no second tab may be filed for a codex thread already open")
        XCTAssertEqual(store.selectedSessionID, tab)
    }

    /// The account resolved for a resume must be the result's own agent's account, not
    /// claude's unconditionally — one layer up from the title and the transcript directory.
    func testOpenConversationResolvesTheCodexAccountNotTheClaudeOne() {
        let chosen = AgentAccount(agent: .codex, displayName: "codex-work", home: AgentID.codex.builtInHome)
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.accounts = [chosen]
        preferences.preferences.storedProjectSettings = [
            projectA.path: ProjectSettings(accounts: [.codex: .account(chosen.id)])
        ]
        let store = makeStore(preferences: preferences)
        store.overrideAdapter(StubCodexAdapter(thread: UUID()), for: .codex, account: chosen.id)
        store.overrideRuntime(FakeAgentRuntime(), for: .codex, account: chosen.id)
        let conversation = UUID()

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", agent: .codex, workingDirectory: projectA.path, transcriptPath: ""
        ), directoryExists: { _ in true })

        XCTAssertEqual(
            store.repos.first?.sessions.first(where: { $0.pinnedConversationID == conversation })?.accountID,
            chosen.id
        )
    }
}
