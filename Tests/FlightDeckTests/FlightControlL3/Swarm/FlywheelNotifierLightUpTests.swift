import XCTest
import IntakeKit
@testable import FlightDeck

/// The three FlywheelNotifier triggers were wired but dormant on live data (Level 1 caveat). With
/// real reservations, guard-block waiters, activity and BLOCKED: they fire — and only when a human
/// is needed.
@MainActor
final class FlywheelNotifierLightUpTests: XCTestCase {
    private final class Recording: Notifying {
        var notified: [(UUID, String)] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, subtitle: String, body: String) { notified.append((sessionID, title)) }
        func withdraw(sessionID: UUID) {}
    }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func projection(holderActiveAt: Date, blocked: Set<String> = [], edges: [FlywheelReadCommands.RawDepEdge] = [],
                            beads: [FlywheelReadCommands.RawBead] = []) -> FlywheelProjection {
        let raw = FlywheelSnapshot(
            agents: [.init(name: "GreenFox"), .init(name: "BlueLake")], beads: beads,
            reservations: [.init(file: "Sources/*.swift", holder: "GreenFox", since: now - 3_600, waiters: [])],
            depEdges: edges, events: nil)
        let contest = Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: nil, message: "m", at: now)
        let enriched = ObserveEnrichment.enrich(raw, contests: ["BlueLake": contest],
                                                activity: ["GreenFox": holderActiveAt, "BlueLake": now], blocked: blocked)
        return FlywheelProjection.project(enriched, now: now, stallThreshold: 600, previous: nil)
    }

    private func notifier(_ recording: Recording, ids: [String: UUID]) -> FlywheelNotifier {
        let n = FlywheelNotifier(notifier: recording, blockThreshold: 120, now: { [now] in now })
        n.route = { _, agent in ids[agent] }
        return n
    }

    func testAStalledHolderOfAContestedFileNotifies() {
        let recording = Recording(); let green = UUID()
        notifier(recording, ids: ["GreenFox": green]).evaluate(projectsByKey: ["/p": projection(holderActiveAt: now - 1_200)])
        XCTAssertEqual(recording.notified.map { $0.0 }, [green])
    }

    func testAnActiveHolderDoesNotNotify() {
        let recording = Recording()
        notifier(recording, ids: ["GreenFox": UUID()]).evaluate(projectsByKey: ["/p": projection(holderActiveAt: now - 30)])
        XCTAssertTrue(recording.notified.isEmpty)
    }

    func testABlockedDeclarationNotifiesOnlyPastTheThreshold() {
        let recording = Recording(); let blue = UUID()
        var clock = now
        let n = FlywheelNotifier(notifier: recording, blockThreshold: 120, now: { clock })
        n.route = { _, agent in agent == "BlueLake" ? blue : nil }
        n.evaluate(projectsByKey: ["/p": projection(holderActiveAt: now, blocked: ["BlueLake"])])
        XCTAssertTrue(recording.notified.isEmpty, "a fresh block is not yet persistent")
        clock = now + 121
        n.evaluate(projectsByKey: ["/p": projection(holderActiveAt: now, blocked: ["BlueLake"])])
        XCTAssertEqual(recording.notified.map { $0.0 }, [blue])
    }

    func testACycleOfUnassignedTasksNotifiesNobodyAndDoesNotCrash() {
        let recording = Recording()
        let p = projection(holderActiveAt: now,
                           edges: [.init(from: "t-1", to: "t-2"), .init(from: "t-2", to: "t-1")],
                           beads: [.init(id: "t-1", title: "a", status: "in_progress", assignee: nil),
                                   .init(id: "t-2", title: "b", status: "in_progress", assignee: nil)])
        notifier(recording, ids: ["BlueLake": UUID(), "GreenFox": UUID()]).evaluate(projectsByKey: ["/p": p])
        XCTAssertTrue(recording.notified.isEmpty, "the task id is not an agent name, so route finds no tab")
    }

    func testADependencyCycleRoutesToTheTaskOwner() {
        let recording = Recording(); let blue = UUID()
        let p = projection(holderActiveAt: now,
                           edges: [.init(from: "t-1", to: "t-2"), .init(from: "t-2", to: "t-1")],
                           beads: [.init(id: "t-1", title: "a", status: "in_progress", assignee: "BlueLake"),
                                   .init(id: "t-2", title: "b", status: "in_progress", assignee: "GreenFox")])
        notifier(recording, ids: ["BlueLake": blue]).evaluate(projectsByKey: ["/p": p])
        XCTAssertEqual(recording.notified.map { $0.0 }, [blue])
        XCTAssertEqual(recording.notified.map { $0.1 }, ["Dependency cycle involving t-1"])
    }
}
