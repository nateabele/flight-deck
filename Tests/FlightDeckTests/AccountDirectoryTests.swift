import XCTest
@testable import FlightDeck

final class AccountDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHome(_ name: String, file: String, contents: String) throws -> URL {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try contents.write(to: home.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return home
    }

    func testReadsClaudeIdentity() throws {
        let home = try makeHome(".claude-work", file: ".claude.json", contents: """
        {"oauthAccount":{"emailAddress":"nate@fieldwealth.ai","organizationName":"Acme"}}
        """)
        let identity = AccountDirectory.identity(atHome: home, agent: .claude)
        XCTAssertEqual(identity?.email, "nate@fieldwealth.ai")
        XCTAssertEqual(identity?.organization, "Acme")
    }

    /// Fails closed. An unreadable or unrecognised home yields nil rather than a guess, and
    /// the row shows its display name alone.
    func testUnreadableClaudeHomeYieldsNil() throws {
        let home = try makeHome(".claude-broken", file: ".claude.json", contents: "not json")
        XCTAssertNil(AccountDirectory.identity(atHome: home, agent: .claude))
    }

    func testReadsCodexIdentityFromTheIdToken() throws {
        // Unsigned, unverified: the payload is read for display only, never for authorisation.
        let payload = Data(#"{"email":"nate@radify.io"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let home = try makeHome(".codex-work", file: "auth.json", contents: """
        {"tokens":{"id_token":"header.\(payload).signature"}}
        """)
        XCTAssertEqual(AccountDirectory.identity(atHome: home, agent: .codex)?.email, "nate@radify.io")
    }

    func testDiscoversSiblingHomesButNotTheBuiltInOrUnrelatedDirectories() throws {
        _ = try makeHome(".claude", file: ".claude.json", contents: "{}")
        _ = try makeHome(".claude-work", file: ".claude.json", contents: "{}")
        _ = try makeHome(".claude-empty", file: "README", contents: "no marker here")
        _ = try makeHome(".codex-work", file: "auth.json", contents: "{}")

        let found = AccountDirectory.discover(in: root, agent: .claude).map(\.lastPathComponent)
        XCTAssertEqual(found, [".claude-work"])
    }
}
