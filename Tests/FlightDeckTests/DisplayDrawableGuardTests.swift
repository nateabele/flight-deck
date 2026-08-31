import XCTest
@testable import FlightDeck

@MainActor
final class DisplayDrawableGuardTests: XCTestCase {
    private final class Reporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }
    private struct Display: DisplayInspecting { var isDrawable: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    // Same reason as `SessionCreationTests`/`CreateFromMenuAgentTests`: `SessionStore.provider`
    // is `weak`, so an unretained `StubProvider` would deallocate immediately — which would
    // silently turn every "provider exists" test here into a "no provider" one.
    private var retainedProviders: [StubProvider] = []

    /// A provider is REQUIRED for these tests: `canCreateTerminal` is deliberately permissive
    /// when there is none, because the drawable is libghostty's requirement and the suite's
    /// fixtures create sessions with `provider: nil`. `StubProvider` (lifted from
    /// `PhonePromptDispatchTests`) returns nil from `makeSurface` — a provider that is present
    /// but makes no surface, which is what production looks like to this guard.
    private func makeStore(drawable: Bool) -> (SessionStore, Reporter) {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let reporter = Reporter()
        store.launchFailureReporter = reporter
        store.display = Display(isDrawable: drawable)
        return (store, reporter)
    }

    /// The bug: a tab was created, persisted and broadcast with no terminal and no error.
    /// Refused BEFORE creation, so no corpse exists to clean up.
    func testCreationIsRefusedWhenTheDisplayCannotBeDrawnTo() {
        let (store, reporter) = makeStore(drawable: false)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(reporter.reported, [.terminalUnavailable(displayAsleep: true)])
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab that cannot get a terminal must never be created")
    }

    /// The guard must not fire in the ordinary case; the suite's own fixtures depend on it.
    func testCreationProceedsWhenTheDisplayIsDrawable() {
        let (store, reporter) = makeStore(drawable: true)
        _ = store.newSession(in: tmp)
        XCTAssertTrue(reporter.reported.isEmpty)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    func testCanCreateTerminalMirrorsTheDisplayWhenAProviderExists() {
        XCTAssertFalse(makeStore(drawable: false).0.canCreateTerminal)
        XCTAssertTrue(makeStore(drawable: true).0.canCreateTerminal)
    }

    /// The escape hatch the whole suite leans on, pinned so nobody "tidies" it away: with no
    /// provider there is no libghostty, so the drawable is irrelevant and creation proceeds.
    func testWithNoProviderTheGuardDoesNotApply() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.display = Display(isDrawable: false)
        XCTAssertTrue(store.canCreateTerminal)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// The message names the cause, because the cause is invisible and the fix is physical.
    func testTheMessageNamesTheDisplay() {
        XCTAssertEqual(
            AgentLaunchError.terminalUnavailable(displayAsleep: true).errorDescription,
            "Flight Deck could not open a terminal because this Mac's display is asleep. "
            + "Wake it and try again.")
        XCTAssertEqual(
            AgentLaunchError.terminalUnavailable(displayAsleep: false).errorDescription,
            "Flight Deck could not open a terminal for this session.")
    }
}
