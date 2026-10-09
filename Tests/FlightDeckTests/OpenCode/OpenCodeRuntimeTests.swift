import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

/// Routing in `OpenCodeRuntime`: signals keyed by OpenCode session reach the right tab, and a
/// subagent's child session is folded onto its root. Driven through `handle(_:)` directly, with
/// a server that is not running, so no stream connects and nothing is spawned.
@MainActor
final class OpenCodeRuntimeTests: XCTestCase {
    private var runtime: OpenCodeRuntime!
    private var events: [AgentEvent] = []
    private var token: AttachmentToken!
    private var mirror: URL!

    override func setUp() async throws {
        runtime = OpenCodeRuntime(server: FakeOpenCodeServer(running: false))
        mirror = OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_root.jsonl")
        let binding = AgentBinding(
            conversationID: OpenCodeIdentity.conversationID(forSession: "ses_root"), transcriptURL: mirror
        )
        token = runtime.attach(binding, for: UUID()) { [weak self] in self?.events.append($0) }
    }

    override func tearDown() async throws {
        runtime.detach(token)
    }

    private func send(_ signals: OpenCodeSignal...) {
        runtime.handle(OpenCodeEventBatch(directory: "/w", signals: signals))
    }

    private func asked(_ id: String) -> String {
        #"{"id":"\#(id)","kind":"permission","permission":"bash","type":"prompt.asked"}"#
    }

    private func resolved(_ id: String) -> String {
        #"{"id":"\#(id)","outcome":"once","type":"prompt.resolved"}"#
    }

    func testTheRootsOwnSignalsReachTheTab() {
        send(.activity(session: "ses_root", .busy), .title(session: "ses_root", "Renamed"),
             .turnAborted(session: "ses_root"))
        XCTAssertEqual(events, [.activity(.busy), .title("Renamed"), .turnAborted])
    }

    /// Flight Control's contested detection: a `BLOCKED:` line the agent writes reaches the tab
    /// as `.outputSignals`, read off the freshly mirrored assistant message — the same channel
    /// claude, codex and grok report it on. Never the user's message, which quotes the marker.
    func testABlockedLineInAMirroredReplyIsReported() async throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_sig", directory: "/w", title: "t")
        try db.message("msg_u", session: "ses_sig", created: 1, data: ["role": "user"])
        try db.part("prt_u", message: "msg_u", session: "ses_sig", data: ["type": "text", "text": "say BLOCKED: if stuck"])
        try db.message("msg_a", session: "ses_sig", created: 2, data: ["role": "assistant", "time": ["completed": 3]])
        try db.part("prt_a", message: "msg_a", session: "ses_sig", data: ["type": "text", "text": "Tried it.\nBLOCKED: tests need a database"])
        let runtime = OpenCodeRuntime(server: FakeOpenCodeServer(running: false, databaseURL: db.url))
        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: OpenCodeIdentity.conversationID(forSession: "ses_sig"),
                                   transcriptURL: OpenCodeFixtures.temporaryDirectory().appendingPathComponent("ses_sig.jsonl"))
        let token = runtime.attach(binding, for: UUID()) { seen.append($0) }
        defer { runtime.detach(token) }
        let deadline = Date().addingTimeInterval(5)
        while !seen.contains(where: { if case .outputSignals = $0 { true } else { false } }), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reported: [[AgentOutputSignal]] = seen.compactMap { event in
            if case .outputSignals(let signals) = event { return signals }
            return nil
        }
        XCTAssertEqual(reported, [[.blocked("tests need a database")]])
    }

    func testAStrangersSignalsAreIgnored() {
        send(.activity(session: "ses_other", .busy), .title(session: "ses_other", "x"))
        XCTAssertEqual(events, [])
    }

    /// OpenCode keeps reporting the blocked turn `busy`; an open request must win until it
    /// closes.
    func testAnOpenRequestHoldsTheTabWaiting() {
        send(.activity(session: "ses_root", .waiting), .prompt(session: "ses_root", line: asked("per_1")))
        send(.activity(session: "ses_root", .busy))
        XCTAssertEqual(events.last, .activity(.waiting))
        send(.activity(session: "ses_root", .busy), .prompt(session: "ses_root", line: resolved("per_1")))
        XCTAssertEqual(events.last, .activity(.busy))
    }

    /// Pending requests live only in the server's memory, so the mirror is the one durable
    /// record the phone and `PromptService` can derive an open prompt from — a subagent's
    /// included, under the ROOT's mirror.
    func testRequestsAreWrittenToTheRootsMirror() throws {
        send(.created(session: "ses_child", parent: "ses_root"))
        send(.prompt(session: "ses_root", line: asked("per_1")),
             .prompt(session: "ses_child", line: asked("per_c")))
        let lines = try String(contentsOf: mirror, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("per_1"))
        XCTAssertTrue(lines[1].contains("per_c"))
    }

    func testASubagentsRequestMakesTheParentTabWait() {
        send(.created(session: "ses_child", parent: "ses_root"))
        send(.activity(session: "ses_child", .waiting), .prompt(session: "ses_child", line: asked("per_c")))
        XCTAssertEqual(events.last, .activity(.waiting))
        send(.prompt(session: "ses_child", line: resolved("per_c")))
        XCTAssertEqual(events.last, .activity(.busy))
    }

    func testRunningSubagentsAreCounted() {
        send(.created(session: "ses_a", parent: "ses_root"), .created(session: "ses_b", parent: "ses_root"))
        send(.activity(session: "ses_a", .busy), .activity(session: "ses_b", .busy))
        XCTAssertEqual(events.last, .subagentCount(2))
        send(.activity(session: "ses_a", .idle))
        XCTAssertEqual(events.last, .subagentCount(1))
    }

    func testAGrandchildIsFoldedOntoTheRootToo() {
        send(.created(session: "ses_child", parent: "ses_root"), .created(session: "ses_grand", parent: "ses_child"))
        send(.activity(session: "ses_grand", .waiting))
        XCTAssertEqual(events.last, .activity(.waiting))
    }

    func testAChildsOwnTurnEndingIsNotTheTabs() {
        send(.created(session: "ses_child", parent: "ses_root"))
        events = []
        send(.turnEnded(session: "ses_child"), .title(session: "ses_child", "Explore"),
             .apiError(session: "ses_child", SessionAPIError(kind: "APIError")))
        XCTAssertEqual(events, [])
    }

    func testTheTurnEndingClearsOpenRequestsAndSubagents() {
        send(.created(session: "ses_a", parent: "ses_root"), .activity(session: "ses_a", .busy))
        send(.prompt(session: "ses_root", line: asked("per_1")))
        send(.turnEnded(session: "ses_root"))
        XCTAssertEqual(Array(events.suffix(3)), [.subagentCount(0), .activity(.idle), .turnEnded])
        send(.activity(session: "ses_root", .busy))
        XCTAssertEqual(events.last, .activity(.busy), "no request is left holding the tab")
    }

    func testANewSettledMessageClearsAStaleError() {
        send(.apiError(session: "ses_root", SessionAPIError(status: 503, kind: "APIError", isTransient: true)))
        send(.messageSettled(session: "ses_root"))
        XCTAssertEqual(events.last, .apiError(nil))
    }
}

