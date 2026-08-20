import Network
import XCTest
import FleetKit

/// Which paired device is on the other end of *this* socket.
///
/// Every other socket test in the suite registers exactly one key on the listener, where a
/// server that simply reports "the key I know about" is indistinguishable from one that
/// reports "the key this peer handshook with". These tests register two, which is the only
/// arrangement that can tell those apart — and the arrangement any Mac with two paired
/// phones is in.
///
/// `@MainActor` with `await fulfillment(of:)` rather than the non-isolated `wait(for:)` style
/// of `FleetSocketLoopbackTests`: `FleetSocketServer`'s queue is `.main`, so being on the main
/// actor is what lets `start`/`stop` be called directly, and a blocking `wait(for:)` on the
/// main actor would starve the very callbacks it waits on.
@MainActor
final class FleetSlotAttributionTests: XCTestCase {
    private var server: FleetSocketServer?
    private var clients: [FleetClient] = []
    /// The slot the server attributed each `hello` to, in the order the helloes arrived.
    private var attributed: [UUID?] = []
    /// The last set `onAttachedSlotsChanged` fired with.
    private var lastSlotSet: Set<UUID> = []

    override func tearDown() async throws {
        for client in clients { client.disconnect() }
        clients.removeAll()
        server?.stop()
        server = nil
    }

    /// Starts a listener holding every one of `keys`, recording who each `hello` is
    /// attributed to. `onHello` answers with no frames: this file is about attribution, and a
    /// snapshot would only add a second thing that could fail.
    private func startServer(keys: [FleetDeviceKey]) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        self.server = server
        server.onAttachedSlotsChanged = { [weak self] slots in
            MainActor.assumeIsolated { self?.lastSlotSet = slots }
        }
        return try await server.start(keys: keys, port: nil)
    }

    /// Connects one client and waits for the server to have answered its `hello`, so callers
    /// can attach devices in a known order — which is what makes `attributed` readable as
    /// "the first device, then the second" rather than as two racing arrivals.
    private func attach(_ key: FleetDeviceKey, to port: NWEndpoint.Port) async {
        let expected = attributed.count + 1
        let said = expectation(description: "hello \(expected)")
        let client = FleetClient(key: key)
        clients.append(client)
        server?.onHello = { [weak self] attachment, _ in
            MainActor.assumeIsolated {
                self?.attributed.append(attachment.slot)
                if self?.attributed.count == expected { said.fulfill() }
            }
            return []
        }
        client.connect(to: .hostPort(host: "127.0.0.1", port: port), lastSeq: 0)
        await fulfillment(of: [said], timeout: 10)
    }

    /// The bug this file exists for: with two paired devices the server must attribute each
    /// connection to the device that actually handshook on it.
    func testEachAttachedDeviceIsAttributedToItsOwnSlot() async throws {
        let first = FleetDeviceKey.mint()
        let second = FleetDeviceKey.mint()
        let port = try await startServer(keys: [first, second])

        await attach(first, to: port)
        XCTAssertEqual(
            attributed, [first.slot],
            "the first device's hello was attributed to a slot it does not hold"
        )

        await attach(second, to: port)
        XCTAssertEqual(
            attributed, [first.slot, second.slot],
            "the second device's hello was attributed to the wrong slot"
        )
    }

    /// The same truth as seen by the Devices tab: two attached phones are two rows, not one.
    /// `attachedSlots()` is a `Set`, so a server that misattributes both connections to one
    /// slot collapses them into a single badge.
    func testTwoAttachedDevicesAreTwoDistinctSlots() async throws {
        let first = FleetDeviceKey.mint()
        let second = FleetDeviceKey.mint()
        let port = try await startServer(keys: [first, second])

        await attach(first, to: port)
        XCTAssertEqual(lastSlotSet, [first.slot])

        await attach(second, to: port)
        XCTAssertEqual(
            lastSlotSet, [first.slot, second.slot],
            "two attached devices must appear as two slots"
        )
    }

    /// A drop must clear the badge of the device that actually left. The *second* device is
    /// the one dropped here, deliberately: a server that attributes both connections to the
    /// last-registered key survives dropping the first (the set it recomputes happens to look
    /// right), and only dropping the other one tells the two behaviours apart.
    func testDroppingOneDeviceLeavesTheOtherOnItsOwnSlot() async throws {
        let first = FleetDeviceKey.mint()
        let second = FleetDeviceKey.mint()
        let port = try await startServer(keys: [first, second])
        await attach(first, to: port)
        await attach(second, to: port)

        let dropped = expectation(description: "a device dropped")
        server?.onAttachedSlotsChanged = { [weak self] slots in
            MainActor.assumeIsolated {
                self?.lastSlotSet = slots
                if slots.count == 1 { dropped.fulfill() }
            }
        }
        clients[1].disconnect()
        await fulfillment(of: [dropped], timeout: 10)

        XCTAssertEqual(
            lastSlotSet, [first.slot],
            "the device that stayed lost its slot to the one that left"
        )
    }
}
