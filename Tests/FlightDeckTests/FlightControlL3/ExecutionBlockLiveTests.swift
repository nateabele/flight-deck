import XCTest
import IntakeKit
@testable import FlightDeck

/// The whole contract rests on one probe: br keeps `agent_context` byte-for-byte, and
/// `br list --json` returns it while `br ready --json` does not. Re-probe it against the real
/// binary so a br upgrade that changes either fact fails here, not in a swarm.
/// Skipped unless `TEST_RUNNER_BR_LIVE=1` or `BR_LIVE=1`, and when `br` is missing.
final class ExecutionBlockLiveTests: XCTestCase {
    func testBlockSurvivesBrCreateAndList() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BR_LIVE"] == "1" || env["TEST_RUNNER_BR_LIVE"] == "1" else { throw XCTSkip("set BR_LIVE=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let br = home.appendingPathComponent(".local/bin/br").path
        guard FileManager.default.isExecutableFile(atPath: br) else { throw XCTSkip("br not at ~/.local/bin/br") }
        let dir = home.appendingPathComponent(".fd-l3-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func run(_ args: [String]) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
            p.currentDirectoryURL = dir
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        _ = try run(["/usr/bin/git", "init", "-q"])
        _ = try run([br, "init"])
        let block = ExecutionBlock(kind: "tests", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"],
                                   pool: "codex-subs", source: AssignmentSource(by: .rule, ruleId: "r1", reason: "live",
                                   at: Date(timeIntervalSince1970: 1_790_000_000)))
        let ctx = try ExecutionBlockCodec.encode(block, into: #"{"instructions":"keep"}"#)
        _ = try run([br, "create", "live probe", "-t", "task", "--agent-context", ctx, "--silent"])

        let list = try L3Fixtures.rows(in: Data(try run([br, "list", "--json"]).utf8))
        let stored = try XCTUnwrap(list.first?["agent_context"] as? String)
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: stored).get(), block)
        XCTAssertTrue(stored.contains("\"instructions\""))

        let ready = try L3Fixtures.rows(in: Data(try run([br, "ready", "--json"]).utf8))
        XCTAssertFalse(ready.isEmpty)
        XCTAssertNil(ready.first?["agent_context"], "br ready started carrying agent_context — readers may simplify")
    }
}
