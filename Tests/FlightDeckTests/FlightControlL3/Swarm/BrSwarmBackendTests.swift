import XCTest
import IntakeKit
@testable import FlightDeck

/// The backend is argv and nothing else, so these pin the exact argv each swarm action runs — a
/// claim that dropped `--actor` would claim as whoever br thinks the shell is — and that every
/// read degrades rather than throws.
@MainActor
final class BrSwarmBackendTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)

    private func fixture(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Swarm"))), as: UTF8.self)
    }

    func testReadyTasksJoinsThreeReads() async throws {
        let fake = MultiRunner()
        fake.responses["br ready --json"] = (try fixture("br-ready"), 0)
        fake.responses["br scheduler --format"] = (try fixture("br-scheduler"), 0)
        fake.responses["br list --status"] = (try fixture("br-list-open"), 0)
        let tasks = try await BrSwarmBackend(runner: fake).readyTasks(project: project).get()
        XCTAssertEqual(tasks.map(\.id), ["fx-b", "fx-a", "fx-c"])
        XCTAssertTrue(fake.argv.contains(["br", "scheduler", "--format", "json"]))
        XCTAssertTrue(fake.argv.contains(["br", "list", "--status", "open", "--json"]))
        XCTAssertEqual(try tasks[1].block.get()?.model, "gpt-6-sol", "the block from br list reached the task")
    }

    /// A pinned block is binding. Without `br list` every task would look block-less, so a pinned
    /// task would be re-routed and `writeBlock` would overwrite its `agent_context`.
    func testListFailureIsAnErrorNotBlocklessTasks() async throws {
        for listResponse: (String, Int32)? in [nil, ("boom", 1), ("not json", 0)] {
            let fake = MultiRunner()
            fake.responses["br ready --json"] = (try fixture("br-ready"), 0)
            fake.responses["br scheduler --format"] = (try fixture("br-scheduler"), 0)
            fake.responses["br list --status"] = listResponse
            let result = await BrSwarmBackend(runner: fake).readyTasks(project: project)
            guard case .failure = result else { return XCTFail("a failed br list must fail readyTasks: \(String(describing: listResponse))") }
        }
    }

    func testSchedulerFailureDegradesToPriorityOrder() async throws {
        let fake = MultiRunner()
        fake.responses["br ready --json"] = (try fixture("br-ready"), 0)
        fake.responses["br list --status"] = (try fixture("br-list-open"), 0)
        let tasks = try await BrSwarmBackend(runner: fake).readyTasks(project: project).get()
        XCTAssertEqual(tasks.map(\.id), ["fx-c", "fx-a", "fx-b"])
    }

    func testReadyFailureIsAnError() async {
        let result = await BrSwarmBackend(runner: MultiRunner()).readyTasks(project: project)
        guard case .failure = result else { return XCTFail("no ready list is not an empty ready list") }
    }

    func testClaimArgvAndConflict() async throws {
        let fake = MultiRunner()
        fake.responses["br update fx-a"] = (try fixture("br-claim-conflict"), 1)
        let outcome = await BrSwarmBackend(runner: fake).claim("fx-a", actor: "GreenFox", project: project)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(fake.argv.last, ["br", "update", "fx-a", "--claim", "--actor", "GreenFox", "--json"])
    }

    func testReturnToOpenClearsAssignee() async {
        let fake = MultiRunner()
        fake.responses["br update fx-a"] = ("{}", 0)
        let ok = await BrSwarmBackend(runner: fake).returnToOpen("fx-a", project: project)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.argv.last, ["br", "update", "fx-a", "--status", "open", "--assignee", "", "--actor", "flight-deck"])
    }

    func testStatusAndDetailComeFromShow() async throws {
        let fake = MultiRunner()
        fake.responses["br show fx-a"] = (try fixture("br-show"), 0)
        let backend = BrSwarmBackend(runner: fake)
        let status = await backend.status("fx-a", project: project)
        XCTAssertEqual(status, TaskStatusReading(status: "in_progress", assignee: "BlueLake"))
        let detail = await backend.taskDetail("fx-a", project: project)
        XCTAssertEqual(detail?.acceptance, "- every fixture has a snapshot\n- CI passes")
        XCTAssertEqual(fake.argv.last, ["br", "show", "fx-a", "--json"])
    }

    func testWriteBlockMergesIntoExistingContext() async throws {
        let fake = MultiRunner()
        fake.responses["br update fx-c"] = ("{}", 0)
        let block = ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-subs",
                                   source: AssignmentSource(by: .manual, reason: "override", at: Date(timeIntervalSince1970: 1_790_000_000)),
                                   pinned: true)
        let ok = await BrSwarmBackend(runner: fake).writeBlock(block, task: "fx-c",
                                                               existingContext: #"{"instructions":"keep"}"#, project: project)
        XCTAssertTrue(ok)
        let argv = try XCTUnwrap(fake.argv.last)
        XCTAssertEqual(Array(argv.prefix(4)), ["br", "update", "fx-c", "--agent-context"])
        XCTAssertTrue(argv[4].contains(#""instructions":"keep""#))
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: argv[4]).get(), block)
    }

    func testReleaseReservationsArgv() async {
        let fake = MultiRunner()
        fake.responses["am file_reservations"] = ("", 0)
        _ = await BrSwarmBackend(runner: fake).releaseReservations(agent: "BlueLake", project: project)
        XCTAssertEqual(fake.argv.last, ["am", "file_reservations", "release", "/tmp/p", "BlueLake"])
    }
}
