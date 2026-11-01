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

    func testKindsRecordTheLineOfEachPathTheyRead() throws {
        let text = """
        id = "fd.t"
        name = "T"
        version = "1"
        contract = 1

        [[kind]]
        id = "a"
        summary = "s"
        output = "svg"
        entry = "a.svg"
        instructions = "a/../a.md"
        assets = ["s.css"]

        [[kind]]
        id = "b"
        summary = "s"
        output = "svg"
        entry = "b.svg"
        instructions = "b.md"
        """
        let kinds = try ProviderManifestParser.parse(text, folder: folder).manifest.kinds
        XCTAssertEqual(kinds[0].lines.entry, 10)
        XCTAssertEqual(kinds[0].lines.instructions, 11)
        XCTAssertEqual(kinds[0].lines.assets, 12)
        XCTAssertEqual(kinds[1].lines.entry, 18)
        XCTAssertEqual(kinds[1].lines.instructions, 19)
        XCTAssertNil(kinds[1].lines.assets)
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

    func testProviderRelativeProgramIsMarked() throws {
        XCTAssertEqual(try parse(Self.specExample).manifest.generator?.providerRelative, true)
        let bare = head + kind() + "[generator]\ncommand = [\"python3\", \"x.py\"]\n"
        XCTAssertEqual(try parse(bare).manifest.generator?.providerRelative, false)
        let absolute = head + kind() + "[generator]\ncommand = [\"/usr/bin/python3\"]\n"
        XCTAssertEqual(try parse(absolute).manifest.generator?.providerRelative, false)
    }

    func testTimeoutAboveTenMinutesIsRefusedWithItsLine() throws {
        let ok = head + kind() + "[generator]\ncommand = [\"x\"]\ntimeout = \"10m\"\n"
        XCTAssertEqual(try parse(ok).manifest.generator?.timeout, Duration(seconds: 600))
        let long = head + kind() + "[generator]\ncommand = [\"x\"]\ntimeout = \"10m1s\"\n"
        XCTAssertEqual(issue(long)?.line, 14)
        XCTAssertEqual(issue(long)?.severity, .error)
        let huge = head + kind() + "[generator]\ncommand = [\"x\"]\ntimeout = \"99999999999d\"\n"
        XCTAssertEqual(issue(huge)?.line, 14)
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

    // MARK: - Final review

    private func loadIssue() -> ProviderManifestIssue? {
        do { _ = try ProviderManifestParser.load(folder: folder); return nil } catch { return error as? ProviderManifestIssue }
    }

    /// The peak footprint so far, so a read that was freed again still shows.
    private func peakFootprint() -> UInt64 {
        #if os(macOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
        #else
        return 0
        #endif
    }

    /// A cloned repo can commit a huge provider.toml; Settings reads every one. It is refused
    /// from its size, without reading it: a 300 MB file used to take 9 s and 1.5 GB.
    func testOversizedManifestIsRefusedQuicklyWithoutReadingIt() throws {
        let url = folder.appendingPathComponent("provider.toml")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data((head + kind()).utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 300 * 1024 * 1024)  // sparse: costs no disk
        try handle.close()
        let before = peakFootprint()
        let start = Date()
        let found = loadIssue()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(found?.message, "provider.toml is larger than 256 KB")
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertLessThan(Int64(peakFootprint()) - Int64(before), 16 * 1024 * 1024, "the file was read into memory")
    }

    func testManifestAtTheCapStillLoads() throws {
        let body = head + kind()
        let pad = "#" + String(repeating: "x", count: ProviderManifestParser.maxManifestBytes - body.utf8.count - 2) + "\n"
        let text = body + pad
        XCTAssertEqual(text.utf8.count, ProviderManifestParser.maxManifestBytes)
        try Data(text.utf8).write(to: folder.appendingPathComponent("provider.toml"))
        XCTAssertNoThrow(try ProviderManifestParser.load(folder: folder))
        try Data((text + "\n").utf8).write(to: folder.appendingPathComponent("provider.toml"))
        XCTAssertEqual(loadIssue()?.message, "provider.toml is larger than 256 KB")
    }

    func testManifestThatIsAFifoIsRefusedPlainly() throws {
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("provider.toml").path, 0o644), 0)
        XCTAssertEqual(loadIssue()?.message, "provider.toml must be a regular file")
    }

    func testManifestThatIsALinkIsRefusedPlainly() throws {
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("provider.toml").path,
                                                   withDestinationPath: "/dev/zero")
        XCTAssertEqual(loadIssue()?.message, "provider.toml must be a regular file")
    }

    func testManifestThatIsAFolderIsRefusedPlainly() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("provider.toml"), withIntermediateDirectories: true)
        XCTAssertEqual(loadIssue()?.message, "provider.toml must be a regular file")
    }

    /// A kind id becomes `samples/<id>` and the generator's `{kind}`, so it follows the visual-id
    /// grammar: lower-case letters, digits, ".", "_" and "-", at most 64.
    func testKindIdOutsideTheVisualIdGrammarIsRefusedWithItsLine() {
        for bad in ["a/b", "..", "../x", "a\\nb", "Upper", "-lead", ".lead", "", String(repeating: "a", count: 65)] {
            let text = head + kind().replacingOccurrences(of: "id = \"k\"", with: "id = \"\(bad)\"")
            let found = issue(text)
            XCTAssertEqual(found?.line, 6, "kind id \(bad.debugDescription)")
            XCTAssertTrue(found?.message.contains("kind id") == true, found?.message ?? "accepted \(bad.debugDescription)")
        }
        for good in ["k", "diagram.sequence", "a_b-c.1", "0", String(repeating: "a", count: 64)] {
            let text = head + kind().replacingOccurrences(of: "id = \"k\"", with: "id = \"\(good)\"")
            XCTAssertNil(issue(text), good)
        }
    }
}
