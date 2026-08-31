import FleetKit
import XCTest
@testable import FlightDeck

/// The seam itself: that the store picks an agent's adapter and runtime by the *session's*
/// agent rather than reaching for `ClaudeSession` directly, and that whatever a runtime
/// reports lands on the tab. Everything claude-specific about that route is pinned by the
/// pre-existing suites (`SessionLaunchTests`, `ConversationRepinTests`,
/// `SessionProjectMoveTests`); these tests pin only that the route exists.
@MainActor
final class AgentRoutingTests: XCTestCase {
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// A throwaway stand-in for `~/.claude/projects`. Every store below creates a session,
    /// and creating one now derives a transcript path through `ClaudeAdapter` and starts a
    /// watcher polling it — pointed at the real root, these tests would poll the user's own
    /// transcripts. This diff is what taught the adapter to honour `projectsRoot`; these
    /// tests are the first that must use it.
    private var projectsRoot: URL!

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface — same retention trick as `SessionCreationTests`.
    private var retainedProviders: [RecordingProvider] = []

    override func setUpWithError() throws {
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl` — tests below create codex
        // tabs, and a real path would have those tabs' watchers tail the user's own home.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        return store
    }

    private func makeRecordingStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.display = DrawableDisplay()
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        return (store, provider)
    }

    /// Matches `ConversationRepinTests.row`: a registry row good enough to drive
    /// `applyRegistry` through a full repin. Two distinct `procStart`s are what let
    /// `ConversationPin` anchor two tabs to two different pids rather than folding both
    /// rows onto one — see `makeStoreWithTwoTabsSharingOneConversation` below.
    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String,
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    /// Two tabs repinned onto ONE conversation via `applyRegistry` — the same route
    /// `ConversationRepinTests.testTwoTabsResumedOntoOneConversationAreBothFlagged` proves is
    /// reachable in production, not a contrivance: each tab's own registry row independently
    /// repins it onto `shared` (distinct pids and `procStart`s, so `ConversationPin` follows
    /// each tab's own anchor instead of both rows resolving against one). `titleResolver` is
    /// stubbed synchronous, same as `ConversationRepinTests.makeStore()`, so both repins —
    /// and the runtime (re)attaches they trigger — are complete by the time this returns.
    private func makeStoreWithTwoTabsSharingOneConversation() -> (
        store: SessionStore, runtime: FakeAgentRuntime, first: Session, second: Session, shared: UUID
    ) {
        let store = makeStore()
        store.titleResolver = { _, _, done in done(nil) }
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude, account: nil)
        let first = store.newSession(in: tmp)
        let second = store.newSession(in: tmp)
        let shared = UUID()

        store.applyRegistry([
            1: row(first.pinnedConversationID, pid: 1, cwd: tmp.path),
            2: row(second.pinnedConversationID, pid: 2, cwd: tmp.path, procStart: "start-b"),
        ])
        store.applyRegistry([
            1: row(shared, pid: 1, cwd: tmp.path),
            2: row(shared, pid: 2, cwd: tmp.path, procStart: "start-b"),
        ])
        XCTAssertEqual(store.conflictedSessionIDs, [first.id, second.id],
                       "fixture must actually land both tabs on `shared`, or the test below "
                       + "proves nothing")
        return (store, fake, first, second, shared)
    }

    /// `account: nil` throughout this file, and it is not a placeholder: every store here is
    /// built with no `PreferencesStore`, so there is no account to name and `nil` is exactly
    /// the key `SessionStore.instance(for:)` resolves for the tabs these tests create. An
    /// override filed under any other account would simply not be found.
    func testTheStoreSelectsAnAdapterByTheSessionsAgent() {
        let store = makeStore()
        XCTAssertEqual(type(of: store.adapter(for: .claude, account: nil)).id, .claude)
    }

    func testEventsFromARuntimeReachTheSessionTitle() {
        let store = makeStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude, account: nil)

        let session = store.newSession(in: tmp)
        XCTAssertEqual(fake.attached, [session.pinnedConversationID],
                       "creating a tab must attach its binding to the agent's runtime")

        fake.emit(.title("after"), for: session.pinnedConversationID)

        XCTAssertEqual(store.title(of: session.id), "after",
                       "a runtime event must move the sidebar title")
    }

    func testClosingATabDetachesItsBinding() {
        let store = makeStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude, account: nil)

        let session = store.newSession(in: tmp)
        store.closeSession(session.id)

        XCTAssertEqual(fake.detached, [session.pinnedConversationID])
    }

    /// The launch text is the adapter's to build, so an overridden adapter must be what the
    /// pty is fed — otherwise the store is still talking to `ClaudeSession` behind its back.
    func testTheAdapterBuildsTheLaunchCommand() {
        let (store, provider) = makeRecordingStore()
        store.overrideAdapter(StubAdapter(), for: .claude, account: nil)

        _ = store.newSession(in: tmp)

        XCTAssertEqual(provider.configs.last?.initialInput, "stub-launch")
    }

    // MARK: - Which route the SIDEBAR's rename takes

    /// Answers `thread/name/set` and records every method it was asked for.
    private final class RenameTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        private(set) var names: [String] = []

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            if method == "thread/name/set",
               let name = (obj["params"] as? [String: Any])?["name"] as? String {
                names.append(name)
            }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// `SessionSidebar` calls `store.rename` for every tab regardless of agent, so this is
    /// the route production actually takes — unlike
    /// `testClaudeRenameDispatchesInlineAndNeverReachesTheAdapter` below, which installs a
    /// recording stand-in for `.claude`'s adapter and therefore could not have caught a
    /// store that never dispatched.
    func testRenamingACodexTabRenamesTheCodexThread() async throws {
        let store = makeStore()
        store.launchFailureReporter = SilentReporter()
        let t = RenameTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: t)), for: .codex, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()
        // Creation already named the thread once — `thread/name/set` is what commits it — so
        // the rename is the SECOND name, not the first.
        let namesAfterCreation = t.names.count

        store.rename(id, to: "renamed")
        // The rename is dispatched, not awaited: the sidebar must not block on the RPC. So
        // the request lands in a later turn of the run loop, and a bare `Task.yield()` is one
        // scheduling assumption too many — spin until it arrives, bounded.
        for _ in 0..<100 where t.names.count == namesAfterCreation { await Task.yield() }

        XCTAssertEqual(store.title(of: id), "renamed", "the sidebar is authoritative and immediate")
        XCTAssertEqual(t.names.last, "renamed",
                       "renaming a codex tab must send thread/name/set — the thread name is what "
                       + "session_index.jsonl and thread/read both report, so a divergence "
                       + "flicks the title back on the next tail or restore")
        XCTAssertTrue(spy.events.isEmpty,
                      "a codex tab must never queue `/rename` for the pty: nothing retires the "
                      + "entry, and a match would paste it into the user's live codex session")
    }

    /// The other half, and the one that must not have moved: claude still types.
    func testRenamingAClaudeTabStillTypesIntoThePtyAndSendsNoRequest() {
        let store = makeStore()
        let t = RenameTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: t)), for: .codex, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity: .idle)])
        spy.events.removeAll()

        store.rename(session.id, to: "renamed")

        // Synchronously, in the same turn of the run loop, exactly as before the dispatch
        // existed: `inject` decides *now* whether the input bar is busy.
        XCTAssertEqual(spy.events, [.killLine, .text("/rename renamed"), .ret])
        XCTAssertTrue(t.methods.isEmpty, "claude's rename must not reach codex's app-server")
    }

    /// Was `testTheAdaptersRenameTypesThroughTheStoresOwnInjectionRoute`, which called
    /// `adapter.rename` directly to prove claude's rename lands on the same injection route
    /// as the sidebar's. That route no longer exists to prove: `ClaudeAdapter.rename` is now
    /// unreachable in production (`SessionStore.rename` dispatches `.claude` inline) and
    /// `assertionFailure`s if a caller ever reaches it, so a test cannot call it directly
    /// without crashing the run. This proves the same property the other way around: install
    /// a recording stand-in for `.claude`'s adapter and confirm `store.rename` never asks it
    /// to rename anything, while still typing `/rename` into the pty exactly as before.
    func testClaudeRenameDispatchesInlineAndNeverReachesTheAdapter() {
        let store = makeStore()
        let recorder = RenameCallRecorder()
        store.overrideAdapter(RecordingRenameAdapter(recorder: recorder), for: .claude, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity: .idle)])
        spy.events.removeAll()

        store.rename(session.id, to: "renamed")

        XCTAssertEqual(spy.events, [.killLine, .text("/rename renamed"), .ret],
                       "claude renames dispatch inline through the store's own injector")
        XCTAssertTrue(recorder.calls.isEmpty,
                       "claude's rename must never reach `adapter.rename` — see "
                       + "`ClaudeAdapter.rename`'s doc comment for why")
    }

    /// Fix round 1 (F-1): a genuine reproduction, not just a guard. This drives two tabs onto
    /// the SAME conversation the way `ConversationRepinTests` proves is reachable, then emits
    /// on ONE tab's token specifically.
    ///
    /// Inexpressible against the pre-token API: `attach` returned `Void`, so nothing a test
    /// could hold would ever identify one specific tab's subscription. And it fails against
    /// the old `for tab in tabs(following: binding.conversationID) { apply(event, to: tab) }`
    /// fan-out — verified by temporarily restoring that closure body and re-running this test,
    /// which then renamed both tabs. See task-5-report.md, "F-1 verification", for the exact
    /// before/after.
    func testATitleOnOneTabsTokenLeavesTheOtherTabOnTheSameConversationAlone() {
        let (store, runtime, first, second, shared) = makeStoreWithTwoTabsSharingOneConversation()
        let firstBefore = store.title(of: first.id)

        runtime.emit(.title("only-second"), to: AttachmentToken(conversationID: shared, tab: second.id))

        XCTAssertEqual(store.title(of: second.id), "only-second")
        XCTAssertEqual(store.title(of: first.id), firstBefore,
                       "an event on one tab's token must not reach another tab following the "
                       + "same conversation")
    }

    /// F-2: the seam between the store's stored `attachment.token` and the runtime's
    /// subscriber set, which no runtime-level test can reach — a `stopWatching` that detached
    /// a synthesized token instead of the one it actually stored would leave both
    /// `ClaudeRuntimeTests` and `CodexRuntimeAttachmentTests` green while quietly cutting the
    /// survivor off (or leaking the closed tab's subscription forever).
    func testClosingOneOfTwoTabsOnOneConversationLeavesTheOtherWatching() {
        let (store, runtime, first, second, shared) = makeStoreWithTwoTabsSharingOneConversation()

        store.closeSession(first.id)
        runtime.emit(.title("after-close"), for: shared)

        XCTAssertEqual(store.title(of: second.id), "after-close",
                       "closing one of two tabs sharing a conversation must not detach the "
                       + "survivor")
    }

    /// **The behaviour change §4.6 of the audit named, end to end and in both places it
    /// shows.** Nothing in the suite asserted the old behaviour, so nothing failed when it
    /// changed — see `AgentTitleTests` for why that is the point.
    ///
    /// `thread/name/set` is JSON-RPC: the name is a JSON string field, and no shell, pty or
    /// quoting step exists anywhere between the sidebar and codex's thread store. So the
    /// title the user typed is the title codex is given AND the title the sidebar shows, and
    /// those two agreeing is what stops the next tail of `session_index.jsonl` flicking it
    /// back.
    func testRenamingACodexTabKeepsPunctuationClaudeWouldHaveStripped() async throws {
        let store = makeStore()
        store.launchFailureReporter = SilentReporter()
        let t = RenameTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: t)), for: .codex, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        let namesAfterCreation = t.names.count

        store.rename(id, to: "fix build (part 2)")
        for _ in 0..<100 where t.names.count == namesAfterCreation { await Task.yield() }

        XCTAssertEqual(t.names.last, "fix build (part 2)",
                       "thread/name/set touches no shell; stripping is claude's rule, not a "
                       + "universal one")
        XCTAssertEqual(store.title(of: id), "fix build (part 2)",
                       "the sidebar and the thread name must be byte-identical, or the next "
                       + "tail flicks the title back")
    }

    private func entry(_ conversation: UUID, activity: SessionActivity) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: conversation, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: tmp.path)
    }

    /// Mirrors `ClaudeAdapter` with every command replaced by a constant, so a test can see
    /// which of the two the store asked for.
    private struct StubAdapter: AgentAdapter {
        static let id: AgentID = .claude
        /// Claude's answers, because this stands in for claude — the store reads both
        /// capabilities off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let textChannel: AgentTextChannel? = ClaudeTextChannel()
        static let dialogDriver: AgentDialogDriver? = ClaudeDialogDriver()
        static let negotiatesIdentity = false
        static let needsRuntimeStart = false
        static let hasStatusRegistry = true
        nonisolated static func sanitizedTitle(_ raw: String) -> String? {
            ClaudeAdapter.sanitizedTitle(raw)
        }
        nonisolated static func title(fromTranscriptAt url: URL) -> String? {
            ClaudeAdapter.title(fromTranscriptAt: url)
        }
        nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
            ClaudeAdapter.timelineItems(inLine: line, at: offset)
        }
        nonisolated static let homeMarkerFile = ClaudeAdapter.homeMarkerFile
        nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
            ClaudeAdapter.identity(fromHomeData: data)
        }
        static let openPromptReader: AgentOpenPromptReader? = ClaudeAdapter.openPromptReader

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-launch" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-resume" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
    }

    /// What `RecordingRenameAdapter` books every `rename` call into. A separate reference
    /// type because `AgentAdapter` conformers here are structs, and a struct's own copy could
    /// not be read back after `overrideAdapter` took it by value.
    private final class RenameCallRecorder {
        private(set) var calls: [(AgentBinding, String)] = []
        func record(_ binding: AgentBinding, _ title: String) { calls.append((binding, title)) }
    }

    /// A `ClaudeAdapter` stand-in for exactly one job: proving `SessionStore.rename` never
    /// calls `adapter.rename` for claude. The real `ClaudeAdapter.rename` now
    /// `assertionFailure`s the moment anything reaches it, so nothing in this suite may call
    /// it directly — this records the call instead of crashing, so a test can assert on
    /// whether one arrived.
    private struct RecordingRenameAdapter: AgentAdapter {
        static let id: AgentID = .claude
        let recorder: RenameCallRecorder

        // Every static requirement delegates to the adapter this stands in for. It exists to
        // record ONE instance method — `rename` — and answering the rest itself would be a
        // second, drifting description of claude: this stub was already a merge conflict
        // once, when the protocol grew and it did not. Delegating means the next requirement
        // added costs nothing here.
        static var textChannel: (any AgentTextChannel)? { ClaudeAdapter.textChannel }
        static var dialogDriver: (any AgentDialogDriver)? { ClaudeAdapter.dialogDriver }
        static var negotiatesIdentity: Bool { ClaudeAdapter.negotiatesIdentity }
        static var needsRuntimeStart: Bool { ClaudeAdapter.needsRuntimeStart }
        static var hasStatusRegistry: Bool { ClaudeAdapter.hasStatusRegistry }
        static var openPromptReader: (any AgentOpenPromptReader)? { ClaudeAdapter.openPromptReader }
        nonisolated static var homeMarkerFile: String { ClaudeAdapter.homeMarkerFile }

        nonisolated static func sanitizedTitle(_ raw: String) -> String? {
            ClaudeAdapter.sanitizedTitle(raw)
        }
        nonisolated static func title(fromTranscriptAt url: URL) -> String? {
            ClaudeAdapter.title(fromTranscriptAt: url)
        }
        nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
            ClaudeAdapter.timelineItems(inLine: line, at: offset)
        }
        nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
            ClaudeAdapter.identity(fromHomeData: data)
        }

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_ binding: AgentBinding, to title: String) async throws { recorder.record(binding, title) }
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
    }

    /// Keeps every configuration it was handed. `SessionCreationTests.StubProvider` throws
    /// its config away, and the initial input is exactly what these tests are about.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }
}
