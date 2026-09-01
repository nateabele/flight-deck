import XCTest
@testable import FlightDeck

/// Sidebar → codex. The direction `SessionStore.rename`'s `.codex` arm exists to serve, and
/// the one nothing covered: every `thread/name/set` assertion in this suite belongs to
/// `prepare`, so a rename that never reached codex would have left all of them green.
///
/// It matters that this is silent when it breaks. The arm is `Task { try? await … }` —
/// deliberately fire-and-forget, because a refused rename must not block the user's edit or
/// pop an alert — so the only evidence a rename never landed is codex's name diverging from
/// the sidebar's, which the next `CodexNameWatcher` tick then papers over by pushing codex's
/// stale name back UP into the sidebar. Up-propagation working is exactly what makes
/// down-propagation failing hard to see.
@MainActor
final class CodexRenameTests: XCTestCase {
    private var retained: [AnyObject] = []
    private var projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-rename-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectsRoot)
        retained.removeAll()
        super.tearDown()
    }

    func testRenamingACodexTabSendsThreadNameSetWithTheSanitizedTitle() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)

        XCTAssertTrue(store.rename(tab.id, to: "renamed from the sidebar"))
        try await settle(transport, untilMethodCountExceeds: 4)

        XCTAssertEqual(transport.methods.last, "thread/name/set",
                       "the sidebar's rename must reach codex, not stop at the local title")
        XCTAssertEqual(transport.lastRenameName, "renamed from the sidebar")
        XCTAssertEqual(transport.lastRenameThreadID, transport.threadID.lowercased(),
                       "renaming must target the thread codex named, not the tab's own id")
    }

    /// The local title changes either way — that is the method's stated promise — so a test
    /// that only checked the title would pass against a completely unwired `.codex` arm.
    func testTheLocalTitleAloneIsNotEvidenceTheAgentWasTold() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)

        XCTAssertTrue(store.rename(tab.id, to: "sidebar only"))
        try await settle(transport, untilMethodCountExceeds: 4)

        XCTAssertEqual(store.repos.flatMap(\.sessions).first?.title, "sidebar only")
        XCTAssertTrue(transport.methods.contains("thread/name/set"),
                      "title updated locally but codex never told — the exact silent divergence "
                      + "this arm exists to prevent")
    }

    /// `rename` returns true and sends nothing when the name is unchanged: re-sending is not
    /// merely wasted work, it interrupts a running agent to tell it what it already knows.
    func testRenamingToTheSameNameTellsCodexNothing() async throws {
        let (store, transport) = try await makeCodexTab()
        let tab = try XCTUnwrap(store.repos.flatMap(\.sessions).first)
        let creationCalls = transport.methods.count

        XCTAssertTrue(store.rename(tab.id, to: tab.title),
                      "an unchanged name is accepted, not rejected")
        try await yieldAWhile()

        XCTAssertEqual(transport.methods.count, creationCalls,
                       "no name/set for a name codex already has")
    }

    // MARK: - Fixtures

    private func makeCodexTab() async throws -> (SessionStore, RenameTransport) {
        let provider = StubProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl` — `runtime(for: .codex)` still
        // builds a real `CodexStack` whose watcher would otherwise tail the user's home.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")

        let transport = RenameTransport()
        retained.append(transport)
        // `/r/t.jsonl` does not exist; stubbed true so creation exercises the real four-call
        // sequence rather than `prepare`'s history-contract guard.
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: transport), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )

        let result = await store.createSession(agent: .codex, in: projectsRoot.path)
        guard case .success = result else {
            throw XCTSkip("codex tab creation failed in fixture: \(result)")
        }
        return (store, transport)
    }

    /// The rename arm is `Task { … }`, so the call returns before the request is written.
    /// Polls rather than sleeping a fixed interval, and never uses `wait(for:)` — on a
    /// `@MainActor` test that deadlocks against the very actor the Task needs.
    private func settle(
        _ transport: RenameTransport,
        untilMethodCountExceeds count: Int,
        ticks: Int = 200
    ) async throws {
        for _ in 0..<ticks {
            if transport.methods.count > count { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func yieldAWhile(ticks: Int = 50) async throws {
        for _ in 0..<ticks {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Records the rename payload as well as the method, so a test cannot pass on a
    /// `thread/name/set` that carried the wrong thread or the wrong name.
    private final class RenameTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        private(set) var lastRenameName: String?
        private(set) var lastRenameThreadID: String?
        let threadID = "01a01705-bd49-7b70-a0a1-4514d4bda5dd"

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            if method == "thread/name/set", let params = obj["params"] as? [String: Any] {
                lastRenameName = params["name"] as? String
                lastRenameThreadID = params["threadId"] as? String
            }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(threadID)","path":"/r/t.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }
}
