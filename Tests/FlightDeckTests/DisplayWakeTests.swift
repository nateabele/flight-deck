import XCTest
@testable import FlightDeck

/// Companion to `DisplayDrawableGuardTests`, which pins what happens when the display cannot
/// be woken. This pins what happens when it can.
@MainActor
final class DisplayWakeTests: XCTestCase {
    private final class Reporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    /// Starts un-drawable and becomes drawable the moment the waker is used, which is the
    /// real sequence compressed: declare activity, then the display comes up.
    private final class Waker: DisplayWaking, @unchecked Sendable {
        let succeeds: Bool
        private let onWake: @Sendable () -> Void
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        init(succeeds: Bool, onWake: @escaping @Sendable () -> Void = {}) {
            self.succeeds = succeeds
            self.onWake = onWake
        }
        func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
            lock.lock(); _calls += 1; lock.unlock()
            if succeeds { onWake() }
            return succeeds
        }
    }

    private final class MutableDisplay: DisplayInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _drawable: Bool
        init(_ drawable: Bool) { _drawable = drawable }
        var isDrawable: Bool { lock.lock(); defer { lock.unlock() }; return _drawable }
        func set(_ v: Bool) { lock.lock(); _drawable = v; lock.unlock() }
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    // `SessionStore.provider` is weak; an unretained stub would deallocate immediately and
    // silently turn these into "no provider" tests. Same reason as `DisplayDrawableGuardTests`.
    private var retainedProviders: [StubProvider] = []

    private func makeStore(
        drawable: Bool, wakeSucceeds: Bool
    ) -> (SessionStore, Reporter, Waker) {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let reporter = Reporter()
        let display = MutableDisplay(drawable)
        let waker = Waker(succeeds: wakeSucceeds, onWake: { display.set(true) })
        store.launchFailureReporter = reporter
        store.display = display
        store.displayWaker = waker
        return (store, reporter, waker)
    }

    /// The point of the whole change: asleep is no longer a refusal.
    func testASleepingDisplayIsWokenAndTheSessionIsCreated() {
        let (store, reporter, waker) = makeStore(drawable: false, wakeSucceeds: true)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 1)
        XCTAssertTrue(reporter.reported.isEmpty, "a woken display must not report a failure")
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// The guard is not removed, only made exceptional. A wake that fails must refuse exactly
    /// as before rather than birth an inert tab.
    func testAFailedWakeStillRefusesExactlyAsBefore() {
        let (store, reporter, waker) = makeStore(drawable: false, wakeSucceeds: false)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 1)
        XCTAssertEqual(reporter.reported, [.terminalUnavailable(displayAsleep: true)])
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty)
    }

    /// The awake path must stay free — no assertion, no blocking, on every ordinary creation.
    func testAnAwakeDisplayIsNeverWoken() {
        let (store, _, waker) = makeStore(drawable: true, wakeSucceeds: true)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 0)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// Seeding runs inline inside `SessionStore.init`. Waking there would light the screen up
    /// on an unattended relaunch and block startup while doing it.
    func testSeedingNeverWakesTheDisplay() {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        store.seedInitialSession(homeURL: tmp)
        XCTAssertEqual(waker.calls, 0, "app launch is not someone asking for a terminal")
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty)
    }

    /// With no provider there is no libghostty, so there is no drawable to need and nothing
    /// to wake. Pinned so the suite's fixtures never start poking the display.
    func testWithNoProviderNothingIsWoken() {
        let store = SessionStore(provider: nil, persistence: nil)
        let waker = Waker(succeeds: true)
        store.display = MutableDisplay(false)
        store.displayWaker = waker
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 0)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// codex does not route through `newSession(in:)`, so it needs its own guard — and
    /// therefore its own wake. R1 of the original guard missed this path.
    func testCreateSessionWakesASleepingDisplay() async {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        _ = await store.createSession(agent: .claude, in: tmp.path)
        XCTAssertEqual(waker.calls, 1)
    }

    func testCreateSessionStillFailsWhenTheWakeFails() async {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: false)
        let result = await store.createSession(agent: .claude, in: tmp.path)
        XCTAssertEqual(waker.calls, 1)
        guard case .failure(let error) = result else {
            return XCTFail("a display that will not wake must still refuse")
        }
        XCTAssertEqual(error, .terminalUnavailable(displayAsleep: true))
    }

    /// Signing in bypasses `createSession` entirely, so it too needs its own wake.
    func testOpenSignInSessionWakesASleepingDisplay() {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        let account = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: "/tmp/claude-work")
        )
        _ = store.openSignInSession(
            for: account, in: tmp.path,
            using: LoginInvocation(command: "claude", inject: nil)
        )
        XCTAssertEqual(waker.calls, 1)
    }

    /// Restart Terminal on an inert tab. Reachable while the display is asleep — that is
    /// precisely the state that produced the inert tab in the first place.
    func testRespawnWakesASleepingDisplay() {
        let (store, _, waker) = makeStore(drawable: true, wakeSucceeds: true)
        let session = store.newSession(in: tmp)
        (store.display as? MutableDisplay)?.set(false)
        _ = store.respawnSurface(for: session.id)
        XCTAssertEqual(waker.calls, 1)
    }

    func testRespawnStillReportsDisplayAsleepWhenTheWakeFails() {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let display = MutableDisplay(true)
        store.display = display
        store.displayWaker = Waker(succeeds: false)
        let session = store.newSession(in: tmp)
        display.set(false)
        XCTAssertEqual(store.respawnSurface(for: session.id), .displayAsleep)
    }

    /// The wiring that makes the wake real, mirroring `testTheRealProbeIsWiredIn`. Deleting
    /// the assignment in `convenience init` is otherwise undetectable: the inert default
    /// silently turns every sleeping display back into a refusal, and no test fails.
    func testTheRealWakerIsWiredIn() {
        let store = SessionStore(ghostty: nil, persistence: nil)
        XCTAssertTrue(store.displayWaker is DisplayWaker)
    }

    /// A deliberately weak check: `DisplayState` is a stateless struct that always reads
    /// `CGMainDisplayID()`, so no two instances of it can disagree and identity cannot be
    /// asserted. This pins the narrower thing that matters — that the wired waker polls a
    /// real display probe, not a stub or the inert default — which is what building it around
    /// the store's own probe is for.
    func testTheWiredWakerPollsTheStoresOwnProbe() throws {
        let store = SessionStore(ghostty: nil, persistence: nil)
        let waker = try XCTUnwrap(store.displayWaker as? DisplayWaker)
        XCTAssertTrue(waker.display is DisplayState)
    }
}
