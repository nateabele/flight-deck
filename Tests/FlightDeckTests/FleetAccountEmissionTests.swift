import XCTest
import FleetKit
@testable import FlightDeck

/// The mutation points agent accounts added, run under the fleet's drift check.
///
/// This file exists because of how narrow that check's reach is: `FleetReplicator` only
/// notices a missing `emit` in a test that actually attaches a replicator, and the account
/// suites (`AccountLaunchTests`, `AccountObservationRootTests`, …) attach none. Accounts
/// introduced four new ways for `repos`/`statuses`/`unreadIdle` to move — signing in,
/// refusing a launch, rebuilding an orphaned tab, and tearing a per-account watcher down —
/// and every one of them would have shipped silently wrong on a paired phone with the whole
/// suite still green. Each test below drives one of them with the harness installed, so the
/// check is on the path.
///
/// The last test is the other half: accounts are *config directories*, and the wire
/// deliberately does not carry them.
@MainActor
final class FleetAccountEmissionTests: XCTestCase {
    // MARK: - Signing in

    /// "Sign In" builds a tab through `openSignInSession`, which bypasses `createSession`'s
    /// negotiation entirely — a login has no thread to start. It reaches `repos` through the
    /// shared `addSession` tail, so it must announce itself exactly like any other creation;
    /// a bespoke insertion that skipped that tail is the shape of bug this pins.
    func testSigningInAnnouncesItsProjectThenItself() {
        let (preferences, work) = configured(.claude)
        let store = makeStore(preferences)
        let replicator = attachedReplicator(to: store)

        let session = store.openSignInSession(
            for: work, in: projectURL.path, using: LoginInvocation(command: "claude", inject: nil)
        )

        guard case .projectAdded(let project, _) = replicator.recorded.first else {
            return XCTFail("a new project must be announced before the session inside it")
        }
        XCTAssertTrue(replicator.recorded.contains {
            if case .sessionAdded(let wire, project.id, _) = $0 { return wire.id == session.id }
            return false
        })
    }

    // MARK: - Refusals emit nothing

    /// A refused launch is the one new path that must stay *silent*. `newSession` returns a
    /// draft it never filed — no repo, no session, nothing in `repos` — so an event here
    /// would invent a session on the phone that does not exist on the Mac and can never be
    /// removed, because no `sessionRemoved` will ever name it.
    func testARefusedClaudeLaunchEmitsNothing() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings =
            ["/p": ProjectSettings(accounts: [.claude: UUID()])]
        let store = makeStore(preferences)
        let replicator = attachedReplicator(to: store)

        store.newSession(in: URL(fileURLWithPath: "/p", isDirectory: true))

