import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingListenerTests: XCTestCase {
    private var listener: PairingListener?
    private var clients: [PairingTestClient] = []
    private var fleet: FleetSocketServer?

    override func tearDown() async throws {
        for client in clients { client.stop() }
        clients.removeAll()
        listener?.stop()
        listener = nil
        fleet?.stop()
        fleet = nil
    }

    private func arm(
        code: PairingCode = .mint(), key: FleetDeviceKey = .mint(), macName: String = "Test Mac"
    ) async throws -> (listener: PairingListener, endpoint: NWEndpoint) {
        let listener = PairingListener()
        self.listener = listener
        let port = try await listener.start(
            code: code, key: key, macName: macName,
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return (listener, .hostPort(host: "127.0.0.1", port: port))
    }

    private func client(_ endpoint: NWEndpoint) -> PairingTestClient {
        let client = PairingTestClient(endpoint: endpoint)
        clients.append(client)
        return client
    }

    /// The exchange, driven from the protocol rather than from `PairingInitiator` — see
    /// `PairingTestClient`'s doc comment for why that distinction is the whole value of this
    /// test. The initiator role, the two names, and the transcript all come from
    /// `PairingChannel` and `SPAKE2Session`, so a listener that disagreed about any of them
    /// produces a confirmation that does not verify and this fails.
    func testAnHonestExchangeDeliversTheSealedDeviceKey() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let (_, endpoint) = try await arm(code: code, key: key, macName: "Nate's MacBook")

        let session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )
        let opened = expectation(description: "sealed key opened")
        nonisolated(unsafe) var delivered: (key: FleetDeviceKey, macName: String)?
        nonisolated(unsafe) var secrets: PairingSecrets?

        let client = client(endpoint)
        client.onFrame = { frame in
            MainActor.assumeIsolated {
                switch frame {
                case .pake(let peer):
                    do {
                        let material = try session.keyMaterial(from: peer)
                        // `session.transcript`, never `myMsg + peer` — it is initiator-first
                        // on both sides, and assembling it here is the mistake the property
                        // exists to make unavailable.
                        let derived = try PairingSecrets(
                            keyMaterial: material, transcript: session.transcript
                        )
                        secrets = derived
                        client.send(.confirm(mac: derived.initiatorConfirmation))
                    } catch {
                        XCTFail("initiator half failed: \(error)")
                    }
                case .sealed(let mac, let box):
                    guard let secrets else { return XCTFail("sealed before pake") }
                    XCTAssertTrue(
                        PairingSecrets.matches(mac, secrets.responderConfirmation),
                        "the Mac's own confirmation did not verify"
                    )
                    delivered = try? secrets.open(box)
                    opened.fulfill()
                case .reject(let reason):
                    XCTFail("rejected: \(reason)")
                }
            }
        }
        client.start()
        // The first frame cannot go before `.ready`, and `PairingTestClient` does not queue —
        // so the PAKE message is sent from the state handler's stead here: give the socket a
        // moment, then send. `onFrame` drives everything after it.
        try await Task.sleep(for: .milliseconds(300))
        client.send(.pake(msg: try session.message(for: code)))

        await fulfillment(of: [opened], timeout: 15)
        let result = try XCTUnwrap(delivered)
        XCTAssertEqual(result.key.slot, key.slot)
        XCTAssertEqual(result.key.secret, key.secret)
        XCTAssertEqual(result.macName, "Nate's MacBook")
    }

    /// Invariant 4, first half: the pairing listener's pending pool is its own. Filling it
    /// must not consume anything the fleet listener needs, and the proof of that is a real
    /// paired device attaching to a real fleet listener while the pairing pool is full.
    func testFillingThePairingListenersPendingPoolLeavesTheFleetListenerServing() async throws {
        let (_, endpoint) = try await arm()

        let key = FleetDeviceKey.mint()
        let fleet = FleetSocketServer()
        fleet.onHello = { _, _ in [.snapshot(seq: 1, fleet: .empty, reason: .initial)] }
        self.fleet = fleet
        let fleetPort = try await fleet.start(keys: [key], port: nil)

        // Silent connections, twice the pairing listener's cap. None of them ever speaks, so
        // each occupies a pending slot until its deadline.
        for _ in 0..<(PairingListener.maxPending * 2) {
            let filler = client(endpoint)
            filler.start()
        }
        try await Task.sleep(for: .milliseconds(500))

        let served = expectation(description: "fleet still serving")
        let fleetClient = FleetClient(key: key)
        fleetClient.onFrame = { if case .snapshot = $0 { served.fulfill() } }
        fleetClient.connect(to: .hostPort(host: "127.0.0.1", port: fleetPort), lastSeq: 0)
        await fulfillment(of: [served], timeout: 15)
        fleetClient.disconnect()
    }

    /// Invariant 4, second half: its own deadline. A peer that completes the bootstrap
    /// handshake and then says nothing is dropped, so a window cannot be held open by silence.
    func testASilentPairingConnectionIsDroppedOnItsOwnDeadline() async throws {
        let listener = PairingListener()
        self.listener = listener
        listener.authDeadline = 0.5
        let port = try await listener.start(
            code: .mint(), key: .mint(), macName: "Test Mac",
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )

        let dropped = expectation(description: "dropped")
        let silent = client(.hostPort(host: "127.0.0.1", port: port))
        silent.onEnd = { dropped.fulfill() }
        silent.start()
        await fulfillment(of: [dropped], timeout: 10)
    }

    /// A message that is not a curve point is a protocol error, not a code guess: it must be
    /// refused without touching the attempt budget, or a stranger could burn a window with
    /// three malformed frames and no knowledge of anything.
    func testAMalformedPakeMessageCostsNoAttempt() async throws {
        let (listener, endpoint) = try await arm()
        let rejected = expectation(description: "rejected")
        let client = client(endpoint)
        client.onFrame = { frame in
            if case .reject(let reason) = frame {
                XCTAssertEqual(reason, .malformed)
                rejected.fulfill()
            }
        }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        // 32 bytes, right length, deliberately not a point: little-endian y = 2, for which
        // decompression has no x. Random bytes decode about half the time, which is not a test.
        var notAPoint = Data(repeating: 0, count: 32)
        notAPoint[0] = 2
        client.send(.pake(msg: notAPoint))
        await fulfillment(of: [rejected], timeout: 10)
        XCTAssertEqual(listener.attemptsSpent, 0)
    }

    /// A confirmation before any PAKE has nothing to check itself against. It must drop the
    /// connection rather than spend an attempt — there is no guess in it.
    func testAConfirmationBeforeAPakeIsRefusedWithoutSpendingAnAttempt() async throws {
        let (listener, endpoint) = try await arm()
        let ended = expectation(description: "connection ended")
        let client = client(endpoint)
        client.onEnd = { ended.fulfill() }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        client.send(.confirm(mac: Data(repeating: 0x00, count: 32)))
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(listener.attemptsSpent, 0)
    }

    /// `stop()` is the mechanism every one of invariant 2's four routes uses, so it has to do
    /// the whole job: the port stops answering and live connections go away.
    func testStoppingTheListenerClosesThePortAndItsConnections() async throws {
        let (listener, endpoint) = try await arm()
        let live = client(endpoint)
        let ended = expectation(description: "live connection ended")
        live.onEnd = { ended.fulfill() }
        live.start()
        try await Task.sleep(for: .milliseconds(300))

        listener.stop()
        await fulfillment(of: [ended], timeout: 10)

        let afterwards = client(endpoint)
        let refused = expectation(description: "refused")
        // `onReady`, not just `onEnd`: a listener that accepted the connection and then
        // dropped it for having no code would end it too, so `onEnd` alone cannot tell
        // "the port is gone" from "the port answered and said no". Removing `stop()`'s
        // `listener?.cancel()` passes without this and fails with it.
        afterwards.onReady = { XCTFail("a stopped listener completed a handshake") }
        afterwards.onFrame = { _ in XCTFail("a stopped listener answered a frame") }
        afterwards.onEnd = { refused.fulfill() }
        afterwards.start()
        try await Task.sleep(for: .milliseconds(300))
        afterwards.send(.pake(msg: Data(repeating: 0x01, count: 32)))
        await fulfillment(of: [refused], timeout: 10)
    }
}
