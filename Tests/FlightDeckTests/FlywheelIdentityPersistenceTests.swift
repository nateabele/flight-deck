import XCTest
@testable import FlightDeck

final class FlywheelIdentityPersistenceTests: XCTestCase {
    func testEntryRoundTripsFlywheelName() throws {
        let e = SessionSnapshot.Entry(id: UUID(), title: "t", workingDirectory: "/tmp/p",
                                      flywheelAgentName: "BlueFalcon")
        let data = try JSONEncoder().encode(e)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.Entry.self, from: data).flywheelAgentName,
                       "BlueFalcon")
    }

    func testLegacyEntryWithoutFieldDecodesToNil() throws {
        // A minimal legacy entry JSON with none of the optional fields present.
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","title":"t","workingDirectory":"/tmp/p"}"#.utf8)
        let e = try JSONDecoder().decode(SessionSnapshot.Entry.self, from: legacy)
        XCTAssertNil(e.flywheelAgentName)
    }

    func testSessionCarriesIdentity() {
        let s = Session(title: "t", workingDirectory: "/tmp/p",
                        flywheelIdentity: FlywheelIdentity(agentName: "RedOtter", project: "/tmp/p"))
        XCTAssertEqual(s.flywheelIdentity?.agentName, "RedOtter")
    }
}
