import FleetKit
import XCTest
@testable import FlightDeck

/// A code built at runtime a test needs to compare against, in the shape
/// `TimelineErrorCode(stringLiteral:)` already gives production call sites — see Ruling C in
/// the task brief: no `failureCode` member exists anywhere in the repo, so it is added here,
/// test-local, rather than shipped in `Sources` where nothing needs it.
extension Result where Success == Void, Failure == TimelineErrorCode {
    var failureCode: String? {
        guard case .failure(let code) = self else { return nil }
        return code.code
    }
}

/// The Mac half of a plan gate.
final class PlanGateServiceTests: XCTestCase {

    /// A gate the phone never saw. Answering it would resolve a plan the reader did not read.
    @MainActor
    func testRefusesACallItDoesNotHave() async {
        let (service, _) = makeService(plan: "# A\n\nB.", callID: "toolu_REAL")
        await service.refresh()
        let result = await service.resolve(
            session: service.knownSession, call: "toolu_OTHER",
            approve: true, feedback: nil, token: UUID()
        )
        XCTAssertEqual(result.failureCode, "prompt_changed")
    }

    /// A retry that lands is an answer that landed — the ruling `answeredPromptTokens` makes
    /// for `prompt.answer`, applied here so a flaky link cannot double-resolve.
    @MainActor
    func testTheSameTokenResolvesOnlyOnce() async {
        let (service, transport) = makeService(plan: "# A\n\nB.", callID: "c")
        await service.refresh()
        let token = UUID()
        let first = await service.resolve(session: service.knownSession, call: "c",
                                          approve: true, feedback: nil, token: token)
        let second = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: token)
        XCTAssertNil(first.failureCode)
        XCTAssertNil(second.failureCode, "a duplicate is an ack, not an error")
        let resolveCallCount = await transport.resolveCallCount
        XCTAssertEqual(resolveCallCount, 1, "the gate must be resolved exactly once")
    }

    /// The block index is resolved against the Mac's own split. A phone naming a block this
    /// plan does not have gets nothing pinned.
    @MainActor
    func testAnnotateResolvesTheBlockIndexLocally() async {
        let (service, transport) = makeService(plan: "First block.\n\nSecond block.", callID: "c")
        await service.refresh()
        let ok = await service.annotate(session: service.knownSession, call: "c",
                                        text: "note", block: 1, token: UUID())
        XCTAssertNil(ok.failureCode)
        let lastAnnotation = await transport.lastAnnotation
        XCTAssertEqual(lastAnnotation?.originalText, "Second block.")
    }

    @MainActor
    func testAnnotateRefusesAnOutOfRangeBlock() async {
        let (service, transport) = makeService(plan: "Only one.", callID: "c")
        await service.refresh()
        let result = await service.annotate(session: service.knownSession, call: "c",
                                            text: "note", block: 9, token: UUID())
        XCTAssertEqual(result.failureCode, "unreadable_screen")
        let lastAnnotation = await transport.lastAnnotation
        XCTAssertNil(lastAnnotation)
    }

    /// A non-target block cannot be pinned; the comment goes global rather than pinning to an
    /// arbitrary copy. Both halves of that must hold: the downgrade is a *different* outcome
    /// than a refusal (an empty `lastAnnotation` reads the same for either), so this asserts
    /// the comment actually went out, not just that it went out unpinned.
    @MainActor
    func testANonTargetBlockBecomesAGlobalComment() async {
        let (service, transport) = makeService(plan: "A.\n\n---\n\nB.", callID: "c")
        await service.refresh()
        let breakIndex = PlanBlocks.split("A.\n\n---\n\nB.").blocks
            .firstIndex { !$0.isTarget }!
        let result = await service.annotate(session: service.knownSession, call: "c",
                                            text: "note", block: breakIndex, token: UUID())
        XCTAssertNil(result.failureCode, "a non-target block is a downgrade, not a refusal")
        let lastAnnotation = await transport.lastAnnotation
        XCTAssertEqual(lastAnnotation?.text, "note", "the comment must actually have been posted")
        XCTAssertNil(lastAnnotation?.originalText, "a non-target must not be sent as an anchor")
    }

    /// The gate closed between the tap and the command — hook killed, or answered on the Mac.
    @MainActor
    func testAVanishedGateRefuses() async {
        let (service, _) = makeService(plan: "# A", callID: "c")
        await service.refresh()
        service.killGate()
        await service.refresh()
        let result = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: UUID())
        XCTAssertEqual(result.failureCode, "not_waiting")
    }

    /// The plan is fetched once, not on every poll: a 4-day gate polled every 2s would be
    /// 170,000 requests for a document that cannot change without the callID changing.
    @MainActor
    func testThePlanIsFetchedOncePerGate() async {
        let (service, transport) = makeService(plan: "# A", callID: "c")
        await service.refresh()
        await service.refresh()
        await service.refresh()
        let planFetchCount = await transport.planFetchCount
        XCTAssertEqual(planFetchCount, 1)
    }

    /// The Plannotator hook sleeps for a beat before its server actually stops, so the
    /// registry file backing a gate this Mac just resolved can still be on disk when the next
    /// poll runs. That poll must not re-fetch the plan or re-open what the phone already
    /// closed — regression coverage for the sequential-resurrection defect.
    @MainActor
    func testAResolvedGateIsNotResurrectedByALaterPoll() async {
        let (service, transport) = makeService(plan: "# A", callID: "c")
        await service.refresh()
        let result = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: UUID())
        XCTAssertNil(result.failureCode)
        XCTAssertNil(service.gate(for: service.knownSession))

        // `killGate()` was not called: the fake registry file is still on disk, standing in
        // for the hook's server still winding down after the resolve.
        await service.refresh()
        XCTAssertNil(service.gate(for: service.knownSession),
                     "a resolved gate must not be resurrected by a later poll")
        let planFetchCount = await transport.planFetchCount
        XCTAssertEqual(planFetchCount, 1, "must not re-fetch a plan it already resolved")
    }

    /// A concurrent `annotate` on one session must survive a `refresh()` that is, at that
    /// moment, suspended fetching a *different* session's plan. Regression coverage for the
    /// wholesale-rebuild defect: gathering kept-and-fetched gates into a separate dictionary
    /// and swapping it in at the end discarded whatever a concurrent annotate/resolve had
    /// mutated on another session while the fetch was in flight.
    @MainActor
    func testAConcurrentAnnotateSurvivesAnInFlightRefresh() async {
        let sessionA = UUID()
        let sessionB = UUID()
        let claudePIDA: pid_t = 4300
        let claudePIDB: pid_t = 4301
        let plannotatorPIDA: pid_t = 9100
        let plannotatorPIDB: pid_t = 9101
        let portA = 54300
        let portB = 54301

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanGateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        func writeEntry(pid: pid_t, port: Int) {
            let json = """
            {"pid":\(pid),"port":\(port),"url":"http://localhost:\(port)",\
            "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
            """
            try? Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
        }
        writeEntry(pid: plannotatorPIDA, port: portA)
        writeEntry(pid: plannotatorPIDB, port: portB)

        let transportA = RecordingTransport(plan: "# A", registryDirectory: dir)
        let transportB = RecordingTransport(plan: "# B", registryDirectory: dir)

        // A `var` a closure captures by reference, so the second refresh can be made to see a
        // fresh call id for B — standing in for a new plan gate opening on that session.
        var currentCallIDB = "callB1"

        let service = PlanGateService(
            callID: { session in
                if session == sessionA { return "callA" }
                if session == sessionB { return currentCallIDB }
                return nil
            },
            pid: { session in
                if session == sessionA { return claudePIDA }
                if session == sessionB { return claudePIDB }
                return nil
            },
            sessions: { [sessionA, sessionB] }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { pid in
            if pid == plannotatorPIDA { return claudePIDA }
            if pid == plannotatorPIDB { return claudePIDB }
            return nil
        }
        service.makeClient = { port in
            let transport = port == portA ? transportA : transportB
            return PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }

        // Both sessions are new, so this refresh fetches both — synchronously, since neither
        // transport is paused yet.
        await service.refresh()
        XCTAssertNotNil(service.gate(for: sessionA))
        XCTAssertNotNil(service.gate(for: sessionB))

        // Force the next refresh to need a fetch only for B, and pause that fetch so the
        // refresh suspends mid-flight with A's already-cached gate simply kept, untouched.
        currentCallIDB = "callB2"
        await transportB.pauseNextPlanFetch()

        async let refreshTask: Void = service.refresh()
        await transportB.waitUntilPaused()

        let annotateResult = await service.annotate(
            session: sessionA, call: "callA", text: "note", block: nil, token: UUID()
        )
        XCTAssertNil(annotateResult.failureCode)

        await transportB.resume()
        await refreshTask

        XCTAssertEqual(
            service.gate(for: sessionA)?.annotationCount, 1,
            "a refresh suspended fetching a different session's plan must not undo a concurrent annotate"
        )
    }

    /// A session lands in `refresh()`'s fetch list either because it is brand new, or because
    /// its gate was superseded — a new `ExitPlanMode` call moved the call id this service still
    /// holds a `Gate` for. If the refetch for that second case fails, the old `Gate` — old call
    /// id, old plan text, old `annotationCount` — must not be left in place and keep being
    /// projected to the phone as though it were still the live gate. Regression coverage for
    /// the stale-gate-on-failed-refetch defect.
    @MainActor
    func testASupersededGateWhoseRefetchFailsIsNotLeftProjectingStaleData() async {
        let session = UUID()
        let claudePID: pid_t = 4400
        let plannotatorPID: pid_t = 9200
        let port = 54400

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanGateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let registryJSON = """
        {"pid":\(plannotatorPID),"port":\(port),"url":"http://localhost:\(port)",\
        "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
        """
        try? Data(registryJSON.utf8).write(to: dir.appendingPathComponent("\(plannotatorPID).json"))

        let transport = RecordingTransport(plan: "# A", registryDirectory: dir)
        // A `var` the closure captures by reference, so the second refresh can be made to see
        // a new call id — standing in for a new `ExitPlanMode` call superseding the first.
        var currentCallID = "c1"

        let service = PlanGateService(
            callID: { $0 == session ? currentCallID : nil },
            pid: { $0 == session ? claudePID : nil },
            sessions: { [session] }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { $0 == plannotatorPID ? claudePID : nil }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }

        await service.refresh()
        XCTAssertNotNil(service.gate(for: session), "the first call's gate must be live")

        // The call id moves on, but this time the refetch fails.
        currentCallID = "c2"
        await transport.failNextPlanFetch()
        await service.refresh()

        XCTAssertNil(
            service.gate(for: session),
            "a superseded gate whose refetch failed must not keep projecting the old, stale plan"
        )
    }
}