final class OpenCodePreferencesTests: XCTestCase {
    func testTheBuiltInHomeIsTheXDGDataRootUnderAnyRoot() {
        let root = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        XCTAssertEqual(AgentID.opencode.builtInHome(under: root).path, "/tmp/home/.local/share")
        XCTAssertEqual(AgentID.claude.builtInHome(under: root).path, "/tmp/home/.claude")
    }

    func testSiblingHomesAreDiscoveredBesideTheBuiltIn() throws {
        let root = OpenCodeFixtures.temporaryDirectory()
        let work = root.appendingPathComponent(".local/share-work/opencode", isDirectory: true)
        let empty = root.appendingPathComponent(".local/share-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let found = AccountDirectory.discover(in: root, agent: .opencode).map(\.lastPathComponent)
        XCTAssertEqual(found, ["share-work"], "a sibling without an opencode directory is not a home")
    }

    /// The agent list gains OpenCode at the END — once it is tab-ready — so every existing
    /// shortcut keeps its agent. Accounts are NOT re-seeded for an install that migrated before
    /// OpenCode existed (the rule grok and gemini follow): its tabs run in the built-in home
    /// until the person adds or scans for an account.
    func testAnExistingInstallGainsOpenCodeAtTheEnd() {
        var preferences = Preferences()
        preferences.storedAgents = [
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
            AgentSettings(id: .claude, options: .claude(FlagSet())),
        ]
        preferences.migrateAgentsIfNeeded()
        XCTAssertEqual(preferences.storedAgents?.map(\.id).prefix(2), [.codex, .claude],
                       "existing order — and therefore every shortcut — is kept")
        XCTAssertEqual(preferences.storedAgents?.last?.id, .opencode)
        XCTAssertEqual(preferences.storedAgents?.last?.options, .opencode(OpenCodeOptions()))
    }

    /// A fresh install seeds OpenCode's built-in account at the XDG data root, like every agent.
    func testAFreshInstallSeedsOpenCodesBuiltInHome() {
        var preferences = Preferences()
        let root = OpenCodeFixtures.temporaryDirectory()
        preferences.migrateAccountsIfNeeded(homeRoot: root)
        XCTAssertEqual(preferences.accounts(for: .opencode).map(\.home.path),
                       [root.appendingPathComponent(".local/share").path])
    }
}
