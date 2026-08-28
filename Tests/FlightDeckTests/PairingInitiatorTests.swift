import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingInitiatorTests: XCTestCase {
    private var listener: PairingListener?
    private var initiator: PairingInitiator?

    override func tearDown() async throws {
        initiator?.cancel()
        initiator = nil
        listener?.stop()
        listener = nil
    }

    private func arm(
        code: PairingCode, key: FleetDeviceKey = .mint(), macName: String = "Nate's MacBook"
    ) async throws -> NWEndpoint {
        let listener = PairingListener()
        self.listener = listener
        let port = try await listener.start(
            code: code, key: key, macName: macName,
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return .hostPort(host: "127.0.0.1", port: port)
    }

    private func run(
        code: PairingCode, endpoint: NWEndpoint
    ) async -> Result<(key: FleetDeviceKey, macName: String), PairingInitiator.Failure> {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome:
            Result<(key: FleetDeviceKey, macName: String), PairingInitiator.Failure>?
        let initiator = PairingInitiator()
        self.initiator = initiator
        initiator.onPaired = { key, macName in
            MainActor.assumeIsolated {
                outcome = .success((key, macName))
                settled.fulfill()
            }
        }
        initiator.onFailure = { failure in
            MainActor.assumeIsolated {
                outcome = .failure(failure)
                settled.fulfill()
            }
        }
        initiator.start(code: code, endpoint: endpoint)
        await fulfillment(of: [settled], timeout: 15)
        return outcome ?? .failure(.unreachable)
    }

    /// The whole phone side against the whole Mac side, over a real socket. Both halves come
    /// out of `FleetKit`, so this cannot catch a *consistent* role or name swap inside
    /// `SPAKE2Session` — that is pinned in process by
    /// `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder`, and no wire test of any kind
    /// can reach it (spec §5's amendment). What it does catch is the two callers disagreeing:
    /// both claiming `.initiator`, passing the names in opposite orders, or assembling the
    /// transcript differently.
    func testTheCorrectCodeDeliversTheKeyAndTheMacsName() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let endpoint = try await arm(code: code, key: key, macName: "Nate's MacBook")

        guard case .success(let paired) = await run(code: code, endpoint: endpoint) else {
            return XCTFail("the correct code did not pair")
        }
        XCTAssertEqual(paired.key.slot, key.slot)
        XCTAssertEqual(paired.key.secret, key.secret)
        XCTAssertEqual(paired.macName, "Nate's MacBook")
    }

    /// A code the Mac never minted must come back as `wrongCode` and not as a connection
    /// problem — those two send the user to different places, which is the whole reason the
    /// checksum exists on the phone as well.
    func testAWrongCodeFailsAsAWrongCodeRatherThanAsANetworkError() async throws {
        let endpoint = try await arm(code: .mint())
        guard case .failure(let failure) = await run(code: .mint(), endpoint: endpoint) else {
            return XCTFail("a wrong code paired")
        }
        XCTAssertEqual(failure, .wrongCode)
    }

    /// Mutual, not one-way. Without checking the Mac's own confirmation, anything that could
    /// speak the frames could walk a phone all the way to a sealed blob it would then try to
    /// open — and the phone would report "damaged" for what is really "that was not your Mac".
    /// Driven by a fake responder that never knew the code.
    func testAMacThatCannotProveItKnewTheCodeIsRefused() async throws {
        let impostor = try ImpostorMac()
        defer { impostor.stop() }
        guard case .failure(let failure) = await run(
            code: .mint(), endpoint: await impostor.endpoint()
        ) else {
            return XCTFail("an impostor Mac paired")
        }
        XCTAssertEqual(failure, .wrongCode)
    }

    /// A dead address must not hang the pairing screen forever with no verdict.
    func testAnUnreachableEndpointFailsRatherThanHanging() async throws {
        // Bound and immediately released, so nothing is listening on it.
        let dead = PairingListener()
        let port = try await dead.start(
            code: .mint(), key: .mint(), macName: "Gone",
            serviceName: "flightdeck-test-gone", port: nil
        )
        dead.stop()

        let initiator = PairingInitiator()
        self.initiator = initiator
        initiator.exchangeTimeout = 1
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var failure: PairingInitiator.Failure?
        initiator.onPaired = { _, _ in XCTFail("paired with nothing") }
        initiator.onFailure = { value in
            MainActor.assumeIsolated {
                failure = value
                settled.fulfill()
            }
        }
        initiator.start(code: .mint(), endpoint: .hostPort(host: "127.0.0.1", port: port))
        await fulfillment(of: [settled], timeout: 15)
        XCTAssertEqual(failure, .unreachable, "nothing was listening, so nothing came up")
    }

    /// The other half of what `exchangeTimeout` bounds, and the half the unreachable-endpoint
    /// test cannot reach: a Mac that accepts the connection, completes TLS and the WebSocket
    /// upgrade, takes our first frame — and then says nothing. Nothing ever fails at the
    /// socket level here, so only the deadline can produce a verdict. Without it the pairing
    /// screen spins forever against a peer that is, from the stack's point of view, perfectly
    /// healthy.
    func testAMacThatAnswersAndThenGoesQuietStillFailsAtTheDeadline() async throws {
        let silent = try SilentMac()
        defer { silent.stop() }
        let heard = expectation(description: "the silent Mac received our first frame")
        silent.onFrame = { MainActor.assumeIsolated { heard.fulfill() } }

        let initiator = PairingInitiator()
        self.initiator = initiator
        initiator.exchangeTimeout = 1
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var failure: PairingInitiator.Failure?
        initiator.onPaired = { _, _ in XCTFail("paired with a Mac that said nothing") }
        initiator.onFailure = { value in
            MainActor.assumeIsolated {
                failure = value
                settled.fulfill()
            }
        }
        initiator.start(code: .mint(), endpoint: await silent.endpoint())
        // Ordered: the frame proves the exchange got past `.ready`, so the failure that
        // follows is a stall being cut off rather than a connect that never happened.
        //
        // Those two used to be the same case, and this comment was the only place the
        // difference was written down. `.noAnswer` says it in the type now, which is what
        // lets the phone stop telling a connected user to check their Wi-Fi.
        await fulfillment(of: [heard, settled], timeout: 15, enforceOrder: true)
        XCTAssertEqual(failure, .noAnswer, "it answered the connection, then said nothing")
    }

    /// A responder that answers the frames but never knew the code. Its SPAKE2 half is real —
    /// it just runs on a different password, which is exactly the position an attacker who
    /// spoofed the Bonjour advertisement would be in.
    private final class ImpostorMac: @unchecked Sendable {
        private let listener: NWListener
        private var connection: NWConnection?

        init() throws {
            // `PairingListener`'s own cap, explicitly: the default is the fleet number and
            // this stands in for the pairing listener, not for a fleet one.
            listener = try NWListener(
                using: FleetSocket.webSocketParameters(
                    FleetTLS.pairingListenerParameters(),
                    maximumMessageSize: PairingListener.maxFrameBytes
                )
            )
        }

        func endpoint() async -> NWEndpoint {
            let ready = Expectation()
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak listener] state in
                if case .ready = state, let port = listener?.port, port != .any {
                    ready.resume(port)
                }
            }
            listener.start(queue: .main)
            return .hostPort(host: "127.0.0.1", port: await ready.value)
        }

        private func serve(_ connection: NWConnection) {
            self.connection = connection
            connection.start(queue: .main)
            let session = SPAKE2Session(
                role: .responder,
                myName: PairingChannel.responderName, theirName: PairingChannel.initiatorName
            )
            FleetSocket.receive(PairingClientFrame.self, from: connection) { frame in
                guard case .pake(let peer) = frame else { return }
                // A different code: everything is well-formed, nothing verifies.
                guard let mine = try? session.message(for: .mint()),
                      let material = try? session.keyMaterial(from: peer),
                      let transcript = try? session.transcript
                else { return }
                let secrets = PairingSecrets(
                    keyMaterial: material, transcript: transcript
                )
                FleetSocket.send(PairingServerFrame.pake(msg: mine), over: connection)
                // Answer the confirmation it cannot verify with a seal it cannot open.
                let key = FleetDeviceKey.mint()
                if let box = try? secrets.seal(key, macName: "Not Your Mac") {
                    FleetSocket.send(
                        PairingServerFrame.sealed(
                            mac: secrets.responderConfirmation, box: box
                        ),
                        over: connection
                    )
                }
            } onEnd: { _ in }
        }

        func stop() {
            connection?.cancel()
            listener.cancel()
        }
    }

    /// A responder that completes the channel and then stops: it accepts, lets TLS and the
    /// WebSocket upgrade finish, reads whatever arrives and answers none of it. A peer the
    /// stack is perfectly happy with, which is the only way to exercise a stall *after*
    /// `.ready`.
    private final class SilentMac: @unchecked Sendable {
        private let listener: NWListener
        private var connection: NWConnection?
        /// Fired on the main queue for each frame received, so a test can prove the exchange
        /// got past `.ready` before the deadline it is really measuring.
        var onFrame: (@Sendable () -> Void)?

        init() throws {
            // `PairingListener`'s own cap, explicitly: the default is the fleet number and
            // this stands in for the pairing listener, not for a fleet one.
            listener = try NWListener(
                using: FleetSocket.webSocketParameters(
                    FleetTLS.pairingListenerParameters(),
                    maximumMessageSize: PairingListener.maxFrameBytes
                )
            )
        }

        func endpoint() async -> NWEndpoint {
            let ready = Expectation()
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { [weak listener] state in
                if case .ready = state, let port = listener?.port, port != .any {
                    ready.resume(port)
                }
            }
            listener.start(queue: .main)
            return .hostPort(host: "127.0.0.1", port: await ready.value)
        }

        private func serve(_ connection: NWConnection) {
            self.connection = connection
            connection.start(queue: .main)
            FleetSocket.receive(PairingClientFrame.self, from: connection) { [weak self] _ in
                self?.onFrame?()
            } onEnd: { _ in }
        }

        func stop() {
            connection?.cancel()
            listener.cancel()
        }
    }

    /// A one-shot continuation, because `XCTestExpectation` cannot carry a value out. Shared
    /// by both fakes above.
    private final class Expectation: @unchecked Sendable {
        private var continuation: CheckedContinuation<NWEndpoint.Port, Never>?
        private var pending: NWEndpoint.Port?
        var value: NWEndpoint.Port {
            get async {
                await withCheckedContinuation { continuation in
                    if let pending {
                        continuation.resume(returning: pending)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        }
        func resume(_ port: NWEndpoint.Port) {
            guard pending == nil else { return }
            pending = port
            continuation?.resume(returning: port)
            continuation = nil
        }
    }
}