// MARK: - Fixtures

/// Stands in for Plannotator's HTTP API and counts what it saw. An actor, not a plain class:
/// `testAConcurrentAnnotateSurvivesAnInFlightRefresh` needs a fetch it can genuinely suspend on
/// (via `pauseNextPlanFetch`/`waitUntilPaused`/`resume`) so a concurrent mutation on another
/// session has a real window to land in, and actor isolation is what makes that safe to drive
/// from two overlapping tasks.
private actor RecordingTransport {
    private let plan: String
    /// Kept only so a test can point `addTeardownBlock` at the right directory when it builds
    /// more than one fixture by hand, as `testAConcurrentAnnotateSurvivesAnInFlightRefresh` does.
    let registryDirectory: URL
    private(set) var planFetchCount = 0
    private(set) var resolveCallCount = 0
    private(set) var lastAnnotation: (text: String, originalText: String?)?

    private var shouldPauseNextPlanFetch = false
    private var shouldFailNextPlanFetch = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var pausedContinuation: CheckedContinuation<Void, Never>?

    init(plan: String, registryDirectory: URL) {
        self.plan = plan
        self.registryDirectory = registryDirectory
    }

    /// Arranges for the *next* `/api/plan` fetch to suspend until `resume()` is called.
    func pauseNextPlanFetch() {
        shouldPauseNextPlanFetch = true
    }

    /// Arranges for the *next* `/api/plan` fetch to come back with a non-2xx status — the
    /// shape `PlanGateClient.plan()` reports as `nil`, the same as a dropped connection.
    func failNextPlanFetch() {
        shouldFailNextPlanFetch = true
    }

    /// Waits until a paused fetch has actually reached its pause point, so a test never races
    /// its own setup.
    func waitUntilPaused() async {
        if pauseContinuation != nil { return }
        await withCheckedContinuation { pausedContinuation = $0 }
    }

    func resume() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func handle(_ request: URLRequest) async -> (Data, Int)? {
        switch request.url?.path {
        case "/api/plan":
            planFetchCount += 1
            if shouldFailNextPlanFetch {
                shouldFailNextPlanFetch = false
                return (Data(), 500)
            }
            if shouldPauseNextPlanFetch {
                shouldPauseNextPlanFetch = false
                await withCheckedContinuation { cont in
                    pauseContinuation = cont
                    pausedContinuation?.resume()
                    pausedContinuation = nil
                }
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["plan": plan])) ?? Data()
            return (body, 200)
        case "/api/external-annotations":
            if let bodyData = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                lastAnnotation = (json["text"] as? String ?? "", json["originalText"] as? String)
            }
            return (Data(#"{"ids":["stub"]}"#.utf8), 201)
        case "/api/approve", "/api/feedback":
            resolveCallCount += 1
            return (Data("{}".utf8), 200)
        default:
            return nil
        }
    }
}

