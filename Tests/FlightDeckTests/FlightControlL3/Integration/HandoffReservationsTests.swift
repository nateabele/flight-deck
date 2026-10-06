import XCTest
import IntakeKit
@testable import FlightDeck

/// The hand-off prompt tells the replacement which files its predecessor reserved. The planner
/// has no reservation read of its own (it lives in Observe's projection, behind the swarm), so
/// the composition backs `StoreHandoffHost.reservationLookup` with `SwarmService.reservationsLookup`.
/// Left unwired the host answers nil, and a prompt then falls back to "held no file
/// reservations" for an agent that held several.
@MainActor
final class HandoffReservationsTests: XCTestCase {
    private var rig: L3IntegrationRig!

    override func setUp() async throws { rig = try L3IntegrationRig.standard() }
    override func tearDown() async throws {
        await rig?.swarm.settle()
        rig = nil
    }

    func testHandoffPromptListsTheOldAgentsReservations() async throws {
        rig.swarm.reservationsLookup = { _ in
            [HeldReservation(pattern: "Sources/A.swift", holder: "Agent1", since: nil),
             HeldReservation(pattern: "Docs/**", holder: "Agent1", since: nil),
             HeldReservation(pattern: "Other.swift", holder: "Agent9", since: nil)]
        }
        _ = try await rig.launchAndCrossHard()
        let handoff = try XCTUnwrap(rig.spawns.dropFirst().first, "the hand-off must have spawned")
        XCTAssertTrue(handoff.firstPrompt.contains("Sources/A.swift"), handoff.firstPrompt)
        XCTAssertTrue(handoff.firstPrompt.contains("Docs/**"), handoff.firstPrompt)
        XCTAssertFalse(handoff.firstPrompt.contains("Other.swift"), "another agent's file is not the old agent's")
        XCTAssertFalse(handoff.firstPrompt.contains("held no file reservations"), handoff.firstPrompt)
    }

    /// `[]` is an answer ("holds none"), distinct from the nil of "cannot read".
    func testAnAgentHoldingNothingSaysSo() async throws {
        rig.swarm.reservationsLookup = { _ in [HeldReservation(pattern: "Other.swift", holder: "Agent9", since: nil)] }
        _ = try await rig.launchAndCrossHard()
        let handoff = try XCTUnwrap(rig.spawns.dropFirst().first)
        XCTAssertTrue(handoff.firstPrompt.contains("held no file reservations"), handoff.firstPrompt)
        XCTAssertFalse(handoff.firstPrompt.contains("Other.swift"), handoff.firstPrompt)
    }
}
