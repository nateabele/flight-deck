import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The whole answering path over a real TLS-PSK socket on loopback: a phone taps a button and
/// the Mac's own terminal moves.
///
/// The same shape as `PhonePromptLoopbackTests`, and it exists for the same reason: every
/// layer below is unit-tested against a fake — `AnswerPromptTests` the store, `PromptServiceTests`
/// the re-derivation, `AnswerFrameCodingTests` the wire — and this is the only test that would
/// catch a frame wired to the wrong handler, or to no handler at all.
///
/// **Every fixture puts a live dialog on the spy's screen.** With no list up,
/// `SessionStore.answerPrompt` refuses on its own, so `spy.events.isEmpty` would be asserting
/// the screen rather than the arm under test — the trap `PromptServiceTests` documents at
/// length. With the list up, a wrongly wired command types.
@MainActor
final class AnswerLoopbackTests: XCTestCase {
    /// Every frame this client received, in order.
    ///
    /// Held for the whole test rather than per command because the assertion that matters is
    /// what did NOT arrive: answering is a write that emits no `FleetEvent`, exactly as
    /// reading a page emits none, so nothing northbound may appear on this socket beyond the
    /// reply itself. `onFrame` is the per-command matcher layered on top.
    private final class FrameLog {
        var frames: [ServerFrame] = []
        var onFrame: ((ServerFrame) -> Void)?
    }

    private var harness: FleetTestHarness?
    private var client: FleetClient?
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness?.service.stop()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// The three options of `Fixtures/Claude/question-single.captured.jsonl`, in its order, so
    /// the labels this test matches on screen are the labels a real dialog carried.
    private static let options = ["Rust", "Go", "Swift"]