extension PlanGateServiceTests {

    /// Wires a **real** `PlanGateService`'s existing injected seams — `registryDirectory`,
    /// `isAlive`, `parentOf`, `makeClient`, `callID`, `pid`, `sessions` — to in-memory values: a
    /// temp registry directory with one fake Plannotator entry, fixed process facts, one known
    /// session, and a `PlanGateClient` whose transport is a `RecordingTransport`. See Ruling B
    /// in the task brief: this must never grow logic of its own that
    /// `refresh`/`resolve`/`annotate` already have — if it needs to, the seams are wrong.
    ///
    /// An instance method rather than a static factory (the review's finding on the original
    /// `stub()`): a static factory had no `XCTestCase` to hand `addTeardownBlock`, so cleanup
    /// had to fake it by purging the *previous* fixture on every new call — which meant a test
    /// building two fixtures would have the first one silently deleted out from under it, and
    /// every "nothing happened" assertion on it would pass vacuously instead of erroring. This
    /// method uses real per-fixture teardown and permits as many fixtures as a test wants.
    @MainActor
    fileprivate func makeService(
        plan: String, callID: String
    ) -> (service: PlanGateService, transport: RecordingTransport) {
        let session = UUID()
        let claudePID: pid_t = 4242
        let plannotatorPID: pid_t = 9001
        let port = 54232

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanGateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let registryJSON = """
        {"pid":\(plannotatorPID),"port":\(port),"url":"http://localhost:\(port)",\
        "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
        """
        try? Data(registryJSON.utf8).write(to: dir.appendingPathComponent("\(plannotatorPID).json"))

        let transport = RecordingTransport(plan: plan, registryDirectory: dir)

        let service = PlanGateService(
            callID: { $0 == session ? callID : nil },
            pid: { $0 == session ? claudePID : nil },
            sessions: { [session] }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { $0 == plannotatorPID ? claudePID : nil }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }
        return (service, transport)
    }
}

extension PlanGateService {

    /// The single session id `makeService` wired up — read straight off the real `sessions`
    /// seam rather than duplicated, so this can never disagree with what `refresh()` actually
    /// sees.
    var knownSession: UUID { sessions().first! }

    /// Empties the fake registry so the next `refresh()` finds nothing — standing in for the
    /// hook dying, or the plan being answered directly on the Mac.
    func killGate() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registryDirectory.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: registryDirectory.appendingPathComponent(name))
        }
    }
}
