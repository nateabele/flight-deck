// Tests/FlightDeckTests/SessionCloseReapTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class SpyReporter: ReapReporting, @unchecked Sendable {
    var reported: [ReapOutcome] = []
    var sweeps: [Int] = []
    func report(_ outcome: ReapOutcome, context: String) { reported.append(outcome) }
    func reportSweep(cleaned: Int) { sweeps.append(cleaned) }
}

@MainActor
final class SessionCloseReapTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(provider: StubProvider(), persistence: nil)
    }

    /// A tab with no recorded process must still close cleanly — this is every tab created
    /// by a stub provider, and every tab whose pid diff came back ambiguous.
    func testClosingATabWithNoRecordedProcessStillCloses() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(session.id)

        XCTAssertTrue(s.repos.flatMap(\.sessions).isEmpty)
    }

    func testClosingForgetsTheProcessRecord() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        s.processRegistry.restore([
            session.id: SessionProcess(
                identity: ProcessIdentity(pid: 31337, procStart: 1), pgid: 31337
            )
        ])

        s.closeSession(session.id)

        XCTAssertNil(s.processRegistry.process(for: session.id))
    }

    /// The row must vanish synchronously; only the invisible surface teardown is deferred.
    func testTheRowDisappearsImmediatelyEvenThoughTheReapIsAsync() {
        let s = store()
        let first = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        let second = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(first.id)

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [second.id])
        XCTAssertEqual(s.selectedSessionID, second.id)
    }

    /// A close notification for a surface the store no longer knows about must be a no-op,
    /// not a crash or a second close — this interleaving is new with parked surfaces.
    func testCloseNotificationForAnUnknownSurfaceIsIgnored() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        // No object at all: `observeSurfaceClose` casts `note.object` to a `SurfaceView` and
        // returns on failure, which is the same path a parked surface's late close takes.
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil
        )

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [session.id])
    }
}
