import FleetKit
import XCTest
@testable import FlightDeck

/// The desktop menu, described for a phone and read back when one is tapped.
///
/// **What is being defended is that there is only one implementation of the menu's rules.**
/// Which agents appear, in what order, flat or nested, and which account is ticked are all
/// `NewSessionAffordance.menu`'s to decide; everything here is translation. A test that built
/// its own expected menu by hand would be the second implementation the design exists to avoid,
/// so every case below starts from that function's real output.
@MainActor
final class NewSessionOptionsProjectionTests: XCTestCase {

    private let project = "/tmp/project"

    private func preferences(_ accounts: [AgentAccount]) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.storedAccounts = accounts
        return store
    }

    private func account(_ agent: AgentID, _ name: String) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func entries(_ store: PreferencesStore) -> [NewSessionAffordance.MenuEntry] {
        let agents = store.agentOrder(forProject: project)
        return NewSessionAffordance.menu(
            agents: agents, preferences: store.preferences,
            resolved: store.resolvedAccounts(for: agents, project: project)
        )
    }

    private func rows(_ store: PreferencesStore) -> [WireNewSessionOption] {
        NewSessionOptionsProjection.rows(for: entries(store)) {
            store.account(id: $0)?.displayName
        }
    }

    // MARK: The shape of a row

    /// One account is a flat row: no account name, so the phone draws "New Claude Session" —
    /// and no tick, because a sole account is a choice that was never offered.
    func testASingleAccountIsAFlatRow() {
        let store = preferences([account(.claude, "Work")])
        let options = rows(store)
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].agent, "claude")
        XCTAssertEqual(options[0].agentName, "Claude")
        XCTAssertNil(options[0].accountName, "a flat row is the agent, not the account")
        XCTAssertEqual(options[0].index, 0, "an only account is always position zero")
    }

    /// Several accounts become a submenu: one row each, named, numbered by position, with the
    /// resolved one marked.
    func testSeveralAccountsBecomeNumberedRows() {
        let store = preferences([account(.claude, "Work"), account(.claude, "Personal")])
        let options = rows(store)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.map(\.index), [0, 1])
        XCTAssertEqual(options.compactMap(\.accountName), ["Work", "Personal"])
        XCTAssertEqual(options.filter(\.isDefault).count, 1, "exactly one account is resolved")
    }

    /// **An agent with no live account contributes nothing** — the rule the affordance already
    /// enforces, asserted here so the translation cannot quietly reintroduce a dead row.
    func testAnAgentWithNoAccountHasNoRow() {
        let store = preferences([account(.claude, "Work")])
        XCTAssertTrue(rows(store).allSatisfy { $0.agent == "claude" },
                      "codex has no login and must not appear")
    }

    /// **A project with nothing signed in answers with no rows at all**, which is a real answer
    /// and not an absent one: the phone greys its `+` out rather than offering a row that
    /// cannot launch.
    func testNothingSignedInProducesAnEmptyAnswer() {
        XCTAssertTrue(rows(preferences([])).isEmpty)
    }

    /// **Order is the ⌘N ladder**, so it is preserved rather than sorted — asserted rather than
    /// trusted, because a sort added anywhere in the translation would disagree with the
    /// sidebar about what ⌘N does and nothing else would notice.
    func testRowsArriveInTheMenusOwnOrder() {
        let store = preferences([account(.claude, "Work"), account(.codex, "Codex login")])
        let expected = entries(store).map(\.agent.rawValue)
        var seen: [String] = []
        for row in rows(store) where seen.last != row.agent { seen.append(row.agent) }
        XCTAssertEqual(seen, expected)
    }

    // MARK: Reading a tapped row back

    func testATappedRowResolvesToItsAccount() {
        let work = account(.claude, "Work")
        let personal = account(.claude, "Personal")
        let store = preferences([work, personal])
        XCTAssertEqual(
            NewSessionOptionsProjection.account(forAgent: "claude", index: 1, in: entries(store)),
            personal.id
        )
    }

    /// **The guard.** An index whose agent no longer matches is refused rather than
    /// reinterpreted against whatever agent now sits at that position — a session opened as a
    /// login nobody chose is indistinguishable from having chosen it, which is worse than a
    /// fallback.
    func testAnIndexForAnAgentThatIsGoneIsRefused() {
        let store = preferences([account(.claude, "Work"), account(.claude, "Personal")])
        XCTAssertNil(
            NewSessionOptionsProjection.account(forAgent: "codex", index: 1, in: entries(store)),
            "codex has no rows here; index 1 must not be read as claude's"
        )
    }

    /// An account signed out since the fetch leaves an index past the end.
    func testAnIndexPastTheEndIsRefused() {
        let store = preferences([account(.claude, "Work"), account(.claude, "Personal")])
        XCTAssertNil(
            NewSessionOptionsProjection.account(forAgent: "claude", index: 7, in: entries(store))
        )
    }

    /// The mirror case: an account *added* since the fetch turns a flat row into a submenu, so
    /// a stored index of 0 is still that agent's first row and still resolves. What must not
    /// resolve is a non-zero index against a row that is still flat.
    func testANonZeroIndexAgainstAFlatRowIsRefused() {
        let store = preferences([account(.claude, "Work")])
        XCTAssertNotNil(
            NewSessionOptionsProjection.account(forAgent: "claude", index: 0, in: entries(store))
        )
        XCTAssertNil(
            NewSessionOptionsProjection.account(forAgent: "claude", index: 1, in: entries(store)),
            "one account has one row, whatever the phone last saw"
        )
    }
}
