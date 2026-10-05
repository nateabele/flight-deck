import XCTest
@testable import FlightDeck

/// The engine lays its type declarations into a `--plugin-dir` folder at every load (probe 1,
/// Outcome 3C). Pointed at the app bundle, that write lands inside a signed bundle. These pin
/// the copy Flight Deck runs instead: complete, refreshed when the bundle changes, and never
/// fighting the engine over the files it owns.
final class ClaudePluginMaterializeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-materialize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testCopiesEveryFileOfTheSource() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("{}", "hooks/hooks.json", in: src)
        try write("export const register = () => {}", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("hooks/register.ts"), encoding: .utf8),
                       "export const register = () => {}")
    }

    func testRefreshesAChangedFileAndKeepsTheEnginesTypes() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("v1", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        try write("declare module 'claude-code' {}", ".claude-plugin/types/claude-code/index.d.ts", in: dst)
        try write("v2", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("hooks/register.ts"), encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".claude-plugin/types/claude-code/index.d.ts").path))
    }

    func testRemovesAFileTheSourceNoLongerShips() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("x", "scripts/old.sh", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        try FileManager.default.removeItem(at: src.appendingPathComponent("scripts/old.sh"))
        try write("y", "scripts/new.sh", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("scripts/old.sh").path))
    }

    func testKeepsTheExecutableBit() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("#!/bin/bash\nexit 0\n", "scripts/record.sh", in: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("scripts/record.sh").path)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        let perms = try FileManager.default.attributesOfItem(atPath: dst.appendingPathComponent("scripts/record.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertNotEqual((perms?.intValue ?? 0) & 0o100, 0, "record.sh must stay executable or every hook exits 126")
    }
}
