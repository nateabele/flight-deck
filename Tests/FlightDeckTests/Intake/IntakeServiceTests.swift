import XCTest
import IntakeKit
@testable import FlightDeck

/// Hands back canned harness stdout, one entry per call (the last repeats once they run
/// out), and records every command it was asked to run.
private final class FakeHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    private(set) var commands: [(executable: String, arguments: [String], unsetEnvironment: [String])] = []
    var outputs: [Data]
    init(_ outputs: [Data]) { self.outputs = outputs }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        commands.append(command)
        let out = outputs.count > 1 ? outputs.removeFirst() : (outputs.first ?? Data())
        return (out, "", 0)
    }
}

/// A triage harness that streams: holds until the test opens the gate, then hands the sink
/// `first` and `output` as two chunks — so a test can look at the triage while it runs, with
/// nothing fed yet that a trailing activity flush could land mid-test.
private final class StreamingHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    let first: Data, output: Data
    private let lock = NSLock()
    private var open = false
    init(first: Data, output: Data) { self.first = first; self.output = output }
    func release() { lock.withLock { open = true } }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        (first + output, "", 0)
    }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]), cwd: URL,
             onStdout: (@Sendable (Data) -> Void)?) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        while !lock.withLock({ open }) { try await Task.sleep(nanoseconds: 1_000_000) }
        onStdout?(first)
        onStdout?(output)
        return (first + output, "", 0)
    }
}

/// `RecordingRunner` (BeadWriterTests) with mutable replies, so a test can move the graph
/// between triage and release review.
private final class MutableRunner: FlywheelProcessRunner, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    var replies: [String: (String, Int32)]
    /// Keys (same `"<exe> <arg0>"` form) whose call sleeps first — a cancellable stand-in
    /// for a slow `br`, so a test can act while a turn or release is mid-flight.
    var slow: [String: UInt64] = [:]
    init(_ replies: [String: (String, Int32)]) { self.replies = replies }
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        calls.append([exe] + args)
        let key = ([exe] + args.prefix(1)).joined(separator: " ")
        if let ns = slow[key] { try await Task.sleep(nanoseconds: ns) }
        // A per-bead reply (`"br update b2"`) wins over the verb-wide one.
        return replies[([exe] + args.prefix(2)).joined(separator: " ")] ?? replies[key] ?? ("", 127)
    }
}

