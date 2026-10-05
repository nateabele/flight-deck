import XCTest
@testable import HostKit

final class ScreenLeaseTests: XCTestCase {
    private final class Grants: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    func testFifoWithHolderLabels() {
        let lease = ScreenLease()
        let grants = Grants()
        XCTAssertEqual(lease.request("r1", holder: LeaseHolder(runID: "r1", session: "A")) { grants.add("r1") }, 0)
        XCTAssertEqual(lease.request("r2", holder: LeaseHolder(runID: "r2", session: "B")) { grants.add("r2") }, 1)
        XCTAssertEqual(lease.request("r3", holder: LeaseHolder(runID: "r3", session: "C")) { grants.add("r3") }, 2)
        XCTAssertEqual(grants.all, ["r1"])
        XCTAssertEqual(lease.holder, LeaseHolder(runID: "r1", session: "A"))
        XCTAssertEqual(lease.queued, 2)
        XCTAssertEqual(lease.position(of: "r3"), 2)

        lease.release("r1")
        XCTAssertEqual(grants.all, ["r1", "r2"], "first come, first served")
        XCTAssertEqual(lease.holder, LeaseHolder(runID: "r2", session: "B"))
        XCTAssertEqual(lease.position(of: "r3"), 1)
    }

    /// A waiter that gives up must leave the queue, or the run behind it waits on a ghost.
    func testCancelledWaiterLeavesTheQueue() {
        let lease = ScreenLease()
        let grants = Grants()
        _ = lease.request("r1", holder: LeaseHolder(runID: "r1", session: "S")) { grants.add("r1") }
        _ = lease.request("r2", holder: LeaseHolder(runID: "r2", session: "S")) { grants.add("r2") }
        _ = lease.request("r3", holder: LeaseHolder(runID: "r3", session: "S")) { grants.add("r3") }
        lease.release("r2")
        XCTAssertEqual(lease.position(of: "r3"), 1)
        lease.release("r1")
        XCTAssertEqual(grants.all, ["r1", "r3"])
        lease.release("r3")
        XCTAssertNil(lease.holder)
        XCTAssertEqual(lease.queued, 0)
        lease.release("r3")   // idempotent: a run's exit and its cancel can both release
    }

    func testObserversHearEveryChange() {
        let lease = ScreenLease()
        let changes = Grants()
        lease.observe { changes.add("change") }
        _ = lease.request("r1", holder: LeaseHolder(runID: "r1", session: "S")) {}
        _ = lease.request("r2", holder: LeaseHolder(runID: "r2", session: "S")) {}
        lease.release("r1")
        XCTAssertEqual(changes.all.count, 3)
    }
}
