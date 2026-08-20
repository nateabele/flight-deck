import XCTest
@testable import FlightDeck

/// That every root the app *observes* is derived from the account a tab runs as, rather than
/// from one app-wide constant or from Flight Deck's own environment.
///
/// This is the failure the whole accounts feature exists to fix, and it is a silent one: a tab
/// signed in as a second account looked identical to a working tab, but its status glyph never
/// moved and a rename typed into it never came back, because every watcher was pointed at the
/// first account's directories.
@MainActor
final class AccountObservationRootTests: XCTestCase {
    /// Would have caught the shipped bug: the index URL was read from Flight Deck's OWN
    /// process environment, so every account tailed one file.
    func testCodexIndexComesFromTheAccountHomeNotTheProcessEnvironment() {
        let home = URL(fileURLWithPath: "/tmp/codex-work")
        XCTAssertEqual(
            CodexNameWatcher.indexURL(forHome: home),
            home.appendingPathComponent("session_index.jsonl")
        )
    }

    func testClaudeTranscriptPathsComeFromTheAccountHome() {
        // `SessionStore.preferences` is a `let` injected at init — it cannot be assigned after
        // construction, so every test here builds the store around its preferences.
        let preferences = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/claude-work"))
        preferences.preferences.storedAccounts = [work]
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)

