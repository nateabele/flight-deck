import XCTest
@testable import FlightDeck

@MainActor
final class SessionRenameTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    /// Records text and Return in one ordered transcript, because their *order* is the
    /// contract: Return must arrive after the paste closes, not inside it.
    final class SpyInjector: TextInjecting {
        enum Event: Equatable {
            case text(String)
            case ret
        }

        var events: [Event] = []
        /// Convenience for assertions that only care about the text payloads.
        var sent: [String] { events.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }

        func sendText(_ text: String) { events.append(.text(text)) }
        func sendReturn() { events.append(.ret) }
    }

    private func makeStore() -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider())
        let spy = SpyInjector()
        store.injectorOverride = spy
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        spy.events.removeAll()          // ignore anything emitted at creation
        return (store, spy, session.id)
    }

    func testRenameUpdatesTitle() {
        let (store, _, id) = makeStore()
        store.rename(id, to: "my session")
        XCTAssertEqual(store.title(of: id), "my session")
    }

    /// The command text carries NO line terminator, and the Returns are separate key events.
    /// `sendText` is a paste in libghostty; with bracketed-paste mode on (Claude Code
    /// enables it) a terminator inside the text arrives between `ESC[200~`/`ESC[201~` and is
    /// inserted as literal content instead of submitting.
    ///
    /// The *leading* Return is the fix for a half-typed input bar: without it the pasted
    /// command is appended to whatever the user already had there.
    func testRenameSendsReturnThenTextThenReturn() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "my session")
        XCTAssertEqual(spy.events, [.ret, .text("/rename my session"), .ret])
    }

    func testRenameTextCarriesNoLineTerminator() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "my session")
        let text = spy.sent.first ?? ""
        XCTAssertFalse(text.contains("\r"), "a CR inside the paste is inserted, not submitted")
        XCTAssertFalse(text.contains("\n"), "an LF inside the paste is inserted, not submitted")
    }

    func testRenameSanitizesBeforeInjecting() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "  bad\nname  ")
        XCTAssertEqual(store.title(of: id), "badname")
        XCTAssertEqual(spy.events, [.ret, .text("/rename badname"), .ret])
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
