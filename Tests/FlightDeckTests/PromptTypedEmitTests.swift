import XCTest
@testable import FleetKit
@testable import FlightDeck

/// The Mac side of the phone's "delivered" ghost: `FleetEvent.promptTyped` must fire at the
/// exact moment `flushPromptQueue`'s `onSent` runs — after the text has actually landed in the
/// pty, never earlier — and only for a prompt that WAS typed. See
/// `docs/superpowers/specs/2026-09-06-phone-prompt-delivered-ghost-design.md`.
@MainActor
final class PromptTypedEmitTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// Mirrors `PhonePromptQueueTests.makeStore`: a fresh claude tab, a stub injector, and a
    /// synchronous settle so `onSent` runs on the same call stack as `submitPrompt` unless a
    /// test substitutes its own `injectionSettle` to hold that open.
    private func makeStore(activity: SessionActivity)
        -> (SessionStore, SpyInjector, UUID, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.statusRootOverride = projectsRoot
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, session.pinnedConversationID)
    }

    /// **The typed moment, held open.** `ClaudeTextChannel.submit` sends the kill line
    /// synchronously and then everything else — the text, the Return, and only after both of
    /// those `onSent()` — inside the settle. Substituting `injectionSettle` to just capture the
    /// closure (rather than run it, as `makeStore` does) is what makes "only after the text was
    /// submitted" a provable claim instead of an assumption: nothing downstream of the kill can
    /// have happened until this test calls `settle()` itself.
    func testAPromptTypedIntoAnIdleEmptyBoxEmitsPromptTypedOnceAfterTheTextLands() {
        let (store, spy, id, _) = makeStore(activity: .idle)
        var settle: (() -> Void)?
        store.injectionSettle = { settle = $0 }
        let replicator = attachedReplicator(to: store)
        let token = UUID()

        store.submitPrompt("hi", token: token, to: id)

        XCTAssertEqual(spy.events, [.killLine], "the kill goes out before the settle")
        XCTAssertTrue(replicator.recorded.isEmpty,
                      "nothing was typed yet, so nothing may be reported as typed")

        settle?()

        XCTAssertEqual(spy.sent, ["hi"], "the settle is what actually types it")
        XCTAssertEqual(replicator.recorded, [.promptTyped(id: id, token: token)],
                       "exactly one promptTyped, for the prompt that just landed")
    }

    /// **The other half.** A box holding a MULTI-ROW draft is the case `inject` refuses
    /// outright: Ctrl+U kills one logical line and yank-pop replaces rather than appends, so a
    /// draft spanning rows cannot be taken apart and put back, and `submit` will not type over
    /// one (see `SessionRenameTests.testRenameDefersWhileTheDraftSpansMultipleRows`). So the
    /// prompt sits in `promptQueue` and nothing is ever typed. `onSent` never runs, and neither
    /// must the event that only belongs beside it. (A one-row draft is a different case now — it
    /// is typed around and restored — so this must span rows to genuinely defer.)
    func testAPromptDeferredByAMultiRowDraftBoxNeverEmitsPromptTyped() {
        let (store, spy, id, _) = makeStore(activity: .busy)
        spy.typeDraft(["half a thought", "and the rest of it"])
        spy.events.removeAll()
        let replicator = attachedReplicator(to: store)
        let token = UUID()

        store.submitPrompt("ship it", token: token, to: id)

        // A multi-row draft is refused before any keystroke; the property this test guards is
        // that nothing was SENT, and `.promptTyped` is not emitted.
        XCTAssertTrue(spy.sent.isEmpty, "a draft is not clobbered mid-turn, so nothing was sent")
        XCTAssertNotNil(store.promptQueue[id], "held, waiting for the box to clear")
        XCTAssertFalse(
            replicator.recorded.contains { if case .promptTyped = $0 { return true }
                                           else { return false } },
            "a prompt that was never typed must never be reported as typed"
        )
    }
}
