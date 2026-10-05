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

    /// `claude plugin test Resources/ClaudePlugin` makes the engine write types into the SOURCE
    /// folder, and the folder reference ships them. Copying them would overwrite the engine's own
    /// declarations in the owned copy with a stale version's.
    func testNeverCopiesTheSourcesEngineTypes() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("v1", "hooks/register.ts", in: src)
        try write("stale", ".claude-plugin/types/x.d.ts", in: src)
        try write("stale", ".claude-plugin/types/y.d.ts", in: src)
        try write("fresh", ".claude-plugin/types/y.d.ts", in: dst)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".claude-plugin/types/x.d.ts").path))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent(".claude-plugin/types/y.d.ts"), encoding: .utf8), "fresh")
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

    /// The engine writes a root `tsconfig.json` into the folder claude loads from. A prune that
    /// deleted every file the bundle does not ship removed it on every launch.
    func testRefreshKeepsAFileTheEngineWroteThatWeNeverCopied() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("v1", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        try write("{\"extends\": \"./.claude-plugin/types/tsconfig.json\"}", "tsconfig.json", in: dst)
        try write("v2", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("tsconfig.json").path))
    }

    func testFirstRunWithNoManifestDeletesNothing() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("v1", "hooks/register.ts", in: src)
        try write("stray", "stray.txt", in: dst)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("stray.txt").path))
    }

    func testAnUnchangedFileHasItsAttributesLeftAlone() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("#!/bin/bash\n", "scripts/record.sh", in: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("scripts/record.sh").path)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        let file = dst.appendingPathComponent("scripts/record.sh")
        let before = try file.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
        Thread.sleep(forTimeInterval: 1.1)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        let after = try file.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
        XCTAssertEqual(before, after, "a chmod to the same mode still bumps ctime")
    }

    /// A destination that cannot be created must not leave the tab with no hooks.
    func testApplyingFallsBackToTheBundleWhenTheDestinationIsUnwritable() throws {
        let blocker = root.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: blocker)
        let dest = blocker.appendingPathComponent("plugin")
        let bundle = Bundle(for: Self.self)
        let bundled = try XCTUnwrap(ClaudePluginLocation.directory(bundle: bundle))
        let out = ClaudePluginLocation.applying(to: .claude(FlagSet()), bundle: bundle, pluginDestination: dest)
        guard case .claude(let flags) = out, case .list(let items)? = flags.values["--plugin-dir"] else {
            return XCTFail("expected a claude payload carrying --plugin-dir")
        }
        XCTAssertEqual(items, [bundled.path])
    }
}
