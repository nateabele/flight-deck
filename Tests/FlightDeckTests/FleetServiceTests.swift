import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The seam test: a real client, a real socket, and a real `SessionStore` at the far end.
/// This is the test that says slice 1a's spine works.
@MainActor
final class FleetServiceTests: XCTestCase {
    private var service: FleetService?
    private var client: FleetClient?

    override func tearDown() async throws {
        client?.disconnect()
        service?.stop()
        client = nil
        service = nil
    }

    private func standUp() async throws -> (SessionStore, FleetDeviceKey, NWEndpoint.Port) {
        let store = SessionStore(provider: nil, persistence: nil)
        let key = FleetDeviceKey.mint()
        let service = FleetService(store: store, keys: { [key] })
        self.service = service
        return (store, key, try await service.start(port: nil))
    }

    func testAConnectingClientIsHandedTheLiveFleet() async throws {
        let (store, key, port) = try await standUp()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        let arrived = expectation(description: "snapshot")
        var snapshot: FleetSnapshot?
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot(_, let fleet, .initial) = frame {
                snapshot = fleet
                arrived.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        // `await fulfillment`, not `wait(for:)`: this method's synchronous prefix runs as a
        // Task job on the MainActor's executor, which is backed by `DispatchQueue.main` — the
        // same queue `FleetSocketServer`/`FleetClient` use to deliver every callback. A
        // `wait(for:)` spin blocks that job in place without suspending it, so the executor
        // never admits the very callbacks the wait is blocking on: the socket frame would
        // never arrive and the expectation would never fulfill. `fulfillment` is a genuine
        // suspension point, so the Task job ends and the queue drains normally.
        await fulfillment(of: [arrived], timeout: 10)

        XCTAssertEqual(snapshot?.projects.first?.name, "alpha")
        XCTAssertEqual(snapshot?.projects.first?.sessions.map(\.id), [session.id])
    }

    func testAMutationAfterAttachingReachesTheClient() async throws {
        let (store, key, port) = try await standUp()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))

        let renamed = expectation(description: "rename reached the client")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .event(_, .renamed(session.id, "elsewhere", .user)) = frame {
                renamed.fulfill()
            }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)

        let attached = expectation(description: "attached")
        // Poll rather than sleep: `attachedDeviceCount` is the service's own published fact.
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.service?.attachedDeviceCount == 1 { attached.fulfill() }
            }
        }
        // See the comment on the first test: `await fulfillment`, not `wait(for:)`, so the
        // MainActor's DispatchQueue.main-backed executor actually drains while we wait.
        await fulfillment(of: [attached], timeout: 10)
        observer.invalidate()

        store.rename(session.id, to: "elsewhere")
        await fulfillment(of: [renamed], timeout: 10)
    }

    func testMarkingReadFromAClientClearsTheMarkOnTheMac() async throws {
        let (store, key, port) = try await standUp()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.selectSession(b.id)
        store.markUnread(a.id)
        XCTAssertTrue(store.unreadIdle.contains(a.id))

        let acked = expectation(description: "ack")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.markRead(id: a.id)) }
            if case .ack = frame { acked.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [acked], timeout: 10)

        // Unread is one fleet-wide fact, not a per-device one (§8): reading on the phone
        // clears the dot on the Mac, which is what the mark means.
        XCTAssertFalse(store.unreadIdle.contains(a.id))
    }

    func testACommandNamingASessionThatIsGoneIsRefusedNotIgnored() async throws {
        let (_, key, port) = try await standUp()
        let refused = expectation(description: "err")
        let client = FleetClient(key: key)
        self.client = client
        client.onFrame = { frame in
            if case .snapshot = frame { _ = client.send(.markRead(id: UUID())) }
            if case .err(_, "unknown_session") = frame { refused.fulfill() }
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 10)
    }
}
