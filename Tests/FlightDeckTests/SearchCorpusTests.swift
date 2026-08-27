// Tests/FlightDeckTests/SearchCorpusTests.swift
import XCTest
@testable import FlightDeck

/// Which `~/.claude/projects` directories a sidebar project owns.
///
/// `claude` encodes a working directory by replacing every non-ASCII-alphanumeric UTF-16
/// code unit with `-`, which is lossy and not invertible — so the corpus cannot be resolved
/// by decoding names. It is resolved by encoding *real* paths and matching exactly.
final class SearchCorpusTests: XCTestCase {
    /// The trap this whole type exists to avoid. `/w/flight-deck` encodes to
    /// `-w-flight-deck`, which is a prefix of `/w/flight-deck-old`'s `-w-flight-deck-old`.
    /// A prefix match would put another project's entire history into this one's results,
    /// silently and permanently.
    func testASiblingProjectSharingAnEncodedPrefixIsNotIncluded() {
        let names = SearchCorpus.transcriptDirectoryNames(
            forProjectAt: "/w/flight-deck",
            listing: { _ in [] }   // no worktrees
        )

        XCTAssertEqual(names, ["-w-flight-deck"])
        XCTAssertFalse(names.contains("-w-flight-deck-old"))
    }

    /// A worktree is a directory *inside* the project where `claude` genuinely runs and
    /// writes its own transcripts, so its conversations belong to this project. Both
    /// worktree roots the repo uses are covered.
    func testWorktreeDirectoriesAreIncluded() {
        let names = SearchCorpus.transcriptDirectoryNames(
            forProjectAt: "/w/flight-deck",
            listing: { path in
                switch path {
                case "/w/flight-deck/.claude/worktrees": return ["fleet-pairing"]
                case "/w/flight-deck/.superpowers/worktrees": return ["status-enums"]
                default: return []
                }
            }
        )

        XCTAssertEqual(
            Set(names),
            [
                "-w-flight-deck",
                "-w-flight-deck--claude-worktrees-fleet-pairing",
                "-w-flight-deck--superpowers-worktrees-status-enums",
            ]
        )
    }

    /// Each returned directory has to remember which project it came from: a transcript hit
    /// carries its project into the result row, and activation needs it to know which
    /// sidebar project to expand.
    func testEachDirectoryRemembersItsProject() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a", "/w/b"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in true }
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].projectPath, "/w/a")
        XCTAssertEqual(entries[0].directory, URL(fileURLWithPath: "/root/-w-a", isDirectory: true))
        XCTAssertEqual(entries[1].projectPath, "/w/b")
    }

    /// A project can be open in the sidebar and have no history at all — it was added
    /// today, or every conversation in it was deleted. That is not an error and must not
    /// produce a directory the builder will then fail to open.
    func testDirectoriesThatDoNotExistAreDropped() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in false }
        )

        XCTAssertTrue(entries.isEmpty)
    }

    /// Two sidebar projects can legitimately resolve to the same directory — nested
    /// projects, or one added twice by different paths that normalise together. The
    /// builder indexes per directory, so a duplicate would index it twice and double every
    /// hit in it.
    func testADirectoryReachedByTwoProjectsIsOnlyReturnedOnce() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a", "/w/a"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in true }
        )

        XCTAssertEqual(entries.count, 1)
    }
}
