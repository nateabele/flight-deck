import XCTest
@testable import FlightDeck

/// Guards the fixtures themselves. `Fixtures/` is a folder reference copied as resources, so
/// a file that fails to land in the bundle produces a confusing nil at the first use site
/// rather than an error here.
final class CodexRolloutFixtureTests: XCTestCase {
    static func lines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle(for: CodexRolloutFixtureTests.self).url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Codex"
            ),
            "Fixtures/Codex/\(name).jsonl not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testTheCapturedRolloutHasTheTurnRecordsThisAppReads() throws {
        let kinds = try Self.lines("rollout.captured").compactMap { line -> String? in
            let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            guard obj?["type"] as? String == "event_msg" else { return nil }
            return (obj?["payload"] as? [String: Any])?["type"] as? String
        }
        XCTAssertEqual(kinds.filter { $0 == "task_started" }.count, 3)
        XCTAssertEqual(kinds.filter { $0 == "task_complete" }.count, 2,
                       "the third turn was interrupted by an approval prompt and never "
                       + "completed — that asymmetry is the point of this capture")
    }

    func testTheCapturedIndexCarriesRenamesFromBothWriters() throws {
        let names = try Self.lines("session-index.captured").compactMap { line -> String? in
            let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            return obj?["thread_name"] as? String
        }
        XCTAssertEqual(names.count, 3, "one line per rename, append-only")
        XCTAssertEqual(names.last, "tui side rename",
                       "the last writer was the TUI's own /rename, which is the case the "
                       + "app-server notification path could never see")
    }
}
