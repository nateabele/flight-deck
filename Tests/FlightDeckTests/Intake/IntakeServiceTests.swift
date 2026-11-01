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

private final class DetectionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Records the account each triage turn was bound to (unify brief R9).
private final class AccountRecordingHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    private(set) var accounts: [AgentAccountRef?] = []
    let output: Data
    init(_ output: Data) { self.output = output }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) { (output, "", 0) }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]), cwd: URL,
             account: AgentAccountRef?, onStdout: (@Sendable (Data) -> Void)?) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        accounts.append(account)
        onStdout?(output)
        return (output, "", 0)
    }
}

/// A resolver that answers one fixed account, or refuses, and counts its lease traffic.
@MainActor
private final class StubAccountResolver: AccountResolving {
    var result: Result<ResolvedAccount, AccountResolutionError>
    private(set) var asked: [(AgentID, String)] = []
    private(set) var released: [AccountLease] = []
    init(_ result: Result<ResolvedAccount, AccountResolutionError>) { self.result = result }
    func billing(_ agent: AgentID, project: String) -> AccountBilling { AccountBilling(text: "stub") }
    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError> {
        asked.append((agent, project))
        return result
    }
    func acquire(_ choice: AccountChoice, agent: AgentID) -> Result<ResolvedAccount, AccountResolutionError> { result }
    func release(_ lease: AccountLease) { released.append(lease) }
    func adopt(_ lease: AccountLease) {}
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
                      triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
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

    /// Unify brief R9: triage bills the project's account for its agent, binds that home, records
    /// the account on its activity, and hands a pool lease back when the turn ends.
    /// The start of an intake refreshes the model lists: detection runs again (which re-reads claude's
    /// and codex's lists per account, and grok/gemini/opencode's through the detection), off the
    /// main actor. A host with no refresher (every test but this) spawns nothing.
    func testStartingAnIntakeRefreshesTheModelLists() async throws {
        let detections = DetectionCount()
        let reads = DetectionCount()
        let work = AccountChoice.account(UUID())
        let targets = ModelListTargets(accounts: [.init(agent: .codex, choice: work, home: URL(fileURLWithPath: "/h/work"), bound: true)])
        let svc = IntakeService(store: IntakeStore(root: root), headless: FakeHeadlessRunner([Self.codex(Self.questions)]),
                                processRunner: MutableRunner([:]),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                detectAgents: { detections.bump(); return .defaults })
        svc.modelRefresher = ModelListRefresher(
            store: ModelListStore(directory: root.appendingPathComponent("model-lists")),
            runClaude: { _, _ in nil },
            readCache: { _, _ in reads.bump(); return [ModelOption(id: "gpt-6-sol", name: "GPT 6 Sol")] }, log: { _ in })
        svc.modelListTargets = { targets }
        XCTAssertEqual(detections.count, 0, "a supplied cache means no launch detection")
        svc.capture(intent: "Add a note", project: "/p")
        await svc.recheckAgents().value   // joins the detection capture started
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(svc.modelLists[work.key]?.map(\.name), ["GPT 6 Sol"])
        XCTAssertEqual(svc.availableModels(project: nil).optionsByAccount[work.key]?.first?.id, "gpt-6-sol")
    }

    func testStartingAnIntakeOnAHostWithNoRefresherDetectsNothing() async throws {
        let detections = DetectionCount()
        let svc = IntakeService(store: IntakeStore(root: root), headless: FakeHeadlessRunner([Self.codex(Self.questions)]),
                                processRunner: MutableRunner([:]),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                detectAgents: { detections.bump(); return .defaults })
        svc.capture(intent: "Add a note", project: "/p")
        await svc.task(for: svc.intakes[0].id)?.value
        XCTAssertEqual(detections.count, 0)
    }

