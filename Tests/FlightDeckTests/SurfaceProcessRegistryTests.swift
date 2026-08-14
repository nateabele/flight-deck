// Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift
import XCTest
@testable import FlightDeck

/// Returns a scripted child set per call, so a test can stage "before" and "after".
private final class ScriptedInspector: ProcessInspecting, @unchecked Sendable {
    var snapshots: [Set<pid_t>]
    /// Overrides `pgid(of:)`'s answer for every pid, so a test can prove `record` goes
    /// through this seam rather than calling `getpgid` itself. `nil` falls back to reporting
    /// the pid as its own group, matching the common `setsid` case.
    var pgidOverride: pid_t?
    init(snapshots: [Set<pid_t>]) { self.snapshots = snapshots }

    func children(of ppid: pid_t) -> Set<pid_t> {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { 100 }
    func isAlive(_ identity: ProcessIdentity) -> Bool { true }
    func pgid(of pid: pid_t) -> pid_t? { pgidOverride ?? pid }
}

@MainActor
final class SurfaceProcessRegistryTests: XCTestCase {
    private let tab = UUID()

    func testRecordsTheOneNewChild() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10, 11], [10, 11, 12]])
        )

        let made = registry.record(for: tab) { "surface" }

        XCTAssertEqual(made, "surface")
        XCTAssertEqual(registry.process(for: tab)?.identity.pid, 12)
    }

    /// `record` must read the group through `ProcessInspecting` rather than calling
    /// `getpgid` itself — otherwise this is untestable, which is exactly what let a stale
    /// on-disk pgid go unnoticed until the orphan sweep started trusting one.
    func testRecordsThePgidTheInspectorReports() {
        let inspector = ScriptedInspector(snapshots: [[10, 11], [10, 11, 12]])
        inspector.pgidOverride = 999
        let registry = SurfaceProcessRegistry(inspector: inspector)

        registry.record(for: tab) { () }

        XCTAssertEqual(registry.process(for: tab)?.pgid, 999)
    }

    /// No new child (surface creation failed) records nothing rather than guessing.
    func testRecordsNothingWhenNoChildAppeared() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10], [10]])
        )

        registry.record(for: tab) { () }

        XCTAssertNil(registry.process(for: tab))
    }

    /// Two new children is ambiguous — which one is the shell? Record nothing.
    func testRecordsNothingWhenTheDiffIsAmbiguous() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10], [10, 11, 12]])
        )

        registry.record(for: tab) { () }

        XCTAssertNil(registry.process(for: tab))
    }

    func testForgetReturnsAndRemovesTheRecord() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[], [7]])
        )
        registry.record(for: tab) { () }

        let forgotten = registry.forget(tab)

        XCTAssertEqual(forgotten?.identity.pid, 7)
        XCTAssertNil(registry.process(for: tab))
        XCTAssertNil(registry.forget(tab))
    }

    func testRestoreRepopulatesFromASnapshot() {
        let registry = SurfaceProcessRegistry(inspector: ScriptedInspector(snapshots: []))
        let stored = SessionProcess(
            identity: ProcessIdentity(pid: 88, procStart: 5), pgid: 88
        )

        registry.restore([tab: stored])

        XCTAssertEqual(registry.all, [tab: stored])
    }
}