    private func askLine(_ id: String) -> String {
        let options = Self.options.map { #"{"label":"\#($0)"}"# }.joined(separator: ",")
        return """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "multiSelect":false,"options":[\(options)]}]}}]}}
        """
    }

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    /// A blocked claude tab behind a real socket, with a client already attached and the
    /// transcript tail substituted — the same seam `PromptServiceTests` substitutes, reached
    /// here through `FleetService` because the service it belongs to is private to it.
    private func standUp(
        tail: @escaping @Sendable (URL, Int) -> [SourceLine]
    ) async throws -> (SpyInjector, FleetClient, FrameLog, UUID) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride =
            projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        harness.store.injectorOverride = spy
        harness.store.injectionSettle = { $0() }
        harness.service.promptTailForTesting = tail
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry(
            [1: entry(session.pinnedConversationID, .waiting, cwd: tmp.path)]
        )
        let port = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client
        let log = FrameLog()
        client.onFrame = { frame in
            log.frames.append(frame)
            log.onFrame?(frame)
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)

        let attached = expectation(description: "attached")
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !harness.service.attachedSlots.isEmpty { attached.fulfill() }
            }
        }
        await fulfillment(of: [attached], timeout: 10)
        observer.invalidate()
        spy.events.removeAll()
        return (spy, client, log, session.id)
    }

    /// Awaits whichever reply frame lands on `cid`. Lifted from `PhonePromptLoopbackTests`,
    /// which needs the same thing for the same reason: the `cid` is the only thing that says
    /// *this* reply answers *this* command.
    private func reply(on cid: Int, in log: FrameLog) -> (XCTestExpectation, () -> ServerFrame?) {
        let landed = expectation(description: "reply for \(cid)")
        var frame: ServerFrame?
        log.onFrame = { received in
            switch received {
            case .ack(cid), .err(cid, _):
                frame = received
                landed.fulfill()
            default:
                break
            }
        }
        return (landed, { frame })
    }

    /// Whether anything northbound rode this socket. See `FrameLog`.
    private func emittedEvents(_ log: FrameLog) -> [ServerFrame] {
        log.frames.filter { if case .event = $0 { return true } else { return false } }
    }

    func testAPhoneAnswersAQuestionAndTheTerminalMoves() async throws {
        let lines = [SourceLine(offset: 0, text: askLine("toolu_A"))]
        let (spy, client, log, id) = try await standUp(tail: { _, _ in lines })
        spy.showOptions(Self.options, selected: 0)

        let cid = client.send(.answerPrompt(
            id: id, token: UUID(), call: "toolu_A",
            answer: .option(index: 2, label: "Swift")
        ))
        let (landed, frame) = reply(on: cid, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(cid) = try XCTUnwrap(frame()) else {
            return XCTFail("an answer the Mac carried out must ack on its own cid")
        }
        // Two rows down and a Return, not one and not three: the index crossed the wire and
        // was counted from where the cursor actually was.
        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1), .ret])
        // The reply and nothing else. Answering changes no fleet state, so it adds no mutation
        // site for `FleetReplicator`'s DEBUG drift check to miss and needed no `FleetEvent`
        // case — the same ruling the history channel makes, and the reason this feature adds
        // exactly one frame to the protocol.
        XCTAssertEqual(emittedEvents(log), [], "answering must emit no fleet event")
    }

    /// **The refusal path, end to end.** One Escape and nothing read — the answer a worried
    /// person sends from a pocket, and the only one that works on a screen this build cannot
    /// parse.
    func testAPhoneDeniesADialogWithOneEscape() async throws {
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]
        let (spy, client, log, id) = try await standUp(tail: { _, _ in lines })
        spy.showOptions(["Yes", "No"], selected: 0)

        let cid = client.send(
            .answerPrompt(id: id, token: UUID(), call: "toolu_BASH", answer: .deny)
        )
        let (landed, frame) = reply(on: cid, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(cid) = try XCTUnwrap(frame()) else {
            return XCTFail("a denial the Mac carried out must ack on its own cid")
        }
        XCTAssertEqual(spy.events, [.escape], "deny is one key event and no screen read")
        XCTAssertEqual(emittedEvents(log), [], "answering must emit no fleet event")
    }

    /// **The socket survives a refusal, and the pair is judged in one store.**
    ///
    /// `FleetSocketServer.onUndecodable` salvages `t == "req"` and nothing else, so a `cmd`
    /// this build cannot parse takes the connection down — and a phone with the same tap still
    /// under its thumb would be one tap from doing it again. So the refusal is not enough on
    /// its own: a second, valid answer goes over the SAME socket afterwards and has to land.
    /// A test that stopped at the `err` would pass against a Mac that hung up immediately
    /// after sending it.
    ///
    /// And the store that refuses one answer is the store that carries out the other, so a
    /// Mac that refused everything could not pass both halves.
    func testAStaleAnswerIsRefusedAndTheSocketStaysUsable() async throws {
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]
        let (spy, client, log, id) = try await standUp(tail: { _, _ in lines })
        // The dialog IS up, and it is readable. The refusal below therefore has to come from
        // the re-derivation refusing a call that is not the open one — a build that dropped
        // the comparison would find a screen it can drive perfectly well and press Return.
        spy.showOptions(["Yes", "No"], selected: 0)

        let refusedCID = client.send(
            .answerPrompt(id: id, token: UUID(), call: "toolu_GONE", answer: .allow)
        )
        let (refused, refusal) = reply(on: refusedCID, in: log)
        await fulfillment(of: [refused], timeout: 10)

        guard case .err(refusedCID, let code) = try XCTUnwrap(refusal()) else {
            return XCTFail("a stale answer must be refused on its own cid, not acked")
        }
        // Not merely "an error": `unhandled` is what an unwired arm answers, and either that
        // or `unknown_session` passing for this would mean the answer never reached the
        // re-derivation at all.
        XCTAssertEqual(code, "prompt_changed")
        XCTAssertTrue(spy.events.isEmpty, "nothing may be typed at a dialog nobody read")

        let goodCID = client.send(
            .answerPrompt(id: id, token: UUID(), call: "toolu_BASH", answer: .allow)
        )
        let (landed, frame) = reply(on: goodCID, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(goodCID) = try XCTUnwrap(frame()) else {
            return XCTFail("the connection must survive a refused answer")
        }
        XCTAssertEqual(spy.events, [.ret], "row 0 is already focused, so allow is one Return")
    }
}
