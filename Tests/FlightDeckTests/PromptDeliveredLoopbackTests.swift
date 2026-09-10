import Network
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// The whole channel, end to end: a real `FleetClient` sends `FleetCommand.prompt` to a real
/// `FleetService` over `service.loopbackEndpoint()`, gets the `ack`, and then receives
/// `FleetEvent.promptTyped` for the same token once the Mac actually types it — the wire Tasks
/// 1-4 built, proven connected rather than merely unit-tested at each end. See
/// `docs/superpowers/specs/2026-09-06-phone-prompt-delivered-ghost-design.md`.
@MainActor
final class PromptDeliveredLoopbackTests: XCTestCase {
    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    private var harness: FleetTestHarness!
    private var client: FleetClient!

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: projectsRoot)
        projectsRoot = nil
        super.tearDown()
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    func testPromptTypedFollowsTheAckOverTheWire() async throws {
        // A real `FleetService`, wired to its own real replicator before the tab exists, so
        // the session-creation and status events below are recorded — mirrors
        // `TimelineLoopbackTests.standUp`, which creates its session after the harness for the
        // same reason.
        harness = FleetTestHarness()

        // The tab injectable exactly as `PromptTypedEmitTests.makeStore` builds one: a stub
        // injector standing in for the pty, idle status, an empty box, and a synchronous
        // settle so `submitPrompt` -> `flushPromptQueue` -> `inject`'s `onSent` actually fires
        // on this call stack rather than 120ms later on a run-loop turn this test does not
        // drive.
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        harness.store.statusRootOverride = projectsRoot
        let spy = SpyInjector()
        harness.store.injectorOverride = spy
        harness.store.injectionSettle = { $0() }
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry(
            [1: entry(session.pinnedConversationID, .idle, cwd: tmp.path)]
        )

        try await harness.start()

        var gotAck = false
        let typed = expectation(description: "promptTyped")
        let token = UUID()
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            switch frame {
            case .ack:
                gotAck = true
            case .event(_, .promptTyped(let id, let t)) where id == session.id && t == token:
                typed.fulfill()
            default:
                break
            }
        }
        client.onReady = { [weak self] in
            guard let self else { return }
            _ = self.client.send(.prompt(id: session.id, token: token, text: "hi"))
        }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [typed], timeout: 15)

        XCTAssertTrue(gotAck, "the ack must arrive before/with the typed event")
        XCTAssertEqual(spy.sent, ["hi"], "the wire delivered the text the phone actually sent")
    }
}
