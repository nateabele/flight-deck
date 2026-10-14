import Foundation
import IntakeKit
import XCTest
@testable import FlightDeck

/// "Check again" in the Rounds editor, and the app-active re-detection: planning's agent
/// detection used to run once per launch, so a CLI signed in after launch (`grok login`) stayed
/// "unavailable" in every agent menu until Flight Deck was relaunched. Every test drives the
/// detection seam (`detectAgents`); none spawns a real CLI.
@MainActor
final class AgentRecheckTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRecheckTests-\(UUID())", isDirectory: true)
        suiteName = "AgentRecheckTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var signedOut: AvailableModels {
        var available = AvailableModels.defaults
        available.unavailable[.grok] = "Grok: run `grok login`"
        return available
    }

    private var signedIn: AvailableModels {
        var available = AvailableModels(choices: [.claude: AvailableModels.defaults.claude!,
                                                  .codex: AvailableModels.defaults.codex!, .grok: grok])
        available.models[.grok] = ["grok-4.7"]
        return available
    }

    private func makeService(available: AvailableModels?, now: @escaping () -> Date = Date.init,
                             detect: @escaping @Sendable () -> AvailableModels) -> IntakeService {
        IntakeService(store: IntakeStore(root: root), availableModels: available,
                      inject: { _, _, _, _ in true }, hasSession: { _, _ in false }, now: now,
                      defaults: defaults, detectAgents: detect)
    }

    // MARK: - Check again

    func testRecheckPublishesTheNewDetection() async {
        let after = signedIn
        let service = makeService(available: signedOut) { after }
        XCTAssertNil(service.availableModels().choice(for: .grok))

        await service.recheckAgents().value

        XCTAssertEqual(service.availableModels().choice(for: .grok), grok,
                       "an agent signed in after launch is offered without a relaunch")
        XCTAssertEqual(service.detectedModels, after, "Settings' tab model pickers read the same refreshed value")
        XCTAssertFalse(service.isDetectingAgents)
    }

    func testRecheckShowsProgressUntilItLands() async {
        let gate = Gate()
        let after = signedIn
        let service = makeService(available: signedOut) { gate.wait(); return after }

        let task = service.recheckAgents()
        XCTAssertTrue(service.isDetectingAgents, "the spinner shows while the probes run")
        gate.open()
        await task.value
        XCTAssertFalse(service.isDetectingAgents)
    }

    func testConcurrentPressesCoalesceIntoOneRun() async {
        let gate = Gate(), runs = Counter()
        let after = signedIn
        let service = makeService(available: signedOut) { runs.increment(); gate.wait(); return after }

        let first = service.recheckAgents()
        let second = service.recheckAgents()
        let third = service.recheckAgents()
        gate.open()
        await first.value; await second.value; await third.value

        XCTAssertEqual(runs.value, 1, "three presses while one detection runs spawn the probes once")

        await service.recheckAgents().value
        XCTAssertEqual(runs.value, 2, "a press after the run lands starts a fresh one")
    }

    func testLaunchDetectionAndAPressShareOneRun() async {
        let gate = Gate(), runs = Counter()
        let after = signedIn
        // nil: the launch warm-up starts detection itself.
        let service = makeService(available: nil) { runs.increment(); gate.wait(); return after }
        let press = service.recheckAgents()
        gate.open()
        await press.value
        XCTAssertEqual(runs.value, 1, "a press during the launch probe joins it rather than racing it")
        XCTAssertEqual(service.availableModels().choice(for: .grok), grok)
    }

    // MARK: - App became active

    func testActivationRechecksOnlyWhileAnAgentIsSignedOutAndAtMostOncePerMinute() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let runs = Counter()
        let before = signedOut
        let service = makeService(available: signedOut, now: { clock }) { runs.increment(); return before }

        await service.appDidBecomeActive()?.value
        XCTAssertEqual(runs.value, 1, "something is signed out and nothing has been checked yet")

        clock += 30
        XCTAssertNil(service.appDidBecomeActive(), "within a minute of the last check: no probe")
        XCTAssertEqual(runs.value, 1)

        clock += 31
        await service.appDidBecomeActive()?.value
        XCTAssertEqual(runs.value, 2, "a minute on, still signed out: check again")
    }

    func testActivationDoesNothingWhenEveryAgentIsReady() {
        let runs = Counter()
        let service = makeService(available: signedIn) { runs.increment(); return AvailableModels.defaults }
        XCTAssertNil(service.appDidBecomeActive())
        XCTAssertEqual(runs.value, 0)
    }

    func testActivationIgnoresAnAgentThatIsMerelyNotInstalled() {
        var available = AvailableModels.defaults
        available.unavailable[.gemini] = "Gemini: not installed"
        let runs = Counter()
        let service = makeService(available: available) { runs.increment(); return available }
        XCTAssertNil(service.appDidBecomeActive(),
                     "a CLI never installed is not news, and must not cost a probe on every activation")
        XCTAssertEqual(runs.value, 0)
    }

    func testActivationCountsAManualPressAsTheLastCheck() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let runs = Counter()
        let before = signedOut
        let service = makeService(available: signedOut, now: { clock }) { runs.increment(); return before }
        await service.recheckAgents().value
        clock += 10
        XCTAssertNil(service.appDidBecomeActive())
        XCTAssertEqual(runs.value, 1)
    }

    // MARK: - Editor

    func testCheckAgainShowsOnlyBesideASignInNote() {
        XCTAssertTrue(RoundConfigEditor.offersRecheck(signedOut))
        XCTAssertFalse(RoundConfigEditor.offersRecheck(signedIn))
        var notInstalled = AvailableModels.defaults
        notInstalled.unavailable[.gemini] = "Gemini: not installed"
        XCTAssertFalse(RoundConfigEditor.offersRecheck(notInstalled),
                       "no button beside a note the editor doesn't show")
    }

    func testUnavailableNoteComesBeforeDataUseNotes() {
        var available = signedIn
        available.unavailable[.gemini] = "Gemini: run `agy` in a terminal to sign in"
        XCTAssertEqual(RoundConfigEditor.unavailableNotes(available), ["Gemini: run `agy` in a terminal to sign in"])
        XCTAssertEqual(RoundConfigEditor.availabilityNotes(available),
                       RoundConfigEditor.unavailableNotes(available) + RoundConfigEditor.dataUseNotes(available))
    }

    /// A re-check that finds an agent signed out again never rewrites a role the human already
    /// gave it: the row keeps the agent, labelled unavailable, instead of a blank picker.
    func testAChosenAgentThatBecameUnavailableStaysInItsPicker() {
        let lost = signedOut
        XCTAssertTrue(RoundConfigEditor.menuAgents(in: lost, chosen: .grok).contains(.grok))
        XCTAssertNotNil(RoundConfigEditor.unavailableReason(.grok, available: lost), "listed, but disabled")
        XCTAssertTrue(RoundConfigEditor.menuAgents(in: signedIn, chosen: .grok).contains(.grok))
        XCTAssertNil(RoundConfigEditor.unavailableReason(.grok, available: signedIn))
    }
}

/// A one-shot latch a detection closure parks on, so a test can observe the "running" state.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait(); semaphore.signal() }
    func open() { semaphore.signal() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