    func testTriageBillsTheProjectsAccountAndReleasesItsLease() async throws {
        let home = root.appendingPathComponent("accounts/cx")
        let account = AgentAccount(agent: .codex, displayName: "CX", home: home)
        let lease = AccountLease(pool: "cx-pool", account: AccountRef(agent: .codex, id: account.id, label: "CX"))
        let resolver = StubAccountResolver(.success(ResolvedAccount(agent: .codex, account: account, lease: lease, label: "CX pool · CX")))
        let headless = AccountRecordingHeadlessRunner(Self.codex(Self.questions))
        let svc = IntakeService(store: IntakeStore(root: root), headless: headless,
                                processRunner: MutableRunner(Self.brReplies(Self.openGraph)),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        svc.accountResolver = resolver
        let id = await capture(svc, project: "/w/proj")
        XCTAssertEqual(intake(svc, id).state, .needsAnswers)
        XCTAssertEqual(resolver.asked.map(\.0), [.codex])
        XCTAssertEqual(resolver.asked.map(\.1), ["/w/proj"])
        XCTAssertEqual(headless.accounts, [AgentAccountRef(id: account.id.uuidString, home: home)])
        XCTAssertEqual(svc.triageActivities[id]?.accountID, account.id)
        XCTAssertEqual(resolver.released, [lease], "the pool lease lives only as long as the turn")
    }

    /// Triage on a pool whose every member is over its hard limit still runs, and tells the
    /// user — the notice a tab in the same project would post.
    func testTriageOnAnAllOverHardPoolPostsTheNotice() async throws {
        let account = AgentAccount(agent: .codex, displayName: "CX", home: root.appendingPathComponent("accounts/cx"))
        let notice = AccountNotice(title: "Every account in “CX pool” is over its limit", body: "Started on “CX”.")
        let resolver = StubAccountResolver(.success(ResolvedAccount(agent: .codex, account: account, lease: nil,
                                                                   label: "CX pool · CX", notice: notice)))
        let svc = IntakeService(store: IntakeStore(root: root), headless: AccountRecordingHeadlessRunner(Self.codex(Self.questions)),
                                processRunner: MutableRunner(Self.brReplies(Self.openGraph)),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        svc.accountResolver = resolver
        var heard: [(UUID, String, AccountNotice)] = []
        svc.onAccountNotice = { heard.append(($0, $1, $2)) }
        let id = await capture(svc, project: "/w/proj")
        XCTAssertEqual(intake(svc, id).state, .needsAnswers, "the turn still runs")
        XCTAssertEqual(heard.map(\.0), [id])
        XCTAssertEqual(heard.map(\.1), ["/w/proj"])
        XCTAssertEqual(heard.map(\.2), [notice])
    }

    /// An assignment that cannot be honoured fails triage with the reason, running nothing.
    func testTriageRefusesAnUnresolvableAccount() async throws {
        let resolver = StubAccountResolver(.failure(.accountMissing(.codex)))
        let headless = AccountRecordingHeadlessRunner(Self.codex(Self.questions))
        let svc = IntakeService(store: IntakeStore(root: root), headless: headless,
                                processRunner: MutableRunner(Self.brReplies(Self.openGraph)),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        svc.accountResolver = resolver
        let id = await capture(svc)
        XCTAssertEqual(intake(svc, id).state, .failed)
        XCTAssertTrue(intake(svc, id).failure?.contains("no longer exists") == true, "\(String(describing: intake(svc, id).failure))")
        XCTAssertTrue(headless.accounts.isEmpty)
    }

    func testCaptureRunsTriageAndStoresQuestions() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions)]), br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .needsAnswers)
        XCTAssertEqual(i.exchanges, [TriageExchange(questions: ["Which README?"], structured: [.text(id: "q1", "Which README?")])])
        XCTAssertEqual(i.triage, HeadlessSession(agent: .codex, sessionID: "S1", model: "m1", effort: "high"))
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
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
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
        XCTAssertEqual(started.agent, .codex)
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
    /// fresh service on the same root — and only for the round they were typed in.
    func testAnswerDraftsSurviveAFreshServiceOnlyForTheSameRound() throws {
        let questions = ["Which README?", "Keep the badge?"]
        var seeded = Intake(projectPath: "/p", intent: "Add a note")
        seeded.state = .needsAnswers
        seeded.exchanges = [TriageExchange(questions: questions)]
        try IntakeStore(root: root).save(seeded)
        let drafts = [StructuredAnswer(questionID: "q1", other: "The root one"),
                      StructuredAnswer(questionID: "q2", other: "Ye")]

        let first = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        first.saveAnswerDrafts(seeded.id, round: 0, answers: drafts)

        let relaunched = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(relaunched.answerDrafts(seeded.id, round: 0), drafts)
        // A newer round replaced these questions; the stale file is deleted, not matched later.
        var next = try IntakeStore(root: root).load(id: seeded.id)
        next.exchanges = [TriageExchange(questions: ["Which README?", "Something else?"])]
        try IntakeStore(root: root).save(next)
        let after = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertNil(after.answerDrafts(seeded.id, round: 0))
    }

    /// Sending the round deletes its drafts, and a debounced save arriving after Send is refused
    /// — otherwise the answered round's drafts would reappear on the next launch.
    func testSendingARoundClearsItsDraftsAndRefusesLateSaves() async {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions), Self.codex(Self.sketch)]),
                              br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        let draft = [StructuredAnswer(questionID: "q1", other: "The root one")]
        svc.saveAnswerDrafts(id, round: 0, answers: draft)
        XCTAssertEqual(svc.answerDrafts(id, round: 0), draft)
        svc.answer(id, structured: draft)
        svc.saveAnswerDrafts(id, round: 0, answers: [StructuredAnswer(questionID: "q1", other: "late")])
        await svc.task(for: id)?.value
        XCTAssertNil(svc.answerDrafts(id, round: 0))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: IntakeStore(root: root).directory(for: id).appendingPathComponent("answer-drafts.json").path))
    }

    private static let choiceQuestions: [StructuredQuestion] = [
        StructuredQuestion(id: "scope", text: "Which machines?", kind: .single,
                           options: [.init(id: "mac", label: "Only this Mac"), .init(id: "any", label: "Any machine")]),
        .text(id: "when", "When?"),
    ]

    private func seedStructuredRound(_ extra: (inout Intake) -> Void = { _ in }) throws -> Intake {
        var seeded = Intake(projectPath: "/p", intent: "Add a note")
        seeded.state = .needsAnswers
        seeded.exchanges = [TriageExchange(questions: Self.choiceQuestions.map(\.text), structured: Self.choiceQuestions)]
        extra(&seeded)
        try IntakeStore(root: root).save(seeded)
        return seeded
    }

    /// Rounds still read plain strings, so a choice must reach them as its label.
    func testStructuredAnswerRendersIntoPlainAnswersForRounds() async throws {
        let seeded = try seedStructuredRound()
        let headless = FakeHeadlessRunner([Self.codex(Self.sketch)])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        let given = [StructuredAnswer(questionID: "scope", selected: ["mac"]),
                     StructuredAnswer(questionID: "when", selected: [], other: "soon")]
        XCTAssertNil(svc.answer(seeded.id, structured: given))
        await svc.task(for: seeded.id)?.value
        let last = try XCTUnwrap(intake(svc, seeded.id).exchanges.first)
        XCTAssertEqual(last.answers, ["Only this Mac", "soon"])
        XCTAssertEqual(last.structuredAnswers, given)
        let sent = headless.commands.flatMap(\.arguments).joined(separator: "\n")
        XCTAssertTrue(sent.contains("Only this Mac"), sent)
        XCTAssertTrue(sent.contains("soon"), sent)
    }

    func testIncompleteOrUnknownAnswersAreRefused() throws {
        let seeded = try seedStructuredRound()
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        let blank = [StructuredAnswer(questionID: "scope", selected: ["mac"]),
                     StructuredAnswer(questionID: "when", selected: [], other: "  ")]
        XCTAssertEqual(svc.answer(seeded.id, structured: blank), .incomplete)
        let unknown = [StructuredAnswer(questionID: "scope", selected: ["mac"]),
                       StructuredAnswer(questionID: "q9", selected: [], other: "x")]
        XCTAssertEqual(svc.answer(seeded.id, structured: unknown), .unknownQuestion)
        let dup = [StructuredAnswer(questionID: "scope", selected: ["mac"]),
                   StructuredAnswer(questionID: "scope", selected: ["any"])]
        XCTAssertEqual(svc.answer(seeded.id, structured: dup), .unknownQuestion)
        let stored = intake(svc, seeded.id)
        XCTAssertNil(stored.exchanges.last?.answers)
        XCTAssertNil(stored.exchanges.last?.structuredAnswers)
        XCTAssertEqual(stored.state, .needsAnswers)
        XCTAssertEqual(svc.answer(UUID(), structured: []), .notAwaitingAnswers)
    }

    /// An option id the question does not have (stale, invented), the same id twice, or a
    /// selection on a text question is refused whole, not stored and rendered as a raw id.
    func testAnswersNamingOptionsTheQuestionLacksAreRefused() throws {
        let seeded = try seedStructuredRound()
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        let when = StructuredAnswer(questionID: "when", selected: [], other: "soon")
        let unknown = [StructuredAnswer(questionID: "scope", selected: ["ghost"]), when]
        XCTAssertEqual(svc.answer(seeded.id, structured: unknown), .incomplete)
        let duplicate = [StructuredAnswer(questionID: "scope", selected: ["mac", "mac"]), when]
        XCTAssertEqual(svc.answer(seeded.id, structured: duplicate), .incomplete)
        let onText = [StructuredAnswer(questionID: "scope", selected: ["mac"]),
                      StructuredAnswer(questionID: "when", selected: ["mac"], other: "soon")]
        XCTAssertEqual(svc.answer(seeded.id, structured: onText), .incomplete)
        let stored = intake(svc, seeded.id)
        XCTAssertNil(stored.exchanges.last?.answers)
        XCTAssertNil(stored.exchanges.last?.structuredAnswers)
        XCTAssertEqual(stored.state, .needsAnswers)
    }

    func testLegacyStringAnswerStillWorks() async throws {
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.questions), Self.codex(Self.sketch)]),
                              br: MutableRunner(Self.brReplies(Self.openGraph)))
        let id = await capture(svc)
        svc.answer(id, answers: ["The root one"])
        await svc.task(for: id)?.value
        let ex = try XCTUnwrap(intake(svc, id).exchanges.first)
        XCTAssertEqual(ex.answers, ["The root one"])
        XCTAssertEqual(ex.structuredAnswers, [StructuredAnswer(questionID: "q1", selected: [], other: "The root one")])
    }

    func testStructuredDraftsSurviveAFreshService() throws {
        let seeded = try seedStructuredRound()
        let drafts = [StructuredAnswer(questionID: "scope", selected: ["any"]),
                      StructuredAnswer(questionID: "when", selected: [], other: "so")]
        makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
            .saveAnswerDrafts(seeded.id, round: 0, answers: drafts)
        let relaunched = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertNil(relaunched.answerDrafts(seeded.id, round: 1))
        XCTAssertEqual(relaunched.answerDrafts(seeded.id, round: 0), drafts)
    }

    /// A drafts file is the app's own, but it is read back from disk: a selection naming an option
    /// the question does not offer (a hand-edited file, or one written by a build whose options
    /// differed under the same digest) is dropped on load, so the form never sends an id the
    /// round would refuse as incomplete. The rest of the answer is kept.
    func testLoadedDraftsKeepOnlyTheQuestionsOwnOptionIDs() throws {
        let seeded = try seedStructuredRound()
        makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
            .saveAnswerDrafts(seeded.id, round: 0, answers: [StructuredAnswer(questionID: "scope", selected: ["any"]),
                                                              StructuredAnswer(questionID: "when", selected: [], other: "so")])
        let url = IntakeStore(root: root).directory(for: seeded.id).appendingPathComponent("answer-drafts.json")
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        file["structured"] = [["questionID": "scope", "selected": ["any", "gone"]],
                              ["questionID": "when", "selected": ["stray"], "other": "so"]]
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let relaunched = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(relaunched.answerDrafts(seeded.id, round: 0),
                       [StructuredAnswer(questionID: "scope", selected: ["any"]),
                        StructuredAnswer(questionID: "when", selected: [], other: "so")])
    }

    /// `retry` clears the exchanges, so a fresh triage's first round is index 0 again — here with
    /// the same question texts but different option ids. Drafts from the old round must not come
    /// back: their ids name options the new round does not have.
    func testDraftsFromAReplacedRoundWithTheSameTextsDoNotComeBack() throws {
        let seeded = try seedStructuredRound()
        let drafts = [StructuredAnswer(questionID: "scope", selected: ["any"]),
                      StructuredAnswer(questionID: "when", selected: [], other: "so")]
        makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
            .saveAnswerDrafts(seeded.id, round: 0, answers: drafts)
        var retried = try IntakeStore(root: root).load(id: seeded.id)
        var questions = Self.choiceQuestions
        questions[0].options = [.init(id: "here", label: "Only this Mac"), .init(id: "all", label: "Any machine")]
        retried.exchanges = [TriageExchange(questions: questions.map(\.text), structured: questions)]
        try IntakeStore(root: root).save(retried)
        let relaunched = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertNil(relaunched.answerDrafts(seeded.id, round: 0))
    }

    /// A drafts file written before the digest existed (round and structured, no digest) still
    /// loads while its round and question texts match: storage is additive.
    func testADraftsFileWithoutADigestStillLoads() throws {
        let seeded = try seedStructuredRound()
        let old = #"{"questions":["Which machines?","When?"],"answers":["Any machine","so"],"round":0,"#
            + #""structured":[{"questionID":"scope","selected":["any"]},{"questionID":"when","selected":[],"other":"so"}]}"#
        try Data(old.utf8).write(to: IntakeStore(root: root).directory(for: seeded.id).appendingPathComponent("answer-drafts.json"))
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(svc.answerDrafts(seeded.id, round: 0), [
            StructuredAnswer(questionID: "scope", selected: ["any"]),
            StructuredAnswer(questionID: "when", selected: [], other: "so"),
        ])
    }

    /// A drafts file from before structured answers has strings only; it must still come back.
    func testOldStringDraftsFileStillLoads() throws {
        let questions = ["Which README?", "Keep the badge?"]
        var seeded = Intake(projectPath: "/p", intent: "Add a note")
        seeded.state = .needsAnswers
        seeded.exchanges = [TriageExchange(questions: questions)]
        try IntakeStore(root: root).save(seeded)
        let old = #"{"questions":["Which README?","Keep the badge?"],"answers":["root","yes"]}"#
        try Data(old.utf8).write(to: IntakeStore(root: root).directory(for: seeded.id).appendingPathComponent("answer-drafts.json"))
        let svc = makeService(headless: FakeHeadlessRunner([]), br: MutableRunner([:]))
        XCTAssertEqual(svc.answerDrafts(seeded.id, round: 0), [
            StructuredAnswer(questionID: "q1", selected: [], other: "root"),
            StructuredAnswer(questionID: "q2", selected: [], other: "yes"),
        ])
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

    // MARK: - Release export (P2a V4)

    @discardableResult
    private func git(_ repo: URL, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A real repo with one commit and a file the user is still editing.
    private func repo() throws -> URL {
        let r = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        try git(r, "init", "-q")
        try git(r, "config", "user.email", "t@example.com")
        try git(r, "config", "user.name", "T")
        try git(r, "config", "commit.gpgsign", "false")
        try "hello\n".write(to: r.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(r, "add", "-A")
        try git(r, "commit", "-q", "-m", "init")
        try "hello, still editing\n".write(to: r.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return r
    }

    private static let visualPlan = "# Pair the phone\n\n## Pairing\n\n```fd-visual id=pairing\nPairing handshake\n```\n"

    /// An intake in review whose encode carried a plan with one visual, and one new task that
    /// cites `cites` — what a shaped intake looks like when it reaches the release sheet.
    private func reviewIntake(project: URL, cites: String?, plan: String = visualPlan, installVisual: Bool = true) throws -> UUID {
        var i = Intake(projectPath: project.path, intent: "Pair the phone")
        i.state = .review
        i.recommended = .fullPlan
        i.changeSet = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_800_000_000), ops: [
            .createBead(NewBead(tempId: "n1", title: "Note", description: "d",
                                visualRefs: cites.map { [VisualRef(visualID: $0, states: ["default"])] })),
        ])
        let intakes = IntakeStore(root: root)
        try intakes.save(i)
        let triage = intakes.directory(for: i.id).appendingPathComponent("triage", isDirectory: true)
        try FileManager.default.createDirectory(at: triage, withIntermediateDirectories: true)
        let graph = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "T b1", status: "open"),
                                          "b2": BeadSnapshot(id: "b2", title: "T b2", status: "open")])
        try IntakeJSON.encoder.encode(graph).write(to: triage.appendingPathComponent("graph.json"))
        let tapes = TapeStore(intakeDirectory: intakes.directory(for: i.id))
        var tape = tapes.loadTape()
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .encode, round: 0, major: true, createdAt: Date()),
                                  files: ["plan.md": Data(plan.utf8)], into: &tape)
        if installVisual { try VisualDiskFixture.install(tapes, id: "pairing") }
        return i.id
    }

    private var releaseBr: MutableRunner {
        MutableRunner(Self.brReplies(Self.openGraph).merging(["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
    }

    /// Release exports the plan and its visual into `docs/plans/<slug>/`, commits only that folder
    /// (the user's own edit stays uncommitted), and the task cites the exported folder.
    func testReleaseExportsThePlanCommitsOnlyItsFolderAndCitesTheVisual() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: "pairing")
        let br = releaseBr
        let svc = makeService(headless: FakeHeadlessRunner([]), br: br)

        let review = await svc.reviewModel(id)
        XCTAssertEqual(review?.export?.paths.contains("docs/plans/pair-the-phone/plan.md"), true, "\(String(describing: review?.export))")
        XCTAssertEqual(review?.export?.commitMessage, "docs: plan pair-the-phone for release")

        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .released, i.failure ?? i.release?.error ?? "")
        XCTAssertEqual(try git(repo, "log", "-1", "--format=%s").trimmingCharacters(in: .whitespacesAndNewlines),
                       "docs: plan pair-the-phone for release")
        let committed = try git(repo, "show", "--name-only", "--format=", "HEAD").split(separator: "\n").map(String.init)
        XCTAssertTrue(committed.allSatisfy { $0.hasPrefix("docs/plans/pair-the-phone/") }, "\(committed)")
        XCTAssertTrue(committed.contains("docs/plans/pair-the-phone/visuals/pairing/diagram.mmd"), "\(committed)")
        XCTAssertEqual(try git(repo, "status", "--porcelain", "--", "README.md"), " M README.md\n", "the user's edit is untouched")
        let plan = try String(contentsOf: repo.appendingPathComponent("docs/plans/pair-the-phone/plan.md"), encoding: .utf8)
        XCTAssertTrue(plan.contains("visuals/pairing/snapshot@default-wide.png"), plan)

        let create = try XCTUnwrap(br.calls.first { $0.prefix(2) == ["br", "create"] })
        let description = create[try XCTUnwrap(create.firstIndex(of: "--description")) + 1]
        XCTAssertTrue(description.contains("Fidelity references"), description)
        XCTAssertTrue(description.contains("docs/plans/pair-the-phone/visuals/pairing/"), description)
    }

    /// Uncommitted changes under the plan's own folder refuse the release with the folder named,
    /// and nothing is written: no task, no export (Review Focus 4). (A folder with no marker is
    /// someone else's, and the export takes `-2` instead: `PlanExporterTests`.)
    func testReleaseRefusesWhenThePlanFolderHasUncommittedChanges() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: "pairing")
        // The folder an earlier release of this intake committed, with an edit since.
        let folder = repo.appendingPathComponent("docs/plans/pair-the-phone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "\(id.uuidString)\n".write(to: folder.appendingPathComponent(".flightdeck-intake"), atomically: true, encoding: .utf8)
        try git(repo, "add", "--", "docs")
        try git(repo, "commit", "-q", "-m", "earlier release")
        try "mine\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let br = releaseBr
        let svc = makeService(headless: FakeHeadlessRunner([]), br: br)
        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .review)
        XCTAssertTrue(i.failure?.contains("docs/plans/pair-the-phone") == true, i.failure ?? "nil")
        XCTAssertFalse(br.calls.contains { $0.prefix(2) == ["br", "create"] }, "no task is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("plan.md").path))
        XCTAssertEqual(try git(repo, "log", "--format=%s"), "earlier release\ninit\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8), "mine\n")
    }

    /// A block removed after encode (ruling A-I2): its citation is dropped with a warning that
    /// the release review shows, and release goes ahead without it, never a hard failure.
    func testACitationOfARemovedVisualIsDroppedWithAWarningAndReleaseGoesAhead() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: "ghost")
        let br = releaseBr
        let svc = makeService(headless: FakeHeadlessRunner([]), br: br)
        let loaded = await svc.reviewModel(id)
        let review = try XCTUnwrap(loaded, "the review loads")
        XCTAssertEqual(review.visualWarnings, ["Task \u{201C}Note\u{201D} no longer cites ghost: the visual was removed"])
        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .released, i.failure ?? "")
        XCTAssertTrue(i.release?.warnings.contains { $0.contains("no longer cites ghost") } == true, "\(i.release?.warnings ?? [])")
        let create = try XCTUnwrap(br.calls.first { $0.prefix(2) == ["br", "create"] })
        XCTAssertFalse(create[try XCTUnwrap(create.firstIndex(of: "--description")) + 1].contains("ghost"))
    }

    /// A-M4: the sheet learns of an export refusal while you review, before you press Release.
    func testTheReviewShowsAnExportRefusalBeforeRelease() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: nil, plan: "# Pair the phone\n\n```fd-visual id=gone\nGone\n```\n",
                                  installVisual: false)
        let svc = makeService(headless: FakeHeadlessRunner([]), br: releaseBr)
        let loaded = await svc.reviewModel(id)
        let review = try XCTUnwrap(loaded)
        XCTAssertTrue(review.exportRefusal?.contains("gone") == true, review.exportRefusal ?? "nil")
        XCTAssertNil(review.export)
    }

    /// Every plan is exported at release (D14, §12), visuals or not.
    func testReleaseExportsAPlanWithNoVisualsToo() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: nil, plan: "# Pair the phone\n\nJust words.\n", installVisual: false)
        let svc = makeService(headless: FakeHeadlessRunner([]), br: releaseBr)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released, intake(svc, id).failure ?? "")
        XCTAssertEqual(try git(repo, "log", "-1", "--format=%s").trimmingCharacters(in: .whitespacesAndNewlines),
                       "docs: plan pair-the-phone for release")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/plans/pair-the-phone/plan.md").path))
    }

    /// A block whose visual the export would mark missing refuses the release, naming the id:
    /// no task is written beside a plan that says the visual is not there.
    func testReleaseRefusesAPlanWithAMissingVisual() async throws {
        let repo = try repo()
        let id = try reviewIntake(project: repo, cites: nil, plan: "# Pair the phone\n\n```fd-visual id=gone\nGone\n```\n",
                                  installVisual: false)
        let br = releaseBr
        let svc = makeService(headless: FakeHeadlessRunner([]), br: br)
        await svc.release(id)
        let i = intake(svc, id)
        XCTAssertEqual(i.state, .review)
        XCTAssertTrue(i.failure?.contains("gone") == true, i.failure ?? "nil")
        XCTAssertFalse(br.calls.contains { $0.prefix(2) == ["br", "create"] })
        XCTAssertEqual(try git(repo, "log", "--format=%s"), "init\n")
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

@MainActor
private final class FakeEncodeRouting: EncodeRoutingProviding {
    var contexts: [String: String] = [:]
    private(set) var calls: [(steps: [ApplyStep], project: String)] = []
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] {
        calls.append((steps, project))
        return contexts
    }
}

