import XCTest
@testable import FlightDeck

/// Pointing the Settings window at a pane — and, for the Projects pane, at one project.
///
/// The half that matters is `select`: `open`'s remaining work is sending the real Settings
/// menu item's action through `NSApp`, which is not something a unit test should stand up.
///
/// The bug these exist to prevent: "Configure…" on a project row promises to take you to that
/// project's overrides. Before this the Projects pane held its selection in local `@State`,
/// so the best any caller could do was land on the pane's "No Project Selected" placeholder.
@MainActor
final class PreferencesOpenerTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saveCount = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saveCount += 1 }
    }

    private func makeStore() -> (PreferencesStore, MemoryPersistence) {
        let persistence = MemoryPersistence()
        return (PreferencesStore(persistence: persistence), persistence)
    }

    func testSelectingAPaneMovesTheSelection() {
        let (store, _) = makeStore()
        PreferencesOpener.select(store, tab: .tools)
        XCTAssertEqual(store.selectedTab, .tools)
    }

    func testSelectingAProjectPicksBothThePaneAndTheProject() {
        let (store, _) = makeStore()
        PreferencesOpener.select(store, tab: .projects, project: "/Users/someone/Code/app")
        XCTAssertEqual(store.selectedTab, .projects)
        XCTAssertEqual(store.selectedProjectPath, "/Users/someone/Code/app")
    }

    func testTheProjectPathIsStandardized() {
        // `ProjectsSettingsTab` tags its rows with `standardizedFileURL.path`; a path spelled
        // any other way is a selection that matches no row, which reads as "nothing happened".
        let (store, _) = makeStore()
        PreferencesOpener.select(store, tab: .projects, project: "/Users/someone/Code/../Code/app/")
        XCTAssertEqual(store.selectedProjectPath, "/Users/someone/Code/app")
    }

    func testOpeningAnotherPaneLeavesTheProjectAlone() {
        // Settings opened from the Tools menu must not discard where the Projects pane was
        // pointed — the panes are independent, and the user may switch back by hand.
        let (store, _) = makeStore()
        PreferencesOpener.select(store, tab: .projects, project: "/Users/someone/Code/app")
        PreferencesOpener.select(store, tab: .tools)
        XCTAssertEqual(store.selectedProjectPath, "/Users/someone/Code/app")
    }

    func testANilStoreIsSurvivable() {
        // `SessionStore.preferences` is optional, and the hermetic UITest gate runs with it nil.
        PreferencesOpener.select(nil, tab: .projects, project: "/Users/someone/Code/app")
    }

    func testSelectingAProjectDoesNotWriteToDisk() {
        // Same reasoning as `selectedTab`: this is transient view state, and `preferences`'s
        // didSet persists the whole blob on every mutation.
        let (store, persistence) = makeStore()
        let before = persistence.saveCount
        PreferencesOpener.select(store, tab: .projects, project: "/Users/someone/Code/app")
        XCTAssertEqual(persistence.saveCount, before)
    }

    func testTheSelectedProjectDoesNotSurviveARelaunch() {
        let (store, persistence) = makeStore()
        PreferencesOpener.select(store, tab: .projects, project: "/Users/someone/Code/app")
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])  // force a real save

        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertNil(reopened.selectedProjectPath)
    }
}
