import XCTest
@testable import FlightDeck

/// `flightdeck provider check`: the pure checker over temp folders, then the built binary
/// against the same fixtures for exit codes and output.
final class ProviderCheckTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    private static let header = """
    id = "fd.t"
    name = "T"
    version = "1"
    contract = 1

    """

    private static let kind = """
    [[kind]]
    id = "chart"
    summary = "A chart"
    output = "svg"
    entry = "chart.svg"
    instructions = "chart.md"
    assets = ["style.css"]

    """

    /// A provider folder holding `manifest` and `files`.
    private func folder(_ manifest: String, files: [(String, String)] = [("chart.md", "draw"), ("style.css", "x"), ("chart.svg", "x")],
                        name: String = "p", executable: [String] = []) throws -> URL {
        let url = tmp.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: url.appendingPathComponent("provider.toml"))
        for (path, text) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            if executable.contains(path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        return url
    }

    private func check(_ folder: URL, runSamples: Bool = true, sandbox: ProviderSandbox? = nil) async -> ProviderCheckReport {
        await ProviderCheck.run(folder: folder, runSamples: runSamples,
                                sandbox: sandbox ?? ProviderSandbox(snapshotRoot: tmp.appendingPathComponent("runs")))
    }

    private var hasSandbox: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }

    private static let generator = """
    [generator]
    command = ["/bin/sh", "gen.sh", "{source}", "{out}"]
    timeout = "20s"

    """

    // MARK: - Manifest

    func testValidProviderExitsZero() async throws {
        let report = await check(try folder(Self.header + Self.kind))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("fd.t"), report.text)
        XCTAssertTrue(report.text.contains("valid"), report.text)
    }

    func testBrokenManifestReportsTheLineAndExitsOne() async throws {
        let manifest = Self.header + Self.kind.replacingOccurrences(of: "output = \"svg\"", with: "output = \"gif\"")
        let report = await check(try folder(manifest))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("provider.toml:"), report.text)
        XCTAssertFalse(report.text.contains("valid\n"), "a broken provider is never partly valid: \(report.text)")
    }

    func testNewerContractSaysSo() async throws {
        let report = await check(try folder("id = \"fd.t\"\ncontract = 2\n"))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("newer Flight Deck"), report.text)
        XCTAssertTrue(report.text.contains("provider.toml:2"), report.text)
    }

    func testMissingInstructionsFileIsReportedAtItsLine() async throws {
        let manifest = Self.header + Self.kind
        let report = await check(try folder(manifest, files: [("style.css", "x"), ("chart.svg", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        let line = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.hasPrefix("instructions") }! + 1
        XCTAssertTrue(report.text.contains("provider.toml:\(line): error: "), report.text)
        XCTAssertTrue(report.text.contains("chart.md"), report.text)
    }

    func testMissingAssetIsReported() async throws {
        let report = await check(try folder(Self.header + Self.kind, files: [("chart.md", "draw"), ("chart.svg", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("style.css"), report.text)
    }

    func testInstructionsThatAreAFolderAreReported() async throws {
        let report = await check(try folder(Self.header + Self.kind, files: [("chart.md/inner", "x"), ("style.css", "x"), ("chart.svg", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
    }

    func testFolderWithoutAManifestExitsOne() async throws {
        let empty = tmp.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let report = await check(empty)
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("provider.toml"), report.text)
    }

    func testMissingFolderExitsOne() async {
        let report = await check(tmp.appendingPathComponent("nope"))
        XCTAssertEqual(report.exitCode, 1, report.text)
    }

    func testUnknownKeyIsAWarningAndStillValid() async throws {
        let report = await check(try folder(Self.header + "colour = \"red\"\n" + Self.kind))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("warning"), report.text)
    }

    // MARK: - Generator samples

    func testGeneratorWithoutSamplesIsNotRunAndSaysSo() async throws {
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 9")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("samples/chart"), report.text)
    }

    func testGeneratorSampleRunsInTheSandboxAndReportsItsOutput() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let script = "cat \"$1\"/in.txt > \"$2\"/chart.svg\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", script), ("samples/chart/in.txt", "<svg/>")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("chart.svg"), report.text)
    }

    func testFailingGeneratorSampleExitsOneWithItsStderr() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "echo boom >&2; exit 3\n"), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("boom"), report.text)
        XCTAssertTrue(report.text.contains("3"), report.text)
    }

    func testGeneratorThatWritesNothingIsAProblem() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 0\n"), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("wrote no files"), report.text)
    }

    func testGeneratorSampleCannotReachTheNetwork() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let script = "/usr/bin/curl -sS --max-time 5 http://1.1.1.1/ > \"$2\"/chart.svg || exit 4\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", script), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("exited 4"), report.text)
        XCTAssertTrue(report.text.contains("curl:"), "the sandbox's own refusal must be shown: \(report.text)")
    }

    func testGeneratorSampleCannotWriteOutsideItsFolder() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let target = tmp.appendingPathComponent("escaped.txt").path
        let script = "echo hi > '\(target)' || exit 5\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", script), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("exited 5"), report.text)
        XCTAssertTrue(report.text.contains("Operation not permitted"), report.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testSamplesFolderThatIsALinkOutIsRefused() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let url = try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 0\n")])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("samples"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent("samples/chart").path,
                                                   withDestinationPath: "/etc")
        let report = await check(url)
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("outside"), report.text)
        XCTAssertTrue(report.text.contains("samples/chart"), report.text)
    }

    // MARK: - Fix round 1

    func testMissingEntryFileIsReportedAtItsLine() async throws {
        let manifest = Self.header + Self.kind
        let report = await check(try folder(manifest, files: [("chart.md", "d"), ("style.css", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        let line = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.hasPrefix("entry") }! + 1
        XCTAssertTrue(report.text.contains("provider.toml:\(line): error: "), report.text)
        XCTAssertTrue(report.text.contains("chart.svg"), report.text)
    }

    func testEntryThatIsAFolderIsReported() async throws {
        let report = await check(try folder(Self.header + Self.kind, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg/inner", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
    }

    func testLineComesFromTheKindThatNamesTheMissingFile() async throws {
        let second = Self.kind.replacingOccurrences(of: "id = \"chart\"", with: "id = \"other\"")
            .replacingOccurrences(of: "instructions = \"chart.md\"", with: "instructions = \"gone/../other.md\"")
        let manifest = Self.header + Self.kind + "\n" + second
        let report = await check(try folder(manifest))
        XCTAssertEqual(report.exitCode, 1, report.text)
        let line = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains("other.md") }! + 1
        XCTAssertTrue(report.text.contains("provider.toml:\(line): error: "), report.text)
        XCTAssertFalse(report.text.contains("provider.toml:1:"), report.text)
    }

    func testACommentNamingThePathDoesNotStealTheLine() async throws {
        let manifest = "# chart.md lives next to chart.svg\n" + Self.header + Self.kind
        let report = await check(try folder(manifest, files: [("style.css", "x"), ("chart.svg", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertFalse(report.text.contains("provider.toml:1:"), report.text)
    }

    func testPathEscapeThroughCheckIsRefusedWithItsLine() async throws {
        let manifest = Self.header + Self.kind.replacingOccurrences(of: "\"chart.md\"", with: "\"../../x.md\"")
        let report = await check(try folder(manifest))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("outside the provider folder"), report.text)
        XCTAssertTrue(report.text.contains("provider.toml:"), report.text)
    }

    func testGeneratorIsNotRunWithoutTheFlagAndTheLastLineSaysSo() async throws {
        let marker = tmp.appendingPathComponent("ran")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "touch '\(marker.path)'\n"),
            ("samples/chart/in.txt", "x")]), runSamples: false)
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertEqual(report.text.split(separator: "\n").last.map(String.init),
                       "generator not run (pass --run-samples to try it in the sandbox)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testArgvIsPrintedBeforeTheRunOnePerKind() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "echo a > \"$2\"/chart.svg\n"),
            ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        let lines = report.text.split(separator: "\n").map(String.init)
        let running = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("running sample chart: /bin/sh gen.sh {source} {out}") }, report.text)
        let done = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("sample chart: ok") }, report.text)
        XCTAssertLessThan(running, done)
    }

    func testValidSaysGeneratorUntestedWhenNoSampleRan() async throws {
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 0\n")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("generator untested"), report.text)
    }

    func testControlCharactersInStderrAreStripped() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let script = "printf '\\033]0;pwned\\007\\033[31mred' >&2; exit 3\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", script), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("red"), report.text)
        XCTAssertFalse(report.text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 }, report.text)
    }

    func testControlCharactersInOutputNamesAreStripped() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let script = "printf x > \"$2\"/\"$(printf 'a\\033[2Jb.svg')\"\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", script), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertFalse(report.text.unicodeScalars.contains { $0.value == 0x1B }, report.text)
    }

    func testSymlinkInsideASampleNamesItsPath() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let url = try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 0\n"), ("samples/chart/in.txt", "x")])
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent("samples/chart/link.txt").path,
                                                   withDestinationPath: "in.txt")
        let report = await check(url)
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("samples/chart/link.txt is a symlink"), report.text)
    }

    func testMissingSandboxExecRefusesAndNeverRunsUnsandboxed() async throws {
        let marker = tmp.appendingPathComponent("ran")
        let missing = ProviderSandbox(sandboxExecPath: "/nonexistent/sandbox-exec",
                                      snapshotRoot: tmp.appendingPathComponent("runs"))
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "touch '\(marker.path)'\n"),
            ("samples/chart/in.txt", "x")]), sandbox: missing)
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("never runs unsandboxed"), report.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testGeneratorReadsTheCheckedCopyNotTheOriginal() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "echo \"$1\" >&2; exit 5\n"),
            ("samples/chart/in.txt", "x")]))
        XCTAssertTrue(report.text.contains("/runs/"), "the input must be inside the private copy: \(report.text)")
        XCTAssertTrue(report.text.contains("/snapshot/samples/chart"), report.text)
    }

    func testMetacharactersInPathsStayData() async throws {
        try XCTSkipUnless(hasSandbox, "no sandbox-exec")
        // A name that would break or run a shell line if anything re-read it as shell text.
        let name = "we ird;$(exit 7);'q`exit 8`"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"),
            ("gen.sh", "cat \"$1\"/*.txt > \"$2\"/chart.svg\n"), ("samples/chart/\(name).txt", "<svg/>")], name: "my provider $(x);"))
        XCTAssertEqual(report.exitCode, 0, report.text)
    }

    func testBrokenManifestNeverRunsTheGenerator() async throws {
        let marker = tmp.appendingPathComponent("ran")
        let manifest = Self.header + Self.kind.replacingOccurrences(of: "output = \"svg\"", with: "output = \"gif\"") + Self.generator
        let report = await check(try folder(manifest, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "touch \(marker.path)\n"), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - The built binary

    private func binary() throws -> URL {
        var url = Bundle(for: type(of: self)).bundleURL
        while url.pathExtension != "app" {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { throw XCTSkip("test bundle is not inside a built app") }
            url = parent
        }
        let cli = url.appendingPathComponent("Contents/MacOS/flightdeck")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "no flightdeck at \(cli.path)")
        return cli
    }

    private func flightdeck(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = args
        // No socket, on purpose: the command must not need one.
        process.environment = ["PATH": "/usr/bin:/bin", "FLIGHT_DECK_CONTROL_SOCKET": tmp.appendingPathComponent("none.sock").path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testBinaryValidProviderExitsZero() throws {
        let result = try flightdeck(["provider", "check", try folder(Self.header + Self.kind).path])
        XCTAssertEqual(result.status, 0, result.out + result.err)
        XCTAssertTrue(result.out.contains("fd.t"), result.out)
    }

    func testBinaryBrokenManifestExitsOneWithLineNumbers() throws {
        let manifest = Self.header + Self.kind.replacingOccurrences(of: "output = \"svg\"", with: "output = \"gif\"")
        let result = try flightdeck(["provider", "check", try folder(manifest).path])
        XCTAssertEqual(result.status, 1, result.out + result.err)
        XCTAssertTrue(result.out.contains("provider.toml:"), result.out)
    }

    func testBinaryGeneratorSampleRuns() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let url = try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "cat \"$1\"/in.txt > \"$2\"/chart.svg\n"),
            ("samples/chart/in.txt", "<svg/>")])
        let result = try flightdeck(["provider", "check", url.path, "--run-samples"])
        XCTAssertEqual(result.status, 0, result.out + result.err)
        XCTAssertTrue(result.out.contains("chart.svg"), result.out)
    }

    func testBinaryWithoutTheFlagDoesNotRunTheGenerator() throws {
        let url = try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("chart.svg", "x"), ("gen.sh", "exit 9\n"), ("samples/chart/in.txt", "x")])
        let result = try flightdeck(["provider", "check", url.path])
        XCTAssertEqual(result.status, 0, result.out + result.err)
        XCTAssertTrue(result.out.contains("generator not run (pass --run-samples"), result.out)
    }

    func testBinaryUsageErrorExitsTwo() throws {
        let result = try flightdeck(["provider", "check"])
        XCTAssertEqual(result.status, 2, result.out + result.err)
        XCTAssertTrue(result.err.contains("provider check"), result.err)
    }

    func testBinaryHelpListsTheProviderFamily() throws {
        let result = try flightdeck(["help", "provider"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.out.contains("provider check"), result.out)
    }
}
