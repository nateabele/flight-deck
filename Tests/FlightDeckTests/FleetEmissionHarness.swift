import XCTest
import FleetKit
@testable import FlightDeck

/// Installs a replicator on a store and turns any drift into a test failure with the two
/// snapshots printed side by side.
///
/// Every store test in this feature goes through here rather than constructing a replicator
/// inline, because the assertion is only worth anything if it is on by default: a test that
/// forgot to install it would pass over exactly the missing-emission bug the assertion
/// exists to catch.
@MainActor
func attachedReplicator(
    to store: SessionStore, file: StaticString = #filePath, line: UInt = #line
) -> FleetReplicator {
    let replicator = FleetReplicator { [weak store] in
        guard let store else { return .empty }
        return FleetProjection.snapshot(of: store)
    }
    replicator.onDrift = { mirrored, actual in
        XCTFail("""
            a mutation changed the fleet without recording its event.
            mirrored: \(mirrored)
            actual:   \(actual)
            """, file: file, line: line)
    }
    store.replicator = replicator
    return replicator
}
