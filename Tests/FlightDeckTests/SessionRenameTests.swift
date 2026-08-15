import XCTest
@testable import FlightDeck

@MainActor
final class SessionRenameTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// Returns a store whose session is idle and whose injection settles synchronously, so
    /// the tests read as straight-line code.
    private func makeStore() -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider())
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.id, .idle, cwd: tmp.path)])
        spy.events.removeAll()          // ignore anything emitted at creation
        return (store, spy, session.id)
    }

    func testRenameUpdatesTitle() {
        let (store, _, id) = makeStore()
        store.rename(id, to: "my session")
        XCTAssertEqual(store.title(of: id), "my session")
    }

    /// The sidebar is authoritative and updates even when the injection cannot run, so a
    /// deferred rename is never a lost rename.
    func testTitleUpdatesEvenWhenInjectionIsDeferred() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["line one", "line two"])
        store.rename(id, to: "deferred")
        XCTAssertEqual(store.title(of: id), "deferred")
    }

    /// Empty bar: nothing to preserve, so nothing is yanked. Yanking here would paste the
    /// user's *previous* kill into the bar — the failure the spike caught.
    func testRenameIntoAnEmptyBarNeverYanks() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "fresh")
        XCTAssertEqual(spy.events, [.killLine, .text("/rename fresh"), .ret])
    }

    /// A one-row draft is killed before the paste and yanked back after the Return, so the
    /// user gets their text returned intact and it is never submitted.
    func testRenameRestoresASingleRowDraft() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["half-written thought"])
        store.rename(id, to: "named")
        XCTAssertEqual(spy.events, [.killLine, .text("/rename named"), .ret, .yank])
    }

    /// The dangerous case: a hint looks exactly like a draft on screen, but the buffer
    /// behind it is empty, so the kill does nothing and there is nothing to restore.
    func testRenameDoesNotYankWhenTheBarOnlyShowsAHint() {
        let (store, spy, id) = makeStore()
        spy.showHint("Try \"how does RootView.swift work?\"")
        store.rename(id, to: "hinted")
        XCTAssertEqual(spy.events, [.killLine, .text("/rename hinted"), .ret])
    }

    /// Ctrl+U kills one logical line and yank-pop replaces rather than appends, so a draft
    /// spanning rows cannot be taken apart and put back. Wrapping renders the same way and
    /// is equally unsafe, so both defer.
    func testRenameDefersWhileTheDraftSpansMultipleRows() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["line one", "line two"])
        store.rename(id, to: "deferred")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testRenameDefersWhileTheSessionIsBusy() {
        let (store, spy, id) = makeStore()
        store.applyRegistry([1: entry(id, .busy, cwd: tmp.path)])
        spy.events.removeAll()
        store.rename(id, to: "busy")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// `waiting` is a permission prompt or an open dialog. A Return there answers the
    /// dialog rather than submitting a command.
    func testRenameDefersWhileTheSessionIsWaiting() {
        let (store, spy, id) = makeStore()
        store.applyRegistry([1: entry(id, .waiting, cwd: tmp.path)])
        spy.events.removeAll()
        store.rename(id, to: "waiting")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testRenameDefersWhenTheScreenCannotBeRead() {
        let (store, spy, id) = makeStore()
        spy.viewportIsReadable = false
        store.rename(id, to: "unreadable")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The queue drains on the next registry scan, which is what makes deferral temporary
    /// rather than permanent.
    func testDeferredRenameInjectsOnceTheBarClears() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["line one", "line two"])
        store.rename(id, to: "later")
        XCTAssertTrue(spy.events.isEmpty)

        spy.buffer = ""                                     // user submitted or cleared it
        spy.renderedRows = ["❯"]
        store.applyRegistry([1: entry(id, .idle, cwd: tmp.path)])

        XCTAssertEqual(spy.events, [.killLine, .text("/rename later"), .ret])
    }

    /// Renaming twice before the queue drains must inject the *last* name only — the queue
    /// holds one pending rename per tab, not a backlog to replay.
    func testASecondRenameReplacesThePendingOne() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["line one", "line two"])
        store.rename(id, to: "first")
        store.rename(id, to: "second")

        spy.buffer = ""
        spy.renderedRows = ["❯"]
        store.applyRegistry([1: entry(id, .idle, cwd: tmp.path)])

        XCTAssertEqual(spy.sent, ["/rename second"])
        XCTAssertEqual(store.title(of: id), "second")
    }

    /// Once drained, a later registry scan must not inject it a second time.
    func testAFlushedRenameIsNotReinjected() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "once")
        spy.events.removeAll()

        store.applyRegistry([1: entry(id, .idle, cwd: tmp.path)])

        XCTAssertTrue(spy.events.isEmpty)
    }

    func testRenameSanitizesBeforeInjecting() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "  bad\nname  ")
        XCTAssertEqual(store.title(of: id), "badname")
        XCTAssertEqual(spy.sent, ["/rename badname"])
    }

    func testRenameTextCarriesNoLineTerminator() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "my session")
        let text = spy.sent.first ?? ""
        XCTAssertFalse(text.contains("\r"), "a CR inside the paste is inserted, not submitted")
        XCTAssertFalse(text.contains("\n"), "an LF inside the paste is inserted, not submitted")
    }

    func testEmptyRenameIsIgnored() {
        let (store, spy, id) = makeStore()
        let before = store.title(of: id)
        store.rename(id, to: "   ")
        XCTAssertEqual(store.title(of: id), before)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testUnknownSessionIsIgnored() {
        let (store, spy, _) = makeStore()
        store.rename(UUID(), to: "x")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testApplyExternalTitleUpdatesWithoutInjecting() {
        let (store, spy, id) = makeStore()
        store.applyExternalTitle(id, "from claude")
        XCTAssertEqual(store.title(of: id), "from claude")
        XCTAssertTrue(spy.events.isEmpty, "inbound must never inject")
    }

    /// Loop suppression: the transcript line our own rename caused must not bounce back.
    func testApplyExternalTitleIsNoOpWhenUnchanged() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "same")
        spy.events.removeAll()
        store.applyExternalTitle(id, "same")
        XCTAssertEqual(store.title(of: id), "same")
        XCTAssertTrue(spy.events.isEmpty)
    }
}