        XCTAssertTrue(replicator.recorded.isEmpty, "a tab that was never filed is not an event")
        XCTAssertTrue(replicator.snapshot().fleet.projects.isEmpty)
    }

    /// The codex half. The refusal happens before the draft exists and before the app-server
    /// is touched, so there is nothing to describe on the wire either.
    func testARefusedCodexLaunchEmitsNothing() async {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings =
            ["/p": ProjectSettings(accounts: [.codex: UUID()])]
        let store = makeStore(preferences)
        let replicator = attachedReplicator(to: store)

        _ = await store.createSession(agent: .codex, in: "/p")

        XCTAssertTrue(replicator.recorded.isEmpty)
        XCTAssertEqual(store.codexServerRequestsForTesting, 0)
    }

    // MARK: - Restore

    /// An orphaned tab is rebuilt but never launched, and it is still a row in the sidebar —
    /// so it is still a session on the phone. Nothing about the fleet distinguishes it, which
    /// is the point: the mirror after a restore has to equal the store's own projection, orphan
    /// included. `restore` says so with `replicator.reset()` rather than an event per row, and
    /// the harness's drift check is what proves the two agree.
    func testAnOrphanedRestoredTabIsInTheFleetAndLeavesNoDrift() throws {
        let (preferences, work) = configured(.claude)
        let healthy = UUID(), orphan = UUID()
        let persistence = StubPersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: healthy, title: "healthy", workingDirectory: projectURL.path,
                      pinnedConversationID: UUID(), accountID: work.id),
                // The login this one ran as was deleted between runs.
                .init(id: orphan, title: "orphan", workingDirectory: projectURL.path,
                      pinnedConversationID: UUID(), accountID: UUID()),
            ],
            sessionCounter: 2
        )
        let store = makeStore(preferences, persistence: persistence)
        let replicator = attachedReplicator(to: store)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        let fleet = replicator.snapshot().fleet
        XCTAssertEqual(fleet.projects.flatMap(\.sessions).map(\.id), [healthy, orphan],
                       "a tab the user can see is a tab the phone can see")
        XCTAssertEqual(fleet, FleetProjection.snapshot(of: store))
        // `reset` throws the replay history away, so a client sitting one sequence back is
        // routed to a fresh snapshot rather than told it is current. Asserted here because
        // accounts added rows to the loop `reset` covers.
        guard case .resnapshot = replicator.resume(from: replicator.seq - 1) else {
            return XCTFail("a wholesale replacement must not be servable as a replay")
        }
    }

    // MARK: - Per-account teardown

    /// Closing the last tab of an account now also stops that account's registry watcher and
    /// drops its cached rows (`stopStatusWatchingIfUnused`). Neither is fleet state, so
    /// neither may emit — but both run inside `closeSession`, between the removal and the
    /// unread prune, and a teardown that reached into `statuses` on its way out would drift
    /// here and nowhere else in the suite.
    func testClosingTheLastTabOfAnAccountAnnouncesOnlyTheRemoval() {
        let (preferences, _) = configured(.claude)
        let store = makeStore(preferences)
        let session = store.newSession(in: projectURL)
        store.applyRegistryForTesting([session.id: SessionStatus(activity: .busy)])
        let replicator = attachedReplicator(to: store)

        store.closeSession(session.id)

        XCTAssertTrue(replicator.recorded.contains(.sessionRemoved(id: session.id)))
        XCTAssertTrue(replicator.snapshot().fleet.projects.allSatisfy(\.sessions.isEmpty))
    }

    /// Two logins, one fleet, one tick. Accounts split the registry into one scan per home and
    /// then merge them precisely so `commitStatuses` still sees every claude tab at once — a
    /// per-watcher apply would find no row for the other login's tabs and report them as
    /// exited, and that fabricated `busy → gone` edge is real state, so it would emit. This
    /// pins the merged shape from the emission side: the tab that changed produces one event,
    /// the tab that did not produces none.
    func testATickOnOneAccountDoesNotAnnounceTheOthersTabAsGone() {
        let (preferences, work) = configured(.claude)
        let other = AgentAccount(agent: .claude, displayName: "Other", home: home("other"))
        preferences.preferences.storedAccounts = [work, other]
        let store = makeStore(preferences)
        let first = store.newSession(in: projectURL)
        let second = store.openSignInSession(
            for: other, in: projectURL.path, using: LoginInvocation(command: "claude", inject: nil)
        )
        store.applyRegistryForTesting([
            first.id: SessionStatus(activity: .busy),
            second.id: SessionStatus(activity: .busy),
        ])
        let replicator = attachedReplicator(to: store)

        store.applyRegistryForTesting([
            first.id: SessionStatus(activity: .idle),
            second.id: SessionStatus(activity: .busy),
        ])

        XCTAssertTrue(replicator.recorded.contains(
            .activityChanged(id: first.id, activity: "idle", waitingFor: nil, subagentCount: 0,
                             hasBackgroundWork: false, openPromptCall: .noPrompt)
        ))
        XCTAssertFalse(replicator.recorded.contains { event in
            guard case .activityChanged(let id, let activity, _, _, _, _) = event
            else { return false }
            return id == second.id && activity == nil
        }, "the other login's tab did not exit; nothing about it changed")
    }

    // MARK: - What must never reach the wire

    /// An account IS a config directory — `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, the directory
    /// holding that login's credentials. `WireSession` carries no account field on purpose and
    /// `Session.accountID` is never projected, so replicating an account-bearing fleet leaks
    /// neither the home path nor the opaque id that resolves to one.
    ///
    /// Encoded rather than inspected field by field: the assertion has to survive somebody
    /// adding a field to `WireSession`, and only the serialized form covers what actually goes
    /// out. `WireProject.path` — the project root — is deliberately still there; that is the
    /// subtitle a client renders, and it is not credential-adjacent.
    func testAnAccountsHomeNeverReachesTheWire() throws {
        let (preferences, work) = configured(.claude)
        let store = makeStore(preferences)
        let session = store.newSession(in: projectURL)
        XCTAssertEqual(session.accountID, work.id, "the tab really is account-bearing")

        // Unescaped before searching. `JSONEncoder` writes `/` as `\/`, so a raw
        // `contains(somePath)` is false no matter what the snapshot holds — the two
        // `XCTAssertFalse`s below would have passed vacuously, which is the worst possible
        // outcome for a privacy assertion. The third one is here to catch exactly that.
        let encoded = try XCTUnwrap(
            String(data: JSONEncoder().encode(FleetProjection.snapshot(of: store)), encoding: .utf8)
        ).replacingOccurrences(of: "\\/", with: "/")

        XCTAssertFalse(encoded.contains(work.home.path), "a config directory is not fleet state")
        XCTAssertFalse(encoded.contains(work.id.uuidString),
                       "nor is the id that resolves to one")
        XCTAssertTrue(encoded.contains(projectURL.path),
                      "the project root still is — that is the client's subtitle")
    }

    /// The same assertion, over the New Session menu's answer.
    ///
    /// **This is the test the first attempt at that feature failed, and it was right to.** The
    /// backed-out version identified a menu row by its account UUID and sent it back on tap;
    /// the row's identity is now the agent plus a *position*, which resolves to an account only
    /// on the Mac. Encoded rather than inspected field by field, for the reason the snapshot
    /// assertion above gives — it has to survive somebody adding a field to
    /// `WireNewSessionOption`.
    func testAnAccountsHomeNeverReachesTheNewSessionMenu() throws {
        let account = AgentAccount(agent: .claude, displayName: "Work", home: home("work"))
        let other = AgentAccount(agent: .claude, displayName: "Personal", home: home("personal"))
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [account, other]

        let agents = preferences.agentOrder(forProject: projectURL.path)
        let entries = NewSessionAffordance.menu(
            agents: agents, preferences: preferences.preferences,
            resolved: preferences.resolvedAccounts(for: agents, project: projectURL.path)
        )
        let rows = NewSessionOptionsProjection.rows(for: entries) {
            preferences.account(id: $0)?.displayName
        }
        XCTAssertFalse(rows.isEmpty, "two logins must produce a menu, or this asserts nothing")

        let encoded = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(
                    WireNewSessionOptions(project: UUID(), options: rows)
                ),
                encoding: .utf8
            )
        ).replacingOccurrences(of: "\\/", with: "/")

        for leaked in [account, other] {
            XCTAssertFalse(encoded.contains(leaked.home.path),
                           "a config directory is not a menu row")
            XCTAssertFalse(encoded.contains(leaked.id.uuidString),
                           "nor is the id that resolves to one")
        }
        XCTAssertTrue(encoded.contains("Work"), "the display name is what a row is for")
    }

    // MARK: - Fixtures

    /// Discards every write, so nothing here reaches the developer's `sessions.json`.
    private final class StubPersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class SpyReporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    private var reporter = SpyReporter()

    /// The spy reporter goes on every store, not only the tests that refuse a launch: the
    /// default reporter is an `NSAlert`, and a refusal in any of these would otherwise put a
    /// real panel on the machine running the suite. The two root overrides keep the watchers
    /// off the developer's real `~/.claude` for the same reason.
    private func makeStore(
        _ preferences: PreferencesStore, persistence: SessionPersisting? = nil
    ) -> SessionStore {
        let store = SessionStore(provider: nil, persistence: persistence, preferences: preferences)
        store.launchFailureReporter = reporter
        store.transcriptsRootOverride = temporaryRoot("projects")
        store.statusRootOverride = temporaryRoot("status")
        return store
    }

    /// One account for `agent`, homed in a directory that really exists — `launchAccount`
    /// refuses a home that is gone, so a fixture that skipped this would refuse every launch
    /// and pass the "emits nothing" tests for the wrong reason.
    private func configured(_ agent: AgentID) -> (PreferencesStore, AgentAccount) {
        let account = AgentAccount(agent: agent, displayName: "Work", home: home("work"))
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [account]
        return (preferences, account)
    }

    private func home(_ name: String) -> URL {
        let url = temporaryRoot(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryRoot(_ name: String) -> URL {
        suite.appendingPathComponent(name, isDirectory: true)
    }

    private lazy var suite = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("fleet-account-emission-\(UUID().uuidString)", isDirectory: true)

    private lazy var projectURL = home("project")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: suite)
    }
}
