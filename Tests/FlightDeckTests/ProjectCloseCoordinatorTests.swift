import XCTest
@testable import FlightDeck

@MainActor
final class ProjectCloseCoordinatorTests: XCTestCase {
    final class FakeConfirmer: ProjectCloseConfirming {
        var decision = ProjectCloseDecision(confirmed: true, suppressFutureConfirmations: false)
        var calls: [(name: String, count: Int)] = []

        func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision {
            calls.append((name, sessionCount))
            return decision
        }
    }

    private func fixture(
        sessionsInA: Int
    ) -> (SessionStore, PreferencesStore, FakeConfirmer, Repo.ID) {
        let store = SessionStore(
            provider: nil, persistence: SessionPersistenceTests.FakePersistence()
        )
        for _ in 0..<sessionsInA {
            store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        }
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        return (store, preferences, FakeConfirmer(), store.repos[0].id)
    }

    func testConfirmationDefaultsToOn() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())

        XCTAssertTrue(preferences.confirmsProjectClose)
    }

    func testPreferencesDecodeWithoutTheConfirmationsKey() throws {
        // A v1 preferences blob predates the field. If this throws, `load()` returns nil and
        // every flag, override and shell setting the user has is silently reset.
        //
        // Built from a real `Preferences()` rather than hand-written JSON, so this test
        // stays about the missing key rather than guessing `FlagSet`'s encoding.
        let encoded = try JSONEncoder().encode(Preferences())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "confirmations")
        let json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try? JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNotNil(decoded, "adding a non-optional key here wipes every preference")
    }

    func testMoreThanOneSessionPrompts() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertEqual(confirmer.calls.count, 1)
        XCTAssertEqual(confirmer.calls.first?.count, 2)
        XCTAssertEqual(confirmer.calls.first?.name, "a")
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testExactlyOneSessionClosesWithoutPrompting() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 1)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAnEmptyProjectClosesWithoutPrompting() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 1)
        store.closeSession(store.repos[0].sessions[0].id)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testSuppressedPreferenceSkipsThePrompt() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 3)
        preferences.confirmsProjectClose = false
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testCancellingClosesNothing() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: false, suppressFutureConfirmations: false)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
    }

    func testTickingSuppressionWritesThePreference() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: true, suppressFutureConfirmations: true)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertFalse(preferences.confirmsProjectClose)
    }

    func testSuppressionIsRecordedEvenWhenCancelling() async {
        // macOS convention: the suppression box applies to the decision the user just made,
        // whichever button they pressed.
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: false, suppressFutureConfirmations: true)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertFalse(preferences.confirmsProjectClose)
        XCTAssertEqual(store.repos.count, 1)
    }

    func testSuppressionRoundTripsThroughPersistence() {
        let persistence = PreferencesStoreTests.MemoryPersistence()
        let preferences = PreferencesStore(persistence: persistence)

        preferences.confirmsProjectClose = false

        XCTAssertFalse(PreferencesStore(persistence: persistence).confirmsProjectClose)
    }
}
