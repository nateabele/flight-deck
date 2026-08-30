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
        let service = PlanGateService.stub(plan: "# A\n\nB.", callID: "toolu_REAL")
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
        let service = PlanGateService.stub(plan: "# A\n\nB.", callID: "c")
        await service.refresh()
        let token = UUID()
        let first = await service.resolve(session: service.knownSession, call: "c",
                                          approve: true, feedback: nil, token: token)
        let second = await service.resolve(session: service.knownSession, call: "c",
                                           approve: true, feedback: nil, token: token)
        XCTAssertNil(first.failureCode)
        XCTAssertNil(second.failureCode, "a duplicate is an ack, not an error")
        XCTAssertEqual(service.resolveCallCount, 1, "the gate must be resolved exactly once")
    }

    /// The block index is resolved against the Mac's own split. A phone naming a block this
    /// plan does not have gets nothing pinned.
    @MainActor
    func testAnnotateResolvesTheBlockIndexLocally() async {
        let service = PlanGateService.stub(plan: "First block.\n\nSecond block.", callID: "c")
        await service.refresh()
        let ok = await service.annotate(session: service.knownSession, call: "c",
                                        text: "note", block: 1, token: UUID())
        XCTAssertNil(ok.failureCode)
        XCTAssertEqual(service.lastAnnotation?.originalText, "Second block.")
    }

    @MainActor
    func testAnnotateRefusesAnOutOfRangeBlock() async {
        let service = PlanGateService.stub(plan: "Only one.", callID: "c")
        await service.refresh()
        let result = await service.annotate(session: service.knownSession, call: "c",
                                            text: "note", block: 9, token: UUID())
        XCTAssertEqual(result.failureCode, "unreadable_screen")
        XCTAssertNil(service.lastAnnotation)
    }

    /// A non-target block cannot be pinned; the comment goes global rather than pinning to an
    /// arbitrary copy.
    @MainActor
    func testANonTargetBlockBecomesAGlobalComment() async {
        let service = PlanGateService.stub(plan: "A.\n\n---\n\nB.", callID: "c")
        await service.refresh()
        let breakIndex = PlanBlocks.split("A.\n\n---\n\nB.").blocks
            .firstIndex { !$0.isTarget }!
        _ = await service.annotate(session: service.knownSession, call: "c",
                                   text: "note", block: breakIndex, token: UUID())
        XCTAssertNil(service.lastAnnotation?.originalText,
                     "a non-target must not be sent as an anchor")
    }

    /// The gate closed between the tap and the command — hook killed, or answered on the Mac.
    @MainActor
    func testAVanishedGateRefuses() async {
        let service = PlanGateService.stub(plan: "# A", callID: "c")
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
        let service = PlanGateService.stub(plan: "# A", callID: "c")
        await service.refresh()
        await service.refresh()
        await service.refresh()
        XCTAssertEqual(service.planFetchCount, 1)
    }
}

// MARK: - Stub

/// See Ruling B in the task brief: the stub wires a **real** `PlanGateService`'s existing
/// injected seams to in-memory values — a temp registry directory, fixed process facts, and a
/// recording transport standing in for Plannotator's HTTP API. It must never grow logic of its
/// own that `refresh`/`resolve`/`annotate` already have; if it needs to, the seams are wrong.
extension PlanGateService {

    /// Stands in for Plannotator's HTTP API and counts what it saw, in the shape
    /// `PlanGateClientTests.Recorder` counts requests — a plain class rather than an actor,
    /// since every call arrives sequentially from the `@MainActor` service under test, exactly
    /// as `PromptServiceTests.ReadCount` documents for its own `@unchecked Sendable`.
    private final class RecordingTransport: @unchecked Sendable {
        let plan: String
        /// Kept only so `stub()` can remove it once this fixture is retired — see
        /// `transports` below for why cleanup cannot ride `XCTestCase.addTeardownBlock`.
        let registryDirectory: URL
        var planFetchCount = 0
        var resolveCallCount = 0
        var lastAnnotation: (text: String, originalText: String?)?

        init(plan: String, registryDirectory: URL) {
            self.plan = plan
            self.registryDirectory = registryDirectory
        }

        func handle(_ request: URLRequest) -> (Data, Int)? {
            switch request.url?.path {
            case "/api/plan":
                planFetchCount += 1
                let body = (try? JSONSerialization.data(withJSONObject: ["plan": plan])) ?? Data()
                return (body, 200)
            case "/api/external-annotations":
                if let bodyData = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    lastAnnotation = (json["text"] as? String ?? "", json["originalText"] as? String)
                }
                return (Data(#"{"ids":["stub"]}"#.utf8), 201)
            case "/api/approve", "/api/deny":
                resolveCallCount += 1
                return (Data("{}".utf8), 200)
            default:
                return nil
            }
        }
    }

    /// Recording transports, keyed by the one session id each stub instance wires up. A plain
    /// static dictionary rather than an associated object: extensions may not add stored
    /// *instance* properties, but a static one is ordinary storage, and each `stub()` call
    /// mints a fresh `UUID` so entries never collide across tests.
    ///
    /// **Cleanup cannot use `XCTestCase.addTeardownBlock`.** That is an instance method with
    /// no free-function form (confirmed against `XCTest.swiftinterface`), and `stub(plan:
    /// callID:)`'s signature — fixed by the test call sites above — carries no `XCTestCase` to
    /// call it on. Instead each `stub()` call purges the *previous* fixture's temp directory
    /// before creating its own, which bounds the leak to at most one directory left behind at
    /// process exit rather than one per test.
    private static var transports: [UUID: RecordingTransport] = [:]

    /// The single session id `stub` wired up — read straight off the real `sessions` seam
    /// rather than duplicated, so this can never disagree with what `refresh()` actually sees.
    var knownSession: UUID { sessions().first! }

    var planFetchCount: Int { Self.transports[knownSession]?.planFetchCount ?? 0 }
    var resolveCallCount: Int { Self.transports[knownSession]?.resolveCallCount ?? 0 }
    var lastAnnotation: (text: String, originalText: String?)? {
        Self.transports[knownSession]?.lastAnnotation
    }

    /// Empties the fake registry so the next `refresh()` finds nothing — standing in for the
    /// hook dying, or the plan being answered directly on the Mac.
    func killGate() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registryDirectory.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: registryDirectory.appendingPathComponent(name))
        }
    }

    /// A service wired to an in-memory registry and a recording transport.
    @MainActor
    static func stub(plan: String, callID: String) -> PlanGateService {
        // Retire the previous fixture, if any — see `transports`'s doc comment.
        for stale in transports.values {
            try? FileManager.default.removeItem(at: stale.registryDirectory)
        }
        transports.removeAll()

        let session = UUID()
        let claudePID: pid_t = 4242
        let plannotatorPID: pid_t = 9001
        let port = 54232

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanGateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let registryJSON = """
        {"pid":\(plannotatorPID),"port":\(port),"url":"http://localhost:\(port)",\
        "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
        """
        try? Data(registryJSON.utf8).write(to: dir.appendingPathComponent("\(plannotatorPID).json"))

        let transport = RecordingTransport(plan: plan, registryDirectory: dir)
        Self.transports[session] = transport

        let service = PlanGateService(
            callID: { $0 == session ? callID : nil },
            pid: { $0 == session ? claudePID : nil },
            sessions: { [session] }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { $0 == plannotatorPID ? claudePID : nil }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in transport.handle(request) })
        }
        return service
    }
}
