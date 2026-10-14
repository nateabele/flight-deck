import XCTest
@testable import FlightDeck

/// Pins the Task 14 fix-round bug: before `CurrentProjectObserver` existed, the File menu's
/// New Session rows (then `SessionCommands`, now `NewSessionMenuController`) had nothing that
/// would notice a project switch on its own — its ⌘N key
/// equivalent closed over `slot.agent` from whatever project was active the *last* time
/// `preferences` changed and rebuilt `body`. These tests exercise the observer directly;
/// `NewSessionMenuTests` covers the File menu items it drives.
@MainActor
final class CurrentProjectObserverTests: XCTestCase {
    private func makeStore(_ preferences: PreferencesStore) -> SessionStore {
        SessionStore(provider: nil, persistence: nil, preferences: preferences)
    }

    /// Spins the run loop briefly so the observer's `.debounce(for: .zero, scheduler: RunLoop
    /// .main)` gets a turn to fire — Combine's zero-interval debounce still schedules through
    /// the run loop rather than firing synchronously, which is the entire point (see the
    /// observer's own doc comment on why a synchronous read would be stale).
    private func pump(until condition: () -> Bool) {
        spinRunLoop(until: condition)
    }

    func testTheObserverStartsAtTheStoresCurrentProject() {
        let preferences = PreferencesStore(persistence: nil)
        let store = makeStore(preferences)
        _ = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        let observer = CurrentProjectObserver(store: store)

        XCTAssertEqual(observer.path, "/a")
    }

    /// The bug itself: switching the active project, with no `preferences` change at all,
    /// must still change what the observer reports.
    func testTheObserverFollowsAProjectSwitchWithNoPreferencesChange() {
        let preferences = PreferencesStore(persistence: nil)
        let store = makeStore(preferences)
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))
        store.selectedSessionID = a.id
        let observer = CurrentProjectObserver(store: store)
        XCTAssertEqual(observer.path, "/a")

        store.selectedSessionID = b.id
        pump { observer.path == "/b" }

        XCTAssertEqual(observer.path, "/b", "the observer must track the newly active project")
    }

    /// The point of the whole fix, stated the way the brief's invariant states it: ⌘N's
    /// resolved agent — `preferences.agentOrder(forProject:)` fed by the observer's `path`,
    /// exactly as `SessionCommands.agentsForCurrentProject` computes it — must follow the
    /// project actually switched to, not the one that was active when the menu last rebuilt
    /// for an unrelated reason.
    func testTheResolvedAgentOrderFollowsTheProjectSwitch() {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet())),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
        preferences.preferences.projectSettings["/b"] = ProjectSettings(defaultAgent: .codex)
        let store = makeStore(preferences)
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))
        store.selectedSessionID = a.id
        let observer = CurrentProjectObserver(store: store)
        XCTAssertEqual(
            preferences.agentOrder(forProject: observer.path ?? "").map(\.id), [.claude, .codex]
        )

        store.selectedSessionID = b.id
        pump { observer.path == "/b" }

        XCTAssertEqual(
            preferences.agentOrder(forProject: observer.path ?? "").map(\.id), [.codex, .claude],
            "⌘N must resolve to the switched-to project's own default agent, not the previous one"
        )
    }
}
