import XCTest
@testable import FlightDeck

/// The window title rule, and the store property that feeds it.
///
/// Split this way because the two halves fail differently. `WindowTitle.text` is a pure
/// string rule and can be pinned exactly; `currentProjectName` is the part that has to
/// *follow a session switch*, which is the behaviour actually asked for — a title that is
/// correct at launch and then never moves would satisfy the first half completely.
///
/// What neither half covers is SwiftUI actually writing the string onto the `NSWindow`.
/// That needs a real window and a real scene, so it lives in `TerminalSmokeTests`
/// ("the window title names the active project").
@MainActor
final class WindowTitleTests: XCTestCase {
    // MARK: the rule

    func testTheTitleNamesTheProject() {
        XCTAssertEqual(WindowTitle.text(project: "flight-deck"), "Flight Deck - flight-deck")
    }

    /// The separator is a plain hyphen with single spaces. Pinned literally rather than
    /// assembled from `WindowTitle.base`, so a change to the format has to be made here too
    /// and cannot ride along silently.
    func testTheSeparatorIsAPlainHyphen() {
        XCTAssertEqual(WindowTitle.text(project: "x"), "Flight Deck - x")
        XCTAssertFalse(WindowTitle.text(project: "x").contains("—"))
        XCTAssertFalse(WindowTitle.text(project: "x").contains("–"))
    }

    func testNoProjectLeavesTheBareProductName() {
        XCTAssertEqual(WindowTitle.text(project: nil), "Flight Deck")
    }

    /// `Repo.displayName` is a URL's `lastPathComponent`, which is empty for `/`. Rendering
    /// it would leave "Flight Deck - " with a dangling separator.
    func testABlankProjectNameLeavesTheBareProductName() {
        XCTAssertEqual(WindowTitle.text(project: ""), "Flight Deck")
        XCTAssertEqual(WindowTitle.text(project: "   "), "Flight Deck")
    }

    // MARK: what the rule is asked about

    private func makeStore() -> SessionStore {
        SessionStore(provider: nil, persistence: nil, preferences: PreferencesStore(persistence: nil))
    }

    func testTheStoreNamesTheActiveSessionsProject() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/tmp/alpha", isDirectory: true))

        XCTAssertEqual(store.currentProjectName, "alpha")
        XCTAssertEqual(WindowTitle.text(project: store.currentProjectName), "Flight Deck - alpha")
    }

    /// The whole point: switching sessions across projects has to move the title.
    func testSwitchingSessionsRetitlesTheWindow() {
        let store = makeStore()
        let alpha = store.newSession(in: URL(fileURLWithPath: "/tmp/alpha", isDirectory: true))
        let beta = store.newSession(in: URL(fileURLWithPath: "/tmp/beta", isDirectory: true))

        store.selectSession(beta.id)
        XCTAssertEqual(WindowTitle.text(project: store.currentProjectName), "Flight Deck - beta")

        store.selectSession(alpha.id)
        XCTAssertEqual(WindowTitle.text(project: store.currentProjectName), "Flight Deck - alpha")
    }

    /// Two sessions in ONE project keep one title — the name is the project's, not the tab's.
    func testSwitchingWithinAProjectKeepsTheTitle() {
        let store = makeStore()
        let first = store.newSession(in: URL(fileURLWithPath: "/tmp/alpha", isDirectory: true))
        let second = store.newSession(in: URL(fileURLWithPath: "/tmp/alpha", isDirectory: true))
        _ = store.rename(second.id, to: "a different tab name")

        store.selectSession(second.id)
        XCTAssertEqual(store.currentProjectName, "alpha")
        store.selectSession(first.id)
        XCTAssertEqual(store.currentProjectName, "alpha")
    }

    /// Clearing the selection — clicking below the last sidebar row — shows the "No Session"
    /// empty state, so the title must stop naming a project rather than fall back to the last
    /// one the way `currentProjectPath` does for ⌘N routing.
    func testNoSelectionDropsTheProjectFromTheTitle() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/tmp/alpha", isDirectory: true))

        store.selectedSessionID = nil

        XCTAssertNil(store.currentProjectName)
        XCTAssertEqual(WindowTitle.text(project: store.currentProjectName), "Flight Deck")
        XCTAssertEqual(
            store.currentProjectPath, "/tmp/alpha",
            "currentProjectPath must keep its ⌘N fallback; only the title drops the project"
        )
    }
}