@MainActor
final class IntakeServiceTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeServiceTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures

    private static func list(_ beads: [(id: String, status: String, assignee: String?)]) -> String {
        let issues = beads.map { b in
            let a = b.assignee.map { #","assignee":"\#($0)""# } ?? ""
            return #"{"id":"\#(b.id)","title":"T \#(b.id)","status":"\#(b.status)"\#(a)}"#
        }
        return #"{"issues":[\#(issues.joined(separator: ","))]}"#
    }
    private static let graph = #"{"components":[{"edges":[["b2","b1"]]}]}"#
    private static func brReplies(_ beads: [(id: String, status: String, assignee: String?)]) -> [String: (String, Int32)] {
        ["br list": (list(beads), 0), "br graph": (graph, 0), "bv --robot-triage": (#"{"triage":1}"#, 0)]
    }
    private static let openGraph: [(id: String, status: String, assignee: String?)] =
        [("b1", "open", nil), ("b2", "open", nil)]

    /// codex `exec --json` JSONL around one structured reply.
    private static func codex(_ json: String, session: String = "S1") -> Data {
        let msg = try! JSONSerialization.data(withJSONObject: ["type": "item.completed",
                                                             "item": ["type": "agent_message", "text": json]])
        return Data((#"{"type":"thread.started","thread_id":"\#(session)"}"# + "\n" + String(decoding: msg, as: UTF8.self) + "\n").utf8)
    }
    private static let questions = #"{"kind":"questions","questions":["Which README?"],"preset":null,"reason":null,"changeSet":null}"#
    private static let sketch = #"{"kind":"recommendation","questions":null,"preset":"sketch","reason":"big","changeSet":null}"#
    private static func beadRec(_ ops: String) -> String {
        #"{"kind":"recommendation","questions":null,"preset":"bead","reason":"small","changeSet":{"graphObservedAt":"2020-01-01T00:00:00Z","ops":[\#(ops)]}}"#
    }
    private static let createOp =
        #"{"op":"createBead","tempId":"n1","title":"Note","type":null,"priority":null,"description":"d","acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null}"#
    private static let danglingEdge =
        #"{"op":"addEdge","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":"new:ghost","to":"b1","kind":"blocks","id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null}"#
    private static let editB1 =
        #"{"op":"editBead","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"id":"b1","set":{"title":"New","description":null,"acceptance":null,"priority":null},"pre":{"status":"open","assignee":null},"delivery":null,"reason":null,"of":null}"#

    private func makeService(headless: FakeHeadlessRunner, br: MutableRunner,
                             hasSession: @escaping (String, String) -> Bool = { _, _ in false },
                             inject: @escaping (String, String, String, UUID) -> Bool = { _, _, _, _ in true }) -> IntakeService {
        IntakeService(store: IntakeStore(root: root), headless: headless, processRunner: br,
                      triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                      inject: inject, hasSession: hasSession)
    }

    private func capture(_ svc: IntakeService, project: String = "/p") async -> UUID {
        svc.capture(intent: "Add a note", project: project)
        let id = svc.intakes[0].id
        await svc.task(for: id)?.value
        return id
    }

    private func intake(_ svc: IntakeService, _ id: UUID) -> Intake { svc.intakes.first { $0.id == id }! }

    private static func inProgressEdit(_ id: String, holder: String, rating: String) -> String {
        #"{"op":"editBead","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"id":"\#(id)","set":{"title":"New","description":null,"acceptance":null,"priority":null},"pre":{"status":"in_progress","assignee":"\#(holder)"},"delivery":{"rating":"\#(rating)","reason":"why"},"reason":null,"of":null}"#
    }
    private static let heldGraph: [(id: String, status: String, assignee: String?)] =
        [("b1", "in_progress", "BlueFalcon"), ("b2", "in_progress", "RedFox")]
    private static let amReplies: [String: (String, Int32)] = [
        "am macros": (#"{"agent":{"name":"FDName"},"inbox":[]}"#, 0), "am mail": ("", 0), "am file_reservations": ("", 0)]

    /// Spins the main actor until `condition` holds, so a test can act mid-flight.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }

    // MARK: tests

    func testCaptureRunsTriageAndStoresQuestions() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions)]), br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .needsAnswers)
        XCTAssertEqual(i.exchanges, [TriageExchange(questions: ["Which README?"])])
        XCTAssertEqual(i.triage, HarnessSession(harness: .codex, sessionID: "S1", model: "m1", effort: "high"))
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
        // Inputs the agent was pointed at exist beside intake.json.
        let dir = IntakeStore(root: root).directory(for: id).appendingPathComponent("triage")
        for f in ["graph.json", "bv.json", "schema.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), f)
        }
        // Persisted, not just published.
        XCTAssertEqual(try IntakeStore(root: root).load(id: id).state, .needsAnswers)
    }

    /// Triage publishes `triage/activity.json` through the same parser and cadence as a round's
    /// seats; the service reads it on the clock tick only when its mtime moved, and holds the
    /// finished fold once the turn is over.
    func testTriagePublishesActivityReadOnTheTickWhenItsMtimeMoves() async throws {
        let command = Data((#"{"type":"item.started","item":{"type":"command_execution","command":"/bin/zsh -lc \"sed -n '1,9p' README.md\""}}"# + "\n").utf8)
        let headless = StreamingHeadlessRunner(first: command, output: Self.codex(Self.questions))
        let svc = IntakeService(store: IntakeStore(root: root), headless: headless,
                                processRunner: MutableRunner(Self.brReplies(Self.openGraph)),
                                triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        svc.capture(intent: "Add a note", project: "/p")
        let id = svc.intakes[0].id
        let file = IntakeStore(root: root).directory(for: id).appendingPathComponent("triage/activity.json")
        try await until { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertNil(svc.triageActivity(id), "nothing is read until the tick")
        // A whole-second mtime: `setAttributes` keeps less precision than a stat returns, so
        // restoring an arbitrary one below would itself read as a change.
        let mtime = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        svc.pollTapes()
        let started = try XCTUnwrap(svc.triageActivity(id))
        XCTAssertEqual(started.harness, .codex)
        XCTAssertFalse(started.finished)

        // Same mtime, new bytes: the tick must not re-read.
        var edited = started
        edited.headline = "edited"
        try IntakeJSON.encoder.encode(edited).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        svc.pollTapes()
        XCTAssertNil(svc.triageActivity(id)?.headline, "an unchanged mtime costs a stat, not a read")
        try FileManager.default.setAttributes([.modificationDate: mtime.addingTimeInterval(1)], ofItemAtPath: file.path)
        svc.pollTapes()
        XCTAssertEqual(svc.triageActivity(id)?.headline, "edited")

        headless.release()
        await svc.task(for: id)?.value
        XCTAssertEqual(intake(svc, id).state, .needsAnswers)
        let done = try XCTUnwrap(svc.triageActivity(id))
        XCTAssertTrue(done.finished)
        XCTAssertNil(done.error)
        XCTAssertEqual(done.action, ActivityAction(verb: "Reading", object: "README.md"))
        let onDisk = try IntakeJSON.decoder.decode(SeatActivity.self, from: Data(contentsOf: file))
        XCTAssertTrue(onDisk.finished)
        XCTAssertEqual(onDisk.action, done.action)
    }

    /// Unsent answers survive a relaunch (a release swap mid-answer) by coming back through a
    /// fresh service on the same root — and only against the exact questions they were typed for.
    func testAnswerDraftsSurviveAFreshServiceOnlyForTheSameQuestions() throws {
        let questions = ["Which README?", "Keep the badge?"]
        var seeded = Intake(projectPath: "/p", intent: "Add a note")
        seeded.state = .needsAnswers
        seeded.exchanges = [TriageExchange(questions: questions)]
        try IntakeStore(root: root).save(seeded)

        let first = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        first.saveAnswerDrafts(seeded.id, questions: questions, answers: ["The root one", "Ye"])

        let relaunched = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(relaunched.answerDrafts(seeded.id, questions: questions), ["The root one", "Ye"])
        XCTAssertNil(relaunched.answerDrafts(seeded.id, questions: ["Which README?", "Something else?"]))
        // A mismatch deletes the stale file, so the original questions no longer match either.
        XCTAssertNil(relaunched.answerDrafts(seeded.id, questions: questions))
    }

    /// Sending the round deletes its drafts, and a debounced save arriving after Send is refused
    /// — otherwise the answered round's drafts would reappear on the next launch.
    func testSendingARoundClearsItsDraftsAndRefusesLateSaves() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions), Self.codex(Self.sketch)]),
                              br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        svc.saveAnswerDrafts(id, questions: ["Which README?"], answers: ["The root one"])
        XCTAssertEqual(svc.answerDrafts(id, questions: ["Which README?"]), ["The root one"])
        svc.answer(id, answers: ["The root one"])
        svc.saveAnswerDrafts(id, questions: ["Which README?"], answers: ["late"])
        await svc.task(for: id)?.value
        XCTAssertNil(svc.answerDrafts(id, questions: ["Which README?"]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: IntakeStore(root: root).directory(for: id).appendingPathComponent("answer-drafts.json").path))
    }

    func testAnswerResumesSameSessionWithModelPinned() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.questions), Self.codex(Self.sketch)])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        svc.answer(id, answers: ["The root one"])
        await svc.task(for: id)?.value
        let argv = headless.commands[1].arguments
        XCTAssertTrue(argv.contains("resume"), "\(argv)")
        XCTAssertTrue(argv.contains("S1"), "\(argv)")
        XCTAssertEqual(argv[argv.firstIndex(of: "-m")! + 1], "m1")
        XCTAssertEqual(intake(svc, id).exchanges.first?.answers, ["The root one"])
        XCTAssertEqual(intake(svc, id).state, .awaitingChoice)
    }

    func testBeadRecommendationGoesToReview() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]),
                              br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .review)
        XCTAssertEqual(i.recommended, .bead)
        XCTAssertEqual(i.changeSet?.ops.count, 1)
        // FD owns graphObservedAt: the agent's value (2020) is replaced by the graph-read time.
        XCTAssertGreaterThan(i.changeSet!.graphObservedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testChoosingBeadWithoutChangeSetEncodesNow() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.sketch), Self.codex(Self.beadRec(Self.createOp))])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        svc.choose(id, preset: .bead)
        await svc.task(for: id)?.value
        XCTAssertEqual(intake(svc, id).state, .review)
        XCTAssertTrue(headless.commands[1].arguments.contains("resume"))
    }

    func testMalformedTriageFailsAndKeepsRawOutput() async {
        let prose = Data("I think you should add a note.\n".utf8)
        let svc = makeService(headless: FakeHeadlessRunner([prose]), br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .failed)
        XCTAssertNotNil(i.failure)
        XCTAssertEqual(i.rawFailureOutput, "I think you should add a note.\n")
    }

    func testInvalidChangeSetFails() async {
        let bad = Self.codex(Self.beadRec(Self.danglingEdge))
        let headless = FakeHeadlessRunner([bad, bad])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .failed)
        // The human's words (`ValidationError.userMessage`), not the schema's: the agent was
        // told about `new:ghost`; the human reads what went wrong, in tasks.
        XCTAssertTrue(i.failure?.contains("a dependency names a new task the plan never creates") == true, i.failure ?? "nil")
        XCTAssertFalse(i.failure?.contains("new:") ?? true, i.failure ?? "nil")
        XCTAssertNotNil(i.rawFailureOutput)
        // Exactly one automatic retry, resuming the same session with the errors listed.
        XCTAssertEqual(headless.commands.count, 2)
        let retry = headless.commands[1].arguments
        XCTAssertTrue(retry.contains("resume") && retry.contains("S1"), "\(retry)")
        XCTAssertTrue(retry.last?.contains("new:ghost") == true, retry.last ?? "")
    }

    func testInvalidChangeSetRecoversOnRetry() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.beadRec(Self.danglingEdge)), Self.codex(Self.beadRec(Self.createOp))])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        XCTAssertEqual(intake(svc, id).state, .review)
        XCTAssertNil(intake(svc, id).failure)
    }

    func testReleaseBlockedUntilDriftResolved() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.editB1))]), br: br)
        let id = await capture(svc)
        XCTAssertEqual(intake(svc, id).state, .review)

        // BlueFalcon claims b1 after triage.
        br.replies = Self.brReplies([("b1", "in_progress", "BlueFalcon"), ("b2", "open", nil)])
        var review = await svc.reviewModel(id)
        guard case .drifted = review?.drift.first else { return XCTFail("\(String(describing: review?.drift))") }
        XCTAssertEqual(review?.canRelease, false)

        svc.confirmDrift(id, op: 0)
        review = await svc.reviewModel(id)
        XCTAssertEqual(review?.canRelease, true)
    }

    func testReleaseWritesBeadsAndRecords() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let id = await capture(svc)
        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .released)
        XCTAssertEqual(i.release?.appliedSteps, 1)
        XCTAssertEqual(i.release?.idMap, ["n1": "b9"])
        let create = br.calls.first { $0.prefix(2) == ["br", "create"] }!
        XCTAssertEqual(create[create.firstIndex(of: "--actor")! + 1], "flightdeck-intake:\(id.uuidString)")
    }

    func testConfirmedDriftReleasesAgainstTheCurrentHolder() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.editB1))]), br: br,
                              hasSession: { _, _ in false })
        let id = await capture(svc)
        br.replies = Self.brReplies([("b1", "in_progress", "BlueFalcon"), ("b2", "open", nil)]).merging([
            "br show": (#"[{"id":"b1","status":"in_progress","assignee":"BlueFalcon"}]"#, 0),
            "br update": ("", 0), "br sync": ("", 0),
            "am macros": (#"{"agent":{"name":"FDName"},"inbox":[]}"#, 0), "am mail": ("", 0),
        ]) { $1 }
        svc.confirmDrift(id, op: 0)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released, intake(svc, id).release?.error ?? "")
        // The recheck used the refreshed precondition, and the new holder was mailed.
        XCTAssertTrue(br.calls.contains { $0.prefix(2) == ["br", "update"] })
        let mail = br.calls.first { $0.prefix(3) == ["am", "mail", "send"] }
        XCTAssertEqual(mail.map { $0[$0.firstIndex(of: "--to")! + 1] }, "BlueFalcon")
    }

    func testInterruptedOnRelaunch() async throws {
        let store = IntakeStore(root: root)
        var i = Intake(projectPath: "/p", intent: "x")
        i.state = .triaging
        try store.save(i)
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(intake(svc, i.id).state, .interrupted)
        XCTAssertEqual(try store.load(id: i.id).state, .interrupted)
    }

    func testProjectPathIsStandardizedForListingAndDelivery() async {
        var injected: [(String, String)] = []
        let br = MutableRunner(Self.brReplies(Self.heldGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.inProgressEdit("b1", holder: "BlueFalcon", rating: "scopeChange")))]),
                              br: br,
                              // A holder's session is keyed by the standardized path, as SessionStore keys flywheel identities.
                              hasSession: { project, agent in project == "/p" && agent == "BlueFalcon" },
                              inject: { project, agent, _, _ in injected.append((project, agent)); return true })
        let id = await capture(svc, project: "/p/")
        XCTAssertEqual(svc.intakes(forProject: "/p").map(\.id), [id])
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
        br.replies.merge(["br show": (#"[{"id":"b1","status":"in_progress","assignee":"BlueFalcon"}]"#, 0),
                          "br update": ("", 0), "br sync": ("", 0)].merging(Self.amReplies) { $1 }) { $1 }
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released, intake(svc, id).release?.error ?? "")
        XCTAssertEqual(injected.map(\.0), ["/p"])
        XCTAssertEqual(injected.map(\.1), ["BlueFalcon"])
    }

    func testPartialReleaseNotifiesOnlyLandedEdits() async {
        var injected: [String] = []
        let ops = Self.inProgressEdit("b1", holder: "BlueFalcon", rating: "invalidating") + "," + Self.inProgressEdit("b2", holder: "RedFox", rating: "invalidating")
        let br = MutableRunner(Self.brReplies(Self.heldGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(ops))]), br: br,
                              hasSession: { _, _ in true },
                              inject: { _, agent, _, _ in injected.append(agent); return true })
        let id = await capture(svc)
        XCTAssertEqual(intake(svc, id).state, .review)
        br.replies.merge([
            "br show b1": (#"[{"id":"b1","status":"in_progress","assignee":"BlueFalcon"}]"#, 0),
            "br show b2": (#"[{"id":"b2","status":"in_progress","assignee":"RedFox"}]"#, 0),
            "br update b1": ("", 0), "br update b2": ("database is locked", 1),
        ].merging(Self.amReplies) { $1 }) { $1 }
        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .partiallyReleased)
        // b1's edit landed before b2's failed: its holder is reclaimed, injected and mailed.
        XCTAssertEqual(injected, ["BlueFalcon"])
        XCTAssertTrue(br.calls.contains { $0.prefix(3) == ["am", "mail", "send"] && $0.contains("BlueFalcon") })
        XCTAssertFalse(br.calls.contains { $0.contains("RedFox") }, "\(br.calls)")
        // b2's never landed: named in the warnings, not notified.
        XCTAssertTrue(i.release?.warnings.contains { $0.contains("b2") && $0.contains("RedFox") } == true,
                      "\(i.release?.warnings ?? [])")
    }

    func testDiscardMidTriageStaysDiscarded() async throws {
        let br = MutableRunner(Self.brReplies(Self.openGraph))
        br.slow["br list"] = 5_000_000_000
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions)]), br: br)
        svc.capture(intent: "Add a note", project: "/p")
        let id = svc.intakes[0].id
        let task = svc.task(for: id)
        try await until { !br.calls.isEmpty }
        svc.discard(id)
        await task?.value
        XCTAssertEqual(intake(svc, id).state, .discarded)
        XCTAssertEqual(try IntakeStore(root: root).load(id: id).state, .discarded)
    }

    func testDiscardAndSecondClickRefusedWhileReleasing() async throws {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let id = await capture(svc)
        br.slow["br create"] = 200_000_000
        let first = Task { await svc.release(id) }
        try await until { self.intake(svc, id).state == .releasing }
        await svc.release(id)                       // double click: returns at once
        XCTAssertFalse(svc.discard(id))
        XCTAssertEqual(intake(svc, id).state, .releasing)
        await first.value
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertEqual(br.calls.filter { $0.prefix(2) == ["br", "create"] }.count, 1)
    }

    /// A project with no AGENTS.md (here, `/p` does not exist at all) must not have one listed.
    func testInitialPromptOmitsAMissingAgentsFile() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.questions)])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        _ = await capture(svc)
        let prompt = headless.commands[0].arguments.last ?? ""
        XCTAssertFalse(prompt.contains("AGENTS.md"), prompt)
    }

    /// A release refused before anything was written returns to `.review` with the reason in
    /// `failure` — the sheet shows it and stays open — and the next attempt starts clean
    /// rather than carrying the old reason onto a release that worked.
    func testRefusedReleaseKeepsItsReasonUntilTheNextAttempt() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let id = await capture(svc)
        let list = br.replies["br list"]
        br.replies["br list"] = ("database is locked", 1)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .review)
        XCTAssertNotNil(intake(svc, id).failure)
        XCTAssertFalse(ReleaseReviewView.shouldClose(after: intake(svc, id)))

        br.replies["br list"] = list
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertNil(intake(svc, id).failure)
        XCTAssertTrue(ReleaseReviewView.shouldClose(after: intake(svc, id)))
    }

    /// Drift says b1 was open at triage and is in progress under BlueFalcon now; the sheet
    /// has to gate its rating picker on THAT, since it is what release will act on.
    func testReviewCarriesTheLiveStateOfADriftedOp() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.editB1))]), br: br)
        let id = await capture(svc)
        br.replies = Self.brReplies([("b1", "in_progress", "BlueFalcon"), ("b2", "open", nil)])
        let review = await svc.reviewModel(id)
        let live = Precondition(status: "in_progress", assignee: "BlueFalcon")
        XCTAssertEqual(review?.livePre, [0: live])
        XCTAssertEqual(review?.effectivePre(0), live)
    }

    /// The rating the human picks for a newly in-progress edit is the one release delivers —
    /// here invalidating, so the holder is reclaimed and told to stop, not merely prompted.
    func testConfirmedDriftReleasesWithTheUsersRating() async {
        var injected: [String] = []
        let br = MutableRunner(Self.brReplies(Self.openGraph))
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.editB1))]), br: br,
                              hasSession: { _, _ in true }, inject: { _, _, text, _ in injected.append(text); return true })
        let id = await capture(svc)
        br.replies = Self.brReplies([("b1", "in_progress", "BlueFalcon"), ("b2", "open", nil)]).merging([
            "br show": (#"[{"id":"b1","status":"in_progress","assignee":"BlueFalcon"}]"#, 0),
            "br update": ("", 0), "br sync": ("", 0),
        ].merging(Self.amReplies) { $1 }) { $1 }
        svc.confirmDrift(id, op: 0)
        svc.setRating(id, op: 0, .invalidating)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released, intake(svc, id).release?.error ?? "")
        XCTAssertTrue(br.calls.contains { $0.prefix(5) == ["br", "update", "b1", "--status", "open"] }, "\(br.calls)")
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected.first?.hasPrefix("Stop work on b1") == true, injected.first ?? "")
    }

    /// Dismissing a partial release is the one way its orange badge ever clears; the record
    /// of what landed stays on disk.
    func testDismissingAPartialReleaseStopsCountingItAndKeepsTheRecord() throws {
        var i = Intake(projectPath: "/p", intent: "x")
        i.state = .partiallyReleased
        i.release = ReleaseRecord(releasedAt: Date(timeIntervalSince1970: 0), appliedSteps: 2, idMap: ["n1": "b9"], error: "boom")
        try IntakeStore(root: root).save(i)
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
        XCTAssertTrue(svc.discard(i.id))
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 0)
        XCTAssertEqual(try IntakeStore(root: root).load(id: i.id).release, i.release)
    }

    func testDiscardCancelsAndHides() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions)]), br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        svc.discard(id)
        XCTAssertEqual(intake(svc, id).state, .discarded)
        XCTAssertTrue(svc.intakes(forProject: "/p").isEmpty)
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 0)
    }
}

final class SystemHeadlessRunnerTests: XCTestCase {
    /// A child killed by a signal nobody on our side sent is a failed turn, not a
    /// cancellation — the caller must get a code and text that name the signal.
    func testSignalDeathIsAFailureNotACancellation() async throws {
        let out = try await SystemHeadlessRunner().run(
            (executable: "sh", arguments: ["-c", "kill -9 $$"], unsetEnvironment: []),
            cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(out.exitCode, 137)
        XCTAssertTrue(out.stderr.contains("signal 9"), out.stderr)
    }
}
