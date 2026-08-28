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
        store.titleResolver = { _, done in done(nil) }
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
            title: "ignored", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), [session.id],
                       "no second tab may be filed for a conversation already open")
        XCTAssertEqual(store.selectedSessionID, session.id)
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

        store.openConversation(.resume(
            conversationID: conversation.uuidString, projectPath: projectA.path,
            title: "Chat", transcriptDirectory: projectA.path
        ), directoryExists: { _ in true })

        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab under the wrong login is worse than no tab")
        XCTAssertEqual(reporter.reported, [.accountMissing("Claude")])
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
}