@MainActor
private final class CancellingEncodeRouting: EncodeRoutingProviding {
    private(set) var calls = 0
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] {
        calls += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return [:]
    }
}

/// L3-R §4: release asks routing for each created task's block and hands it to the writer, and
/// triage — which encodes at single-task fidelity — is told the project's kinds.
extension IntakeServiceTests {
    func testReleaseWritesTheRoutedAgentContextOnCreate() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let routing = FakeEncodeRouting()
        routing.contexts = ["n1": #"{"flight_deck":{"execution":{"v":1}}}"#]
        svc.encodeRouting = { routing }
        let id = await capture(svc)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertEqual(routing.calls.first?.project, "/p")
        let create = br.calls.first { $0.prefix(2) == ["br", "create"] }!
        XCTAssertEqual(create[create.firstIndex(of: "--agent-context")! + 1], #"{"flight_deck":{"execution":{"v":1}}}"#)
    }

    /// Routing suspends after release's last cancellation check. A discard or retry that lands
    /// while the router works must not still create the tasks.
    func testReleaseCancelledWhileRoutingWritesNothing() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let routing = CancellingEncodeRouting()
        svc.encodeRouting = { routing }
        let id = await capture(svc)
        await Task { await svc.release(id) }.value
        XCTAssertEqual(routing.calls, 1, "the router was reached, so the guard after it is what is under test")
        XCTAssertNil(br.calls.first { $0.prefix(2) == ["br", "create"] }, "a cancelled release must not write")
        XCTAssertNotEqual(intake(svc, id).state, .released)
    }

    func testReleaseWithoutRoutingWritesNoAgentContext() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let id = await capture(svc)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertFalse(br.calls.first { $0.prefix(2) == ["br", "create"] }!.contains("--agent-context"))
    }

    func testTriageIsToldTheProjectsKinds() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.questions)])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        _ = await capture(svc)
        let prompt = headless.commands.first?.arguments.last ?? ""
        XCTAssertTrue(prompt.contains("- `implement-simple` — "), "a project with no kinds.json is offered the seed set")
    }
}
