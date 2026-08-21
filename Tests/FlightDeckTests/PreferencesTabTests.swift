import XCTest
@testable import FlightDeck

/// Which pane the Settings window shows.
///
/// The bug these exist to prevent: "Configure Tools…" promises to take you to the Tools pane,
/// and `PreferencesView`'s `TabView` had no selection binding and no tags at all — so there was
/// no mechanism to land on a particular tab, and the item opened Settings wherever SwiftUI
/// happened to leave it.
///
/// The selection deliberately lives outside `Preferences` and is never written to disk. It is
/// transient UI state; persisting it would mean every click of a tab dirties the preferences
/// blob and rewrites `preferences.v1` for nothing.
@MainActor
final class PreferencesTabTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saveCount = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saveCount += 1 }
    }

    func testAFreshStoreOpensOnAgents() {
        XCTAssertEqual(PreferencesStore(persistence: MemoryPersistence()).selectedTab, .agents)
    }

    func testSelectingATabDoesNotWriteToDisk() {
        // `preferences`'s didSet persists on every mutation. If the selected tab lived in
        // there, moving between panes would rewrite the whole blob each time.
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        let before = persistence.saveCount
        store.selectedTab = .tools
        XCTAssertEqual(persistence.saveCount, before, "changing panes must not touch persistence")
    }

    func testTheSelectedTabDoesNotSurviveARelaunch() {
        // Transient by design: reopening Settings should not drop you wherever you were days
        // ago, and nothing about a pane belongs in the persisted preferences.
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.selectedTab = .tools
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])  // force a real save

        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reopened.selectedTab, .agents)
        XCTAssertEqual(reopened.preferences.globalFlags.values["--model"], .value("opus"),
                       "the real preferences must still round-trip")
    }

    func testEveryPaneHasADistinctTag() {
        // The tags are what `TabView(selection:)` matches on; two panes sharing one would make
        // selection ambiguous and silently select the wrong pane.
        XCTAssertEqual(Set(PreferencesTab.allCases).count, PreferencesTab.allCases.count)
    }
}
