import FleetKit
import XCTest

final class FakeTransport: CLITransport {
    var onReady: (() -> Void)?
    var onFrame: ((ServerFrame) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var connects: [Int] = []
    var sent: [ClientFrame] = []
    private var cid = 0
    func connect(lastSeq: Int) { connects.append(lastSeq) }
    func send(_ command: FleetCommand) -> Int { cid += 1; sent.append(.cmd(cid: cid, command)); return cid }
    func send(_ request: FleetRequest) -> Int { cid += 1; sent.append(.req(cid: cid, request)); return cid }
    func send(raw frame: ClientFrame) { sent.append(frame) }
    func disconnect() {}
    func push(_ frame: ServerFrame) { onFrame?(frame) }
    /// The socket reaching `.ready`. Never fired by `connect` itself, so a test says whether
    /// the Mac was reachable rather than getting it for free.
    func ready() { onReady?() }
}

final class CLIRunnerTests: XCTestCase {
    private let project = UUID()
    private let other = UUID()
    private let a = UUID()
    private var out: [String] = []
    private var err: [String] = []
    private var code: Int32?
    private var scheduled: [(TimeInterval, () -> Void)] = []

    private func fleet(activity: String? = "busy", extra: [WireSession] = []) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: project, name: "a", path: "/w/a",
                        sessions: [WireSession(id: a, title: "alpha", agent: "claude", activity: activity)] + extra),
            WireProject(id: other, name: "b", path: "/w/b"),
        ])
    }

    private func runner(_ args: String..., transport: FakeTransport, selfID: UUID? = nil) -> CLIRunner {
        let r = CLIRunner(invocation: try! CLIArguments.parse(args), transport: transport,
                          context: CLIContext(selfID: selfID, cwd: "/w/a", json: true, isTTY: false),
                          out: { self.out.append($0) }, err: { self.err.append($0) },
                          finish: { self.code = $0 }, schedule: { self.scheduled.append(($0, $1)) })
        r.run()
        return r
    }

    func testSendResolvesSelfAndFinishesOnAck() {
        let t = FakeTransport()
        _ = runner("send", "self", "hi", transport: t, selfID: a)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, .prompt(a, _, "hi")) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertNil(code)
        t.push(.ack(cid: cid))
        XCTAssertEqual(code, 0)
    }

    func testARefusalIsExitOneWithTheWireCode() {
        let t = FakeTransport()
        _ = runner("close", "alpha", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.err(cid: cid, code: "out_of_scope"))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("out_of_scope"))
    }

    func testUnreachableBeforeSnapshotIsSixtyNine() {
        let t = FakeTransport()
        _ = runner("ls", transport: t)
        t.onDisconnect?(nil)
        XCTAssertEqual(code, 69)
    }

    func testTailReconnectsAndResumesFromLastSeq() {
        let t = FakeTransport()
        _ = runner("tail", transport: t)
        t.push(.snapshot(seq: 5, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 6, .unreadChanged(id: a, isUnread: true)))
        t.onDisconnect?(nil)
        XCTAssertNil(code, "tail outlives an app restart")
        XCTAssertEqual(scheduled.count, 1)
        scheduled[0].1()
        XCTAssertEqual(t.connects, [0, 6])
        XCTAssertEqual(out.count, 2)
    }

    func testTailSessionFilter() {
        let t = FakeTransport()
        _ = runner("tail", "--session", "alpha", "--no-snapshot", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 2, .unreadChanged(id: UUID(), isUnread: true)))
        t.push(.event(seq: 3, .unreadChanged(id: a, isUnread: true)))
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].contains(a.uuidString))
    }

    func testWaitFinishesWhenActivityMatches() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "idle", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "busy"), reason: .initial))
        XCTAssertNil(code)
        t.push(.event(seq: 2, .activityChanged(id: a, activity: "idle", waitingFor: nil,
                                               subagentCount: 0, hasBackgroundWork: false)))
        XCTAssertEqual(code, 0)
    }

    func testWaitGone() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "gone", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        t.push(.event(seq: 2, .sessionRemoved(id: a)))
        XCTAssertEqual(code, 0)
    }

    func testNewPrintsTheSessionAddedInItsProject() {
        let t = FakeTransport()
        _ = runner("new", "/w/a", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, .newSession(project, nil, nil)) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.ack(cid: cid))
        let elsewhere = WireSession(id: UUID(), title: "x", agent: "claude")
        t.push(.event(seq: 2, .sessionAdded(elsewhere, project: other, at: 0)))
        XCTAssertNil(code, "a tab created in another project is not ours")
        let ours = WireSession(id: UUID(), title: "new", agent: "claude")
        t.push(.event(seq: 3, .sessionAdded(ours, project: project, at: 1)))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.joined().contains(ours.id.uuidString))
    }

    func testAmbiguousTitleIsExitTwo() {
        let t = FakeTransport()
        let d1 = WireSession(id: UUID(), title: "dup", agent: "claude")
        let d2 = WireSession(id: UUID(), title: "dup", agent: "claude")
        _ = runner("close", "dup", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(extra: [d1, d2]), reason: .initial))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(t.sent.isEmpty, "nothing is closed on a guess")
        XCTAssertTrue(err.joined().contains(d1.id.uuidString))
        XCTAssertTrue(err.joined().contains(d2.id.uuidString))
    }

    /// A hand-built question, not a capture: this tests the runner's index-to-label mapping,
    /// and `OpenPromptTests` already pins the parse against real captures.
    ///
    /// `kind: .prompt`, not `.toolCall`: `OpenPrompt.find` reads an `AskUserQuestion` as a
    /// question only off a `.prompt` item (see `OpenPromptTests`' `call(_:tool:kind:…)`), and a
    /// `.toolCall` would derive a permission dialog with no options to map.
    private func questionPage() -> TimelinePage {
        let input = #"{"questions":[{"question":"Pick","header":"H","multiSelect":false,"options":[{"label":"Red","description":"r"},{"label":"Blue","description":"b"}]}]}"#
        let item = TimelineItem(
            id: TimelineItem.identifier(offset: 0, index: 0), kind: .prompt, status: .complete,
            body: .init(text: input, tool: "AskUserQuestion", callID: "toolu_q"))
        return TimelinePage(session: a, items: [item], start: 0, end: 100, hasMore: false, reset: false)
    }

    func testAnswerBuildsLabelledSelectionsFromTheDerivedPrompt() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "[[1]]", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, .timeline(a, .latest, 200)) = t.sent.last else { return XCTFail("\(t.sent)") }
        t.push(.page(cid: cid, questionPage()))
        guard case .cmd(_, .answerPrompt(a, _, "toolu_q", let answer)) = t.sent.last else { return XCTFail("\(t.sent)") }
        XCTAssertEqual(answer, .answers([[AnswerSelection(index: 1, label: "Blue")]]))
    }

    func testAnswerOutOfRangeIsExitTwoAndSendsNothing() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "[[5]]", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.page(cid: cid, questionPage()))
        XCTAssertEqual(code, 2)
        XCTAssertEqual(t.sent.count, 1, "only the timeline request went out")
    }

    func testRawCorrelatesItsReply() {
        let t = FakeTransport()
        _ = runner("raw", #"{"t":"req","cid":99,"op":"session.recentlyClosed"}"#, transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        XCTAssertEqual(t.sent.last, .req(cid: 99, .recentlyClosed))
        t.push(.ack(cid: 1))                      // someone else's
        XCTAssertNil(code)
        t.push(.recentlyClosed(cid: 99, []))
        XCTAssertEqual(code, 0)
    }

    // MARK: Behaviour beyond the brief's table

    /// A caught-up resume is answered with an empty replay, so a quiet fleet sends no frame at
    /// all. Reachability has to come from `onReady`, or an app restart ends `tail` with 69.
    func testTailSinceSurvivesARestartWhenNothingWasReplayed() {
        let t = FakeTransport()
        _ = runner("tail", "--since", "6", transport: t)
        t.ready()
        t.onDisconnect?(nil)
        XCTAssertNil(code, "tail never finishes on its own")
        XCTAssertEqual(scheduled.count, 1)
        guard let reconnect = scheduled.first else { return } // not a crash that ends the suite
        reconnect.1()
        XCTAssertEqual(t.connects, [6, 6])
    }

    func testRawParseErrorIsTwoAndNeverConnects() {
        let t = FakeTransport()
        _ = runner("raw", "not json", transport: t)
        XCTAssertEqual(code, 2)
        XCTAssertTrue(t.connects.isEmpty)
    }

    func testTailSinceWithATitleIsTwo() {
        let t = FakeTransport()
        _ = runner("tail", "--session", "alpha", "--since", "3", transport: t)
        XCTAssertEqual(code, 2)
        XCTAssertTrue(t.connects.isEmpty)
    }

    func testDisconnectAfterAFrameIsOneForACommand() {
        let t = FakeTransport()
        _ = runner("close", "alpha", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        t.onDisconnect?(nil)
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("disconnected"))
    }

    func testWaitTimeoutIsOne() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "idle", "--timeout", "5", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "busy"), reason: .initial))
        XCTAssertNil(code)
        XCTAssertEqual(scheduled.map(\.0), [5])
        scheduled[0].1()
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("timed_out"))
    }

    func testWaitForAnActivityOnARemovedSessionIsGone() {
        let t = FakeTransport()
        _ = runner("wait", "alpha", "--for", "idle", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "busy"), reason: .initial))
        t.push(.event(seq: 2, .sessionRemoved(id: a)))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("gone"))
    }

    func testNewTimeoutIsLaunchUnconfirmed() {
        let t = FakeTransport()
        _ = runner("new", "/w/a", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.ack(cid: cid))
        XCTAssertEqual(scheduled.map(\.0), [30])
        scheduled[0].1()
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("launch_unconfirmed"))
    }

    /// The replicator can emit the event while the command is still being applied, before the
    /// ack is written, so the two are accepted in either order.
    func testNewAcceptsTheSessionAddedBeforeTheAck() {
        let t = FakeTransport()
        _ = runner("new", "/w/a", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .cmd(let cid, _) = t.sent.last else { return XCTFail() }
        let ours = WireSession(id: UUID(), title: "new", agent: "claude")
        t.push(.event(seq: 2, .sessionAdded(ours, project: project, at: 1)))
        XCTAssertNil(code, "not done until the Mac acks")
        t.push(.ack(cid: cid))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.joined().contains(ours.id.uuidString))
    }

    func testAnswerCountMismatchIsTwoAndSendsNothing() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "[[1],[0]]", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.page(cid: cid, questionPage()))
        XCTAssertEqual(code, 2)
        XCTAssertEqual(t.sent.count, 1, "only the timeline request went out")
    }

    func testAllowAgainstAQuestionIsTwo() {
        let t = FakeTransport()
        _ = runner("answer", "alpha", "allow", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(activity: "waiting"), reason: .initial))
        guard case .req(let cid, _) = t.sent.last else { return XCTFail() }
        t.push(.page(cid: cid, questionPage()))
        XCTAssertEqual(code, 2)
        XCTAssertEqual(t.sent.count, 1, "only the timeline request went out")
    }

    func testPlanWithNoGateIsOne() {
        let t = FakeTransport()
        _ = runner("plan", "approve", "alpha", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        XCTAssertEqual(code, 1)
        XCTAssertTrue(err.joined().contains("no_plan_gate"))
        XCTAssertTrue(t.sent.isEmpty)
    }

    func testTimelinePrintsThePage() {
        let t = FakeTransport()
        _ = runner("timeline", "alpha", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .req(let cid, .timeline(a, .latest, 40)) = t.sent.last else { return XCTFail("\(t.sent)") }
        let page = questionPage()
        t.push(.page(cid: cid, page))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, [CLIOutput.json(page)])
    }

    func testOpenPrintsTheSessionID() {
        let t = FakeTransport()
        _ = runner("open", "conv-1", "/w/a", transport: t)
        t.push(.snapshot(seq: 1, fleet: fleet(), reason: .initial))
        guard case .req(let cid, .openConversation("conv-1", "/w/a")) = t.sent.last else { return XCTFail("\(t.sent)") }
        let opened = UUID()
        t.push(.session(cid: cid, opened))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, [opened.uuidString])
    }
}
