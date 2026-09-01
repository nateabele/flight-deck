import XCTest
@testable import FlightDeck

/// Reading Plannotator's session registry.
///
/// The shape is undocumented and unversioned, so every rule fails closed — the same discipline
/// `ClaudeStatusFile` applies to claude's registry, and for the same reason: a guess here
/// attaches a plan gate to the wrong tab.
final class PlannotatorRegistryTests: XCTestCase {

    /// Verbatim from `~/.plannotator/sessions/18418.json`, captured 2026-08-29 while the gate
    /// was open. Hand-editing this defeats the point of having captured it.
    private let captured = Data("""
    {"pid":18418,"port":54232,"url":"http://localhost:54232","mode":"plan",\
    "project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z","label":"plan-flight-deck"}
    """.utf8)

    func testDecodesTheCapturedEntry() throws {
        let entry = try XCTUnwrap(PlannotatorRegistry.decode(captured))
        XCTAssertEqual(entry.pid, 18418)
        XCTAssertEqual(entry.port, 54232)
        XCTAssertEqual(entry.mode, "plan")
        XCTAssertEqual(entry.project, "flight-deck")
    }

    func testRefusesAnEntryMissingAField() {
        XCTAssertNil(PlannotatorRegistry.decode(Data(#"{"pid":1,"mode":"plan"}"#.utf8)))
        XCTAssertNil(PlannotatorRegistry.decode(Data("not json".utf8)))
    }

    /// A `review` or `annotate` server is a real Plannotator session and is not a plan gate.
    /// Treating one as a gate would offer Approve for a document no agent is blocked on.
    func testKeepsOnlyPlanMode() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan"),
            "2.json": entryJSON(pid: 2, mode: "review"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { $0 + 100 }
        )
        XCTAssertEqual(Set(gates.keys), [101])
    }

    /// A crashed hook leaves its file behind. A dead pid is not a gate — the phone would draw
    /// an Approve button wired to nothing.
    func testDropsDeadProcesses() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan"),
            "2.json": entryJSON(pid: 2, mode: "plan"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { $0 == 1 }, parentOf: { $0 + 100 }
        )
        XCTAssertEqual(Set(gates.keys), [101])
    }

    /// **Attribution is by parent pid, never by `project` or `cwd`.** This checkout runs many
    /// sessions from one directory; two gates that share a project name belong to different
    /// tabs and must not collapse into one.
    func testTwoGatesInOneProjectAttributeToDifferentSessions() throws {
        let dir = try makeRegistry([
            "1.json": entryJSON(pid: 1, mode: "plan", project: "flight-deck"),
            "2.json": entryJSON(pid: 2, mode: "plan", project: "flight-deck"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { $0 == 1 ? 900 : 901 }
        )
        XCTAssertEqual(Set(gates.keys), [900, 901])
        XCTAssertEqual(gates[900]?.port, 1 + 50000)
        XCTAssertEqual(gates[901]?.port, 2 + 50000)
    }

    /// An orphaned hook whose parent has gone belongs to no tab.
    func testDropsAnEntryWithNoResolvableParent() throws {
        let dir = try makeRegistry(["1.json": entryJSON(pid: 1, mode: "plan")])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { _ in nil }
        )
        XCTAssertTrue(gates.isEmpty)
    }

    /// **A port that cannot name a server is not a gate.** Everything downstream builds
    /// `http://127.0.0.1:<port>` out of this number, and `URL(string:)` answers nil for a
    /// negative one — so an unchecked `-1` reaches `PlanGateClient` and used to take the whole
    /// Mac app down on the next poll. The range is the file's own fail-closed rule applied to a
    /// number: 0 and 65536 are not ports either, and neither describes anything worth polling.
    func testRefusesAPortThatIsNotAPort() {
        for port in [-1, 0, 65536, 70000] {
            XCTAssertNil(
                PlannotatorRegistry.decode(Data("""
                {"pid":1,"port":\(port),"url":"http://localhost","mode":"plan",\
                "project":"p","startedAt":"2026-08-29T17:40:36.186Z"}
                """.utf8)),
                "\(port) is not a port"
            )
        }
    }

    /// And end to end: a registry file carrying one takes the same road every other
    /// unrecognised entry takes — the caller sees no gate, rather than a gate that crashes.
    func testAnEntryWithAnImpossiblePortYieldsNoGate() throws {
        let dir = try makeRegistry([
            "1.json": """
            {"pid":1,"port":-1,"url":"http://localhost","mode":"plan",\
            "project":"p","startedAt":"2026-08-29T17:40:36.186Z"}
            """,
            "2.json": entryJSON(pid: 2, mode: "plan"),
        ])
        let gates = PlannotatorRegistry.planGates(
            in: dir, isAlive: { _ in true }, parentOf: { $0 + 100 }
        )
        XCTAssertEqual(Set(gates.keys), [102], "only the well-formed entry is a gate")
    }

    // MARK: Helpers

    private func entryJSON(pid: Int, mode: String, project: String = "p") -> String {
        """
        {"pid":\(pid),"port":\(pid + 50000),"url":"http://localhost:\(pid + 50000)",\
        "mode":"\(mode)","project":"\(project)","startedAt":"2026-08-29T17:40:36.186Z",\
        "label":"\(mode)-\(project)"}
        """
    }

    private func makeRegistry(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }
}
