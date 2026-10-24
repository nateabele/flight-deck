import XCTest
@testable import FlightDeck

/// Folder trust carried between claude accounts — read side only. Exactly the folder asked
/// about; a trusted parent is a wider grant and carries nothing.
final class ClaudeFolderTrustTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func home(_ name: String, trusting projects: [String: Bool]) throws -> URL {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let body = ["projects": projects.mapValues { ["hasTrustDialogAccepted": $0] }]
        try JSONSerialization.data(withJSONObject: body)
            .write(to: home.appendingPathComponent(".claude.json"))
        return home
    }

    func testTheExactFolderTrustedElsewhereCarries() throws {
        let other = try home(".claude-a", trusting: ["/work/tessera": true])
        let mine = try home(".claude-b", trusting: [:])
        XCTAssertTrue(ClaudeFolderTrust.anyTrusts("/work/tessera", homes: [mine, other]))
    }

    func testATrustedParentDoesNotCarry() throws {
        let other = try home(".claude-a", trusting: ["/work": true])
        XCTAssertFalse(ClaudeFolderTrust.anyTrusts("/work/tessera", homes: [other]))
    }

    func testAnEntryWithoutAcceptanceDoesNotCarry() throws {
        let other = try home(".claude-a", trusting: ["/work/tessera": false])
        XCTAssertFalse(ClaudeFolderTrust.anyTrusts("/work/tessera", homes: [other]))
    }

    func testAMissingOrBrokenConfigTrustsNothing() throws {
        let broken = root.appendingPathComponent(".claude-broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent(".claude.json"))
        let missing = root.appendingPathComponent(".claude-missing", isDirectory: true)
        XCTAssertFalse(ClaudeFolderTrust.anyTrusts("/work/tessera", homes: [broken, missing]))
    }

    func testTheBuiltInHomeAlsoReadsTheConfigBesideIt() throws {
        let builtIn = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeFolderTrust.configs(forHome: builtIn, builtInHome: builtIn).map(\.path), [
            builtIn.appendingPathComponent(".claude.json").path,
            root.appendingPathComponent(".claude.json").path,
        ])
    }
}
