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

    /// Drives the phone's half of one real exchange and returns what the Mac sealed, from the
    /// protocol rather than from `PairingInitiator` — see `PairingTestClient`'s doc comment
    /// for why that distinction is the whole value of these tests. The initiator role, the two
    /// names and the transcript all come from `PairingChannel` and `SPAKE2Session`, so a
    /// listener that disagreed about any of them produces a confirmation that does not verify
    /// and every caller of this fails. The Mac's own confirmation is checked here so no caller
    /// has to remember to.
    private func exchange(
        code: PairingCode, over endpoint: NWEndpoint, timeout: TimeInterval = 15
    ) async throws -> (key: FleetDeviceKey, macName: String) {
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

        await fulfillment(of: [opened], timeout: timeout)
        return try XCTUnwrap(delivered)
    }

    /// A whole honest exchange: the phone gets the Mac's real device key and its real name,
    /// and neither side had anything but the code to start from.
    func testAnHonestExchangeDeliversTheSealedDeviceKey() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let (_, endpoint) = try await arm(code: code, key: key, macName: "Nate's MacBook")

        let result = try await exchange(code: code, over: endpoint)
        XCTAssertEqual(result.key.slot, key.slot)
        XCTAssertEqual(result.key.secret, key.secret)
        XCTAssertEqual(result.macName, "Nate's MacBook")
    }

    /// The frame the whole exchange exists to deliver must survive the consumer closing the
    /// window from inside `onPaired` — which is what every consumer will do, because "the
    /// window is open" is the consumer's fact, not the listener's.
    ///
    /// Two exchanges, not the five a probabilistic guard would need: against the unfixed shape
    /// (`onPaired` on the line after the send) this fails on the *first* one, 3 runs out of 3,
    /// with the aborted send reporting `ECANCELED` — so one exchange already pins it and the
    /// second is nearly free. The second earns its place differently anyway: the first window
    /// closes itself from inside `onPaired`, so this is also the only test that arms a second
    /// window after a first has been torn down.
    ///
    /// Deliberately at shipping size. Inflating the frame to 2 MB would make it fail against
    /// *correct* code too, pinning a property this design does not have — see `stop()`.
    func testTheSealedFrameSurvivesAStopFromInsideOnPaired() async throws {
        for _ in 0..<2 {
            let code = PairingCode.mint()
            let key = FleetDeviceKey.mint()
            let (listener, endpoint) = try await arm(code: code, key: key, macName: "Test Mac")
            listener.onPaired = { [weak listener] in listener?.stop() }

            let result = try await exchange(code: code, over: endpoint)
            XCTAssertEqual(result.key.slot, key.slot)
        }
    }

    /// The same fix, on the sibling path: the third attempt's `.attemptsExhausted` is what
    /// sends the user back to the Mac for a new code instead of leaving the phone reporting a
    /// network failure, and closing the window from inside `onAttemptsExhausted` is the only
    /// sensible thing to do there.
    ///
    /// This one detects the unfixed shape only under load — 2 failures in 2 full-suite runs,
    /// 0 in 3 runs on its own — so it is the weaker of the pair, and worth knowing about
    /// before trusting a green run of it in isolation. What makes that acceptable rather than
    /// a hole: both paths now go through the same `reply(_:over:thenDrop:then:)`/`onSent`
    /// mechanism, and `testTheSealedFrameSurvivesAStopFromInsideOnPaired` pins that mechanism
    /// deterministically. This test's job is that the exhaustion path is *wired* to it.
    func testTheExhaustedRejectSurvivesAStopFromInsideOnAttemptsExhausted() async throws {
        let (listener, endpoint) = try await arm()
        listener.onAttemptsExhausted = { [weak listener] in listener?.stop() }

        for attempt in 1...PairingListener.maxAttempts {
            let answered = expectation(description: "attempt \(attempt) answered")
            nonisolated(unsafe) var reason: PairingRejection?
            let session = SPAKE2Session(
                role: .initiator,
                myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
            )
            let client = client(endpoint)
            client.onFrame = { frame in
                MainActor.assumeIsolated {
                    switch frame {
                    // A well-formed curve point, then a confirmation that cannot verify: a
                    // typo, which is what the budget counts — not a malformed frame, which
                    // costs nothing.
                    case .pake:
                        client.send(.confirm(mac: Data(repeating: 0xAB, count: 32)))
                    case .reject(let rejected):
                        reason = rejected
                        answered.fulfill()
                    case .sealed:
                        XCTFail("sealed on a confirmation that could not verify")
                    }
                }
            }
            client.start()
            try await Task.sleep(for: .milliseconds(300))
            client.send(.pake(msg: try session.message(for: .mint())))
            await fulfillment(of: [answered], timeout: 10)
            XCTAssertEqual(
                reason,
                attempt == PairingListener.maxAttempts ? .attemptsExhausted : .badCode
            )
        }
        XCTAssertEqual(listener.attemptsSpent, PairingListener.maxAttempts)
    }

    /// `onPaired` says "fired once", and a consumer hangs window teardown and key promotion
    /// off it. The connection is deliberately left open after the seal, so the phone can
    /// replay the confirmation the Mac just accepted — which must not seal a second key.
    func testAReplayedConfirmationDoesNotPairTwice() async throws {
        let code = PairingCode.mint()
        let (listener, endpoint) = try await arm(code: code)
        nonisolated(unsafe) var pairings = 0
        listener.onPaired = { pairings += 1 }

        let session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )
        let sealed = expectation(description: "sealed")
        sealed.assertForOverFulfill = false
        nonisolated(unsafe) var confirmation: Data?
        nonisolated(unsafe) var replayed = false

        let client = client(endpoint)
        client.onFrame = { frame in
            MainActor.assumeIsolated {
                switch frame {
                case .pake(let peer):
                    do {
                        let derived = try PairingSecrets(
                            keyMaterial: session.keyMaterial(from: peer),
                            transcript: session.transcript
                        )
                        confirmation = derived.initiatorConfirmation
                        client.send(.confirm(mac: derived.initiatorConfirmation))
                    } catch {
                        XCTFail("initiator half failed: \(error)")
                    }
                case .sealed:
                    sealed.fulfill()
                    // Once, or the unfixed listener answers the replay with another seal and
                    // this drives itself round forever.
                    guard !replayed, let confirmation else { return }
                    replayed = true
                    client.send(.confirm(mac: confirmation))
                case .reject(let reason):
                    XCTFail("rejected: \(reason)")
                }
            }
        }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        client.send(.pake(msg: try session.message(for: code)))
        await fulfillment(of: [sealed], timeout: 15)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(pairings, 1, "a replayed confirmation paired the same window twice")
    }

    /// The cap itself, which the isolation test below deliberately does not pin: it proves the
    /// two listeners' pools are independent, and passes with this cap raised or deleted. On a
    /// socket whose entire job is bounding *unauthenticated* peers, the number needs its own
    /// test — four are admitted and kept, the fifth is refused.
    func testThePendingPoolAdmitsItsCapAndRefusesTheNextConnection() async throws {
        let (_, endpoint) = try await arm()
        nonisolated(unsafe) var endedEarly = 0
        for _ in 0..<PairingListener.maxPending {
            let filler = client(endpoint)
            filler.onEnd = { endedEarly += 1 }
            filler.start()
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(endedEarly, 0, "a connection inside the cap was dropped")

        let overflow = client(endpoint)
        let refused = expectation(description: "the connection past the cap was refused")
        overflow.onEnd = { refused.fulfill() }
        overflow.start()
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(endedEarly, 0, "the refused connection cost an admitted one its slot")
    }

    /// The bytes an unauthenticated peer may make the Mac buffer are bounded, and the bound is
    /// in the *stack* rather than after the parse. Without it the frame is buffered whole,
    /// JSON-decoded and base64-decoded before anything refuses it — which is why the
    /// assertion is that no answer comes back at all: a listener that parsed this would reply
    /// `.malformed`, and one that never received it cannot.
    func testAnOversizedFrameIsRefusedBeforeItIsParsed() async throws {
        let (listener, endpoint) = try await arm()
        let ended = expectation(description: "connection ended")
        let client = client(endpoint)
        client.onFrame = { XCTFail("an oversized frame was parsed and answered: \($0)") }
        client.onEnd = { ended.fulfill() }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        client.send(.pake(msg: Data(repeating: 0x41, count: 4 * PairingListener.maxFrameBytes)))
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(listener.attemptsSpent, 0)
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
    ///
    /// `exchangeDeadline` is set long on purpose, so the long deadline cannot be what closes
    /// this connection: what is being asserted is that *silence* is bounded by the short one,
    /// and a single deadline of any length would pass a version of this test that did not say
    /// so. Four slots emptied only every 30 seconds is what made the pool cheap to hold.
    func testASilentPairingConnectionIsDroppedOnItsOwnDeadline() async throws {
        let listener = PairingListener()
        self.listener = listener
        listener.firstFrameDeadline = 0.5
        listener.exchangeDeadline = 60
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

    /// The other half of that split, and the half that makes it safe: the short deadline is
    /// for *silence*, not for slowness. A peer that sends its `pake` and then thinks — a phone
    /// on a bad link, a screen the user tabbed away from — keeps the whole exchange window, or
    /// the deadline that exists to evict squatters becomes one that refuses real pairings.
    ///
    /// It pauses for four times the short deadline and then finishes the exchange for real,
    /// because "was not dropped" and "was still usable" are different claims and only the
    /// second one is worth having.
    func testAPeerThatSpeaksAndThenPausesKeepsTheWholeExchangeWindow() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let listener = PairingListener()
        self.listener = listener
        listener.firstFrameDeadline = 0.5
        let port = try await listener.start(
            code: code, key: key, macName: "Test Mac",
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )

        let session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )
        let answered = expectation(description: "the Mac answered our pake")
        let sealed = expectation(description: "sealed key")
        nonisolated(unsafe) var secrets: PairingSecrets?
        nonisolated(unsafe) var delivered: FleetDeviceKey?

        let client = client(.hostPort(host: "127.0.0.1", port: port))
        client.onEnd = { XCTFail("a peer that had spoken was dropped on the silent deadline") }
        client.onFrame = { frame in
            MainActor.assumeIsolated {
                switch frame {
                case .pake(let peer):
                    do {
                        secrets = PairingSecrets(
                            keyMaterial: try session.keyMaterial(from: peer),
                            transcript: try session.transcript
                        )
                        answered.fulfill()
                    } catch { XCTFail("the Mac's pake did not process: \(error)") }
                case .sealed(_, let box):
                    delivered = try? secrets?.open(box).key
                    sealed.fulfill()
                case .reject(let reason):
                    XCTFail("the Mac rejected a correct exchange: \(reason)")
                }
            }
        }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        client.send(.pake(msg: try session.message(for: code)))
        await fulfillment(of: [answered], timeout: 10)

        // Four times the silent deadline, spent holding a pending slot and saying nothing.
        try await Task.sleep(for: .seconds(2))
        client.send(.confirm(mac: try XCTUnwrap(secrets).initiatorConfirmation))
        await fulfillment(of: [sealed], timeout: 10)
        XCTAssertEqual(delivered, key, "the pause cost the exchange its key")
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
