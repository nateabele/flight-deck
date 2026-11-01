import FleetKit
import XCTest
@testable import FlightDeck

/// Real app service, real per-tab child processes, real native sockets and the store's
/// real input adapter. Only the terminal is a spy: no model, account login or GUI is used.
@MainActor
final class PeerMessagingLoopbackTests: XCTestCase {
    private final class ScriptedCodex: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            if object["method"] as? String == "thread/start" {
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/tmp","path":"/r/x.jsonl"}}}"#)
            } else { onLine?(#"{"id":\#(id),"result":{}}"#) }
        }
    }
    private var root: URL!
    private var store: SessionStore!
    private var harness: FleetTestHarness!
    private var peers: PeerMessagingService!
    private var spy: SpyInjector!
    private var first: Session!, second: Session!

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/tmp/fd-peer-loop-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = root.appendingPathComponent("transcripts")
        store.promptLifecycleSink = { _ in }
        spy = SpyInjector(); store.injectorOverride = spy; store.injectionSettle = { $0() }
        first = store.newSession(in: root)
        second = store.newSession(in: root)
        store.applyRegistry([
            1: .init(pid: 1, sessionID: first.id, activity: .idle, waitingFor: nil, startedAt: 1, cwd: root.path, procStart: "a"),
            2: .init(pid: 2, sessionID: second.id, activity: .idle, waitingFor: nil, startedAt: 1, cwd: root.path, procStart: "b"),
        ])
        harness = FleetTestHarness(store: store)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = checkout.appendingPathComponent("DerivedData/Build/Products/Debug/flightdeck-peer")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        peers = PeerMessagingService(store: store, preferences: harness.preferences, executable: helper,
            stateDirectory: root.appendingPathComponent("peers"))
        harness.service.peerMessaging = peers
        _ = try await peers.request(.init(operation: "receive"), caller: .session(first.id))
        _ = try await peers.request(.init(operation: "receive"), caller: .session(second.id))
        spy.events.removeAll()
    }
    override func tearDown() async throws {
        peers?.stop(); harness?.service.stop()
        peers = nil; harness = nil; store = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func waitFor(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "peer delivery never reached its observable endpoint")
    }
    func testNativeDeliveryPreservesDraftAndIsRetiredOnlyAfterTyping() async throws {
        let address = try XCTUnwrap(peers.endpointAddress(for: second.id))
        spy.typeDraft(["my unfinished draft"])
        let sent = try await peers.request(.init(operation: "send", target: address, message: "LOOPBACK_NATIVE_PAYLOAD"), caller: .session(first.id))
        XCTAssertTrue(sent.contains("sent"))
        try await waitFor { self.spy.sent.contains(where: { $0.contains("LOOPBACK_NATIVE_PAYLOAD") }) }
        XCTAssertEqual(spy.buffer, "my unfinished draft")
        let text = try XCTUnwrap(spy.sent.first(where: { $0.contains("LOOPBACK_NATIVE_PAYLOAD") }))
        XCTAssertTrue(text.contains("not from your user"))
        try await waitFor {
            let path = self.root.appendingPathComponent("peers/\(self.second.id.uuidString.lowercased())/events.jsonl")
            return ((try? String(contentsOf: path, encoding: .utf8)) ?? "").contains("host_accepted")
        }
    }
    func testAQueuedMessageDoesNotTypeIntoAPermissionDialog() async throws {
        let address = try XCTUnwrap(peers.endpointAddress(for: second.id))
        spy.showOptions(["Allow", "Deny"])
        _ = try await peers.request(.init(operation: "send", target: address, message: "DO_NOT_TYPE_IN_DIALOG"), caller: .session(first.id))
        let deadline = Date().addingTimeInterval(5)
        var inbox = ""
        while !inbox.contains("DO_NOT_TYPE_IN_DIALOG"), Date() < deadline {
            inbox = try await peers.request(.init(operation: "receive"), caller: .session(second.id))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(inbox.contains("DO_NOT_TYPE_IN_DIALOG"))
        XCTAssertTrue(spy.events.isEmpty, "a peer message must never answer a dialog")
        let journal = try String(contentsOf: root.appendingPathComponent("peers/\(second.id.uuidString.lowercased())/events.jsonl"), encoding: .utf8)
        XCTAssertFalse(journal.contains("host_accepted"), "queued is not typed")
    }
    func testAuthenticatedCallerCannotImpersonateAnotherTab() async throws {
        do {
            _ = try await peers.request(.init(operation: "send", target: "unused", message: "bad", source: second.id), caller: .session(first.id))
            XCTFail("a model supplied sender ID must not replace its tab token")
        } catch { XCTAssertTrue(String(describing: error).contains("impersonate")) }
    }
    func testNonClaudeTabsAutomaticallyBecomeDiscoverableNativePeers() async throws {
        store.codexIndexURLOverride = root.appendingPathComponent("session_index.jsonl")
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: ScriptedCodex()), rolloutExists: { _ in true }), for: .codex, account: nil)
        guard case .success(let id) = await store.createSession(agent: .codex, in: root.path) else {
            return XCTFail("scripted Codex session must be created without launching a real model")
        }
        peers.synchronize()
        try await waitFor { self.peers.endpointAddress(for: id) != nil }
        let listing = try await peers.request(.init(operation: "list"), caller: .session(first.id))
        XCTAssertTrue(listing.contains(id.uuidString.lowercased()))
        XCTAssertTrue(listing.contains("codex"))
        _ = try await peers.request(.init(operation: "send", target: id.uuidString, message: "NATIVE_CODEX_TAB"), caller: .session(first.id))
        let deadline = Date().addingTimeInterval(5)
        var inbox = ""
        while !inbox.contains("NATIVE_CODEX_TAB"), Date() < deadline {
            inbox = try await peers.request(.init(operation: "receive"), caller: .session(id))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(inbox.contains("NATIVE_CODEX_TAB"))
        XCTAssertFalse(spy.sent.contains(where: { $0.contains("NATIVE_CODEX_TAB") }), "a Claude-looking screen is not a Codex composer")
    }
    func testClosingTabStopsItsNativeEndpoint() async throws {
        let address = try XCTUnwrap(peers.endpointAddress(for: second.id))
        let socket = try PeerJSON.path(address)
        store.closeSession(second.id)
        peers.synchronize()
        try await waitFor { !FileManager.default.fileExists(atPath: socket) }
        XCTAssertNil(peers.endpointAddress(for: second.id))
    }
    func testUnexpectedHelperExitIsSupervisedEvenWhenTabStaysIdle() async throws {
        let address = try XCTUnwrap(peers.endpointAddress(for: second.id))
        let pid = try XCTUnwrap(Int32(((try PeerJSON.path(address) as NSString).lastPathComponent as NSString).deletingPathExtension))
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        try await waitFor {
            guard let replacement = self.peers.endpointAddress(for: self.second.id) else { return false }
            return replacement != address
        }
    }
    func testPeerRequestOverExistingAuthenticatedControlSocket() async throws {
        let path = root.appendingPathComponent("control.sock")
        try await harness.service.startLocal(at: path)
        let token = ControlEnvironment.token(for: first.id, secret: harness.service.controlSecret)
        let client = FleetClient(localCaller: token)
        defer { client.disconnect() }
        let replied = expectation(description: "peer receive reply")
        client.onReady = { _ = client.send(.peer(.init(operation: "receive"))) }
        client.onFrame = { frame in
            if case .peer(_, let json) = frame { XCTAssertTrue(json.contains("cursor")); replied.fulfill() }
        }
        client.connect(toLocal: path.path, lastSeq: 0)
        await fulfillment(of: [replied], timeout: 5)
    }
}
