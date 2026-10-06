import XCTest
@testable import HostKit

extension GitRunnerTests {
    /// Flight Deck's commits are internal plumbing and are never signed. `commit-tree` (the
    /// only way the sync engine commits today) has ignored `commit.gpgSign` since git 2.15, but
    /// any porcelain commit or tag would sign with the user's key, and a key gpg cannot use
    /// (or a pinentry nobody can answer from hostd) would fail every snapshot or result. So
    /// `GitRunner` turns signing off for every call, and this pins it on both paths.
    func testCommitsNeverSignWhateverTheUserConfigured() throws {
        let repo = try TempRepo()
        repo.write("a.txt", "a\n")
        try repo.commitAll()
        let signing = "[commit]\n\tgpgSign = true\n[tag]\n\tgpgSign = true\n[user]\n\tsigningkey = 0xFD00DEADBEEF0000\n"
        let global = TempRepo.scratch().appendingPathComponent("gitconfig")
        try signing.write(to: global, atomically: true, encoding: .utf8)
        // Repo-local too: the isolated host runner ignores the global file, not the repo's own.
        try repo.git("config", "commit.gpgSign", "true")
        try repo.git("config", "user.signingkey", "0xFD00DEADBEEF0000")

        for isolated in [false, true] {
            let git = GitRunner(isolated: isolated)
            let env = isolated ? [:] : ["GIT_CONFIG_GLOBAL": global.path]
            let tree = try git.text(["rev-parse", "HEAD^{tree}"], in: repo.url)
            let head = try git.text(["rev-parse", "HEAD"], in: repo.url)
            let commit = try git.text(["commit-tree", tree, "-p", head, "-m", "flightdeck"], in: repo.url, env: env)
            XCTAssertEqual(commit.count, 40, "isolated: \(isolated)")
            let raw = try git.text(["cat-file", "commit", commit], in: repo.url)
            XCTAssertFalse(raw.contains("gpgsig"), "isolated: \(isolated)")
            try git.run(["commit", "-q", "--allow-empty", "-m", "porcelain"], in: repo.url, env: env)
            try git.run(["tag", "-a", "-m", "t", "t-\(isolated)"], in: repo.url, env: env)
        }
    }
}
