import XCTest
@testable import HostKit

final class ProviderManifestParserTests: XCTestCase {
    /// Spec §9's example, verbatim.
    static let specExample = #"""
    id = "fd.diagram.mermaid"
    name = "Mermaid diagrams"
    version = "1.0.0"
    contract = 1

    [[kind]]
    id = "diagram.sequence"
    summary = "Message order between named participants"
    output = "mermaid"          # html | svg | png | mermaid | canvas
    entry = "diagram.mmd"
    pins = "nodes"              # nodes | canvas | dom | xy
    states = []
    sizes = ["default"]
    cost = { seconds = 20, tokens = 6000 }
    instructions = "kinds/diagram.sequence.md"
    assets = []

    [generator]                 # optional; omit for a data-only provider
    command = ["./bin/render", "{source}", "{out}"]
    timeout = "60s"
    network = false
    """#

    private let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("provider-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func parse(_ text: String) throws -> ProviderManifestParseResult {
        try ProviderManifestParser.parse(text, folder: folder)
    }

    private func issue(_ text: String) -> ProviderManifestIssue? {
        do { _ = try parse(text); return nil } catch { return error as? ProviderManifestIssue }
    }

    private let head = "id = \"p\"\nname = \"P\"\nversion = \"1\"\ncontract = 1\n"
    private func kind(_ extra: String = "") -> String {
        "[[kind]]\nid = \"k\"\nsummary = \"s\"\noutput = \"svg\"\nentry = \"a.svg\"\ninstructions = \"i.md\"\n\(extra)\n"
    }

    func testSpecExampleLandsInTheTypedManifest() throws {
        let result = try parse(Self.specExample)
        XCTAssertEqual(result.issues, [])
        let m = result.manifest
        XCTAssertEqual(m.id, "fd.diagram.mermaid")
        XCTAssertEqual(m.name, "Mermaid diagrams")
        XCTAssertEqual(m.version, "1.0.0")
        XCTAssertEqual(m.contract, 1)
        XCTAssertEqual(m.kinds.count, 1)
        let k = m.kinds[0]
        XCTAssertEqual(k.id, "diagram.sequence")
        XCTAssertEqual(k.summary, "Message order between named participants")
        XCTAssertEqual(k.output, .mermaid)
        XCTAssertEqual(k.entry, "diagram.mmd")
        XCTAssertEqual(k.pins, .nodes)
        XCTAssertEqual(k.states, [])
        XCTAssertEqual(k.sizes, ["default"])
        XCTAssertEqual(k.cost, ProviderKind.Cost(seconds: 20, tokens: 6000))
        XCTAssertEqual(k.instructions, "kinds/diagram.sequence.md")
        XCTAssertEqual(k.assets, [])
        XCTAssertEqual(m.generator?.command, ["bin/render", "{source}", "{out}"])
        XCTAssertEqual(m.generator?.timeout, Duration(seconds: 60))
        XCTAssertEqual(m.generator?.network, false)
    }

    func testKindArrayKeepsEveryTableInOrder() throws {
        let text = head + kind() + "\n[[kind]]\nid = \"k2\"\nsummary = \"s\"\noutput = \"html\"\nentry = \"b.html\"\ninstructions = \"j.md\"\n"
        let kinds = try parse(text).manifest.kinds
        XCTAssertEqual(kinds.map(\.id), ["k", "k2"])
        XCTAssertNil(try parse(text).manifest.generator)
    }

    func testDurationParsesThroughDuration() throws {
        let text = head + kind() + "[generator]\ncommand = [\"python3\", \"x.py\"]\ntimeout = \"1m30s\"\n"
        let generator = try XCTUnwrap(parse(text).manifest.generator)
        XCTAssertEqual(generator.timeout, Duration(seconds: 90))
        XCTAssertEqual(generator.command, ["python3", "x.py"], "a bare program name is a PATH lookup, left as written")
        let bad = head + kind() + "[generator]\ncommand = [\"x\"]\ntimeout = \"soon\"\n"
        XCTAssertEqual(issue(bad)?.line, 14)
    }

    func testMissingRequiredKeyIsAnError() {
        XCTAssertNotNil(issue(head.replacingOccurrences(of: "name = \"P\"\n", with: "") + kind()))
        XCTAssertNotNil(issue(head + kind().replacingOccurrences(of: "entry = \"a.svg\"\n", with: "")))
        XCTAssertNotNil(issue(head), "a provider with no kind is refused")
    }

    func testHigherContractNeedsANewerFlightDeckAndIsNotPartlyLoaded() {
        // The rest of the file is unreadable on purpose: nothing past `contract` may be consulted.
        let found = issue("contract = 2\nfuture = { shape = 1 }\n")
        XCTAssertEqual(found?.needsNewerFlightDeck, true)
        XCTAssertEqual(found?.line, 1)
        XCTAssertEqual(issue(head + kind())?.needsNewerFlightDeck, nil)
        XCTAssertEqual(issue(Self.specExample.replacingOccurrences(of: "contract = 1", with: "contract = 9"))?.needsNewerFlightDeck, true)
    }

    func testEscapingPathIsRefusedWithItsLine() {
        let text = head + kind().replacingOccurrences(of: "i.md", with: "../../x")
        let found = issue(text)
        XCTAssertEqual(found?.line, 10)
        XCTAssertEqual(found?.severity, .error)
        XCTAssertTrue(found?.message.contains("outside the provider folder") == true)
        XCTAssertNotNil(issue(head + kind("assets = [\"ok/../../bad\"]")))
        XCTAssertNotNil(issue(head + kind().replacingOccurrences(of: "a.svg", with: "/etc/passwd")))
        XCTAssertNotNil(issue(head + kind() + "[generator]\ncommand = [\"../bin/x\"]\n"))
    }

    func testPathThatStaysInsideIsNormalized() throws {
        let text = head + kind().replacingOccurrences(of: "i.md", with: "a/../kinds/./i.md")
        XCTAssertEqual(try parse(text).manifest.kinds[0].instructions, "kinds/i.md")
    }

    func testSymlinkOutOfTheFolderIsRefused() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        let found = issue(head + kind().replacingOccurrences(of: "i.md", with: "link/i.md"))
        XCTAssertEqual(found?.line, 10)
        XCTAssertTrue(found?.message.contains("symlink") == true)
    }

    func testUnknownTopLevelKeyIsAWarning() throws {
        let result = try parse("future = true\n" + head + kind())
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues[0].severity, .warning)
        XCTAssertEqual(result.issues[0].line, 1)
    }

    func testBadOutputNamesTheOptions() {
        let found = issue(head + kind().replacingOccurrences(of: "\"svg\"", with: "\"gif\""))
        XCTAssertTrue(found?.message.contains("mermaid") == true)
    }

    func testLoadReadsProviderTomlFromTheFolder() throws {
        XCTAssertThrowsError(try ProviderManifestParser.load(folder: folder))
        try Self.specExample.write(to: folder.appendingPathComponent("provider.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProviderManifestParser.load(folder: folder).manifest.id, "fd.diagram.mermaid")
    }

    func testEmptyOrUnsafeIdIsRefused() {
        for bad in ["", "../x", "a/b", "a b", ".hidden", "a..b", "fd.x\\n", "fd.x\\r\\n"] {
            let found = issue(head.replacingOccurrences(of: "id = \"p\"", with: "id = \"\(bad)\"") + kind())
            XCTAssertEqual(found?.line, 1, "id \"\(bad)\" must be refused at its line")
        }
        XCTAssertNil(issue(head.replacingOccurrences(of: "id = \"p\"", with: "id = \"fd.a_b-1\"") + kind()))
        XCTAssertEqual(issue(head.replacingOccurrences(of: "name = \"P\"", with: "name = \"\"") + kind())?.line, 2)
        XCTAssertEqual(issue(head.replacingOccurrences(of: "version = \"1\"", with: "version = \"\"") + kind())?.line, 3)
    }

    func testDanglingSymlinkPointingOutsideIsRefused() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nowhere-\(UUID().uuidString)/missing")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: missing)
        let found = issue(head + kind().replacingOccurrences(of: "i.md", with: "link"))
        XCTAssertEqual(found?.line, 10)
        XCTAssertTrue(found?.message.contains("symlink") == true)
        // A dangling link that stays inside is only a missing file, which `check` reports.
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("inner").path, withDestinationPath: "nothing.md")
        XCTAssertNil(issue(head + kind().replacingOccurrences(of: "i.md", with: "inner")))
    }

    func testNewerContractWithUnknownSyntaxSaysNeedsNewer() {
        let found = issue("contract = 3\nstamp = 2026-10-31T10:00:00Z\n[[[weird\n")
        XCTAssertEqual(found?.needsNewerFlightDeck, true)
        // Contract 1 with the same bad syntax is a plain parse error, not "newer".
        let plain = issue("contract = 1\n[[[weird\n")
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain?.needsNewerFlightDeck, false)
    }

    func testNewerContractInCRLFFileReportsRightLine() {
        let found = issue("id = \"p\"\r\nname = \"P\"\r\ncontract = 4\r\n[[[weird\r\n")
        XCTAssertEqual(found?.needsNewerFlightDeck, true)
        XCTAssertEqual(found?.line, 3)
    }

    func testNestedContractKeyDoesNotTriggerFallback() {
        let found = issue("contract = 1\n[[kind]]\ncontract = 9\n[[[weird\n")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.needsNewerFlightDeck, false)
    }

    func testNewlineOnlyOrTabOnlyNameAndVersionAreRefused() {
        for bad in ["\\n", "\\t", " \\r\\n"] {
            XCTAssertEqual(issue(head.replacingOccurrences(of: "name = \"P\"", with: "name = \"\(bad)\"") + kind())?.line, 2, "name \(bad)")
            XCTAssertEqual(issue(head.replacingOccurrences(of: "version = \"1\"", with: "version = \"\(bad)\"") + kind())?.line, 3, "version \(bad)")
        }
    }

    func testDanglingIntermediateLinkPointingOutsideIsRefused() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nowhere-\(UUID().uuidString)/missing")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("d"), withDestinationURL: missing)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("x").path, withDestinationPath: "d/file")
        let found = issue(head + kind().replacingOccurrences(of: "i.md", with: "x"))
        XCTAssertEqual(found?.line, 10)
        XCTAssertTrue(found?.message.contains("symlink") == true)
    }
}
