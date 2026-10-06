import XCTest
import IntakeKit
@testable import FlightDeck

/// The Debug-only fixture backend's routing and slots are what the UI test's swarm runs on, so
/// their rules are pinned here, headless.
@MainActor
final class FixtureBackendTests: XCTestCase {
    func testTheBackendReadsItsTableAndHandsOutLocalSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fcfb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"pools":{"claude-local":2},"routing":{"harness":"claude","model":"opus","pool":"claude-local"}}"#
            .write(to: root.appendingPathComponent("swarm-deps.json"), atomically: true, encoding: .utf8)
        let backend = FlightControlFixtureBackend(root: root)
        XCTAssertEqual(backend.tools.br, root.appendingPathComponent("bin/br").path)
        XCTAssertEqual(backend.swarmsRoot, root.appendingPathComponent("state", isDirectory: true))
        let deps = try XCTUnwrap(backend.dependencies())
        let a = try XCTUnwrap(deps.allocator.lease(pool: "claude-local"))
        let b = try XCTUnwrap(deps.allocator.lease(pool: "claude-local"))
        XCTAssertNil(deps.allocator.lease(pool: "claude-local"), "two slots")
        XCTAssertNil(a.account.id, "a local slot has no account")
        deps.allocator.release(b)
        XCTAssertNotNil(deps.allocator.lease(pool: "claude-local"))
        XCTAssertEqual(deps.capacity.headroom(pool: "claude-local").count, 2)
        let kind = try XCTUnwrap(KindResolution.resolve("tests", in: deps.kinds.kinds(project: root)))
        let routed = deps.makeRouter().assign(kind: kind, project: root, catalogs: AdapterCatalogs([]), now: Date()).block
        XCTAssertEqual(routed.model, "opus")
        XCTAssertEqual(routed.pool, "claude-local")
        XCTAssertNil(deps.makeRouter().spill(routed, kind: kind, project: root, exhausted: ["claude-local"],
                                       catalogs: AdapterCatalogs([]), now: Date()))
    }

    func testOnlyTheLaunchArgumentTurnsItOn() {
        let defaults = UserDefaults(suiteName: "fcfb-\(UUID().uuidString)")!
        XCTAssertNil(FlightControlFixtureBackend.fromDefaults(defaults))
        defaults.set("/tmp/x", forKey: "FlightControlFixtureBackend")
        XCTAssertEqual(FlightControlFixtureBackend.fromDefaults(defaults)?.root.path, "/tmp/x")
    }

    /// The stub agent writes the guard's whole wrapped message into its transcript; the scan needs the
    /// file, pattern and holder from the second line, so a one-line truncation contests nothing.
    func testTheGeneratorsGuardRecordParsesToAGuardBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fcfb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-flight-control-fixture.py")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        make.arguments = [script.path, root.path]
        make.standardOutput = FileHandle.nullDevice
        try make.run(); make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0)
        let message = try String(contentsOf: root.appendingPathComponent("guard-message.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let record: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "fixture", "is_error": true, "content": "Exit code 1\n" + message]]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let signals = AgentOutputScan.signals(line: line, record: record)
        guard case .guardBlock(let block)? = signals.first else { return XCTFail("no guard block in \(signals)") }
        XCTAssertEqual(block.file, "Sources/Foo.swift")
        XCTAssertEqual(block.pattern, "Sources/*.swift")
        XCTAssertEqual(block.holder, "GreenFox")
    }
}
