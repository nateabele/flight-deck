import XCTest
@testable import FlightDeck

/// That the adapter, runtime and codex-stack registries are keyed by an agent *as an account*
/// rather than by the agent alone — and that one account still gets exactly one of each.
///
/// Nothing here spawns anything: building a `CodexStack` starts no process, only
/// `startCodex()` does, so the stack-count assertion below stays inside the "no committed test
/// runs `codex app-server`" rule.
@MainActor
final class AgentInstanceTests: XCTestCase {
    /// `ClaudeAdapter` is a struct, so there is no identity to compare — the registry seam is
    /// the observable fact, mirroring the existing `hasCodexStackForTesting` style.
    func testTwoAccountsOnOneAgentGetTwoInstances() {
        let store = SessionStore(provider: nil, persistence: nil)
        _ = store.adapter(for: .claude, account: UUID())
        _ = store.adapter(for: .claude, account: UUID())
        XCTAssertEqual(store.adapterCountForTesting, 2, "an adapter is per (agent, account), not per agent")
    }

    /// A runtime is stateful — it holds the attachment `detach` has to find — so two instances
    /// for one key would start a watcher nothing can stop.
    func testOneAccountIsMemoizedNotRebuilt() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID()
        XCTAssertTrue(store.runtime(for: .claude, account: a) === store.runtime(for: .claude, account: a))
        XCTAssertEqual(store.runtimeCountForTesting, 1)
    }

    func testAnOverrideIsScopedToItsAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID(), b = UUID()
        let fake = FakeRuntime()
        store.overrideRuntime(fake, for: .claude, account: a)
        XCTAssertTrue(store.runtime(for: .claude, account: a) === fake)
        XCTAssertFalse(store.runtime(for: .claude, account: b) === fake)
    }

    /// The invariant nil-normalisation exists to protect: one home, one stack. Two keys for
    /// `~/.codex` would put two app-servers on one `session_index.jsonl`.
    func testOneAccountYieldsOneCodexStack() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID()
        _ = store.adapter(for: .codex, account: a)
        _ = store.runtime(for: .codex, account: a)
        XCTAssertEqual(store.codexStackCountForTesting, 1)
    }

    /// The other half: two logins on codex are two app-servers, because one `CODEX_HOME` is
    /// all a single one can ever answer for.
    func testTwoAccountsYieldTwoCodexStacks() {
        let store = SessionStore(provider: nil, persistence: nil)
        _ = store.adapter(for: .codex, account: UUID())
        _ = store.adapter(for: .codex, account: UUID())
        XCTAssertEqual(store.codexStackCountForTesting, 2)
        XCTAssertEqual(store.codexServerRequestsForTesting, 0,
                       "building a stack must still spawn nothing")
    }

    /// Teardown narrows with the key. `stopCodexIfUnused` used to ask "does any codex tab
    /// remain?", which with two logins keeps one user's app-server running for the rest of the
    /// session on the strength of a tab belonging to the *other* — the exact leak it exists to
    /// prevent, one account over. It now asks "does any tab remain on this account?", and
    /// stops only that account's stack.
    func testClosingOneAccountsLastCodexTabLeavesTheOtherAccountsServerAlone() async {
        let builtIn = AgentAccount(
            agent: .codex, displayName: "Default", home: AgentID.codex.builtInHome
        )
        let other = AgentAccount(
            agent: .codex, displayName: "work",
            home: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("other-codex", isDirectory: true)
        )
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [builtIn, other]

        // Restored rather than created: `createSession` cannot yet be pointed at a
        // non-default account — that is a later task — but a snapshot already carries
        // `accountID` per tab, so this is the one route to two live logins today.
        let defaultTab = UUID(), otherTab = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: defaultTab, title: "default", workingDirectory: NSTemporaryDirectory(),
                      pinnedConversationID: UUID(), agent: .codex),
                .init(id: otherTab, title: "work", workingDirectory: NSTemporaryDirectory(),
                      pinnedConversationID: UUID(), agent: .codex, accountID: other.id),
            ],
            selectedSessionID: defaultTab,
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence, preferences: preferences)
        store.launchFailureReporter = SilentReporter()
        // One override per account, under the same keys the tabs resolve to: an override that
        // missed would send `resumeRestoredCodex` into `startCodex` and spawn a real
        // `codex app-server`.
        for account in [builtIn, other] {
            store.overrideAdapter(
                CodexAdapter(rpc: CodexRPC(transport: EchoingTransport())),
                for: .codex, account: account.id
            )
        }

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value
        XCTAssertEqual(store.codexStackCountForTesting, 2, "one app-server per login")
        XCTAssertEqual(store.codexServerRequestsForTesting, 2,
                       "each login is asked for its own server, and neither waits on the other")
        let survivor = store.runtime(for: .codex, account: other.id) as AnyObject

        store.closeSession(defaultTab)

        XCTAssertEqual(store.codexStackCountForTesting, 1,
                       "the closed tab's own login loses its app-server — and asking whether "
                       + "any codex tab remains ANYWHERE would have kept both alive")
        XCTAssertTrue(store.runtime(for: .codex, account: other.id) === survivor,
                      "the login that still has a tab must keep the very stack it was using; "
                      + "a rebuilt one would leave that tab attached to an orphan")
    }

    @MainActor final class FakeRuntime: AgentRuntime {
        func attach(_ binding: AgentBinding, for tab: UUID,
                    onEvent: @escaping (AgentEvent) -> Void) -> AttachmentToken {
            AttachmentToken(conversationID: binding.conversationID, tab: tab)
        }
        func detach(_ token: AttachmentToken) {}
    }

    /// Answers `thread/read` with the very thread it was asked about, so a restored tab
    /// settles onto its own pin and nothing is re-pinned out from under this test.
    private final class EchoingTransport: CodexTransport {
        var onLine: ((String) -> Void)?

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            let thread = (obj["params"] as? [String: Any])?["threadId"] as? String ?? ""
            switch method {
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(thread)","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }
}
