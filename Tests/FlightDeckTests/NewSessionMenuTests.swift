import AppKit
import XCTest
@testable import FlightDeck

/// File ▸ New … Session as AppKit items above Add Project…, rewritten in place when the current
/// project changes. These were a SwiftUI `Commands` observing the project, which rebuilt the
/// menu bar (and blinked the Tools menu) on every switch between two projects' tabs.
@MainActor
final class NewSessionMenuTests: XCTestCase {
    private typealias Row = NewSessionMenuModel.Row

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    /// No accounts: a fresh store seeds one per agent from this Mac's own logins, which would make
    /// the rows depend on the machine running the test.
    private func prefs() -> PreferencesStore {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.accounts = []
        return preferences
    }

    func testRowsFollowTheProjectsAgentOrderAndItsChords() {
        let preferences = prefs()
        var settings = preferences.projectSettings("/p")
        settings.defaultAgent = .codex
        preferences.setProjectSettings("/p", settings)
        let rows = NewSessionMenuModel.rows(project: "/p", preferences: preferences)
        guard case .item(let title, let agent, nil, false, let chord) = rows.first else { return XCTFail("\(rows)") }
        XCTAssertEqual(title, "New Codex Session")
        XCTAssertEqual(agent, .codex)
        XCTAssertEqual(chord, [.command], "the project's first agent takes ⌘N")
        guard case .item(_, .claude, _, _, let second) = rows[1] else { return XCTFail("\(rows)") }
        XCTAssertEqual(second, [.command, .shift])
    }

    func testTwoAccountsMakeASubmenuWithTheChordOnTheResolvedLeaf() {
        let preferences = prefs()
        XCTAssertNil(preferences.addAccount(AgentAccount(agent: .claude, displayName: "Personal",
                                                         home: URL(fileURLWithPath: "/tmp/fd-ns-a"))))
        XCTAssertNil(preferences.addAccount(AgentAccount(agent: .claude, displayName: "Work",
                                                         home: URL(fileURLWithPath: "/tmp/fd-ns-b"))))
        let rows = NewSessionMenuModel.rows(project: "/p", preferences: preferences)
        let claude = rows.first { if case .submenu("New Claude Session", _) = $0 { true } else { false } }
        guard case .submenu(_, let leaves)? = claude else { return XCTFail("\(rows)") }
        let checked = leaves.filter { if case .item(_, _, _, true, _) = $0 { true } else { false } }
        XCTAssertEqual(checked.count, 1, "exactly the resolved account is checked")
        guard case .item(_, _, _, _, let chord)? = checked.first else { return XCTFail() }
        XCTAssertEqual(chord, [.command], "the agent's chord sits on its resolved leaf")
    }

    /// A switch between two projects' tabs rewrites only these items, in the File menu, a turn
    /// later — the menu bar itself is untouched.
    func testASwitchBetweenProjectsRewritesTheItemsInPlace() {
        let preferences = prefs()
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let a = store.selectedSessionID!
        store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))
        let b = store.selectedSessionID!
        var settings = preferences.projectSettings("/a")
        settings.defaultAgent = .codex
        preferences.setProjectSettings("/a", settings)

        let main = NSMenu(title: "Main")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Add Project…", action: nil, keyEquivalent: "a")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let controller = NewSessionMenuController(store: store, preferences: preferences)
        controller.install(in: main)
        pump()
        let bar = main.items.map(ObjectIdentifier.init)
        XCTAssertEqual(file.items.first?.title, "New Claude Session", "B keeps the global order")
        XCTAssertEqual(file.items.last?.title, "Add Project…", "above Add Project…")
        XCTAssertEqual(file.items.first?.keyEquivalent, "n")

        store.selectSession(a)
        pump()
        XCTAssertEqual(file.items.first?.title, "New Codex Session", "A's default agent leads, and takes ⌘N")
        XCTAssertEqual(file.items.first?.keyEquivalentModifierMask, [.command])
        store.selectSession(b)
        pump()
        XCTAssertEqual(file.items.first?.title, "New Claude Session")
        XCTAssertEqual(main.items.map(ObjectIdentifier.init), bar, "the bar itself never changed")
        XCTAssertEqual(file.items.filter { $0.title == "Add Project…" }.count, 1)
    }
}
