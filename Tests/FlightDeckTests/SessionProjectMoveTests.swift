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

    /// The registry drives it: a resume that changes cwd moves the tab.
    func testRegistryCwdChangeMovesTheTab() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/moved")])

        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }

    func testRegistryCanRepinAndMoveInOneTick() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/moved")])

        XCTAssertEqual(store.pinnedConversationID(of: a.id), resumed)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }

    /// `workingDirectory` is an input to `ClaudeSession.transcriptURL`, so a move that left
    /// the watcher alone would keep tailing the transcript under the *old* encoded project
    /// directory — renames and sub-agent counts stop arriving and nothing looks broken.
    func testMoveRepointsTheWatcherAtTheNewProjectsTranscript() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/moved", isDirectory: true))

        XCTAssertEqual(
            store.watchedTranscriptURL(of: a.id),
            ClaudeSession.transcriptURL(
                sessionID: a.pinnedConversationID,
                workingDirectory: "/moved",
                projectsRoot: store.projectsRoot
            )
        )
    }

    /// The cwd-alone path — a `/resume` into the same conversation's new project, or a
    /// plain `cd` — never goes through `repin`, so the move is the only thing that can
    /// rebuild the watcher.
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
                projectsRoot: store.projectsRoot
            )
        )
    }

    /// Repin and move in one tick: the repin already rebuilds from the registry row's cwd,
    /// which is this same destination, so the move must not start a second watcher — and
    /// the one watcher has to be on the new conversation *in* the new project.
    func testRepinAndMoveInOneTickLeaveOneWatcherOnTheNewTranscript() {
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
                projectsRoot: store.projectsRoot
            )
        )
    }

    /// The same pair straddling two ticks, which is what production does: the repin's title
    /// read is a whole-file load, so the move lands while it is still outstanding. The
    /// move's watcher is the newer one; the late completion must leave it alone rather than
    /// replace it with one built from the directory the tab has already left.
    func testAMoveDuringATitleReadKeepsTheWatcherOnTheNewProject() {
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
                projectsRoot: store.projectsRoot
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
    }
}
