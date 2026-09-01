import XCTest
@testable import FlightDeck

/// Covers the PATH repair that lets a Finder-launched Flight Deck find agents installed
/// outside launchd's `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
///
/// The parsing cases are the point. The failure this fixes was invisible from source — it
/// needed `ps eww` on the running app to see the bare PATH — and the *next* failure in this
/// area would be a PATH that parses to nonsense rather than one that is missing, which is why
/// `lookUp` rejects output it cannot use instead of trusting whatever a shell printed.
final class LoginShellPathTests: XCTestCase {
    func testAColonSeparatedPathIsAccepted() {
        let path = LoginShellPath.lookUp(shell: "/bin/zsh") { _, _ in
            "/Users/nate/.local/bin:/opt/homebrew/bin:/usr/bin\n"
        }
        XCTAssertEqual(path, "/Users/nate/.local/bin:/opt/homebrew/bin:/usr/bin")
    }

    /// The exact reason the command is `printenv PATH` and not `echo $PATH`: in fish, `$PATH`
    /// is a list and `echo` joins it with spaces. This is what that mistake looks like coming
    /// back, and it must not be accepted as a PATH.
    func testASpaceJoinedFishStylePathIsStillRejectedAsUnusable() {
        // A space-joined list contains slashes, so the shape check alone cannot catch it —
        // what saves us is that we never ask a shell to `echo` a list in the first place.
        // Pin the command instead, so a future "simplification" fails here.
        var seen: [String] = []
        _ = LoginShellPath.lookUp(shell: "/opt/homebrew/bin/fish") { _, arguments in
            seen = arguments
            return "/a /b /c\n"
        }
        XCTAssertEqual(seen, ["-lc", "printenv PATH"],
                       "must ask for the exported colon-separated value, never `echo $PATH`")
    }

    func testALoginShellIsRequestedNotAPlainInteractiveOne() {
        var seen: [String] = []
        _ = LoginShellPath.lookUp(shell: "/bin/zsh") { _, arguments in
            seen = arguments
            return "/usr/bin\n"
        }
        XCTAssertEqual(seen.first, "-lc",
                       "the profile that sets PATH is a login profile — the one a Finder launch skipped")
    }

    func testTheConfiguredShellIsTheOneRun() {
        var seen = ""
        _ = LoginShellPath.lookUp(shell: "/opt/homebrew/bin/fish") { executable, _ in
            seen = executable
            return "/usr/bin\n"
        }
        XCTAssertEqual(seen, "/opt/homebrew/bin/fish")
    }

    func testAThrowingShellLeavesTheInheritedPathAlone() {
        struct Boom: Error {}
        XCTAssertNil(LoginShellPath.lookUp(shell: "/bin/zsh") { _, _ in throw Boom() })
    }

    func testEmptyOrUnusableOutputIsRejectedRatherThanInstalled() {
        XCTAssertNil(LoginShellPath.lookUp(shell: "/bin/zsh") { _, _ in "" })
        XCTAssertNil(LoginShellPath.lookUp(shell: "/bin/zsh") { _, _ in "   \n" })
        XCTAssertNil(LoginShellPath.lookUp(shell: "/bin/zsh") { _, _ in "not-a-path\n" },
                     "a value with no path separator is not a PATH; keep what we inherited")
    }

    // MARK: - repairing

    func testRepairingAppendsMissingDirectoriesAndLeavesEverythingElse() {
        let repaired = LoginShellPath.repairing(
            ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/tmp/h", "TERM": "xterm"],
            path: "/Users/nate/.local/bin:/usr/bin"
        )
        XCTAssertEqual(repaired["PATH"], "/usr/bin:/bin:/Users/nate/.local/bin",
                       "inherited entries keep their order; only unseen ones are appended")
        XCTAssertEqual(repaired["CODEX_HOME"], "/tmp/h", "unrelated variables must survive")
        XCTAssertEqual(repaired["TERM"], "xterm")
    }

    /// The whole point: the bare launchd PATH is what a Finder-launched app actually carries,
    /// and after repair the agent's own directory is reachable.
    func testRepairingFixesTheMeasuredLaunchdEnvironment() {
        let repaired = LoginShellPath.repairing(
            ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            path: "/Users/nate/.local/bin:/usr/bin:/bin"
        )
        XCTAssertTrue(repaired["PATH"]?.contains("/Users/nate/.local/bin") == true)
    }

    /// The regression that made this an append rather than a substitution: a wholesale replace
    /// silently discarded a PATH the caller had set on purpose, which defeated
    /// `CodexIntegrationTests`' stub-`codex`-first mechanism — and would equally defeat a
    /// user's shim or version manager.
    func testADeliberatelyPlacedBinaryStillWinsOverTheLoginShellsCopy() {
        let repaired = LoginShellPath.repairing(
            ["PATH": "/tmp/stub-bin:/usr/bin"],
            path: "/Users/nate/.local/bin:/usr/bin"
        )
        let entries = (repaired["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, "/tmp/stub-bin",
                       "an entry the caller put first must stay first")
        XCTAssertTrue(entries.contains("/Users/nate/.local/bin"))
    }

    func testAlreadyReachableDirectoriesAreNotDuplicated() {
        let repaired = LoginShellPath.repairing(
            ["PATH": "/usr/bin:/bin"],
            path: "/bin:/usr/bin"
        )
        XCTAssertEqual(repaired["PATH"], "/usr/bin:/bin", "nothing to add, nothing changed")
    }

    func testAFailedLookupLeavesTheEnvironmentExactlyAsFound() {
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm"]
        XCTAssertEqual(LoginShellPath.repairing(base, path: nil), base,
                       "replacing a working PATH with nothing would be worse than the bug")
    }
}
