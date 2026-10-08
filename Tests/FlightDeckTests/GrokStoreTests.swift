import XCTest
import FleetKit
@testable import FlightDeck

/// A grok tab through `SessionStore`: answered by key and never by Return, interrupted with
/// Ctrl+C, renamed by typing `/rename`.
@MainActor
final class GrokStoreTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private struct Unavailable: Error {}

    private var home: URL!
    private var cwd: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-store-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        cwd = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func makeStore(activity: SessionActivity, screen: String) async throws -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        let home = self.home!
        store.overrideAdapter(GrokAdapter(home: { home }), for: .grok, account: nil)
        let spy = SpyInjector()
        spy.viewportOverride = try GrokScreenTests.screen(screen)
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        store.answerAbortSink = { _ in }
        guard case .success(let id) = await store.createSession(agent: .grok, in: cwd.path) else {
            XCTFail("a grok tab must be creatable")
            throw Unavailable()
        }
        store.applyRegistryForTesting([id: SessionStatus(activity: activity)])
        spy.events.removeAll()
        return (store, spy, id)
    }

    func testANewTabLaunchesGrokOnItsOwnSessionId() async throws {
        let (store, _, id) = try await makeStore(activity: .idle, screen: "tui-idle.synthetic")
        let session = try XCTUnwrap(store.repos.flatMap(\.sessions).first { $0.id == id })
        XCTAssertEqual(session.agent, .grok)
        let adapter = store.adapter(for: .grok, account: nil)
        XCTAssertEqual(adapter.launchCommand(adapter.binding(for: session), session, .grok(GrokOptions())),
                       "grok -s \(session.pinnedConversationID.uuidString.lowercased())\n")
    }

    /// The card focuses always-approve; allow presses the plain "Yes" row's own key, and no
    /// Return or arrow ever reaches the terminal.
    func testAllowPressesTheYesKeyAndNeverReturn() async throws {
        let (store, spy, id) = try await makeStore(activity: .waiting, screen: "permission-write.synthetic")
        let result = store.answerPrompt(.permission(callID: "call-9", tool: "write", summary: nil),
                                        with: .allow, in: id, token: UUID())
        XCTAssertEqual(result, .dispatched)
        XCTAssertEqual(spy.events, [.key("3")])
    }

    func testAQuestionOptionIsItsKey() async throws {
        let (store, spy, id) = try await makeStore(activity: .waiting, screen: "question.synthetic")
        let open = OpenPrompt.question(callID: "call-q", [PromptQuestion(
            header: nil, question: "Red or blue?", options: [.init(label: "Red"), .init(label: "Blue")])])
        XCTAssertEqual(store.answerPrompt(open, with: .option(index: 1, label: "Blue"), in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.key("2")])
        spy.events.removeAll()
        XCTAssertEqual(store.answerPrompt(open, with: .answers([[AnswerSelection(index: 0, label: "Red")]]),
                                          in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.key("1")])
    }

    func testALabelTheScreenDoesNotShowIsRefusedWithNothingSent() async throws {
        let (store, spy, id) = try await makeStore(activity: .waiting, screen: "question.synthetic")
        let open = OpenPrompt.question(callID: "call-q", [PromptQuestion(
            header: nil, question: "Red or blue?", options: [.init(label: "Green"), .init(label: "Blue")])])
        XCTAssertEqual(store.answerPrompt(open, with: .option(index: 0, label: "Green"), in: id, token: UUID()),
                       .unreadableScreen)
        XCTAssertEqual(spy.events, [])
    }

    func testDenyIsCtrlC() async throws {
        let (store, spy, id) = try await makeStore(activity: .waiting, screen: "permission-write.synthetic")
        XCTAssertEqual(store.answerPrompt(.permission(callID: "c", tool: nil, summary: nil), with: .deny,
                                          in: id, token: UUID()), .dispatched)
        XCTAssertEqual(spy.events, [.control("c")])
    }

    func testInterruptIsCtrlCNotEscape() async throws {
        let (store, spy, id) = try await makeStore(activity: .busy, screen: "tui-busy.synthetic")
        XCTAssertTrue(store.interruptTurn(id))
        XCTAssertEqual(spy.events, [.control("c")])
    }

    func testARenameIsTypedAsOneSlashCommand() async throws {
        let (store, spy, id) = try await makeStore(activity: .idle, screen: "tui-idle.synthetic")
        XCTAssertTrue(store.rename(id, to: "new name"))
        XCTAssertEqual(spy.events, [.text("/rename new name"), .ret])
    }
}
