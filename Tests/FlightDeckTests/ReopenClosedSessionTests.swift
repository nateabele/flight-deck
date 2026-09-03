// Tests/FlightDeckTests/ReopenClosedSessionTests.swift
import XCTest
@testable import FlightDeck

/// ⌘⇧T: bringing back what was just closed, browser-style.
///
/// The rebuild deliberately mirrors `restore` — same resume command, same worktree-gone
/// fallback, same codex deferral — so most of what is asserted here is that a reopened tab is
/// indistinguishable from a restored one, and that it lands back where it was.
@MainActor
final class ReopenClosedSessionTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private let projectA = URL(fileURLWithPath: "/w/a", isDirectory: true)
    private let projectB = URL(fileURLWithPath: "/w/b", isDirectory: true)

    private func registryRow(
        _ conversation: UUID, pid: pid_t = 1, cwd: String
    ) -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: conversation, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    private func makeStore(provider: CapturingProvider? = nil) -> SessionStore {
        let store = SessionStore(provider: provider, persistence: nil)
        store.titleResolver = { _, _, done in done(nil) }
        store.launchFailureReporter = SilentReporter()
        return store
    }

    /// Reopening is only worth anything if the tab comes back attached to the conversation it
    /// had. The id and the pin are what `--resume` is built from, so they are the assertion.
    func testReopeningBringsTheClosedTabBackOnItsOwnConversation() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.closeSession(session.id)

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [session.id])
        XCTAssertEqual(
            store.repos.first?.sessions.first?.pinnedConversationID, session.pinnedConversationID
        )
    }

    func testTheReopenedTabResumesRatherThanStartingAFreshConversation() {
        let provider = CapturingProvider()
        let store = makeStore(provider: provider)
        let session = store.newSession(in: projectA)
        store.closeSession(session.id)

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(
            provider.configs.last?.initialInput,
            ClaudeSession.resumeCommand(sessionID: session.pinnedConversationID)
        )
    }

    func testReopeningLandsTheTabBackOnItsOwnRow() {
        let store = makeStore()
        store.newSession(in: projectA)
        let middle = store.newSession(in: projectA)
        store.newSession(in: projectA)
        store.closeSession(middle.id)

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.firstIndex { $0.id == middle.id }, 1)
    }

    func testTheReopenedTabBecomesTheSelectedOne() {
        let store = makeStore()
        let first = store.newSession(in: projectA)
        let second = store.newSession(in: projectA)
        store.closeSession(first.id)
        XCTAssertEqual(store.selectedSessionID, second.id)

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.selectedSessionID, first.id)
    }

    /// The browser behaviour the shortcut is borrowed from: keep pressing and keep walking
    /// back.
    func testRepeatedReopensWalkBackThroughSeveralCloses() {
        let store = makeStore()
        let first = store.newSession(in: projectA)
        let second = store.newSession(in: projectA)
        store.closeSession(first.id)
        store.closeSession(second.id)

        store.reopenLastClosed(directoryExists: { _ in true })
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [second.id])

        store.reopenLastClosed(directoryExists: { _ in true })
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [first.id, second.id])
    }

    func testReopeningWithNothingClosedChangesNothing() {
        let store = makeStore()
        let session = store.newSession(in: projectA)

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [session.id])
    }

    /// A tab closed while its worktree existed and reopened after it was deleted has to be
    /// rebuilt against its project directory instead — the same rule `restore` applies, and
    /// for the same reason: `--resume` run somewhere claude never wrote finds no conversation.
    func testATabWhoseTranscriptDirectoryIsGoneComesBackInItsProject() {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.applyRegistry([1: registryRow(session.pinnedConversationID, cwd: "/w/a")])
        store.applyRegistry([1: registryRow(session.pinnedConversationID,
                                            cwd: "/w/a/.claude/worktrees/gone")])
        XCTAssertEqual(store.repos.first?.sessions.first?.transcriptDirectory,
                       "/w/a/.claude/worktrees/gone")
        store.closeSession(session.id)

        store.reopenLastClosed(directoryExists: { $0 == "/w/a" })

        XCTAssertEqual(store.repos.first?.sessions.first?.transcriptDirectory, "/w/a")
    }

    // MARK: - Closed projects

    func testReopeningAClosedProjectBringsBackEveryOneOfItsTabsInOrder() {
        let store = makeStore()
        let first = store.newSession(in: projectA)
        let second = store.newSession(in: projectA)
        store.newSession(in: projectB)
        store.closeProject(store.repos[0].id)

        store.reopenLastClosed(directoryExists: { _ in true })

        let reopened = store.repos.first { $0.url.path == "/w/a" }
        XCTAssertEqual(reopened?.sessions.map(\.id), [first.id, second.id])
    }

    func testAReopenedProjectReturnsToItsSidebarPositionAndCollapseState() {
        let store = makeStore()
        store.newSession(in: projectA)
        store.newSession(in: projectB)
        let a = store.repos[0].id
        store.setCollapsed(true, forProjectAt: a)

        store.closeProject(a)
        XCTAssertEqual(store.repos.map(\.url.path), ["/w/b"])

        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos.map(\.url.path), ["/w/a", "/w/b"])
        XCTAssertEqual(store.repos.first?.isCollapsed, true)
    }

    /// Closing a project is one entry, not one per tab — so undoing it is one press, and the
    /// press after that finds an empty stack rather than the same project's tabs again.
    func testAClosedProjectCostsOneReopenRatherThanOnePerTab() {
        let store = makeStore()
        store.newSession(in: projectA)
        store.newSession(in: projectA)
        store.closeProject(store.repos[0].id)

        store.reopenLastClosed(directoryExists: { _ in true })
        let afterFirst = store.repos.flatMap(\.sessions).map(\.id)
        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(afterFirst.count, 2)
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.id), afterFirst,
                       "the project's tabs must not be reopenable a second time")
    }

    // MARK: - Codex

    /// Codex's resume text is deferred exactly the way `restore` defers it: `binding(for:)` is
    /// a pure read of the pin and cannot tell a live thread from one deleted while the tab was
    /// closed, so nothing may be typed until the app-server has settled it.
    func testAReopenedCodexTabSettlesItsThreadBeforeTypingAnything() async {
        let provider = CapturingProvider()
        let store = makeStore(provider: provider)
        let transport = ScriptedTransport()
        // The fixture's rollout path does not exist on disk; stubbed true so creation reaches
        // success rather than tripping `prepare`'s history-contract check.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: transport), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        let injector = SpyInjector()
        store.injectorOverride = injector
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: "/w/a") else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        store.closeSession(id)
        injector.events.removeAll()

        store.reopenLastClosed(directoryExists: { _ in true })
        XCTAssertEqual(provider.configs.last?.initialInput, "",
                       "nothing may be typed at a codex tab before its thread is known to exist")
        await store.codexRestoreTask?.value

        XCTAssertEqual(injector.sent.last, "codex resume 01a01269-baa6-7493-8d15-8fa21bcb602b")
    }

    /// The lazy half of the same rule: reopening a claude tab must not spawn `codex`.
    func testReopeningAClaudeTabNeverAsksForCodex() async {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        store.closeSession(session.id)

        store.reopenLastClosed(directoryExists: { _ in true })
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.codexServerRequestsForTesting, 0)
    }

    // MARK: - Reopen by id

    /// The phone's reopen is ⌘⇧T aimed at one entry, and it must land the tab back among
    /// its siblings rather than at the bottom.
    func testReopeningByIDRebuildsTheTabAtItsRecordedIndex() {
        let store = makeStore()
        _ = store.newSession(in: projectA)
        let target = store.newSession(in: projectA)
        _ = store.newSession(in: projectA)
        XCTAssertEqual(store.repos.first?.sessions[1].id, target.id, "fixture assumption")

        store.closeSession(target.id)
        let selectedBeforeReopen = store.selectedSessionID
        store.reopenClosedSession(id: target.id, directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.count, 3)
        XCTAssertEqual(store.repos.first?.sessions[1].id, target.id, "not appended")
        // `reopenClosedSession` is the phone's own entry point (see its doc comment), so under
        // the client-selection rule it must not move the desk off whatever `closeSession` left
        // selected — that is the behaviour change this method exists to pin at the store level;
        // `FleetServiceTests` pins the same rule over the real socket.
        XCTAssertEqual(store.selectedSessionID, selectedBeforeReopen,
                       "a phone reopen must not move the desk's selection")
    }

    /// The consumed entry must leave the stack, or ⌘⇧T would insert a second tab carrying an
    /// id the sidebar already holds.
    func testReopeningByIDConsumesTheEntrySoCommandShiftTPopsTheNextOne() {
        let store = makeStore()
        let older = store.newSession(in: projectA)
        let newer = store.newSession(in: projectA)

        store.closeSession(older.id)
        store.closeSession(newer.id)
        // Reach past the top of the stack — what a menu does and ⌘⇧T cannot.
        store.reopenClosedSession(id: older.id, directoryExists: { _ in true })
        store.reopenLastClosed(directoryExists: { _ in true })

        let ids = store.repos.first?.sessions.map(\.id) ?? []
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "no duplicate tab ids")
        XCTAssertEqual(Set(ids), [older.id, newer.id])
        XCTAssertTrue(store.recentlyClosedSessions.isEmpty)
    }

    func testReopeningAnUnknownIDDoesNothing() {
        let store = makeStore()
        let session = store.newSession(in: projectA)

        store.reopenClosedSession(id: UUID(), directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [session.id])
    }

    /// A tab reopened into a collapsed project would come back invisible — `SidebarRow.rows`
    /// renders only the header for a collapsed repo. The rule `reopenLastClosed` follows.
    func testReopeningByIDUncollapsesItsProject() throws {
        let store = makeStore()
        let session = store.newSession(in: projectA)
        let project = try XCTUnwrap(store.repos.first).id

        store.closeSession(session.id)
        store.setCollapsed(true, forProjectAt: project)
        store.reopenClosedSession(id: session.id, directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.isCollapsed, false)
    }

    final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"reopened","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }
}