        let session = Session(title: "s", workingDirectory: "/p", accountID: work.id)
        let url = store.adapter(for: .claude, account: work.id).binding(for: session).transcriptURL
        XCTAssertEqual(url?.path.hasPrefix("/tmp/claude-work/projects/"), true)
    }

    /// Directory-flagged expectations throughout: the roots are built with `isDirectory: true`
    /// like `SessionStatusWatcher.defaultRoot` is, and `URL` equality is over the string — so a
    /// bare `URL(fileURLWithPath:)` would differ by a trailing slash, or worse, differ only on
    /// machines where the path happens to exist.
    func testTheStatusWatcherRootFollowsTheAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/claude-work"))
        XCTAssertEqual(
            store.statusRoot(for: work),
            URL(fileURLWithPath: "/tmp/claude-work/sessions", isDirectory: true)
        )
        XCTAssertEqual(
            store.transcriptsRoot(for: work),
            URL(fileURLWithPath: "/tmp/claude-work/projects", isDirectory: true)
        )
    }

    /// A fixture run that missed one account would write into the real `~/.claude/sessions` —
    /// the exact corruption `SessionFixture` exists to prevent.
    func testAFixtureRootOverridesEveryAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let fixture = URL(fileURLWithPath: "/tmp/fixture")
        store.transcriptsRootOverride = fixture.appendingPathComponent("projects")
        store.statusRootOverride = fixture.appendingPathComponent("status")
        let a = AgentAccount(agent: .claude, displayName: "A", home: URL(fileURLWithPath: "/tmp/a"))
        let b = AgentAccount(agent: .claude, displayName: "B", home: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(store.statusRoot(for: a), store.statusRoot(for: b))
        XCTAssertEqual(store.statusRoot(for: a), fixture.appendingPathComponent("status"))
        XCTAssertEqual(store.transcriptsRoot(for: a), store.transcriptsRoot(for: b))
        XCTAssertEqual(store.transcriptsRoot(for: a), fixture.appendingPathComponent("projects"))
    }

    /// The codex half of the same fact, at the seam that actually feeds `CodexStack`.
    func testEachAccountsCodexStackIsPointedAtItsOwnIndex() {
        let preferences = PreferencesStore(persistence: nil)
        let a = AgentAccount(agent: .codex, displayName: "A", home: URL(fileURLWithPath: "/tmp/codex-a"))
        let b = AgentAccount(agent: .codex, displayName: "B", home: URL(fileURLWithPath: "/tmp/codex-b"))
        preferences.preferences.storedAccounts = [a, b]
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)

        XCTAssertEqual(
            store.codexIndexURL(for: a.id), a.home.appendingPathComponent("session_index.jsonl")
        )
        XCTAssertEqual(
            store.codexIndexURL(for: b.id), b.home.appendingPathComponent("session_index.jsonl")
        )

        // And the override still wins for both, for the same reason the two roots above have
        // one: a test that let one account through would tail the developer's real index.
        let fixture = URL(fileURLWithPath: "/tmp/fixture/session_index.jsonl")
        store.codexIndexURLOverride = fixture
        XCTAssertEqual(store.codexIndexURL(for: a.id), fixture)
        XCTAssertEqual(store.codexIndexURL(for: b.id), fixture)
    }

    /// One registry watcher per account with a live claude tab — not one for the app.
    ///
    /// Hermetic by `statusRootOverride`, which every watcher here therefore shares: what is
    /// under test is the *keying*, and pointing two accounts at a temp directory is the only
    /// way to assert it without scanning the developer's real `~/.claude/sessions`.
    func testEachAccountWithAClaudeTabGetsItsOwnStatusWatcher() {
        let (preferences, a, b) = accountsPair()
        let tabA = UUID(), tabB = UUID()
        let persistence = StubPersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: tabA, title: "a", workingDirectory: NSTemporaryDirectory(),
                      pinnedConversationID: UUID(), accountID: a.id),
                .init(id: tabB, title: "b", workingDirectory: NSTemporaryDirectory(),
                      pinnedConversationID: UUID(), accountID: b.id),
            ],
            selectedSessionID: tabA,
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence, preferences: preferences)
        store.statusRootOverride = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("account-observation-status", isDirectory: true)
        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        store.startStatusWatching()
        XCTAssertEqual(store.statusWatcherAccountsForTesting, [a.id, b.id],
                       "a second login's tab is invisible until its own registry is scanned")

        // A watcher registers on the shared `WatchClock`, so a second one for an account that
        // already has one polls forever with nothing able to stop it.
        store.startStatusWatching()
        XCTAssertEqual(store.statusWatcherAccountsForTesting.count, 2, "never two for one account")

        store.closeSession(tabA)
        XCTAssertEqual(store.statusWatcherAccountsForTesting, [b.id],
                       "the closed tab's login stops scanning; the other login keeps its watcher")
    }

    /// The other half of the teardown rule: `startWatching` is what builds a watcher for a tab
    /// created after launch, and it must stay silent in a store that never started watching —
    /// otherwise every test that makes a claude tab begins polling the real registry.
    func testATabCreatedAfterLaunchStartsItsOwnAccountsWatcherAndOnlyIfWatchingBegan() {
        let (preferences, a, _) = accountsPair()
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        store.statusRootOverride = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("account-observation-status", isDirectory: true)

        store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        XCTAssertTrue(store.statusWatcherAccountsForTesting.isEmpty,
                      "a store built by a test must never scan a registry")

        store.startStatusWatching()
        XCTAssertEqual(store.statusWatcherAccountsForTesting, [a.id],
                       "the sweep covers the tabs that already exist")
    }

    /// Two claude logins: the built-in one, which is what a tab naming no account resolves to,
    /// and a second homed under a temp directory. Only the *keys* matter to these tests — both
    /// stores that use this also set `statusRootOverride`, so neither login's watcher can reach
    /// the developer's real `~/.claude/sessions`.
    private func accountsPair() -> (PreferencesStore, AgentAccount, AgentAccount) {
        let builtIn = AgentAccount(
            agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome
        )
        let other = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("other-claude", isDirectory: true)
        )
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [builtIn, other]
        return (preferences, builtIn, other)
    }
}

/// Restores a posed snapshot and discards every write, so nothing here can reach the
/// developer's `sessions.json`. Each test file keeps its own — `SessionPersisting` is two
/// methods, and a shared one would have to grow options for every caller's needs.
@MainActor
private final class StubPersistence: SessionPersisting {
    var stored: SessionSnapshot?
    func load() -> SessionSnapshot? { stored }
    func save(_ snapshot: SessionSnapshot) { stored = snapshot }
}
