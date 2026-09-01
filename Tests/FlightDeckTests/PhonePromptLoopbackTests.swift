import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The seam test for prompts: a real client, a real socket, a real `SessionStore` and a real
/// `inject` at the far end. This is what says a message typed on a phone reaches an agent.
@MainActor
final class PhonePromptLoopbackTests: XCTestCase {
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

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private final class ScriptedCodexTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private func entry(_ sid: UUID, cwd: String) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: .idle, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// A harness whose store can actually be typed into, and a client already attached.
    private func standUp() async throws -> (FleetTestHarness, SpyInjector, FleetClient, NWEndpoint.Port) {
        let harness = FleetTestHarness()
        self.harness = harness
        harness.store.transcriptsRootOverride = projectsRoot
        harness.store.codexIndexURLOverride =
            projectsRoot.appendingPathComponent("session_index.jsonl")
        harness.store.launchFailureReporter = SilentReporter()
        // The fixture's rollout path does not exist on disk; stubbed true so creation reaches
        // success rather than tripping `prepare`'s history-contract check.
        harness.store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedCodexTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        let spy = SpyInjector()
        harness.store.injectorOverride = spy
        harness.store.injectionSettle = { $0() }
        let port = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client
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
        return (harness, spy, client, port)
    }

    /// Answers whichever reply frame lands on `cid`.
    private func answer(_ client: FleetClient, cid: Int) -> (XCTestExpectation, () -> ServerFrame?) {
        let landed = expectation(description: "reply for \(cid)")
        var frame: ServerFrame?
        client.onFrame = { received in
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

    func testAPromptFromARealClientIsTypedIntoTheAgent() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let cid = client.send(.prompt(id: session.id, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(cid) = try XCTUnwrap(frame()) else {
            return XCTFail("an accepted prompt must ack on its own cid")
        }
        XCTAssertEqual(spy.sent, ["ship it"])
    }

    /// The other half, in the same store, so a Mac that refused EVERYTHING could not pass
    /// both tests. It still names the code, because the codes send the reader in opposite
    /// directions — but the code changed, and that IS the feature: a freshly created codex
    /// tab reports no registry status, so it is `not_running` ("not right now") rather than
    /// `unsupported_agent` ("never on this tab"). Codex has a text channel now.
    ///
    /// The spy assertion is unchanged and is the half that guards the user's words: whatever
    /// the code, nothing may be typed into a screen that is not codex's composer.
    func testACodexTabWithNoStatusIsRefusedWithNotRunning() async throws {
        let (harness, spy, client, _) = try await standUp()
        guard case .success(let codexID) =
                await harness.store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()

        let cid = client.send(.prompt(id: codexID, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("a codex tab with no status must be refused, not acked")
        }
        XCTAssertEqual(code, "not_running")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAControlCharacterIsRefusedWithItsOwnCode() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let cid = client.send(
            .prompt(id: session.id, token: UUID(), text: "go\u{1b}[201~ahead")
        )
        let (landed, frame) = answer(client, cid: cid)
        await fulfillment(of: [landed], timeout: 10)

        guard case .err(cid, let code) = try XCTUnwrap(frame()) else {
            return XCTFail("hostile text must be refused on the wire, not typed")
        }
        XCTAssertEqual(code, PromptText.Rejection.controlCharacters.rawValue)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// **The socket survives it**, which is the whole reason `FleetCommand`'s decoder does not
    /// judge its own payload: `onUndecodable` salvages `t == "req"` only, so a throwing `cmd`
    /// decoder would hang up on the phone — and the phone, text still in its composer, would
    /// be one tap from doing it again.
    func testAPromptTheMacRefusesLeavesTheSocketUsable() async throws {
        let (harness, spy, client, _) = try await standUp()
        let session = harness.store.newSession(in: tmp)
        harness.store.applyRegistry([1: entry(session.pinnedConversationID, cwd: tmp.path)])
        spy.events.removeAll()

        let refusedCID = client.send(
            .prompt(id: session.id, token: UUID(),
                    text: String(repeating: "x", count: PromptText.maxCharacters + 1))
        )
        let (refused, _) = answer(client, cid: refusedCID)
        await fulfillment(of: [refused], timeout: 10)

        let goodCID = client.send(.prompt(id: session.id, token: UUID(), text: "ship it"))
        let (landed, frame) = answer(client, cid: goodCID)
        await fulfillment(of: [landed], timeout: 10)

        guard case .ack(goodCID) = try XCTUnwrap(frame()) else {
            return XCTFail("the connection must survive a refused prompt")
        }
        XCTAssertEqual(spy.sent, ["ship it"])
    }
}
