import XCTest
import IntakeKit
@testable import FlightDeck

/// Runs `BeadWriter` and `IntakeGraphReader` against a REAL `br` binary. `BeadWriterTests`
/// only proves the argv this type builds is well-formed against a scripted reply; nothing
/// else in the suite proves a real `br create`/`dep add`/`update`/`reopen`/`sync` sequence
/// actually lands the way this writer assumes, or that its output decodes the way the fake
/// replies (copied from a live probe — see the task-14 report) claim it will.
///
/// Skipped when `br` isn't resolvable, so a clean clone/CI host degrades rather than fails.
/// The scratch repo is created fresh under `$HOME` (never `/tmp` — see AGENTS.md/the task
/// brief) in `setUp` and removed in `tearDown` on every path, pass or fail.
final class BeadWriterLiveTests: XCTestCase {
    private var brPath = ""
    private var projectDir = ""
    private var runner: FlywheelProcessRunner!

    /// `~/.local/bin/br` first — where `br` actually lives in this environment, and a
    /// headless `xcodebuild test` process's PATH is not guaranteed to include it — then the
    /// process's own PATH, so a host with `br` installed conventionally still finds it.
    private static func resolveBrPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = "\(home)/.local/bin/br"
        if FileManager.default.isExecutableFile(atPath: localBin) { return localBin }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/br"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    override func setUp() async throws {
        guard let brPath = Self.resolveBrPath() else {
            throw XCTSkip("br not found at ~/.local/bin/br or on PATH")
        }
        self.brPath = brPath
        self.runner = SystemFlywheelProcessRunner()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        projectDir = "\(home)/.fd-intake-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let (initOut, initCode) = try await runner.run(brPath, ["init"], cwd: projectDir)
        XCTAssertEqual(initCode, 0, "br init failed to set up the scratch repo: \(initOut)")
    }

    override func tearDown() async throws {
        if !projectDir.isEmpty { try? FileManager.default.removeItem(atPath: projectDir) }
    }

    /// Create -> depend -> update -> reopen, then reads the result back with
    /// `IntakeGraphReader` — the same round trip `BeadWriter.apply` promises: whatever it
    /// says landed is what a fresh read of the real graph shows.
    func testAppliesCreateDependUpdateReopenAndSyncsToARealBr() async throws {
        // A pre-existing bead for the plan's `.depend`/`.update`/`.reopen` steps to target —
        // created directly through the runner (not through `BeadWriter`) so this test's own
        // setup doesn't depend on the very steps it's about to verify.
        let (createOut, createCode) = try await runner.run(
            brPath, ["create", "--title", "Existing bead", "-t", "task", "-p", "2",
                     "--description", "pre-existing", "--json"], cwd: projectDir)
        XCTAssertEqual(createCode, 0, createOut)
        struct CreateReply: Decodable { let id: String }
        let existingID = try JSONDecoder().decode(CreateReply.self, from: Data(createOut.utf8)).id

        let writer = BeadWriter(runner: runner, brPath: brPath, actor: "flightdeck-intake:live-test")
        let steps: [ApplyStep] = [
            .create(NewBead(tempId: "n1", title: "New bead", description: "created by the live test")),
            .depend(dependent: .new("n1"), dependency: .existing(existingID), kind: .blocks),
            .update(id: existingID, set: FieldSet(title: "Existing bead, updated")),
            .reopen(id: existingID, reason: "still needed"),
        ]
        let outcome = await writer.apply(steps, project: projectDir)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.applied, steps.count)
        let newID = try XCTUnwrap(outcome.idMap["n1"])

        let graph = try await IntakeGraphReader(runner: runner, brPath: brPath).read(project: projectDir)
        XCTAssertEqual(graph.beads[existingID]?.title, "Existing bead, updated")
        XCTAssertEqual(graph.beads[newID]?.title, "New bead")
        XCTAssertTrue(graph.edges.contains(DepEdge(dependent: newID, dependency: existingID)))
    }

    /// A step that fails against the real CLI (a dependency id that was never created)
    /// stops the run — proving the "stop at the first failure" contract against `br`'s real
    /// exit code and stdout, not a fake that always answers whatever the test wants.
    func testUnknownDependencyStopsTheRunWithBrsRealError() async throws {
        let writer = BeadWriter(runner: runner, brPath: brPath, actor: "flightdeck-intake:live-test")
        let steps: [ApplyStep] = [
            .create(NewBead(tempId: "n1", title: "New bead", description: "d")),
            .depend(dependent: .new("n1"), dependency: .existing("no-such-bead"), kind: .blocks),
            .update(id: "no-such-bead", set: FieldSet(title: "never reached")),
        ]
        let outcome = await writer.apply(steps, project: projectDir)

        XCTAssertEqual(outcome.applied, 1)
        XCTAssertNotNil(outcome.error)
    }
}
