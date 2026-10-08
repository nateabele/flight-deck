import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §6. The sidebar is the roster, so everything a swarm row says is derived here, as
/// values, where it can be tested without a window.
@MainActor
final class SwarmAnnotationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ state: SwarmAgentState, task: String? = nil, lastTask: String? = nil,
                       marker: String? = nil) -> SwarmAgentRecord {
        var a = SwarmAgentRecord(session: UUID(), agentName: "BlueLake",
                                 block: SwarmFixtures.block(kind: "snapshot-tests"), lease: nil,
                                 task: task, state: state, stateSince: now)
        a.lastTask = lastTask; a.marker = marker
        return a
    }

    func testTheTaskChipNamesTaskAndKind() {
        let a = SwarmAnnotations.session(agent(.working, task: "fd-3x9"), headroom: nil, contested: false, lastActive: nil, now: now)
        XCTAssertEqual(a.taskChip, "fd-3x9 · snapshot-tests")
        XCTAssertNil(a.marker)
    }

    func testMarkersPerState() {
        func marker(_ a: SwarmAgentRecord) -> String? {
            SwarmAnnotations.session(a, headroom: nil, contested: false, lastActive: nil, now: now).marker
        }
        XCTAssertEqual(marker(agent(.idle)), "waiting")
        XCTAssertEqual(marker(agent(.idle, lastTask: "fd-1")), "done fd-1")
        XCTAssertEqual(marker(agent(.idle, marker: "stuck at start")), "stuck at start")
        XCTAssertEqual(marker(agent(.handedOff)), "handed off →")
        XCTAssertEqual(marker(agent(.done)), "done")
        XCTAssertEqual(marker(agent(.starting)), "starting")
    }

    func testTheMeterShowsOnlyPastSoft() {
        let account = AccountRef(agent: .codex, id: UUID(), label: "Work")
        func meter(_ state: HeadroomState, _ u: Double?) -> Double? {
            SwarmAnnotations.session(agent(.working, task: "t"),
                                     headroom: AccountHeadroom(account: account, worstUtilization: u, state: state, resetsAt: nil),
                                     contested: false, lastActive: nil, now: now).meter
        }
        XCTAssertNil(meter(.underSoft, 0.4))
        XCTAssertEqual(meter(.overSoft, 0.82), 0.82)
        XCTAssertEqual(meter(.overHard, nil), 1)
    }

    func testActiveAgo() {
        XCTAssertNil(SwarmAnnotations.activeAgo(nil, now: now))
        XCTAssertEqual(SwarmAnnotations.activeAgo(now.addingTimeInterval(-20), now: now), "active just now")
        XCTAssertEqual(SwarmAnnotations.activeAgo(now.addingTimeInterval(-240), now: now), "active 4 min ago")
    }

    func testHeaderSummaryText() {
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: [:], filter: .allReady, state: .running,
                                 agents: [agent(.working, task: "a"), agent(.working, task: "b"), agent(.starting)],
                                 createdAt: now)
        record.waiting = [WaitingTask(task: "c", reason: "r"), WaitingTask(task: "d", reason: "r")]
        XCTAssertEqual(SwarmAnnotations.header(record, contested: 1).text, "swarm 3/3 · 2 waiting · 1 contested")
        record.state = .paused; record.waiting = []
        let paused = SwarmAnnotations.header(record, contested: 0)
        XCTAssertEqual(paused.text, "swarm paused · 3/3")
        XCTAssertTrue(paused.canResume)
        XCTAssertFalse(paused.canPause)
        record.banner = SwarmStore.restartBanner
        XCTAssertEqual(SwarmAnnotations.header(record, contested: 0).chipText, "Swarm paused after restart · Resume")
    }

    func testTheServiceAnnotatesOnlySwarmSessions() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.host.activity[a.session] = rig.now.addingTimeInterval(-300)
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.taskChip, "fx-1 · tests")
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.lastActive, "active 5 min ago")
        XCTAssertNil(service.annotation(for: UUID(), now: rig.now))
        service.isContested = { $0 == a.session }
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.contested, true)
        XCTAssertEqual(service.summary(forProject: SwarmFixtures.project)?.text, "swarm paused · 1/3 · 1 contested")
    }
}
