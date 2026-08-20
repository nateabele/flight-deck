import XCTest
@testable import FlightDeck

@MainActor
final class SessionProjectMoveTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String,
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    func testMoveRelocatesTheSessionToAnExistingProject() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        _ = store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))

        let b = store.repos.first { $0.url.path == "/b" }
        XCTAssertEqual(b?.sessions.map(\.id).contains(a.id), true)
        XCTAssertEqual(store.repos.count, 2)
    }

    func testMoveCreatesTheDestinationProjectWhenAbsent() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.repos.count, 2)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/new" }?.sessions.map(\.id), [a.id]
        )
    }

    /// A project with no sessions is a legitimate sidebar state. Matching `closeSession`,
    /// moving out does not prune the source.
    func testMoveLeavesAnEmptiedSourceProjectStanding() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        let source = store.repos.first { $0.url.path == "/a" }
        XCTAssertNotNil(source)
        XCTAssertTrue(source!.sessions.isEmpty)
    }

    func testMoveUpdatesTheSessionsWorkingDirectory() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(
            store.repos.flatMap(\.sessions).first { $0.id == a.id }?.workingDirectory, "/new"
        )
    }

    func testMoveKeepsTheSelection() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.selectedSessionID, a.id)
    }

    func testMoveToTheSameProjectIsANoOp() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/a", isDirectory: true))

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// The registry still drives a move — but only into a project that is already open,
    /// which is the resume-into-another-project case §7 of the pinning design describes. A
    /// destination nothing has opened is the worktree case and moves nothing; see
    /// `testRegistryCwdChangeIntoAnUnopenedDirectoryDoesNotMoveTheTab`.
    func testRegistryCwdChangeMovesTheTabIntoAnAlreadyOpenProject() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        // Opened first: the registry may file a tab under an existing project, never
        // conjure one.
        _ = store.newSession(in: URL(fileURLWithPath: "/moved", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/moved")])

        XCTAssertEqual(store.repos.count, 2)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id).contains(a.id),
            true
        )
    }

    func testRegistryCanRepinAndMoveInOneTick() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        // As above: the move half of this tick needs its destination already open.
        _ = store.newSession(in: URL(fileURLWithPath: "/moved", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/moved")])

        XCTAssertEqual(store.pinnedConversationID(of: a.id), resumed)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id).contains(a.id),
            true
        )
    }

    /// The worktree bug. `EnterWorktree` puts `claude`'s cwd at
    /// `<project>/.claude/worktrees/<name>` — a directory change *within* a project, not a
    /// resume into another one. Treating every cwd change as a move called `moveSession`,
    /// which creates a repo when none matches, so a phantom project named after the worktree
    /// appeared in the sidebar and took the tab with it. Seen live in
    /// `~/.claude/sessions/39551.json`.
    func testRegistryCwdChangeIntoAnUnopenedDirectoryDoesNotMoveTheTab() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a/.claude/worktrees/w")])

        XCTAssertEqual(store.repos.count, 1, "a cwd matching no open project must create none")
        XCTAssertEqual(store.repos.first?.url.path, "/a")
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// …and the transcript watcher has to follow that cwd all the same. `claude` encodes its
    /// live `process.cwd()` into the project directory name under `~/.claude/projects`, so
    /// inside a worktree it genuinely writes somewhere else (verified on disk). Declining the
    /// move without splitting the transcript directory off would leave the tab tailing a file
    /// nothing writes to — title sync and sub-agent counts stop, and nothing looks broken.
    func testRegistryCwdChangeIntoAnUnopenedDirectoryStillFollowsTheTranscript() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a/.claude/worktrees/w")])

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: "/a/.claude/worktrees/w",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// `ExitWorktree` walks the cwd back out again, which is the ordinary end of a worktree
    /// session. The tab must come out of it still watched, and watching its own project's
    /// transcript — the round trip is where a retarget that forgot to update
    /// `transcriptDirectory` would strand it on the worktree's.
    ///
    /// `watchedSessionIDs` is keyed by tab, so it pins "still watched, and only this tab" and
    /// nothing more: an orphaned `TranscriptWatcher` left running by a retarget that skipped
    /// its `stop()` is invisible to that seam by construction (see the seam's own doc). The
    /// URL assertion below is the one with teeth here.
    func testAWorktreeRoundTripLeavesOneWatcherOnTheProjectsTranscript() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a/.claude/worktrees/w")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])

        XCTAssertEqual(store.repos.count, 1, "the round trip must not have conjured a project")
        XCTAssertEqual(store.watchedSessionIDs, [a.id])
        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: "/a",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    // MARK: A quiet tick is not evidence

    /// Drives a tab into a worktree that is *also* an open project — the state the user's
    /// sidebar is already in, since this change deliberately does not migrate the phantom
    /// projects its predecessor created and `restore` re-seeds them from `snapshot.projects`.
    private func storeWithATabWatchingAnOpenWorktreeProject()
        -> (SessionStore, Session, String) {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let worktree = "/a/.claude/worktrees/w"

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: worktree)])
        // Opened after the retarget, which is the only ordering that leaves the tab filed
        // under /a while its transcript directory names an open project.
        _ = store.newSession(in: URL(fileURLWithPath: worktree, isDirectory: true))
        XCTAssertEqual(
            store.repos.first?.sessions.map(\.id), [a.id], "precondition: still filed under /a"
        )
        return (store, a, worktree)
    }

    /// A tick with no rows at all — `claude` exited, or this is the first tick after launch
    /// before it registers — reports no cwd, and must therefore move nothing.
    ///
    /// `ConversationPin.resolve` echoes the caller's fallback when nothing matched, and that
    /// fallback is the tab's *transcript* directory. Before the split the echo was the tab's
    /// own project, so it always compared equal and the move branch was immune by
    /// construction; the split made the echo divergent, and reading it as a reported cwd
    /// refiles the tab into its worktree on no evidence whatsoever.
    func testATickWithNoRowsDoesNotRefileTheTabIntoItsWorktreeProject() {
        let (store, a, _) = storeWithATabWatchingAnOpenWorktreeProject()

        store.applyRegistry([:])

        XCTAssertEqual(store.repos.first?.url.path, "/a")
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// The same trap through the anchored branch: a live row that simply omits its `cwd`.
    /// An empty `cwd` is the registry saying nothing, not saying "somewhere new".
    func testALiveRowWithNoCwdDoesNotRefileTheTabIntoItsWorktreeProject() {
        let (store, a, _) = storeWithATabWatchingAnOpenWorktreeProject()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "")])

        XCTAssertEqual(store.repos.first?.url.path, "/a")
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// The control: the same quiet tick with the worktree *not* open as a project. Passing
    /// here and failing above is what tells the two apart — it is the destination being an
    /// open project, not the tick itself, that used to move the tab.
    func testAQuietTickMovesNothingWhenTheWorktreeIsNotAProject() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a/.claude/worktrees/w")])
        store.applyRegistry([:])

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    // MARK: A repin carries the directory with it

    /// `repin` has to *store* the directory it watched, not merely watch it. Nothing else
    /// observes that field directly, so this walks the cwd back out again: the return tick
    /// can only be recognised as a change — and retarget the watcher home — if the repin
    /// recorded where it went.
    func testARepinStoresItsDirectorySoALaterReturnRetargetsBack() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/a/.claude/worktrees/w")])
        store.applyRegistry([1: row(resumed, cwd: "/a")])

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: resumed, workingDirectory: "/a", projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// And the stored directory reaches the snapshot, so a relaunch resumes the tab where
    /// the resumed conversation actually is rather than where it started life.
    func testARepinsDirectoryIsPersisted() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.titleResolver = { _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/a/.claude/worktrees/w")])

        XCTAssertEqual(
            persistence.stored?.sessions.first(where: { $0.id == a.id })?.transcriptDirectory,
            "/a/.claude/worktrees/w"
        )
    }

    /// The inverse of `testMoveRepointsTheWatcherAtTheNewProjectsTranscript`, which this
    /// replaces. That test was right while `workingDirectory` was the input to
    /// `ClaudeSession.transcriptURL`: a move changed where `claude` was assumed to be
    /// writing, so the watcher had to follow. The field split ended that — the transcript
    /// path now comes from `transcriptDirectory` alone, and filing a tab under another
    /// project tells us nothing about `claude`'s cwd. Repointing here would aim the watcher
    /// at a transcript that need not exist, and would fight `retarget`, which is fed by the
    /// registry and is the only thing that actually knows.
    func testAnExplicitMoveLeavesTheWatcherOnTheTranscriptItWasTailing() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/moved", isDirectory: true))

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: "/a",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// The cwd-alone path — a `/resume` into the same conversation's new project, or a
    /// plain `cd` — never goes through `repin`, so `retarget` is the only thing that can
    /// rebuild the watcher for it. It has to, whether or not the destination is a project
    /// Flight Deck knows about: `claude` is writing there either way.
    func testRegistryCwdChangeRepointsTheWatcher() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/moved")])

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: "/moved",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// A resume that also reports a new cwd, in one tick. `repin` stores that directory and
    /// rebuilds the watcher from it, which is why `retarget` is the `else` of that branch
    /// rather than a second independent one: running both would start two watchers for one
    /// tab, and in production the repin's watcher arrives only after an async title read, so
    /// the second would be the one the late completion is written to defer to.
    func testARepinCarryingANewCwdLeavesOneWatcherOnTheNewTranscript() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/moved")])

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: resumed,
                workingDirectory: "/moved",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// The same pair straddling two ticks, which is what production does: the repin's title
    /// read is a whole-file load, so the cwd change lands while it is still outstanding. The
    /// retarget's watcher is the newer one; the late completion must leave it alone rather
    /// than replace it with one built from the directory the tab has already left.
    func testARetargetDuringATitleReadKeepsTheNewerWatcher() {
        let store = makeStore()
        var pending: [(String?) -> Void] = []
        store.titleResolver = { _, done in pending.append(done) }
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])  // anchor
        store.applyRegistry([1: row(resumed, cwd: "/a")])                 // /resume, read pending
        store.applyRegistry([1: row(resumed, cwd: "/moved")])             // cwd follows, later tick
        pending.first?("a title that arrives after the move")

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: resumed,
                workingDirectory: "/moved",
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }

    /// `claude` reports `process.cwd()` with symlinks already resolved; Flight Deck stores
    /// whatever the folder picker handed it, which `standardizedFileURL` never resolves.
    /// Compared raw, a symlinked project looks like a different project on the very first
    /// registry tick: the tab moves into a duplicate and leaves an empty ghost behind.
    func testASymlinkedProjectIsNotMovedIntoADuplicate() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let real = root.appendingPathComponent("fd-real-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("fd-link-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? fm.removeItem(at: link)
            try? fm.removeItem(at: real)
        }

        let store = makeStore()
        // The tab is filed under the symlink; the row reports the resolved path.
        let a = store.newSession(in: link)

        store.applyRegistry([
            1: row(a.pinnedConversationID, cwd: real.resolvingSymlinksInPath().path),
        ])

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.url.path, link.path)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])

        // The other half of the same symlink story, and the guard on the *transcript*
        // comparison: it is deliberately raw, because `encodedProjectDirName` encodes the cwd
        // string byte for byte, so the link path and the resolved path name two different
        // transcript files and only the resolved one is ever written. Making the two
        // comparisons "consistent" — the obvious tidy-up — silently reinstates a project
        // opened through a symlink watching a file `claude` never touches.
        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: real.resolvingSymlinksInPath().path,
                projectsRoot: store.transcriptsRoot(forAccount: nil)
            )
        )
    }
}
