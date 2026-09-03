import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// `prompt.abort` over a real TLS-PSK socket: the gate `FleetService` owns before the store is
/// ever touched, and the dispatch the store owns after it.
///
/// The same shape as `AnswerLoopbackTests`, for the same reason — every layer below is
/// unit-tested against a fake (`SessionStoreAbortTests` the store, `AnswerFrameCodingTests` the
/// wire) and this is the only test that would catch the command wired to the wrong handler, or
/// the preference gate placed on the wrong side of the store call.
@MainActor
final class AbortPromptLoopbackTests: XCTestCase {
    private final class FrameLog {
        var frames: [ServerFrame] = []
        var onFrame: ((ServerFrame) -> Void)?
    }

    private final class LifecycleRecorder {
        var records: [PromptLifecycleRecord] = []
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

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    /// A blocked claude tab behind a real socket, client attached, transcript tail substituted
    /// — the same fixture `AnswerLoopbackTests` stands up, so a wrongly wired arm would be
    /// caught the same way.
    private func standUp(
        allowsAbort: Bool
    ) async throws -> (SpyInjector, FleetClient, FrameLog, LifecycleRecorder, UUID) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.preferences.allowsBlockedPromptAbort = allowsAbort
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride =
            projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        harness.store.injectorOverride = spy
        harness.store.injectionSettle = { $0() }
        let lines = [SourceLine(offset: 0, text: bashLine("toolu_BASH"))]
        harness.service.promptTailForTesting = { _, _ in lines }
        // Two routes write a `.aborted` record — `FleetService`'s own early gate, through
        // `prompts.lifecycleSink`, and `SessionStore.abortPrompt`, through `promptLifecycleSink`
        // — because the gate refuses before the store is ever reached and so cannot leave the
        // record to it. Both are pointed at the same recorder so a test sees one merged order
        // regardless of which route produced a given record.
        let recorder = LifecycleRecorder()
        harness.service.promptLifecycleForTesting = { recorder.records.append($0) }
        harness.store.promptLifecycleSink = { recorder.records.append($0) }
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
        recorder.records.removeAll()
        return (spy, client, log, recorder, session.id)
    }

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

    private func emittedEvents(_ log: FrameLog) -> [ServerFrame] {
        log.frames.filter { if case .event = $0 { return true } else { return false } }
    }

    /// **The gate, proven from the outside.** The dialog is up and perfectly drivable — spy
    /// shows a live list — so a refusal here can only be the preference gate, not a screen the
    /// build could not read anyway. And the store must never be reached: no Escape, no
    /// `.duplicate` on a retried token, nothing.
    func testAbortIsRefusedWhenThePreferenceIsOff() async throws {
        let (spy, client, log, recorder, id) = try await standUp(allowsAbort: false)
        spy.showOptions(["Yes", "No"], selected: 0)

        let cid = client.send(.abortPrompt(id: id, token: UUID()))
        let (landed, frame) = reply(on: cid, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("abort must be refused, not carried out, while the preference is off")
        }
        XCTAssertEqual(code, "abort_disabled")
        XCTAssertTrue(spy.events.isEmpty, "the store must never be reached")
        XCTAssertEqual(
            recorder.records, [PromptLifecycleRecord(session: id, event: .aborted(code: "abort_disabled"))],
            "the refusal is recorded even though the store never saw the attempt"
        )
        XCTAssertEqual(emittedEvents(log), [])
    }

    /// **The dispatch, end to end.** One Escape and nothing read — the same answer `deny`
    /// sends, now reachable with no call id at all.
    func testAbortSendsOneEscapeWhenThePreferenceIsOn() async throws {
        let (spy, client, log, recorder, id) = try await standUp(allowsAbort: true)
        spy.showOptions(["Yes", "No"], selected: 0)

        let cid = client.send(.abortPrompt(id: id, token: UUID()))
        let (landed, frame) = reply(on: cid, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(cid) = try XCTUnwrap(frame()) else {
            return XCTFail("an abort the Mac carried out must ack on its own cid")
        }
        XCTAssertEqual(spy.events, [.escape], "abort is one key event and no screen read")
        XCTAssertEqual(
            recorder.records, [PromptLifecycleRecord(session: id, event: .aborted(code: nil))],
            "a dispatched abort is recorded with no error code"
        )
        XCTAssertEqual(emittedEvents(log), [], "aborting must emit no fleet event")
    }

    /// **A replayed token, over the socket.** `AnswerDispatch.duplicate.errorCode` is `nil` —
    /// "a retry that lands is an answer that landed", the same ruling `answerPrompt` makes — so
    /// the second send must `ack` exactly like the first, without a second Escape reaching the
    /// spy. A build that mapped `.duplicate` to an error here would tell a phone its own retry
    /// had failed when the Mac had already carried it out.
    func testAReplayedTokenAcksWithoutASecondEscape() async throws {
        let (spy, client, log, recorder, id) = try await standUp(allowsAbort: true)
        spy.showOptions(["Yes", "No"], selected: 0)
        let token = UUID()

        let firstCID = client.send(.abortPrompt(id: id, token: token))
        let (firstLanded, firstFrame) = reply(on: firstCID, in: log)
        await fulfillment(of: [firstLanded], timeout: 10)
        guard case .ack(firstCID) = try XCTUnwrap(firstFrame()) else {
            return XCTFail("the first abort on a fresh token must be carried out")
        }
        recorder.records.removeAll()

        let secondCID = client.send(.abortPrompt(id: id, token: token))
        let (secondLanded, secondFrame) = reply(on: secondCID, in: log)
        await fulfillment(of: [secondLanded], timeout: 10)
        guard case .ack(secondCID) = try XCTUnwrap(secondFrame()) else {
            return XCTFail("a replayed token is a landed retry, not a failure")
        }
        XCTAssertEqual(spy.events, [.escape], "the replay must not type a second Escape")
        XCTAssertEqual(
            recorder.records, [PromptLifecycleRecord(session: id, event: .aborted(code: nil))],
            "a duplicate still logs an attempt, with no error code"
        )
    }

    /// **The store's own refusal, reached through the socket.** Proves the wiring past the
    /// preference gate: `store.abortPrompt(...).errorCode` has to make it all the way to
    /// `.err(cid:code:)`, not just the early gate the first two tests exercise. An unknown
    /// session id is the simplest such refusal to trigger without racing the store's activity.
    func testAnUnknownSessionIsRefusedByTheStoreOverTheSocket() async throws {
        let (spy, client, log, recorder, _) = try await standUp(allowsAbort: true)
        spy.showOptions(["Yes", "No"], selected: 0)
        let unknown = UUID()

        let cid = client.send(.abortPrompt(id: unknown, token: UUID()))
        let (landed, frame) = reply(on: cid, in: log)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("an unknown session must be refused by the store, not acked")
        }
        XCTAssertEqual(code, "unknown_session")
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertEqual(
            recorder.records,
            [PromptLifecycleRecord(session: unknown, event: .aborted(code: "unknown_session"))],
            "recorded, even though the id names no session"
        )
    }
}
