import XCTest
@testable import FlightDeck

@MainActor
final class SessionRenameTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
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

    /// **A rename to the name it already has does nothing at all.**
    ///
    /// Everything past the guard is observable: a `.renamed` event to every paired phone, a
    /// `persist()`, and — for claude — a rename **typed into the live pty**. So re-submitting
    /// the current name is not merely wasted work, it interrupts a running agent to tell it
    /// something it already knows. The sidebar seeds its editor with the current title and the
    /// phone's alert does too, so "open the rename and press Return" is the ordinary way to
    /// reach this, not a corner case.
    ///
    /// The injector is the assertion rather than the title, because the title is what a
    /// no-op cannot change either way: only the spy can tell "left alone" apart from
    /// "rewritten with the same string".
    func testRenamingToTheNameItAlreadyHasTypesNothingIntoTheAgent() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "same name")
        XCTAssertEqual(store.title(of: id), "same name", "the premise: that is its name now")
        spy.events.removeAll()

        let accepted = store.rename(id, to: "same name")

        XCTAssertTrue(accepted,
                      "false is the store's \"this title is unusable\" answer, which "
                          + "FleetService turns into a rejected_title error on the phone — "
                          + "and the session has exactly the name that was asked for")
        XCTAssertEqual(spy.events, [], "nothing was typed at the agent")
    }

    /// Compared AFTER sanitising, so a title that only differs by what the agent's own rule
    /// strips is the same title. Submitting "same name " over "same name" looks like a no-op
    /// to the person doing it, and a guard that compared the raw string would disagree with
    /// them — and then type into the pty to prove it.
    func testATitleThatOnlyDiffersBeforeSanitisingIsStillANoOp() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "same name")
        spy.events.removeAll()

        XCTAssertTrue(store.rename(id, to: "  same name  "))

        XCTAssertEqual(store.title(of: id), "same name")
        XCTAssertEqual(spy.events, [], "nothing was typed at the agent")
    }

    /// The guard must not swallow a real rename that merely starts from the same session.
    func testAGenuineRenameStillReachesTheAgent() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "first")
        spy.events.removeAll()

        XCTAssertTrue(store.rename(id, to: "second"))

        XCTAssertEqual(store.title(of: id), "second")
        XCTAssertFalse(spy.events.isEmpty, "a changed name is still typed at the agent")
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

    /// A one-row draft is typed AROUND, then restored. The kill-probe kills the line to find out
    /// whether the box held anything; it did, so — after the `/rename` is typed and submitted —
    /// the draft is yanked back out of Claude's ring, and Claude queues text typed mid-draft, so
    /// the user's own words reappear behind the rename rather than being lost. An earlier cut
    /// BAILED here, typing nothing, which broke 100% of sidebar renames: an idle box's rotating
    /// placeholder reads as a draft, so every rename bailed.
    func testARenameIntoAOneRowDraftIsTypedThenRestoresTheDraft() {
        let (store, spy, id) = makeStore()
        spy.typeDraft(["half-written thought"])
        store.rename(id, to: "named")
        XCTAssertEqual(spy.events, [.killLine, .text("/rename named"), .ret, .yank],
                       "type the rename, then put the draft straight back")
        XCTAssertTrue(spy.sent.contains("/rename named"), "the rename is typed")
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

    /// **Inverted on purpose.** `inject` no longer gates on activity — a composer box on
    /// screen is what it asks for, and `.busy` draws exactly the composer `.idle` does (see
    /// `ClaudeTextChannel.isComposerBox`). Claude queues text typed mid-turn, so a rename sent
    /// while busy is typed now rather than left pending for an idle tick that a back-to-back
    /// turn might never reach.
    func testARenameSentWhileBusyIsInjectedRatherThanDeferred() {
        let (store, spy, id) = makeStore()
        store.applyRegistry([1: entry(id, .busy, cwd: tmp.path)])
        spy.events.removeAll()
        store.rename(id, to: "busy")
        XCTAssertEqual(spy.sent, ["/rename busy"])
    }

    /// **Rewritten, not merely inverted.** The refusal used to come from the status file's
    /// `.waiting`; now nothing reads activity at all, so what has to refuse is the SCREEN — a
    /// real captured permission dialog, which draws its own `❯` but never the rule immediately
    /// above it that a genuine composer does (see `ClaudeTextChannel.isComposerBox`). The
    /// `.waiting` status is set anyway, for realism, but it is the viewport that does the work.
    func testARenameIntoADialogIsDeferredForWantOfAComposerBox() throws {
        let (store, spy, id) = makeStore()
        store.applyRegistry([1: entry(id, .waiting, cwd: tmp.path)])
        spy.viewportOverride = try TimelineFixtureTests.text("permission-bash.captured", in: "Claude")
        spy.events.removeAll()
        store.rename(id, to: "waiting")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The first half of the bug this branch exists to fix, reached from the store.**
    /// `46c2402`'s coverage was entirely at the predicate (`ClaudeComposerDetectorTests`); this
    /// asserts that a sidebar rename against the screen it newly admits actually reaches the
    /// agent. This session's `composerReadiness` defaults to `.unknown` (see `makeStore`), so
    /// `hasComposerBox` — not the `.live` hook feed — is the operative gate here, exactly the
    /// arm `46c2402` fixed.
    func testARenameIntoTheEchoOnlyScreenReachesTheAgent() throws {
        let (store, spy, id) = makeStore()
        spy.viewportOverride = try TimelineFixtureTests.text("busy-echo-only.captured", in: "Claude")
        spy.events.removeAll()
        store.rename(id, to: "echoed")
        XCTAssertTrue(spy.sent.contains("/rename echoed"), "the rename reaches the agent")
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

    /// **The tab that used to wedge itself, and the replacement that must survive the wedge.**
    ///
    /// `inject` marks the tab mid-injection before the channel is asked and used to release
    /// that mark only from inside the completion the channel ran when text really went out.
    /// A rename superseded while claude repainted never reached that completion, so the mark
    /// stayed set with no path left to clear it: `injectionGate` then refused every later
    /// rename AND every phone prompt for that tab, for the life of the process. Nothing
    /// surfaced — the sidebar kept accepting names, and none of them were ever typed.
    ///
    /// The second assertion is the split that fix must not collapse. Releasing the mark is
    /// unconditional; retiring `pendingRenames[id]` is not, because by the time `stillWanted`
    /// reads false that entry holds the NEWER name — retiring it here would silently drop the
    /// replacement rename, trading a wedged tab for a lost one.
    ///
    /// Driven by holding `injectionSettle`'s continuation rather than running it inline,
    /// which is the only way to genuinely suspend a drive mid-flight — the technique
    /// `AgentTextChannelTests
    /// .testASecondPromptArrivingBetweenCodexsTwoSettleHopsIsQueuedNotTyped` documents.
    func testASupersededRenameReleasesTheMarkAndKeepsItsReplacement() {
        let (store, spy, id) = makeStore()
        var pending: [() -> Void] = []
        store.injectionSettle = { pending.append($0) }

        store.rename(id, to: "first")
        XCTAssertEqual(pending.count, 1, "the kill is out; its settle has not run yet")
        XCTAssertFalse(store.injectionGateAdmitsForTesting(id),
                       "the premise: this tab is marked mid-injection")

        // A second rename lands in that window. The gate refuses to type it now, so it sits
        // in the queue as the newer name — which is what makes the first one superseded.
        store.rename(id, to: "second")
        XCTAssertEqual(store.pendingRenamesForTesting[id], "second")

        pending.removeFirst()()

        XCTAssertTrue(store.injectionGateAdmitsForTesting(id),
                      "the mark is released on the superseded path too, or this tab never "
                          + "accepts another rename or phone prompt again")
        XCTAssertEqual(store.pendingRenamesForTesting[id], "second",
                       "a superseded rename must not retire the replacement that superseded it")
        XCTAssertEqual(spy.sent, [], "the superseded name itself is never typed")

        // The payoff: the next registry scan drains the replacement, which is exactly what a
        // wedged tab could never do.
        store.injectionSettle = { $0() }
        store.applyRegistry([1: entry(id, .idle, cwd: tmp.path)])
        XCTAssertEqual(spy.sent, ["/rename second"])
        XCTAssertNil(store.pendingRenamesForTesting[id], "typed, so retired")
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
