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
    private func folder(_ manifest: String, files: [(String, String)] = [("chart.md", "draw"), ("style.css", "x")],
                        executable: [String] = []) throws -> URL {
        let url = tmp.appendingPathComponent("p-\(UUID().uuidString)")
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

    private func check(_ folder: URL) async -> ProviderCheckReport {
        await ProviderCheck.run(folder: folder, sandbox: ProviderSandbox(snapshotRoot: tmp.appendingPathComponent("runs")))
    }

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
        let report = await check(try folder(manifest, files: [("style.css", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        let line = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.hasPrefix("instructions") }! + 1
        XCTAssertTrue(report.text.contains("provider.toml:\(line): error: "), report.text)
        XCTAssertTrue(report.text.contains("chart.md"), report.text)
    }

    func testMissingAssetIsReported() async throws {
        let report = await check(try folder(Self.header + Self.kind, files: [("chart.md", "draw")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("style.css"), report.text)
    }

    func testInstructionsThatAreAFolderAreReported() async throws {
        let report = await check(try folder(Self.header + Self.kind, files: [("chart.md/inner", "x"), ("style.css", "x")]))
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
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "exit 9")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("samples/chart"), report.text)
    }

    func testGeneratorSampleRunsInTheSandboxAndReportsItsOutput() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let script = "cat \"$1\"/in.txt > \"$2\"/chart.svg\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", script), ("samples/chart/in.txt", "<svg/>")]))
        XCTAssertEqual(report.exitCode, 0, report.text)
        XCTAssertTrue(report.text.contains("chart.svg"), report.text)
    }

    func testFailingGeneratorSampleExitsOneWithItsStderr() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "echo boom >&2; exit 3\n"), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("boom"), report.text)
        XCTAssertTrue(report.text.contains("3"), report.text)
    }

    func testGeneratorThatWritesNothingIsAProblem() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "exit 0\n"), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
    }

    func testGeneratorSampleCannotReachTheNetwork() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let script = "/usr/bin/curl -sS --max-time 5 http://1.1.1.1/ > \"$2\"/chart.svg || exit 4\n"
        let report = await check(try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", script), ("samples/chart/in.txt", "x")]))
        XCTAssertEqual(report.exitCode, 1, report.text)
    }

    func testSamplesFolderThatIsALinkOutIsRefused() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), "no sandbox-exec")
        let url = try folder(Self.header + Self.kind + Self.generator, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "exit 0\n")])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("samples"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.appendingPathComponent("samples/chart").path,
                                                   withDestinationPath: "/etc")
        let report = await check(url)
        XCTAssertEqual(report.exitCode, 1, report.text)
        XCTAssertTrue(report.text.contains("outside"), report.text)
    }

    func testBrokenManifestNeverRunsTheGenerator() async throws {
        let marker = tmp.appendingPathComponent("ran")
        let manifest = Self.header + Self.kind.replacingOccurrences(of: "output = \"svg\"", with: "output = \"gif\"") + Self.generator
        let report = await check(try folder(manifest, files: [
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "touch \(marker.path)\n"), ("samples/chart/in.txt", "x")]))
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
            ("chart.md", "d"), ("style.css", "x"), ("gen.sh", "cat \"$1\"/in.txt > \"$2\"/chart.svg\n"),
            ("samples/chart/in.txt", "<svg/>")])
        let result = try flightdeck(["provider", "check", url.path])
        XCTAssertEqual(result.status, 0, result.out + result.err)
        XCTAssertTrue(result.out.contains("chart.svg"), result.out)
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
